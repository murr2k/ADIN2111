/* ADIN2111 Atomic Context Fix
 * Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
 *
 * This file provides the fix for the "scheduling while atomic" bug
 * found in the ADIN2111 driver when called from atomic context.
 * 
 * The issue: start_xmit is called with BH disabled (atomic context)
 * but spi_sync() can sleep, causing the kernel BUG.
 *
 * Solution: Use spi_async() or defer to workqueue/tasklet
 */

#include <linux/netdevice.h>
#include <linux/skbuff.h>
#include <linux/spi/spi.h>
#include <linux/workqueue.h>
#include <linux/spinlock.h>
#include "adin2111.h"

/* TX queue management structure */
struct adin2111_tx_queue {
	struct sk_buff_head queue;
	struct work_struct work;
	struct adin2111_priv *priv;
	spinlock_t lock;
	bool stopped;
};

/* Async SPI completion callback */
static void adin2111_spi_complete(void *context)
{
	struct adin2111_async_tx *async_tx = context;
	struct adin2111_priv *priv = async_tx->priv;
	struct net_device *netdev = async_tx->netdev;
	
	/* Update statistics */
	if (async_tx->status == 0) {
		netdev->stats.tx_packets++;
		netdev->stats.tx_bytes += async_tx->len;
	} else {
		netdev->stats.tx_errors++;
	}
	
	/* Free resources */
	dev_kfree_skb_any(async_tx->skb);
	kfree(async_tx->tx_buf);
	kfree(async_tx);
	
	/* Wake queue if it was stopped */
	if (netif_queue_stopped(netdev))
		netif_wake_queue(netdev);
}

/* Async transmit using spi_async (can be called from atomic context) */
static netdev_tx_t adin2111_start_xmit_async(struct sk_buff *skb, struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;
	struct adin2111_async_tx *async_tx;
	struct spi_transfer *xfer;
	struct spi_message *msg;
	u8 *tx_buf;
	u16 frame_header;
	int ret;
	
	/* Check frame size */
	if (skb->len > ADIN2111_MAX_FRAME_SIZE) {
		netdev->stats.tx_dropped++;
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}
	
	/* Allocate async context */
	async_tx = kzalloc(sizeof(*async_tx), GFP_ATOMIC);
	if (!async_tx) {
		netdev->stats.tx_dropped++;
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}
	
	/* Allocate TX buffer */
	tx_buf = kmalloc(skb->len + ADIN2111_FRAME_HEADER_LEN, GFP_ATOMIC);
	if (!tx_buf) {
		kfree(async_tx);
		netdev->stats.tx_dropped++;
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}
	
	/* Prepare frame header */
	frame_header = FIELD_PREP(ADIN2111_FRAME_HEADER_LEN_MASK, skb->len) |
	               FIELD_PREP(ADIN2111_FRAME_HEADER_PORT_MASK, port->port_num);
	
	/* Copy header and data to TX buffer */
	put_unaligned_be16(frame_header, tx_buf);
	memcpy(tx_buf + ADIN2111_FRAME_HEADER_LEN, skb->data, skb->len);
	
	/* Setup async context */
	async_tx->priv = priv;
	async_tx->netdev = netdev;
	async_tx->skb = skb;
	async_tx->tx_buf = tx_buf;
	async_tx->len = skb->len;
	
	/* Initialize SPI message */
	msg = &async_tx->msg;
	xfer = &async_tx->xfer;
	
	spi_message_init(msg);
	msg->complete = adin2111_spi_complete;
	msg->context = async_tx;
	
	/* Setup SPI transfer */
	xfer->tx_buf = tx_buf;
	xfer->len = skb->len + ADIN2111_FRAME_HEADER_LEN;
	spi_message_add_tail(xfer, msg);
	
	/* Submit async SPI transfer */
	ret = spi_async(priv->spi, msg);
	if (ret) {
		netdev->stats.tx_dropped++;
		kfree(tx_buf);
		kfree(async_tx);
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}
	
	/* Stop queue if too many pending transfers */
	if (atomic_inc_return(&priv->tx_pending) >= ADIN2111_TX_QUEUE_LIMIT) {
		netif_stop_queue(netdev);
	}
	
	return NETDEV_TX_OK;
}

/* Workqueue-based transmit handler */
static void adin2111_tx_work(struct work_struct *work)
{
	struct adin2111_tx_queue *tx_queue = container_of(work, struct adin2111_tx_queue, work);
	struct adin2111_priv *priv = tx_queue->priv;
	struct sk_buff *skb;
	unsigned long flags;
	
	/* Process queued packets */
	while ((skb = skb_dequeue(&tx_queue->queue)) != NULL) {
		struct adin2111_port *port = netdev_priv(skb->dev);
		int ret;
		
		/* Now we're in process context, can use spi_sync */
		ret = adin2111_tx_frame(priv, skb, port->port_num);
		
		if (ret) {
			skb->dev->stats.tx_errors++;
		} else {
			skb->dev->stats.tx_packets++;
			skb->dev->stats.tx_bytes += skb->len;
		}
		
		dev_kfree_skb(skb);
		
		/* Wake queue if it was stopped */
		spin_lock_irqsave(&tx_queue->lock, flags);
		if (tx_queue->stopped && skb_queue_len(&tx_queue->queue) < ADIN2111_TX_QUEUE_LOW) {
			tx_queue->stopped = false;
			netif_wake_queue(skb->dev);
		}
		spin_unlock_irqrestore(&tx_queue->lock, flags);
	}
}

/* Workqueue-based start_xmit (defers to work queue) */
static netdev_tx_t adin2111_start_xmit_workqueue(struct sk_buff *skb, struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;
	struct adin2111_tx_queue *tx_queue = &priv->tx_queue;
	unsigned long flags;
	
	/* Check frame size */
	if (skb->len > ADIN2111_MAX_FRAME_SIZE) {
		netdev->stats.tx_dropped++;
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}
	
	/* Queue the packet */
	spin_lock_irqsave(&tx_queue->lock, flags);
	
	/* Check queue limit */
	if (skb_queue_len(&tx_queue->queue) >= ADIN2111_TX_QUEUE_LIMIT) {
		if (!tx_queue->stopped) {
			tx_queue->stopped = true;
			netif_stop_queue(netdev);
		}
		spin_unlock_irqrestore(&tx_queue->lock, flags);
		return NETDEV_TX_BUSY;
	}
	
	skb_queue_tail(&tx_queue->queue, skb);
	spin_unlock_irqrestore(&tx_queue->lock, flags);
	
	/* Schedule work */
	schedule_work(&tx_queue->work);
	
	return NETDEV_TX_OK;
}

/* Initialize TX queue for workqueue approach */
int adin2111_init_tx_queue(struct adin2111_priv *priv)
{
	struct adin2111_tx_queue *tx_queue = &priv->tx_queue;
	
	skb_queue_head_init(&tx_queue->queue);
	INIT_WORK(&tx_queue->work, adin2111_tx_work);
	spin_lock_init(&tx_queue->lock);
	tx_queue->priv = priv;
	tx_queue->stopped = false;
	
	return 0;
}

/* Cleanup TX queue */
void adin2111_cleanup_tx_queue(struct adin2111_priv *priv)
{
	struct adin2111_tx_queue *tx_queue = &priv->tx_queue;
	struct sk_buff *skb;
	
	/* Cancel pending work */
	cancel_work_sync(&tx_queue->work);
	
	/* Free any queued packets */
	while ((skb = skb_dequeue(&tx_queue->queue)) != NULL) {
		dev_kfree_skb_any(skb);
	}
}

/* Module parameter to select TX method */
static int tx_method = 0; /* 0=workqueue, 1=async */
module_param(tx_method, int, 0644);
MODULE_PARM_DESC(tx_method, "TX method: 0=workqueue (default), 1=async");

/* Get the appropriate start_xmit function based on configuration */
netdev_tx_t (*adin2111_get_start_xmit(void))(struct sk_buff *, struct net_device *)
{
	if (tx_method == 1) {
		pr_info("adin2111: Using async SPI for TX (atomic-safe)\n");
		return adin2111_start_xmit_async;
	} else {
		pr_info("adin2111: Using workqueue for TX (atomic-safe)\n");
		return adin2111_start_xmit_workqueue;
	}
}
// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Network Device Operations - CORRECT Implementation
 * No sleeping in softirq context!
 */

#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/interrupt.h>
#include <linux/kthread.h>
#include <linux/skbuff.h>
#include <linux/circ_buf.h>
#include <linux/module.h>

#include "adin2111.h"
#include "adin2111_regs.h"

/* External functions */
extern int adin2111_read_reg(struct adin2111_priv *priv, u32 reg, u32 *val);
extern int adin2111_write_reg(struct adin2111_priv *priv, u32 reg, u32 val);
extern int adin2111_write_fifo(struct adin2111_priv *priv, u32 reg, const u8 *data, size_t len);
extern int adin2111_read_fifo(struct adin2111_priv *priv, u32 reg, u8 *data, size_t len);
extern int adin2111_set_bits(struct adin2111_priv *priv, u32 reg, u32 mask);
extern int adin2111_clear_bits(struct adin2111_priv *priv, u32 reg, u32 mask);

#define ADIN2111_MAX_FRAME_SIZE 1518
#define ADIN2111_FRAME_HEADER_LEN 2
#define TX_RING_SIZE 16
#define RX_POLL_INTERVAL_MS 10

/* TX ring entry */
struct tx_ring_entry {
	struct sk_buff *skb;
	int port;
};

/* Extended port structure with TX ring */
struct adin2111_port_ext {
	struct adin2111_port base;
	
	/* TX ring - lockless for single producer/consumer */
	struct tx_ring_entry tx_ring[TX_RING_SIZE];
	unsigned int tx_head;  /* Producer (ndo_start_xmit) */
	unsigned int tx_tail;  /* Consumer (TX worker) */
	
	/* TX worker */
	struct work_struct tx_work;
	
	/* RX thread */
	struct task_struct *rx_thread;
	bool rx_thread_running;
	
	/* Link polling */
	struct delayed_work link_work;
};

/* TX worker - runs in process context, can sleep */
static void adin2111_tx_worker(struct work_struct *work)
{
	struct adin2111_port_ext *port_ext = container_of(work, 
			struct adin2111_port_ext, tx_work);
	struct adin2111_port *port = &port_ext->base;
	struct adin2111_priv *priv = port->priv;
	struct net_device *netdev = port->netdev;
	unsigned int tail;
	
	/* Process all pending TX */
	while (port_ext->tx_tail != port_ext->tx_head) {
		struct tx_ring_entry *entry;
		struct sk_buff *skb;
		u32 tx_space;
		u16 frame_header;
		u8 header_buf[2];
		int ret;
		
		/* Get next entry */
		tail = port_ext->tx_tail;
		entry = &port_ext->tx_ring[tail % TX_RING_SIZE];
		skb = entry->skb;
		
		if (!skb)
			break;
		
		/* Check TX space (can sleep) */
		mutex_lock(&priv->lock);
		ret = adin2111_read_reg(priv, ADIN2111_TX_SPACE, &tx_space);
		if (ret || tx_space < (skb->len + ADIN2111_FRAME_HEADER_LEN)) {
			mutex_unlock(&priv->lock);
			/* No space, retry later */
			schedule_work(&port_ext->tx_work);
			break;
		}
		
		/* Build frame header */
		frame_header = skb->len;
		if (priv->switch_mode) {
			frame_header |= ((entry->port + 1) << 12);
		}
		
		header_buf[0] = (frame_header >> 8) & 0xFF;
		header_buf[1] = frame_header & 0xFF;
		
		/* Write to FIFO (can sleep) */
		ret = adin2111_write_fifo(priv, ADIN2111_TX_FIFO, header_buf, 2);
		if (!ret) {
			ret = adin2111_write_fifo(priv, ADIN2111_TX_FIFO, 
						  skb->data, skb->len);
		}
		mutex_unlock(&priv->lock);
		
		if (!ret) {
			/* Success - update stats */
			u64_stats_update_begin(&port->stats_lock);
			port->stats.tx_packets++;
			port->stats.tx_bytes += skb->len;
			u64_stats_update_end(&port->stats_lock);
			netdev_sent_queue(netdev, skb->len);
		} else {
			/* Error */
			port->stats.tx_errors++;
		}
		
		/* Free SKB and advance tail */
		dev_kfree_skb(skb);
		entry->skb = NULL;
		
		/* Memory barrier before updating tail */
		smp_wmb();
		port_ext->tx_tail = tail + 1;
		
		/* Wake queue if it was stopped */
		if (netif_queue_stopped(netdev)) {
			unsigned int space = CIRC_SPACE(port_ext->tx_head,
							 port_ext->tx_tail,
							 TX_RING_SIZE);
			if (space >= TX_RING_SIZE / 2)
				netif_wake_queue(netdev);
		}
	}
}

/* ndo_start_xmit - CANNOT sleep, just enqueue */
static netdev_tx_t adin2111_start_xmit(struct sk_buff *skb, 
					struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_port_ext *port_ext = container_of(port,
			struct adin2111_port_ext, base);
	unsigned int head, tail;
	
	/* Quick sanity checks */
	if (skb->len > ADIN2111_MAX_FRAME_SIZE) {
		dev_kfree_skb_any(skb);
		port->stats.tx_dropped++;
		return NETDEV_TX_OK;
	}
	
	/* Check ring space */
	head = port_ext->tx_head;
	tail = READ_ONCE(port_ext->tx_tail);
	
	if (CIRC_SPACE(head, tail, TX_RING_SIZE) < 1) {
		/* Ring full, stop queue */
		netif_stop_queue(netdev);
		return NETDEV_TX_BUSY;
	}
	
	/* Enqueue SKB */
	port_ext->tx_ring[head % TX_RING_SIZE].skb = skb;
	port_ext->tx_ring[head % TX_RING_SIZE].port = port->port_num;
	
	/* Memory barrier before updating head */
	smp_wmb();
	port_ext->tx_head = head + 1;
	
	/* Kick TX worker */
	schedule_work(&port_ext->tx_work);
	
	/* Stop queue if ring is getting full */
	if (CIRC_SPACE(port_ext->tx_head, tail, TX_RING_SIZE) < 2)
		netif_stop_queue(netdev);
	
	return NETDEV_TX_OK;
}

/* RX thread - runs in process context, can sleep */
static int adin2111_rx_thread(void *data)
{
	struct adin2111_port *port = data;
	struct adin2111_port_ext *port_ext = container_of(port,
			struct adin2111_port_ext, base);
	struct adin2111_priv *priv = port->priv;
	struct net_device *netdev = port->netdev;
	
	while (!kthread_should_stop()) {
		u32 status1, rx_size;
		u32 rx_ready_mask;
		int ret;
		
		/* Check if we should keep running */
		if (!port_ext->rx_thread_running) {
			msleep(10);
			continue;
		}
		
		/* Check RX ready (can sleep) */
		mutex_lock(&priv->lock);
		ret = adin2111_read_reg(priv, ADIN2111_STATUS1, &status1);
		if (ret) {
			mutex_unlock(&priv->lock);
			msleep(RX_POLL_INTERVAL_MS);
			continue;
		}
		
		rx_ready_mask = (port->port_num == 0) ?
			ADIN2111_STATUS1_P1_RX_RDY : ADIN2111_STATUS1_P2_RX_RDY;
		
		if (!(status1 & rx_ready_mask)) {
			mutex_unlock(&priv->lock);
			msleep(RX_POLL_INTERVAL_MS);
			continue;
		}
		
		/* Read RX size */
		ret = adin2111_read_reg(priv, ADIN2111_RX_SIZE, &rx_size);
		if (ret || rx_size == 0) {
			mutex_unlock(&priv->lock);
			continue;
		}
		
		u16 frame_size = rx_size & 0xFFFF;
		if (frame_size > ADIN2111_MAX_FRAME_SIZE) {
			/* Bad frame, clear it */
			adin2111_write_reg(priv, ADIN2111_STATUS1, rx_ready_mask);
			port->stats.rx_errors++;
			mutex_unlock(&priv->lock);
			continue;
		}
		
		/* Allocate SKB */
		struct sk_buff *skb = netdev_alloc_skb_ip_align(netdev, frame_size);
		if (!skb) {
			port->stats.rx_dropped++;
			adin2111_write_reg(priv, ADIN2111_STATUS1, rx_ready_mask);
			mutex_unlock(&priv->lock);
			continue;
		}
		
		/* Read frame from FIFO (can sleep) */
		ret = adin2111_read_fifo(priv, ADIN2111_RX_FIFO, 
					  skb->data, frame_size);
		
		/* Clear RX ready */
		adin2111_write_reg(priv, ADIN2111_STATUS1, rx_ready_mask);
		mutex_unlock(&priv->lock);
		
		if (ret) {
			dev_kfree_skb(skb);
			continue;
		}
		
		/* Setup SKB and deliver */
		skb_put(skb, frame_size);
		skb->protocol = eth_type_trans(skb, netdev);
		
		/* Update stats */
		u64_stats_update_begin(&port->stats_lock);
		port->stats.rx_packets++;
		port->stats.rx_bytes += frame_size;
		u64_stats_update_end(&port->stats_lock);
		
		/* Deliver to network stack (we're in process context) */
		netif_rx_ni(skb);
	}
	
	return 0;
}

/* Link polling work */
static void adin2111_link_poll(struct work_struct *work)
{
	struct adin2111_port_ext *port_ext = container_of(work,
			struct adin2111_port_ext, link_work.work);
	struct adin2111_port *port = &port_ext->base;
	struct adin2111_priv *priv = port->priv;
	struct net_device *netdev = port->netdev;
	u32 status;
	int ret;
	
	mutex_lock(&priv->lock);
	
	/* Read link status from hardware */
	ret = adin2111_read_reg(priv, ADIN2111_STATUS0, &status);
	
	mutex_unlock(&priv->lock);
	
	if (!ret) {
		/* Check link bit for our port */
		bool link_up = (status & ADIN2111_STATUS0_LINK) ? true : false;
		
		if (link_up && !netif_carrier_ok(netdev)) {
			netif_carrier_on(netdev);
			netif_wake_queue(netdev);
			netdev_info(netdev, "link up\n");
		} else if (!link_up && netif_carrier_ok(netdev)) {
			netif_carrier_off(netdev);
			netif_stop_queue(netdev);
			netdev_info(netdev, "link down\n");
		}
	}
	
	/* Schedule next poll */
	if (port_ext->rx_thread_running)
		schedule_delayed_work(&port_ext->link_work, HZ);
}

/* Network device open */
static int adin2111_open(struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_port_ext *port_ext = container_of(port,
			struct adin2111_port_ext, base);
	struct adin2111_priv *priv = port->priv;
	u32 config0;
	int ret;
	
	/* Enable hardware */
	mutex_lock(&priv->lock);
	ret = adin2111_read_reg(priv, ADIN2111_CONFIG0, &config0);
	if (!ret) {
		config0 |= ADIN2111_CONFIG0_SYNC;
		ret = adin2111_write_reg(priv, ADIN2111_CONFIG0, config0);
	}
	mutex_unlock(&priv->lock);
	
	if (ret)
		return ret;
	
	/* Start RX thread */
	port_ext->rx_thread_running = true;
	wake_up_process(port_ext->rx_thread);
	
	/* Start link polling */
	schedule_delayed_work(&port_ext->link_work, 0);
	
	/* Start queue */
	netif_start_queue(netdev);
	
	return 0;
}

/* Network device stop */
static int adin2111_stop(struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_port_ext *port_ext = container_of(port,
			struct adin2111_port_ext, base);
	
	/* Stop queue */
	netif_stop_queue(netdev);
	
	/* Stop RX thread */
	port_ext->rx_thread_running = false;
	
	/* Cancel link polling */
	cancel_delayed_work_sync(&port_ext->link_work);
	
	/* Flush TX work */
	cancel_work_sync(&port_ext->tx_work);
	
	/* Drop any pending TX */
	while (port_ext->tx_tail != port_ext->tx_head) {
		unsigned int tail = port_ext->tx_tail;
		struct sk_buff *skb = port_ext->tx_ring[tail % TX_RING_SIZE].skb;
		if (skb)
			dev_kfree_skb(skb);
		port_ext->tx_ring[tail % TX_RING_SIZE].skb = NULL;
		port_ext->tx_tail = tail + 1;
	}
	
	netif_carrier_off(netdev);
	
	return 0;
}

/* TX timeout handler */
static void adin2111_tx_timeout(struct net_device *netdev, unsigned int txqueue)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_port_ext *port_ext = container_of(port,
			struct adin2111_port_ext, base);
	
	netdev_err(netdev, "TX timeout, kicking worker\n");
	port->stats.tx_errors++;
	
	/* Kick TX worker */
	schedule_work(&port_ext->tx_work);
}

/* Get stats64 */
static void adin2111_get_stats64(struct net_device *netdev,
				  struct rtnl_link_stats64 *stats)
{
	struct adin2111_port *port = netdev_priv(netdev);
	unsigned int start;
	
	do {
		start = u64_stats_fetch_begin(&port->stats_lock);
		*stats = port->stats;
	} while (u64_stats_fetch_retry(&port->stats_lock, start));
}

/* Network device operations */
static const struct net_device_ops adin2111_netdev_ops = {
	.ndo_open		= adin2111_open,
	.ndo_stop		= adin2111_stop,
	.ndo_start_xmit		= adin2111_start_xmit,
	.ndo_tx_timeout		= adin2111_tx_timeout,
	.ndo_get_stats64	= adin2111_get_stats64,
	.ndo_validate_addr	= eth_validate_addr,
	.ndo_set_mac_address	= eth_mac_addr,
};

/* Create network device */
struct net_device *adin2111_create_netdev_correct(struct adin2111_priv *priv,
						   int port_num)
{
	struct net_device *netdev;
	struct adin2111_port *port;
	struct adin2111_port_ext *port_ext;
	
	/* Allocate with extended structure */
	netdev = alloc_etherdev(sizeof(struct adin2111_port_ext));
	if (!netdev)
		return NULL;
	
	/* Basic setup */
	ether_setup(netdev);
	SET_NETDEV_DEV(netdev, &priv->spi->dev);
	
	/* Set operations */
	netdev->netdev_ops = &adin2111_netdev_ops;
	
	/* Conservative features */
	netdev->features = NETIF_F_SG;
	netdev->hw_features = netdev->features;
	
	/* Watchdog timeout */
	netdev->watchdog_timeo = msecs_to_jiffies(5000);
	
	/* MTU range */
	netdev->min_mtu = ETH_MIN_MTU;
	netdev->max_mtu = 1500;
	
	/* Setup port structure */
	port_ext = netdev_priv(netdev);
	port = &port_ext->base;
	port->netdev = netdev;
	port->priv = priv;
	port->port_num = port_num;
	u64_stats_init(&port->stats_lock);
	
	/* Initialize TX ring */
	port_ext->tx_head = 0;
	port_ext->tx_tail = 0;
	INIT_WORK(&port_ext->tx_work, adin2111_tx_worker);
	
	/* Initialize link work */
	INIT_DELAYED_WORK(&port_ext->link_work, adin2111_link_poll);
	
	/* Create RX thread */
	port_ext->rx_thread = kthread_create(adin2111_rx_thread, port,
					      "adin2111-rx%d", port_num);
	if (IS_ERR(port_ext->rx_thread)) {
		free_netdev(netdev);
		return NULL;
	}
	
	/* Generate MAC address */
	eth_hw_addr_random(netdev);
	
	return netdev;
}

/* Initialize network device */
int adin2111_netdev_init_correct(struct adin2111_priv *priv)
{
	struct net_device *netdev;
	int ret;
	
	/* Create single netdev for unmanaged switch mode */
	netdev = adin2111_create_netdev_correct(priv, 0);
	if (!netdev)
		return -ENOMEM;
	
	priv->netdev = netdev;
	
	/* Register network device */
	ret = register_netdev(netdev);
	if (ret) {
		dev_err(&priv->spi->dev, "Failed to register netdev: %d\n", ret);
		free_netdev(netdev);
		return ret;
	}
	
	dev_info(&priv->spi->dev, "Registered %s (correct implementation)\n", 
		 netdev->name);
	return 0;
}

/* Cleanup network device */
void adin2111_netdev_uninit_correct(struct adin2111_priv *priv)
{
	if (priv->netdev) {
		struct adin2111_port *port = netdev_priv(priv->netdev);
		struct adin2111_port_ext *port_ext = container_of(port,
				struct adin2111_port_ext, base);
		
		/* Stop RX thread */
		if (port_ext->rx_thread) {
			kthread_stop(port_ext->rx_thread);
		}
		
		unregister_netdev(priv->netdev);
		free_netdev(priv->netdev);
	}
}

MODULE_DESCRIPTION("ADIN2111 Network Device - Correct Implementation");
MODULE_AUTHOR("Analog Devices Inc.");
MODULE_LICENSE("GPL");
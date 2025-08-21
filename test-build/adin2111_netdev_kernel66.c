// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Network Device - Kernel 6.6+ Compatible Version
 * Fixed for kernel API changes:
 * - netif_rx_ni() replaced with netif_rx()
 * - Added missing ADIN2111_STATUS0_LINK definition
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/kthread.h>
#include <linux/workqueue.h>
#include <linux/u64_stats_sync.h>

#include "adin2111.h"
#include "adin2111_regs.h"

/* Add missing register definition for link status */
#ifndef ADIN2111_STATUS0_LINK
#define ADIN2111_STATUS0_LINK		BIT(12)  /* P0_LINK_STATUS bit */
#endif

/* Kernel version compatibility */
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,18,0)
/* netif_rx_ni() was removed in 5.18+, use netif_rx() */
#define netif_rx_compat(skb)	netif_rx(skb)
#else
/* Older kernels use netif_rx_ni() for process context */
#define netif_rx_compat(skb)	netif_rx_ni(skb)
#endif

/* Add missing interrupt defines if not in regs.h */
#ifndef ADIN2111_IMASK0_RXRDYM
#define ADIN2111_IMASK0_RXRDYM		BIT(10)
#endif

#ifndef ADIN2111_IMASK1_P1_RX_RDY
#define ADIN2111_IMASK1_P1_RX_RDY	BIT(17)
#endif

#ifndef ADIN2111_RX_FSIZE
#define ADIN2111_RX_FSIZE		0x90  /* RX frame size register */
#endif

#ifndef ADIN2111_TX_SPACE
#define ADIN2111_TX_SPACE		0x32  /* TX buffer space register */
#endif

#ifndef ADIN2111_RX
#define ADIN2111_RX			0x91  /* RX data register */
#endif

#ifndef ADIN2111_TX
#define ADIN2111_TX			0x31  /* TX data register */
#endif

#define TX_RING_SIZE		256
#define RX_MAX_FRAME_SIZE	1536
#define ADIN2111_MAX_BUFF	2048
#define FRAME_HEADER_SIZE	4  /* 4-byte frame header */

/* External functions */
extern int adin2111_read_reg(struct adin2111_priv *priv, u16 addr, u32 *val);
extern int adin2111_write_reg(struct adin2111_priv *priv, u16 addr, u32 val);
extern int adin2111_read_fifo(struct adin2111_priv *priv, u16 addr, 
			      u8 *data, size_t len);
extern int adin2111_write_fifo(struct adin2111_priv *priv, u16 addr,
			       const u8 *data, size_t len);

/* Port structure for kernel 6.6+ */
struct adin2111_port_kernel66 {
	struct net_device *netdev;
	struct adin2111_priv *priv;
	int port_num;
	
	/* TX ring buffer */
	struct {
		struct sk_buff *skb;
	} tx_ring[TX_RING_SIZE];
	unsigned int tx_head;
	unsigned int tx_tail;
	struct work_struct tx_work;
	
	/* RX kthread */
	struct task_struct *rx_thread;
	bool rx_thread_running;
	
	/* Link state polling */
	struct delayed_work link_work;
	
	/* Statistics with u64_stats_sync */
	struct rtnl_link_stats64 stats;
	struct u64_stats_sync stats_sync;
};

/* TX worker - runs in process context, can sleep */
static void adin2111_tx_worker(struct work_struct *work)
{
	struct adin2111_port_kernel66 *port = container_of(work,
			struct adin2111_port_kernel66, tx_work);
	struct adin2111_priv *priv = port->priv;
	struct net_device *netdev = port->netdev;
	
	while (port->tx_tail != port->tx_head) {
		unsigned int tail = port->tx_tail;
		struct sk_buff *skb = port->tx_ring[tail % TX_RING_SIZE].skb;
		u8 frame_header[FRAME_HEADER_SIZE];
		u32 tx_space;
		int ret;
		
		if (!skb) {
			port->tx_tail = tail + 1;
			continue;
		}
		
		/* Check TX space */
		mutex_lock(&priv->lock);
		ret = adin2111_read_reg(priv, ADIN2111_TX_SPACE, &tx_space);
		if (ret || tx_space < skb->len + FRAME_HEADER_SIZE) {
			mutex_unlock(&priv->lock);
			schedule_work(&port->tx_work);
			break;
		}
		
		/* Build frame header */
		frame_header[0] = (port->port_num << 5) | 0x01;
		frame_header[1] = 0;
		frame_header[2] = (skb->len >> 8) & 0xFF;
		frame_header[3] = skb->len & 0xFF;
		
		/* Write header and data */
		ret = adin2111_write_fifo(priv, ADIN2111_TX, 
					  frame_header, FRAME_HEADER_SIZE);
		if (!ret)
			ret = adin2111_write_fifo(priv, ADIN2111_TX,
						  skb->data, skb->len);
		
		mutex_unlock(&priv->lock);
		
		/* Update stats */
		if (!ret) {
			u64_stats_update_begin(&port->stats_sync);
			port->stats.tx_packets++;
			port->stats.tx_bytes += skb->len;
			u64_stats_update_end(&port->stats_sync);
		} else {
			u64_stats_update_begin(&port->stats_sync);
			port->stats.tx_errors++;
			u64_stats_update_end(&port->stats_sync);
		}
		
		dev_kfree_skb(skb);
		port->tx_ring[tail % TX_RING_SIZE].skb = NULL;
		smp_wmb();
		port->tx_tail = tail + 1;
		
		netif_wake_queue(netdev);
	}
}

/* Network device start_xmit - must not sleep! */
static netdev_tx_t adin2111_start_xmit(struct sk_buff *skb,
					struct net_device *netdev)
{
	struct adin2111_port_kernel66 *port = netdev_priv(netdev);
	unsigned int head = port->tx_head;
	unsigned int next_head = head + 1;
	
	/* Check ring full */
	if (next_head == port->tx_tail + TX_RING_SIZE) {
		netif_stop_queue(netdev);
		return NETDEV_TX_BUSY;
	}
	
	/* Enqueue SKB */
	port->tx_ring[head % TX_RING_SIZE].skb = skb;
	smp_wmb();
	port->tx_head = next_head;
	
	/* Schedule worker */
	schedule_work(&port->tx_work);
	
	/* Stop queue if getting full */
	if (next_head >= port->tx_tail + TX_RING_SIZE - 8)
		netif_stop_queue(netdev);
	
	return NETDEV_TX_OK;
}

/* RX kthread - runs in process context, can sleep */
static int adin2111_rx_thread(void *data)
{
	struct adin2111_port_kernel66 *port = data;
	struct adin2111_priv *priv = port->priv;
	struct net_device *netdev = port->netdev;
	
	while (!kthread_should_stop()) {
		u32 rx_cnt, rx_size;
		int ret;
		
		if (!port->rx_thread_running) {
			set_current_state(TASK_INTERRUPTIBLE);
			schedule();
			continue;
		}
		
		/* Check for RX frames */
		mutex_lock(&priv->lock);
		ret = adin2111_read_reg(priv, ADIN2111_RX_FSIZE, &rx_size);
		mutex_unlock(&priv->lock);
		
		if (ret || rx_size == 0) {
			msleep(1);
			continue;
		}
		
		/* Read frame size */
		u16 frame_size = rx_size & 0xFFFF;
		if (frame_size > RX_MAX_FRAME_SIZE) {
			dev_err(&priv->spi->dev, "Invalid RX size: %u\n", frame_size);
			mutex_lock(&priv->lock);
			adin2111_write_reg(priv, ADIN2111_STATUS1, BIT(17));
			mutex_unlock(&priv->lock);
			continue;
		}
		
		/* Allocate SKB */
		struct sk_buff *skb = netdev_alloc_skb(netdev, frame_size);
		if (!skb) {
			netdev->stats.rx_dropped++;
			continue;
		}
		
		/* Read frame data */
		mutex_lock(&priv->lock);
		ret = adin2111_read_fifo(priv, ADIN2111_RX, skb->data, frame_size);
		
		/* Clear RX ready */
		u32 rx_ready_mask = (port->port_num == 0) ? 
				    ADIN2111_IMASK0_RXRDYM :
				    ADIN2111_IMASK1_P1_RX_RDY;
		
		adin2111_write_reg(priv, ADIN2111_STATUS1, rx_ready_mask);
		mutex_unlock(&priv->lock);
		
		if (ret) {
			dev_kfree_skb(skb);
			continue;
		}
		
		skb_put(skb, frame_size);
		skb->protocol = eth_type_trans(skb, netdev);
		
		/* Update stats with proper sync */
		u64_stats_update_begin(&port->stats_sync);
		port->stats.rx_packets++;
		port->stats.rx_bytes += frame_size;
		u64_stats_update_end(&port->stats_sync);
		
		/* Deliver to network stack - use kernel version appropriate function */
		netif_rx_compat(skb);
	}
	
	return 0;
}

/* Link polling */
static void adin2111_link_poll(struct work_struct *work)
{
	struct adin2111_port_kernel66 *port = container_of(work,
			struct adin2111_port_kernel66, link_work.work);
	struct adin2111_priv *priv = port->priv;
	struct net_device *netdev = port->netdev;
	u32 status;
	int ret;
	
	mutex_lock(&priv->lock);
	ret = adin2111_read_reg(priv, ADIN2111_STATUS0, &status);
	mutex_unlock(&priv->lock);
	
	if (!ret) {
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
	
	if (port->rx_thread_running)
		schedule_delayed_work(&port->link_work, HZ);
}

/* Network device open */
static int adin2111_open(struct net_device *netdev)
{
	struct adin2111_port_kernel66 *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;
	u32 config0;
	int ret;
	
	mutex_lock(&priv->lock);
	ret = adin2111_read_reg(priv, ADIN2111_CONFIG0, &config0);
	if (!ret) {
		config0 |= ADIN2111_CONFIG0_SYNC;
		ret = adin2111_write_reg(priv, ADIN2111_CONFIG0, config0);
	}
	mutex_unlock(&priv->lock);
	
	if (ret)
		return ret;
	
	port->rx_thread_running = true;
	if (port->rx_thread)
		wake_up_process(port->rx_thread);
	
	schedule_delayed_work(&port->link_work, 0);
	netif_start_queue(netdev);
	
	return 0;
}

/* Network device stop */
static int adin2111_stop(struct net_device *netdev)
{
	struct adin2111_port_kernel66 *port = netdev_priv(netdev);
	
	netif_stop_queue(netdev);
	port->rx_thread_running = false;
	cancel_delayed_work_sync(&port->link_work);
	cancel_work_sync(&port->tx_work);
	
	/* Drop pending TX */
	while (port->tx_tail != port->tx_head) {
		unsigned int tail = port->tx_tail;
		struct sk_buff *skb = port->tx_ring[tail % TX_RING_SIZE].skb;
		if (skb)
			dev_kfree_skb(skb);
		port->tx_ring[tail % TX_RING_SIZE].skb = NULL;
		port->tx_tail = tail + 1;
	}
	
	netif_carrier_off(netdev);
	return 0;
}

/* TX timeout handler */
static void adin2111_tx_timeout(struct net_device *netdev, unsigned int txqueue)
{
	struct adin2111_port_kernel66 *port = netdev_priv(netdev);
	
	netdev_err(netdev, "TX timeout\n");
	netdev->stats.tx_errors++;
	schedule_work(&port->tx_work);
}

/* Get stats64 with proper sync */
static void adin2111_get_stats64(struct net_device *netdev,
				  struct rtnl_link_stats64 *stats)
{
	struct adin2111_port_kernel66 *port = netdev_priv(netdev);
	unsigned int start;
	
	do {
		start = u64_stats_fetch_begin(&port->stats_sync);
		*stats = port->stats;
	} while (u64_stats_fetch_retry(&port->stats_sync, start));
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
struct net_device *adin2111_create_netdev_kernel66(struct adin2111_priv *priv,
						    int port_num)
{
	struct net_device *netdev;
	struct adin2111_port_kernel66 *port;
	
	netdev = alloc_etherdev(sizeof(struct adin2111_port_kernel66));
	if (!netdev)
		return NULL;
	
	ether_setup(netdev);
	SET_NETDEV_DEV(netdev, &priv->spi->dev);
	
	netdev->netdev_ops = &adin2111_netdev_ops;
	netdev->features = NETIF_F_SG;
	netdev->hw_features = netdev->features;
	netdev->watchdog_timeo = msecs_to_jiffies(5000);
	netdev->min_mtu = ETH_MIN_MTU;
	netdev->max_mtu = 1500;
	
	port = netdev_priv(netdev);
	port->netdev = netdev;
	port->priv = priv;
	port->port_num = port_num;
	u64_stats_init(&port->stats_sync);
	
	port->tx_head = 0;
	port->tx_tail = 0;
	INIT_WORK(&port->tx_work, adin2111_tx_worker);
	INIT_DELAYED_WORK(&port->link_work, adin2111_link_poll);
	
	port->rx_thread = kthread_create(adin2111_rx_thread, port,
					  "adin2111-rx%d", port_num);
	if (IS_ERR(port->rx_thread)) {
		free_netdev(netdev);
		return NULL;
	}
	
	eth_hw_addr_random(netdev);
	
	return netdev;
}

/* Initialize network device - compatible entry point */
int adin2111_netdev_init_correct(struct adin2111_priv *priv)
{
	struct net_device *netdev;
	int ret;
	
	netdev = adin2111_create_netdev_kernel66(priv, 0);
	if (!netdev)
		return -ENOMEM;
	
	priv->netdev = netdev;
	
	ret = register_netdev(netdev);
	if (ret) {
		struct adin2111_port_kernel66 *port = netdev_priv(netdev);
		if (port->rx_thread)
			kthread_stop(port->rx_thread);
		free_netdev(netdev);
		return ret;
	}
	
	dev_info(&priv->spi->dev, "Registered %s (kernel 6.6+ version)\n", 
		 netdev->name);
	return 0;
}

/* Cleanup network device - compatible entry point */
void adin2111_netdev_uninit_correct(struct adin2111_priv *priv)
{
	if (priv->netdev) {
		struct adin2111_port_kernel66 *port = netdev_priv(priv->netdev);
		
		if (port->rx_thread)
			kthread_stop(port->rx_thread);
		
		unregister_netdev(priv->netdev);
		free_netdev(priv->netdev);
	}
}

MODULE_DESCRIPTION("ADIN2111 Network Device - Kernel 6.6+ Compatible");
MODULE_AUTHOR("Murray Kopit <murr2k@gmail.com>");
MODULE_LICENSE("GPL");
MODULE_VERSION("3.0.1");
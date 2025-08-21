// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Network Device Operations - FINAL FIXED VERSION
 * Compiles against actual kernel headers
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
#define TX_RING_SIZE 16
#define RX_POLL_INTERVAL_MS 10

/* Use the correct register names from adin2111_regs.h */
#define ADIN2111_RX_FIFO	ADIN2111_RX
#define ADIN2111_TX_FIFO	ADIN2111_TX
#define ADIN2111_RX_SIZE_REG	ADIN2111_RX_FSIZE
#define ADIN2111_TX_SPACE_REG	ADIN2111_TX_SPACE

/* Interrupt mask bits - define if not in regs.h */
#ifndef ADIN2111_IMASK1_P1_RX_RDY
#define ADIN2111_IMASK1		ADIN2111_IMASK0
#define ADIN2111_IMASK1_P1_RX_RDY	BIT(1)
#define ADIN2111_IMASK1_P2_RX_RDY	BIT(2)
#endif

/* TX ring entry */
struct tx_ring_entry {
	struct sk_buff *skb;
	int port;
};

/* Extended port structure with proper stats sync */
struct adin2111_port_final {
	/* Base port info */
	struct net_device *netdev;
	struct adin2111_priv *priv;
	u8 port_num;
	
	/* Statistics with proper u64_stats_sync */
	struct rtnl_link_stats64 stats;
	struct u64_stats_sync stats_sync;  /* CORRECT TYPE */
	
	/* TX ring */
	struct tx_ring_entry tx_ring[TX_RING_SIZE];
	unsigned int tx_head;
	unsigned int tx_tail;
	struct work_struct tx_work;
	
	/* RX thread */
	struct task_struct *rx_thread;
	bool rx_thread_running;
	
	/* Link polling */
	struct delayed_work link_work;
};

/* TX worker - runs in process context */
static void adin2111_tx_worker(struct work_struct *work)
{
	struct adin2111_port_final *port = container_of(work, 
			struct adin2111_port_final, tx_work);
	struct adin2111_priv *priv = port->priv;
	struct net_device *netdev = port->netdev;
	unsigned int tail;
	
	while (port->tx_tail != port->tx_head) {
		struct tx_ring_entry *entry;
		struct sk_buff *skb;
		u32 tx_space;
		u16 frame_header;
		u8 header_buf[ADIN2111_FRAME_HEADER_LEN];  /* Use the 4-byte version */
		int ret;
		
		tail = port->tx_tail;
		entry = &port->tx_ring[tail % TX_RING_SIZE];
		skb = entry->skb;
		
		if (!skb)
			break;
		
		/* Check TX space */
		mutex_lock(&priv->lock);
		ret = adin2111_read_reg(priv, ADIN2111_TX_SPACE_REG, &tx_space);
		if (ret || tx_space < (skb->len + ADIN2111_FRAME_HEADER_LEN)) {
			mutex_unlock(&priv->lock);
			schedule_work(&port->tx_work);
			break;
		}
		
		/* Build frame header (4 bytes for this hardware) */
		frame_header = skb->len & ADIN2111_FRAME_HEADER_LEN_MASK;
		if (priv->switch_mode) {
			frame_header |= ((entry->port + 1) << 12);
		}
		
		/* 4-byte header format */
		header_buf[0] = 0;  /* Reserved */
		header_buf[1] = 0;  /* Reserved */
		header_buf[2] = (frame_header >> 8) & 0xFF;
		header_buf[3] = frame_header & 0xFF;
		
		/* Write to FIFO */
		ret = adin2111_write_fifo(priv, ADIN2111_TX_FIFO, header_buf, 
					  ADIN2111_FRAME_HEADER_LEN);
		if (!ret) {
			ret = adin2111_write_fifo(priv, ADIN2111_TX_FIFO, 
						  skb->data, skb->len);
		}
		mutex_unlock(&priv->lock);
		
		if (!ret) {
			/* Update stats with proper sync */
			u64_stats_update_begin(&port->stats_sync);
			port->stats.tx_packets++;
			port->stats.tx_bytes += skb->len;
			u64_stats_update_end(&port->stats_sync);
			netdev_sent_queue(netdev, skb->len);
		} else {
			netdev->stats.tx_errors++;
		}
		
		dev_kfree_skb(skb);
		entry->skb = NULL;
		
		smp_wmb();
		port->tx_tail = tail + 1;
		
		if (netif_queue_stopped(netdev)) {
			unsigned int space = CIRC_SPACE(port->tx_head,
							 port->tx_tail,
							 TX_RING_SIZE);
			if (space >= TX_RING_SIZE / 2)
				netif_wake_queue(netdev);
		}
	}
}

/* ndo_start_xmit - cannot sleep */
static netdev_tx_t adin2111_start_xmit(struct sk_buff *skb, 
					struct net_device *netdev)
{
	struct adin2111_port_final *port = netdev_priv(netdev);
	unsigned int head, tail;
	
	if (skb->len > ADIN2111_MAX_FRAME_SIZE) {
		dev_kfree_skb_any(skb);
		netdev->stats.tx_dropped++;
		return NETDEV_TX_OK;
	}
	
	head = port->tx_head;
	tail = READ_ONCE(port->tx_tail);
	
	if (CIRC_SPACE(head, tail, TX_RING_SIZE) < 1) {
		netif_stop_queue(netdev);
		return NETDEV_TX_BUSY;
	}
	
	port->tx_ring[head % TX_RING_SIZE].skb = skb;
	port->tx_ring[head % TX_RING_SIZE].port = port->port_num;
	
	smp_wmb();
	port->tx_head = head + 1;
	
	schedule_work(&port->tx_work);
	
	if (CIRC_SPACE(port->tx_head, tail, TX_RING_SIZE) < 2)
		netif_stop_queue(netdev);
	
	return NETDEV_TX_OK;
}

/* RX thread - runs in process context */
static int adin2111_rx_thread(void *data)
{
	struct adin2111_port_final *port = data;
	struct adin2111_priv *priv = port->priv;
	struct net_device *netdev = port->netdev;
	
	while (!kthread_should_stop()) {
		u32 status1, rx_size;
		u32 rx_ready_mask;
		int ret;
		
		if (!port->rx_thread_running) {
			msleep(10);
			continue;
		}
		
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
		ret = adin2111_read_reg(priv, ADIN2111_RX_SIZE_REG, &rx_size);
		if (ret || rx_size == 0) {
			mutex_unlock(&priv->lock);
			continue;
		}
		
		u16 frame_size = rx_size & ADIN2111_RX_SIZE_MASK;
		if (frame_size > ADIN2111_MAX_FRAME_SIZE) {
			adin2111_write_reg(priv, ADIN2111_STATUS1, rx_ready_mask);
			netdev->stats.rx_errors++;
			mutex_unlock(&priv->lock);
			continue;
		}
		
		struct sk_buff *skb = netdev_alloc_skb_ip_align(netdev, frame_size);
		if (!skb) {
			netdev->stats.rx_dropped++;
			adin2111_write_reg(priv, ADIN2111_STATUS1, rx_ready_mask);
			mutex_unlock(&priv->lock);
			continue;
		}
		
		/* Read frame from FIFO */
		ret = adin2111_read_fifo(priv, ADIN2111_RX_FIFO, 
					  skb->data, frame_size);
		
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
		
		/* Deliver to network stack */
		netif_rx_ni(skb);
	}
	
	return 0;
}

/* Link polling */
static void adin2111_link_poll(struct work_struct *work)
{
	struct adin2111_port_final *port = container_of(work,
			struct adin2111_port_final, link_work.work);
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
	struct adin2111_port_final *port = netdev_priv(netdev);
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
	struct adin2111_port_final *port = netdev_priv(netdev);
	
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
	struct adin2111_port_final *port = netdev_priv(netdev);
	
	netdev_err(netdev, "TX timeout\n");
	netdev->stats.tx_errors++;
	schedule_work(&port->tx_work);
}

/* Get stats64 with proper sync */
static void adin2111_get_stats64(struct net_device *netdev,
				  struct rtnl_link_stats64 *stats)
{
	struct adin2111_port_final *port = netdev_priv(netdev);
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
struct net_device *adin2111_create_netdev_final(struct adin2111_priv *priv,
						 int port_num)
{
	struct net_device *netdev;
	struct adin2111_port_final *port;
	
	netdev = alloc_etherdev(sizeof(struct adin2111_port_final));
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
	u64_stats_init(&port->stats_sync);  /* CORRECT INIT */
	
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

/* Initialize network device */
int adin2111_netdev_init_final(struct adin2111_priv *priv)
{
	struct net_device *netdev;
	int ret;
	
	netdev = adin2111_create_netdev_final(priv, 0);
	if (!netdev)
		return -ENOMEM;
	
	priv->netdev = netdev;
	
	ret = register_netdev(netdev);
	if (ret) {
		struct adin2111_port_final *port = netdev_priv(netdev);
		if (port->rx_thread)
			kthread_stop(port->rx_thread);
		free_netdev(netdev);
		return ret;
	}
	
	dev_info(&priv->spi->dev, "Registered %s (final version)\n", 
		 netdev->name);
	return 0;
}

/* Cleanup network device */
void adin2111_netdev_uninit_final(struct adin2111_priv *priv)
{
	if (priv->netdev) {
		struct adin2111_port_final *port = netdev_priv(priv->netdev);
		
		if (port->rx_thread)
			kthread_stop(port->rx_thread);
		
		unregister_netdev(priv->netdev);
		free_netdev(priv->netdev);
	}
}

MODULE_DESCRIPTION("ADIN2111 Network Device - Final Fixed Version");
MODULE_AUTHOR("Murray Kopit <murr2k@gmail.com>");
MODULE_LICENSE("GPL");
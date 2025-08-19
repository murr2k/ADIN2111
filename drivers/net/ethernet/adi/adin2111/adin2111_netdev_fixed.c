// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Dual Port Industrial Ethernet Switch/PHY
 * Network Device Operations - FIXED for atomic context bug
 *
 * Copyright 2024 Analog Devices Inc.
 */

#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/interrupt.h>
#include <linux/workqueue.h>
#include <linux/module.h>
#include <linux/bitfield.h>

#include "adin2111.h"
#include "adin2111_regs.h"

/* External function declarations */
extern int adin2111_read_fifo(struct adin2111_priv *priv, u32 reg, u8 *data, size_t len);
extern int adin2111_write_fifo(struct adin2111_priv *priv, u32 reg, const u8 *data, size_t len);

/* TX work structure for deferred transmission */
struct adin2111_tx_work {
	struct work_struct work;
	struct adin2111_priv *priv;
	struct sk_buff *skb;
	struct adin2111_port *port;
};

static void adin2111_tx_work_handler(struct work_struct *work)
{
	struct adin2111_tx_work *tx_work = container_of(work, struct adin2111_tx_work, work);
	struct adin2111_priv *priv = tx_work->priv;
	struct adin2111_port *port = tx_work->port;
	struct sk_buff *skb = tx_work->skb;
	struct net_device *netdev = port->netdev;
	int ret;

	/* Use mutex for SPI access - can sleep */
	mutex_lock(&priv->lock);

	/* Check if TX FIFO has space */
	u32 tx_space;
	ret = adin2111_read_reg(priv, ADIN2111_TX_SPACE, &tx_space);
	if (ret || tx_space < (skb->len + ADIN2111_FRAME_HEADER_LEN)) {
		/* No space, requeue */
		netif_stop_queue(netdev);
		dev_kfree_skb(skb);
		port->stats.tx_dropped++;
		goto out;
	}

	ret = adin2111_tx_frame(priv, skb, port->port_num);
	if (ret) {
		dev_err(&priv->spi->dev, "TX failed: %d\n", ret);
		port->stats.tx_errors++;
		dev_kfree_skb(skb);
	} else {
		port->stats.tx_packets++;
		port->stats.tx_bytes += skb->len;
		dev_consume_skb_any(skb);
	}

	/* Wake queue if it was stopped */
	if (netif_queue_stopped(netdev))
		netif_wake_queue(netdev);

out:
	mutex_unlock(&priv->lock);
	kfree(tx_work);
}

static netdev_tx_t adin2111_start_xmit(struct sk_buff *skb, struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv;
	struct adin2111_tx_work *tx_work;

	/* Validate pointers to prevent kernel panic */
	if (!port) {
		dev_err(&netdev->dev, "Invalid port in xmit\n");
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}

	priv = port->priv;
	if (!priv) {
		dev_err(&netdev->dev, "Invalid priv in xmit\n");
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}

	if (skb->len > ADIN2111_MAX_FRAME_SIZE) {
		dev_err(&priv->spi->dev, "Frame too large: %d bytes\n", skb->len);
		dev_kfree_skb_any(skb);
		port->stats.tx_dropped++;
		return NETDEV_TX_OK;
	}

	/* Allocate work structure for deferred transmission */
	tx_work = kmalloc(sizeof(*tx_work), GFP_ATOMIC);
	if (!tx_work) {
		dev_kfree_skb_any(skb);
		port->stats.tx_dropped++;
		return NETDEV_TX_OK;
	}

	/* Initialize work structure */
	INIT_WORK(&tx_work->work, adin2111_tx_work_handler);
	tx_work->priv = priv;
	tx_work->port = port;
	tx_work->skb = skb;

	/* Schedule transmission work - this doesn't sleep */
	queue_work(system_wq, &tx_work->work);

	return NETDEV_TX_OK;
}

/* Alternative fix using bottom half (tasklet) instead of workqueue */
static void adin2111_tx_tasklet(unsigned long data)
{
	struct adin2111_port *port = (struct adin2111_port *)data;
	struct adin2111_priv *priv = port->priv;
	struct sk_buff *skb;
	int ret;

	/* Process all queued packets */
	while ((skb = skb_dequeue(&port->tx_queue))) {
		/* Use mutex for SPI access */
		mutex_lock(&priv->lock);

		/* Check TX space */
		u32 tx_space;
		ret = adin2111_read_reg(priv, ADIN2111_TX_SPACE, &tx_space);
		if (ret || tx_space < (skb->len + ADIN2111_FRAME_HEADER_LEN)) {
			/* No space, requeue and stop */
			skb_queue_head(&port->tx_queue, skb);
			netif_stop_queue(port->netdev);
			mutex_unlock(&priv->lock);
			break;
		}

		ret = adin2111_tx_frame(priv, skb, port->port_num);
		if (ret) {
			dev_err(&priv->spi->dev, "TX failed: %d\n", ret);
			port->stats.tx_errors++;
		} else {
			port->stats.tx_packets++;
			port->stats.tx_bytes += skb->len;
		}

		mutex_unlock(&priv->lock);
		dev_kfree_skb(skb);
	}

	/* Wake queue if packets were transmitted */
	if (netif_queue_stopped(port->netdev) && skb_queue_empty(&port->tx_queue))
		netif_wake_queue(port->netdev);
}

/* Alternative start_xmit using tasklet approach */
static netdev_tx_t adin2111_start_xmit_tasklet(struct sk_buff *skb, struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv;

	/* Validate pointers */
	if (!port) {
		dev_err(&netdev->dev, "Invalid port in xmit\n");
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}

	priv = port->priv;
	if (!priv) {
		dev_err(&netdev->dev, "Invalid priv in xmit\n");
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}

	if (skb->len > ADIN2111_MAX_FRAME_SIZE) {
		dev_err(&priv->spi->dev, "Frame too large: %d bytes\n", skb->len);
		dev_kfree_skb_any(skb);
		port->stats.tx_dropped++;
		return NETDEV_TX_OK;
	}

	/* Queue the packet for tasklet processing */
	skb_queue_tail(&port->tx_queue, skb);

	/* Schedule tasklet to process TX queue */
	tasklet_schedule(&port->tx_tasklet);

	return NETDEV_TX_OK;
}

static int adin2111_open(struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;
	int ret;

	dev_info(&priv->spi->dev, "Opening port %d\n", port->port_num);

	/* Initialize TX queue and tasklet if using tasklet approach */
	skb_queue_head_init(&port->tx_queue);
	tasklet_init(&port->tx_tasklet, adin2111_tx_tasklet, (unsigned long)port);

	/* Start PHY */
	if (port->phydev) {
		phy_start(port->phydev);
	}

	/* Enable port in switch configuration */
	if (priv->switch_mode) {
		u32 port_func_reg;
		ret = adin2111_read_reg(priv, ADIN2111_PORT_FUNCT, &port_func_reg);
		if (ret)
			goto err_phy_stop;

		/* Enable broadcast and multicast for this port */
		if (port->port_num == 0) {
			port_func_reg &= ~(ADIN2111_PORT_FUNCT_BC_DIS_P1 |
					    ADIN2111_PORT_FUNCT_MC_DIS_P1);
		} else {
			port_func_reg &= ~(ADIN2111_PORT_FUNCT_BC_DIS_P2 |
					    ADIN2111_PORT_FUNCT_MC_DIS_P2);
		}

		ret = adin2111_write_reg(priv, ADIN2111_PORT_FUNCT, port_func_reg);
		if (ret)
			goto err_phy_stop;
	}

	netif_start_queue(netdev);
	return 0;

err_phy_stop:
	if (port->phydev)
		phy_stop(port->phydev);
	tasklet_kill(&port->tx_tasklet);
	skb_queue_purge(&port->tx_queue);
	return ret;
}

static int adin2111_stop(struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;

	dev_info(&priv->spi->dev, "Stopping port %d\n", port->port_num);

	netif_stop_queue(netdev);

	/* Kill tasklet and purge TX queue */
	tasklet_kill(&port->tx_tasklet);
	skb_queue_purge(&port->tx_queue);

	/* Stop PHY */
	if (port->phydev)
		phy_stop(port->phydev);

	/* Disable port in switch configuration */
	if (priv->switch_mode) {
		u32 port_func_reg;
		int ret = adin2111_read_reg(priv, ADIN2111_PORT_FUNCT, &port_func_reg);
		if (!ret) {
			if (port->port_num == 0) {
				port_func_reg |= ADIN2111_PORT_FUNCT_BC_DIS_P1 |
						 ADIN2111_PORT_FUNCT_MC_DIS_P1;
			} else {
				port_func_reg |= ADIN2111_PORT_FUNCT_BC_DIS_P2 |
						 ADIN2111_PORT_FUNCT_MC_DIS_P2;
			}
			adin2111_write_reg(priv, ADIN2111_PORT_FUNCT, port_func_reg);
		}
	}

	return 0;
}

static void adin2111_get_stats64(struct net_device *netdev,
				  struct rtnl_link_stats64 *stats)
{
	struct adin2111_port *port = netdev_priv(netdev);

	spin_lock(&port->stats_lock);
	*stats = port->stats;
	spin_unlock(&port->stats_lock);
}

static int adin2111_netdev_set_mac_address(struct net_device *netdev, void *addr)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;
	struct sockaddr *sock_addr = addr;
	int ret;

	if (!is_valid_ether_addr(sock_addr->sa_data))
		return -EADDRNOTAVAIL;

	ret = eth_mac_addr(netdev, addr);
	if (ret)
		return ret;

	/* Update hardware MAC filter */
	if (priv->switch_mode && port->port_num == 0) {
		u32 mac_upper = (netdev->dev_addr[0] << 8) | netdev->dev_addr[1];
		u32 mac_lower = (netdev->dev_addr[2] << 24) | (netdev->dev_addr[3] << 16) |
				(netdev->dev_addr[4] << 8) | netdev->dev_addr[5];

		ret = adin2111_write_reg(priv, ADIN2111_MAC_ADDR_FILTER_UPR, mac_upper);
		if (ret)
			return ret;

		ret = adin2111_write_reg(priv, ADIN2111_MAC_ADDR_FILTER_LWR, mac_lower);
		if (ret)
			return ret;

		/* Enable MAC filtering */
		ret = adin2111_write_reg(priv, ADIN2111_MAC_ADDR_MASK_UPR, 0xFFFF);
		if (ret)
			return ret;

		ret = adin2111_write_reg(priv, ADIN2111_MAC_ADDR_MASK_LWR, 0xFFFFFFFF);
		if (ret)
			return ret;
	}

	return 0;
}

static int adin2111_change_mtu(struct net_device *netdev, int new_mtu)
{
	if (new_mtu < ETH_ZLEN || new_mtu > (ADIN2111_MAX_FRAME_SIZE - ETH_HLEN))
		return -EINVAL;

	netdev->mtu = new_mtu;
	return 0;
}

/* Use workqueue approach for production */
static const struct net_device_ops adin2111_netdev_ops = {
	.ndo_open		= adin2111_open,
	.ndo_stop		= adin2111_stop,
	.ndo_start_xmit		= adin2111_start_xmit,  /* Workqueue approach */
	.ndo_get_stats64	= adin2111_get_stats64,
	.ndo_set_mac_address	= adin2111_netdev_set_mac_address,
	.ndo_change_mtu		= adin2111_change_mtu,
	.ndo_validate_addr	= eth_validate_addr,
};

/* Alternative using tasklet approach */
static const struct net_device_ops adin2111_netdev_ops_tasklet = {
	.ndo_open		= adin2111_open,
	.ndo_stop		= adin2111_stop,
	.ndo_start_xmit		= adin2111_start_xmit_tasklet,  /* Tasklet approach */
	.ndo_get_stats64	= adin2111_get_stats64,
	.ndo_set_mac_address	= adin2111_netdev_set_mac_address,
	.ndo_change_mtu		= adin2111_change_mtu,
	.ndo_validate_addr	= eth_validate_addr,
};

int adin2111_tx_frame(struct adin2111_priv *priv, struct sk_buff *skb, int port)
{
	u8 *frame_buf;
	u16 frame_header;
	int ret;

	/* NOTE: This function is now called from workqueue/tasklet context
	 * where sleeping is allowed, so spi_sync is safe to use
	 */

	/* Allocate buffer for frame header + data */
	frame_buf = kmalloc(skb->len + ADIN2111_FRAME_HEADER_LEN, GFP_KERNEL);
	if (!frame_buf)
		return -ENOMEM;

	/* Prepare frame header */
	frame_header = FIELD_PREP(ADIN2111_FRAME_HEADER_LEN_MASK, skb->len) |
		       FIELD_PREP(ADIN2111_FRAME_HEADER_PORT_MASK, port);

	frame_buf[0] = frame_header >> 8;
	frame_buf[1] = frame_header & 0xFF;

	/* Copy frame data */
	memcpy(frame_buf + ADIN2111_FRAME_HEADER_LEN, skb->data, skb->len);

	/* Write frame size */
	ret = adin2111_write_reg(priv, ADIN2111_TX_FSIZE,
				 skb->len + ADIN2111_FRAME_HEADER_LEN);
	if (ret)
		goto out;

	/* Write frame data - this calls spi_sync which can sleep */
	ret = adin2111_write_fifo(priv, ADIN2111_TX,
				  frame_buf, skb->len + ADIN2111_FRAME_HEADER_LEN);

out:
	kfree(frame_buf);
	return ret;
}

/* Currently unused - will be used when interrupt handling is implemented */
void __maybe_unused adin2111_rx_handler(struct adin2111_priv *priv)
{
	u32 rx_fsize, frame_size, port_mask;
	u8 *frame_buf;
	struct sk_buff *skb;
	struct net_device *netdev;
	struct adin2111_port *port;
	u16 frame_header;
	int ret, port_num;

	/* Read frame size */
	ret = adin2111_read_reg(priv, ADIN2111_RX_FSIZE, &rx_fsize);
	if (ret || !rx_fsize)
		return;

	frame_size = rx_fsize & 0x7FF;
	if (frame_size < ADIN2111_FRAME_HEADER_LEN ||
	    frame_size > ADIN2111_MAX_FRAME_SIZE + ADIN2111_FRAME_HEADER_LEN) {
		dev_err(&priv->spi->dev, "Invalid frame size: %u\n", frame_size);
		return;
	}

	frame_buf = kmalloc(frame_size, GFP_KERNEL);
	if (!frame_buf)
		return;

	/* Read frame data */
	ret = adin2111_read_fifo(priv, ADIN2111_RX, frame_buf, frame_size);
	if (ret) {
		dev_err(&priv->spi->dev, "Failed to read RX frame: %d\n", ret);
		goto out;
	}

	/* Parse frame header */
	frame_header = (frame_buf[0] << 8) | frame_buf[1];
	port_mask = FIELD_GET(ADIN2111_FRAME_HEADER_PORT_MASK, frame_header);

	/* Determine target port */
	if (priv->switch_mode) {
		port_num = (port_mask & BIT(1)) ? 1 : 0;
		if (port_num >= ADIN2111_PORTS || !priv->ports[port_num].netdev) {
			dev_err(&priv->spi->dev, "Invalid port in frame header: %d\n", port_num);
			goto out;
		}
		port = &priv->ports[port_num];
		netdev = port->netdev;
	} else {
		netdev = priv->netdev;
		port = netdev_priv(netdev);
	}

	/* Create SKB */
	skb = netdev_alloc_skb(netdev, frame_size - ADIN2111_FRAME_HEADER_LEN + NET_IP_ALIGN);
	if (!skb) {
		port->stats.rx_dropped++;
		goto out;
	}

	skb_reserve(skb, NET_IP_ALIGN);
	skb_put_data(skb, frame_buf + ADIN2111_FRAME_HEADER_LEN,
		     frame_size - ADIN2111_FRAME_HEADER_LEN);

	skb->protocol = eth_type_trans(skb, netdev);
	skb->ip_summed = CHECKSUM_NONE;

	/* Update statistics */
	port->stats.rx_packets++;
	port->stats.rx_bytes += skb->len;

	/* Deliver to network stack */
	netif_rx(skb);

out:
	kfree(frame_buf);
}

struct net_device *adin2111_create_netdev(struct adin2111_priv *priv, int port_num)
{
	struct net_device *netdev;
	struct adin2111_port *port;

	netdev = alloc_etherdev(sizeof(struct adin2111_port));
	if (!netdev)
		return NULL;

	SET_NETDEV_DEV(netdev, &priv->spi->dev);
	
	/* Use workqueue approach by default (recommended) */
	netdev->netdev_ops = &adin2111_netdev_ops;

	/* Setup port structure */
	port = netdev_priv(netdev);
	port->netdev = netdev;
	port->priv = priv;
	port->port_num = port_num;
	spin_lock_init(&port->stats_lock);

	/* Set device name */
	if (priv->switch_mode) {
		snprintf(netdev->name, IFNAMSIZ, "sw%dp%d", 0, port_num);
	} else {
		snprintf(netdev->name, IFNAMSIZ, "eth%d", 0);
	}

	/* Set MAC address */
	if (priv->switch_mode) {
		if (port_num == 0 && !is_zero_ether_addr(priv->pdata.mac_addr_p1)) {
			memcpy((u8 *)netdev->dev_addr, priv->pdata.mac_addr_p1, ETH_ALEN);
		} else if (port_num == 1 && !is_zero_ether_addr(priv->pdata.mac_addr_p2)) {
			memcpy((u8 *)netdev->dev_addr, priv->pdata.mac_addr_p2, ETH_ALEN);
		} else {
			eth_hw_addr_random(netdev);
		}
	} else {
		eth_hw_addr_random(netdev);
	}

	/* Configure device features */
	netdev->min_mtu = ETH_ZLEN;
	netdev->max_mtu = ADIN2111_MAX_FRAME_SIZE - ETH_HLEN;

	return netdev;
}

MODULE_DESCRIPTION("ADIN2111 Network Device Operations - Fixed for Atomic Context");
MODULE_AUTHOR("Analog Devices Inc.");
MODULE_LICENSE("GPL");

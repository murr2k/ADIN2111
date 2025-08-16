// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Dual Port Industrial Ethernet Switch/PHY
 * Network Device Operations
 *
 * Copyright 2024 Analog Devices Inc.
 */

#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/interrupt.h>
#include <linux/workqueue.h>
#include <linux/module.h>

#include "adin2111.h"
#include "adin2111_regs.h"

/* External function declarations */
extern int adin2111_read_fifo(struct adin2111_priv *priv, u32 reg, void *data, size_t len);
extern int adin2111_write_fifo(struct adin2111_priv *priv, u32 reg, const void *data, size_t len);

static netdev_tx_t adin2111_start_xmit(struct sk_buff *skb, struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;
	int ret;

	if (skb->len > ADIN2111_MAX_FRAME_SIZE) {
		dev_err(&priv->spi->dev, "Frame too large: %d bytes\n", skb->len);
		dev_kfree_skb_any(skb);
		port->stats.tx_dropped++;
		return NETDEV_TX_OK;
	}

	mutex_lock(&priv->tx_lock);

	/* Check if TX FIFO has space */
	u32 tx_space;
	ret = adin2111_read_reg(priv, ADIN2111_TX_SPACE, &tx_space);
	if (ret || tx_space < (skb->len + ADIN2111_FRAME_HEADER_LEN)) {
		mutex_unlock(&priv->tx_lock);
		netif_stop_queue(netdev);
		return NETDEV_TX_BUSY;
	}

	ret = adin2111_tx_frame(priv, skb, port->port_num);
	if (ret) {
		dev_err(&priv->spi->dev, "TX failed: %d\n", ret);
		port->stats.tx_errors++;
		dev_kfree_skb_any(skb);
	} else {
		port->stats.tx_packets++;
		port->stats.tx_bytes += skb->len;
		dev_consume_skb_any(skb);
	}

	mutex_unlock(&priv->tx_lock);
	return NETDEV_TX_OK;
}

static int adin2111_open(struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;
	int ret;

	dev_info(&priv->spi->dev, "Opening port %d\n", port->port_num);

	/* Start PHY */
	if (port->phydev) {
		ret = phy_start(port->phydev);
		if (ret) {
			dev_err(&priv->spi->dev, "Failed to start PHY: %d\n", ret);
			return ret;
		}
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
	return ret;
}

static int adin2111_stop(struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;

	dev_info(&priv->spi->dev, "Stopping port %d\n", port->port_num);

	netif_stop_queue(netdev);

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

	spin_lock(&port->state_lock);
	*stats = port->stats;
	spin_unlock(&port->state_lock);
}

static int adin2111_set_mac_address(struct net_device *netdev, void *addr)
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

		ret = adin2111_write_reg(priv, ADIN2111_ADDR_FILT_UPR, mac_upper);
		if (ret)
			return ret;

		ret = adin2111_write_reg(priv, ADIN2111_ADDR_FILT_LWR, mac_lower);
		if (ret)
			return ret;

		/* Enable MAC filtering */
		ret = adin2111_write_reg(priv, ADIN2111_ADDR_MSK_UPR, 0xFFFF);
		if (ret)
			return ret;

		ret = adin2111_write_reg(priv, ADIN2111_ADDR_MSK_LWR, 0xFFFFFFFF);
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

static const struct net_device_ops adin2111_netdev_ops = {
	.ndo_open		= adin2111_open,
	.ndo_stop		= adin2111_stop,
	.ndo_start_xmit		= adin2111_start_xmit,
	.ndo_get_stats64	= adin2111_get_stats64,
	.ndo_set_mac_address	= adin2111_set_mac_address,
	.ndo_change_mtu		= adin2111_change_mtu,
	.ndo_validate_addr	= eth_validate_addr,
};

int adin2111_tx_frame(struct adin2111_priv *priv, struct sk_buff *skb, int port)
{
	u8 *frame_buf;
	u16 frame_header;
	int ret;

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

	/* Write frame data */
	ret = adin2111_write_fifo(priv, ADIN2111_TX,
				  frame_buf, skb->len + ADIN2111_FRAME_HEADER_LEN);

out:
	kfree(frame_buf);
	return ret;
}

void adin2111_rx_handler(struct adin2111_priv *priv)
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
		if (port_num >= ADIN2111_MAX_PORTS || !priv->ports[port_num]) {
			dev_err(&priv->spi->dev, "Invalid port in frame header: %d\n", port_num);
			goto out;
		}
		port = priv->ports[port_num];
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
	netdev->netdev_ops = &adin2111_netdev_ops;

	/* Setup port structure */
	port = netdev_priv(netdev);
	port->netdev = netdev;
	port->priv = priv;
	port->port_num = port_num;
	spin_lock_init(&port->state_lock);

	/* Set device name */
	if (priv->switch_mode) {
		snprintf(netdev->name, IFNAMSIZ, "sw%dp%d", priv->spi->bus->num, port_num);
	} else {
		snprintf(netdev->name, IFNAMSIZ, "eth%d", priv->spi->bus->num);
	}

	/* Set MAC address */
	if (priv->switch_mode) {
		if (port_num == 0 && !is_zero_ether_addr(priv->pdata.mac_addr_p1)) {
			ether_addr_copy(netdev->dev_addr, priv->pdata.mac_addr_p1);
		} else if (port_num == 1 && !is_zero_ether_addr(priv->pdata.mac_addr_p2)) {
			ether_addr_copy(netdev->dev_addr, priv->pdata.mac_addr_p2);
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

MODULE_DESCRIPTION("ADIN2111 Network Device Operations");
MODULE_AUTHOR("Analog Devices Inc.");
MODULE_LICENSE("GPL");
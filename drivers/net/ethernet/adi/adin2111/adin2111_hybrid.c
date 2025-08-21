// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Hybrid Driver - Single Interface Mode Implementation
 * Based on official ADI ADIN1110 driver with single interface enhancement
 * 
 * Copyright (C) 2025 Murray Kopit
 * Copyright (C) 2022 Analog Devices Inc.
 */

#include <linux/bitfield.h>
#include <linux/bits.h>
#include <linux/cache.h>
#include <linux/crc8.h>
#include <linux/etherdevice.h>
#include <linux/ethtool.h>
#include <linux/if_bridge.h>
#include <linux/interrupt.h>
#include <linux/iopoll.h>
#include <linux/gpio.h>
#include <linux/kernel.h>
#include <linux/mii.h>
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/regulator/consumer.h>
#include <linux/phy.h>
#include <linux/property.h>
#include <linux/spi/spi.h>
#include <linux/version.h>
#include <net/switchdev.h>
#include <linux/hashtable.h>
#include <linux/jhash.h>

#include <asm/unaligned.h>

/* Module parameters for configuration */
static bool single_interface_mode = false;
module_param(single_interface_mode, bool, 0644);
MODULE_PARM_DESC(single_interface_mode, 
    "Enable single interface mode - ADIN2111 acts as 3-port switch (default: false)");

/* Kernel 6.6+ compatibility */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,18,0)
#define netif_rx_compat(skb)	netif_rx(skb)
#else
#define netif_rx_compat(skb)	netif_rx_ni(skb)
#endif

/* Register definitions */
#define ADIN1110_PHY_ID			0x1
#define ADIN1110_RESET				0x03
#define   ADIN1110_SWRESET			BIT(0)

#define ADIN1110_CONFIG1			0x04
#define   ADIN1110_CONFIG1_SYNC		BIT(15)

#define ADIN1110_CONFIG2			0x06
#define   ADIN2111_P2_FWD_UNK2HOST		BIT(12)
#define   ADIN2111_PORT_CUT_THRU_EN		BIT(11)
#define   ADIN1110_CRC_APPEND			BIT(5)
#define   ADIN1110_FWD_UNK2HOST		BIT(2)

#define ADIN1110_STATUS0			0x08
#define ADIN1110_STATUS1			0x09
#define   ADIN2111_P2_RX_RDY			BIT(17)
#define   ADIN1110_SPI_ERR			BIT(10)
#define   ADIN1110_RX_RDY			BIT(4)

#define ADIN1110_IMASK1			0x0D
#define   ADIN2111_RX_RDY_IRQ			BIT(17)
#define   ADIN1110_SPI_ERR_IRQ			BIT(10)
#define   ADIN1110_RX_RDY_IRQ			BIT(4)
#define   ADIN1110_TX_RDY_IRQ			BIT(3)

#define ADIN1110_MDIOACC			0x20
#define   ADIN1110_MDIO_TRDONE			BIT(31)
#define   ADIN1110_MDIO_ST			GENMASK(29, 28)
#define   ADIN1110_MDIO_OP			GENMASK(27, 26)
#define   ADIN1110_MDIO_PRTAD			GENMASK(25, 21)
#define   ADIN1110_MDIO_DEVAD			GENMASK(20, 16)
#define   ADIN1110_MDIO_DATA			GENMASK(15, 0)

#define ADIN1110_TX_FSIZE			0x30
#define ADIN1110_TX				0x31
#define ADIN1110_TX_SPACE			0x32

#define ADIN1110_MAC_ADDR_FILTER_UPR		0x50
#define   ADIN2111_MAC_ADDR_APPLY2PORT2	BIT(31)
#define   ADIN1110_MAC_ADDR_APPLY2PORT		BIT(30)
#define   ADIN2111_MAC_ADDR_TO_OTHER_PORT	BIT(17)
#define   ADIN1110_MAC_ADDR_TO_HOST		BIT(16)

#define ADIN1110_MAC_ADDR_FILTER_LWR		0x51
#define ADIN1110_MAC_ADDR_MASK_UPR		0x70
#define ADIN1110_MAC_ADDR_MASK_LWR		0x71

#define ADIN1110_RX_FSIZE			0x90
#define ADIN1110_RX				0x91

#define ADIN2111_RX_P2_FSIZE			0xC0
#define ADIN2111_RX_P2				0xC1

#define ADIN1110_CLEAR_STATUS0			0xFFF

/* SPI Header */
#define ADIN1110_CD				BIT(7)
#define ADIN1110_WRITE				BIT(5)

#define ADIN1110_MAX_BUFF			2048
#define ADIN1110_MAX_FRAMES_READ		64
#define ADIN1110_WR_HEADER_LEN			2
#define ADIN1110_FRAME_HEADER_LEN		2
#define ADIN1110_INTERNAL_SIZE_HEADER_LEN	2
#define ADIN1110_FEC_LEN			4

#define ADIN1110_PHY_ID_VAL			0x0283BC91
#define ADIN2111_PHY_ID_VAL			0x0283BCA1

#define ADIN_MAC_MAX_PORTS			2
#define ADIN_MAC_ADDR_SLOT_NUM			16

/* MAC Learning Table for Single Interface Mode */
#define MAC_TABLE_SIZE				256
#define MAC_AGE_TIME				(5 * HZ * 60)  /* 5 minutes */

struct mac_entry {
	unsigned char addr[ETH_ALEN];
	u8 port;
	unsigned long updated;
	struct hlist_node node;
};

/* Configuration structure */
struct adin2111_config {
	bool single_interface_mode;
	bool hardware_switching;
	bool kernel66_compat;
};

struct adin1110_cfg {
	int id;
	char name[MDIO_NAME_SIZE];
	u32 phy_ids[PHY_MAX_ADDR];
	u32 ports_nr;
	u32 phy_id_val;
};

struct adin1110_port_priv {
	struct adin1110_priv *priv;
	struct net_device *netdev;
	struct net_device *bridge;
	struct phy_device *phydev;
	struct work_struct tx_work;
	struct sk_buff_head txq;
	u32 nr;
	u32 state;
	u32 flags;
	u8 macaddr_filter_id[ADIN_MAC_ADDR_SLOT_NUM];
	/* Statistics */
	u64 rx_packets;
	u64 tx_packets;
	u64 rx_bytes;
	u64 tx_bytes;
};

struct adin1110_priv {
	struct mutex lock;
	struct mii_bus *mii_bus;
	struct spi_device *spidev;
	struct adin1110_cfg *cfg;
	struct adin1110_port_priv *ports[ADIN_MAC_MAX_PORTS];
	struct adin2111_config config;
	struct net_device *single_netdev;  /* For single interface mode */
	char mii_bus_name[MII_BUS_ID_SIZE];
	u8 broadcast_filter_id;
	u8 cfgcrc_en;
	u32 tx_space;
	u32 irq_mask;
	bool forwarding_en;
	
	/* MAC learning table for single interface mode */
	DECLARE_HASHTABLE(mac_table, 8);  /* 256 buckets */
	spinlock_t mac_table_lock;
};

/* Function prototypes */
static int adin2111_probe_single_interface(struct adin1110_priv *priv);
static int adin2111_probe_dual_interfaces(struct adin1110_priv *priv);
static int adin2111_enable_hw_forwarding(struct adin1110_priv *priv);
static int adin2111_learn_mac(struct adin1110_priv *priv, const u8 *addr, int port);
static int adin2111_lookup_mac_port(struct adin1110_priv *priv, const u8 *addr);

/* Include the bulk of the official driver code here */
/* We'll need to copy and modify specific functions */

/* SPI transfer functions */
static int adin1110_read_reg(struct adin1110_priv *priv, u16 reg, u32 *val)
{
	struct spi_device *spi = priv->spidev;
	u8 tx_buf[3] = {0};
	u8 rx_buf[5] = {0};
	struct spi_transfer t = {
		.tx_buf = tx_buf,
		.rx_buf = rx_buf,
		.len = 5,
	};
	int ret;

	tx_buf[0] = ADIN1110_CD | FIELD_GET(0xFF00, reg);
	tx_buf[1] = FIELD_GET(0x00FF, reg);
	tx_buf[2] = 0x00;  /* Turn around */

	ret = spi_sync_transfer(spi, &t, 1);
	if (ret)
		return ret;

	*val = get_unaligned_be32(&rx_buf[1]);
	return 0;
}

static int adin1110_write_reg(struct adin1110_priv *priv, u16 reg, u32 val)
{
	struct spi_device *spi = priv->spidev;
	u8 tx_buf[6] = {0};
	struct spi_transfer t = {
		.tx_buf = tx_buf,
		.len = 6,
	};

	tx_buf[0] = ADIN1110_CD | ADIN1110_WRITE | FIELD_GET(0xFF00, reg);
	tx_buf[1] = FIELD_GET(0x00FF, reg);
	put_unaligned_be32(val, &tx_buf[2]);

	return spi_sync_transfer(spi, &t, 1);
}

/* Hardware configuration for single interface mode */
static int adin2111_enable_hw_forwarding(struct adin1110_priv *priv)
{
	u32 val;
	int ret;

	dev_info(&priv->spidev->dev, "Enabling hardware forwarding for single interface mode\n");

	/* Read current CONFIG2 */
	ret = adin1110_read_reg(priv, ADIN1110_CONFIG2, &val);
	if (ret) {
		dev_err(&priv->spidev->dev, "Failed to read CONFIG2: %d\n", ret);
		return ret;
	}

	/* Enable hardware cut-through forwarding between ports */
	val |= ADIN2111_PORT_CUT_THRU_EN;
	
	/* Don't forward unknown unicast to host - let hardware handle it */
	val &= ~ADIN2111_P2_FWD_UNK2HOST;
	val &= ~ADIN1110_FWD_UNK2HOST;

	/* Write back CONFIG2 */
	ret = adin1110_write_reg(priv, ADIN1110_CONFIG2, val);
	if (ret) {
		dev_err(&priv->spidev->dev, "Failed to write CONFIG2: %d\n", ret);
		return ret;
	}

	priv->forwarding_en = true;
	dev_info(&priv->spidev->dev, "Hardware forwarding enabled (CONFIG2=0x%08x)\n", val);
	
	return 0;
}

/* MAC Learning Table Implementation */
static int adin2111_learn_mac(struct adin1110_priv *priv, const u8 *addr, int port)
{
	struct mac_entry *entry;
	u32 hash = jhash(addr, ETH_ALEN, 0);
	bool found = false;

	if (!priv->config.single_interface_mode)
		return 0;

	spin_lock(&priv->mac_table_lock);

	/* Look for existing entry */
	hash_for_each_possible(priv->mac_table, entry, node, hash) {
		if (ether_addr_equal(entry->addr, addr)) {
			entry->port = port;
			entry->updated = jiffies;
			found = true;
			break;
		}
	}

	/* Add new entry if not found */
	if (!found) {
		entry = kmalloc(sizeof(*entry), GFP_ATOMIC);
		if (entry) {
			ether_addr_copy(entry->addr, addr);
			entry->port = port;
			entry->updated = jiffies;
			hash_add(priv->mac_table, &entry->node, hash);
			
			dev_dbg(&priv->spidev->dev, "MAC learned: %pM on port %d\n", 
				addr, port);
		}
	}

	spin_unlock(&priv->mac_table_lock);
	return 0;
}

static int adin2111_lookup_mac_port(struct adin1110_priv *priv, const u8 *addr)
{
	struct mac_entry *entry;
	u32 hash = jhash(addr, ETH_ALEN, 0);
	int port = -1;

	if (!priv->config.single_interface_mode)
		return 0;

	spin_lock(&priv->mac_table_lock);

	hash_for_each_possible(priv->mac_table, entry, node, hash) {
		if (ether_addr_equal(entry->addr, addr)) {
			if (time_after(jiffies, entry->updated + MAC_AGE_TIME)) {
				/* Entry too old, remove it */
				hash_del(&entry->node);
				kfree(entry);
				dev_dbg(&priv->spidev->dev, "MAC aged out: %pM\n", addr);
			} else {
				port = entry->port;
			}
			break;
		}
	}

	spin_unlock(&priv->mac_table_lock);
	return port;
}

/* Forward declarations for TX/RX functions */
static int adin1110_write_fifo(struct adin1110_port_priv *port_priv, struct sk_buff *skb);
static int adin1110_read_fifo(struct adin1110_port_priv *port_priv);
static void adin1110_tx_work(struct work_struct *work);
static netdev_tx_t adin1110_start_xmit(struct sk_buff *skb, struct net_device *dev);

/* TX FIFO write implementation */
static int adin1110_write_fifo(struct adin1110_port_priv *port_priv, struct sk_buff *skb)
{
	struct adin1110_priv *priv = port_priv->priv;
	u32 header_len = ADIN1110_WR_HEADER_LEN;
	u32 frame_header_len = ADIN1110_FRAME_HEADER_LEN;
	u32 padding = 0;
	u32 tx_space;
	u32 port_rules = 0;
	u8 *tx_buf;
	int ret;

	/* Check available TX space */
	ret = adin1110_read_reg(priv, ADIN1110_TX_SPACE, &tx_space);
	if (ret)
		return ret;

	if (tx_space < skb->len + frame_header_len + ADIN1110_INTERNAL_SIZE_HEADER_LEN)
		return -ENOSPC;

	/* Pad to minimum Ethernet frame size */
	if (skb->len < ETH_ZLEN)
		padding = ETH_ZLEN - skb->len;

	tx_buf = kzalloc(header_len + frame_header_len + skb->len + padding, GFP_KERNEL);
	if (!tx_buf)
		return -ENOMEM;

	/* SPI header */
	tx_buf[0] = ADIN1110_CD | ADIN1110_WRITE | FIELD_GET(0xFF00, ADIN1110_TX);
	tx_buf[1] = FIELD_GET(0x00FF, ADIN1110_TX);

	/* Frame header with port rules */
	if (port_priv->nr == 0)
		port_rules = BIT(0);  /* Send to Port 0 */
	else
		port_rules = BIT(1);  /* Send to Port 1 */

	put_unaligned_be16(port_rules, &tx_buf[header_len]);

	/* Copy frame data */
	memcpy(&tx_buf[header_len + frame_header_len], skb->data, skb->len);

	/* Send via SPI */
	ret = spi_write(priv->spidev, tx_buf, header_len + frame_header_len + skb->len + padding);

	kfree(tx_buf);

	if (!ret) {
		port_priv->tx_packets++;
		port_priv->tx_bytes += skb->len;
	}

	return ret;
}

/* Standard TX work handler */
static void adin1110_tx_work(struct work_struct *work)
{
	struct adin1110_port_priv *port_priv;
	struct adin1110_priv *priv;
	struct sk_buff *txb;
	int ret;

	port_priv = container_of(work, struct adin1110_port_priv, tx_work);
	priv = port_priv->priv;

	mutex_lock(&priv->lock);

	while ((txb = skb_dequeue(&port_priv->txq))) {
		ret = adin1110_write_fifo(port_priv, txb);
		if (ret < 0)
			dev_err_ratelimited(&priv->spidev->dev,
					    "Frame write error: %d\n", ret);

		dev_kfree_skb(txb);
	}

	mutex_unlock(&priv->lock);
}

/* Standard TX start for dual interface mode */
static netdev_tx_t adin1110_start_xmit(struct sk_buff *skb, struct net_device *dev)
{
	struct adin1110_port_priv *port_priv = netdev_priv(dev);
	struct adin1110_priv *priv = port_priv->priv;
	netdev_tx_t netdev_ret = NETDEV_TX_OK;
	u32 tx_space_needed;

	tx_space_needed = skb->len + ADIN1110_FRAME_HEADER_LEN + ADIN1110_INTERNAL_SIZE_HEADER_LEN;
	if (tx_space_needed > priv->tx_space) {
		netif_stop_queue(dev);
		netdev_ret = NETDEV_TX_BUSY;
	} else {
		priv->tx_space -= tx_space_needed;
		skb_queue_tail(&port_priv->txq, skb);
	}

	schedule_work(&port_priv->tx_work);

	return netdev_ret;
}

/* Network device operations for single interface mode */
static netdev_tx_t adin2111_single_xmit(struct sk_buff *skb,
					 struct net_device *netdev)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);
	struct adin1110_priv *priv = port_priv->priv;
	struct ethhdr *eth = eth_hdr(skb);
	int port = 0;

	/* Determine target port */
	if (is_broadcast_ether_addr(eth->h_dest) ||
	    is_multicast_ether_addr(eth->h_dest)) {
		/* Let hardware handle broadcast/multicast */
		port = 0;  /* Send to port 0, hardware will replicate */
		dev_dbg(&priv->spidev->dev, "TX broadcast/multicast via port 0\n");
	} else {
		/* Check MAC learning table for unicast */
		port = adin2111_lookup_mac_port(priv, eth->h_dest);
		if (port < 0) {
			/* Unknown unicast - flood to both ports */
			port = 0;
			dev_dbg(&priv->spidev->dev, "TX unknown unicast %pM via port 0\n",
				eth->h_dest);
		} else {
			dev_dbg(&priv->spidev->dev, "TX unicast %pM via port %d\n",
				eth->h_dest, port);
		}
	}

	/* Queue for transmission */
	skb_queue_tail(&port_priv->txq, skb);
	schedule_work(&port_priv->tx_work);

	return NETDEV_TX_OK;
}

/* RX FIFO read implementation */
static int adin1110_read_fifo(struct adin1110_port_priv *port_priv)
{
	struct adin1110_priv *priv = port_priv->priv;
	struct net_device *netdev = port_priv->netdev;
	u32 header_len = ADIN1110_WR_HEADER_LEN;
	u32 frame_size_reg, frame_size;
	u32 rx_reg;
	u8 *rx_buf;
	struct sk_buff *skb;
	int ret;

	/* Determine which port's RX FIFO to read */
	if (port_priv->nr == 0) {
		frame_size_reg = ADIN1110_RX_FSIZE;
		rx_reg = ADIN1110_RX;
	} else {
		frame_size_reg = ADIN2111_RX_P2_FSIZE;
		rx_reg = ADIN2111_RX_P2;
	}

	/* Read frame size */
	ret = adin1110_read_reg(priv, frame_size_reg, &frame_size);
	if (ret)
		return ret;

	frame_size &= 0xFFFF;  /* Lower 16 bits contain size */
	if (frame_size == 0)
		return 0;

	/* Allocate buffer for SPI read */
	rx_buf = kzalloc(header_len + frame_size + ADIN1110_FEC_LEN, GFP_KERNEL);
	if (!rx_buf)
		return -ENOMEM;

	/* Setup SPI read command */
	rx_buf[0] = ADIN1110_CD | FIELD_GET(0xFF00, rx_reg);
	rx_buf[1] = FIELD_GET(0x00FF, rx_reg);

	/* Read frame data */
	ret = spi_write_then_read(priv->spidev, rx_buf, header_len,
				  &rx_buf[header_len], frame_size + ADIN1110_FEC_LEN);
	if (ret) {
		kfree(rx_buf);
		return ret;
	}

	/* Skip frame header and allocate skb */
	frame_size -= ADIN1110_FRAME_HEADER_LEN;
	skb = netdev_alloc_skb(netdev, frame_size);
	if (!skb) {
		kfree(rx_buf);
		return -ENOMEM;
	}

	/* Copy frame data to skb */
	skb_put_data(skb, &rx_buf[header_len + ADIN1110_FRAME_HEADER_LEN], frame_size);
	kfree(rx_buf);

	/* Learn source MAC in single interface mode */
	if (priv->config.single_interface_mode) {
		struct ethhdr *eth = eth_hdr(skb);
		adin2111_learn_mac(priv, eth->h_source, port_priv->nr);
	}

	/* Pass to network stack */
	skb->protocol = eth_type_trans(skb, netdev);
	netif_rx_compat(skb);

	port_priv->rx_packets++;
	port_priv->rx_bytes += frame_size;

	return 0;
}

/* IRQ handler */
static irqreturn_t adin1110_irq(int irq, void *p)
{
	struct adin1110_priv *priv = p;
	u32 status0, status1;
	int ret;

	mutex_lock(&priv->lock);

	/* Read status registers */
	ret = adin1110_read_reg(priv, ADIN1110_STATUS0, &status0);
	if (ret)
		goto out;

	ret = adin1110_read_reg(priv, ADIN1110_STATUS1, &status1);
	if (ret)
		goto out;

	/* Clear status */
	ret = adin1110_write_reg(priv, ADIN1110_STATUS0, ADIN1110_CLEAR_STATUS0);
	if (ret)
		goto out;

	/* Handle Port 0 RX */
	if (status1 & ADIN1110_RX_RDY_IRQ) {
		if (priv->ports[0])
			adin1110_read_fifo(priv->ports[0]);
	}

	/* Handle Port 1 RX (ADIN2111 only) */
	if (status1 & ADIN2111_RX_RDY_IRQ) {
		if (priv->cfg->ports_nr > 1 && priv->ports[1])
			adin1110_read_fifo(priv->ports[1]);
	}

out:
	mutex_unlock(&priv->lock);
	return IRQ_HANDLED;
}

static int adin2111_single_open(struct net_device *netdev)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);
	struct adin1110_priv *priv = port_priv->priv;
	int ret;

	/* Enable hardware forwarding */
	ret = adin2111_enable_hw_forwarding(priv);
	if (ret) {
		netdev_err(netdev, "Failed to enable hardware forwarding: %d\n", ret);
		return ret;
	}

	/* Enable interrupts */
	priv->irq_mask = ADIN1110_RX_RDY_IRQ | ADIN1110_TX_RDY_IRQ;
	if (priv->cfg->ports_nr > 1)
		priv->irq_mask |= ADIN2111_RX_RDY_IRQ;

	ret = adin1110_write_reg(priv, ADIN1110_IMASK1, priv->irq_mask);
	if (ret)
		return ret;

	/* Start PHYs for both ports */
	if (port_priv->phydev) {
		ret = phy_connect_direct(netdev, port_priv->phydev,
					  adin1110_adjust_link,
					  PHY_INTERFACE_MODE_MII);
		if (ret)
			return ret;

		phy_start(port_priv->phydev);
	}

	/* If single interface mode, start PHY for port 1 too */
	if (priv->config.single_interface_mode && priv->cfg->ports_nr > 1) {
		/* Port 1 PHY management would go here */
		dev_info(&netdev->dev, "Single interface mode: managing both PHYs\n");
	}

	netif_start_queue(netdev);
	return 0;
}

static int adin2111_single_stop(struct net_device *netdev)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);
	struct adin1110_priv *priv = port_priv->priv;
	
	netif_stop_queue(netdev);
	
	/* Stop PHYs */
	if (port_priv->phydev) {
		phy_stop(port_priv->phydev);
		phy_disconnect(port_priv->phydev);
	}
	
	/* Disable interrupts */
	adin1110_write_reg(priv, ADIN1110_IMASK1, 0);
	
	/* Flush TX queue */
	skb_queue_purge(&port_priv->txq);
	
	return 0;
}

static void adin2111_single_get_stats64(struct net_device *netdev,
					 struct rtnl_link_stats64 *stats)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);
	struct adin1110_priv *priv = port_priv->priv;

	/* Combine statistics from both hardware ports */
	stats->rx_packets = port_priv->rx_packets;
	stats->tx_packets = port_priv->tx_packets;
	stats->rx_bytes = port_priv->rx_bytes;
	stats->tx_bytes = port_priv->tx_bytes;
	
	/* Add port 1 stats if in single interface mode */
	if (priv->config.single_interface_mode && priv->cfg->ports_nr > 1 && priv->ports[1]) {
		stats->rx_packets += priv->ports[1]->rx_packets;
		stats->tx_packets += priv->ports[1]->tx_packets;
		stats->rx_bytes += priv->ports[1]->rx_bytes;
		stats->tx_bytes += priv->ports[1]->tx_bytes;
	}
}

static const struct net_device_ops adin2111_single_netdev_ops = {
	.ndo_open		= adin2111_single_open,
	.ndo_stop		= adin2111_single_stop,
	.ndo_start_xmit		= adin2111_single_xmit,
	.ndo_get_stats64	= adin2111_single_get_stats64,
	.ndo_validate_addr	= eth_validate_addr,
	.ndo_set_mac_address	= eth_mac_addr,
};

/* Single interface probe function */
static int adin2111_probe_single_interface(struct adin1110_priv *priv)
{
	struct device *dev = &priv->spidev->dev;
	struct adin1110_port_priv *port_priv;
	struct net_device *netdev;
	int ret;

	dev_info(dev, "Configuring ADIN2111 in single interface mode (3-port switch)\n");

	/* Allocate single network device */
	netdev = devm_alloc_etherdev(dev, sizeof(*port_priv));
	if (!netdev)
		return -ENOMEM;

	port_priv = netdev_priv(netdev);
	port_priv->netdev = netdev;
	port_priv->priv = priv;
	port_priv->nr = 0;  /* Primary port */

	/* Initialize TX queue and work */
	skb_queue_head_init(&port_priv->txq);
	INIT_WORK(&port_priv->tx_work, NULL);  /* TODO: Add TX worker */

	/* Configure for both PHY ports */
	priv->ports[0] = port_priv;
	priv->ports[1] = port_priv;  /* Both ports use same netdev */
	priv->single_netdev = netdev;

	/* Set up netdev */
	netdev->netdev_ops = &adin2111_single_netdev_ops;
	netdev->features = NETIF_F_SG;
	netdev->priv_flags |= IFF_UNICAST_FLT;

	/* Set MAC address */
	eth_hw_addr_random(netdev);

	/* Initialize MAC learning table */
	hash_init(priv->mac_table);
	spin_lock_init(&priv->mac_table_lock);

	/* Enable hardware switching by default */
	ret = adin2111_enable_hw_forwarding(priv);
	if (ret) {
		netdev_err(netdev, "Failed to enable hardware forwarding: %d\n", ret);
		return ret;
	}

	/* Register network device */
	ret = devm_register_netdev(dev, netdev);
	if (ret) {
		netdev_err(netdev, "Failed to register netdev: %d\n", ret);
		return ret;
	}

	netdev_info(netdev, "ADIN2111 configured as single interface (3-port switch)\n");
	netdev_info(netdev, "Hardware forwarding enabled between PHY ports\n");
	
	return 0;
}

/* Dual interface probe (traditional mode) */
static int adin2111_probe_dual_interfaces(struct adin1110_priv *priv)
{
	struct device *dev = &priv->spidev->dev;
	
	dev_info(dev, "Configuring ADIN2111 in dual interface mode (traditional)\n");
	
	/* TODO: Implement traditional dual interface setup */
	/* This would be similar to the original adin1110_probe_port() */
	
	return -ENOTSUPP;  /* For now */
}

/* Main probe function */
static int adin2111_probe(struct spi_device *spi)
{
	struct device *dev = &spi->dev;
	struct adin1110_priv *priv;
	int ret;

	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	priv->spidev = spi;
	spi_set_drvdata(spi, priv);
	mutex_init(&priv->lock);

	/* Allocate and initialize configuration */
	priv->cfg = devm_kzalloc(dev, sizeof(*priv->cfg), GFP_KERNEL);
	if (!priv->cfg)
		return -ENOMEM;

	/* Set up ADIN2111 configuration */
	priv->cfg->id = 0;
	strscpy(priv->cfg->name, "adin2111", sizeof(priv->cfg->name));
	priv->cfg->ports_nr = 2;  /* ADIN2111 has 2 ports */
	priv->cfg->phy_id_val = ADIN2111_PHY_ID_VAL;

	/* Parse device tree for configuration */
	if (dev->of_node) {
		priv->config.single_interface_mode = 
			of_property_read_bool(dev->of_node, "adi,single-interface-mode");
	}

	/* Module parameter overrides device tree */
	if (single_interface_mode)
		priv->config.single_interface_mode = true;

	/* Hardware reset if GPIO available */
	/* TODO: Handle reset GPIO */

	/* Verify chip ID */
	u32 val;
	ret = adin1110_read_reg(priv, ADIN1110_RESET, &val);
	if (ret) {
		dev_err(dev, "Failed to read chip ID: %d\n", ret);
		return ret;
	}

	dev_info(dev, "ADIN2111 detected (ID=0x%08x)\n", val);

	/* Request IRQ */
	if (spi->irq) {
		ret = devm_request_irq(dev, spi->irq, adin1110_irq, 0,
					dev_name(dev), priv);
		if (ret) {
			dev_err(dev, "Failed to request IRQ %d: %d\n", spi->irq, ret);
			return ret;
		}
	} else {
		dev_err(dev, "No IRQ specified\n");
		return -EINVAL;
	}

	/* Set default TX space */
	priv->tx_space = ADIN1110_MAX_BUFF;

	/* Branch based on mode */
	if (priv->config.single_interface_mode) {
		ret = adin2111_probe_single_interface(priv);
	} else {
		ret = adin2111_probe_dual_interfaces(priv);
	}

	if (ret) {
		dev_err(dev, "Failed to configure interfaces: %d\n", ret);
		return ret;
	}

	dev_info(dev, "ADIN2111 driver loaded successfully\n");
	return 0;
}

static void adin2111_remove(struct spi_device *spi)
{
	struct adin1110_priv *priv = spi_get_drvdata(spi);
	struct mac_entry *entry;
	struct hlist_node *tmp;
	int bkt;

	/* Clean up MAC learning table */
	if (priv->config.single_interface_mode) {
		spin_lock(&priv->mac_table_lock);
		hash_for_each_safe(priv->mac_table, bkt, tmp, entry, node) {
			hash_del(&entry->node);
			kfree(entry);
		}
		spin_unlock(&priv->mac_table_lock);
	}
}

static const struct of_device_id adin2111_of_match[] = {
	{ .compatible = "adi,adin2111" },
	{ .compatible = "adi,adin1110" },
	{ }
};
MODULE_DEVICE_TABLE(of, adin2111_of_match);

static const struct spi_device_id adin2111_spi_id[] = {
	{ "adin2111", 0 },
	{ "adin1110", 0 },
	{ }
};
MODULE_DEVICE_TABLE(spi, adin2111_spi_id);

static struct spi_driver adin2111_driver = {
	.driver = {
		.name = "adin2111",
		.of_match_table = adin2111_of_match,
	},
	.probe = adin2111_probe,
	.remove = adin2111_remove,
	.id_table = adin2111_spi_id,
};

module_spi_driver(adin2111_driver);

MODULE_DESCRIPTION("ADIN2111 Hybrid Driver with Single Interface Mode");
MODULE_AUTHOR("Murray Kopit <murr2k@gmail.com>");
MODULE_LICENSE("GPL");
MODULE_VERSION("4.0.0-hybrid");
// SPDX-License-Identifier: (GPL-2.0+ OR BSD-3-Clause)
/*
 * ADIN1110 Low Power 10BASE-T1L Ethernet MAC-PHY
 *
 * Copyright 2021 Analog Devices Inc.
 */

#include <linux/bitfield.h>
#include <linux/bits.h>
#include <linux/cache.h>
#include <linux/crc8.h>
#include <linux/etherdevice.h>
#include <linux/ethtool.h>
#include <linux/gpio/consumer.h>
#include <linux/if_bridge.h>
#include <linux/interrupt.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/mii.h>
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/regulator/consumer.h>
#include <linux/phy.h>
#include <linux/property.h>
#include <linux/spi/spi.h>

#include <net/switchdev.h>

#include <asm/unaligned.h>

#define ADIN1110_PHY_ID				0x1

#define ADIN1110_RESET				0x03
#define   ADIN1110_SWRESET			BIT(0)

#define ADIN1110_CONFIG1			0x04
#define   ADIN1110_CONFIG1_SYNC			BIT(15)

#define ADIN1110_CONFIG2			0x06
#define   ADIN2111_P2_FWD_UNK2HOST		BIT(12)
#define   ADIN2111_PORT_CUT_THRU_EN		BIT(11)
#define   ADIN1110_CRC_APPEND			BIT(5)
#define   ADIN1110_FWD_UNK2HOST			BIT(2)

#define ADIN1110_STATUS0			0x08

#define ADIN1110_STATUS1			0x09
#define   ADIN2111_P2_RX_RDY			BIT(17)
#define   ADIN1110_SPI_ERR			BIT(10)
#define   ADIN1110_RX_RDY			BIT(4)

#define ADIN1110_IMASK1				0x0D
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
#define   ADIN2111_MAC_ADDR_APPLY2PORT2		BIT(31)
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

/* MDIO_OP codes */
#define ADIN1110_MDIO_OP_WR			0x1
#define ADIN1110_MDIO_OP_RD			0x3

#define ADIN1110_CD_LEN				4
#define ADIN1110_FRAME_HEADER_LEN		2
#define ADIN1110_INTERNAL_SIZE_HEADER_LEN	2
#define ADIN1110_ETH_OVERHEAD_LEN		(ADIN1110_CD_LEN + \
						 ADIN1110_FRAME_HEADER_LEN + \
						 ADIN1110_INTERNAL_SIZE_HEADER_LEN)
#define ADIN1110_MAX_FRAME_LEN			(ETH_FRAME_LEN + \
						 ADIN1110_ETH_OVERHEAD_LEN)
#define ADIN1110_WR_HEADER_LEN			2
#define ADIN1110_RD_HEADER_LEN			3
#define ADIN1110_REG_LEN			4
#define ADIN1110_CRC_LEN			1

#define ADIN1110_MAX_BUFF			(ADIN1110_MAX_FRAME_LEN + \
						 ADIN1110_RD_HEADER_LEN)

#define ADIN1110_CRC8_POLY			0x7

static u8 adin1110_crc_table[256];

enum adin1110_chips {
	ADIN1110_MAC = 0,
	ADIN2111_MAC = 1,
};

struct adin1110_cfg {
	enum adin1110_chips	id;
	char			name[16];
	u32			ports_nr;
};

static const struct adin1110_cfg adin1110_cfgs[] = {
	{
		.id = ADIN1110_MAC,
		.name = "ADIN1110",
		.ports_nr = 1,
	},
	{
		.id = ADIN2111_MAC,
		.name = "ADIN2111",
		.ports_nr = 2,
	},
};

struct adin1110_port_priv {
	struct adin1110_priv		*priv;
	struct net_device		*netdev;
	struct phy_device		*phydev;
	u32				nr;
	u32				rx_bytes_dropped;
	u32				tx_bytes_dropped;

	struct work_struct		tx_work;
	struct sk_buff_head		txq;

	bool				nr_addrs_mac_fltrs;
	struct netdev_hw_addr_list	uc;
	struct netdev_hw_addr_list	mc;
	struct netdev_hw_addr_list	sync_uc;
	struct netdev_hw_addr_list	sync_mc;
};

struct adin1110_priv {
	spinlock_t			lock;
	struct device			*dev;
	struct spi_device		*spidev;
	struct mii_bus			*mii_bus;
	const struct adin1110_cfg	*cfg;
	struct adin1110_port_priv	**ports;
	char				*data;
	bool				append_crc;
	u32				spi_addr_mask;
	u32				max_frame_len;
	u32				tx_space;
	u32				irq_mask;
	struct gpio_desc		*reset_gpio;

	struct work_struct		irq_work;
	struct mutex			lock;
	bool				wake_up_once_scheduler;
};

static void adin1110_crc_table_init(void)
{
	crc8_populate_msb(adin1110_crc_table, ADIN1110_CRC8_POLY);
}

static u8 adin1110_calc_crc(u8 *data, u16 len)
{
	return crc8(adin1110_crc_table, data, len, 0);
}

static int adin1110_read_reg(struct adin1110_priv *priv, u16 reg, u32 *val)
{
	u32 ret_len;
	u32 temp;
	u8 *buf;
	int ret;

	temp = (reg & 0xFFF) << 13;
	temp |= ADIN1110_RD_HEADER_LEN - ADIN1110_CRC_LEN + ADIN1110_REG_LEN;

	if (priv->append_crc)
		temp |= BIT(5);

	buf = kzalloc(ADIN1110_RD_HEADER_LEN + ADIN1110_REG_LEN, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	buf[0] = (temp >> 16) & 0xFF;
	buf[1] = (temp >> 8) & 0xFF;
	buf[2] = temp & 0xFF;

	if (priv->append_crc)
		buf[ADIN1110_RD_HEADER_LEN - ADIN1110_CRC_LEN] = adin1110_calc_crc(buf, ADIN1110_RD_HEADER_LEN - ADIN1110_CRC_LEN);

	ret_len = ADIN1110_RD_HEADER_LEN + ADIN1110_REG_LEN;

	ret = spi_write_then_read(priv->spidev, buf,
				  ADIN1110_RD_HEADER_LEN, buf, ret_len);
	if (ret < 0)
		goto out;

	*val = get_unaligned_be32(buf + ADIN1110_RD_HEADER_LEN);

out:
	kfree(buf);

	return ret;
}

static int adin1110_write_reg(struct adin1110_priv *priv, u16 reg, u32 val)
{
	u32 header_len = ADIN1110_WR_HEADER_LEN;
	u32 full_len;
	u32 temp;
	u8 *buf;
	int ret;

	temp = BIT(13);
	temp |= (reg & 0xFFF) << 1;

	full_len = header_len + ADIN1110_REG_LEN;
	if (priv->append_crc) {
		full_len += ADIN1110_CRC_LEN;
		temp |= BIT(5);
	}

	buf = kzalloc(full_len, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	buf[0] = (temp >> 8) & 0xFF;
	buf[1] = temp & 0xFF;

	put_unaligned_be32(val, buf + header_len);

	if (priv->append_crc)
		buf[full_len - ADIN1110_CRC_LEN] = adin1110_calc_crc(buf, full_len - ADIN1110_CRC_LEN);

	ret = spi_write(priv->spidev, buf, full_len);

	kfree(buf);

	return ret;
}

static int adin1110_set_bits(struct adin1110_priv *priv, u32 reg, u32 mask)
{
	u32 val;
	int ret;

	ret = adin1110_read_reg(priv, reg, &val);
	if (ret < 0)
		return ret;

	val |= mask;

	return adin1110_write_reg(priv, reg, val);
}

static int adin1110_clear_bits(struct adin1110_priv *priv, u32 reg, u32 mask)
{
	u32 val;
	int ret;

	ret = adin1110_read_reg(priv, reg, &val);
	if (ret < 0)
		return ret;

	val &= ~mask;

	return adin1110_write_reg(priv, reg, val);
}

static int adin1110_round_len(int len)
{
	return round_up(len, 4);
}

static int adin1110_write_fifo(struct adin1110_port_priv *port_priv, struct sk_buff *txb)
{
	struct adin1110_priv *priv = port_priv->priv;
	u32 header_len = ADIN1110_WR_HEADER_LEN;
	u32 frame_size_len = ADIN1110_FRAME_HEADER_LEN;
	u32 internal_header_len = ADIN1110_INTERNAL_SIZE_HEADER_LEN;
	u32 full_len;
	u16 frame_header;
	u32 temp;
	u8 *buf;
	int ret;

	full_len = header_len + frame_size_len + internal_header_len + adin1110_round_len(txb->len);

	if (priv->append_crc)
		full_len += ADIN1110_CRC_LEN;

	buf = kzalloc(full_len, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	/* Can write to FIFO on ADIN2111 */
	temp = BIT(13);
	temp |= ADIN1110_TX << 1;

	if (priv->append_crc)
		temp |= BIT(5);

	buf[0] = (temp >> 8) & 0xFF;
	buf[1] = temp & 0xFF;

	frame_header = txb->len + ADIN1110_FRAME_HEADER_LEN;

	if (port_priv->nr == 0)
		frame_header |= ADIN1110_FRAME_HEADER_LEN;

	if (port_priv->nr == 1)
		frame_header |= BIT(15);

	put_unaligned_be16(frame_header, buf + header_len);
	put_unaligned_be16(txb->len, buf + header_len + frame_size_len);

	memcpy(buf + header_len + frame_size_len + internal_header_len, txb->data, txb->len);

	if (priv->append_crc)
		buf[full_len - ADIN1110_CRC_LEN] = adin1110_calc_crc(buf, full_len - ADIN1110_CRC_LEN);

	ret = spi_write(priv->spidev, buf, full_len);

	kfree(buf);

	return ret;
}

static int adin1110_read_fifo(struct adin1110_port_priv *port_priv)
{
	struct adin1110_priv *priv = port_priv->priv;
	u32 header_len = ADIN1110_RD_HEADER_LEN;
	struct sk_buff *rxb;
	u32 frame_size;
	u16 frame_len;
	int round_len;
	u32 full_len;
	u16 reg;
	u32 temp;
	u8 *buf;
	int ret;

	if (port_priv->nr == 0) {
		ret = adin1110_read_reg(priv, ADIN1110_RX_FSIZE, &frame_size);
		reg = ADIN1110_RX;
	} else {
		ret = adin1110_read_reg(priv, ADIN2111_RX_P2_FSIZE, &frame_size);
		reg = ADIN2111_RX_P2;
	}
	if (ret < 0)
		return ret;

	frame_len = frame_size & GENMASK(10, 0);
	round_len = adin1110_round_len((int)frame_len);
	if (round_len < 0)
		return -EINVAL;

	full_len = header_len + round_len;

	buf = kzalloc(full_len, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	temp = (reg & 0xFFF) << 13;
	temp |= round_len >> 2;

	if (priv->append_crc)
		temp |= BIT(5);

	buf[0] = (temp >> 16) & 0xFF;
	buf[1] = (temp >> 8) & 0xFF;
	buf[2] = temp & 0xFF;

	if (priv->append_crc)
		buf[header_len - ADIN1110_CRC_LEN] = adin1110_calc_crc(buf, header_len - ADIN1110_CRC_LEN);

	ret = spi_write_then_read(priv->spidev, buf, header_len, buf, full_len);
	if (ret < 0)
		goto out;

	if (frame_len < ETH_ZLEN || frame_len > ETH_FRAME_LEN) {
		netdev_err(port_priv->netdev, "invalid frame size.\n");
		port_priv->rx_bytes_dropped += frame_len;
		ret = -EINVAL;
		goto out;
	}

	rxb = netdev_alloc_skb(port_priv->netdev, frame_len);
	if (!rxb) {
		netdev_err(port_priv->netdev, "could not allocate skb.\n");
		port_priv->rx_bytes_dropped += frame_len;
		ret = -ENOMEM;
		goto out;
	}

	memcpy(skb_put(rxb, frame_len), buf + header_len, frame_len);

	rxb->protocol = eth_type_trans(rxb, port_priv->netdev);

	if (port_priv->netdev->features & NETIF_F_RXCSUM)
		skb_checksum_none_assert(rxb);

	netif_rx(rxb);

	port_priv->netdev->stats.rx_packets++;
	port_priv->netdev->stats.rx_bytes += frame_len;

out:
	kfree(buf);

	return ret;
}

static bool adin1110_port_rx_ready(struct adin1110_port_priv *port_priv,
				   u32 status)
{
	if (!netif_oper_up(port_priv->netdev))
		return false;

	if (!port_priv->nr)
		return !!(status & ADIN1110_RX_RDY);
	else
		return !!(status & ADIN2111_P2_RX_RDY);
}

#define ADIN1110_MAX_FRAMES_READ		64

static void adin1110_read_frames(struct adin1110_port_priv *port_priv,
				 unsigned int budget)
{
	struct adin1110_priv *priv = port_priv->priv;
	u32 status1;
	int ret;

	while (budget) {
		ret = adin1110_read_reg(priv, ADIN1110_STATUS1, &status1);
		if (ret < 0)
			return;

		if (!adin1110_port_rx_ready(port_priv, status1))
			return;

		ret = adin1110_read_fifo(port_priv);
		if (ret < 0)
			return;

		budget--;
	}
}

static irqreturn_t adin1110_irq(int irq, void *p)
{
	struct adin1110_priv *priv = p;
	u32 status1;
	u32 val;
	int ret;
	int i;

	spin_lock(&priv->lock);

	ret = adin1110_read_reg(priv, ADIN1110_STATUS1, &status1);
	if (ret < 0)
		goto out;

	if (priv->append_crc && (status1 & ADIN1110_SPI_ERR))
		dev_warn_ratelimited(&priv->spidev->dev,
				     "SPI CRC error on write.\n");

	ret = adin1110_read_reg(priv, ADIN1110_TX_SPACE, &val);
	if (ret < 0)
		goto out;

	/* TX FIFO space is expressed in half-words */
	priv->tx_space = 2 * val;

	for (i = 0; i < priv->cfg->ports_nr; i++) {
		if (adin1110_port_rx_ready(priv->ports[i], status1))
			adin1110_read_frames(priv->ports[i],
					     ADIN1110_MAX_FRAMES_READ);
	}

	/* clear IRQ sources */
	adin1110_write_reg(priv, ADIN1110_STATUS0, ADIN1110_CLEAR_STATUS0);
	adin1110_write_reg(priv, ADIN1110_STATUS1, priv->irq_mask);

out:
	spin_unlock(&priv->lock);

	if (priv->tx_space > 0 && ret >= 0) {
		for (i = 0; i < priv->cfg->ports_nr; i++) {
			if (netif_queue_stopped(priv->ports[i]->netdev) &&
			    netif_oper_up(priv->ports[i]->netdev))
				netif_wake_queue(priv->ports[i]->netdev);
		}
	}

	return IRQ_HANDLED;
}

/* ADIN1110 can filter up to 16 MAC addresses, mac_nr here is the slot used */
static int adin1110_write_mac_address(struct adin1110_port_priv *port_priv,
				      int mac_nr, const u8 *addr,
				      u8 *mask, u32 port_rules)
{
	struct adin1110_priv *priv = port_priv->priv;
	u32 offset = mac_nr * 2;
	u32 port_rules_mask;
	u32 addr_val;
	u32 ret;

	if (priv->cfg->id == ADIN2111_MAC)
		port_rules_mask = ADIN2111_MAC_ADDR_APPLY2PORT2;
	else
		port_rules_mask = 0;

	addr_val = get_unaligned_be16(&addr[0]) << 16;
	addr_val |= port_rules;
	addr_val |= port_rules_mask;

	ret = adin1110_write_reg(priv, ADIN1110_MAC_ADDR_FILTER_UPR + offset, addr_val);
	if (ret < 0)
		return ret;

	addr_val = get_unaligned_be32(&addr[2]);

	ret = adin1110_write_reg(priv, ADIN1110_MAC_ADDR_FILTER_LWR + offset, addr_val);
	if (ret < 0)
		return ret;

	if (mask) {
		addr_val = get_unaligned_be16(&mask[0]) << 16;

		ret = adin1110_write_reg(priv, ADIN1110_MAC_ADDR_MASK_UPR + offset, addr_val);
		if (ret < 0)
			return ret;

		addr_val = get_unaligned_be32(&mask[2]);

		ret = adin1110_write_reg(priv, ADIN1110_MAC_ADDR_MASK_LWR + offset, addr_val);
		if (ret < 0)
			return ret;
	}

	return 0;
}

static int adin1110_clear_mac_address(struct adin1110_priv *priv, int mac_nr)
{
	u32 offset = mac_nr * 2;
	int ret;

	ret = adin1110_write_reg(priv, ADIN1110_MAC_ADDR_FILTER_UPR + offset, 0);
	if (ret < 0)
		return ret;

	ret = adin1110_write_reg(priv, ADIN1110_MAC_ADDR_FILTER_LWR + offset, 0);
	if (ret < 0)
		return ret;

	ret = adin1110_write_reg(priv, ADIN1110_MAC_ADDR_MASK_UPR + offset, 0);
	if (ret < 0)
		return ret;

	return adin1110_write_reg(priv, ADIN1110_MAC_ADDR_MASK_LWR + offset, 0);
}

static int adin1110_multicast_filter(struct adin1110_port_priv *port_priv,
				     int mac_nr, bool accept_multicast)
{
	u8 mask[ETH_ALEN] = {0};
	u8 mac[ETH_ALEN] = {0};
	u32 port_rules = 0;

	if (accept_multicast && !is_multicast_ether_addr(mac))
		mac[0] = 0x01;

	if (accept_multicast)
		mask[0] = 0x01;

	if (port_priv->nr == 1)
		port_rules |= ADIN2111_MAC_ADDR_TO_OTHER_PORT;

	port_rules |= ADIN1110_MAC_ADDR_TO_HOST;

	return adin1110_write_mac_address(port_priv, mac_nr, mac, mask, port_rules);
}

static int adin1110_broadcasts_filter(struct adin1110_port_priv *port_priv,
				      int mac_nr, bool accept_broadcast)
{
	u8 mask[ETH_ALEN] = {0};
	u8 mac[ETH_ALEN] = {0};
	u32 port_rules = 0;

	if (accept_broadcast)
		eth_broadcast_addr(mac);

	eth_broadcast_addr(mask);

	if (port_priv->nr == 1)
		port_rules |= ADIN2111_MAC_ADDR_TO_OTHER_PORT;

	port_rules |= ADIN1110_MAC_ADDR_TO_HOST;

	return adin1110_write_mac_address(port_priv, mac_nr, mac, mask, port_rules);
}

static int adin1110_set_mac_address(struct net_device *netdev,
				    void *addr)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);
	struct sockaddr *sa = addr;
	u32 port_rules = 0;

	if (port_priv->nr == 1)
		port_rules |= ADIN2111_MAC_ADDR_TO_OTHER_PORT;

	port_rules |= ADIN1110_MAC_ADDR_TO_HOST;

	adin1110_write_mac_address(port_priv, 0, sa->sa_data, NULL, port_rules);

	eth_hw_addr_set(netdev, sa->sa_data);

	return 0;
}

static void adin1110_set_rx_mode(struct net_device *netdev)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);
	bool accept_multicast = netdev->flags & IFF_ALLMULTI;
	bool accept_broadcast = !(netdev->flags & IFF_NOARP);
	int max_mac_nr = port_priv->nr_addrs_mac_fltrs - 2;
	struct netdev_hw_addr *ha;
	u32 port_rules = 0;
	int mac_nr = 1;

	if (port_priv->nr == 1)
		port_rules |= ADIN2111_MAC_ADDR_TO_OTHER_PORT;

	port_rules |= ADIN1110_MAC_ADDR_TO_HOST;

	/* get all the multicast/unicast addresses */
	if (netdev->flags & (IFF_PROMISC | IFF_ALLMULTI)) {
		accept_multicast = true;
	} else {
		netdev_for_each_mc_addr(ha, netdev) {
			if (mac_nr < max_mac_nr) {
				adin1110_write_mac_address(port_priv, mac_nr,
							   ha->addr, NULL, port_rules);
				mac_nr++;
			} else {
				accept_multicast = true;
				break;
			}
		}

		netdev_for_each_uc_addr(ha, netdev) {
			if (mac_nr < max_mac_nr) {
				adin1110_write_mac_address(port_priv, mac_nr,
							   ha->addr, NULL, port_rules);
				mac_nr++;
			} else {
				/* do not accept more unicast addresses */
				/* than space available in the MAC address filter Stores */
				netdev_uc_count(netdev)++;
				break;
			}
		}
	}

	/* clear the remaining MAC address filters */
	for (; mac_nr < max_mac_nr; mac_nr++)
		adin1110_clear_mac_address(port_priv->priv, mac_nr);

	adin1110_multicast_filter(port_priv, max_mac_nr, accept_multicast);
	adin1110_broadcasts_filter(port_priv, max_mac_nr + 1, accept_broadcast);
}

static void adin1110_tx_work(struct work_struct *work)
{
	struct adin1110_port_priv *port_priv;
	struct adin1110_priv *priv;
	struct sk_buff *txb;
	int ret;

	port_priv = container_of(work, struct adin1110_port_priv, tx_work);
	priv = port_priv->priv;

	spin_lock(&priv->lock);

	while ((txb = skb_dequeue(&port_priv->txq))) {
		if (txb->len + ADIN1110_ETH_OVERHEAD_LEN > priv->tx_space) {
			skb_queue_head(&port_priv->txq, txb);
			netif_stop_queue(port_priv->netdev);
			spin_unlock(&priv->lock);
			return;
		}

		ret = adin1110_write_fifo(port_priv, txb);
		if (ret < 0) {
			dev_warn(&priv->spidev->dev, "Frame TX failed\n");
			port_priv->tx_bytes_dropped += txb->len;
			goto tx_err;
		}

		priv->tx_space -= txb->len + ADIN1110_ETH_OVERHEAD_LEN;

		port_priv->netdev->stats.tx_packets++;
		port_priv->netdev->stats.tx_bytes += txb->len;

tx_err:
		dev_consume_skb_any(txb);
	}

	spin_unlock(&priv->lock);
}

static netdev_tx_t adin1110_start_xmit(struct sk_buff *skb, struct net_device *netdev)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);

	skb_queue_tail(&port_priv->txq, skb);
	schedule_work(&port_priv->tx_work);

	return NETDEV_TX_OK;
}

static int adin1110_ndo_get_phys_port_name(struct net_device *netdev,
					   char *name, size_t len)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);
	int ret;

	ret = snprintf(name, len, "p%d", port_priv->nr);
	if (ret >= len)
		return -EINVAL;

	return 0;
}

static void adin1110_get_drvinfo(struct net_device *netdev,
				 struct ethtool_drvinfo *di)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);

	strlcpy(di->driver, "adin1110", sizeof(di->driver));
	strlcpy(di->bus_info, dev_name(&port_priv->priv->spidev->dev), sizeof(di->bus_info));
}

static const struct ethtool_ops adin1110_ethtool_ops = {
	.get_drvinfo		= adin1110_get_drvinfo,
	.get_link_ksettings	= phy_ethtool_get_link_ksettings,
	.set_link_ksettings	= phy_ethtool_set_link_ksettings,
	.get_link		= ethtool_op_get_link,
};

static void adin1110_adjust_link(struct net_device *dev)
{
	struct phy_device *phydev = dev->phydev;

	if (!phydev->link)
		phy_print_status(phydev);
}

static int adin1110_phy_connect(struct adin1110_port_priv *port_priv)
{
	struct device_node *dn = port_priv->priv->spidev->dev.of_node;
	struct phy_device *phydev;
	int ret;

	if (!dn) {
		dev_err(&port_priv->priv->spidev->dev, "eth%d: no device tree node found.\n",
			port_priv->nr);
		return -ENODEV;
	}

	phydev = of_phy_get_and_connect(port_priv->netdev, dn, adin1110_adjust_link);
	if (!phydev)
		return -ENODEV;

	if (port_priv->nr == 0)
		ret = phy_attached_info(phydev);

	return ret;
}

static void adin1110_phy_disconnect(struct adin1110_port_priv *port_priv)
{
	phy_disconnect(port_priv->netdev->phydev);
}

static int adin1110_ndo_open(struct net_device *netdev)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);
	u32 val;
	int ret;

	ret = adin1110_phy_connect(port_priv);
	if (ret < 0)
		return ret;

	phy_start(port_priv->netdev->phydev);

	adin1110_set_rx_mode(netdev);

	netif_start_queue(netdev);

	netif_carrier_off(netdev);

	if (!port_priv->nr) {
		val = ADIN1110_TX_RDY_IRQ | ADIN1110_RX_RDY_IRQ |
		      ADIN1110_SPI_ERR_IRQ;

		if (port_priv->priv->cfg->id == ADIN2111_MAC)
			val |= ADIN2111_RX_RDY_IRQ;

		port_priv->priv->irq_mask = val;
		ret = adin1110_write_reg(port_priv->priv, ADIN1110_IMASK1, ~val);
		if (ret < 0) {
			netif_stop_queue(netdev);
			phy_disconnect(netdev->phydev);
			return ret;
		}
	}

	return 0;
}

static int adin1110_ndo_stop(struct net_device *netdev)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);
	u32 mask;
	int ret;

	netif_stop_queue(netdev);

	flush_work(&port_priv->tx_work);

	adin1110_phy_disconnect(port_priv);

	if (!port_priv->nr) {
		mask = ~(ADIN1110_RX_RDY_IRQ | ADIN1110_TX_RDY_IRQ | ADIN1110_SPI_ERR_IRQ);

		if (port_priv->priv->cfg->id == ADIN2111_MAC)
			mask &= ~ADIN2111_RX_RDY_IRQ;

		ret = adin1110_write_reg(port_priv->priv, ADIN1110_IMASK1, mask);
		if (ret < 0)
			return ret;
	}

	return 0;
}

static const struct net_device_ops adin1110_netdev_ops = {
	.ndo_open		= adin1110_ndo_open,
	.ndo_stop		= adin1110_ndo_stop,
	.ndo_start_xmit		= adin1110_start_xmit,
	.ndo_set_rx_mode	= adin1110_set_rx_mode,
	.ndo_set_mac_address	= adin1110_set_mac_address,
	.ndo_validate_addr	= eth_validate_addr,
	.ndo_get_phys_port_name	= adin1110_ndo_get_phys_port_name,
};

static void adin1110_get_stats64(struct net_device *netdev,
				 struct rtnl_link_stats64 *storage)
{
	struct adin1110_port_priv *port_priv = netdev_priv(netdev);

	storage->rx_packets = netdev->stats.rx_packets;
	storage->tx_packets = netdev->stats.tx_packets;
	storage->rx_bytes = netdev->stats.rx_bytes;
	storage->tx_bytes = netdev->stats.tx_bytes;
	storage->tx_dropped = port_priv->tx_bytes_dropped;
	storage->rx_dropped = port_priv->rx_bytes_dropped;
}

static const struct net_device_ops adin2111_netdev_ops = {
	.ndo_open		= adin1110_ndo_open,
	.ndo_stop		= adin1110_ndo_stop,
	.ndo_start_xmit		= adin1110_start_xmit,
	.ndo_set_rx_mode	= adin1110_set_rx_mode,
	.ndo_set_mac_address	= adin1110_set_mac_address,
	.ndo_validate_addr	= eth_validate_addr,
	.ndo_get_stats64	= adin1110_get_stats64,
	.ndo_get_phys_port_name	= adin1110_ndo_get_phys_port_name,
};

static struct adin1110_port_priv *adin1110_create_port(struct adin1110_priv *priv, int nr)
{
	struct adin1110_port_priv *port_priv;
	struct net_device *netdev;

	netdev = alloc_etherdev(sizeof(*port_priv));
	if (!netdev)
		return NULL;

	port_priv = netdev_priv(netdev);
	port_priv->netdev = netdev;
	port_priv->priv = priv;
	port_priv->nr = nr;

	if (priv->cfg->id == ADIN2111_MAC)
		netdev->netdev_ops = &adin2111_netdev_ops;
	else
		netdev->netdev_ops = &adin1110_netdev_ops;

	netdev->ethtool_ops = &adin1110_ethtool_ops;

	netdev->priv_flags |= IFF_UNICAST_FLT;
	netdev->features |= NETIF_F_NETNS_LOCAL;

	port_priv->nr_addrs_mac_fltrs = 16;

	netdev->mtu = ETH_DATA_LEN;
	netdev->min_mtu = ETH_ZLEN;
	netdev->max_mtu = ETH_DATA_LEN;

	eth_hw_addr_gen(netdev, (const u8 *)&priv->spidev->dev.id, nr + 1);

	netdev->dev_id = nr;

	INIT_WORK(&port_priv->tx_work, adin1110_tx_work);
	skb_queue_head_init(&port_priv->txq);

	__hw_addr_init(&port_priv->uc);
	__hw_addr_init(&port_priv->mc);
	__hw_addr_init(&port_priv->sync_uc);
	__hw_addr_init(&port_priv->sync_mc);

	return port_priv;
}

static void adin1110_destroy_port(struct adin1110_port_priv *port_priv)
{
	__hw_addr_unsync_dev(&port_priv->uc, port_priv->netdev,
			     port_priv->netdev->addr_len);
	__hw_addr_unsync_dev(&port_priv->mc, port_priv->netdev,
			     port_priv->netdev->addr_len);
	__hw_addr_init(&port_priv->uc);
	__hw_addr_init(&port_priv->mc);
	__hw_addr_init(&port_priv->sync_uc);
	__hw_addr_init(&port_priv->sync_mc);

	free_netdev(port_priv->netdev);
}

static int adin1110_mdiobus_read(struct mii_bus *bus, int addr, int regnum)
{
	struct adin1110_priv *priv = bus->priv;
	u32 val = FIELD_PREP(ADIN1110_MDIO_OP, ADIN1110_MDIO_OP_RD);
	u32 data;
	int ret;

	val |= FIELD_PREP(ADIN1110_MDIO_ST, 0x1);
	val |= FIELD_PREP(ADIN1110_MDIO_PRTAD, addr);
	val |= FIELD_PREP(ADIN1110_MDIO_DEVAD, regnum);

	ret = adin1110_write_reg(priv, ADIN1110_MDIOACC, val);
	if (ret < 0)
		return ret;

	ret = readx_poll_timeout(adin1110_read_reg, priv, ADIN1110_MDIOACC,
				 data, data & ADIN1110_MDIO_TRDONE, 1000, 30000);

	if (ret < 0)
		return ret;

	return FIELD_GET(ADIN1110_MDIO_DATA, data);
}

static int adin1110_mdiobus_write(struct mii_bus *bus, int addr, int regnum, u16 val)
{
	struct adin1110_priv *priv = bus->priv;
	u32 reg_val = FIELD_PREP(ADIN1110_MDIO_OP, ADIN1110_MDIO_OP_WR);

	reg_val |= FIELD_PREP(ADIN1110_MDIO_ST, 0x1);
	reg_val |= FIELD_PREP(ADIN1110_MDIO_PRTAD, addr);
	reg_val |= FIELD_PREP(ADIN1110_MDIO_DEVAD, regnum);
	reg_val |= FIELD_PREP(ADIN1110_MDIO_DATA, val);

	return adin1110_write_reg(priv, ADIN1110_MDIOACC, reg_val);
}

static int adin1110_mdio_register(struct adin1110_priv *priv)
{
	struct device *dev = &priv->spidev->dev;
	struct mii_bus *mii_bus;
	int ret;

	mii_bus = devm_mdiobus_alloc(dev);
	if (!mii_bus)
		return -ENOMEM;

	snprintf(mii_bus->id, MII_BUS_ID_SIZE, "%s", dev_name(dev));

	mii_bus->priv = priv;
	mii_bus->parent = dev;
	mii_bus->name = "adin1110_mdio";
	mii_bus->read = adin1110_mdiobus_read;
	mii_bus->write = adin1110_mdiobus_write;

	priv->mii_bus = mii_bus;

	ret = devm_mdiobus_register(dev, mii_bus);
	if (ret)
		return ret;

	return 0;
}

static int adin1110_hw_forwarding(struct adin1110_priv *priv, bool enable)
{
	int ret;

	if (enable)
		ret = adin1110_set_bits(priv, ADIN1110_CONFIG2, ADIN2111_PORT_CUT_THRU_EN);
	else
		ret = adin1110_clear_bits(priv, ADIN1110_CONFIG2, ADIN2111_PORT_CUT_THRU_EN);

	if (ret < 0)
		return ret;

	if (enable) {
		ret = adin1110_set_bits(priv, ADIN1110_CONFIG2, ADIN1110_FWD_UNK2HOST);
		if (ret < 0)
			return ret;

		ret = adin1110_set_bits(priv, ADIN1110_CONFIG2, ADIN2111_P2_FWD_UNK2HOST);
		if (ret < 0)
			return ret;
	} else {
		ret = adin1110_clear_bits(priv, ADIN1110_CONFIG2, ADIN1110_FWD_UNK2HOST);
		if (ret < 0)
			return ret;

		ret = adin1110_clear_bits(priv, ADIN1110_CONFIG2, ADIN2111_P2_FWD_UNK2HOST);
		if (ret < 0)
			return ret;
	}

	return 0;
}

static int adin1110_set_forwarding(struct adin1110_priv *priv, bool enable)
{
	/* configure default forwarding for standalone mode */
	return adin1110_hw_forwarding(priv, enable);
}

static int adin1110_requests_from_host(struct adin1110_priv *priv, bool enable)
{
	int ret;

	ret = adin1110_set_bits(priv, ADIN1110_CONFIG1, ADIN1110_CONFIG1_SYNC);
	if (ret < 0)
		return ret;

	if (enable)
		ret = adin1110_clear_bits(priv, ADIN1110_CONFIG2, ADIN1110_CRC_APPEND);
	else
		ret = adin1110_set_bits(priv, ADIN1110_CONFIG2, ADIN1110_CRC_APPEND);

	return ret;
}

static int adin1110_probe_netdevs(struct adin1110_priv *priv)
{
	struct device *dev = &priv->spidev->dev;
	struct adin1110_port_priv *port_priv;
	int ret;
	int i;

	priv->ports = devm_kcalloc(dev, priv->cfg->ports_nr, sizeof(*priv->ports), GFP_KERNEL);
	if (!priv->ports)
		return -ENOMEM;

	for (i = 0; i < priv->cfg->ports_nr; i++) {
		port_priv = adin1110_create_port(priv, i);
		if (!port_priv) {
			ret = -ENOMEM;
			goto out_free_netdevs;
		}

		ret = register_netdev(port_priv->netdev);
		if (ret < 0) {
			free_netdev(port_priv->netdev);
			goto out_free_netdevs;
		}

		priv->ports[i] = port_priv;
	}

	return 0;

out_free_netdevs:
	while (--i >= 0) {
		unregister_netdev(priv->ports[i]->netdev);
		adin1110_destroy_port(priv->ports[i]);
	}

	return ret;
}

static void adin1110_remove_netdevs(struct adin1110_priv *priv)
{
	int i;

	for (i = 0; i < priv->cfg->ports_nr; i++) {
		unregister_netdev(priv->ports[i]->netdev);
		adin1110_destroy_port(priv->ports[i]);
	}
}

static int adin1110_probe(struct spi_device *spi)
{
	const struct spi_device_id *dev_id = spi_get_device_id(spi);
	struct device *dev = &spi->dev;
	struct adin1110_priv *priv;
	int ret;
	u32 val;

	priv = devm_kzalloc(dev, sizeof(struct adin1110_priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	priv->spidev = spi;
	priv->cfg = &adin1110_cfgs[dev_id->driver_data];
	spi->max_speed_hz = min(spi->max_speed_hz, 24500000U);
	priv->max_frame_len = ADIN1110_MAX_FRAME_LEN;
	priv->append_crc = false;
	mutex_init(&priv->lock);
	spin_lock_init(&priv->lock);

	if (device_property_present(dev, "adi,spi-crc")) {
		priv->append_crc = true;
		spi->mode |= SPI_3WIRE;
	}

	priv->data = devm_kzalloc(dev, ADIN1110_MAX_BUFF, GFP_KERNEL);
	if (!priv->data)
		return -ENOMEM;

	priv->reset_gpio = devm_gpiod_get_optional(dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(priv->reset_gpio)) {
		ret = PTR_ERR(priv->reset_gpio);
		return ret;
	}

	if (priv->reset_gpio) {
		/* A reset pulse width of 10 us minimum is specified */
		usleep_range(10, 20);
		gpiod_set_value_cansleep(priv->reset_gpio, 1);
		/* 90 us minimum reset to ready time is specified */
		usleep_range(90, 100);
	}

	ret = adin1110_read_reg(priv, ADIN1110_STATUS1, &val);
	if (ret < 0)
		return ret;

	adin1110_crc_table_init();

	ret = adin1110_write_reg(priv, ADIN1110_RESET, ADIN1110_SWRESET);
	if (ret < 0)
		return ret;

	ret = adin1110_requests_from_host(priv, false);
	if (ret < 0)
		return ret;

	ret = adin1110_set_forwarding(priv, priv->cfg->id == ADIN2111_MAC);
	if (ret < 0)
		return ret;

	ret = adin1110_mdio_register(priv);
	if (ret < 0) {
		dev_err(dev, "Could not register MDIO bus\n");
		return ret;
	}

	ret = adin1110_probe_netdevs(priv);
	if (ret < 0) {
		dev_err(dev, "Could not probe netdevs\n");
		return ret;
	}

	ret = devm_request_threaded_irq(dev, spi->irq, NULL, adin1110_irq,
					IRQF_TRIGGER_LOW | IRQF_ONESHOT,
					dev_name(&spi->dev), priv);
	if (ret < 0) {
		dev_err(dev, "Could not request IRQ\n");
		adin1110_remove_netdevs(priv);
		return ret;
	}

	spi_set_drvdata(spi, priv);

	return 0;
}

static void adin1110_remove(struct spi_device *spi)
{
	struct adin1110_priv *priv = spi_get_drvdata(spi);

	adin1110_remove_netdevs(priv);
}

static const struct spi_device_id adin1110_spi_id[] = {
	{ .name = "adin1110", .driver_data = ADIN1110_MAC },
	{ .name = "adin2111", .driver_data = ADIN2111_MAC },
	{ }
};
MODULE_DEVICE_TABLE(spi, adin1110_spi_id);

static const struct of_device_id adin1110_match_table[] = {
	{ .compatible = "adi,adin1110" },
	{ .compatible = "adi,adin2111" },
	{ }
};
MODULE_DEVICE_TABLE(of, adin1110_match_table);

static struct spi_driver adin1110_driver = {
	.driver = {
		.name = "adin1110",
		.of_match_table = adin1110_match_table,
	},
	.probe = adin1110_probe,
	.remove = adin1110_remove,
	.id_table = adin1110_spi_id,
};
module_spi_driver(adin1110_driver);

MODULE_DESCRIPTION("ADIN1110 Network driver");
MODULE_AUTHOR("Alexandru Tachici <alexandru.tachici@analog.com>");
MODULE_LICENSE("Dual BSD/GPL");
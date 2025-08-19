/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * ADIN2111 Driver Internal Definitions - FIXED for atomic context bug
 *
 * Author: Murray Kopit
 * Date: August 19, 2025
 * Copyright (C) 2025 Analog Devices Inc.
 */

#ifndef __ADIN2111_H__
#define __ADIN2111_H__

#include <linux/spi/spi.h>
#include <linux/netdevice.h>
#include <linux/phy.h>
#include <linux/regmap.h>
#include <linux/workqueue.h>
#include <linux/mutex.h>
#include <linux/spinlock.h>
#include <linux/interrupt.h>
#include <linux/skbuff.h>

#define ADIN2111_PORTS		2
#define ADIN2111_PORT_1		0
#define ADIN2111_PORT_2		1

#define ADIN2111_DRV_NAME	"adin2111"
#define ADIN2111_DRV_VERSION	"1.0.1"  /* Bumped for atomic fix */

/* Driver operation modes */
enum adin2111_mode {
	ADIN2111_MODE_SWITCH,	/* Hardware switch mode */
	ADIN2111_MODE_DUAL,	/* Dual MAC mode */
};

/* Port state - FIXED with TX queue support */
struct adin2111_port {
	struct net_device *netdev;
	struct adin2111_priv *priv;
	struct phy_device *phydev;
	struct napi_struct napi;
	u8 port_num;
	bool enabled;

	/* Statistics */
	struct rtnl_link_stats64 stats;
	spinlock_t stats_lock;

	/* MAC address */
	u8 mac_addr[ETH_ALEN];

	/* TX queue for deferred transmission (atomic context fix) */
	struct sk_buff_head tx_queue;	/* Queue of packets to transmit */
	struct tasklet_struct tx_tasklet;  /* Tasklet for TX processing */
	struct work_struct tx_work;	/* Alternative: workqueue for TX */
	bool use_tasklet;		/* Flag to choose tasklet vs workqueue */
};

/* Platform data */
struct adin2111_pdata {
	bool switch_mode;
	bool cut_through;
	bool crc_append;
	bool tx_fcs_validation;
	bool port1_enabled;
	bool port2_enabled;
	u8 mac_addr_p1[ETH_ALEN];
	u8 mac_addr_p2[ETH_ALEN];
};

/* Main driver private data */
struct adin2111_priv {
	struct spi_device *spi;
	struct regmap *regmap;
	struct mii_bus *mii_bus;
	struct device *dev;

	/* Platform data */
	struct adin2111_pdata pdata;

	/* Operation mode */
	enum adin2111_mode mode;
	bool cut_through_en;
	bool switch_mode;

	/* Ports */
	struct adin2111_port ports[ADIN2111_PORTS];
	int num_ports;

	/* Single netdev for switch mode */
	struct net_device *netdev;

	/* Work and interrupts */
	struct work_struct irq_work;
	struct workqueue_struct *wq;
	struct workqueue_struct *tx_wq;  /* Dedicated TX workqueue */
	int irq;
	u32 irq_mask;

	/* Synchronization */
	struct mutex lock;		/* Protects register access - can sleep */
	spinlock_t tx_lock;		/* REMOVED - no longer used in atomic context */
	spinlock_t rx_lock;		/* Protects RX FIFO */

	/* Configuration */
	bool crc_append;
	bool tx_fcs_validation;
	u32 tx_space;
	u32 rx_size;

	/* GPIO */
	struct gpio_desc *reset_gpio;

	/* PHY addresses */
	u8 phy_addr[ADIN2111_PORTS];

	/* Atomic context fix configuration */
	bool use_deferred_tx;		/* Enable deferred TX processing */
};

/* Function prototypes */

/* Main driver */
int adin2111_soft_reset(struct adin2111_priv *priv);
struct regmap *adin2111_init_regmap(struct spi_device *spi);
struct net_device *adin2111_create_netdev(struct adin2111_priv *priv, int port_num);

/* SPI interface */
int adin2111_spi_init(struct adin2111_priv *priv);
int adin2111_read_reg(struct adin2111_priv *priv, u32 reg, u32 *val);
int adin2111_write_reg(struct adin2111_priv *priv, u32 reg, u32 val);
int adin2111_set_bits(struct adin2111_priv *priv, u32 reg, u32 mask);
int adin2111_clear_bits(struct adin2111_priv *priv, u32 reg, u32 mask);
int adin2111_read_fifo(struct adin2111_priv *priv, u32 reg, u8 *data, size_t len);
int adin2111_write_fifo(struct adin2111_priv *priv, u32 reg, const u8 *data, size_t len);
struct regmap *adin2111_init_regmap(struct spi_device *spi);
int adin2111_modify_reg(struct adin2111_priv *priv, u32 reg, u32 mask, u32 val);

/* MDIO interface */
int adin2111_mdio_init(struct adin2111_priv *priv);
void adin2111_mdio_uninit(struct adin2111_priv *priv);
int adin2111_mdio_read(struct mii_bus *bus, int phy_id, int reg);
int adin2111_mdio_write(struct mii_bus *bus, int phy_id, int reg, u16 val);

/* Network device operations */
int adin2111_netdev_init(struct adin2111_priv *priv);
void adin2111_netdev_uninit(struct adin2111_priv *priv);
int adin2111_netdev_open(struct net_device *ndev);
int adin2111_netdev_stop(struct net_device *ndev);
netdev_tx_t adin2111_netdev_xmit(struct sk_buff *skb, struct net_device *ndev);
void adin2111_netdev_get_stats64(struct net_device *ndev, struct rtnl_link_stats64 *stats);
int adin2111_netdev_change_mtu(struct net_device *ndev, int new_mtu);

/* Switch operations */
int adin2111_switch_init(struct adin2111_priv *priv);
int adin2111_switch_enable(struct adin2111_priv *priv);
int adin2111_switch_disable(struct adin2111_priv *priv);
int adin2111_switch_config_port(struct adin2111_priv *priv, int port, bool enable);
int adin2111_switch_set_mac_filter(struct adin2111_priv *priv, int port, const u8 *addr);

/* Interrupt handling */
irqreturn_t adin2111_irq_handler(int irq, void *data);
void adin2111_irq_work(struct work_struct *work);
int adin2111_enable_interrupts(struct adin2111_priv *priv);
int adin2111_disable_interrupts(struct adin2111_priv *priv);

/* RX/TX processing */
int adin2111_rx_packet(struct adin2111_priv *priv, int port);
int adin2111_tx_packet(struct adin2111_priv *priv, struct sk_buff *skb, int port);
int adin2111_poll(struct napi_struct *napi, int budget);

/* PHY management */
int adin2111_phy_init(struct adin2111_priv *priv, int port);
void adin2111_phy_uninit(struct adin2111_priv *priv, int port);
void adin2111_adjust_link(struct net_device *ndev);

/* Hardware initialization */
int adin2111_hw_init(struct adin2111_priv *priv);
int adin2111_hw_reset(struct adin2111_priv *priv);
int adin2111_check_id(struct adin2111_priv *priv);

/* Network device functions */
int adin2111_tx_frame(struct adin2111_priv *priv, struct sk_buff *skb, int port);
void adin2111_rx_handler(struct adin2111_priv *priv);
struct net_device *adin2111_create_netdev(struct adin2111_priv *priv, int port_num);

/* Utilities */
void adin2111_get_mac_address(struct adin2111_priv *priv, int port, u8 *addr);
int adin2111_set_mac_address_hw(struct adin2111_priv *priv, int port, const u8 *addr);
int adin2111_update_statistics(struct adin2111_priv *priv, int port);

#ifdef CONFIG_ADIN2111_DEBUG
#define adin2111_dbg(priv, fmt, ...) \
	dev_dbg((priv)->dev, fmt, ##__VA_ARGS__)
#else
#define adin2111_dbg(priv, fmt, ...) do {} while (0)
#endif

#define adin2111_err(priv, fmt, ...) \
	dev_err((priv)->dev, fmt, ##__VA_ARGS__)

#define adin2111_warn(priv, fmt, ...) \
	dev_warn((priv)->dev, fmt, ##__VA_ARGS__)

#define adin2111_info(priv, fmt, ...) \
	dev_info((priv)->dev, fmt, ##__VA_ARGS__)

#endif /* __ADIN2111_H__ */

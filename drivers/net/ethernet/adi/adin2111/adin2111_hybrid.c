// SPDX-License-Identifier: GPL-2.0
/*
 * ADIN2111 Hybrid Driver - Single Interface Mode
 * 
 * This driver implements single interface mode for the ADIN2111 2-port
 * 10BASE-T1L Ethernet switch, presenting both PHY ports as a single
 * network interface with hardware-based forwarding.
 *
 * Copyright (C) 2025 Murray Kopit
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/spi/spi.h>
#include <linux/of.h>
#include <linux/crc32.h>
#include <linux/timer.h>
#include <linux/version.h>

#define DRV_NAME "adin2111_hybrid"
#define DRV_VERSION "4.0.0"

/* Module parameters */
static bool single_interface_mode = false;
module_param(single_interface_mode, bool, 0644);
MODULE_PARM_DESC(single_interface_mode, "Enable single interface mode (3-port switch)");

static bool hardware_forwarding = true;
module_param(hardware_forwarding, bool, 0644);
MODULE_PARM_DESC(hardware_forwarding, "Enable hardware forwarding between PHY ports");

/* ADIN2111 Register Definitions */
#define ADIN2111_DEVID          0x00
#define ADIN2111_PHYID          0x01
#define ADIN2111_STATUS0        0x08
#define ADIN2111_STATUS1        0x09
#define ADIN2111_CONFIG0        0x10
#define ADIN2111_CONFIG2        0x11
#define ADIN2111_TX_FSIZE       0x30
#define ADIN2111_TX             0x31
#define ADIN2111_TX_SPACE       0x32
#define ADIN2111_FIFO_CLR       0x36
#define ADIN2111_RX_FSIZE       0x90
#define ADIN2111_RX             0x91

/* Port Control Registers */
#define ADIN2111_PORT_CUT_THRU_EN      0x3000
#define ADIN2111_MAC_ADDR_FILT_UPR(p)  (0x50 + (p) * 0x10)
#define ADIN2111_MAC_ADDR_FILT_LWR(p)  (0x51 + (p) * 0x10)

/* Status bits */
#define ADIN2111_STATUS_LINK_UP_P1     BIT(0)
#define ADIN2111_STATUS_LINK_UP_P2     BIT(1)

/* Configuration bits */
#define ADIN2111_CONFIG0_SYNC           BIT(15)
#define ADIN2111_CONFIG2_P1_FWD_EN      BIT(1)
#define ADIN2111_CONFIG2_P2_FWD_EN      BIT(2)

/* MAC Learning Table */
#define MAC_TABLE_SIZE 256
#define MAC_ENTRY_TIMEOUT (5 * 60 * HZ)  /* 5 minutes */

struct mac_entry {
    u8 mac[ETH_ALEN];
    u8 port;
    unsigned long timestamp;
    struct hlist_node node;
};

struct adin2111_priv {
    struct net_device *netdev;
    struct spi_device *spi;
    spinlock_t lock;
    
    /* Single interface mode */
    bool single_interface_mode;
    bool hardware_forwarding_enabled;
    
    /* MAC learning table */
    DECLARE_HASHTABLE(mac_table, 8);
    struct timer_list aging_timer;
    
    /* Statistics */
    struct {
        u64 tx_packets;
        u64 rx_packets;
        u64 tx_bytes;
        u64 rx_bytes;
        u64 tx_errors;
        u64 rx_errors;
    } stats[2];  /* Per-port statistics */
};

/* SPI register access functions */
static int adin2111_read_reg(struct adin2111_priv *priv, u16 reg, u32 *val)
{
    struct spi_message msg;
    struct spi_transfer xfer = {0};
    u8 tx_buf[4] = {0};
    u8 rx_buf[4] = {0};
    int ret;
    
    /* Format: CMD(1) | ADDR(15) */
    tx_buf[0] = 0x80 | ((reg >> 8) & 0x7F);
    tx_buf[1] = reg & 0xFF;
    
    xfer.tx_buf = tx_buf;
    xfer.rx_buf = rx_buf;
    xfer.len = 4;
    
    spi_message_init(&msg);
    spi_message_add_tail(&xfer, &msg);
    
    ret = spi_sync(priv->spi, &msg);
    if (ret)
        return ret;
    
    *val = (rx_buf[2] << 8) | rx_buf[3];
    return 0;
}

static int adin2111_write_reg(struct adin2111_priv *priv, u16 reg, u32 val)
{
    struct spi_message msg;
    struct spi_transfer xfer = {0};
    u8 tx_buf[4];
    int ret;
    
    /* Format: CMD(1) | ADDR(15) | DATA(16) */
    tx_buf[0] = 0x00 | ((reg >> 8) & 0x7F);
    tx_buf[1] = reg & 0xFF;
    tx_buf[2] = (val >> 8) & 0xFF;
    tx_buf[3] = val & 0xFF;
    
    xfer.tx_buf = tx_buf;
    xfer.len = 4;
    
    spi_message_init(&msg);
    spi_message_add_tail(&xfer, &msg);
    
    ret = spi_sync(priv->spi, &msg);
    return ret;
}

/* MAC Learning Table Functions */
static u32 mac_hash(const u8 *mac)
{
    return jhash(mac, ETH_ALEN, 0) & (MAC_TABLE_SIZE - 1);
}

static struct mac_entry *mac_table_lookup(struct adin2111_priv *priv, const u8 *mac)
{
    struct mac_entry *entry;
    u32 hash = mac_hash(mac);
    
    hash_for_each_possible(priv->mac_table, entry, node, hash) {
        if (ether_addr_equal(entry->mac, mac))
            return entry;
    }
    return NULL;
}

static void mac_table_learn(struct adin2111_priv *priv, const u8 *mac, u8 port)
{
    struct mac_entry *entry;
    u32 hash;
    
    spin_lock(&priv->lock);
    
    entry = mac_table_lookup(priv, mac);
    if (entry) {
        /* Update existing entry */
        entry->port = port;
        entry->timestamp = jiffies;
    } else {
        /* Add new entry */
        entry = kzalloc(sizeof(*entry), GFP_ATOMIC);
        if (entry) {
            ether_addr_copy(entry->mac, mac);
            entry->port = port;
            entry->timestamp = jiffies;
            hash = mac_hash(mac);
            hash_add(priv->mac_table, &entry->node, hash);
            
            netdev_dbg(priv->netdev, "Learned MAC %pM on port %d\n", mac, port);
        }
    }
    
    spin_unlock(&priv->lock);
}

static void mac_table_aging(struct timer_list *t)
{
    struct adin2111_priv *priv = from_timer(priv, t, aging_timer);
    struct mac_entry *entry;
    struct hlist_node *tmp;
    int bkt;
    
    spin_lock(&priv->lock);
    
    hash_for_each_safe(priv->mac_table, bkt, tmp, entry, node) {
        if (time_after(jiffies, entry->timestamp + MAC_ENTRY_TIMEOUT)) {
            hash_del(&entry->node);
            netdev_dbg(priv->netdev, "Aged out MAC %pM\n", entry->mac);
            kfree(entry);
        }
    }
    
    spin_unlock(&priv->lock);
    
    /* Restart timer */
    mod_timer(&priv->aging_timer, jiffies + HZ * 60);
}

/* Network device operations */
static int adin2111_open(struct net_device *netdev)
{
    struct adin2111_priv *priv = netdev_priv(netdev);
    u32 val;
    int ret;
    
    /* Enable device */
    ret = adin2111_write_reg(priv, ADIN2111_CONFIG0, ADIN2111_CONFIG0_SYNC);
    if (ret)
        return ret;
    
    /* Configure single interface mode if enabled */
    if (priv->single_interface_mode) {
        netdev_info(netdev, "Enabling single interface mode\n");
        
        /* Enable hardware forwarding between PHY ports */
        if (priv->hardware_forwarding_enabled) {
            val = ADIN2111_CONFIG2_P1_FWD_EN | ADIN2111_CONFIG2_P2_FWD_EN;
            ret = adin2111_write_reg(priv, ADIN2111_CONFIG2, val);
            if (ret)
                return ret;
            
            /* Enable cut-through mode for low latency */
            ret = adin2111_write_reg(priv, ADIN2111_PORT_CUT_THRU_EN, 0x03);
            if (ret)
                return ret;
            
            netdev_info(netdev, "Hardware forwarding enabled\n");
        }
        
        /* Start MAC aging timer */
        mod_timer(&priv->aging_timer, jiffies + HZ * 60);
    }
    
    netif_start_queue(netdev);
    
    return 0;
}

static int adin2111_stop(struct net_device *netdev)
{
    struct adin2111_priv *priv = netdev_priv(netdev);
    
    netif_stop_queue(netdev);
    
    if (priv->single_interface_mode)
        del_timer_sync(&priv->aging_timer);
    
    return 0;
}

static netdev_tx_t adin2111_xmit(struct sk_buff *skb, struct net_device *netdev)
{
    struct adin2111_priv *priv = netdev_priv(netdev);
    struct ethhdr *eth = eth_hdr(skb);
    struct mac_entry *entry;
    u8 dest_port = 0;
    int ret;
    
    if (priv->single_interface_mode) {
        /* Learn source MAC */
        mac_table_learn(priv, eth->h_source, 0);  /* Port 0 = host */
        
        /* Determine destination port */
        if (is_multicast_ether_addr(eth->h_dest)) {
            /* Flood to both PHY ports */
            dest_port = 0x03;
        } else {
            entry = mac_table_lookup(priv, eth->h_dest);
            if (entry) {
                dest_port = BIT(entry->port);
            } else {
                /* Unknown unicast - flood */
                dest_port = 0x03;
            }
        }
    } else {
        /* Standard mode - send to configured port */
        dest_port = 0x01;
    }
    
    /* Transmit packet (simplified - actual implementation would use DMA) */
    ret = adin2111_write_reg(priv, ADIN2111_TX_FSIZE, skb->len);
    if (ret) {
        priv->stats[0].tx_errors++;
        dev_kfree_skb_any(skb);
        return NETDEV_TX_OK;
    }
    
    /* Update statistics */
    if (dest_port & 0x01) {
        priv->stats[0].tx_packets++;
        priv->stats[0].tx_bytes += skb->len;
    }
    if (dest_port & 0x02) {
        priv->stats[1].tx_packets++;
        priv->stats[1].tx_bytes += skb->len;
    }
    
    dev_kfree_skb_any(skb);
    return NETDEV_TX_OK;
}

static void adin2111_get_stats64(struct net_device *netdev,
                                 struct rtnl_link_stats64 *stats)
{
    struct adin2111_priv *priv = netdev_priv(netdev);
    
    if (priv->single_interface_mode) {
        /* Combine statistics from both ports */
        stats->tx_packets = priv->stats[0].tx_packets + priv->stats[1].tx_packets;
        stats->rx_packets = priv->stats[0].rx_packets + priv->stats[1].rx_packets;
        stats->tx_bytes = priv->stats[0].tx_bytes + priv->stats[1].tx_bytes;
        stats->rx_bytes = priv->stats[0].rx_bytes + priv->stats[1].rx_bytes;
        stats->tx_errors = priv->stats[0].tx_errors + priv->stats[1].tx_errors;
        stats->rx_errors = priv->stats[0].rx_errors + priv->stats[1].rx_errors;
    } else {
        /* Port 0 statistics only */
        stats->tx_packets = priv->stats[0].tx_packets;
        stats->rx_packets = priv->stats[0].rx_packets;
        stats->tx_bytes = priv->stats[0].tx_bytes;
        stats->rx_bytes = priv->stats[0].rx_bytes;
        stats->tx_errors = priv->stats[0].tx_errors;
        stats->rx_errors = priv->stats[0].rx_errors;
    }
}

static const struct net_device_ops adin2111_netdev_ops = {
    .ndo_open = adin2111_open,
    .ndo_stop = adin2111_stop,
    .ndo_start_xmit = adin2111_xmit,
    .ndo_get_stats64 = adin2111_get_stats64,
    .ndo_validate_addr = eth_validate_addr,
    .ndo_set_mac_address = eth_mac_addr,
};

/* SPI driver probe/remove */
static int adin2111_probe(struct spi_device *spi)
{
    struct net_device *netdev;
    struct adin2111_priv *priv;
    u32 devid;
    int ret;
    
    /* Allocate network device */
    netdev = alloc_etherdev(sizeof(struct adin2111_priv));
    if (!netdev)
        return -ENOMEM;
    
    priv = netdev_priv(netdev);
    priv->netdev = netdev;
    priv->spi = spi;
    priv->single_interface_mode = single_interface_mode;
    priv->hardware_forwarding_enabled = hardware_forwarding;
    
    spin_lock_init(&priv->lock);
    hash_init(priv->mac_table);
    timer_setup(&priv->aging_timer, mac_table_aging, 0);
    
    /* Read device ID to verify communication */
    ret = adin2111_read_reg(priv, ADIN2111_DEVID, &devid);
    if (ret) {
        netdev_err(netdev, "Failed to read device ID\n");
        goto err_free;
    }
    
    netdev_info(netdev, "ADIN2111 detected, ID: 0x%04x\n", devid);
    
    /* Set up network device */
    netdev->netdev_ops = &adin2111_netdev_ops;
    eth_hw_addr_random(netdev);
    
    /* Register network device */
    ret = register_netdev(netdev);
    if (ret) {
        netdev_err(netdev, "Failed to register netdev\n");
        goto err_free;
    }
    
    spi_set_drvdata(spi, priv);
    
    netdev_info(netdev, "ADIN2111 hybrid driver loaded%s\n",
                priv->single_interface_mode ? " (single interface mode)" : "");
    
    return 0;
    
err_free:
    free_netdev(netdev);
    return ret;
}

static void adin2111_remove(struct spi_device *spi)
{
    struct adin2111_priv *priv = spi_get_drvdata(spi);
    struct mac_entry *entry;
    struct hlist_node *tmp;
    int bkt;
    
    unregister_netdev(priv->netdev);
    
    /* Clean up MAC table */
    hash_for_each_safe(priv->mac_table, bkt, tmp, entry, node) {
        hash_del(&entry->node);
        kfree(entry);
    }
    
    free_netdev(priv->netdev);
}

static const struct of_device_id adin2111_of_match[] = {
    { .compatible = "adi,adin2111" },
    { }
};
MODULE_DEVICE_TABLE(of, adin2111_of_match);

static const struct spi_device_id adin2111_spi_id[] = {
    { "adin2111", 0 },
    { }
};
MODULE_DEVICE_TABLE(spi, adin2111_spi_id);

static struct spi_driver adin2111_driver = {
    .driver = {
        .name = DRV_NAME,
        .of_match_table = adin2111_of_match,
    },
    .probe = adin2111_probe,
    .remove = adin2111_remove,
    .id_table = adin2111_spi_id,
};

module_spi_driver(adin2111_driver);

MODULE_DESCRIPTION("ADIN2111 Hybrid Driver with Single Interface Mode");
MODULE_AUTHOR("Murray Kopit <murr2k@gmail.com>");
MODULE_LICENSE("GPL v2");
MODULE_VERSION(DRV_VERSION);
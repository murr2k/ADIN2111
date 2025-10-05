/*
 * QEMU ADIN2111 Hybrid Model - Enhanced for Single Interface Mode Testing
 *
 * Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 *
 * Enhanced ADIN2111 model with:
 * - Single interface mode support
 * - MAC learning table emulation
 * - Hardware forwarding simulation
 * - Combined statistics tracking
 */

#include "qemu/osdep.h"
#include "hw/sysbus.h"
#include "hw/irq.h"
#include "hw/ssi/ssi.h"
#include "net/net.h"
#include "net/eth.h"
#include "qapi/error.h"
#include "qemu/module.h"
#include "qemu/log.h"
#include "qemu/timer.h"
#include "hw/qdev-properties.h"

#define TYPE_ADIN2111_HYBRID "adin2111-hybrid"
OBJECT_DECLARE_SIMPLE_TYPE(ADIN2111HybridState, ADIN2111_HYBRID)

/* Register definitions from hybrid driver */
#define ADIN1110_RESET              0x03
#define ADIN1110_CONFIG1            0x04
#define ADIN1110_CONFIG2            0x06
#define ADIN2111_PORT_CUT_THRU_EN   BIT(11)
#define ADIN2111_P2_FWD_UNK2HOST    BIT(12)
#define ADIN1110_FWD_UNK2HOST       BIT(2)

#define ADIN1110_STATUS0            0x08
#define ADIN1110_STATUS1            0x09
#define ADIN2111_P2_RX_RDY          BIT(17)
#define ADIN1110_RX_RDY             BIT(4)
#define ADIN1110_TX_RDY             BIT(3)

#define ADIN1110_IMASK1             0x0D
#define ADIN1110_TX_FSIZE           0x30
#define ADIN1110_TX                 0x31
#define ADIN1110_TX_SPACE           0x32
#define ADIN1110_RX_FSIZE           0x90
#define ADIN1110_RX                 0x91
#define ADIN2111_RX_P2_FSIZE        0xC0
#define ADIN2111_RX_P2              0xC1

/* MAC learning table size */
#define MAC_TABLE_SIZE              256
#define MAC_AGE_TIME_NS             (5LL * 60 * 1000000000)  /* 5 minutes */

typedef struct MacEntry {
    uint8_t addr[ETH_ALEN];
    uint8_t port;
    int64_t timestamp;
    bool valid;
} MacEntry;

typedef struct ADIN2111HybridState {
    SSIPeripheral parent_obj;
    
    /* Network interfaces */
    NICState *host_nic;          /* Host interface (SPI) */
    NICState *phy_nic[2];        /* PHY0 and PHY1 interfaces */
    NICConf host_conf;
    NICConf phy_conf[2];
    
    /* Operating modes */
    bool single_interface_mode;
    bool hardware_forwarding_enabled;
    
    /* MAC Learning Table */
    MacEntry mac_table[MAC_TABLE_SIZE];
    
    /* Registers */
    uint32_t regs[256];
    
    /* RX/TX FIFOs */
    uint8_t tx_fifo[2048];
    uint8_t rx_fifo[2][2048];
    uint32_t tx_fifo_size;
    uint32_t rx_fifo_size[2];
    
    /* Statistics (per port) */
    struct {
        uint64_t rx_packets;
        uint64_t tx_packets;
        uint64_t rx_bytes;
        uint64_t tx_bytes;
    } port_stats[2];
    
    /* Combined statistics for single interface mode */
    struct {
        uint64_t rx_packets;
        uint64_t tx_packets;
        uint64_t rx_bytes;
        uint64_t tx_bytes;
    } combined_stats;
    
    /* SPI state machine */
    enum {
        SPI_IDLE,
        SPI_CMD,
        SPI_ADDR,
        SPI_DATA
    } spi_state;
    
    uint8_t spi_cmd;
    uint16_t spi_addr;
    uint32_t spi_data_len;
    uint32_t spi_data_pos;
    
    /* Interrupt handling */
    qemu_irq irq;
    uint32_t irq_status;
    uint32_t irq_mask;
    
    /* Timers for realistic timing */
    QEMUTimer *forward_timer;
    
} ADIN2111HybridState;

/* MAC address utilities */
static bool is_broadcast_ether_addr(const uint8_t *addr)
{
    return (addr[0] & addr[1] & addr[2] & addr[3] & addr[4] & addr[5]) == 0xff;
}

static bool is_multicast_ether_addr(const uint8_t *addr)
{
    return addr[0] & 0x01;
}

/* MAC learning table hash function */
static uint32_t mac_hash(const uint8_t *mac)
{
    uint32_t hash = 0;
    for (int i = 0; i < ETH_ALEN; i++) {
        hash = (hash << 5) + hash + mac[i];
    }
    return hash % MAC_TABLE_SIZE;
}

/* Learn MAC address on port */
static void adin2111_learn_mac(ADIN2111HybridState *s, 
                               const uint8_t *mac, 
                               int port)
{
    uint32_t idx = mac_hash(mac);
    MacEntry *entry = &s->mac_table[idx];
    
    /* Update or create entry */
    memcpy(entry->addr, mac, ETH_ALEN);
    entry->port = port;
    entry->timestamp = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    entry->valid = true;
    
    qemu_log_mask(LOG_UNIMP, 
                 "ADIN2111: Learned MAC %02x:%02x:%02x:%02x:%02x:%02x on port %d\n",
                 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], port);
}

/* Lookup MAC in learning table */
static int adin2111_lookup_mac(ADIN2111HybridState *s, const uint8_t *mac)
{
    uint32_t idx = mac_hash(mac);
    MacEntry *entry = &s->mac_table[idx];
    
    if (!entry->valid) {
        return -1;
    }
    
    if (memcmp(entry->addr, mac, ETH_ALEN) != 0) {
        return -1;
    }
    
    /* Check if entry has aged out */
    int64_t age = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) - entry->timestamp;
    if (age > MAC_AGE_TIME_NS) {
        entry->valid = false;
        return -1;
    }
    
    return entry->port;
}

/* Hardware forwarding implementation */
static void adin2111_forward_packet(ADIN2111HybridState *s,
                                    int src_port,
                                    const uint8_t *buf,
                                    size_t size)
{
    struct eth_header *eth = (struct eth_header *)buf;
    int dst_port;
    
    if (!s->hardware_forwarding_enabled) {
        return;
    }
    
    /* Learn source MAC */
    adin2111_learn_mac(s, eth->h_source, src_port);
    
    /* Determine destination port */
    if (is_broadcast_ether_addr(eth->h_dest) ||
        is_multicast_ether_addr(eth->h_dest)) {
        /* Flood to other port */
        dst_port = (src_port == 0) ? 1 : 0;
        qemu_log_mask(LOG_UNIMP, 
                     "ADIN2111: Flooding broadcast/multicast from port %d to port %d\n",
                     src_port, dst_port);
    } else {
        /* Lookup destination MAC */
        dst_port = adin2111_lookup_mac(s, eth->h_dest);
        if (dst_port < 0) {
            /* Unknown unicast - flood to other port */
            dst_port = (src_port == 0) ? 1 : 0;
            qemu_log_mask(LOG_UNIMP, 
                         "ADIN2111: Unknown unicast, flooding from port %d to port %d\n",
                         src_port, dst_port);
        } else if (dst_port == src_port) {
            /* Same port - drop */
            qemu_log_mask(LOG_UNIMP, 
                         "ADIN2111: Dropping packet (same port %d)\n", src_port);
            return;
        } else {
            qemu_log_mask(LOG_UNIMP, 
                         "ADIN2111: Forwarding unicast from port %d to port %d\n",
                         src_port, dst_port);
        }
    }
    
    /* Forward to destination port */
    if (s->phy_nic[dst_port]) {
        qemu_send_packet(qemu_get_queue(s->phy_nic[dst_port]), buf, size);
        
        /* Update statistics */
        s->port_stats[dst_port].tx_packets++;
        s->port_stats[dst_port].tx_bytes += size;
    }
}

/* PHY port receive handler */
static ssize_t adin2111_phy_receive(NetClientState *nc,
                                    const uint8_t *buf,
                                    size_t size)
{
    ADIN2111HybridState *s = qemu_get_nic_opaque(nc);
    int port = (nc == qemu_get_queue(s->phy_nic[0])) ? 0 : 1;
    
    qemu_log_mask(LOG_UNIMP, 
                 "ADIN2111: PHY%d received %zu bytes\n", port, size);
    
    /* Update statistics */
    s->port_stats[port].rx_packets++;
    s->port_stats[port].rx_bytes += size;
    
    /* Store in RX FIFO */
    if (size <= sizeof(s->rx_fifo[port])) {
        memcpy(s->rx_fifo[port], buf, size);
        s->rx_fifo_size[port] = size;
        
        /* Set RX ready flag */
        if (port == 0) {
            s->regs[ADIN1110_STATUS1] |= ADIN1110_RX_RDY;
        } else {
            s->regs[ADIN1110_STATUS1] |= ADIN2111_P2_RX_RDY;
        }
        
        /* Trigger interrupt if enabled */
        if (s->irq_mask & (port == 0 ? ADIN1110_RX_RDY : ADIN2111_P2_RX_RDY)) {
            qemu_irq_raise(s->irq);
        }
    }
    
    /* Perform hardware forwarding */
    adin2111_forward_packet(s, port, buf, size);
    
    return size;
}

/* Host (SPI) receive handler */
static ssize_t adin2111_host_receive(NetClientState *nc,
                                     const uint8_t *buf,
                                     size_t size)
{
    ADIN2111HybridState *s = qemu_get_nic_opaque(nc);
    struct eth_header *eth = (struct eth_header *)buf;
    int dst_port;
    
    qemu_log_mask(LOG_UNIMP, 
                 "ADIN2111: Host transmitted %zu bytes\n", size);
    
    /* Determine destination port based on MAC */
    if (is_broadcast_ether_addr(eth->h_dest) ||
        is_multicast_ether_addr(eth->h_dest)) {
        /* Send to both PHY ports */
        if (s->phy_nic[0]) {
            qemu_send_packet(qemu_get_queue(s->phy_nic[0]), buf, size);
            s->port_stats[0].tx_packets++;
            s->port_stats[0].tx_bytes += size;
        }
        if (s->phy_nic[1]) {
            qemu_send_packet(qemu_get_queue(s->phy_nic[1]), buf, size);
            s->port_stats[1].tx_packets++;
            s->port_stats[1].tx_bytes += size;
        }
    } else {
        /* Lookup destination MAC or send to port 0 */
        dst_port = adin2111_lookup_mac(s, eth->h_dest);
        if (dst_port < 0) {
            dst_port = 0;  /* Default to port 0 */
        }
        
        if (s->phy_nic[dst_port]) {
            qemu_send_packet(qemu_get_queue(s->phy_nic[dst_port]), buf, size);
            s->port_stats[dst_port].tx_packets++;
            s->port_stats[dst_port].tx_bytes += size;
        }
    }
    
    /* Update combined statistics */
    if (s->single_interface_mode) {
        s->combined_stats.tx_packets++;
        s->combined_stats.tx_bytes += size;
    }
    
    return size;
}

/* Network client info */
static NetClientInfo adin2111_host_info = {
    .type = NET_CLIENT_DRIVER_NIC,
    .size = sizeof(NICState),
    .receive = adin2111_host_receive,
};

static NetClientInfo adin2111_phy_info = {
    .type = NET_CLIENT_DRIVER_NIC,
    .size = sizeof(NICState),
    .receive = adin2111_phy_receive,
};

/* SPI transfer handler */
static uint32_t adin2111_transfer(SSIPeripheral *dev, uint32_t val)
{
    ADIN2111HybridState *s = ADIN2111_HYBRID(dev);
    uint32_t ret = 0;
    
    /* Simple SPI state machine */
    switch (s->spi_state) {
    case SPI_CMD:
        s->spi_cmd = val;
        s->spi_state = SPI_ADDR;
        break;
        
    case SPI_ADDR:
        if (s->spi_addr == 0) {
            s->spi_addr = val << 8;
        } else {
            s->spi_addr |= val;
            s->spi_state = SPI_DATA;
        }
        break;
        
    case SPI_DATA:
        if (s->spi_cmd & 0x02) {  /* Write */
            /* Handle register write */
            s->regs[s->spi_addr] = val;
            
            /* Check for special registers */
            if (s->spi_addr == ADIN1110_CONFIG2) {
                if (val & ADIN2111_PORT_CUT_THRU_EN) {
                    s->hardware_forwarding_enabled = true;
                    qemu_log_mask(LOG_UNIMP, 
                                 "ADIN2111: Hardware forwarding enabled\n");
                }
            }
        } else {  /* Read */
            ret = s->regs[s->spi_addr];
        }
        s->spi_state = SPI_IDLE;
        break;
        
    default:
        s->spi_state = SPI_CMD;
        break;
    }
    
    return ret;
}

/* Device initialization */
static void adin2111_hybrid_realize(DeviceState *dev, Error **errp)
{
    ADIN2111HybridState *s = ADIN2111_HYBRID(dev);
    
    /* Initialize MAC learning table */
    memset(s->mac_table, 0, sizeof(s->mac_table));
    
    /* Initialize registers */
    s->regs[ADIN1110_RESET] = 0x0283BCA1;  /* ADIN2111 PHY ID */
    s->regs[ADIN1110_TX_SPACE] = 2048;     /* Available TX space */
    
    /* Create host network interface */
    s->host_nic = qemu_new_nic(&adin2111_host_info, &s->host_conf,
                               object_get_typename(OBJECT(dev)),
                               dev->id, s);
    
    /* Create PHY network interfaces */
    for (int i = 0; i < 2; i++) {
        char name[32];
        snprintf(name, sizeof(name), "%s.phy%d", dev->id, i);
        s->phy_nic[i] = qemu_new_nic(&adin2111_phy_info, &s->phy_conf[i],
                                     object_get_typename(OBJECT(dev)),
                                     name, s);
    }
    
    /* Create timer for delayed forwarding */
    s->forward_timer = timer_new_ns(QEMU_CLOCK_VIRTUAL, NULL, s);
    
    qemu_log_mask(LOG_UNIMP, 
                 "ADIN2111: Hybrid model initialized (single_interface=%d)\n",
                 s->single_interface_mode);
}

static void adin2111_hybrid_reset(DeviceState *dev)
{
    ADIN2111HybridState *s = ADIN2111_HYBRID(dev);
    
    /* Reset state */
    s->spi_state = SPI_IDLE;
    s->spi_cmd = 0;
    s->spi_addr = 0;
    s->hardware_forwarding_enabled = false;
    
    /* Clear statistics */
    memset(&s->port_stats, 0, sizeof(s->port_stats));
    memset(&s->combined_stats, 0, sizeof(s->combined_stats));
    
    /* Clear MAC table */
    memset(s->mac_table, 0, sizeof(s->mac_table));
    
    /* Apply single interface mode if set */
    if (s->single_interface_mode) {
        s->regs[ADIN1110_CONFIG2] |= ADIN2111_PORT_CUT_THRU_EN;
        s->hardware_forwarding_enabled = true;
    }
}

static Property adin2111_hybrid_properties[] = {
    DEFINE_NIC_PROPERTIES(ADIN2111HybridState, host_conf),
    DEFINE_PROP_BOOL("single-interface", ADIN2111HybridState, 
                     single_interface_mode, false),
    DEFINE_PROP_END_OF_LIST(),
};

static void adin2111_hybrid_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    SSIPeripheralClass *k = SSI_PERIPHERAL_CLASS(klass);
    
    k->realize = adin2111_hybrid_realize;
    k->transfer = adin2111_transfer;
    dc->reset = adin2111_hybrid_reset;
    device_class_set_props(dc, adin2111_hybrid_properties);
    dc->desc = "ADIN2111 Hybrid Ethernet Switch (Single Interface Mode)";
}

static const TypeInfo adin2111_hybrid_info = {
    .name          = TYPE_ADIN2111_HYBRID,
    .parent        = TYPE_SSI_PERIPHERAL,
    .instance_size = sizeof(ADIN2111HybridState),
    .class_init    = adin2111_hybrid_class_init,
};

static void adin2111_hybrid_register_types(void)
{
    type_register_static(&adin2111_hybrid_info);
}

type_init(adin2111_hybrid_register_types)
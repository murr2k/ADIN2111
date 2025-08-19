/*
 * QEMU ADIN2111 Dual-Port Ethernet Switch/PHY Emulation
 *
 * Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 *
 * Based on ADIN2111 datasheet Rev. B
 * Implements SPI slave interface, dual PHY ports, and internal switch
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
#include "hw/net/adin2111.h"

#define TYPE_ADIN2111 "adin2111"
OBJECT_DECLARE_SIMPLE_TYPE(ADIN2111State, ADIN2111)

/* Timing constants from datasheet (in microseconds) */
#define ADIN2111_RESET_TIME_MS      50    /* Reset to ready time */
#define ADIN2111_PHY_RX_LATENCY_US  6400  /* 6.4µs PHY RX latency */
#define ADIN2111_PHY_TX_LATENCY_US  3200  /* 3.2µs PHY TX latency */
#define ADIN2111_SWITCH_LATENCY_US  12600 /* 12.6µs switch latency */
#define ADIN2111_POWER_ON_TIME_MS   43    /* Power-on to ready */

typedef struct ADIN2111State {
    SSISlave parent_obj;
    
    /* Network interfaces */
    NICState *nic[2];
    NICConf conf[2];
    
    /* Register storage */
    uint32_t regs[ADIN2111_REG_COUNT];
    
    /* MAC filtering table */
    struct {
        uint8_t mac[6];
        uint8_t port;
        bool valid;
    } mac_table[16];
    
    /* State */
    bool reset_active;
    bool cut_through_mode;
    bool switch_enabled;
    uint32_t spi_cmd;
    uint32_t spi_addr;
    int spi_state;
    
    /* Statistics */
    uint64_t rx_packets[2];
    uint64_t tx_packets[2];
    uint64_t rx_bytes[2];
    uint64_t tx_bytes[2];
    uint64_t rx_errors[2];
    uint64_t tx_errors[2];
    
    /* Timers for realistic timing */
    QEMUTimer *reset_timer;
    QEMUTimer *switch_timer;
    
    /* Interrupts */
    qemu_irq irq;
    uint32_t int_status;
    uint32_t int_mask;
    
} ADIN2111State;

/* SPI transaction states */
enum {
    SPI_STATE_IDLE,
    SPI_STATE_CMD,
    SPI_STATE_ADDR_HIGH,
    SPI_STATE_ADDR_LOW,
    SPI_STATE_DATA,
};

/* Register read implementation */
static uint32_t adin2111_reg_read(ADIN2111State *s, uint32_t addr)
{
    uint32_t val = 0;
    
    switch (addr) {
    case ADIN2111_REG_CHIP_ID:
        val = 0x2111;  /* ADIN2111 chip ID */
        break;
        
    case ADIN2111_REG_DEVICE_STATUS:
        val = s->reset_active ? 0 : ADIN2111_STATUS_READY;
        if (s->nic[0] && qemu_get_queue(s->nic[0])->link_down == 0) {
            val |= ADIN2111_STATUS_LINK1_UP;
        }
        if (s->nic[1] && qemu_get_queue(s->nic[1])->link_down == 0) {
            val |= ADIN2111_STATUS_LINK2_UP;
        }
        break;
        
    case ADIN2111_REG_INT_STATUS:
        val = s->int_status;
        break;
        
    case ADIN2111_REG_INT_MASK:
        val = s->int_mask;
        break;
        
    case ADIN2111_REG_SWITCH_CONFIG:
        val = s->cut_through_mode ? 0x01 : 0x00;
        val |= s->switch_enabled ? 0x10 : 0x00;
        break;
        
    case ADIN2111_REG_PORT1_STATUS:
        val = (s->nic[0] && !qemu_get_queue(s->nic[0])->link_down) ? 0x01 : 0x00;
        break;
        
    case ADIN2111_REG_PORT2_STATUS:
        val = (s->nic[1] && !qemu_get_queue(s->nic[1])->link_down) ? 0x01 : 0x00;
        break;
        
    default:
        if (addr < ADIN2111_REG_COUNT) {
            val = s->regs[addr];
        } else {
            qemu_log_mask(LOG_GUEST_ERROR,
                         "adin2111: read from invalid register 0x%04x\n", addr);
        }
        break;
    }
    
    return val;
}

/* Register write implementation */
static void adin2111_reg_write(ADIN2111State *s, uint32_t addr, uint32_t val)
{
    switch (addr) {
    case ADIN2111_REG_SCRATCH:
        s->regs[addr] = val;  /* Scratchpad register */
        break;
        
    case ADIN2111_REG_RESET_CTL:
        if (val & ADIN2111_RESET_SOFT) {
            /* Trigger soft reset */
            s->reset_active = true;
            timer_mod(s->reset_timer,
                     qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + ADIN2111_RESET_TIME_MS);
        }
        break;
        
    case ADIN2111_REG_INT_MASK:
        s->int_mask = val;
        break;
        
    case ADIN2111_REG_INT_STATUS:
        s->int_status &= ~val;  /* Write 1 to clear */
        break;
        
    case ADIN2111_REG_SWITCH_CONFIG:
        s->cut_through_mode = (val & 0x01) ? true : false;
        s->switch_enabled = (val & 0x10) ? true : false;
        break;
        
    default:
        if (addr < ADIN2111_REG_COUNT) {
            s->regs[addr] = val;
        } else {
            qemu_log_mask(LOG_GUEST_ERROR,
                         "adin2111: write to invalid register 0x%04x\n", addr);
        }
        break;
    }
}

/* SPI transfer handler */
static uint32_t adin2111_transfer(SSISlave *dev, uint32_t val)
{
    ADIN2111State *s = ADIN2111(dev);
    uint32_t ret = 0;
    
    if (s->reset_active) {
        return 0xFFFFFFFF;  /* Return all 1s during reset */
    }
    
    switch (s->spi_state) {
    case SPI_STATE_IDLE:
    case SPI_STATE_CMD:
        /* Command byte */
        s->spi_cmd = val;
        s->spi_state = SPI_STATE_ADDR_HIGH;
        break;
        
    case SPI_STATE_ADDR_HIGH:
        /* Address high byte */
        s->spi_addr = val << 8;
        s->spi_state = SPI_STATE_ADDR_LOW;
        break;
        
    case SPI_STATE_ADDR_LOW:
        /* Address low byte */
        s->spi_addr |= val;
        s->spi_state = SPI_STATE_DATA;
        
        /* Handle read command */
        if (s->spi_cmd & ADIN2111_SPI_READ) {
            ret = adin2111_reg_read(s, s->spi_addr);
        }
        break;
        
    case SPI_STATE_DATA:
        /* Data transfer */
        if (s->spi_cmd & ADIN2111_SPI_WRITE) {
            adin2111_reg_write(s, s->spi_addr, val);
        } else {
            ret = adin2111_reg_read(s, s->spi_addr);
        }
        break;
    }
    
    return ret;
}

/* Network receive handler */
static ssize_t adin2111_receive(NetClientState *nc, const uint8_t *buf, size_t size)
{
    ADIN2111State *s = qemu_get_nic_opaque(nc);
    int port = (nc == qemu_get_queue(s->nic[0])) ? 0 : 1;
    int other_port = 1 - port;
    
    /* Update statistics */
    s->rx_packets[port]++;
    s->rx_bytes[port] += size;
    
    /* Check if we're in reset */
    if (s->reset_active) {
        return size;  /* Drop packet */
    }
    
    /* If switch is enabled, forward to other port */
    if (s->switch_enabled && s->nic[other_port]) {
        /* Emulate switching latency */
        int64_t latency_ns = (ADIN2111_PHY_RX_LATENCY_US + 
                             ADIN2111_SWITCH_LATENCY_US +
                             ADIN2111_PHY_TX_LATENCY_US) * 1000;
        
        if (s->cut_through_mode) {
            /* Cut-through: minimal latency */
            latency_ns /= 2;
        }
        
        /* Forward packet to other port after latency */
        /* Note: In real implementation, would use timer for delayed send */
        qemu_send_packet(qemu_get_queue(s->nic[other_port]), buf, size);
        
        s->tx_packets[other_port]++;
        s->tx_bytes[other_port] += size;
    }
    
    /* Generate interrupt if enabled */
    s->int_status |= (port == 0) ? ADIN2111_INT_RX1 : ADIN2111_INT_RX2;
    if (s->int_status & s->int_mask) {
        qemu_irq_raise(s->irq);
    }
    
    return size;
}

/* Reset timer callback */
static void adin2111_reset_timer_cb(void *opaque)
{
    ADIN2111State *s = opaque;
    
    s->reset_active = false;
    
    /* Generate ready interrupt */
    s->int_status |= ADIN2111_INT_READY;
    if (s->int_status & s->int_mask) {
        qemu_irq_raise(s->irq);
    }
}

/* Link status change handler */
static void adin2111_set_link(NetClientState *nc)
{
    ADIN2111State *s = qemu_get_nic_opaque(nc);
    int port = (nc == qemu_get_queue(s->nic[0])) ? 0 : 1;
    
    /* Generate link change interrupt */
    s->int_status |= (port == 0) ? ADIN2111_INT_LINK1 : ADIN2111_INT_LINK2;
    if (s->int_status & s->int_mask) {
        qemu_irq_raise(s->irq);
    }
}

static NetClientInfo net_adin2111_info = {
    .type = NET_CLIENT_DRIVER_NIC,
    .size = sizeof(NICState),
    .receive = adin2111_receive,
    .link_status_changed = adin2111_set_link,
};

/* Device reset */
static void adin2111_reset(DeviceState *dev)
{
    ADIN2111State *s = ADIN2111(dev);
    
    /* Clear registers */
    memset(s->regs, 0, sizeof(s->regs));
    
    /* Set default values */
    s->regs[ADIN2111_REG_CHIP_ID] = 0x2111;
    s->reset_active = false;
    s->cut_through_mode = true;  /* Default to cut-through */
    s->switch_enabled = true;     /* Default to switch mode */
    s->spi_state = SPI_STATE_IDLE;
    s->int_status = 0;
    s->int_mask = 0;
    
    /* Clear statistics */
    memset(s->rx_packets, 0, sizeof(s->rx_packets));
    memset(s->tx_packets, 0, sizeof(s->tx_packets));
    memset(s->rx_bytes, 0, sizeof(s->rx_bytes));
    memset(s->tx_bytes, 0, sizeof(s->tx_bytes));
    
    /* Clear MAC table */
    memset(s->mac_table, 0, sizeof(s->mac_table));
}

/* Device realization */
static void adin2111_realize(SSISlave *dev, Error **errp)
{
    ADIN2111State *s = ADIN2111(dev);
    int i;
    
    /* Create timers */
    s->reset_timer = timer_new_ms(QEMU_CLOCK_VIRTUAL, 
                                  adin2111_reset_timer_cb, s);
    
    /* Initialize NICs */
    for (i = 0; i < 2; i++) {
        s->nic[i] = qemu_new_nic(&net_adin2111_info, &s->conf[i],
                                 object_get_typename(OBJECT(s)),
                                 dev->qdev.id, i, s);
        qemu_format_nic_info_str(qemu_get_queue(s->nic[i]),
                                s->conf[i].macaddr.a);
    }
    
    /* Initialize interrupt */
    sysbus_init_irq(SYS_BUS_DEVICE(dev), &s->irq);
}

/* Property definitions */
static Property adin2111_properties[] = {
    DEFINE_NIC_PROPERTIES(ADIN2111State, conf[0]),
    DEFINE_PROP_END_OF_LIST(),
};

/* Class initialization */
static void adin2111_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);
    SSISlaveClass *ssc = SSI_SLAVE_CLASS(klass);
    
    ssc->realize = adin2111_realize;
    ssc->transfer = adin2111_transfer;
    dc->reset = adin2111_reset;
    device_class_set_props(dc, adin2111_properties);
    dc->desc = "ADIN2111 Dual-Port 10BASE-T1L Ethernet Switch/PHY";
}

static const TypeInfo adin2111_info = {
    .name          = TYPE_ADIN2111,
    .parent        = TYPE_SSI_SLAVE,
    .instance_size = sizeof(ADIN2111State),
    .class_init    = adin2111_class_init,
};

static void adin2111_register_types(void)
{
    type_register_static(&adin2111_info);
}

type_init(adin2111_register_types)
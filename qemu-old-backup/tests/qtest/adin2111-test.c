/*
 * QEMU ADIN2111 QTest Suite
 *
 * Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#include "qemu/osdep.h"
#include "libqtest.h"
#include "qapi/qmp/qdict.h"
#include "hw/net/adin2111.h"

/* Test fixture */
typedef struct {
    QTestState *qts;
    uint64_t spi_base;
} ADIN2111TestState;

/* SPI helper functions */
static uint32_t spi_transfer(ADIN2111TestState *s, uint32_t val)
{
    /* Simulate SPI transfer through QEMU test interface */
    qtest_writeb(s->qts, s->spi_base, val & 0xFF);
    return qtest_readb(s->qts, s->spi_base);
}

static uint32_t adin2111_read_reg(ADIN2111TestState *s, uint16_t addr)
{
    uint32_t val = 0;
    
    /* Send read command */
    spi_transfer(s, 0x80);  /* Read command */
    spi_transfer(s, (addr >> 8) & 0xFF);
    spi_transfer(s, addr & 0xFF);
    
    /* Read data */
    val |= spi_transfer(s, 0) << 24;
    val |= spi_transfer(s, 0) << 16;
    val |= spi_transfer(s, 0) << 8;
    val |= spi_transfer(s, 0);
    
    return val;
}

static void adin2111_write_reg(ADIN2111TestState *s, uint16_t addr, uint32_t val)
{
    /* Send write command */
    spi_transfer(s, 0x00);  /* Write command */
    spi_transfer(s, (addr >> 8) & 0xFF);
    spi_transfer(s, addr & 0xFF);
    
    /* Write data */
    spi_transfer(s, (val >> 24) & 0xFF);
    spi_transfer(s, (val >> 16) & 0xFF);
    spi_transfer(s, (val >> 8) & 0xFF);
    spi_transfer(s, val & 0xFF);
}

/* Test cases */
static void test_chip_id(void)
{
    ADIN2111TestState s = {0};
    uint32_t chip_id;
    
    s.qts = qtest_init("-device adin2111");
    
    /* Read chip ID register */
    chip_id = adin2111_read_reg(&s, ADIN2111_REG_CHIP_ID);
    
    /* Verify chip ID */
    g_assert_cmpuint(chip_id, ==, 0x2111);
    
    qtest_quit(s.qts);
}

static void test_scratch_register(void)
{
    ADIN2111TestState s = {0};
    uint32_t val;
    
    s.qts = qtest_init("-device adin2111");
    
    /* Write test pattern to scratch register */
    adin2111_write_reg(&s, ADIN2111_REG_SCRATCH, 0xDEADBEEF);
    
    /* Read back and verify */
    val = adin2111_read_reg(&s, ADIN2111_REG_SCRATCH);
    g_assert_cmpuint(val, ==, 0xDEADBEEF);
    
    /* Write different pattern */
    adin2111_write_reg(&s, ADIN2111_REG_SCRATCH, 0x12345678);
    val = adin2111_read_reg(&s, ADIN2111_REG_SCRATCH);
    g_assert_cmpuint(val, ==, 0x12345678);
    
    qtest_quit(s.qts);
}

static void test_soft_reset(void)
{
    ADIN2111TestState s = {0};
    uint32_t status;
    
    s.qts = qtest_init("-device adin2111");
    
    /* Check initial status */
    status = adin2111_read_reg(&s, ADIN2111_REG_DEVICE_STATUS);
    g_assert_cmpuint(status & ADIN2111_STATUS_READY, ==, ADIN2111_STATUS_READY);
    
    /* Trigger soft reset */
    adin2111_write_reg(&s, ADIN2111_REG_RESET_CTL, ADIN2111_RESET_SOFT);
    
    /* Device should not be ready immediately */
    status = adin2111_read_reg(&s, ADIN2111_REG_DEVICE_STATUS);
    g_assert_cmpuint(status & ADIN2111_STATUS_READY, ==, 0);
    
    /* Wait for reset to complete (50ms from datasheet) */
    qtest_clock_step(s.qts, 60 * 1000000);  /* 60ms in ns */
    
    /* Device should be ready again */
    status = adin2111_read_reg(&s, ADIN2111_REG_DEVICE_STATUS);
    g_assert_cmpuint(status & ADIN2111_STATUS_READY, ==, ADIN2111_STATUS_READY);
    
    qtest_quit(s.qts);
}

static void test_switch_config(void)
{
    ADIN2111TestState s = {0};
    uint32_t config;
    
    s.qts = qtest_init("-device adin2111");
    
    /* Read default configuration */
    config = adin2111_read_reg(&s, ADIN2111_REG_SWITCH_CONFIG);
    
    /* Default should be cut-through and enabled */
    g_assert_cmpuint(config & ADIN2111_SWITCH_CUT_THROUGH, ==, 
                     ADIN2111_SWITCH_CUT_THROUGH);
    g_assert_cmpuint(config & ADIN2111_SWITCH_ENABLE, ==, 
                     ADIN2111_SWITCH_ENABLE);
    
    /* Switch to store-and-forward */
    adin2111_write_reg(&s, ADIN2111_REG_SWITCH_CONFIG, ADIN2111_SWITCH_ENABLE);
    config = adin2111_read_reg(&s, ADIN2111_REG_SWITCH_CONFIG);
    g_assert_cmpuint(config & ADIN2111_SWITCH_CUT_THROUGH, ==, 0);
    
    /* Disable switch */
    adin2111_write_reg(&s, ADIN2111_REG_SWITCH_CONFIG, 0);
    config = adin2111_read_reg(&s, ADIN2111_REG_SWITCH_CONFIG);
    g_assert_cmpuint(config & ADIN2111_SWITCH_ENABLE, ==, 0);
    
    qtest_quit(s.qts);
}

static void test_interrupt_mask(void)
{
    ADIN2111TestState s = {0};
    uint32_t mask, status;
    
    s.qts = qtest_init("-device adin2111");
    
    /* Set interrupt mask */
    adin2111_write_reg(&s, ADIN2111_REG_INT_MASK, 
                      ADIN2111_INT_LINK1 | ADIN2111_INT_LINK2);
    
    /* Read back mask */
    mask = adin2111_read_reg(&s, ADIN2111_REG_INT_MASK);
    g_assert_cmpuint(mask, ==, ADIN2111_INT_LINK1 | ADIN2111_INT_LINK2);
    
    /* Clear interrupt status */
    status = adin2111_read_reg(&s, ADIN2111_REG_INT_STATUS);
    if (status) {
        adin2111_write_reg(&s, ADIN2111_REG_INT_STATUS, status);
    }
    
    qtest_quit(s.qts);
}

static void test_mac_table(void)
{
    ADIN2111TestState s = {0};
    uint32_t val;
    int i;
    
    s.qts = qtest_init("-device adin2111");
    
    /* Write MAC entries */
    for (i = 0; i < 4; i++) {
        uint32_t addr = ADIN2111_REG_MAC_TABLE_BASE + (i * 2);
        adin2111_write_reg(&s, addr, 0x11223344 + i);
        adin2111_write_reg(&s, addr + 1, 0x5566 + i);
    }
    
    /* Read back and verify */
    for (i = 0; i < 4; i++) {
        uint32_t addr = ADIN2111_REG_MAC_TABLE_BASE + (i * 2);
        val = adin2111_read_reg(&s, addr);
        g_assert_cmpuint(val, ==, 0x11223344 + i);
        val = adin2111_read_reg(&s, addr + 1);
        g_assert_cmpuint(val, ==, 0x5566 + i);
    }
    
    qtest_quit(s.qts);
}

static void test_port_statistics(void)
{
    ADIN2111TestState s = {0};
    uint32_t packets, bytes;
    
    s.qts = qtest_init("-device adin2111,netdev=n1 -netdev user,id=n1");
    
    /* Read initial statistics (should be zero) */
    packets = adin2111_read_reg(&s, ADIN2111_REG_PORT1_RX_PKTS);
    g_assert_cmpuint(packets, ==, 0);
    
    bytes = adin2111_read_reg(&s, ADIN2111_REG_PORT1_RX_BYTES);
    g_assert_cmpuint(bytes, ==, 0);
    
    /* TODO: Send test packet and verify counters increment */
    
    qtest_quit(s.qts);
}

static void test_timing_emulation(void)
{
    ADIN2111TestState s = {0};
    int64_t start_time, elapsed;
    
    s.qts = qtest_init("-device adin2111");
    
    /* Test reset timing */
    start_time = qtest_clock_step(s.qts, 0);
    
    /* Trigger reset */
    adin2111_write_reg(&s, ADIN2111_REG_RESET_CTL, ADIN2111_RESET_SOFT);
    
    /* Step clock by less than reset time */
    qtest_clock_step(s.qts, 40 * 1000000);  /* 40ms */
    
    /* Should still be in reset */
    uint32_t status = adin2111_read_reg(&s, ADIN2111_REG_DEVICE_STATUS);
    g_assert_cmpuint(status & ADIN2111_STATUS_READY, ==, 0);
    
    /* Step past reset time */
    qtest_clock_step(s.qts, 20 * 1000000);  /* +20ms = 60ms total */
    
    /* Should be ready now */
    status = adin2111_read_reg(&s, ADIN2111_REG_DEVICE_STATUS);
    g_assert_cmpuint(status & ADIN2111_STATUS_READY, ==, ADIN2111_STATUS_READY);
    
    qtest_quit(s.qts);
}

/* Main test registration */
int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    
    qtest_add_func("/adin2111/chip_id", test_chip_id);
    qtest_add_func("/adin2111/scratch", test_scratch_register);
    qtest_add_func("/adin2111/reset", test_soft_reset);
    qtest_add_func("/adin2111/switch_config", test_switch_config);
    qtest_add_func("/adin2111/interrupts", test_interrupt_mask);
    qtest_add_func("/adin2111/mac_table", test_mac_table);
    qtest_add_func("/adin2111/statistics", test_port_statistics);
    qtest_add_func("/adin2111/timing", test_timing_emulation);
    
    return g_test_run();
}
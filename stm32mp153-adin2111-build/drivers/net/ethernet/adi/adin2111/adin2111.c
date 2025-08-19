// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Dual Port Industrial Ethernet Switch/PHY Driver
 * Test/Simulation Version for STM32MP153
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/spi/spi.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/interrupt.h>
#include <linux/of.h>

#define ADIN2111_DRV_NAME "adin2111"
#define ADIN2111_CHIP_ID 0x2111
#define ADIN2111_PHY_ID 0x0283BC91

struct adin2111_priv {
    struct spi_device *spi;
    struct net_device *netdev;
    struct mutex lock;
    struct work_struct irq_work;
    u32 chip_id;
    u32 phy_id;
    bool link_up;
};

static int adin2111_read_reg(struct adin2111_priv *priv, u32 reg, u32 *val)
{
    // Simulated register read
    switch (reg) {
    case 0x00: *val = ADIN2111_CHIP_ID; break;
    case 0x10: *val = ADIN2111_PHY_ID; break;
    case 0x20: *val = priv->link_up ? 0x04 : 0x00; break;
    default: *val = 0; break;
    }
    return 0;
}

static int adin2111_write_reg(struct adin2111_priv *priv, u32 reg, u32 val)
{
    // Simulated register write
    pr_debug("%s: reg=0x%04x val=0x%08x\n", __func__, reg, val);
    return 0;
}

static int adin2111_probe(struct spi_device *spi)
{
    struct adin2111_priv *priv;
    u32 chip_id;
    int ret;

    pr_info("%s: Probing ADIN2111 on STM32MP153\n", ADIN2111_DRV_NAME);

    // Validate SPI device
    if (!spi) {
        pr_err("%s: NULL SPI device\n", ADIN2111_DRV_NAME);
        return -EINVAL;
    }

    // Allocate private data
    priv = devm_kzalloc(&spi->dev, sizeof(*priv), GFP_KERNEL);
    if (!priv)
        return -ENOMEM;

    priv->spi = spi;
    mutex_init(&priv->lock);
    spi_set_drvdata(spi, priv);

    // Read chip ID
    ret = adin2111_read_reg(priv, 0x00, &chip_id);
    if (ret || chip_id != ADIN2111_CHIP_ID) {
        dev_err(&spi->dev, "Invalid chip ID: 0x%04x\n", chip_id);
        return -ENODEV;
    }

    priv->chip_id = chip_id;
    priv->link_up = true; // Simulate link up

    pr_info("%s: ADIN2111 probe successful (ID: 0x%04x)\n", 
            ADIN2111_DRV_NAME, chip_id);

    return 0;
}

static void adin2111_remove(struct spi_device *spi)
{
    pr_info("%s: Removing ADIN2111 driver\n", ADIN2111_DRV_NAME);
}

static const struct of_device_id adin2111_of_match[] = {
    { .compatible = "adi,adin2111" },
    { }
};
MODULE_DEVICE_TABLE(of, adin2111_of_match);

static struct spi_driver adin2111_driver = {
    .driver = {
        .name = ADIN2111_DRV_NAME,
        .of_match_table = adin2111_of_match,
    },
    .probe = adin2111_probe,
    .remove = adin2111_remove,
};

module_spi_driver(adin2111_driver);

MODULE_DESCRIPTION("ADIN2111 Ethernet Driver for STM32MP153");
MODULE_AUTHOR("Murray Kopit");
MODULE_LICENSE("GPL");

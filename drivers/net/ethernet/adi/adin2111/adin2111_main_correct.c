// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Main Driver - CORRECT Implementation
 * No sleeping in softirq contexts!
 */

#include <linux/module.h>
#include <linux/spi/spi.h>
#include <linux/of.h>
#include <linux/gpio/consumer.h>

#include "adin2111.h"
#include "adin2111_regs.h"

/* External functions */
extern int adin2111_netdev_init_correct(struct adin2111_priv *priv);
extern void adin2111_netdev_uninit_correct(struct adin2111_priv *priv);
extern int adin2111_soft_reset(struct adin2111_priv *priv);
extern struct regmap *adin2111_init_regmap(struct spi_device *spi);
extern int adin2111_mdio_init(struct adin2111_priv *priv);
extern void adin2111_mdio_uninit(struct adin2111_priv *priv);

static int adin2111_hw_init(struct adin2111_priv *priv)
{
	u32 config0;
	int ret;
	
	/* Soft reset */
	ret = adin2111_soft_reset(priv);
	if (ret)
		return ret;
	
	/* Basic configuration */
	config0 = ADIN2111_CONFIG0_SYNC;
	ret = adin2111_write_reg(priv, ADIN2111_CONFIG0, config0);
	if (ret)
		return ret;
	
	/* Enable unmanaged switch mode */
	u32 config2 = 0;
	ret = adin2111_read_reg(priv, ADIN2111_CONFIG2, &config2);
	if (!ret) {
		config2 |= ADIN2111_CONFIG2_PORT_CUT_THRU_EN;
		ret = adin2111_write_reg(priv, ADIN2111_CONFIG2, config2);
	}
	
	return ret;
}

static int adin2111_probe_correct(struct spi_device *spi)
{
	struct adin2111_priv *priv;
	int ret;
	
	dev_info(&spi->dev, "ADIN2111 CORRECT probe\n");
	
	/* Allocate private data */
	priv = devm_kzalloc(&spi->dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;
	
	priv->spi = spi;
	spi_set_drvdata(spi, priv);
	
	/* Initialize locks */
	mutex_init(&priv->lock);
	spin_lock_init(&priv->tx_lock);
	spin_lock_init(&priv->rx_lock);
	
	/* Set mode */
	priv->mode = ADIN2111_MODE_SWITCH;
	priv->switch_mode = true;
	
	/* Get reset GPIO (optional) */
	priv->reset_gpio = devm_gpiod_get_optional(&spi->dev, "reset", 
						    GPIOD_OUT_LOW);
	if (IS_ERR(priv->reset_gpio))
		return PTR_ERR(priv->reset_gpio);
	
	/* Initialize regmap */
	priv->regmap = adin2111_init_regmap(spi);
	if (IS_ERR(priv->regmap))
		return PTR_ERR(priv->regmap);
	
	/* Hardware initialization */
	ret = adin2111_hw_init(priv);
	if (ret) {
		dev_err(&spi->dev, "Hardware init failed: %d\n", ret);
		return ret;
	}
	
	/* Initialize MDIO bus (optional, for PHY access) */
	ret = adin2111_mdio_init(priv);
	if (ret)
		dev_warn(&spi->dev, "MDIO init failed: %d\n", ret);
	
	/* Set PHY addresses */
	priv->phy_addr[0] = 1;
	priv->phy_addr[1] = 2;
	
	/* Initialize network device with CORRECT implementation */
	ret = adin2111_netdev_init_correct(priv);
	if (ret) {
		dev_err(&spi->dev, "Failed to init netdev: %d\n", ret);
		goto err_mdio;
	}
	
	dev_info(&spi->dev, "ADIN2111 driver loaded (CORRECT version)\n");
	return 0;
	
err_mdio:
	if (priv->mii_bus)
		adin2111_mdio_uninit(priv);
	return ret;
}

static void adin2111_remove_correct(struct spi_device *spi)
{
	struct adin2111_priv *priv = spi_get_drvdata(spi);
	
	adin2111_netdev_uninit_correct(priv);
	
	if (priv->mii_bus)
		adin2111_mdio_uninit(priv);
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
		.name = "adin2111",
		.of_match_table = adin2111_of_match,
	},
	.probe = adin2111_probe_correct,
	.remove = adin2111_remove_correct,
	.id_table = adin2111_spi_id,
};

module_spi_driver(adin2111_driver);

MODULE_DESCRIPTION("ADIN2111 Driver - CORRECT Implementation");
MODULE_AUTHOR("Analog Devices Inc.");
MODULE_LICENSE("GPL");
MODULE_VERSION("3.0.0");
// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Main Driver - MVP Integration
 * Simplified probe with MVP netdev implementation
 */

#include <linux/module.h>
#include <linux/spi/spi.h>
#include <linux/of.h>
#include <linux/gpio/consumer.h>

#include "adin2111.h"
#include "adin2111_regs.h"

/* External MVP functions */
extern int adin2111_netdev_init_mvp(struct adin2111_priv *priv);
extern void adin2111_netdev_uninit_mvp(struct adin2111_priv *priv);
extern int adin2111_link_init(struct adin2111_priv *priv);
extern void adin2111_link_uninit(struct adin2111_priv *priv);
extern int adin2111_soft_reset(struct adin2111_priv *priv);
extern struct regmap *adin2111_init_regmap(struct spi_device *spi);

static int adin2111_probe_mvp(struct spi_device *spi)
{
	struct adin2111_priv *priv;
	int ret;

	dev_info(&spi->dev, "ADIN2111 MVP probe\n");

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

	/* Set mode to unmanaged switch */
	priv->mode = ADIN2111_MODE_SWITCH;
	priv->switch_mode = true;

	/* Get reset GPIO (optional) */
	priv->reset_gpio = devm_gpiod_get_optional(&spi->dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(priv->reset_gpio))
		return PTR_ERR(priv->reset_gpio);

	/* Initialize regmap */
	priv->regmap = adin2111_init_regmap(spi);
	if (IS_ERR(priv->regmap))
		return PTR_ERR(priv->regmap);

	/* Hardware init */
	ret = adin2111_soft_reset(priv);
	if (ret) {
		dev_err(&spi->dev, "Failed to reset device: %d\n", ret);
		return ret;
	}

	/* Set PHY addresses */
	priv->phy_addr[0] = 1;
	priv->phy_addr[1] = 2;

	/* Initialize network devices */
	ret = adin2111_netdev_init_mvp(priv);
	if (ret) {
		dev_err(&spi->dev, "Failed to init netdev: %d\n", ret);
		return ret;
	}

	/* Start link monitoring */
	ret = adin2111_link_init(priv);
	if (ret) {
		dev_err(&spi->dev, "Failed to init link monitoring: %d\n", ret);
		goto err_netdev;
	}

	dev_info(&spi->dev, "ADIN2111 MVP driver loaded successfully\n");
	return 0;

err_netdev:
	adin2111_netdev_uninit_mvp(priv);
	return ret;
}

static void adin2111_remove_mvp(struct spi_device *spi)
{
	struct adin2111_priv *priv = spi_get_drvdata(spi);

	adin2111_link_uninit(priv);
	adin2111_netdev_uninit_mvp(priv);
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
	.probe = adin2111_probe_mvp,
	.remove = adin2111_remove_mvp,
	.id_table = adin2111_spi_id,
};

module_spi_driver(adin2111_driver);

MODULE_DESCRIPTION("ADIN2111 MVP Driver");
MODULE_AUTHOR("Analog Devices Inc.");
MODULE_LICENSE("GPL");
MODULE_VERSION("2.0.0");
// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Dual Port Industrial Ethernet Switch/PHY Driver
 *
 * Copyright 2024 Analog Devices Inc.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/spi/spi.h>
#include <linux/regmap.h>
#include <linux/gpio/consumer.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/of_net.h>
#include <linux/interrupt.h>
#include <linux/workqueue.h>
#include <linux/delay.h>
#include <linux/crc32.h>
#include <linux/etherdevice.h>

#include "adin2111.h"
#include "adin2111_regs.h"

/* External function declarations */
extern struct regmap *adin2111_init_regmap(struct spi_device *spi);
extern struct net_device *adin2111_create_netdev(struct adin2111_priv *priv, int port_num);

static void adin2111_work_handler(struct work_struct *work)
{
	struct adin2111_priv *priv = container_of(work, struct adin2111_priv, irq_work);
	u32 status0, status1;
	int ret;

	mutex_lock(&priv->lock);

	/* Read interrupt status */
	ret = adin2111_read_reg(priv, ADIN2111_STATUS0, &status0);
	if (ret)
		goto out;

	ret = adin2111_read_reg(priv, ADIN2111_STATUS1, &status1);
	if (ret)
		goto out;

	/* Handle PHY interrupt */
	if (status0 & ADIN2111_STATUS0_PHYINT) {
		dev_dbg(&priv->spi->dev, "PHY interrupt\n");
		/* PHY interrupt handling is done by the PHY subsystem */
	}

	/* Handle port-specific RX */
	if (priv->mode == ADIN2111_MODE_SWITCH) {
		if (status1 & ADIN2111_STATUS1_P1_RX_RDY) {
			dev_dbg(&priv->spi->dev, "Port 1 RX ready\n");
			/* RX handling would be implemented here */
		}
		if (status1 & ADIN2111_STATUS1_P2_RX_RDY) {
			dev_dbg(&priv->spi->dev, "Port 2 RX ready\n");
			/* RX handling would be implemented here */
		}
	}

	/* Handle errors */
	if (status1 & ADIN2111_STATUS1_SPI_ERR) {
		dev_err(&priv->spi->dev, "SPI error detected\n");
	}

	if (status0 & ADIN2111_STATUS0_TXPE) {
		dev_err(&priv->spi->dev, "TX protocol error\n");
	}

	if (status0 & ADIN2111_STATUS0_RXEVM) {
		dev_err(&priv->spi->dev, "RX error\n");
	}

	/* Clear processed interrupts by writing to status registers */
	adin2111_write_reg(priv, ADIN2111_STATUS0, status0);
	adin2111_write_reg(priv, ADIN2111_STATUS1, status1);

out:
	mutex_unlock(&priv->lock);
}

irqreturn_t adin2111_irq_handler(int irq, void *dev_id)
{
	struct adin2111_priv *priv = dev_id;

	schedule_work(&priv->irq_work);
	return IRQ_HANDLED;
}

int adin2111_hw_reset(struct adin2111_priv *priv)
{
	if (priv->reset_gpio) {
		gpiod_set_value_cansleep(priv->reset_gpio, 1);
		msleep(10);
		gpiod_set_value_cansleep(priv->reset_gpio, 0);
		msleep(100);
		return 0;
	}
	return -ENODEV;
}

int adin2111_soft_reset(struct adin2111_priv *priv)
{
	int ret;
	unsigned long timeout;
	u32 val;

	ret = adin2111_write_reg(priv, ADIN2111_RESET, ADIN2111_RESET_SWRESET);
	if (ret)
		return ret;

	/* Wait for reset completion */
	timeout = jiffies + msecs_to_jiffies(ADIN2111_RESET_TIMEOUT_MS);
	do {
		ret = adin2111_read_reg(priv, ADIN2111_RESET, &val);
		if (ret)
			return ret;

		if (!(val & ADIN2111_RESET_SWRESET))
			return 0;

		usleep_range(100, 200);
	} while (time_before(jiffies, timeout));

	return -ETIMEDOUT;
}

static int adin2111_configure_switch_mode(struct adin2111_priv *priv)
{
	u32 config2;
	int ret;

	/* Read current CONFIG2 register */
	ret = adin2111_read_reg(priv, ADIN2111_CONFIG2, &config2);
	if (ret)
		return ret;

	/* Enable cut-through switching if requested */
	if (priv->pdata.cut_through)
		config2 |= ADIN2111_CONFIG2_PORT_CUT_THRU_EN;
	else
		config2 &= ~ADIN2111_CONFIG2_PORT_CUT_THRU_EN;

	/* Configure CRC append */
	if (priv->pdata.crc_append)
		config2 |= ADIN2111_CONFIG2_CRC_APPEND;
	else
		config2 &= ~ADIN2111_CONFIG2_CRC_APPEND;

	ret = adin2111_write_reg(priv, ADIN2111_CONFIG2, config2);
	if (ret)
		return ret;

	/* Configure port functionality */
	u32 port_func = 0;

	/* Disable unused ports */
	if (!priv->pdata.port1_enabled) {
		port_func |= ADIN2111_PORT_FUNCT_BC_DIS_P1 |
			     ADIN2111_PORT_FUNCT_MC_DIS_P1;
	}

	if (!priv->pdata.port2_enabled) {
		port_func |= ADIN2111_PORT_FUNCT_BC_DIS_P2 |
			     ADIN2111_PORT_FUNCT_MC_DIS_P2;
	}

	ret = adin2111_write_reg(priv, ADIN2111_PORT_FUNCT, port_func);
	if (ret)
		return ret;

	dev_info(&priv->spi->dev, "Switch mode configured: cut_through=%d, crc_append=%d\n",
		 priv->pdata.cut_through, priv->pdata.crc_append);

	return 0;
}

int adin2111_hw_init(struct adin2111_priv *priv)
{
	u32 config0, config2;
	int ret;

	/* Perform hardware reset if possible */
	adin2111_hw_reset(priv);

	/* Perform soft reset */
	ret = adin2111_soft_reset(priv);
	if (ret) {
		dev_err(&priv->spi->dev, "Soft reset failed: %d\n", ret);
		return ret;
	}

	/* Configure CONFIG0 register */
	config0 = ADIN2111_CONFIG0_SYNC;
	
	if (priv->pdata.tx_fcs_validation)
		config0 |= ADIN2111_CONFIG0_TXFCSVE;

	config0 |= ADIN2111_CONFIG0_TXCTE | ADIN2111_CONFIG0_RXCTE;

	ret = adin2111_write_reg(priv, ADIN2111_CONFIG0, config0);
	if (ret)
		return ret;

	/* Configure switch mode if enabled */
	if (priv->switch_mode) {
		ret = adin2111_configure_switch_mode(priv);
		if (ret)
			return ret;
	}

	/* Configure interrupt mask */
	priv->irq_mask = ADIN2111_STATUS1_RX_RDY;
	if (priv->switch_mode) {
		priv->irq_mask |= ADIN2111_STATUS1_P1_RX_RDY |
				  ADIN2111_STATUS1_P2_RX_RDY;
	}

	ret = adin2111_write_reg(priv, ADIN2111_IMASK1, ~priv->irq_mask);
	if (ret)
		return ret;

	/* Clear any pending interrupts */
	ret = adin2111_write_reg(priv, ADIN2111_CLEAR0, 0xFFFF);
	if (ret)
		return ret;

	ret = adin2111_write_reg(priv, ADIN2111_CLEAR1, 0xFFFFFFFF);
	if (ret)
		return ret;

	/* Clear FIFOs */
	ret = adin2111_write_reg(priv, ADIN2111_FIFO_CLR,
				 ADIN2111_FIFO_CLR_TX | ADIN2111_FIFO_CLR_RX);
	if (ret)
		return ret;

	dev_info(&priv->spi->dev, "Hardware initialized successfully\n");
	return 0;
}

static int adin2111_parse_dt(struct adin2111_priv *priv)
{
	struct device *dev = &priv->spi->dev;
	struct device_node *np = dev->of_node;

	if (!np)
		return 0;

	/* Parse switch mode configuration */
	priv->pdata.switch_mode = of_property_read_bool(np, "adi,switch-mode");
	priv->pdata.cut_through = of_property_read_bool(np, "adi,cut-through");
	priv->pdata.tx_fcs_validation = of_property_read_bool(np, "adi,tx-fcs-validation");
	priv->pdata.crc_append = of_property_read_bool(np, "adi,crc-append");

	/* Parse port enable flags */
	priv->pdata.port1_enabled = !of_property_read_bool(np, "adi,port1-disabled");
	priv->pdata.port2_enabled = !of_property_read_bool(np, "adi,port2-disabled");

	/* Default to both ports enabled if not specified */
	if (!of_find_property(np, "adi,port1-disabled", NULL))
		priv->pdata.port1_enabled = true;
	if (!of_find_property(np, "adi,port2-disabled", NULL))
		priv->pdata.port2_enabled = true;

	/* Parse MAC addresses */
	of_get_mac_address(np, priv->pdata.mac_addr_p1);
	
	/* For port 2, try to get from a separate property or derive from port 1 */
	if (of_get_mac_address(np, priv->pdata.mac_addr_p2) != 0) {
		if (!is_zero_ether_addr(priv->pdata.mac_addr_p1)) {
			memcpy(priv->pdata.mac_addr_p2, priv->pdata.mac_addr_p1, ETH_ALEN);
			priv->pdata.mac_addr_p2[5] += 1;
		}
	}

	priv->switch_mode = priv->pdata.switch_mode;

	dev_info(dev, "Device tree parsed: switch_mode=%d, cut_through=%d\n",
		 priv->pdata.switch_mode, priv->pdata.cut_through);

	return 0;
}

static int adin2111_probe(struct spi_device *spi)
{
	struct adin2111_priv *priv;
	struct net_device *netdev;
	int ret, i;

	/* Allocate private data structure */
	priv = devm_kzalloc(&spi->dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	priv->spi = spi;
	spi_set_drvdata(spi, priv);

	/* Initialize locks and work queues */
	mutex_init(&priv->lock);
	mutex_init(&priv->tx_lock);
	INIT_WORK(&priv->work, adin2111_work_handler);

	/* Parse device tree */
	ret = adin2111_parse_dt(priv);
	if (ret)
		return ret;

	/* Get reset GPIO */
	priv->reset_gpio = devm_gpiod_get_optional(&spi->dev, "reset", GPIOD_OUT_LOW);
	if (IS_ERR(priv->reset_gpio))
		return PTR_ERR(priv->reset_gpio);

	/* Initialize regmap for SPI access */
	priv->regmap = adin2111_init_regmap(spi);
	if (IS_ERR(priv->regmap)) {
		dev_err(&spi->dev, "Failed to initialize regmap: %ld\n",
			PTR_ERR(priv->regmap));
		return PTR_ERR(priv->regmap);
	}

	/* Initialize hardware */
	ret = adin2111_hw_init(priv);
	if (ret) {
		dev_err(&spi->dev, "Hardware initialization failed: %d\n", ret);
		return ret;
	}

	/* Initialize PHY management */
	ret = adin2111_phy_init(priv);
	if (ret) {
		dev_err(&spi->dev, "PHY initialization failed: %d\n", ret);
		return ret;
	}

	/* Create network devices */
	if (priv->switch_mode) {
		/* Create separate netdevs for each port */
		for (i = 0; i < ADIN2111_MAX_PORTS; i++) {
			if ((i == 0 && priv->pdata.port1_enabled) ||
			    (i == 1 && priv->pdata.port2_enabled)) {
				netdev = adin2111_create_netdev(priv, i);
				if (!netdev) {
					ret = -ENOMEM;
					goto err_cleanup_netdevs;
				}

				priv->ports[i] = netdev_priv(netdev);
				
				ret = register_netdev(netdev);
				if (ret) {
					dev_err(&spi->dev, "Failed to register netdev for port %d: %d\n",
						i, ret);
					free_netdev(netdev);
					goto err_cleanup_netdevs;
				}

				dev_info(&spi->dev, "Registered netdev for port %d: %s\n",
					 i, netdev->name);
			}
		}
	} else {
		/* Single netdev for dual MAC mode */
		netdev = adin2111_create_netdev(priv, 0);
		if (!netdev) {
			ret = -ENOMEM;
			goto err_cleanup_phy;
		}

		priv->netdev = netdev;

		ret = register_netdev(netdev);
		if (ret) {
			dev_err(&spi->dev, "Failed to register netdev: %d\n", ret);
			free_netdev(netdev);
			goto err_cleanup_phy;
		}

		dev_info(&spi->dev, "Registered netdev: %s\n", netdev->name);
	}

	/* Request IRQ */
	if (spi->irq) {
		ret = devm_request_threaded_irq(&spi->dev, spi->irq, NULL,
						adin2111_irq_handler,
						IRQF_TRIGGER_FALLING | IRQF_ONESHOT,
						dev_name(&spi->dev), priv);
		if (ret) {
			dev_err(&spi->dev, "Failed to request IRQ: %d\n", ret);
			goto err_cleanup_netdevs;
		}
		dev_info(&spi->dev, "IRQ %d registered\n", spi->irq);
	}

	dev_info(&spi->dev, "ADIN2111 driver probe completed successfully\n");
	return 0;

err_cleanup_netdevs:
	if (priv->switch_mode) {
		for (i = 0; i < ADIN2111_MAX_PORTS; i++) {
			if (priv->ports[i]) {
				unregister_netdev(priv->ports[i]->netdev);
				free_netdev(priv->ports[i]->netdev);
			}
		}
	} else if (priv->netdev) {
		unregister_netdev(priv->netdev);
		free_netdev(priv->netdev);
	}
err_cleanup_phy:
	adin2111_phy_cleanup(priv);
	return ret;
}

static void adin2111_remove(struct spi_device *spi)
{
	struct adin2111_priv *priv = spi_get_drvdata(spi);
	int i;

	dev_info(&spi->dev, "Removing ADIN2111 driver\n");

	/* Cancel work */
	cancel_work_sync(&priv->work);

	/* Cleanup network devices */
	if (priv->switch_mode) {
		for (i = 0; i < ADIN2111_MAX_PORTS; i++) {
			if (priv->ports[i]) {
				unregister_netdev(priv->ports[i]->netdev);
				free_netdev(priv->ports[i]->netdev);
			}
		}
	} else if (priv->netdev) {
		unregister_netdev(priv->netdev);
		free_netdev(priv->netdev);
	}

	/* Cleanup PHY */
	adin2111_phy_cleanup(priv);

	/* Reset device */
	adin2111_soft_reset(priv);
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
		.name = ADIN2111_DRV_NAME,
		.of_match_table = adin2111_of_match,
	},
	.probe = adin2111_probe,
	.remove = adin2111_remove,
	.id_table = adin2111_spi_id,
};

module_spi_driver(adin2111_driver);

MODULE_DESCRIPTION("ADIN2111 Dual Port Industrial Ethernet Switch/PHY Driver");
MODULE_AUTHOR("Analog Devices Inc.");
MODULE_LICENSE("GPL");
MODULE_VERSION(ADIN2111_DRV_VERSION);
// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Dual Port Industrial Ethernet Switch/PHY
 * SPI Register Access Layer
 *
 * Copyright 2024 Analog Devices Inc.
 */

#include <linux/regmap.h>
#include <linux/spi/spi.h>
#include <linux/module.h>

#include "adin2111.h"
#include "adin2111_regs.h"

/* Removed unused adin2111_spi_read and adin2111_spi_write functions */

static int adin2111_spi_reg_read(void *context, unsigned int reg,
				 unsigned int *val)
{
	struct spi_device *spi = context;
	u8 tx_buf[4];
	u8 rx_buf[4];
	int ret;
	
	/* Validate parameters to prevent kernel panic */
	if (!spi || !val) {
		pr_err("adin2111: Invalid SPI context or value pointer\n");
		return -EINVAL;
	}

	/* Prepare SPI header */
	tx_buf[0] = (ADIN2111_SPI_READ | ADIN2111_SPI_ADDR(reg)) >> 8;
	tx_buf[1] = ADIN2111_SPI_ADDR(reg) & 0xFF;
	tx_buf[2] = 0;
	tx_buf[3] = 0;

	struct spi_transfer xfers[] = {
		{
			.tx_buf = tx_buf,
			.rx_buf = rx_buf,
			.len = 4,
		},
	};

	ret = spi_sync_transfer(spi, xfers, ARRAY_SIZE(xfers));
	if (ret)
		return ret;

	*val = (rx_buf[2] << 8) | rx_buf[3];
	return 0;
}

static int adin2111_spi_reg_write(void *context, unsigned int reg,
				  unsigned int val)
{
	/* Validate SPI context to prevent kernel panic */
	if (!context) {
		pr_err("adin2111: Invalid SPI context in write\n");
		return -EINVAL;
	}
	struct spi_device *spi = context;
	u8 tx_buf[4];

	/* Prepare SPI header and data */
	tx_buf[0] = (ADIN2111_SPI_WRITE | ADIN2111_SPI_ADDR(reg)) >> 8;
	tx_buf[1] = ADIN2111_SPI_ADDR(reg) & 0xFF;
	tx_buf[2] = (val >> 8) & 0xFF;
	tx_buf[3] = val & 0xFF;

	return spi_write(spi, tx_buf, sizeof(tx_buf));
}

static const struct regmap_config adin2111_regmap_config = {
	.reg_bits = 16,
	.val_bits = 16,
	.reg_stride = 1,
	.max_register = 0x1FFF,
	.cache_type = REGCACHE_NONE,
	.reg_read = adin2111_spi_reg_read,
	.reg_write = adin2111_spi_reg_write,
};

struct regmap *adin2111_init_regmap(struct spi_device *spi)
{
	return devm_regmap_init(&spi->dev, NULL, spi, &adin2111_regmap_config);
}

int adin2111_read_reg(struct adin2111_priv *priv, u32 reg, u32 *val)
{
	unsigned int tmp;
	int ret;

	ret = regmap_read(priv->regmap, reg, &tmp);
	*val = tmp;
	return ret;
}

int adin2111_write_reg(struct adin2111_priv *priv, u32 reg, u32 val)
{
	return regmap_write(priv->regmap, reg, val);
}

int adin2111_modify_reg(struct adin2111_priv *priv, u32 reg, u32 mask, u32 val)
{
	return regmap_update_bits(priv->regmap, reg, mask, val);
}

/* Bulk read/write functions for frame data */
int adin2111_read_fifo(struct adin2111_priv *priv, u32 reg, u8 *data, size_t len)
{
	struct spi_device *spi = priv->spi;
	u8 tx_buf[2];
	int ret;

	/* Prepare SPI header for read */
	tx_buf[0] = (ADIN2111_SPI_READ | ADIN2111_SPI_ADDR(reg)) >> 8;
	tx_buf[1] = ADIN2111_SPI_ADDR(reg) & 0xFF;

	struct spi_transfer xfers[] = {
		{
			.tx_buf = tx_buf,
			.len = 2,
		},
		{
			.rx_buf = data,
			.len = len,
		},
	};

	ret = spi_sync_transfer(spi, xfers, ARRAY_SIZE(xfers));
	if (ret)
		dev_err(&spi->dev, "FIFO read failed: %d\n", ret);

	return ret;
}

int adin2111_write_fifo(struct adin2111_priv *priv, u32 reg, const u8 *data, size_t len)
{
	struct spi_device *spi = priv->spi;
	u8 *tx_buf;
	int ret;

	tx_buf = kmalloc(len + 2, GFP_KERNEL);
	if (!tx_buf)
		return -ENOMEM;

	/* Prepare SPI header for write */
	tx_buf[0] = (ADIN2111_SPI_WRITE | ADIN2111_SPI_ADDR(reg)) >> 8;
	tx_buf[1] = ADIN2111_SPI_ADDR(reg) & 0xFF;

	/* Copy frame data */
	memcpy(tx_buf + 2, data, len);

	ret = spi_write(spi, tx_buf, len + 2);
	if (ret)
		dev_err(&spi->dev, "FIFO write failed: %d\n", ret);

	kfree(tx_buf);
	return ret;
}

MODULE_DESCRIPTION("ADIN2111 SPI Register Access");
MODULE_AUTHOR("Analog Devices Inc.");
MODULE_LICENSE("GPL");
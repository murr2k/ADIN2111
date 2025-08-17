// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Dual Port Industrial Ethernet Switch/PHY
 * MDIO/PHY Management Layer
 *
 * Copyright 2024 Analog Devices Inc.
 */

#include <linux/phy.h>
#include <linux/delay.h>
#include <linux/module.h>
#include <linux/bitfield.h>

#include "adin2111.h"
#include "adin2111_regs.h"

static int adin2111_mdio_wait_ready(struct adin2111_priv *priv)
{
	unsigned long timeout = jiffies + msecs_to_jiffies(ADIN2111_MDIO_TIMEOUT_MS);
	u32 val;
	int ret;

	do {
		ret = adin2111_read_reg(priv, ADIN2111_MDIO_ACC, &val);
		if (ret)
			return ret;

		if (!(val & ADIN2111_MDIO_ACC_MDIO_TRCNT))
			return 0;

		usleep_range(10, 20);
	} while (time_before(jiffies, timeout));

	return -ETIMEDOUT;
}

int adin2111_mdio_read(struct mii_bus *bus, int addr, int regnum)
{
	struct adin2111_priv *priv = bus->priv;
	u32 val;
	int ret;

	mutex_lock(&priv->lock);

	/* Wait for any ongoing MDIO transaction */
	ret = adin2111_mdio_wait_ready(priv);
	if (ret)
		goto out;

	/* Setup MDIO read transaction */
	val = FIELD_PREP(ADIN2111_MDIO_ACC_MDIO_ST, ADIN2111_MDIO_ST_CLAUSE_22) |
	      FIELD_PREP(ADIN2111_MDIO_ACC_MDIO_OP, ADIN2111_MDIO_OP_RD) |
	      FIELD_PREP(ADIN2111_MDIO_ACC_MDIO_PRTAD, addr) |
	      FIELD_PREP(ADIN2111_MDIO_ACC_MDIO_DEVAD, regnum) |
	      ADIN2111_MDIO_ACC_MDIO_TRCNT;

	ret = adin2111_write_reg(priv, ADIN2111_MDIO_ACC, val);
	if (ret)
		goto out;

	/* Wait for completion */
	ret = adin2111_mdio_wait_ready(priv);
	if (ret)
		goto out;

	/* Read the result */
	ret = adin2111_read_reg(priv, ADIN2111_MDIO_ACC, &val);
	if (ret)
		goto out;

	ret = FIELD_GET(ADIN2111_MDIO_ACC_MDIO_DATA, val);

out:
	mutex_unlock(&priv->lock);
	return ret;
}

int adin2111_mdio_write(struct mii_bus *bus, int addr, int regnum, u16 val)
{
	struct adin2111_priv *priv = bus->priv;
	u32 mdio_val;
	int ret;

	mutex_lock(&priv->lock);

	/* Wait for any ongoing MDIO transaction */
	ret = adin2111_mdio_wait_ready(priv);
	if (ret)
		goto out;

	/* Setup MDIO write transaction */
	mdio_val = FIELD_PREP(ADIN2111_MDIO_ACC_MDIO_ST, ADIN2111_MDIO_ST_CLAUSE_22) |
		   FIELD_PREP(ADIN2111_MDIO_ACC_MDIO_OP, ADIN2111_MDIO_OP_WR) |
		   FIELD_PREP(ADIN2111_MDIO_ACC_MDIO_PRTAD, addr) |
		   FIELD_PREP(ADIN2111_MDIO_ACC_MDIO_DEVAD, regnum) |
		   FIELD_PREP(ADIN2111_MDIO_ACC_MDIO_DATA, val) |
		   ADIN2111_MDIO_ACC_MDIO_TRCNT;

	ret = adin2111_write_reg(priv, ADIN2111_MDIO_ACC, mdio_val);
	if (ret)
		goto out;

	/* Wait for completion */
	ret = adin2111_mdio_wait_ready(priv);

out:
	mutex_unlock(&priv->lock);
	return ret;
}

static void adin2111_link_change(struct phy_device *phydev)
{
	struct adin2111_port *port = phydev->priv;
	struct net_device *netdev = port->netdev;

	phy_print_status(phydev);

	if (phydev->link) {
		netif_carrier_on(netdev);
		netif_start_queue(netdev);
	} else {
		netif_carrier_off(netdev);
		netif_stop_queue(netdev);
	}
}

static int adin2111_phy_connect_port(struct adin2111_priv *priv, int port_num)
{
	struct adin2111_port *port = &priv->ports[port_num];
	struct phy_device *phydev;
	char phy_id[MII_BUS_ID_SIZE + 3];

	snprintf(phy_id, sizeof(phy_id), PHY_ID_FMT,
		 priv->mii_bus->id, port_num + 1);

	phydev = phy_connect(port->netdev, phy_id, adin2111_link_change,
			     PHY_INTERFACE_MODE_INTERNAL);
	if (IS_ERR(phydev)) {
		dev_err(&priv->spi->dev, "Failed to connect PHY for port %d: %ld\n",
			port_num, PTR_ERR(phydev));
		return PTR_ERR(phydev);
	}

	/* Configure PHY capabilities */
	phy_remove_link_mode(phydev, ETHTOOL_LINK_MODE_1000baseT_Half_BIT);
	phy_remove_link_mode(phydev, ETHTOOL_LINK_MODE_1000baseT_Full_BIT);
	phy_set_max_speed(phydev, SPEED_100);

	phydev->priv = port;
	port->phydev = phydev;

	dev_info(&priv->spi->dev, "PHY connected for port %d: %s\n",
		 port_num, phydev_name(phydev));

	return 0;
}

int adin2111_phy_init(struct adin2111_priv *priv, int port)
{
	struct mii_bus *mii_bus;
	int ret, i;

	mii_bus = devm_mdiobus_alloc(&priv->spi->dev);
	if (!mii_bus)
		return -ENOMEM;

	mii_bus->name = "ADIN2111 MDIO";
	mii_bus->read = adin2111_mdio_read;
	mii_bus->write = adin2111_mdio_write;
	mii_bus->priv = priv;
	mii_bus->parent = &priv->spi->dev;
	snprintf(mii_bus->id, MII_BUS_ID_SIZE, "%s", dev_name(&priv->spi->dev));

	/* Internal PHYs are at addresses 1 and 2 */
	mii_bus->phy_mask = 0xFFFFFFFC;  /* Allow only addresses 1 and 2 */

	ret = devm_mdiobus_register(&priv->spi->dev, mii_bus);
	if (ret) {
		dev_err(&priv->spi->dev, "Failed to register MDIO bus: %d\n", ret);
		return ret;
	}

	priv->mii_bus = mii_bus;

	/* Connect PHYs in switch mode */
	if (priv->switch_mode) {
		for (i = 0; i < ADIN2111_PORTS; i++) {
			if (priv->ports[i].netdev) {
				ret = adin2111_phy_connect_port(priv, i);
				if (ret)
					return ret;
			}
		}
	}

	dev_info(&priv->spi->dev, "PHY initialization completed\n");
	return 0;
}

void adin2111_phy_uninit(struct adin2111_priv *priv, int port)
{
	int i;

	if (priv->switch_mode) {
		for (i = 0; i < ADIN2111_PORTS; i++) {
			if (priv->ports[i].netdev && priv->ports[i].phydev) {
				phy_disconnect(priv->ports[i].phydev);
				priv->ports[i].phydev = NULL;
			}
		}
	}

	/* MDIO bus is automatically cleaned up by devm */
}

MODULE_DESCRIPTION("ADIN2111 MDIO/PHY Management");
MODULE_AUTHOR("Analog Devices Inc.");
MODULE_LICENSE("GPL");
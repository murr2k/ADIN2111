// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Link State Management
 * Handles PHY link state changes for G6
 */

#include <linux/netdevice.h>
#include <linux/workqueue.h>
#include <linux/phy.h>

#include "adin2111.h"
#include "adin2111_regs.h"

/* External functions */
extern int adin2111_read_reg(struct adin2111_priv *priv, u32 reg, u32 *val);
extern int adin2111_mdio_read(struct mii_bus *bus, int phy_id, int reg);

/* PHY registers */
#define MII_BMSR	0x01	/* Basic mode status register */
#define BMSR_LSTATUS	0x0004	/* Link status */

/* Link polling work */
static void adin2111_link_work(struct work_struct *work)
{
	struct adin2111_priv *priv = container_of(work, struct adin2111_priv, 
						   link_work.work);
	struct net_device *netdev;
	bool link_up = false;
	int ret, i;
	u16 bmsr;

	mutex_lock(&priv->lock);

	/* Check link status via MDIO for each PHY */
	for (i = 0; i < ADIN2111_PORTS; i++) {
		if (!priv->mii_bus)
			break;
			
		/* Read PHY status */
		ret = adin2111_mdio_read(priv->mii_bus, priv->phy_addr[i], MII_BMSR);
		if (ret < 0)
			continue;
		
		bmsr = ret;
		
		/* Check link status bit */
		if (bmsr & BMSR_LSTATUS) {
			link_up = true;
			dev_dbg(&priv->spi->dev, "PHY %d link up\n", i);
		} else {
			dev_dbg(&priv->spi->dev, "PHY %d link down\n", i);
		}
		
		/* Update port-specific netdev if in dual MAC mode */
		if (priv->mode == ADIN2111_MODE_DUAL && priv->ports[i].netdev) {
			netdev = priv->ports[i].netdev;
			if (bmsr & BMSR_LSTATUS) {
				if (!netif_carrier_ok(netdev)) {
					netif_carrier_on(netdev);
					netif_wake_queue(netdev);
					dev_info(&priv->spi->dev, "%s: link up\n", 
						 netdev->name);
				}
			} else {
				if (netif_carrier_ok(netdev)) {
					netif_carrier_off(netdev);
					netif_stop_queue(netdev);
					dev_info(&priv->spi->dev, "%s: link down\n",
						 netdev->name);
				}
			}
		}
	}

	/* For switch mode, report link if any port is up */
	if (priv->mode == ADIN2111_MODE_SWITCH && priv->netdev) {
		netdev = priv->netdev;
		if (link_up) {
			if (!netif_carrier_ok(netdev)) {
				netif_carrier_on(netdev);
				netif_wake_queue(netdev);
				dev_info(&priv->spi->dev, "%s: link up\n", netdev->name);
			}
		} else {
			if (netif_carrier_ok(netdev)) {
				netif_carrier_off(netdev);
				netif_stop_queue(netdev);
				dev_info(&priv->spi->dev, "%s: link down\n", netdev->name);
			}
		}
	}

	mutex_unlock(&priv->lock);

	/* Schedule next poll (1 second interval) */
	schedule_delayed_work(&priv->link_work, HZ);
}

/* Link interrupt handler for PHY state changes */
void adin2111_link_interrupt(struct adin2111_priv *priv)
{
	/* Cancel any pending work and schedule immediate check */
	cancel_delayed_work(&priv->link_work);
	schedule_delayed_work(&priv->link_work, 0);
}

/* Initialize link state monitoring */
int adin2111_link_init(struct adin2111_priv *priv)
{
	/* Initialize delayed work for link polling */
	INIT_DELAYED_WORK(&priv->link_work, adin2111_link_work);
	
	/* Start link monitoring */
	schedule_delayed_work(&priv->link_work, 0);
	
	return 0;
}

/* Stop link state monitoring */
void adin2111_link_uninit(struct adin2111_priv *priv)
{
	cancel_delayed_work_sync(&priv->link_work);
}

/* Force link state update (for testing) */
void adin2111_force_link_state(struct adin2111_priv *priv, int port, bool up)
{
	struct net_device *netdev = NULL;
	
	if (port >= 0 && port < ADIN2111_PORTS && priv->ports[port].netdev) {
		netdev = priv->ports[port].netdev;
	} else if (priv->netdev) {
		netdev = priv->netdev;
	}
	
	if (!netdev)
		return;
		
	if (up) {
		if (!netif_carrier_ok(netdev)) {
			netif_carrier_on(netdev);
			netif_wake_queue(netdev);
			dev_info(&priv->spi->dev, "%s: link forced up\n", netdev->name);
		}
	} else {
		if (netif_carrier_ok(netdev)) {
			netif_carrier_off(netdev);
			netif_stop_queue(netdev);
			dev_info(&priv->spi->dev, "%s: link forced down\n", netdev->name);
		}
	}
}

MODULE_DESCRIPTION("ADIN2111 Link State Management");
MODULE_AUTHOR("Analog Devices Inc.");
MODULE_LICENSE("GPL");
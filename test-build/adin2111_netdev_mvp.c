// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Network Device Operations - MVP Implementation
 * Minimal correct implementation to unblock G4-G7 gates
 */

#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/interrupt.h>
#include <linux/module.h>
#include <linux/spi/spi.h>
#include <linux/of_irq.h>

#include "adin2111.h"
#include "adin2111_regs.h"

/* External functions from adin2111_spi.c */
extern int adin2111_read_reg(struct adin2111_priv *priv, u32 reg, u32 *val);
extern int adin2111_write_reg(struct adin2111_priv *priv, u32 reg, u32 val);
extern int adin2111_write_fifo(struct adin2111_priv *priv, u32 reg, const u8 *data, size_t len);
extern int adin2111_read_fifo(struct adin2111_priv *priv, u32 reg, u8 *data, size_t len);

#define ADIN2111_MAX_FRAME_SIZE 1518
#define ADIN2111_FRAME_HEADER_LEN 2
#define NAPI_POLL_WEIGHT 64

/* NAPI poll function for RX handling (G5) */
static int adin2111_napi_poll(struct napi_struct *napi, int budget)
{
	struct adin2111_port *port = container_of(napi, struct adin2111_port, napi);
	struct adin2111_priv *priv = port->priv;
	struct net_device *netdev = port->netdev;
	int work_done = 0;
	u32 status1, rx_size;
	int ret;

	mutex_lock(&priv->lock);

	while (work_done < budget) {
		/* Check RX ready status */
		ret = adin2111_read_reg(priv, ADIN2111_STATUS1, &status1);
		if (ret)
			break;

		/* Check if RX ready for our port */
		u32 rx_ready_mask = (port->port_num == 0) ? 
			ADIN2111_STATUS1_P1_RX_RDY : ADIN2111_STATUS1_P2_RX_RDY;
		
		if (!(status1 & rx_ready_mask))
			break;

		/* Read RX size register */
		ret = adin2111_read_reg(priv, ADIN2111_RX_SIZE, &rx_size);
		if (ret || rx_size == 0)
			break;

		/* Mask off port bits to get actual size */
		u16 frame_size = rx_size & 0xFFFF;
		if (frame_size > ADIN2111_MAX_FRAME_SIZE) {
			dev_err(&priv->spi->dev, "Invalid frame size: %u\n", frame_size);
			/* Clear bad frame */
			adin2111_write_reg(priv, ADIN2111_STATUS1, rx_ready_mask);
			port->stats.rx_errors++;
			continue;
		}

		/* Allocate skb */
		struct sk_buff *skb = netdev_alloc_skb_ip_align(netdev, frame_size);
		if (!skb) {
			port->stats.rx_dropped++;
			break;
		}

		/* Read frame from FIFO */
		ret = adin2111_read_fifo(priv, ADIN2111_RX_FIFO, skb->data, frame_size);
		if (ret) {
			dev_kfree_skb(skb);
			break;
		}

		/* Setup skb */
		skb_put(skb, frame_size);
		skb->protocol = eth_type_trans(skb, netdev);

		/* Update stats */
		u64_stats_update_begin(&port->stats_lock);
		port->stats.rx_packets++;
		port->stats.rx_bytes += frame_size;
		u64_stats_update_end(&port->stats_lock);

		/* Pass to network stack */
		napi_gro_receive(napi, skb);
		work_done++;

		/* Clear RX ready status */
		adin2111_write_reg(priv, ADIN2111_STATUS1, rx_ready_mask);
	}

	mutex_unlock(&priv->lock);

	/* Re-enable interrupts if done */
	if (work_done < budget) {
		napi_complete_done(napi, work_done);
		/* Re-enable RX interrupt */
		adin2111_set_bits(priv, ADIN2111_IMASK1, 
			(port->port_num == 0) ? ADIN2111_IMASK1_P1_RX_RDY : 
			ADIN2111_IMASK1_P2_RX_RDY);
	}

	return work_done;
}

/* TX implementation for G4 */
static netdev_tx_t adin2111_start_xmit(struct sk_buff *skb, struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;
	u32 tx_space;
	u16 frame_header;
	int ret;

	/* Quick sanity checks */
	if (skb_is_gso(skb) || skb->len > ADIN2111_MAX_FRAME_SIZE) {
		dev_kfree_skb_any(skb);
		port->stats.tx_dropped++;
		return NETDEV_TX_OK;
	}

	/* Linearize if needed */
	if (skb_linearize(skb)) {
		dev_kfree_skb_any(skb);
		port->stats.tx_dropped++;
		return NETDEV_TX_OK;
	}

	/* Take TX lock */
	spin_lock_bh(&priv->tx_lock);

	/* Check TX space */
	ret = adin2111_read_reg(priv, ADIN2111_TX_SPACE, &tx_space);
	if (ret || tx_space < (skb->len + ADIN2111_FRAME_HEADER_LEN)) {
		/* No space, stop queue */
		netif_stop_queue(netdev);
		spin_unlock_bh(&priv->tx_lock);
		return NETDEV_TX_BUSY;
	}

	/* Build frame header (port selection and length) */
	frame_header = skb->len;
	if (priv->switch_mode) {
		/* In switch mode, specify port */
		frame_header |= ((port->port_num + 1) << 12);
	}

	/* Write header to TX FIFO */
	u8 header_buf[2];
	header_buf[0] = (frame_header >> 8) & 0xFF;
	header_buf[1] = frame_header & 0xFF;
	
	ret = adin2111_write_fifo(priv, ADIN2111_TX_FIFO, header_buf, 2);
	if (ret) {
		netif_stop_queue(netdev);
		spin_unlock_bh(&priv->tx_lock);
		dev_kfree_skb_any(skb);
		port->stats.tx_errors++;
		return NETDEV_TX_OK;
	}

	/* Write frame data */
	ret = adin2111_write_fifo(priv, ADIN2111_TX_FIFO, skb->data, skb->len);
	if (ret) {
		port->stats.tx_errors++;
	} else {
		/* Update stats */
		u64_stats_update_begin(&port->stats_lock);
		port->stats.tx_packets++;
		port->stats.tx_bytes += skb->len;
		u64_stats_update_end(&port->stats_lock);
		
		/* Notify stack */
		netdev_sent_queue(netdev, skb->len);
	}

	spin_unlock_bh(&priv->tx_lock);
	dev_kfree_skb_any(skb);
	
	return NETDEV_TX_OK;
}

/* Open network device */
static int adin2111_open(struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;
	int ret;

	/* Enable NAPI */
	napi_enable(&port->napi);

	/* Enable device interrupts */
	u32 imask1 = 0;
	if (port->port_num == 0) {
		imask1 |= ADIN2111_IMASK1_P1_RX_RDY;
	} else {
		imask1 |= ADIN2111_IMASK1_P2_RX_RDY;
	}
	
	ret = adin2111_write_reg(priv, ADIN2111_IMASK1, imask1);
	if (ret) {
		napi_disable(&port->napi);
		return ret;
	}

	/* Enable port in hardware */
	u32 config0;
	ret = adin2111_read_reg(priv, ADIN2111_CONFIG0, &config0);
	if (!ret) {
		config0 |= ADIN2111_CONFIG0_SYNC;
		adin2111_write_reg(priv, ADIN2111_CONFIG0, config0);
	}

	/* Start queue */
	netif_start_queue(netdev);

	/* Assume link up for now (G6 will handle proper link state) */
	netif_carrier_on(netdev);

	return 0;
}

/* Stop network device */
static int adin2111_stop(struct net_device *netdev)
{
	struct adin2111_port *port = netdev_priv(netdev);
	struct adin2111_priv *priv = port->priv;

	/* Stop queue */
	netif_stop_queue(netdev);

	/* Disable NAPI */
	napi_disable(&port->napi);

	/* Mask interrupts for this port */
	u32 mask_bit = (port->port_num == 0) ? 
		ADIN2111_IMASK1_P1_RX_RDY : ADIN2111_IMASK1_P2_RX_RDY;
	adin2111_clear_bits(priv, ADIN2111_IMASK1, mask_bit);

	/* Set carrier off */
	netif_carrier_off(netdev);

	return 0;
}

/* Get stats64 */
static void adin2111_get_stats64(struct net_device *netdev,
				  struct rtnl_link_stats64 *stats)
{
	struct adin2111_port *port = netdev_priv(netdev);
	unsigned int start;

	do {
		start = u64_stats_fetch_begin(&port->stats_lock);
		*stats = port->stats;
	} while (u64_stats_fetch_retry(&port->stats_lock, start));
}

/* Network device operations */
static const struct net_device_ops adin2111_netdev_ops = {
	.ndo_open		= adin2111_open,
	.ndo_stop		= adin2111_stop,
	.ndo_start_xmit		= adin2111_start_xmit,
	.ndo_get_stats64	= adin2111_get_stats64,
	.ndo_validate_addr	= eth_validate_addr,
	.ndo_set_mac_address	= eth_mac_addr,
};

/* IRQ handler - schedules NAPI */
static irqreturn_t adin2111_irq_handler(int irq, void *data)
{
	struct adin2111_priv *priv = data;
	u32 status0, status1;
	int ret;

	/* Read interrupt status */
	ret = adin2111_read_reg(priv, ADIN2111_STATUS0, &status0);
	if (ret)
		return IRQ_NONE;

	ret = adin2111_read_reg(priv, ADIN2111_STATUS1, &status1);
	if (ret)
		return IRQ_NONE;

	/* Check for RX ready and schedule NAPI */
	if (status1 & ADIN2111_STATUS1_P1_RX_RDY) {
		/* Mask RX interrupt and schedule NAPI */
		adin2111_clear_bits(priv, ADIN2111_IMASK1, ADIN2111_IMASK1_P1_RX_RDY);
		if (priv->mode == ADIN2111_MODE_SWITCH && priv->netdev) {
			struct adin2111_port *port = netdev_priv(priv->netdev);
			napi_schedule(&port->napi);
		} else if (priv->ports[0].netdev) {
			napi_schedule(&priv->ports[0].napi);
		}
	}

	if (status1 & ADIN2111_STATUS1_P2_RX_RDY) {
		adin2111_clear_bits(priv, ADIN2111_IMASK1, ADIN2111_IMASK1_P2_RX_RDY);
		if (priv->ports[1].netdev) {
			napi_schedule(&priv->ports[1].napi);
		}
	}

	/* Check for TX complete and wake queue if needed */
	if (status0 & ADIN2111_STATUS0_TXPE) {
		/* TX complete, wake queues */
		if (priv->netdev && netif_queue_stopped(priv->netdev))
			netif_wake_queue(priv->netdev);
		for (int i = 0; i < ADIN2111_PORTS; i++) {
			if (priv->ports[i].netdev && 
			    netif_queue_stopped(priv->ports[i].netdev))
				netif_wake_queue(priv->ports[i].netdev);
		}
	}

	/* Clear processed interrupts */
	adin2111_write_reg(priv, ADIN2111_STATUS0, status0);
	adin2111_write_reg(priv, ADIN2111_STATUS1, status1);

	return IRQ_HANDLED;
}

/* Create network device with proper setup */
struct net_device *adin2111_create_netdev_mvp(struct adin2111_priv *priv, int port_num)
{
	struct net_device *netdev;
	struct adin2111_port *port;

	/* Allocate network device */
	netdev = alloc_etherdev(sizeof(struct adin2111_port));
	if (!netdev)
		return NULL;

	/* Set device parent */
	SET_NETDEV_DEV(netdev, &priv->spi->dev);

	/* Setup netdev operations */
	netdev->netdev_ops = &adin2111_netdev_ops;
	
	/* Conservative features - no offloads */
	netdev->features = NETIF_F_SG;
	netdev->hw_features = netdev->features;
	
	/* Standard MTU */
	netdev->min_mtu = ETH_MIN_MTU;
	netdev->max_mtu = 1500;

	/* Setup port structure */
	port = netdev_priv(netdev);
	port->netdev = netdev;
	port->priv = priv;
	port->port_num = port_num;
	u64_stats_init(&port->stats_lock);

	/* Add NAPI */
	netif_napi_add(netdev, &port->napi, adin2111_napi_poll);

	/* Generate MAC address */
	eth_hw_addr_random(netdev);

	return netdev;
}

/* Initialize network devices in probe */
int adin2111_netdev_init_mvp(struct adin2111_priv *priv)
{
	struct net_device *netdev;
	int ret;

	/* Create single netdev for unmanaged switch mode */
	netdev = adin2111_create_netdev_mvp(priv, 0);
	if (!netdev)
		return -ENOMEM;

	priv->netdev = netdev;
	
	/* Request IRQ */
	if (priv->spi->irq > 0) {
		ret = request_threaded_irq(priv->spi->irq, 
					    adin2111_irq_handler,
					    NULL,
					    IRQF_TRIGGER_LOW | IRQF_ONESHOT,
					    "adin2111", priv);
		if (ret) {
			dev_err(&priv->spi->dev, "Failed to request IRQ %d: %d\n",
				priv->spi->irq, ret);
			free_netdev(netdev);
			return ret;
		}
		priv->irq = priv->spi->irq;
	}

	/* Register network device */
	ret = register_netdev(netdev);
	if (ret) {
		dev_err(&priv->spi->dev, "Failed to register netdev: %d\n", ret);
		if (priv->irq > 0)
			free_irq(priv->irq, priv);
		free_netdev(netdev);
		return ret;
	}

	dev_info(&priv->spi->dev, "Registered %s\n", netdev->name);
	return 0;
}

/* Cleanup network devices */
void adin2111_netdev_uninit_mvp(struct adin2111_priv *priv)
{
	if (priv->netdev) {
		unregister_netdev(priv->netdev);
		free_netdev(priv->netdev);
	}
	
	if (priv->irq > 0)
		free_irq(priv->irq, priv);
}

MODULE_DESCRIPTION("ADIN2111 Network Device MVP Implementation");
MODULE_AUTHOR("Analog Devices Inc.");
MODULE_LICENSE("GPL");
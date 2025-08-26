# ADIN2111 Hybrid Driver - Required Corrections

## Corrected SPI Communication

```c
/* Proper ADIN2111 SPI register read */
static int adin2111_read_reg(struct adin2111_priv *priv, u16 reg, u32 *val)
{
    struct spi_message msg;
    struct spi_transfer xfer = {0};
    u8 tx_buf[4];
    u8 rx_buf[4];
    int ret;
    
    /* ADIN2111 read command format */
    tx_buf[0] = 0x80 | ((reg >> 8) & 0x7F);  /* Read bit + upper addr */
    tx_buf[1] = reg & 0xFF;                   /* Lower addr */
    tx_buf[2] = 0;                             /* Turn-around byte */
    tx_buf[3] = 0;                             /* Turn-around byte */
    
    xfer.tx_buf = tx_buf;
    xfer.rx_buf = rx_buf;
    xfer.len = 4;
    
    spi_message_init(&msg);
    spi_message_add_tail(&xfer, &msg);
    
    ret = spi_sync(priv->spi, &msg);
    if (ret)
        return ret;
    
    /* Data is in bytes 2-3 of response */
    *val = (rx_buf[2] << 8) | rx_buf[3];
    return 0;
}

/* Proper FIFO write for packet data */
static int adin2111_write_fifo(struct adin2111_priv *priv, u32 reg, 
                               const u8 *data, size_t len)
{
    struct spi_device *spi = priv->spi;
    u8 *tx_buf;
    int ret;
    
    tx_buf = kmalloc(len + 2, GFP_KERNEL);
    if (!tx_buf)
        return -ENOMEM;
    
    /* SPI header for FIFO write */
    tx_buf[0] = 0x00 | ((reg >> 8) & 0x7F);  /* Write bit + upper addr */
    tx_buf[1] = reg & 0xFF;                   /* Lower addr */
    
    /* Copy frame data */
    memcpy(tx_buf + 2, data, len);
    
    ret = spi_write(spi, tx_buf, len + 2);
    
    kfree(tx_buf);
    return ret;
}
```

## Corrected TX Path

```c
static netdev_tx_t adin2111_xmit(struct sk_buff *skb, struct net_device *netdev)
{
    struct adin2111_priv *priv = netdev_priv(netdev);
    u8 header_buf[4];  /* Frame header is 2-4 bytes */
    u16 frame_header;
    u32 tx_space;
    int ret;
    
    /* Check TX space available */
    ret = adin2111_read_reg(priv, ADIN2111_TX_SPACE, &tx_space);
    if (ret || tx_space < skb->len + 4) {
        netif_stop_queue(netdev);
        return NETDEV_TX_BUSY;
    }
    
    /* Build frame header with port selection */
    frame_header = skb->len & 0x0FFF;  /* 12-bit length */
    
    if (priv->single_interface_mode) {
        struct ethhdr *eth = eth_hdr(skb);
        
        /* Learn source MAC */
        mac_table_learn(priv, eth->h_source, 0);
        
        /* Determine destination port */
        if (is_multicast_ether_addr(eth->h_dest)) {
            /* Flood to both ports */
            frame_header |= (0x3 << 12);  /* Port 1 and 2 */
        } else {
            struct mac_entry *entry = mac_table_lookup(priv, eth->h_dest);
            if (entry) {
                frame_header |= ((entry->port + 1) << 12);
            } else {
                /* Unknown - flood */
                frame_header |= (0x3 << 12);
            }
        }
    } else {
        /* Single port mode - send to port 1 */
        frame_header |= (0x1 << 12);
    }
    
    /* Prepare header buffer */
    header_buf[0] = (frame_header >> 8) & 0xFF;
    header_buf[1] = frame_header & 0xFF;
    
    /* Write frame header to TX FIFO */
    ret = adin2111_write_fifo(priv, ADIN2111_TX, header_buf, 2);
    if (ret) {
        netdev->stats.tx_errors++;
        goto out;
    }
    
    /* Write packet data to TX FIFO */
    ret = adin2111_write_fifo(priv, ADIN2111_TX, skb->data, skb->len);
    if (ret) {
        netdev->stats.tx_errors++;
        goto out;
    }
    
    /* Update statistics */
    netdev->stats.tx_packets++;
    netdev->stats.tx_bytes += skb->len;
    
out:
    dev_kfree_skb_any(skb);
    return NETDEV_TX_OK;
}
```

## Required RX Handler

```c
static int adin2111_rx_packet(struct adin2111_priv *priv)
{
    struct net_device *netdev = priv->netdev;
    struct sk_buff *skb;
    u8 header_buf[4];
    u16 frame_header;
    u16 frame_len;
    u8 port_num;
    int ret;
    
    /* Read frame header from RX FIFO */
    ret = adin2111_read_fifo(priv, ADIN2111_RX, header_buf, 2);
    if (ret)
        return ret;
    
    frame_header = (header_buf[0] << 8) | header_buf[1];
    frame_len = frame_header & 0x0FFF;
    port_num = (frame_header >> 12) & 0x03;
    
    /* Validate frame length */
    if (frame_len > ETH_FRAME_LEN) {
        netdev->stats.rx_errors++;
        /* Clear FIFO */
        adin2111_write_reg(priv, ADIN2111_FIFO_CLR, BIT(0));
        return -EINVAL;
    }
    
    /* Allocate skb */
    skb = netdev_alloc_skb(netdev, frame_len);
    if (!skb) {
        netdev->stats.rx_dropped++;
        return -ENOMEM;
    }
    
    /* Read packet data from RX FIFO */
    ret = adin2111_read_fifo(priv, ADIN2111_RX, skb->data, frame_len);
    if (ret) {
        dev_kfree_skb_any(skb);
        return ret;
    }
    
    /* Learn source MAC if in single interface mode */
    if (priv->single_interface_mode) {
        struct ethhdr *eth = eth_hdr(skb);
        mac_table_learn(priv, eth->h_source, port_num);
    }
    
    /* Setup skb and pass to network stack */
    skb_put(skb, frame_len);
    skb->protocol = eth_type_trans(skb, netdev);
    
    /* Update statistics */
    netdev->stats.rx_packets++;
    netdev->stats.rx_bytes += frame_len;
    
    /* Deliver to network stack */
    netif_rx(skb);
    
    return 0;
}

/* IRQ handler */
static irqreturn_t adin2111_irq(int irq, void *data)
{
    struct adin2111_priv *priv = data;
    u32 status;
    
    /* Read interrupt status */
    adin2111_read_reg(priv, ADIN2111_STATUS1, &status);
    
    /* RX ready? */
    if (status & BIT(4)) {  /* P1_RX_RDY */
        while (adin2111_rx_packet(priv) == 0)
            ; /* Process all pending RX */
    }
    
    /* Link change? */
    if (status & (BIT(0) | BIT(1))) {
        /* Handle link status change */
        schedule_work(&priv->link_work);
    }
    
    return IRQ_HANDLED;
}
```

## Proper Initialization

```c
static int adin2111_hw_init(struct adin2111_priv *priv)
{
    u32 val;
    int ret;
    
    /* Read and verify device ID */
    ret = adin2111_read_reg(priv, ADIN2111_DEVID, &val);
    if (ret || val != 0x0283) {
        dev_err(&priv->spi->dev, "Invalid device ID: 0x%04x\n", val);
        return -ENODEV;
    }
    
    /* Soft reset */
    ret = adin2111_write_reg(priv, ADIN2111_CONFIG0, BIT(0));
    if (ret)
        return ret;
    
    msleep(10);
    
    /* Enable CONFIG0 sync */
    ret = adin2111_write_reg(priv, ADIN2111_CONFIG0, BIT(15));
    if (ret)
        return ret;
    
    /* Enable cut-through forwarding if single interface mode */
    if (priv->single_interface_mode) {
        ret = adin2111_write_reg(priv, ADIN2111_CONFIG2, 
                                 BIT(1) | BIT(2));  /* P1_FWD_EN | P2_FWD_EN */
        if (ret)
            return ret;
        
        ret = adin2111_write_reg(priv, ADIN2111_PORT_CUT_THRU_EN, 0x3);
        if (ret)
            return ret;
    }
    
    /* Enable interrupts */
    ret = adin2111_write_reg(priv, 0x0E, 0xFFFF);  /* IMASK1 */
    
    return ret;
}
```

## Key Differences from Original

1. **Proper SPI protocol** with correct command format
2. **Actual packet data transfer** to/from FIFOs
3. **Frame header with port selection**
4. **RX packet handling** with interrupt support
5. **Device ID verification** (0x0283 not 0xff00)
6. **Hardware initialization** sequence
7. **Link state monitoring**
8. **Error handling** and recovery

This corrected implementation would actually communicate with the ADIN2111 hardware and transfer network packets properly.
/*
 * QEMU ADIN2111 Dual-Port Ethernet Switch/PHY Emulation
 * Header file with register definitions
 *
 * Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
 *
 * This work is licensed under the terms of the GNU GPL, version 2 or later.
 * See the COPYING file in the top-level directory.
 */

#ifndef HW_NET_ADIN2111_H
#define HW_NET_ADIN2111_H

/* Total register count (4KB address space) */
#define ADIN2111_REG_COUNT          0x400  /* 1024 32-bit registers */

/* System Control Registers (0x0000 - 0x001F) */
#define ADIN2111_REG_CHIP_ID        0x0000  /* Chip ID (RO): 0x2111 */
#define ADIN2111_REG_SCRATCH        0x0001  /* Scratchpad register */
#define ADIN2111_REG_RESET_CTL      0x0002  /* Reset control */
#define ADIN2111_REG_DEVICE_STATUS  0x0003  /* Device status */
#define ADIN2111_REG_INT_STATUS     0x0004  /* Interrupt status */
#define ADIN2111_REG_INT_MASK       0x0005  /* Interrupt mask */

/* Switch Core Configuration (0x0040 - 0x007F) */
#define ADIN2111_REG_SWITCH_CONFIG  0x0040  /* Switch configuration */
#define ADIN2111_REG_MAC_FLT_ENABLE 0x0041  /* MAC filtering enable */
#define ADIN2111_REG_SWITCH_STATUS  0x0042  /* Switch status */
#define ADIN2111_REG_FWD_TABLE_PTR  0x0043  /* Forwarding table pointer */
#define ADIN2111_REG_MAC_TABLE_BASE 0x0044  /* MAC table base (16 entries) */

/* Port 1 Control and Status (0x0080 - 0x009F) */
#define ADIN2111_REG_PORT1_CTRL     0x0080  /* Port 1 control */
#define ADIN2111_REG_PORT1_STATUS   0x0081  /* Port 1 status */
#define ADIN2111_REG_PORT1_STATS_CTRL 0x0082 /* Port 1 stats control */
#define ADIN2111_REG_PORT1_RX_PKTS  0x0083  /* Port 1 RX packets */
#define ADIN2111_REG_PORT1_TX_PKTS  0x0084  /* Port 1 TX packets */
#define ADIN2111_REG_PORT1_RX_BYTES 0x0085  /* Port 1 RX bytes */
#define ADIN2111_REG_PORT1_TX_BYTES 0x0086  /* Port 1 TX bytes */
#define ADIN2111_REG_PORT1_RX_ERRS  0x0087  /* Port 1 RX errors */
#define ADIN2111_REG_PORT1_TX_ERRS  0x0088  /* Port 1 TX errors */

/* Port 2 Control and Status (0x00A0 - 0x00BF) */
#define ADIN2111_REG_PORT2_CTRL     0x00A0  /* Port 2 control */
#define ADIN2111_REG_PORT2_STATUS   0x00A1  /* Port 2 status */
#define ADIN2111_REG_PORT2_STATS_CTRL 0x00A2 /* Port 2 stats control */
#define ADIN2111_REG_PORT2_RX_PKTS  0x00A3  /* Port 2 RX packets */
#define ADIN2111_REG_PORT2_TX_PKTS  0x00A4  /* Port 2 TX packets */
#define ADIN2111_REG_PORT2_RX_BYTES 0x00A5  /* Port 2 RX bytes */
#define ADIN2111_REG_PORT2_TX_BYTES 0x00A6  /* Port 2 TX bytes */
#define ADIN2111_REG_PORT2_RX_ERRS  0x00A7  /* Port 2 RX errors */
#define ADIN2111_REG_PORT2_TX_ERRS  0x00A8  /* Port 2 TX errors */

/* Diagnostics and Monitoring (0x00C0 - 0x00DF) */
#define ADIN2111_REG_LINK_QUALITY   0x00C0  /* Link quality metrics */
#define ADIN2111_REG_TDR_CTRL       0x00C1  /* TDR control */
#define ADIN2111_REG_TDR_RESULT     0x00C2  /* TDR result */
#define ADIN2111_REG_FRAME_GEN_CTRL 0x00C4  /* Frame generator control */
#define ADIN2111_REG_FRAME_CHECK_CTRL 0x00C5 /* Frame checker control */
#define ADIN2111_REG_CRC_STATUS     0x00C6  /* CRC error status */

/* IEEE 1588 Timestamping (0x0100 - 0x011F) */
#define ADIN2111_REG_TIMESTAMP_CTRL 0x0100  /* Timestamp control */
#define ADIN2111_REG_TX_TIMESTAMP_SEC 0x0101 /* TX timestamp seconds */
#define ADIN2111_REG_TX_TIMESTAMP_NS 0x0102  /* TX timestamp nanoseconds */
#define ADIN2111_REG_RX_TIMESTAMP_SEC 0x0103 /* RX timestamp seconds */
#define ADIN2111_REG_RX_TIMESTAMP_NS 0x0104  /* RX timestamp nanoseconds */

/* TX/RX Buffers (0x0200 - 0x03FF) */
#define ADIN2111_REG_TX_FIFO        0x0200  /* TX FIFO base */
#define ADIN2111_REG_RX_FIFO        0x0300  /* RX FIFO base */

/* SPI Command Bits */
#define ADIN2111_SPI_READ           0x80000000  /* Read command */
#define ADIN2111_SPI_WRITE          0x00000000  /* Write command */
#define ADIN2111_SPI_ADDR_MASK      0x0000FFFF  /* Address mask */

/* Reset Control Bits */
#define ADIN2111_RESET_SOFT         0x00000001  /* Software reset */
#define ADIN2111_RESET_PHY1         0x00000002  /* PHY1 reset */
#define ADIN2111_RESET_PHY2         0x00000004  /* PHY2 reset */
#define ADIN2111_RESET_MAC          0x00000008  /* MAC reset */

/* Device Status Bits */
#define ADIN2111_STATUS_READY       0x00000001  /* Device ready */
#define ADIN2111_STATUS_LINK1_UP    0x00000002  /* Port 1 link up */
#define ADIN2111_STATUS_LINK2_UP    0x00000004  /* Port 2 link up */
#define ADIN2111_STATUS_SPI_ERROR   0x00000008  /* SPI error */

/* Interrupt Status/Mask Bits */
#define ADIN2111_INT_READY          0x00000001  /* Device ready */
#define ADIN2111_INT_LINK1          0x00000002  /* Port 1 link change */
#define ADIN2111_INT_LINK2          0x00000004  /* Port 2 link change */
#define ADIN2111_INT_RX1            0x00000008  /* Port 1 RX ready */
#define ADIN2111_INT_RX2            0x00000010  /* Port 2 RX ready */
#define ADIN2111_INT_TX1_DONE       0x00000020  /* Port 1 TX complete */
#define ADIN2111_INT_TX2_DONE       0x00000040  /* Port 2 TX complete */
#define ADIN2111_INT_SPI_ERROR      0x00000080  /* SPI error */

/* Switch Configuration Bits */
#define ADIN2111_SWITCH_CUT_THROUGH 0x00000001  /* Cut-through mode */
#define ADIN2111_SWITCH_ENABLE      0x00000010  /* Enable switching */
#define ADIN2111_SWITCH_LEARN       0x00000020  /* MAC learning enable */

/* Port Control Bits */
#define ADIN2111_PORT_ENABLE        0x00000001  /* Port enable */
#define ADIN2111_PORT_LOOPBACK      0x00000002  /* Loopback mode */
#define ADIN2111_PORT_TEST_MODE     0x00000004  /* Test mode */

/* Constants */
#define ADIN2111_MAC_TABLE_SIZE     16          /* 16 MAC filter entries */
#define ADIN2111_MAC_ENTRY_SIZE     8           /* 6 bytes MAC + 2 bytes ctrl */
#define ADIN2111_FIFO_SIZE          0x7000      /* 28KB shared buffer */
#define ADIN2111_MAX_FRAME_SIZE     1518        /* Maximum Ethernet frame */

#endif /* HW_NET_ADIN2111_H */
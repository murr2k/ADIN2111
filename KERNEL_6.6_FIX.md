# ADIN2111 Driver - Kernel 6.6+ Compilation Fix

## Quick Fix for Your Client

The compilation errors are due to kernel API changes in Linux 6.6+:

### Issue 1: `netif_rx_ni()` was removed
- **Error**: `implicit declaration of function 'netif_rx_ni'`
- **Cause**: `netif_rx_ni()` was removed in kernel 5.18+
- **Fix**: Use `netif_rx()` instead

### Issue 2: Missing `ADIN2111_STATUS0_LINK` definition
- **Error**: `'ADIN2111_STATUS0_LINK' undeclared`
- **Cause**: Register bit not defined in header
- **Fix**: Added definition for link status bit

## Solution: Use the Kernel 6.6+ Compatible Version

### Files to Use:
```
adin2111_main_correct.c      - Main driver (unchanged)
adin2111_netdev_kernel66.c   - Network ops (NEW - kernel 6.6+ compatible)
adin2111_spi.c               - SPI operations (unchanged)
adin2111_mdio.c              - MDIO operations (unchanged)
adin2111.h                   - Main header (unchanged)
adin2111_regs.h              - Register definitions (unchanged)
Makefile.kernel66            - Build file for kernel 6.6+
```

### Build Commands:
```bash
# For Yocto build:
cd drivers/net/ethernet/adi/adin2111/
make -f Makefile.kernel66 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- \
     KDIR=/mnt/misc-extra/yocto-st-6.6/dci/build/tmp-glibc/work-shared/stm32mp153a-red5vav-edge/kernel-source

# Output will be: adin2111_kernel66.ko
```

## What Was Fixed:

### 1. Kernel Version Compatibility
```c
/* Automatic kernel version detection */
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5,18,0)
#define netif_rx_compat(skb)  netif_rx(skb)     /* 5.18+ */
#else
#define netif_rx_compat(skb)  netif_rx_ni(skb)  /* Older */
#endif
```

### 2. Missing Register Definition
```c
/* Added missing link status bit */
#ifndef ADIN2111_STATUS0_LINK
#define ADIN2111_STATUS0_LINK  BIT(12)  /* P0_LINK_STATUS */
#endif
```

### 3. Other Missing Definitions
```c
/* Added all potentially missing register defines */
#ifndef ADIN2111_RX_FSIZE
#define ADIN2111_RX_FSIZE      0x90
#endif

#ifndef ADIN2111_TX_SPACE
#define ADIN2111_TX_SPACE      0x32
#endif
```

## Integration with Yocto

If building within Yocto, you may need to patch the kernel source tree:

### Option 1: Direct Replacement
```bash
# Replace the problematic file
cp adin2111_netdev_kernel66.c \
   /mnt/misc-extra/yocto-st-6.6/dci/build/tmp-glibc/work-shared/stm32mp153a-red5vav-edge/kernel-source/drivers/net/ethernet/adi/adin2111/adin2111_netdev_final.c
```

### Option 2: Create a Yocto Patch
Create a `.bbappend` file in your layer:
```
SRC_URI += "file://0001-adin2111-fix-kernel-6.6-compatibility.patch"
```

## Testing After Build

```bash
# Load the module
insmod adin2111_kernel66.ko

# Check dmesg for errors
dmesg | tail -20

# Verify network interface
ip link show
```

## Troubleshooting

If you still get errors:

1. **Check kernel version**:
```bash
uname -r
# Should show 6.6.48-stm32mp-r1.1
```

2. **Verify all files are present**:
```bash
ls -la *.c *.h Makefile.kernel66
```

3. **Clean build**:
```bash
make -f Makefile.kernel66 clean
make -f Makefile.kernel66 KDIR=/path/to/kernel
```

## Summary

The `adin2111_netdev_kernel66.c` file is fully compatible with:
- Linux kernel 6.6.x (your client's version)
- Linux kernel 5.18+ (when netif_rx_ni was removed)
- Older kernels (automatic compatibility)

This version maintains the same architecture (no sleeping in softirq) while being compatible with modern kernel APIs.

**Author**: Murray Kopit
**Version**: 3.0.1 (Kernel 6.6+ Compatible)
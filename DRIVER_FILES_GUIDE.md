# ADIN2111 Driver Files Guide for Client

## Which Files to Use

### PRIMARY DRIVER FILES (USE THESE)

Your client should compile and use these files together as a complete driver:

1. **`adin2111.c`** - Main driver core (probe, init, hardware setup)
2. **`adin2111_spi.c`** - SPI communication layer  
3. **`adin2111_mdio.c`** - MDIO/PHY management
4. **`adin2111_atomic_fix.c`** - **CRITICAL**: Fixes the "scheduling while atomic" crash
5. **`adin2111.h`** - Main header with structures
6. **`adin2111_regs.h`** - Hardware register definitions

### CHOOSE ONE NETDEV IMPLEMENTATION:

**Option A (RECOMMENDED - Has the atomic fix integrated):**
- **`adin2111_netdev_fixed.c`** - Network device implementation WITH atomic context fixes
- **`adin2111_fixed.h`** - Header for fixed version

**Option B (Original - may still have atomic issues):**
- **`adin2111_netdev.c`** - Original network device implementation

## Build Instructions

### For In-Tree Build (Recommended)

Use the standard `Makefile`:

```bash
# In the kernel source tree
make M=drivers/net/ethernet/adi/adin2111 modules
```

### For Out-of-Tree Build

Use `Makefile.standalone`:

```bash
# In the driver directory
make -f Makefile.standalone KERNEL_DIR=/path/to/kernel
```

### Module Name

The compiled module will be: **`adin2111_driver.ko`**

## Complete File List for Compilation

```makefile
# From Makefile - these are the files that get compiled:
obj-m += adin2111_driver.o
adin2111_driver-objs := \
    adin2111.o \
    adin2111_spi.o \
    adin2111_mdio.o \
    adin2111_netdev_fixed.o \
    adin2111_atomic_fix.o
```

## Loading the Driver

```bash
# Remove any old driver
sudo rmmod adin2111_driver 2>/dev/null

# Load the fixed driver
sudo insmod adin2111_driver.ko

# Or with module parameters
sudo insmod adin2111_driver.ko tx_method=0  # 0=workqueue (safe), 1=async
```

## Critical Notes

1. **DO NOT** use `adin2111_netdev.c` alone - it has the atomic bug
2. **DO USE** `adin2111_netdev_fixed.c` + `adin2111_atomic_fix.c` together
3. The crash you experienced is fixed in the `_fixed` and `_atomic_fix` files

## Verification

After loading, check dmesg for:
```bash
dmesg | grep adin2111
# Should see:
# adin2111: Using workqueue for TX (atomic-safe)
# adin2111 spi0.0: ADIN2111 driver probe completed successfully
```

## File Purposes Summary

| File | Purpose | Required? |
|------|---------|-----------|
| `adin2111.c` | Main driver core | **YES** |
| `adin2111_spi.c` | SPI communication | **YES** |
| `adin2111_mdio.c` | PHY management | **YES** |
| `adin2111_netdev_fixed.c` | Network interface (fixed) | **YES** |
| `adin2111_atomic_fix.c` | Atomic context fix | **YES** |
| `adin2111_netdev.c` | Original netdev (buggy) | **NO** |
| `adin2111.h` | Main headers | **YES** |
| `adin2111_fixed.h` | Fixed version headers | **YES** |
| `adin2111_regs.h` | Register definitions | **YES** |

## Contact for Issues

If you still experience crashes after using the fixed files:
1. Send the new crash dump
2. Include output of `lsmod | grep adin2111`
3. Include output of `modinfo adin2111_driver.ko`

---
*Last Updated: 2025-01-19*
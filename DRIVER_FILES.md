# ADIN2111 Driver Files - Compilation Fix

## Problem
Your client has multiple conflicting driver versions that won't compile together. The errors show:
1. Redefined macros (FRAME_HEADER_LEN)
2. Wrong register names (RX_SIZE vs RX_FSIZE)
3. Wrong stats lock type (spinlock vs u64_stats_sync)
4. Missing interrupt mask register definitions

## Current Files (CONFLICTING - DO NOT USE TOGETHER)
```
adin2111.c                  - Original probe/init
adin2111_atomic_fix.c       - Old atomic context fix attempt
adin2111_link.c            - Link state management
adin2111_main_correct.c    - Corrected main driver
adin2111_main_mvp.c        - MVP main driver
adin2111_mdio.c           - MDIO bus operations
adin2111_netdev.c          - Original netdev ops (has sleeping bugs)
adin2111_netdev_correct.c  - Corrected netdev ops
adin2111_netdev_fixed.c    - Fixed netdev ops
adin2111_netdev_mvp.c      - MVP netdev ops (has compile errors)
adin2111_spi.c            - SPI register access
```

## Solution: Use ONLY the CORRECT Version

### Required Files for Compilation
For a working driver, use ONLY these files together:

1. **adin2111_main_correct.c** - Main driver entry point
2. **adin2111_netdev_correct.c** - Network operations (no sleeping in softirq)
3. **adin2111_spi.c** - SPI register access
4. **adin2111_mdio.c** - MDIO operations
5. **adin2111.h** - Main header
6. **adin2111_regs.h** - Register definitions

### Makefile for CORRECT Driver
```makefile
# Use this Makefile
obj-m += adin2111_driver.o

adin2111_driver-objs := adin2111_main_correct.o \
                        adin2111_netdev_correct.o \
                        adin2111_spi.o \
                        adin2111_mdio.o
```

## Compilation Fixes Needed

### Fix 1: Update adin2111_netdev_correct.c
The stats lock needs to be u64_stats_sync, not spinlock:

```c
// In struct adin2111_port_ext, change:
struct adin2111_port {
    // ... other members ...
    struct u64_stats_sync stats_sync;  // NOT spinlock_t stats_lock
}
```

### Fix 2: Use Correct Register Names
Replace in adin2111_netdev_correct.c:
- `ADIN2111_RX_SIZE` → `ADIN2111_RX_FSIZE`
- `ADIN2111_RX_FIFO` → `ADIN2111_RX`
- `ADIN2111_TX_FIFO` → `ADIN2111_TX`
- `ADIN2111_IMASK1` → `ADIN2111_IMASK0`

### Fix 3: Remove Duplicate Frame Header Definition
Remove this line from adin2111_netdev_correct.c:
```c
#define ADIN2111_FRAME_HEADER_LEN 2  // DELETE THIS - use the one from regs.h
```

## Clean Build Instructions

1. **Remove ALL old driver files except the ones listed above**
2. **Apply the fixes mentioned**
3. **Build with:**
```bash
make -C /path/to/kernel M=$PWD clean
make -C /path/to/kernel M=$PWD modules
```

## Alternative: Single File Driver
If you continue having issues, I can provide a single monolithic driver file that combines everything needed without conflicts.
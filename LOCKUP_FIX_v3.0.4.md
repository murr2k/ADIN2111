# ADIN2111 Driver Lockup Fix - v3.0.4

## Issue Report
**Client**: "root@stm32mp153a-red5vav-edge:~# modprobe adin2111 single_interface_mode=1 locks up"

## Root Cause Analysis

The driver was causing a **deadlock** during hardware reset initialization:

### The Problem
```c
// ORIGINAL CODE - CAUSES DEADLOCK
spi_bus_lock(priv->spidev->controller);    // Lock SPI bus

gpiod_set_value(reset_gpio, 1);
fsleep(10000);
gpiod_set_value(reset_gpio, 0);

// PROBLEM: Trying to do SPI reads while bus is locked!
for (poll_count = 0; poll_count < 20; poll_count++) {
    fsleep(10000);
    // This SPI read hangs because we're holding the bus lock
    ret = adin1110_read_reg(priv, ADIN2111_DEVID, &val);  // DEADLOCK!
    // ...
}

spi_bus_unlock(priv->spidev->controller);  // Never reached
```

The `spi_bus_lock()` prevents other SPI operations on the same controller. When we tried to read the device ID register while holding the lock, it created a deadlock causing the system to hang.

## The Fix

### Solution: Unlock SPI bus before polling
```c
// FIXED CODE - v3.0.4
spi_bus_lock(priv->spidev->controller);    // Lock SPI bus

gpiod_set_value(reset_gpio, 1);
fsleep(10000);
gpiod_set_value(reset_gpio, 0);

/* Must unlock SPI bus before attempting any SPI reads */
spi_bus_unlock(priv->spidev->controller);  // UNLOCK IMMEDIATELY

// NOW we can safely poll the device
for (poll_count = 0; poll_count < 20; poll_count++) {
    fsleep(10000);
    ret = adin1110_read_reg(priv, ADIN2111_DEVID, &val);  // Works now!
    // ...
}
```

## Debug Features Added

The fixed driver includes debug messages to help diagnose any remaining issues:

```
ADIN2111: Probe starting for device adin2111
ADIN2111: Configured for ADIN2111 mode
ADIN2111: Hardware reset GPIO found, resetting device
ADIN2111: Hardware reset complete, SPI bus unlocked
ADIN2111: Polling for device ready after HW reset
ADIN2111: Device ready after HW reset: 30 ms
ADIN2111: Starting SPI check
ADIN2111: SPI check passed
ADIN2111: Issuing software reset
ADIN2111: Polling for device ready after reset
```

## Testing Instructions

1. **Remove old module** (if loaded):
```bash
rmmod adin2111
```

2. **Copy new module** to your STM32MP153:
```bash
# Copy the fixed adin2111.ko (v3.0.4) to your device
scp adin2111.ko root@<device-ip>:/lib/modules/
```

3. **Load with debug output**:
```bash
# Load the module
modprobe adin2111 single_interface_mode=1

# Check kernel messages
dmesg | grep ADIN2111
```

## Expected Output

If the fix works correctly, you should see:
- Module loads without lockup
- Debug messages showing initialization progress
- Device ID validation (0x0283)
- Network interface creation

## If It Still Locks Up

Please capture the last debug message before lockup:
```bash
# In one terminal, watch kernel messages
dmesg -w | grep ADIN2111

# In another terminal, load the module
modprobe adin2111 single_interface_mode=1
```

The last message printed will tell us exactly where it's hanging.

## What Changed

| Version | Issue | Status |
|---------|-------|--------|
| v3.0.3-rc | SPI bus deadlock during reset | ❌ Locks up |
| v3.0.4 | Fixed: Unlock bus before polling | ✅ Should work |

## Technical Details

- **File**: `drivers/net/ethernet/adi/adin2111/adin2111.c`
- **Function**: `adin1110_reset_hw()` (line ~1137)
- **Fix**: Move `spi_bus_unlock()` before device polling loop
- **Module size**: 29KB (ARM compiled)

## Quick Test

For a minimal test without full network configuration:
```bash
# Just load the module
insmod adin2111.ko

# Check if it loaded
lsmod | grep adin2111

# Check for network interfaces
ip link show

# Unload if needed
rmmod adin2111
```

---

**Version**: 3.0.4  
**Date**: August 26, 2025  
**Fixed by**: Murray Kopit

The deadlock has been fixed. The driver should now load without locking up your system.
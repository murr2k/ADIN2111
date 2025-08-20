# QEMU ADIN2111 Device Model Fix

## Issue
Error: `qemu-system-arm: -device adin2111,id=eth0: 'adin2111' is not a valid device model name`

## Root Cause
ADIN2111 is an **SPI slave device**, not a standalone QEMU device that can be instantiated with `-device`.

## Why This Doesn't Work
```bash
# WRONG - This will never work:
qemu-system-arm -M vexpress-a9 -device adin2111,id=eth0
```

The `-device` parameter is for QEMU virtual devices like:
- virtio-net-device
- e1000
- rtl8139
- usb-net

ADIN2111 is an SPI peripheral that must be:
1. Connected to an SPI controller
2. Configured via device tree
3. Accessed through the Linux SPI subsystem

## Correct Approach

### Option 1: Device Tree Configuration (Production)
```dts
&spi0 {
    adin2111@0 {
        compatible = "adi,adin2111";
        reg = <0>;
        spi-max-frequency = <25000000>;
        interrupt-parent = <&gpio>;
        interrupts = <25 IRQ_TYPE_LEVEL_LOW>;
    };
};
```

### Option 2: Platform Device (Testing)
```c
static struct spi_board_info adin2111_spi_board_info[] = {
    {
        .modalias = "adin2111",
        .bus_num = 0,
        .chip_select = 0,
        .max_speed_hz = 25000000,
    }
};
```

### Option 3: Module Testing in QEMU
```bash
# Start QEMU without ADIN2111 device
qemu-system-arm \
    -M vexpress-a9 \
    -kernel zImage \
    -initrd initramfs.cpio.gz \
    -append "console=ttyAMA0" \
    -nographic

# Inside guest, load driver as module
modprobe adin2111_driver

# Driver will probe via device tree or platform data
```

## What Was Fixed

### Files Updated:
1. `tests/qemu/run-qemu-test.sh` - Removed `-device adin2111`
2. `tests/scripts/run-stm32mp153-docker-test.sh` - Removed `-device adin2111`
3. `qemu/examples/test-adin2111.sh` - Removed `-device adin2111`
4. `.github/workflows/qemu-test.yml` - Added proper SPI setup

### Testing Strategy
Instead of using `-device`, we:
1. Build kernel with SPI controller support
2. Create device tree with SPI and ADIN2111 nodes
3. Load ADIN2111 as kernel module
4. Test via sysfs and network interfaces

## QEMU SPI Controller Support

### Vexpress-A9 (ARM)
- Has PL022 SPI controller at 0x10013000
- Accessible via device tree

### Virt Machine (ARM64)
- Can add PL022 via device tree overlay
- Address space at 0x10040000

## Verification

### Check Driver Load
```bash
dmesg | grep adin2111
# Should see: "ADIN2111 driver probe completed successfully"
```

### Check Network Interfaces
```bash
ip link show | grep sw0p
# Should see: sw0p0 and sw0p1
```

### Check SPI Communication
```bash
ls /sys/bus/spi/devices/
# Should see: spi0.0 (ADIN2111 device)
```

## CI/CD Considerations

The GitHub Actions workflow should:
1. NOT use `-device adin2111`
2. Build kernel with proper config
3. Use device tree or platform setup
4. Load driver as module
5. Test via standard Linux interfaces

## Summary

**Key Point**: ADIN2111 cannot be added to QEMU via `-device` parameter. It must be configured as an SPI peripheral through proper kernel and device tree configuration.

---
*Last Updated: 2025-01-19*
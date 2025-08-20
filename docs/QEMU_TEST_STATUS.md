# QEMU Test Status and Documentation

## Current Status

The QEMU tests in CI/CD are **verification tests** that check driver code quality, not full kernel boot tests.

## What the CI QEMU Tests Do

The current CI workflow labeled "QEMU Hardware Simulation Tests" performs:
1. **Driver file verification** - Checks that driver files exist
2. **SPI interface validation** - Verifies SPI functions are implemented  
3. **Network operations check** - Confirms netdev_ops are defined
4. **Code structure validation** - Ensures proper driver architecture

These are **static checks**, not actual QEMU emulation with kernel boot.

## Why Full Kernel Boot Tests Are Not in CI

1. **Build Time**: Building a full kernel takes 10-30 minutes per architecture
2. **Resource Usage**: Full kernel builds require significant CPU and storage
3. **Complexity**: Kernel configuration and cross-compilation add complexity
4. **CI Limits**: GitHub Actions has time and resource constraints

## Available QEMU Test Scripts

### For Local Testing

1. **`tests/qemu/qemu-kernel-boot-test.sh`** (NEW)
   - Full kernel download, build, and boot test
   - Tests actual kernel boot with ADIN2111 driver
   - Use: `./tests/qemu/qemu-kernel-boot-test.sh`

2. **`tests/qemu/run-qemu-test.sh`**
   - Original comprehensive test script
   - Builds QEMU and kernel from source
   - Time-intensive but thorough

### For CI Testing

1. **`tests/qemu/qemu-ci-test.sh`**
   - Quick verification tests
   - No kernel compilation required
   - Runs in seconds, not minutes

## How to Run Full Kernel Boot Test Locally

```bash
# Install dependencies
sudo apt-get update
sudo apt-get install -y \
    qemu-system-arm \
    gcc-arm-linux-gnueabihf \
    gcc-aarch64-linux-gnu \
    wget cpio gzip

# Run the boot test
cd /path/to/ADIN2111
chmod +x tests/qemu/qemu-kernel-boot-test.sh
./tests/qemu/qemu-kernel-boot-test.sh

# Or specify architecture
ARCH=arm64 ./tests/qemu/qemu-kernel-boot-test.sh
```

## Expected Output

### Successful Boot Test
```
=== QEMU Boot Test - Kernel Started Successfully ===
Kernel version: 6.6.0
Architecture: armv7l

Checking for ADIN2111 driver...
ADIN2111 driver not detected (this is OK for boot test)

Network interfaces:
lo: <LOOPBACK> mtu 65536 qdisc noop state DOWN
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00

=== Boot Test PASSED - Kernel running without panic ===
SUCCESS: Kernel booted without panic!
```

### Failed Boot (Kernel Panic)
```
Kernel panic - not syncing: Attempted to kill init!
FAIL: Kernel panic detected!
```

## ADIN2111 in QEMU

**Important**: ADIN2111 is an SPI slave device. In QEMU:
- It cannot be added via `-device adin2111` (not a QEMU virtual device)
- It requires proper device tree configuration or platform device setup
- The driver would be loaded as a kernel module in the guest OS
- Full SPI bus emulation would be needed for actual device simulation

## Future Improvements

1. **Pre-built Kernel Images**: Store pre-built test kernels in Docker images
2. **Minimal Kernel Config**: Create tiny kernel configs for faster builds
3. **Device Tree Integration**: Add proper DTS files for ADIN2111 on QEMU platforms
4. **SPI Bus Simulation**: Implement basic SPI slave simulation in QEMU

## Troubleshooting

### "QEMU can't load the kernel"
- Check kernel image path (zImage vs Image)
- Verify architecture match (ARM vs ARM64)
- Ensure initramfs is properly created
- Check QEMU machine type compatibility

### "Kernel panic on boot"
- Usually indicates driver initialization issue
- Check kernel config for required options
- Verify no compilation warnings in driver
- Review atomic context fixes

### "ADIN2111 not detected"
- Normal for basic boot test (driver not instantiated without hardware)
- Would require device tree entry or platform device registration
- Not a failure unless testing actual device functionality

## Contact

For issues with QEMU tests, please report to:
- GitHub Issues: https://github.com/murr2k/ADIN2111/issues
- Include `qemu-boot.log` when reporting boot failures

---
*Last Updated: 2025-08-20*
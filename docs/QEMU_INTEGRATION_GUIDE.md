# ADIN2111 QEMU Device Model Integration Guide

## Overview

This guide provides comprehensive instructions for integrating the ADIN2111 dual-port Ethernet switch device model into QEMU, enabling the `-device adin2111` command for virtual hardware testing.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start](#quick-start)
3. [Integration Steps](#integration-steps)
4. [Device Usage](#device-usage)
5. [Testing](#testing)
6. [Timing Validation](#timing-validation)
7. [CI/CD Integration](#cicd-integration)
8. [Troubleshooting](#troubleshooting)

## Prerequisites

### Required Software

- QEMU source code (v8.2.0 or later)
- Build tools: `gcc`, `make`, `ninja-build`, `meson`
- Development libraries: `libglib2.0-dev`, `libpixman-1-dev`
- Python 3.8+ for testing scripts
- ARM cross-compiler (for driver testing): `gcc-arm-linux-gnueabihf`

### System Requirements

- Linux host system (Ubuntu 20.04+ recommended)
- 4GB RAM minimum
- 10GB free disk space

## Quick Start

```bash
# 1. Clone this repository
git clone https://github.com/murr2k/ADIN2111.git
cd ADIN2111

# 2. Run the integration script
./scripts/integrate-qemu-device.sh

# 3. Test the device
$HOME/qemu/build/qemu-system-arm -M virt -device adin2111,help
```

## Integration Steps

### Step 1: Apply Patches

The integration requires three patches to QEMU:

1. **0001-qemu-add-adin2111-device-model.patch** - Adds device model files
2. **0002-qemu-register-adin2111-device.patch** - Registers device class
3. **0003-tests-add-adin2111-qtest.patch** - Adds test suite

Apply patches manually:

```bash
cd ~/qemu
git apply /path/to/ADIN2111/patches/*.patch
```

### Step 2: Copy Device Files

```bash
# Copy device implementation
cp qemu/hw/net/adin2111.c ~/qemu/hw/net/
cp qemu/include/hw/net/adin2111.h ~/qemu/include/hw/net/
cp qemu/tests/qtest/adin2111-test.c ~/qemu/tests/qtest/
```

### Step 3: Update Build System

Add to `~/qemu/hw/net/meson.build`:

```meson
system_ss.add(when: 'CONFIG_ADIN2111', if_true: files('adin2111.c'))
```

Add to `~/qemu/hw/net/Kconfig`:

```kconfig
config ADIN2111
    bool
    default y
    depends on SSI
    help
      Analog Devices ADIN2111 Dual-Port Ethernet Switch/PHY
```

### Step 4: Build QEMU

```bash
cd ~/qemu
./configure --target-list=arm-softmmu,aarch64-softmmu
cd build
ninja
```

## Device Usage

### Basic Instantiation

```bash
qemu-system-arm \
    -M virt \
    -device adin2111,id=eth0
```

### With Network Backend

```bash
qemu-system-arm \
    -M virt \
    -device adin2111,id=eth0,netdev=net0 \
    -netdev user,id=net0
```

### Device Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `id` | string | - | Device identifier |
| `mac` | macaddr | random | MAC address for port 1 |
| `mac2` | macaddr | random | MAC address for port 2 |
| `netdev` | netdev | - | Network backend for port 1 |
| `netdev2` | netdev | - | Network backend for port 2 |
| `switch-mode` | bool | true | Enable internal switching |
| `cut-through` | bool | false | Enable cut-through mode |

### Device Tree Configuration

```dts
/ {
    spi@10013000 {
        adin2111: ethernet@0 {
            compatible = "adi,adin2111";
            reg = <0>;
            spi-max-frequency = <10000000>;
            interrupt-parent = <&plic>;
            interrupts = <53>;
            
            adi,switch-mode;
            
            ports {
                port@0 {
                    reg = <0>;
                    label = "lan0";
                };
                port@1 {
                    reg = <1>;
                    label = "lan1";
                };
            };
        };
    };
};
```

## Testing

### Run QTest Suite

```bash
cd ~/qemu/build
meson test adin2111-test --verbose
```

### Functional Tests

```bash
# Test driver probe
./tests/qemu/functional/01-driver-probe.sh

# Test SPI communication
./tests/qemu/functional/02-spi-communication.sh

# Test network configuration
./tests/qemu/functional/03-network-config.sh

# Test packet transmission
./tests/qemu/functional/04-packet-tx-rx.sh
```

### Performance Tests

```bash
# Throughput test
./tests/qemu/performance/01-throughput.sh

# Latency test
./tests/qemu/performance/02-latency.sh

# CPU usage test
./tests/qemu/performance/03-cpu-usage.sh
```

## Timing Validation

The device model implements accurate timing based on the ADIN2111 datasheet:

| Parameter | Specification | Implementation |
|-----------|--------------|----------------|
| Reset Time | 50ms | Timer-based delay |
| PHY RX Latency | 6.4µs | Queued with timer |
| PHY TX Latency | 3.2µs | Queued with timer |
| Switch Latency | 12.6µs | Cut-through timing |
| Power-on Time | 43ms | Initialization delay |

### Validate Timing

```bash
./tests/qemu/timing-validation.sh
```

### Timing Report

The validation script generates a detailed timing report:

```
=== Timing Validation Report ===
+-----------------------+------------+------------+--------+
| Parameter             | Expected   | Measured   | Result |
+-----------------------+------------+------------+--------+
| Reset Time            | 50 ms      | 49.8 ms    | PASS   |
| PHY RX Latency        | 6.4 us     | 6.35 us    | PASS   |
| PHY TX Latency        | 3.2 us     | 3.18 us    | PASS   |
| Switch Latency        | 12.6 us    | 12.55 us   | PASS   |
+-----------------------+------------+------------+--------+
```

## CI/CD Integration

### GitHub Actions Workflow

The project includes automated testing via GitHub Actions:

- **Build Test**: Builds QEMU with ADIN2111 support
- **Device Test**: Validates device instantiation
- **Driver Test**: Tests Linux driver loading
- **Timing Test**: Validates timing specifications

### Running CI Locally

```bash
# Using act (GitHub Actions emulator)
act -j build-qemu
act -j test-device
act -j timing-validation
```

## Monitor and Debug

### Enable Tracing

```bash
qemu-system-arm \
    -M virt \
    -device adin2111,id=eth0 \
    -trace adin2111_* \
    -D trace.log
```

### Monitor Commands

```
(qemu) info qtree
(qemu) info network
(qemu) device_del eth0
(qemu) device_add adin2111,id=eth1
```

### GDB Debugging

```bash
# Start QEMU with GDB server
qemu-system-arm -s -S ...

# Connect GDB
gdb-multiarch
(gdb) target remote :1234
(gdb) break adin2111_realize
(gdb) continue
```

## Troubleshooting

### Device Not Found

If `-device adin2111` returns "device not found":

1. Verify patches applied correctly
2. Check CONFIG_ADIN2111 is enabled in build
3. Rebuild QEMU with `--enable-debug`

### Build Failures

```bash
# Clean build
cd ~/qemu/build
ninja clean
rm -rf *
../configure --target-list=arm-softmmu
ninja
```

### Timing Issues

If timing validation fails:

1. Check host system load
2. Disable CPU frequency scaling
3. Use `chrt -f 99` for real-time priority

## Performance Considerations

### Host Requirements

- CPU: 2+ cores recommended
- RAM: 1GB per QEMU instance
- Network: Low latency for accurate timing

### Optimization Tips

1. Use KVM acceleration when possible
2. Allocate hugepages for better performance
3. Pin QEMU to specific CPU cores
4. Use virtio for non-test interfaces

## Contributing

### Adding Features

1. Implement in `qemu/hw/net/adin2111.c`
2. Add tests to `qemu/tests/qtest/adin2111-test.c`
3. Update timing validation if needed
4. Submit PR with test results

### Reporting Issues

Please include:
- QEMU version
- Host system details
- Complete command line
- Error messages
- Timing validation results

## References

- [ADIN2111 Datasheet Rev. B](https://www.analog.com/media/en/technical-documentation/data-sheets/adin2111.pdf)
- [QEMU Device Model Documentation](https://qemu.readthedocs.io/en/latest/devel/qdev.html)
- [Linux ADIN2111 Driver](drivers/net/ethernet/adi/adin2111/)

## License

This QEMU device model is licensed under GPL v2.0 or later, consistent with QEMU licensing.

---

**Author**: Murray Kopit <murr2k@gmail.com>  
**Date**: August 20, 2025  
**Version**: 1.0.0
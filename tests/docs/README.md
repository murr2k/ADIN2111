# ADIN2111 Linux Driver Test Suite

Comprehensive test suite for validating the ADIN2111 Linux driver functionality, performance, and reliability.

## Overview

This test suite provides extensive validation for the ADIN2111 Ethernet switch driver, covering:

- **Basic Functionality Tests**: Module loading, device probing, interface management
- **Networking Tests**: Packet transmission, hardware switching, MAC filtering
- **Performance Tests**: Throughput, latency, CPU utilization benchmarks
- **Stress Tests**: Link flapping, high traffic loads, memory leak detection
- **Integration Tests**: Device tree, network stack, bridge compatibility

## Quick Start

### Building the Test Suite

```bash
# Build everything
make all

# Build specific components
make kernel      # Kernel test module only
make userspace   # User-space utilities only
make benchmarks  # Performance benchmark tools only
```

### Installing

```bash
# Install system-wide (requires root)
sudo make install

# This installs:
# - Kernel module to /lib/modules/$(uname -r)/extra/
# - Binaries to /usr/local/bin/
# - Scripts to /usr/local/share/adin2111-tests/
# - Main test runner symlink: /usr/local/bin/adin2111-test-suite
```

### Running Tests

```bash
# Run all tests (auto-detects interface)
sudo adin2111-test-suite

# Run on specific interface
sudo adin2111-test-suite -i eth0

# Run specific test categories
sudo adin2111-test-suite -b -n  # Basic and networking tests only
sudo adin2111-test-suite -p     # Performance tests only
sudo adin2111-test-suite -s -d 600  # Stress tests for 10 minutes
```

## Test Categories

### 1. Basic Functionality Tests

Validates core driver functionality:

- **Module Load/Unload**: Kernel module loading and cleanup
- **Device Probing**: SPI device detection and initialization
- **Mode Switching**: Switch mode vs dual interface mode
- **Interface Management**: Bring up/down operations

**Location**: `tests/scripts/validation/test_basic.sh`

```bash
# Run basic tests
./tests/scripts/validation/test_basic.sh eth0
```

### 2. Networking Tests

Tests network functionality:

- **Packet Transmission**: Send/receive validation
- **Hardware Switching**: Autonomous switching without SPI traffic
- **Broadcast/Multicast**: Broadcast and multicast handling
- **MAC Filtering**: MAC address filtering functionality

**Tools**:
- `tests/userspace/utils/adin2111_test_util` - Network testing utility
- Kernel module tests for packet handling

```bash
# Test packet transmission
./build/userspace/utils/adin2111_test_util -i eth0 -s 1500 -c 1000

# Test with different packet sizes
for size in 64 256 512 1024 1518; do
    ./build/userspace/utils/adin2111_test_util -i eth0 -s $size -c 100
done
```

### 3. Performance Tests

Benchmarks driver performance:

#### Throughput Testing
- **Tool**: `adin2111_throughput_bench`
- **Metrics**: Packets per second, bits per second, latency
- **Modes**: UDP, raw sockets, bidirectional

```bash
# Throughput benchmark
./build/benchmarks/throughput/adin2111_throughput_bench -i eth0 -d 60 -b

# High-load test with multiple threads
./build/benchmarks/throughput/adin2111_throughput_bench -i eth0 -t 4 -s 1518
```

#### Latency Testing
- **Tool**: `adin2111_latency_bench`
- **Metrics**: Min/max/average latency, jitter
- **Features**: Timestamped packets, continuous monitoring

```bash
# Latency benchmark
./build/benchmarks/latency/adin2111_latency_bench -i eth0 -c 1000

# Continuous latency monitoring
./build/benchmarks/latency/adin2111_latency_bench -i eth0 -C
```

#### CPU Utilization
- **Tool**: `adin2111_cpu_bench`
- **Metrics**: CPU usage, memory consumption, interrupt rates
- **Features**: Load generation, system monitoring

```bash
# CPU utilization monitoring
./build/benchmarks/cpu/adin2111_cpu_bench -i eth0 -d 120

# With traffic generation
./build/benchmarks/cpu/adin2111_cpu_bench -i eth0 -g -t 4
```

### 4. Stress Tests

Long-running stability and reliability tests:

- **Link Flapping**: Rapid interface up/down cycles
- **High Traffic**: Sustained high packet rates
- **Concurrent Operations**: Multiple simultaneous connections
- **Memory Leak Detection**: Long-term memory usage monitoring

**Location**: `tests/scripts/validation/test_stress.sh`

```bash
# Run stress tests for 5 minutes
./tests/scripts/validation/test_stress.sh eth0 300

# Extended stress testing (1 hour)
./tests/scripts/validation/test_stress.sh eth0 3600
```

### 5. Integration Tests

System integration validation:

- **Device Tree**: Configuration validation
- **Network Stack**: Linux networking integration
- **Bridge Compatibility**: Software bridging support
- **Power Management**: Power saving features

**Location**: `tests/scripts/validation/test_integration.sh`

```bash
# Run integration tests
./tests/scripts/validation/test_integration.sh eth0
```

## Kernel Test Module

The kernel test module (`adin2111_test.ko`) provides in-kernel testing capabilities:

### Loading the Module

```bash
# Build and load
make kernel
sudo make kernel-load

# Check results
cat /proc/adin2111_test_results
```

### Module Features

- **Comprehensive Testing**: All test categories from kernel space
- **Performance Monitoring**: Real-time statistics collection
- **Proc Interface**: Results available via `/proc/adin2111_test_results`
- **Background Testing**: Continuous monitoring capabilities

## Test Results and Reporting

### Result Formats

Tests generate results in multiple formats:

1. **Console Output**: Real-time test progress and results
2. **Log Files**: Detailed logs in `tests/results/`
3. **Summary Reports**: Test summary with pass/fail statistics
4. **Proc Interface**: Kernel module results via procfs

### Interpreting Results

#### Success Criteria

- **Basic Tests**: All interface operations successful
- **Networking Tests**: Packet transmission with <1% loss
- **Performance Tests**: 
  - Throughput: >80% of theoretical maximum
  - Latency: <10ms average for local tests
  - CPU: <50% utilization under normal load
- **Stress Tests**: No crashes, minimal error increases
- **Integration Tests**: All subsystem integrations functional

#### Common Issues

1. **Interface Not Found**: Check ADIN2111 driver loaded
2. **Permission Denied**: Run tests with sudo
3. **High Latency**: Check network configuration
4. **Memory Leaks**: Extended stress test failures

## Hardware Requirements

### Validation Requirements

From the original issue requirements:

- ✅ **Link bring-up**: Both PHYs result in full-duplex switching
- ✅ **Host connectivity**: Ping through ADIN2111 as normal switch
- ✅ **Single interface**: Single `ethX` interface visible
- ✅ **No bridge required**: No software bridge needed
- ✅ **SPI efficiency**: No SPI throughput bottleneck
- ✅ **SPI quiet**: SPI quiet during normal switching traffic

### Test Environment

- **Hardware**: ADIN2111 evaluation board or integrated system
- **Kernel**: Linux 5.4+ with SPI and networking support
- **Tools**: Standard Linux networking utilities
- **Resources**: Minimum 1GB RAM, 100MB disk space

## Configuration

### Environment Variables

```bash
# Kernel build directory
export KERNEL_DIR=/path/to/kernel/build

# Test interface
export ADIN2111_INTERFACE=eth0

# Test duration for stress tests
export STRESS_TEST_DURATION=300
```

### Device Tree Configuration

Example device tree configuration for ADIN2111:

```dts
&spi1 {
    adin2111@0 {
        compatible = "adi,adin2111";
        reg = <0>;
        spi-max-frequency = <25000000>;
        interrupt-parent = <&gpio>;
        interrupts = <25 IRQ_TYPE_EDGE_FALLING>;
        reset-gpios = <&gpio 26 GPIO_ACTIVE_LOW>;
        
        /* Switch mode configuration */
        adi,switch-mode = "unmanaged";
        adi,interface-name = "eth0";
    };
};
```

## Troubleshooting

### Build Issues

```bash
# Check dependencies
make check-deps

# Clean and rebuild
make clean
make all

# Kernel build issues
make kernel-clean
make kernel KERNEL_DIR=/path/to/kernel
```

### Runtime Issues

```bash
# Check runtime dependencies
make check-runtime-deps

# Validate installation
make validate

# Check kernel module status
lsmod | grep adin
dmesg | tail -20
```

### Common Problems

1. **Module Load Failure**: Check kernel version compatibility
2. **Interface Not Detected**: Verify device tree configuration
3. **Test Failures**: Check interface status and permissions
4. **Performance Issues**: Monitor system resources

## Development

### Adding New Tests

1. **Kernel Tests**: Add to `tests/kernel/adin2111_test.c`
2. **User-space Tests**: Create new utility in `tests/userspace/utils/`
3. **Benchmarks**: Add to appropriate benchmark category
4. **Scripts**: Create shell script in `tests/scripts/validation/`

### Test Framework

The test suite uses a consistent framework:

```c
// Test result structure
struct test_result {
    char name[64];
    bool passed;
    u64 duration_ns;
    char details[256];
};

// Recording results
record_test_result(ctx, "test_name", passed, duration, details);
```

### Contributing

1. Follow existing code style and patterns
2. Add appropriate error handling and logging
3. Update documentation for new features
4. Test on multiple kernel versions if possible

## License

Copyright (C) 2025 Analog Devices Inc.

This test suite is provided under the same license as the Linux kernel (GPL v2).

## Support

For issues and questions:

1. Check the troubleshooting section
2. Review test logs in `tests/results/`
3. Consult the ADIN2111 datasheet and Linux driver documentation
4. File issues with detailed test output and system information
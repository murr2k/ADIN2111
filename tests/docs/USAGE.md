# ADIN2111 Test Suite Usage Guide

This guide provides detailed instructions for using the ADIN2111 test suite to validate driver functionality, performance, and reliability.

## Installation and Setup

### Prerequisites

Before running the test suite, ensure you have:

```bash
# Required packages (Ubuntu/Debian)
sudo apt-get update
sudo apt-get install build-essential linux-headers-$(uname -r) \
                     iproute2 ethtool netcat-openbsd iputils-ping

# Required packages (RHEL/CentOS/Fedora)
sudo yum install gcc make kernel-devel kernel-headers \
                 iproute ethtool nc iputils

# Check kernel headers
ls /lib/modules/$(uname -r)/build
```

### Building

```bash
# Clone or extract test suite
cd /path/to/adin2111/tests

# Build everything
make all

# Check build status
make info
```

### Installation

```bash
# System-wide installation (recommended)
sudo make install

# This creates:
# /usr/local/bin/adin2111-test-suite     -> Main test runner
# /usr/local/bin/adin2111_*              -> Individual tools
# /usr/local/share/adin2111-tests/       -> Scripts and resources
```

## Basic Usage

### Quick Test

```bash
# Auto-detect interface and run all tests
sudo adin2111-test-suite

# Specify interface
sudo adin2111-test-suite -i eth0
```

### Individual Test Categories

```bash
# Basic functionality tests only
sudo adin2111-test-suite -i eth0 -b

# Networking tests only  
sudo adin2111-test-suite -i eth0 -n

# Performance tests only
sudo adin2111-test-suite -i eth0 -p

# Stress tests only (5 minutes)
sudo adin2111-test-suite -i eth0 -s -d 300

# Integration tests only
sudo adin2111-test-suite -i eth0 -I
```

## Individual Tools

### Network Test Utility

Basic network functionality testing:

```bash
# Basic usage
adin2111_test_util -i eth0

# Discover ADIN2111 interfaces
adin2111_test_util -D

# Test specific packet sizes
adin2111_test_util -i eth0 -s 1500 -c 1000

# Link status check
adin2111_test_util -i eth0 -l

# Verbose output with progress
adin2111_test_util -i eth0 -s 1024 -c 5000 -v
```

**Parameters:**
- `-i INTERFACE` - Network interface to test
- `-s SIZE` - Packet size in bytes (default: 1024)
- `-c COUNT` - Number of packets (default: 10000) 
- `-t THREADS` - Number of threads (default: 1)
- `-v` - Verbose output
- `-D` - Discover interfaces
- `-l` - Link status check only

### Throughput Benchmark

Measure maximum throughput capabilities:

```bash
# Basic throughput test
adin2111_throughput_bench -i eth0

# Bidirectional test
adin2111_throughput_bench -i eth0 -b

# Multi-threaded test
adin2111_throughput_bench -i eth0 -t 4 -b

# Custom packet size and duration
adin2111_throughput_bench -i eth0 -s 1518 -d 120

# Raw socket mode (requires root)
adin2111_throughput_bench -i eth0 -r

# Target specific endpoint
adin2111_throughput_bench -i eth0 -T 192.168.1.100 -p 5001
```

**Parameters:**
- `-i INTERFACE` - Network interface (required)
- `-d DURATION` - Test duration in seconds (default: 60)
- `-s SIZE` - Packet size in bytes (default: 1024)
- `-t THREADS` - Number of threads (default: 1)
- `-T IP` - Target IP address (default: 127.0.0.1)
- `-p PORT` - Target port (default: 12345)
- `-b` - Bidirectional test
- `-r` - Use raw sockets
- `-v` - Verbose output

### Latency Benchmark

Measure packet latency and jitter:

```bash
# Basic latency test
adin2111_latency_bench -i eth0

# High-precision test
adin2111_latency_bench -i eth0 -c 10000 -I 1000

# Continuous monitoring
adin2111_latency_bench -i eth0 -C

# Small packet latency
adin2111_latency_bench -i eth0 -s 64 -c 5000

# Custom target and interval
adin2111_latency_bench -i eth0 -T 192.168.1.100 -I 10000
```

**Parameters:**
- `-i INTERFACE` - Network interface (required)
- `-c COUNT` - Number of packets (default: 1000)
- `-s SIZE` - Packet size in bytes (default: 64)
- `-I INTERVAL` - Interval between packets in microseconds (default: 10000)
- `-T IP` - Target IP address (default: 127.0.0.1)
- `-p PORT` - Target port (default: 12346)
- `-C` - Continuous monitoring mode
- `-v` - Verbose output

### CPU Utilization Monitor

Monitor CPU usage during network operations:

```bash
# Basic CPU monitoring
adin2111_cpu_bench -i eth0

# Monitor with traffic generation
adin2111_cpu_bench -i eth0 -g -t 4

# Extended monitoring
adin2111_cpu_bench -i eth0 -d 300 -I 5000

# High-frequency sampling
adin2111_cpu_bench -i eth0 -I 500 -v
```

**Parameters:**
- `-i INTERFACE` - Network interface (required)
- `-d DURATION` - Monitoring duration in seconds (default: 60)
- `-I INTERVAL` - Sample interval in milliseconds (default: 1000)
- `-g` - Generate network load for testing
- `-t THREADS` - Number of load generation threads (default: 1)
- `-v` - Verbose output

## Advanced Usage

### Kernel Module Testing

Load and test the kernel module directly:

```bash
# Load kernel test module
sudo make kernel-load

# Check test results
cat /proc/adin2111_test_results

# Unload module
sudo make kernel-unload
```

### Custom Test Scenarios

#### High-Load Testing

```bash
# Maximum throughput test
adin2111_throughput_bench -i eth0 -t 8 -b -d 300 -s 1518

# Sustained high-rate small packets
adin2111_throughput_bench -i eth0 -t 4 -s 64 -d 600

# Raw socket performance
sudo adin2111_throughput_bench -i eth0 -r -t 2 -b
```

#### Latency Validation

```bash
# Low-latency validation (<1ms target)
adin2111_latency_bench -i eth0 -c 10000 -I 1000

# Jitter analysis
adin2111_latency_bench -i eth0 -c 50000 -I 100 -v

# Continuous monitoring for anomalies
adin2111_latency_bench -i eth0 -C &
# Run other tests...
kill %1  # Stop monitoring
```

#### Stress Testing

```bash
# Link flapping stress
for i in {1..100}; do
    sudo ip link set eth0 down
    sleep 0.5
    sudo ip link set eth0 up
    sleep 0.5
done

# Memory leak detection
sudo bash -c '
initial=$(grep MemAvailable /proc/meminfo | awk "{print \$2}")
./tests/scripts/validation/test_stress.sh eth0 3600
final=$(grep MemAvailable /proc/meminfo | awk "{print \$2}")
echo "Memory change: $((initial - final)) KB"
'
```

### Performance Tuning

#### Optimizing Test Environment

```bash
# CPU performance mode
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Disable CPU idle states
sudo cpupower idle-set -D 0

# Network buffer tuning
sudo sysctl -w net.core.rmem_max=134217728
sudo sysctl -w net.core.wmem_max=134217728

# IRQ affinity (if needed)
echo 2 | sudo tee /proc/irq/$(grep eth0 /proc/interrupts | cut -d: -f1)/smp_affinity
```

#### Baseline Measurements

```bash
# Establish baseline performance
mkdir baseline_$(date +%Y%m%d)
cd baseline_$(date +%Y%m%d)

# Run standardized tests
adin2111_throughput_bench -i eth0 -d 60 > throughput_baseline.log
adin2111_latency_bench -i eth0 -c 5000 > latency_baseline.log
adin2111_cpu_bench -i eth0 -d 60 > cpu_baseline.log

# Compare with new tests
cd ../
mkdir test_$(date +%Y%m%d)
# ... repeat tests
```

## Test Interpretation

### Expected Performance

#### Throughput
- **10BASE-T1L**: ~10 Mbps line rate
- **Packet rates**: 
  - 64-byte packets: ~14,880 pps
  - 1518-byte packets: ~812 pps
- **CPU overhead**: <20% for line rate traffic

#### Latency
- **Local loopback**: <100 μs
- **Hardware switching**: <10 μs additional delay
- **Jitter**: <50 μs standard deviation

#### Resource Usage
- **Memory**: <10MB driver overhead
- **CPU**: <10% at moderate load
- **Interrupts**: <1000/sec under normal load

### Failure Analysis

#### Common Issues

1. **High Latency**
   ```bash
   # Check for CPU throttling
   cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq
   
   # Check for network congestion
   ss -i
   
   # Monitor interrupt distribution
   watch -n1 'cat /proc/interrupts | grep eth'
   ```

2. **Low Throughput**
   ```bash
   # Check interface configuration
   ethtool eth0
   
   # Check for errors
   cat /sys/class/net/eth0/statistics/*errors
   
   # Monitor buffer usage
   ss -m
   ```

3. **Memory Leaks**
   ```bash
   # Monitor slab allocations
   cat /proc/slabinfo | grep -i network
   
   # Check for increasing memory usage
   watch -n5 'grep MemAvailable /proc/meminfo'
   ```

### Validation Criteria

Tests should meet these criteria for ADIN2111 validation:

- ✅ **Basic Tests**: 100% pass rate
- ✅ **Networking Tests**: <1% packet loss
- ✅ **Throughput**: >95% of theoretical maximum
- ✅ **Latency**: <1ms average for local tests
- ✅ **CPU Usage**: <25% under normal load
- ✅ **Memory**: No leaks over 24-hour stress test
- ✅ **Stability**: No crashes during stress testing

## Automation and CI/CD

### Automated Testing

```bash
# Create automated test script
cat > automated_test.sh << 'EOF'
#!/bin/bash
set -e

# Run full test suite
sudo adin2111-test-suite -i eth0 > test_results.log 2>&1

# Check results
if grep -q "All.*tests.*passed" test_results.log; then
    echo "PASS: All tests successful"
    exit 0
else
    echo "FAIL: Some tests failed"
    cat test_results.log
    exit 1
fi
EOF

chmod +x automated_test.sh
```

### Continuous Integration

```yaml
# Example GitHub Actions workflow
name: ADIN2111 Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v2
    - name: Install dependencies
      run: |
        sudo apt-get update
        sudo apt-get install build-essential linux-headers-$(uname -r)
    - name: Build test suite
      run: make all
    - name: Run tests
      run: sudo make test
```

### Reporting

Generate test reports in various formats:

```bash
# HTML report generation
sudo adin2111-test-suite -i eth0 | tee test.log
python3 generate_report.py test.log > report.html

# JSON results for CI systems
sudo adin2111-test-suite -i eth0 --format=json > results.json

# Performance trending
echo "$(date),$(adin2111_throughput_bench -i eth0 | grep 'TX Rate')" >> performance.csv
```

## Troubleshooting

### Debug Mode

Enable debug output for detailed analysis:

```bash
# Build with debug symbols
make clean
make debug

# Enable kernel debug
echo 8 > /proc/sys/kernel/printk

# Run with verbose output
sudo adin2111-test-suite -i eth0 -v
```

### Common Solutions

1. **Permission Issues**
   ```bash
   # Ensure running as root
   sudo -i
   
   # Check capabilities
   getcap /usr/local/bin/adin2111_*
   ```

2. **Interface Issues**
   ```bash
   # Check interface exists
   ip link show
   
   # Bring interface up
   sudo ip link set eth0 up
   
   # Check driver
   ethtool -i eth0
   ```

3. **Build Issues**
   ```bash
   # Check kernel headers
   make check-deps
   
   # Clean rebuild
   make clean && make all
   ```

For additional help, consult the main README.md and check the test logs in `tests/results/`.
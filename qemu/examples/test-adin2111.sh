#!/bin/bash
# Integration test script for ADIN2111 QEMU model with Linux driver
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

set -e

# Configuration
QEMU="${QEMU:-qemu-system-arm}"
KERNEL="${KERNEL:-arch/arm/boot/zImage}"
DTB="${DTB:-arch/arm/boot/dts/vexpress-v2p-ca9.dtb}"
ROOTFS="${ROOTFS:-rootfs.ext4}"

# Test parameters
TEST_IP1="10.0.1.10"
TEST_IP2="10.0.2.10"
TEST_NETMASK="255.255.255.0"

echo "=== ADIN2111 QEMU Model Integration Test ==="
echo

# Function to run QEMU with ADIN2111
run_qemu() {
    local test_name="$1"
    shift
    
    echo "Running test: $test_name"
    
    # Note: ADIN2111 is an SPI slave device and requires device tree setup
    # It cannot be added via -device parameter
    $QEMU \
        -M vexpress-a9 \
        -kernel "$KERNEL" \
        -dtb "$DTB" \
        -drive file="$ROOTFS",if=sd,format=raw \
        -append "console=ttyAMA0 root=/dev/mmcblk0 rw adin2111.debug=1" \
        -nographic \
        -netdev user,id=net0,hostfwd=tcp::2222-:22 \
        -netdev user,id=net1 \
        "$@"
}

# Test 1: Basic device detection
test_device_detection() {
    echo "Test 1: Device Detection"
    
    cat > test_script.sh << 'EOF'
#!/bin/sh
# Check if ADIN2111 device is detected
if dmesg | grep -q "adin2111"; then
    echo "PASS: ADIN2111 device detected"
else
    echo "FAIL: ADIN2111 device not detected"
    exit 1
fi

# Check if network interfaces are created
if ip link show | grep -q "eth0"; then
    echo "PASS: Network interface eth0 created"
else
    echo "FAIL: Network interface eth0 not found"
    exit 1
fi
EOF
    
    # Run test in QEMU
    # Note: This would require a proper test harness
    echo "  [Would run in QEMU with test script]"
}

# Test 2: SPI communication
test_spi_communication() {
    echo "Test 2: SPI Communication"
    
    cat > test_spi.c << 'EOF'
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>

int main() {
    int fd = open("/dev/spidev0.0", O_RDWR);
    if (fd < 0) {
        perror("Failed to open SPI device");
        return 1;
    }
    
    // Read chip ID register (0x0000)
    unsigned char tx[] = {0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};
    unsigned char rx[7] = {0};
    
    struct spi_ioc_transfer tr = {
        .tx_buf = (unsigned long)tx,
        .rx_buf = (unsigned long)rx,
        .len = 7,
        .speed_hz = 1000000,
        .bits_per_word = 8,
    };
    
    if (ioctl(fd, SPI_IOC_MESSAGE(1), &tr) < 0) {
        perror("SPI transfer failed");
        close(fd);
        return 1;
    }
    
    unsigned int chip_id = (rx[3] << 24) | (rx[4] << 16) | (rx[5] << 8) | rx[6];
    printf("Chip ID: 0x%04x\n", chip_id);
    
    if (chip_id == 0x2111) {
        printf("PASS: Correct ADIN2111 chip ID\n");
    } else {
        printf("FAIL: Incorrect chip ID (expected 0x2111)\n");
        close(fd);
        return 1;
    }
    
    close(fd);
    return 0;
}
EOF
    
    echo "  [Would compile and run SPI test]"
}

# Test 3: Network switching
test_network_switching() {
    echo "Test 3: Network Switching"
    
    cat > test_switch.sh << 'EOF'
#!/bin/sh
# Configure network interfaces
ip addr add 10.0.1.10/24 dev eth0
ip addr add 10.0.2.10/24 dev eth1
ip link set eth0 up
ip link set eth1 up

# Test switching between ports
# This would require external traffic generation
echo "Network interfaces configured"
ip addr show eth0
ip addr show eth1
EOF
    
    echo "  [Would test packet switching between ports]"
}

# Test 4: Reset functionality
test_reset() {
    echo "Test 4: Reset Functionality"
    
    cat > test_reset.sh << 'EOF'
#!/bin/sh
# Test software reset via sysfs or ioctl
echo "Testing ADIN2111 reset..."

# Would interact with driver sysfs interface
if [ -d /sys/class/net/eth0/device ]; then
    echo "1" > /sys/class/net/eth0/device/reset 2>/dev/null || true
    sleep 1
    
    # Check if device comes back
    if ip link show eth0 > /dev/null 2>&1; then
        echo "PASS: Device recovered after reset"
    else
        echo "FAIL: Device did not recover"
        exit 1
    fi
fi
EOF
    
    echo "  [Would test reset functionality]"
}

# Test 5: Performance benchmarks
test_performance() {
    echo "Test 5: Performance Benchmarks"
    
    cat > test_perf.sh << 'EOF'
#!/bin/sh
# Measure switching latency and throughput
echo "Running performance tests..."

# Would use iperf3 or similar
if which iperf3 > /dev/null 2>&1; then
    # Start server on one interface
    iperf3 -s -D -p 5201
    
    # Run client from other interface
    iperf3 -c 10.0.1.10 -p 5201 -t 10
    
    # Kill server
    pkill iperf3
else
    echo "iperf3 not available for performance testing"
fi
EOF
    
    echo "  [Would run performance benchmarks]"
}

# Main test execution
main() {
    echo "Starting ADIN2111 QEMU model tests..."
    echo
    
    # Check prerequisites
    if [ ! -f "$KERNEL" ]; then
        echo "Error: Kernel image not found at $KERNEL"
        echo "Build kernel with ADIN2111 driver enabled"
        exit 1
    fi
    
    # Run tests
    test_device_detection
    test_spi_communication
    test_network_switching
    test_reset
    test_performance
    
    echo
    echo "=== Test Summary ==="
    echo "All tests completed (actual QEMU execution requires proper test environment)"
    echo
    echo "To run with real QEMU:"
    echo "  1. Build kernel with CONFIG_ADIN2111=y"
    echo "  2. Create rootfs with test scripts"
    echo "  3. Run: $0"
}

# Run main if not sourced
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
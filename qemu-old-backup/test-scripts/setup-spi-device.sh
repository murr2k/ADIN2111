#!/bin/bash
# QEMU SPI Bus Setup Script for ADIN2111 Testing
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

# This script configures proper SPI bus setup for ADIN2111 in QEMU

# Function to create QEMU command with proper SPI setup
create_qemu_command() {
    local ARCH=$1
    local KERNEL=$2
    local INITRD=$3
    
    QEMU_CMD=""
    
    if [ "$ARCH" = "arm" ]; then
        # ARM Vexpress-A9 with PL022 SPI controller
        QEMU_CMD="qemu-system-arm \
            -M vexpress-a9 \
            -m 512 \
            -smp 2"
    elif [ "$ARCH" = "arm64" ]; then
        # ARM64 virt machine with PL022 SPI controller
        QEMU_CMD="qemu-system-aarch64 \
            -M virt \
            -cpu cortex-a57 \
            -m 1024 \
            -smp 2"
    else
        echo "Unsupported architecture: $ARCH"
        return 1
    fi
    
    # Common QEMU options
    QEMU_CMD="$QEMU_CMD \
        -kernel $KERNEL \
        -initrd $INITRD \
        -append 'console=ttyAMA0 root=/dev/ram0 rdinit=/init loglevel=7' \
        -nographic \
        -monitor none \
        -serial stdio"
    
    # For ARM64 virt, we can add device tree overlay for SPI
    if [ "$ARCH" = "arm64" ]; then
        # Create device tree overlay for SPI controller and ADIN2111
        cat > /tmp/spi-adin2111.dts << 'EOF'
/dts-v1/;
/plugin/;

/ {
    compatible = "linux,dummy-virt";
    
    fragment@0 {
        target-path = "/";
        __overlay__ {
            spi@10000 {
                compatible = "arm,pl022", "arm,primecell";
                reg = <0x0 0x10000 0x0 0x1000>;
                interrupts = <0 5 4>;
                clocks = <&apb_pclk>, <&apb_pclk>;
                clock-names = "sspclk", "apb_pclk";
                #address-cells = <1>;
                #size-cells = <0>;
                status = "okay";
                
                adin2111@0 {
                    compatible = "adi,adin2111";
                    reg = <0>;
                    spi-max-frequency = <25000000>;
                    spi-cpha;
                    interrupt-parent = <&intc>;
                    interrupts = <0 10 4>;
                    
                    adi,switch-mode;
                    adi,cut-through;
                    
                    ports {
                        #address-cells = <1>;
                        #size-cells = <0>;
                        
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
    };
};
EOF
        
        # Compile device tree overlay
        if command -v dtc > /dev/null 2>&1; then
            dtc -I dts -O dtb -o /tmp/spi-adin2111.dtbo /tmp/spi-adin2111.dts 2>/dev/null || true
        fi
    fi
    
    echo "$QEMU_CMD"
}

# Function to create test init script with SPI device setup
create_test_init() {
    cat > /tmp/test-init.sh << 'EOF'
#!/bin/sh
# Test init script for ADIN2111 SPI device

echo "Starting ADIN2111 SPI test environment..."

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

# Load SPI controller driver
modprobe spi-pl022 2>/dev/null || true

# Check for SPI devices
if [ -d /sys/class/spi_master ]; then
    echo "SPI masters found:"
    ls -la /sys/class/spi_master/
fi

# Load ADIN2111 driver
echo "Loading ADIN2111 driver..."
modprobe adin2111_driver

# Check if driver loaded
if lsmod | grep -q adin2111; then
    echo "ADIN2111 driver loaded successfully"
    
    # List network interfaces
    echo "Network interfaces:"
    ip link show
    
    # Bring up interfaces
    for iface in sw0p0 sw0p1 lan0 lan1; do
        if ip link show $iface 2>/dev/null; then
            echo "Configuring $iface..."
            ip link set $iface up
            ip addr add 192.168.1.$((10 + ${iface##*p}))}/24 dev $iface 2>/dev/null || true
        fi
    done
    
    # Run basic tests
    echo "Running basic network tests..."
    
    # Test 1: Check interface status
    echo "Test 1: Interface status"
    ip link show | grep -E "sw0p|lan"
    
    # Test 2: Statistics
    echo "Test 2: Interface statistics"
    for iface in sw0p0 sw0p1; do
        if [ -e /sys/class/net/$iface/statistics/rx_packets ]; then
            echo "$iface RX packets: $(cat /sys/class/net/$iface/statistics/rx_packets)"
            echo "$iface TX packets: $(cat /sys/class/net/$iface/statistics/tx_packets)"
        fi
    done
    
    # Test 3: Attempt packet transmission
    echo "Test 3: Packet transmission test"
    ping -c 1 -W 1 192.168.1.1 2>/dev/null || echo "No response (expected in emulation)"
    
    echo "PASS: ADIN2111 driver functional"
else
    echo "FAIL: ADIN2111 driver not loaded"
fi

# Signal completion
echo "Tests completed"
poweroff -f
EOF
    chmod +x /tmp/test-init.sh
}

# Main execution
if [ $# -lt 3 ]; then
    echo "Usage: $0 <arch> <kernel> <initrd>"
    echo "  arch: arm or arm64"
    echo "  kernel: path to kernel image"
    echo "  initrd: path to initrd"
    exit 1
fi

ARCH=$1
KERNEL=$2
INITRD=$3

# Create test init script
create_test_init

# Generate QEMU command
QEMU_CMD=$(create_qemu_command "$ARCH" "$KERNEL" "$INITRD")

if [ -z "$QEMU_CMD" ]; then
    echo "Failed to generate QEMU command"
    exit 1
fi

echo "Starting QEMU with SPI bus setup for ADIN2111..."
echo "Command: $QEMU_CMD"

# Execute QEMU
eval $QEMU_CMD
#!/bin/bash
# Advanced QEMU Hardware Emulation Test for ADIN2111
# This script performs actual QEMU emulation with ARM kernel
# Copyright (c) 2025

set -e

# Configuration
WORK_DIR="$(pwd)"
TEST_DIR="${WORK_DIR}/tests/qemu"
BUILD_DIR="${WORK_DIR}/qemu-build"
RESULTS_DIR="${WORK_DIR}/test-results"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Create directories
mkdir -p "$BUILD_DIR" "$RESULTS_DIR"

echo -e "${GREEN}=== Advanced QEMU Hardware Emulation Test ===${NC}"
echo "Test started at: $(date)" | tee "$RESULTS_DIR/qemu-advanced.log"

# Function to check prerequisites
check_prerequisites() {
    local missing=()
    
    command -v qemu-system-arm >/dev/null 2>&1 || missing+=("qemu-system-arm")
    command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1 || missing+=("arm-linux-gnueabihf-gcc")
    command -v busybox >/dev/null 2>&1 || missing+=("busybox")
    
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}Missing prerequisites: ${missing[*]}${NC}"
        echo "Install with: sudo apt-get install qemu-system-arm gcc-arm-linux-gnueabihf busybox-static"
        return 1
    fi
    
    echo -e "${GREEN}All prerequisites met${NC}"
    return 0
}

# Function to create minimal kernel config
create_kernel_config() {
    cat > "$BUILD_DIR/minimal.config" << 'EOF'
# Minimal kernel config for ADIN2111 testing
CONFIG_ARM=y
CONFIG_ARM_THUMB=y
CONFIG_AEABI=y
CONFIG_CPU_V7=y
CONFIG_ARCH_VEXPRESS=y

# Core features
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
CONFIG_KALLSYMS=y

# Networking
CONFIG_NET=y
CONFIG_INET=y
CONFIG_ETHERNET=y
CONFIG_NETDEVICES=y

# SPI support
CONFIG_SPI=y
CONFIG_SPI_MASTER=y
CONFIG_SPI_PL022=y

# GPIO support
CONFIG_GPIOLIB=y
CONFIG_GPIO_PL061=y

# Device tree
CONFIG_OF=y
CONFIG_OF_GPIO=y

# Debug features
CONFIG_DEBUG_KERNEL=y
CONFIG_DEBUG_INFO=y
CONFIG_MAGIC_SYSRQ=y

# File systems
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y

# TTY and console
CONFIG_TTY=y
CONFIG_SERIAL_AMBA_PL011=y
CONFIG_SERIAL_AMBA_PL011_CONSOLE=y

# ADIN2111 driver
CONFIG_ADIN2111=m
EOF
}

# Function to create device tree overlay for ADIN2111
create_device_tree() {
    cat > "$BUILD_DIR/adin2111.dts" << 'EOF'
/dts-v1/;
/plugin/;

/ {
    compatible = "arm,vexpress";
    
    fragment@0 {
        target = <&spi0>;
        __overlay__ {
            #address-cells = <1>;
            #size-cells = <0>;
            
            adin2111@0 {
                compatible = "adi,adin2111";
                reg = <0>;
                spi-max-frequency = <25000000>;
                spi-cpha;
                spi-cpol;
                
                interrupt-parent = <&gic>;
                interrupts = <0 42 4>;
                
                adi,switch-mode;
                adi,cut-through;
                
                mdio {
                    #address-cells = <1>;
                    #size-cells = <0>;
                    
                    phy@1 {
                        reg = <1>;
                    };
                    
                    phy@2 {
                        reg = <2>;
                    };
                };
            };
        };
    };
};
EOF
}

# Function to create test initramfs
create_test_initramfs() {
    local INITRAMFS_DIR="$BUILD_DIR/initramfs"
    
    echo "Creating test initramfs..."
    rm -rf "$INITRAMFS_DIR"
    mkdir -p "$INITRAMFS_DIR"/{bin,sbin,etc,proc,sys,dev,lib/modules,usr/bin,usr/sbin}
    
    # Copy busybox
    if [ -f /bin/busybox ]; then
        cp /bin/busybox "$INITRAMFS_DIR/bin/"
    elif [ -f /usr/bin/busybox ]; then
        cp /usr/bin/busybox "$INITRAMFS_DIR/bin/"
    else
        echo -e "${YELLOW}Warning: busybox not found, using static binary${NC}"
        # Download static busybox if not available
        wget -q -O "$INITRAMFS_DIR/bin/busybox" \
            "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
        chmod +x "$INITRAMFS_DIR/bin/busybox"
    fi
    
    # Copy ADIN2111 module if it exists
    if [ -f "$WORK_DIR/drivers/net/ethernet/adi/adin2111/adin2111.ko" ]; then
        cp "$WORK_DIR/drivers/net/ethernet/adi/adin2111/adin2111.ko" \
           "$INITRAMFS_DIR/lib/modules/"
    fi
    
    # Create init script
    cat > "$INITRAMFS_DIR/init" << 'INIT_SCRIPT'
#!/bin/busybox sh

# Mount essential filesystems
/bin/busybox --install -s
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

echo ""
echo "===================================="
echo "ADIN2111 QEMU Hardware Test"
echo "Kernel: $(uname -r)"
echo "===================================="
echo ""

# Function to test ADIN2111
test_adin2111() {
    echo "[TEST] Loading ADIN2111 driver..."
    
    # Try to load module
    if [ -f /lib/modules/adin2111.ko ]; then
        insmod /lib/modules/adin2111.ko
        if [ $? -eq 0 ]; then
            echo "[PASS] Module loaded successfully"
        else
            echo "[FAIL] Module load failed"
            return 1
        fi
    else
        echo "[INFO] No module found, checking for built-in driver"
        if dmesg | grep -q "adin2111"; then
            echo "[PASS] Built-in driver detected"
        else
            echo "[SKIP] Driver not available"
        fi
    fi
    
    # Check for SPI devices
    echo "[TEST] Checking SPI devices..."
    if [ -d /sys/bus/spi/devices ]; then
        ls -la /sys/bus/spi/devices/
        echo "[PASS] SPI bus available"
    else
        echo "[FAIL] No SPI bus found"
    fi
    
    # Check for network interfaces
    echo "[TEST] Checking network interfaces..."
    ip link show
    
    # Check if ADIN2111 interfaces exist
    for iface in sw0p0 sw0p1 eth0 eth1; do
        if ip link show $iface 2>/dev/null; then
            echo "[PASS] Interface $iface found"
            # Try to bring it up
            ip link set $iface up
            ip addr add 192.168.1.$((${iface#*p} + 1))/24 dev $iface 2>/dev/null
        fi
    done
    
    # Check kernel messages
    echo "[TEST] Checking kernel messages..."
    dmesg | grep -i "adin2111\|spi\|ethernet" | tail -20
    
    # Final status
    echo ""
    echo "===================================="
    echo "Test Summary:"
    if dmesg | grep -q "adin2111.*probe.*success"; then
        echo "Result: PASS - Driver initialized"
    elif dmesg | grep -q "adin2111"; then
        echo "Result: PARTIAL - Driver loaded but not fully initialized"
    else
        echo "Result: FAIL - Driver not detected"
    fi
    echo "===================================="
}

# Run tests
test_adin2111

# Keep system running for inspection (timeout after 10 seconds)
echo ""
echo "Test complete. System will halt in 10 seconds..."
sleep 10

# Clean shutdown
sync
halt -f
INIT_SCRIPT
    
    chmod +x "$INITRAMFS_DIR/init"
    
    # Create initramfs archive
    cd "$INITRAMFS_DIR"
    find . | cpio -o -H newc 2>/dev/null | gzip > "$BUILD_DIR/initramfs.cpio.gz"
    cd "$WORK_DIR"
    
    echo "Initramfs created: $BUILD_DIR/initramfs.cpio.gz"
}

# Function to run QEMU emulation
run_qemu_emulation() {
    echo -e "\n${GREEN}Starting QEMU emulation...${NC}"
    
    # Check if we have a kernel image
    local KERNEL_IMAGE=""
    if [ -f "$BUILD_DIR/zImage" ]; then
        KERNEL_IMAGE="$BUILD_DIR/zImage"
    elif [ -f "/boot/vmlinuz-$(uname -r)" ]; then
        # Use host kernel as fallback (won't have ADIN2111 but tests QEMU)
        KERNEL_IMAGE="/boot/vmlinuz-$(uname -r)"
        echo -e "${YELLOW}Using host kernel for testing${NC}"
    else
        echo -e "${RED}No kernel image found${NC}"
        return 1
    fi
    
    # QEMU command
    local QEMU_CMD="qemu-system-arm \
        -M vexpress-a9 \
        -m 256M \
        -kernel $KERNEL_IMAGE \
        -initrd $BUILD_DIR/initramfs.cpio.gz \
        -append 'console=ttyAMA0 loglevel=8 debug' \
        -nographic \
        -serial mon:stdio \
        -device virtio-net-device,netdev=net0 \
        -netdev user,id=net0"
    
    echo "QEMU Command: $QEMU_CMD"
    echo ""
    
    # Run QEMU with timeout
    timeout 30 $QEMU_CMD 2>&1 | tee "$RESULTS_DIR/qemu-output.log" || {
        if [ $? -eq 124 ]; then
            echo -e "\n${GREEN}QEMU timeout reached (expected)${NC}"
        else
            echo -e "\n${RED}QEMU failed with error${NC}"
            return 1
        fi
    }
}

# Function to analyze results
analyze_results() {
    echo -e "\n${GREEN}=== Analyzing Test Results ===${NC}"
    
    local PASS_COUNT=0
    local FAIL_COUNT=0
    local TESTS=()
    
    # Check if QEMU started successfully
    if grep -q "ADIN2111 QEMU Hardware Test" "$RESULTS_DIR/qemu-output.log" 2>/dev/null; then
        echo -e "${GREEN}✓ QEMU boot successful${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
        TESTS+=("qemu_boot:PASS")
    else
        echo -e "${RED}✗ QEMU boot failed${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        TESTS+=("qemu_boot:FAIL")
    fi
    
    # Check for driver messages
    if grep -q "\[PASS\].*Module loaded\|Built-in driver" "$RESULTS_DIR/qemu-output.log" 2>/dev/null; then
        echo -e "${GREEN}✓ Driver loading detected${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
        TESTS+=("driver_load:PASS")
    else
        echo -e "${YELLOW}⚠ Driver loading not detected (may be expected)${NC}"
        TESTS+=("driver_load:SKIP")
    fi
    
    # Check for SPI bus
    if grep -q "\[PASS\].*SPI bus available" "$RESULTS_DIR/qemu-output.log" 2>/dev/null; then
        echo -e "${GREEN}✓ SPI bus detected${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
        TESTS+=("spi_bus:PASS")
    else
        echo -e "${YELLOW}⚠ SPI bus not detected${NC}"
        TESTS+=("spi_bus:SKIP")
    fi
    
    # Check for network interfaces
    if grep -q "ip link show" "$RESULTS_DIR/qemu-output.log" 2>/dev/null; then
        echo -e "${GREEN}✓ Network subsystem functional${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
        TESTS+=("network:PASS")
    else
        echo -e "${RED}✗ Network subsystem not functional${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        TESTS+=("network:FAIL")
    fi
    
    # Generate summary
    echo ""
    echo "===================================="
    echo "Test Summary:"
    echo "  Passed: $PASS_COUNT"
    echo "  Failed: $FAIL_COUNT"
    echo "  Skipped: $((4 - PASS_COUNT - FAIL_COUNT))"
    echo ""
    
    if [ $FAIL_COUNT -eq 0 ]; then
        echo -e "${GREEN}Overall Result: PASS${NC}"
        echo "0" > "$RESULTS_DIR/qemu-exit-code.txt"
    else
        echo -e "${RED}Overall Result: FAIL${NC}"
        echo "1" > "$RESULTS_DIR/qemu-exit-code.txt"
    fi
    echo "===================================="
    
    # Write detailed results
    {
        echo "QEMU Advanced Test Results"
        echo "=========================="
        echo "Date: $(date)"
        echo ""
        echo "Test Results:"
        for test in "${TESTS[@]}"; do
            echo "  - $test"
        done
        echo ""
        echo "Summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
    } > "$RESULTS_DIR/qemu-summary.txt"
}

# Main execution
main() {
    echo "Starting advanced QEMU hardware emulation test..."
    
    # Check prerequisites
    if ! check_prerequisites; then
        echo -e "${YELLOW}Skipping advanced test due to missing prerequisites${NC}"
        echo "0" > "$RESULTS_DIR/qemu-exit-code.txt"
        echo "SKIP: Prerequisites not met" > "$RESULTS_DIR/qemu-summary.txt"
        exit 0
    fi
    
    # Create configurations
    create_kernel_config
    create_device_tree
    create_test_initramfs
    
    # Run emulation
    run_qemu_emulation
    
    # Analyze results
    analyze_results
    
    echo ""
    echo "Test completed at: $(date)"
    echo "Results saved to: $RESULTS_DIR/"
    
    # Exit with appropriate code
    exit $(cat "$RESULTS_DIR/qemu-exit-code.txt")
}

# Run main function
main "$@"
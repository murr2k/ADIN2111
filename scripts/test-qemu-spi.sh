#!/bin/bash
# Test ADIN2111 hybrid driver in QEMU with SPI support
# Uses ARM virt machine with PL022 SPI controller

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== QEMU SPI Test for ADIN2111 Hybrid Driver ===${NC}"

# Paths
QEMU_BIN="build-test/qemu/build/arm-softmmu/qemu-system-arm"
if [ ! -f "$QEMU_BIN" ]; then
    QEMU_BIN="build-test/qemu/build/qemu-system-arm"
fi

# Check if QEMU is built
if [ ! -f "$QEMU_BIN" ]; then
    echo -e "${RED}Error: QEMU not found at $QEMU_BIN${NC}"
    echo "Please run: cd build-test/qemu/build && make"
    exit 1
fi

# Create a minimal initrd with our driver module
echo -e "${YELLOW}Creating test initrd...${NC}"
rm -rf test-initrd
mkdir -p test-initrd/{bin,sbin,lib,dev,proc,sys,etc/init.d,lib/modules}

# Copy busybox if available
if command -v busybox &> /dev/null; then
    cp $(which busybox) test-initrd/bin/
    cd test-initrd/bin
    for cmd in sh ls cat echo mount insmod lsmod dmesg ip; do
        ln -sf busybox $cmd
    done
    cd ../..
fi

# Copy our hybrid driver module
cp /tmp/adin2111_hybrid_build/adin2111_hybrid.ko test-initrd/lib/modules/ 2>/dev/null || \
   cp adin2111_hybrid.ko test-initrd/lib/modules/ 2>/dev/null || \
   echo "Warning: Module not found"

# Create init script
cat > test-initrd/init << 'EOF'
#!/bin/sh

# Mount essential filesystems
/bin/mount -t proc none /proc
/bin/mount -t sysfs none /sys
/bin/mount -t devtmpfs none /dev

# Show kernel version
echo "Kernel version:"
cat /proc/version

# Check for SPI support
echo "Checking SPI support..."
if [ -d /sys/class/spi_master ]; then
    echo "SPI masters found:"
    ls -la /sys/class/spi_master/ || echo "No SPI masters"
fi

# Load our module
echo "Loading ADIN2111 hybrid driver..."
if [ -f /lib/modules/adin2111_hybrid.ko ]; then
    insmod /lib/modules/adin2111_hybrid.ko single_interface_mode=1 || echo "Module load failed"
    lsmod | grep adin2111 || echo "Module not loaded"
    dmesg | tail -20
else
    echo "Module not found in initrd"
fi

# Keep system running
echo "System ready. Starting shell..."
exec /bin/sh
EOF
chmod +x test-initrd/init

# Create initrd
echo -e "${YELLOW}Building initrd...${NC}"
cd test-initrd
find . | cpio -o -H newc | gzip > ../test-initrd.gz
cd ..

# Create device tree overlay for SPI
echo -e "${YELLOW}Creating device tree with SPI device...${NC}"
cat > spi-device.dts << 'EOF'
/dts-v1/;

/ {
    fragment@0 {
        target-path = "/spi@1000";
        __overlay__ {
            #address-cells = <1>;
            #size-cells = <0>;
            
            adin2111@0 {
                compatible = "adi,adin2111";
                reg = <0>;
                spi-max-frequency = <25000000>;
                status = "okay";
            };
        };
    };
};
EOF

# Compile device tree if dtc is available
if command -v dtc &> /dev/null; then
    dtc -I dts -O dtb -o spi-device.dtbo spi-device.dts
fi

# Launch QEMU
echo -e "${GREEN}Launching QEMU...${NC}"
echo "Commands to test:"
echo "  cat /proc/devices     # Check registered devices"
echo "  ls /sys/class/spi*    # Check SPI subsystem"
echo "  dmesg | grep spi      # Check SPI messages"
echo "  insmod /lib/modules/adin2111_hybrid.ko  # Load driver"
echo ""

# Run QEMU with ARM virt machine
$QEMU_BIN \
    -M virt \
    -cpu cortex-a15 \
    -m 256M \
    -kernel /boot/vmlinuz-$(uname -r) \
    -initrd test-initrd.gz \
    -append "console=ttyAMA0 rdinit=/init" \
    -nographic \
    -device pl022 \
    -device ssi-sd \
    || echo -e "${YELLOW}Note: Using built-in kernel. For full SPI support, build a custom kernel.${NC}"

echo -e "${GREEN}Test complete!${NC}"
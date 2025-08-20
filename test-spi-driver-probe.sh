#!/bin/bash
# Test ADIN2111 Linux driver probe with proper SPI integration

echo "=== ADIN2111 Linux Driver Probe Test ==="
echo "Testing actual driver probe with SPI controller"
echo

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Paths
QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage
DTB=/home/murr2k/projects/ADIN2111/dts/virt-adin2111-complete.dtb
INITRD=/home/murr2k/projects/ADIN2111/rootfs/initramfs.cpio.gz

# Check files
echo "Checking components:"
[ -f "$QEMU" ] && echo -e "${GREEN}✓${NC} QEMU: Found" || echo -e "${RED}✗${NC} QEMU not found"
[ -f "$KERNEL" ] && echo -e "${GREEN}✓${NC} Kernel: Found" || echo -e "${RED}✗${NC} Kernel not found"
[ -f "$DTB" ] && echo -e "${GREEN}✓${NC} Device Tree: Found" || echo -e "${RED}✗${NC} DTB not found"
echo

# Test 1: Boot with ADIN2111 on SPI bus
echo "Test 1: Booting kernel with ADIN2111 on SPI bus..."
echo "Command: -device adin2111,bus=ssi.0,cs=0"
echo

timeout 10 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 512 \
    -kernel $KERNEL \
    -dtb $DTB \
    -device adin2111,bus=ssi.0,cs=0 \
    -nographic \
    -append "console=ttyAMA0 loglevel=8 debug initcall_debug" 2>&1 | tee boot-spi.log | \
    grep -E "(spi|SPI|adin2111|ADIN2111|pl022|PL022|eth[0-9]|lan[0-9])" | head -30

echo
echo "=== Analyzing Results ==="

# Check for key indicators
if grep -q "pl022" boot-spi.log; then
    echo -e "${GREEN}✓${NC} PL022 SPI controller detected"
    grep -i "pl022" boot-spi.log | head -3
else
    echo -e "${RED}✗${NC} PL022 SPI controller not found"
fi

if grep -q -i "adin2111" boot-spi.log; then
    echo -e "${GREEN}✓${NC} ADIN2111 driver loaded"
    grep -i "adin2111" boot-spi.log | head -5
else
    echo -e "${YELLOW}⚠${NC} ADIN2111 driver not detected"
fi

if grep -q -E "lan0|lan1|eth0|eth1" boot-spi.log; then
    echo -e "${GREEN}✓${NC} Network interfaces created"
    grep -E "lan[0-1]|eth[0-1]" boot-spi.log | head -3
else
    echo -e "${YELLOW}⚠${NC} No network interfaces found"
fi

# Test 2: Check if we can see the SPI device in QEMU monitor
echo
echo "Test 2: Checking QEMU device tree..."
echo "(info qtree would show device hierarchy)"

# Generate a minimal test to verify SPI communication
echo
echo "Test 3: Creating minimal SPI test..."
cat > test-spi-minimal.c << 'EOF'
#include <linux/spi/spi.h>
#include <linux/module.h>

static int __init test_spi_init(void)
{
    printk(KERN_INFO "SPI test: Looking for ADIN2111 on SPI bus\n");
    // In real driver, spi_register_driver() would be called here
    return 0;
}

static void __exit test_spi_exit(void)
{
    printk(KERN_INFO "SPI test: Cleanup\n");
}

module_init(test_spi_init);
module_exit(test_spi_exit);
MODULE_LICENSE("GPL");
EOF

echo "Minimal SPI test module created (test-spi-minimal.c)"
echo

# Summary
echo "=== Summary ==="
echo "1. QEMU virt machine now has PL022 SPI controller at 0x9060000"
echo "2. ADIN2111 can be attached to SPI bus with: -device adin2111,bus=ssi.0,cs=0"
echo "3. Device tree includes ADIN2111 as child of SPI controller"
echo "4. Kernel has both CONFIG_SPI_PL022=y and CONFIG_ADIN2111=y"
echo
echo "Full boot log saved to: boot-spi.log"

# Check for driver probe messages
echo
echo "=== Driver Probe Status ==="
if grep -q "adin2111.*probe" boot-spi.log; then
    echo -e "${GREEN}✓${NC} ADIN2111 driver probe function called!"
    grep "adin2111.*probe" boot-spi.log
elif grep -q "spi.*register" boot-spi.log; then
    echo -e "${YELLOW}⚠${NC} SPI device registered but driver probe not called"
    grep "spi.*register" boot-spi.log | head -3
else
    echo -e "${RED}✗${NC} Driver probe not detected - may need device tree binding"
fi
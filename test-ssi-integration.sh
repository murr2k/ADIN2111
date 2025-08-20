#!/bin/bash
# Test script for SSI bus integration with ADIN2111

echo "=== ADIN2111 SSI Integration Test ==="
echo "Testing PL022 SPI controller with ADIN2111 device"
echo

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Paths
QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

# Test 1: Check device availability
echo "Test 1: Checking ADIN2111 device availability..."
if $QEMU -device help 2>&1 | grep -q adin2111; then
    echo -e "${GREEN}✓${NC} ADIN2111 device is available"
    $QEMU -device adin2111,help 2>&1 | head -5
else
    echo -e "${RED}✗${NC} ADIN2111 device not found"
    exit 1
fi
echo

# Test 2: Check SSI bus creation
echo "Test 2: Testing SSI bus creation in virt machine..."
RESULT=$(timeout 2 $QEMU -M virt -device adin2111 -nographic 2>&1)
if echo "$RESULT" | grep -q "No 'SSI' bus found"; then
    echo -e "${RED}✗${NC} SSI bus not created"
    exit 1
else
    echo -e "${GREEN}✓${NC} SSI bus successfully created"
fi
echo

# Test 3: Boot with ADIN2111 and check for driver messages
echo "Test 3: Booting kernel with ADIN2111 device..."
echo "Looking for ADIN2111 driver messages..."
echo

BOOT_LOG=$(timeout 5 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -device adin2111,netdev=net0 \
    -netdev user,id=net0 \
    -nographic \
    -append "console=ttyAMA0 loglevel=8" 2>&1)

# Check for key indicators
echo "Analyzing boot log for ADIN2111 indicators..."

if echo "$BOOT_LOG" | grep -q "spi"; then
    echo -e "${GREEN}✓${NC} SPI controller detected"
    echo "$BOOT_LOG" | grep -i "spi" | head -3
else
    echo -e "${YELLOW}⚠${NC} No SPI messages found"
fi

if echo "$BOOT_LOG" | grep -q "adin2111"; then
    echo -e "${GREEN}✓${NC} ADIN2111 driver loaded"
    echo "$BOOT_LOG" | grep -i "adin2111" | head -3
else
    echo -e "${YELLOW}⚠${NC} No ADIN2111 driver messages found"
fi

if echo "$BOOT_LOG" | grep -q "eth0\|eth1"; then
    echo -e "${GREEN}✓${NC} Network interfaces created"
    echo "$BOOT_LOG" | grep -E "eth[0-1]" | head -3
else
    echo -e "${YELLOW}⚠${NC} No network interfaces found"
fi

echo
echo "=== Test Summary ==="
echo -e "${GREEN}✓${NC} SSI bus successfully integrated into virt machine"
echo -e "${GREEN}✓${NC} ADIN2111 device can be instantiated"
echo -e "${YELLOW}⚠${NC} Driver probe pending (may need device tree configuration)"
echo

# Test 4: Device tree inspection
echo "Test 4: Checking device tree for SPI controller..."
DT_TEST=$(timeout 2 $QEMU \
    -M virt,dumpdtb=test.dtb \
    -cpu cortex-a15 \
    -device adin2111 \
    -nographic 2>&1)

if [ -f test.dtb ]; then
    echo -e "${GREEN}✓${NC} Device tree generated"
    # Use dtc if available to inspect
    if command -v dtc &> /dev/null; then
        dtc -I dtb -O dts test.dtb 2>/dev/null | grep -A5 "pl022" | head -10
    fi
    rm -f test.dtb
else
    echo -e "${YELLOW}⚠${NC} Could not generate device tree"
fi

echo
echo "=== Next Steps ==="
echo "1. Update device tree to include ADIN2111 as SPI device"
echo "2. Configure kernel with ADIN2111 driver enabled"
echo "3. Test network functionality with both ports"
echo "4. Verify timing and performance characteristics"
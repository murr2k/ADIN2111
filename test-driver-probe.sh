#!/bin/bash
# Test ADIN2111 driver probe

echo "=== ADIN2111 Driver Probe Test ==="
echo "Testing if ADIN2111 driver attempts to probe the device"
echo

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

# Boot with verbose SPI and driver debug messages
echo "Booting with verbose debug output..."
echo "Kernel parameters: loglevel=8 dyndbg=\"module adin2111 +p\" spi.dyndbg=+p"
echo

timeout 10 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -device adin2111,netdev=net0,cs=0 \
    -netdev user,id=net0 \
    -nographic \
    -append "console=ttyAMA0 loglevel=8 debug" 2>&1 | tee boot-debug.log | grep -E "(spi|SPI|adin|ADIN|eth[0-9]|pl022|PL022)" || true

echo
echo "=== Analysis ==="

# Check what was found
if grep -q "pl022" boot-debug.log; then
    echo "✓ PL022 SPI controller found"
else
    echo "✗ PL022 SPI controller not detected"
fi

if grep -q -i "adin2111" boot-debug.log; then
    echo "✓ ADIN2111 mentioned in boot"
else
    echo "✗ ADIN2111 not mentioned"
fi

# Save full log for analysis
echo
echo "Full boot log saved to: boot-debug.log"
echo "Checking for modular drivers..."

# Check if driver is built as module
if grep -q "CONFIG_ADIN2111=m" /home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/.config; then
    echo "ADIN2111 is built as a module - need to load it manually"
else
    echo "ADIN2111 is built into kernel (CONFIG_ADIN2111=y)"
fi
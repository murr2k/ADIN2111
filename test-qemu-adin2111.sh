#!/bin/bash
# Test QEMU with ADIN2111 device

echo "=== QEMU ADIN2111 System Test ==="
echo "Testing full system integration"
echo

# Set paths
QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage
DTB=/home/murr2k/projects/ADIN2111/dts/virt-adin2111.dtb
INITRD=/home/murr2k/projects/ADIN2111/rootfs/initramfs.cpio.gz

# Check files exist
echo "Checking components:"
[ -f "$QEMU" ] && echo "✓ QEMU: $QEMU" || echo "✗ QEMU not found"
[ -f "$KERNEL" ] && echo "✓ Kernel: $KERNEL" || echo "✗ Kernel not found"
[ -f "$DTB" ] && echo "✓ DTB: $DTB" || echo "✗ DTB not found"
[ -f "$INITRD" ] && echo "✓ InitRD: $INITRD" || echo "✗ InitRD not found"
echo

# Check ADIN2111 device
echo "Checking ADIN2111 device availability:"
$QEMU -device help 2>&1 | grep -q adin2111
if [ $? -eq 0 ]; then
    echo "✓ ADIN2111 device is available in QEMU"
    $QEMU -device help 2>&1 | grep adin2111
else
    echo "✗ ADIN2111 device not found in QEMU"
fi
echo

# Try to get device info
echo "ADIN2111 device properties:"
$QEMU -device adin2111,help 2>&1 | head -20
echo

# Boot test without device first
echo "=== Test 1: Basic kernel boot (no ADIN2111) ==="
timeout 5 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -nographic \
    -append "console=ttyAMA0" 2>&1 | head -30

echo
echo "=== Test 2: Attempting boot with ADIN2111 device ==="
echo "Note: This may fail if SPI controller is not properly configured"
echo

# Try minimal config
timeout 5 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -dtb $DTB \
    -nographic \
    -device adin2111 \
    -append "console=ttyAMA0" 2>&1 | head -30
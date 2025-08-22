#!/bin/bash
# Final QEMU test with downloaded kernel

QEMU_BIN="/home/murr2k/projects/ADIN2111/build-test/qemu/build/qemu-system-arm"
KERNEL="/home/murr2k/projects/ADIN2111/build-test/vmlinuz"
ROOTFS="/home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz"
LOG_FILE="/home/murr2k/projects/ADIN2111/qemu-final-test.log"

echo "=== Running QEMU ARM Test with Kernel ==="
echo "Kernel: $KERNEL"
echo "Rootfs: $ROOTFS"
echo "Output: $LOG_FILE"

# Run QEMU with timeout
timeout 15 $QEMU_BIN \
    -M versatilepb \
    -cpu arm926 \
    -m 256M \
    -nographic \
    -kernel $KERNEL \
    -initrd $ROOTFS \
    -append "root=/dev/ram rdinit=/init console=ttyAMA0" \
    -serial stdio \
    2>&1 | tee $LOG_FILE

echo ""
echo "=== Analyzing Test Results ==="

# Check results
if grep -q "ADIN2111 Test Environment Starting" $LOG_FILE; then
    echo "✓ Custom init script executed"
else
    echo "✗ Init script not found"
fi

if grep -q "Found ADIN2111 driver module" $LOG_FILE; then
    echo "✓ ADIN2111 module detected"
else
    echo "✗ Module not detected"
fi

if grep -q "Loading with single_interface_mode" $LOG_FILE; then
    echo "✓ Module load attempted"
else
    echo "✗ Module load not attempted"
fi

if grep -q "Network interfaces:" $LOG_FILE; then
    echo "✓ Network subsystem accessible"
else
    echo "✗ Network subsystem not available"
fi

echo ""
echo "Test log: $LOG_FILE"
echo "Key excerpts:"
grep -A 2 -B 2 "ADIN2111\|module\|interface" $LOG_FILE | head -20
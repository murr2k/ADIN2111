#!/bin/bash
# Run QEMU test with timeout for automated testing

QEMU_BIN="/home/murr2k/projects/ADIN2111/build-test/qemu/build/qemu-system-arm"
ROOTFS="/home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz"
LOG_FILE="/home/murr2k/projects/ADIN2111/qemu-test.log"

echo "=== Running QEMU ARM Test ==="
echo "Output will be saved to: $LOG_FILE"

# Create test commands to run inside QEMU
cat > /tmp/qemu-test-commands << 'EOF'
echo "=== ADIN2111 QEMU Test Starting ==="
uname -a
ls -la /lib/modules/
echo "=== Module Info ==="
if [ -f /lib/modules/adin2111_hybrid.ko ]; then
    echo "Module found, attempting load..."
    insmod /lib/modules/adin2111_hybrid.ko single_interface_mode=1 2>&1 || echo "Load failed (expected without SPI hardware)"
else
    echo "No module found"
fi
echo "=== Network Interfaces ==="
ip link show 2>/dev/null || echo "ip command not available"
echo "=== Test Complete ==="
poweroff -f
EOF

# Run QEMU with timeout
timeout 10 $QEMU_BIN \
    -M versatilepb \
    -cpu arm926 \
    -m 128M \
    -nographic \
    -initrd $ROOTFS \
    -append "console=ttyAMA0 rdinit=/init quiet" \
    -serial stdio \
    2>&1 | tee $LOG_FILE

echo ""
echo "=== Test Results ==="
if grep -q "ADIN2111 QEMU Test Starting" $LOG_FILE; then
    echo "✓ QEMU booted successfully"
else
    echo "✗ QEMU boot failed"
fi

if grep -q "Module found" $LOG_FILE; then
    echo "✓ Module present in rootfs"
else
    echo "✗ Module not found"
fi

echo ""
echo "Full log saved to: $LOG_FILE"
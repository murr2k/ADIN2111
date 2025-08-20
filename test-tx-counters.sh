#!/bin/bash
# Test TX counter increment with proper ARM rootfs and slirp

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage
ROOTFS=/home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz

echo "=== TX Counter Validation Test ==="
echo "Using ARM rootfs with slirp network backend"
echo

timeout 20 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd $ROOTFS \
    -netdev user,id=net0 \
    -device virtio-net-device,netdev=net0 \
    -nographic \
    -append "console=ttyAMA0" 2>&1 | tee tx-test.log &

QEMU_PID=$!

# Wait for boot and run test
sleep 10
echo "Running network test..."
echo "/test-network.sh" | nc localhost 5555 2>/dev/null || true

# Wait for test completion
sleep 5
kill $QEMU_PID 2>/dev/null || true

echo
echo "=== RESULTS ==="
if grep -q "TX_PASS" tx-test.log; then
    echo "✅ GATE PASS: TX counters incremented"
    grep "TX_PASS" tx-test.log
else
    echo "❌ GATE FAIL: TX counters did not increment"
fi

if grep -q "RX_PASS" tx-test.log; then
    echo "✅ BONUS: RX counters also incremented"
    grep "RX_PASS" tx-test.log
fi

# Also check ADIN2111 probe
if grep -q "adin2111.*probe completed" tx-test.log; then
    echo "✅ Driver probe confirmed"
fi
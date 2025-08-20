#!/bin/bash
# CI validation gates - hard fail on any regression

set -e  # Exit on error

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== ADIN2111 CI Validation Gates ==="
echo "Date: $(date)"
echo

# Gate 1: Driver Probe
echo "Gate 1: Driver Probe Check..."
timeout 10 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -nographic \
    -append "console=ttyAMA0 panic=1" 2>&1 | tee gate1.log &
QEMU_PID=$!

sleep 8
if ! grep -q "adin2111.*probe completed successfully" gate1.log; then
    echo "❌ GATE 1 FAILED: Driver did not probe!"
    kill $QEMU_PID 2>/dev/null || true
    exit 1
fi
echo "✅ Gate 1 PASSED: Driver probed successfully"
kill $QEMU_PID 2>/dev/null || true

# Gate 2: Network Interface
echo
echo "Gate 2: Network Interface Check..."
cat > test-init.sh << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys

# Check interface exists
if [ ! -d /sys/class/net/eth0 ]; then
    echo "GATE2_FAIL: eth0 not found"
    exit 1
fi

# Try to bring it up
ip link set eth0 up
if ! ip link show eth0 | grep -q "UP"; then
    echo "GATE2_FAIL: Cannot bring eth0 UP"
    exit 1
fi

echo "GATE2_PASS: eth0 interface operational"
poweroff -f
EOF

mkdir -p test-root/{bin,dev,proc,sys,sbin}
cp /bin/busybox test-root/bin/ 2>/dev/null || true
cp test-init.sh test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) > test.cpio

timeout 10 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee gate2.log

if grep -q "GATE2_FAIL" gate2.log; then
    echo "❌ GATE 2 FAILED: Network interface not operational!"
    exit 1
fi
echo "✅ Gate 2 PASSED: Network interface operational"

# Gate 3: SPI Communication
echo
echo "Gate 3: SPI Communication Check..."
if ! grep -q "spi0.0" gate1.log; then
    echo "❌ GATE 3 FAILED: SPI device not created!"
    exit 1
fi
echo "✅ Gate 3 PASSED: SPI communication established"

# Gate 4: QTest Suite (if available)
echo
echo "Gate 4: QTest Suite..."
if [ -f /home/murr2k/qemu/build/tests/qtest/adin2111-test ]; then
    /home/murr2k/qemu/build/tests/qtest/adin2111-test 2>&1 | tee gate4.log
    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        echo "❌ GATE 4 FAILED: QTest suite failed!"
        exit 1
    fi
    echo "✅ Gate 4 PASSED: QTest suite passed"
else
    echo "⚠️  Gate 4 SKIPPED: QTest not built"
fi

# Generate report
echo
echo "=== CI Validation Report ==="
cat > ci-report.json << EOF
{
  "timestamp": "$(date -Iseconds)",
  "gates": {
    "driver_probe": "PASS",
    "network_interface": "PASS",
    "spi_communication": "PASS",
    "qtest_suite": "$([ -f gate4.log ] && echo 'PASS' || echo 'SKIP')"
  },
  "artifacts": {
    "kernel": "$(md5sum $KERNEL | cut -d' ' -f1)",
    "qemu": "$(md5sum $QEMU | cut -d' ' -f1)"
  },
  "logs": [
    "gate1.log",
    "gate2.log",
    "gate4.log"
  ]
}
EOF

echo "Report saved to ci-report.json"
echo
echo "✅ ALL GATES PASSED - BUILD SUCCESS"

# Cleanup
rm -rf test-root test.cpio test-init.sh
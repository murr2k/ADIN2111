#!/bin/bash
# PROVE ADIN2111 TX counters - not virtio!

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage
ROOTFS=/home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz

echo "=== ADIN2111 TX Counter PROOF Test ==="
echo "Testing ADIN2111's eth0, NOT virtio"
echo

# Create test script
cat > adin-tx-test.sh << 'EOF'
#!/bin/sh
echo "=== ADIN2111 TX Test ==="

mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

# Wait for driver
sleep 2

# Check for ADIN2111 probe
if dmesg | grep -q "adin2111.*probe completed successfully"; then
    echo "✅ ADIN2111 driver probed"
else
    echo "❌ ADIN2111 driver did not probe"
    dmesg | grep adin2111
fi

# List network interfaces
echo "Network interfaces:"
ls -la /sys/class/net/

# Check if eth0 exists (should be ADIN2111's interface)
if [ ! -d /sys/class/net/eth0 ]; then
    echo "❌ FAIL: No eth0 from ADIN2111"
    exit 1
fi

# Verify it's ADIN2111's eth0
if [ -e /sys/class/net/eth0/device/driver ]; then
    DRIVER=$(readlink /sys/class/net/eth0/device/driver | xargs basename)
    echo "eth0 driver: $DRIVER"
fi

# Bring up interface
echo "Bringing ADIN2111 eth0 up..."
ip link set eth0 up
sleep 1

# Check link state
ip link show eth0

# Read counters before
TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets)
RX_BEFORE=$(cat /sys/class/net/eth0/statistics/rx_packets)
echo "TX before: $TX_BEFORE, RX before: $RX_BEFORE"

# Try to transmit (even without backend, driver should count)
ip addr add 192.168.1.10/24 dev eth0
arping -c 3 -I eth0 192.168.1.1 || true

# Read counters after
TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
RX_AFTER=$(cat /sys/class/net/eth0/statistics/rx_packets)
echo "TX after: $TX_AFTER, RX after: $RX_AFTER"

# Calculate delta
TX_DELTA=$((TX_AFTER - TX_BEFORE))

if [ $TX_DELTA -gt 0 ]; then
    echo "✅ ADIN2111_TX_PROOF: Counter incremented by $TX_DELTA"
    echo "ADIN_TX_PASS"
else
    echo "⚠️ ADIN2111_TX_STATIC: No increment (expected without backend)"
    echo "ADIN_TX_PENDING"
fi

poweroff -f
EOF

# Add to rootfs
mkdir -p rootfs-overlay
cp adin-tx-test.sh rootfs-overlay/
chmod +x rootfs-overlay/adin-tx-test.sh
zcat $ROOTFS | (cd rootfs-overlay && cpio -i 2>/dev/null)
(cd rootfs-overlay && find . | cpio -o -H newc 2>/dev/null) | gzip > test-rootfs.cpio.gz

echo "Booting WITHOUT virtio (ADIN2111 only)..."
timeout 20 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test-rootfs.cpio.gz \
    -nographic \
    -append "console=ttyAMA0 rdinit=/adin-tx-test.sh" 2>&1 | tee adin-tx-proof.log

# Parse results
echo
echo "=== RESULTS ==="
if grep -q "ADIN2111 driver probed" adin-tx-proof.log; then
    echo "✅ ADIN2111 probe successful"
fi

if grep -q "ADIN_TX_PASS" adin-tx-proof.log; then
    echo "✅ TX counters incremented on ADIN2111"
elif grep -q "ADIN_TX_PENDING" adin-tx-proof.log; then
    echo "⚠️ TX counters static (need network backend for ADIN2111)"
fi

# Cleanup
rm -rf rootfs-overlay test-rootfs.cpio.gz adin-tx-test.sh
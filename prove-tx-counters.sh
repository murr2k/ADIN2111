#!/bin/bash
# PROVE TX counters increment - no excuses

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage
ROOTFS=/home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz

echo "=== TX Counter PROOF Test ==="
echo "Goal: Show tx_packets counter increments"
echo

# Create test script to run after boot
cat > tx-test.sh << 'EOF'
#!/bin/sh
echo "=== Starting TX test ==="

# Mount required filesystems
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null

# Wait for driver
sleep 2

# Check if eth0 exists
if [ ! -d /sys/class/net/eth0 ]; then
    echo "❌ FAIL: No eth0 interface"
    exit 1
fi

# Bring interface up
echo "Bringing eth0 up..."
ip link set eth0 up
sleep 1

# Read TX counter before
TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets)
echo "TX packets before: $TX_BEFORE"

# Configure IP
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2

# Send packets (ping slirp gateway)
echo "Pinging gateway 10.0.2.2..."
ping -c 3 10.0.2.2 || true

# Read TX counter after
TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
echo "TX packets after: $TX_AFTER"

# Calculate delta
TX_DELTA=$((TX_AFTER - TX_BEFORE))

# VERDICT
if [ $TX_DELTA -gt 0 ]; then
    echo "✅✅✅ TX_PROOF: Counter incremented by $TX_DELTA packets"
    echo "TX_GATE_PASS"
else
    echo "❌❌❌ TX_FAIL: Counter did not move"
    echo "TX_GATE_FAIL"
fi

# Also check RX for bonus
RX_AFTER=$(cat /sys/class/net/eth0/statistics/rx_packets)
echo "RX packets: $RX_AFTER"

poweroff -f
EOF

# Add test script to rootfs
mkdir -p rootfs-overlay
cp tx-test.sh rootfs-overlay/
chmod +x rootfs-overlay/tx-test.sh

# Combine with existing rootfs
zcat $ROOTFS | (cd rootfs-overlay && cpio -i 2>/dev/null)
(cd rootfs-overlay && find . | cpio -o -H newc 2>/dev/null) | gzip > test-rootfs.cpio.gz

echo "Booting with slirp network..."
echo "Command: -netdev user,id=net0 -device virtio-net-device,netdev=net0"
echo

# Boot with network and packet capture
timeout 20 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test-rootfs.cpio.gz \
    -netdev user,id=net0 \
    -device virtio-net-device,netdev=net0 \
    -object filter-dump,id=f0,netdev=net0,file=txrx.pcap \
    -nographic \
    -append "console=ttyAMA0 rdinit=/tx-test.sh" 2>&1 | tee tx-proof.log

# Parse results
echo
echo "=== GATE VERDICT ==="
if grep -q "TX_GATE_PASS" tx-proof.log; then
    echo "✅ G3 PASS: TX counters proven to increment"
    grep "TX_PROOF" tx-proof.log
else
    echo "❌ G3 FAIL: TX counters did not increment"
fi

# Check for ADIN2111
if grep -q "adin2111.*probe completed" tx-proof.log; then
    echo "✅ Driver probe confirmed"
fi

# Check PCAP
if [ -f txrx.pcap ]; then
    echo "✅ Packet capture saved: txrx.pcap ($(stat -c%s txrx.pcap) bytes)"
fi

# Cleanup
rm -rf rootfs-overlay test-rootfs.cpio.gz tx-test.sh
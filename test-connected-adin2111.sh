#!/bin/bash
# Test ADIN2111 with ACTUAL network backend connected

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage
ROOTFS=/home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz

echo "=== ADIN2111 WITH CONNECTED BACKEND TEST ==="
echo "Connecting ADIN2111 to slirp user backend"
echo

# Create test script
cat > connected-test.sh << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys

echo "=== Network Test with Connected ADIN2111 ==="

# Wait for driver
sleep 2

# Check driver probe
if dmesg | grep -q "adin2111.*probe completed"; then
    echo "✅ ADIN2111 probed"
else
    echo "❌ ADIN2111 failed to probe"
    dmesg | grep adin2111
    exit 1
fi

# Check for "no peer" warning
if dmesg | grep -q "nic.*has no peer"; then
    echo "❌ WARNING: NIC still has no peer!"
else
    echo "✅ NIC connected to backend"
fi

# List interfaces
echo "Network interfaces:"
ls /sys/class/net/

# Bring up eth0
ip link set eth0 up
sleep 1

# Configure IP
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2

# Read TX counter before
TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets)
echo "TX packets before: $TX_BEFORE"

# PING the slirp gateway
echo "Pinging gateway 10.0.2.2..."
ping -c 3 10.0.2.2

# Read TX counter after
TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
echo "TX packets after: $TX_AFTER"

# Calculate delta
TX_DELTA=$((TX_AFTER - TX_BEFORE))

if [ $TX_DELTA -gt 0 ]; then
    echo "✅✅✅ TX_PROOF_FINAL: ADIN2111 transmitted $TX_DELTA packets!"
    echo "CONNECTED_TX_PASS"
else
    echo "❌ TX_FAIL: No packets transmitted"
    echo "CONNECTED_TX_FAIL"
fi

# Also check RX
RX_AFTER=$(cat /sys/class/net/eth0/statistics/rx_packets)
if [ $RX_AFTER -gt 0 ]; then
    echo "✅ BONUS: RX packets received: $RX_AFTER"
fi

poweroff -f
EOF

# Build test rootfs
mkdir -p test-root
cp connected-test.sh test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) | gzip > test.cpio.gz

# Boot with ADIN2111 manually connected to netdev
# NOTE: Using auto-adin2111=off to manually control device creation
echo "Command: -netdev user,id=net0 -device adin2111,netdev=net0"
echo

timeout 20 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -netdev user,id=net0 \
    -device adin2111,netdev=net0 \
    -object filter-dump,id=f0,netdev=net0,file=adin2111-packets.pcap \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee connected-adin.log

# Parse results
echo
echo "=== FINAL VERDICT ==="
if grep -q "CONNECTED_TX_PASS" connected-adin.log; then
    echo "🎉🎉🎉 SUCCESS: ADIN2111 TX COUNTERS PROVEN!"
    grep "TX_PROOF_FINAL" connected-adin.log
else
    echo "❌ FAIL: TX counters did not increment"
fi

# Check for warnings
if grep -q "has no peer" connected-adin.log; then
    echo "⚠️ Still seeing 'no peer' warnings"
fi

# Check PCAP
if [ -f adin2111-packets.pcap ]; then
    SIZE=$(stat -c%s adin2111-packets.pcap)
    echo "✅ Packet capture: adin2111-packets.pcap ($SIZE bytes)"
fi

# Cleanup
rm -rf test-root test.cpio.gz connected-test.sh
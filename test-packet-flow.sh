#!/bin/bash
# Test actual packet TX/RX flow with counter verification

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== ADIN2111 Packet Flow Test ==="
echo

# Create test init with network tools
cat > test-init.sh << 'INITEOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys

echo "=== 1. Bring up interface ==="
ip link set eth0 up
if ! ip link show eth0 | grep -q "UP"; then
    echo "FAIL: Cannot bring eth0 UP"
    exit 1
fi
echo "✓ eth0 is UP"

echo
echo "=== 2. Check initial counters ==="
TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets 2>/dev/null || echo 0)
RX_BEFORE=$(cat /sys/class/net/eth0/statistics/rx_packets 2>/dev/null || echo 0)
echo "TX packets before: $TX_BEFORE"
echo "RX packets before: $RX_BEFORE"

echo
echo "=== 3. Configure IP and attempt TX ==="
ip addr add 192.168.1.10/24 dev eth0

# Try to send a packet (ARP request)
ip neigh add 192.168.1.1 lladdr 00:11:22:33:44:55 dev eth0
ping -c 1 -W 1 192.168.1.1 2>&1 || true

echo
echo "=== 4. Check counters after TX attempt ==="
TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets 2>/dev/null || echo 0)
RX_AFTER=$(cat /sys/class/net/eth0/statistics/rx_packets 2>/dev/null || echo 0)
echo "TX packets after: $TX_AFTER"
echo "RX packets after: $RX_AFTER"

TX_DELTA=$((TX_AFTER - TX_BEFORE))
RX_DELTA=$((RX_AFTER - RX_BEFORE))

echo
echo "=== 5. Results ==="
if [ $TX_DELTA -gt 0 ]; then
    echo "✅ TX_COUNTER_MOVED: Delta=$TX_DELTA packets"
else
    echo "❌ TX_COUNTER_STATIC: No packets transmitted"
fi

# Check dmesg for driver activity
echo
echo "=== 6. Driver messages ==="
dmesg | grep -E "adin2111|eth0" | tail -5

echo
echo "=== 7. Link state ==="
ip link show eth0 | grep -o "state [A-Z]*"

poweroff -f
INITEOF

# Build initramfs with busybox + basic tools
mkdir -p test-root/{bin,sbin,dev,proc,sys,etc}
if [ -f /bin/busybox ]; then
    cp /bin/busybox test-root/bin/
    for cmd in sh ip ping cat grep ls mount umount poweroff; do
        ln -sf busybox test-root/bin/$cmd
    done
fi
cp test-init.sh test-root/init
chmod +x test-root/init

# Create minimal /etc files
echo "127.0.0.1 localhost" > test-root/etc/hosts

(cd test-root && find . | cpio -o -H newc 2>/dev/null) > test.cpio

echo "Booting kernel with network test..."
timeout 15 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee packet-flow.log

# Parse results
echo
echo "=== VALIDATION ==="
if grep -q "TX_COUNTER_MOVED" packet-flow.log; then
    echo "✅ GATE PASS: TX path proven - counters incremented"
else
    echo "❌ GATE FAIL: TX counters did not move"
    exit 1
fi

if grep -q "state UP" packet-flow.log; then
    echo "✅ Interface state confirmed UP"
fi

# Cleanup
rm -rf test-root test.cpio test-init.sh
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

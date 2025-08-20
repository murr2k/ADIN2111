#!/bin/sh
echo "=== Network Counter Test ==="

# Bring up interface
ip link set eth0 up
sleep 1

# Check initial counters
TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets)
RX_BEFORE=$(cat /sys/class/net/eth0/statistics/rx_packets)
echo "TX before: $TX_BEFORE"
echo "RX before: $RX_BEFORE"

# Configure IP
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2

# Try to ping gateway (slirp)
ping -c 3 10.0.2.2

# Check counters after
TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
RX_AFTER=$(cat /sys/class/net/eth0/statistics/rx_packets)
echo "TX after: $TX_AFTER"
echo "RX after: $RX_AFTER"

TX_DELTA=$((TX_AFTER - TX_BEFORE))
RX_DELTA=$((RX_AFTER - RX_BEFORE))

if [ $TX_DELTA -gt 0 ]; then
    echo "✅ TX_PASS: Sent $TX_DELTA packets"
else
    echo "❌ TX_FAIL: No packets sent"
fi

if [ $RX_DELTA -gt 0 ]; then
    echo "✅ RX_PASS: Received $RX_DELTA packets"
else
    echo "⚠️ RX_NONE: No packets received (expected with no backend)"
fi

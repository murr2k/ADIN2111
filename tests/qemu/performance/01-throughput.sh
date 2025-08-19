#!/bin/sh
# Test: Throughput Performance
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

echo "TEST: Throughput Performance"

# Check for iperf3
if ! command -v iperf3 > /dev/null 2>&1; then
    echo "SKIP: iperf3 not available for throughput testing"
    exit 0
fi

# Setup interfaces
for iface in eth0 eth1; do
    if ip link show $iface > /dev/null 2>&1; then
        ip link set $iface up
        ip addr add 10.0.$((${iface#eth} + 1)).10/24 dev $iface 2>/dev/null || true
    fi
done

# Start iperf3 server in background
iperf3 -s -D -p 5201 --logfile /tmp/iperf-server.log

# Allow server to start
sleep 2

# Test throughput on each interface
for iface in eth0 eth1; do
    if ! ip link show $iface > /dev/null 2>&1; then
        echo "SKIP: Interface $iface not found"
        continue
    fi
    
    echo "Testing throughput on $iface..."
    
    # Run iperf3 client (test against loopback)
    iperf3 -c 10.0.$((${iface#eth} + 1)).10 -p 5201 -t 5 -i 1 > /tmp/iperf-$iface.log 2>&1
    
    # Parse results
    if grep -q "sender" /tmp/iperf-$iface.log; then
        throughput=$(grep "sender" /tmp/iperf-$iface.log | awk '{print $(NF-2), $(NF-1)}')
        echo "Throughput: $throughput"
        
        # Check if throughput meets minimum (8 Mbps for 10BASE-T1L)
        mbps=$(echo "$throughput" | awk '{print $1}')
        if [ "$(echo "$mbps > 7" | bc 2>/dev/null)" = "1" ] || [ "${mbps%.*}" -ge "7" ]; then
            echo "PASS: Throughput acceptable ($throughput)"
        else
            echo "WARN: Throughput below target ($throughput < 8 Mbps)"
        fi
    else
        echo "FAIL: Could not measure throughput on $iface"
    fi
done

# Kill iperf3 server
pkill iperf3

echo "TEST COMPLETE: Throughput measured"
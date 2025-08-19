#!/bin/sh
# Test: Latency Performance
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

echo "TEST: Latency Performance"

# Setup interfaces
for iface in eth0 eth1; do
    if ip link show $iface > /dev/null 2>&1; then
        ip link set $iface up
        ip addr add 10.0.$((${iface#eth} + 1)).20/24 dev $iface 2>/dev/null || true
    fi
done

# Test latency on each interface
for iface in eth0 eth1; do
    if ! ip link show $iface > /dev/null 2>&1; then
        echo "SKIP: Interface $iface not found"
        continue
    fi
    
    echo "Testing latency on $iface..."
    
    # Ping test for latency
    ping -c 20 -i 0.2 -I $iface 10.0.$((${iface#eth} + 1)).20 > /tmp/ping-$iface.log 2>&1
    
    if grep -q "min/avg/max" /tmp/ping-$iface.log; then
        # Extract latency stats
        latency_stats=$(grep "min/avg/max" /tmp/ping-$iface.log)
        avg_latency=$(echo "$latency_stats" | cut -d'/' -f5)
        
        echo "Latency: avg=$avg_latency ms"
        
        # Check if latency is acceptable (< 1ms for local)
        if [ "${avg_latency%.*}" -eq "0" ]; then
            echo "PASS: Latency acceptable ($avg_latency ms)"
        else
            echo "WARN: Higher than expected latency ($avg_latency ms)"
        fi
        
        # Check for packet loss
        loss=$(grep "packet loss" /tmp/ping-$iface.log | grep -o "[0-9]*%")
        if [ "$loss" = "0%" ]; then
            echo "PASS: No packet loss"
        else
            echo "FAIL: Packet loss detected ($loss)"
            exit 1
        fi
    else
        echo "FAIL: Could not measure latency on $iface"
    fi
done

echo "TEST COMPLETE: Latency measured"
#!/bin/sh
# Test: Latency Performance
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e  # Exit on any error
set -u  # Exit on undefined variable

# Error handling and cleanup
trap 'cleanup; echo "ERROR: Test failed at line $LINENO" >&2; exit 1' ERR
trap 'cleanup' EXIT

# Cleanup function
cleanup() {
    # Kill any background ping processes
    pkill ping 2>/dev/null || true
    # Remove temp files
    rm -f /tmp/ping-*.log 2>/dev/null || true
}

echo "TEST: Latency Performance"

# Check for ping command
if ! command -v ping > /dev/null 2>&1; then
    echo "SKIP: ping not available for latency testing"
    echo "INFO: Install with: apt-get install iputils-ping" >&2
    exit 0
fi

# Setup interfaces with error handling
for iface in eth0 eth1; do
    if ! ip link show "$iface" > /dev/null 2>&1; then
        echo "WARN: Interface $iface not found" >&2
        continue
    fi
    
    # Bring up interface
    ip link set "$iface" up 2>/dev/null || true
    
    # Add IP address (ignore if already exists)
    ip_addr="10.0.$((${iface#eth} + 1)).20/24"
    ip addr add "$ip_addr" dev "$iface" 2>/dev/null || true
done

# Test latency on each interface
test_passed=true
for iface in eth0 eth1; do
    if ! ip link show "$iface" > /dev/null 2>&1; then
        echo "SKIP: Interface $iface not found"
        continue
    fi
    
    echo "Testing latency on $iface..."
    
    # Target IP for ping test
    target_ip="10.0.$((${iface#eth} + 1)).20"
    
    # Ping test for latency with timeout
    if ! timeout 10 ping -c 20 -i 0.2 -I "$iface" "$target_ip" > "/tmp/ping-$iface.log" 2>&1; then
        echo "FAIL: Ping test failed or timed out on $iface" >&2
        cat "/tmp/ping-$iface.log" >&2
        test_passed=false
        continue
    fi
    
    # Verify results were captured
    if ! grep -q "min/avg/max" "/tmp/ping-$iface.log"; then
        echo "FAIL: Could not measure latency on $iface" >&2
        cat "/tmp/ping-$iface.log" >&2
        test_passed=false
        continue
    fi
    
    # Extract latency stats with error handling
    latency_stats=$(grep "min/avg/max" "/tmp/ping-$iface.log" || echo "")
    if [ -z "$latency_stats" ]; then
        echo "FAIL: No latency statistics found" >&2
        test_passed=false
        continue
    fi
    
    # Parse average latency
    avg_latency=$(echo "$latency_stats" | cut -d'/' -f5 | sed 's/[^0-9.]//g')
    
    if [ -z "$avg_latency" ]; then
        echo "FAIL: Could not parse average latency" >&2
        test_passed=false
        continue
    fi
    
    echo "Latency: avg=$avg_latency ms"
    
    # Check if latency is acceptable (< 2ms for local)
    # Use awk for floating point comparison
    if echo "$avg_latency" | awk '{exit !($1 < 2)}' 2>/dev/null; then
        echo "PASS: Latency acceptable ($avg_latency ms)"
    else
        echo "WARN: Higher than expected latency ($avg_latency ms)" >&2
    fi
    
    # Check for packet loss with error handling
    loss_line=$(grep "packet loss" "/tmp/ping-$iface.log" || echo "100% packet loss")
    loss=$(echo "$loss_line" | grep -o "[0-9]*%" || echo "100%")
    
    if [ "$loss" = "0%" ]; then
        echo "PASS: No packet loss"
    else
        echo "FAIL: Packet loss detected ($loss)" >&2
        test_passed=false
    fi
done

# Final status
if [ "$test_passed" = true ]; then
    echo "TEST COMPLETE: Latency measured successfully"
    exit 0
else
    echo "TEST FAILED: One or more interfaces failed latency test" >&2
    exit 1
fi
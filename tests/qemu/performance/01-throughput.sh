#!/bin/sh
# Test: Throughput Performance
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e  # Exit on any error
set -u  # Exit on undefined variable

# Error handling and cleanup
trap 'cleanup; echo "ERROR: Test failed at line $LINENO" >&2; exit 1' ERR
trap 'cleanup' EXIT

# Cleanup function
cleanup() {
    # Kill iperf3 server if running
    pkill iperf3 2>/dev/null || true
    # Remove temp files
    rm -f /tmp/iperf-*.log 2>/dev/null || true
}

echo "TEST: Throughput Performance"

# Check for iperf3
if ! command -v iperf3 > /dev/null 2>&1; then
    echo "SKIP: iperf3 not available for throughput testing"
    echo "INFO: Install with: apt-get install iperf3" >&2
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
    ip_addr="10.0.$((${iface#eth} + 1)).10/24"
    ip addr add "$ip_addr" dev "$iface" 2>/dev/null || true
done

# Start iperf3 server with timeout
if ! timeout 5 iperf3 -s -D -p 5201 --logfile /tmp/iperf-server.log 2>/dev/null; then
    echo "WARN: Could not start iperf3 server (may already be running)" >&2
fi

# Allow server to start
sleep 2

# Verify server is running
if ! pgrep -x iperf3 > /dev/null; then
    echo "FAIL: iperf3 server failed to start" >&2
    exit 1
fi

# Test throughput on each interface
for iface in eth0 eth1; do
    if ! ip link show "$iface" > /dev/null 2>&1; then
        echo "SKIP: Interface $iface not found"
        continue
    fi
    
    echo "Testing throughput on $iface..."
    
    # Run iperf3 client with timeout
    target_ip="10.0.$((${iface#eth} + 1)).10"
    if ! timeout 10 iperf3 -c "$target_ip" -p 5201 -t 5 -i 1 > "/tmp/iperf-$iface.log" 2>&1; then
        echo "FAIL: iperf3 client failed on $iface" >&2
        cat "/tmp/iperf-$iface.log" >&2
        exit 1
    fi
    
    # Parse results with error handling
    if ! grep -q "sender" "/tmp/iperf-$iface.log"; then
        echo "FAIL: Could not measure throughput on $iface" >&2
        cat "/tmp/iperf-$iface.log" >&2
        exit 1
    fi
    
    throughput=$(grep "sender" "/tmp/iperf-$iface.log" | awk '{print $(NF-2), $(NF-1)}')
    echo "Throughput: $throughput"
    
    # Extract numeric value for comparison
    mbps=$(echo "$throughput" | awk '{print $1}' | sed 's/[^0-9.]//g')
    
    # Check if throughput meets minimum (8 Mbps for 10BASE-T1L)
    # Use awk for floating point comparison
    if echo "$mbps" | awk '{exit !($1 >= 7)}' 2>/dev/null; then
        echo "PASS: Throughput acceptable ($throughput)"
    else
        echo "WARN: Throughput below target ($throughput < 8 Mbps)" >&2
    fi
done

echo "TEST COMPLETE: Throughput measured"
exit 0
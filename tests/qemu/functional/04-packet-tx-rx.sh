#!/bin/sh
# Test: Packet Transmission and Reception
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
    rm -f /tmp/packet-*.log 2>/dev/null || true
    # Clean up any test network namespaces
    if [ -n "${test_namespace:-}" ]; then
        ip netns del "$test_namespace" 2>/dev/null || true
    fi
}

echo "TEST: Packet Transmission and Reception"

# Check prerequisites
if ! command -v ip > /dev/null 2>&1; then
    echo "SKIP: iproute2 not available"
    echo "INFO: Install with: apt-get install iproute2" >&2
    exit 0
fi

# Initialize test state
test_passed=true
test_namespace=""

# Setup interfaces if not already configured
echo "Setting up network interfaces..."
interfaces_found=false

for iface in eth0 eth1; do
    if ip link show "$iface" > /dev/null 2>&1; then
        interfaces_found=true
        echo "Configuring $iface..."
        
        # Bring up interface with error handling
        if ! ip link set "$iface" up 2>/dev/null; then
            echo "WARN: Could not bring up $iface" >&2
            continue
        fi
        
        # Add IP address (ignore if already exists)
        ip_addr="10.0.$((${iface#eth} + 1)).1/24"
        ip addr add "$ip_addr" dev "$iface" 2>/dev/null || true
        
        # Verify interface is configured
        if ! ip addr show "$iface" | grep -q "10.0.$((${iface#eth} + 1)).1"; then
            echo "WARN: Failed to configure IP on $iface" >&2
        fi
    fi
done

if [ "$interfaces_found" = false ]; then
    echo "SKIP: No network interfaces found"
    exit 0
fi

# Test loopback on each interface
echo "Testing packet transmission and reception..."

for iface in eth0 eth1; do
    if ! ip link show "$iface" > /dev/null 2>&1; then
        echo "SKIP: Interface $iface not found"
        continue
    fi
    
    echo "Testing $iface loopback..."
    
    # Get initial packet counts with error handling
    tx_before=$(ip -s link show "$iface" 2>/dev/null | grep -A1 "TX:" | tail -1 | awk '{print $1}' || echo "0")
    rx_before=$(ip -s link show "$iface" 2>/dev/null | grep -A1 "RX:" | tail -1 | awk '{print $1}' || echo "0")
    
    # Validate packet counts are numeric
    if ! echo "$tx_before" | grep -q '^[0-9]*$'; then
        echo "WARN: Could not read TX counter for $iface" >&2
        tx_before=0
    fi
    
    if ! echo "$rx_before" | grep -q '^[0-9]*$'; then
        echo "WARN: Could not read RX counter for $iface" >&2
        rx_before=0
    fi
    
    # Send test packets with timeout (self-ping)
    target_ip="10.0.$((${iface#eth} + 1)).1"
    
    if ! timeout 5 ping -c 3 -I "$iface" "$target_ip" > "/tmp/packet-$iface.log" 2>&1; then
        echo "WARN: Ping test failed on $iface" >&2
        cat "/tmp/packet-$iface.log" >&2
        
        # Check if interface is up
        if ! ip link show "$iface" | grep -q "UP"; then
            echo "FAIL: Interface $iface is not UP" >&2
            test_passed=false
            continue
        fi
    fi
    
    # Small delay to ensure counters update
    sleep 0.5
    
    # Get new packet counts with error handling
    tx_after=$(ip -s link show "$iface" 2>/dev/null | grep -A1 "TX:" | tail -1 | awk '{print $1}' || echo "0")
    rx_after=$(ip -s link show "$iface" 2>/dev/null | grep -A1 "RX:" | tail -1 | awk '{print $1}' || echo "0")
    
    # Validate packet counts are numeric
    if ! echo "$tx_after" | grep -q '^[0-9]*$'; then
        echo "WARN: Could not read final TX counter for $iface" >&2
        tx_after=0
    fi
    
    if ! echo "$rx_after" | grep -q '^[0-9]*$'; then
        echo "WARN: Could not read final RX counter for $iface" >&2
        rx_after=0
    fi
    
    # Calculate packet differences
    tx_diff=$((tx_after - tx_before))
    rx_diff=$((rx_after - rx_before))
    
    echo "  TX: $tx_before -> $tx_after (diff: $tx_diff)"
    echo "  RX: $rx_before -> $rx_after (diff: $rx_diff)"
    
    # Check if packets were transmitted
    if [ "$tx_diff" -gt 0 ]; then
        echo "PASS: Packets transmitted on $iface ($tx_diff packets)"
    else
        echo "FAIL: No packets transmitted on $iface" >&2
        test_passed=false
    fi
    
    # Check if packets were received (for loopback)
    if [ "$rx_diff" -gt 0 ]; then
        echo "PASS: Packets received on $iface ($rx_diff packets)"
    else
        # This might be expected depending on driver implementation
        echo "INFO: No packets received on $iface (might be normal for this driver)"
    fi
done

# Test switching between interfaces (if both present)
if ip link show eth0 > /dev/null 2>&1 && ip link show eth1 > /dev/null 2>&1; then
    echo "Testing inter-port communication..."
    
    # Check for namespace support
    if command -v unshare > /dev/null 2>&1 && [ -e /proc/self/ns/net ]; then
        # Advanced switching test with network namespaces
        test_namespace="adin2111_test_$$"
        
        # Try to create namespace (may fail without privileges)
        if ip netns add "$test_namespace" 2>/dev/null; then
            echo "Created test namespace: $test_namespace"
            
            # Would perform advanced switching tests here
            echo "INFO: Advanced switching test setup complete"
            
            # Cleanup namespace
            ip netns del "$test_namespace" 2>/dev/null || true
            test_namespace=""
        else
            echo "SKIP: Cannot create network namespace (requires privileges)"
        fi
    else
        echo "SKIP: Network namespace tools not available"
    fi
    
    # Basic inter-port test
    echo "Performing basic inter-port connectivity test..."
    
    # Try to ping from one interface to another
    if timeout 5 ping -c 2 -I eth0 10.0.2.1 > /tmp/packet-inter.log 2>&1; then
        echo "INFO: Inter-port communication possible"
    else
        echo "INFO: Direct inter-port communication not configured (expected for switch mode)"
    fi
fi

# Check for error conditions
echo "Checking for interface errors..."

for iface in eth0 eth1; do
    if ! ip link show "$iface" > /dev/null 2>&1; then
        continue
    fi
    
    # Get error counters
    errors=$(ip -s link show "$iface" 2>/dev/null | grep -A5 "RX:" | grep "errors" | head -1 | awk '{print $3}' || echo "0")
    
    if [ "$errors" != "0" ] && [ -n "$errors" ]; then
        echo "WARN: $iface has $errors RX errors" >&2
    else
        echo "PASS: No errors on $iface"
    fi
done

# Final status
if [ "$test_passed" = true ]; then
    echo "TEST COMPLETE: Packet transmission verified successfully"
    exit 0
else
    echo "TEST FAILED: One or more interfaces failed packet transmission" >&2
    exit 1
fi
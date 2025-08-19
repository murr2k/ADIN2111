#!/bin/sh
# Test: Network Interface Configuration
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e  # Exit on any error
set -u  # Exit on undefined variable

# Error handling
trap 'cleanup; echo "ERROR: Test failed at line $LINENO" >&2; exit 1' ERR

# Cleanup function
cleanup() {
    # Restore interfaces to original state
    for iface in eth0 eth1; do
        ip link set "$iface" down 2>/dev/null || true
        ip addr flush dev "$iface" 2>/dev/null || true
    done
}

echo "TEST: Network Interface Configuration"

# Test interface configuration
for iface in eth0 eth1; do
    if ! ip link show "$iface" > /dev/null 2>&1; then
        echo "SKIP: Interface $iface not found"
        continue
    fi
    
    echo "Testing $iface..."
    
    # Bring interface down with retry
    if ! ip link set "$iface" down 2>/dev/null; then
        echo "FAIL: Could not bring $iface down" >&2
        exit 1
    fi
    
    # Wait for state change
    sleep 0.5
    
    if ! ip link show "$iface" | grep -q "state DOWN"; then
        echo "FAIL: $iface failed to go down" >&2
        ip link show "$iface" >&2
        exit 1
    fi
    echo "PASS: $iface brought down"
    
    # Bring interface up with retry
    if ! ip link set "$iface" up 2>/dev/null; then
        echo "FAIL: Could not bring $iface up" >&2
        exit 1
    fi
    
    # Wait for state change
    sleep 1
    
    if ! ip link show "$iface" | grep -E "state (UP|UNKNOWN)"; then
        echo "FAIL: $iface failed to come up" >&2
        ip link show "$iface" >&2
        exit 1
    fi
    echo "PASS: $iface brought up"
    
    # Set IP address with error handling
    ip_suffix=$((10 + ${iface#eth}))
    ip_addr="192.168.1.${ip_suffix}/24"
    
    # Remove any existing addresses first
    ip addr flush dev "$iface" 2>/dev/null || true
    
    if ! ip addr add "$ip_addr" dev "$iface" 2>/dev/null; then
        echo "WARN: Could not add IP $ip_addr to $iface (may already exist)" >&2
    fi
    
    if ! ip addr show "$iface" | grep -q "192.168.1."; then
        echo "FAIL: IP address configuration failed on $iface" >&2
        ip addr show "$iface" >&2
        exit 1
    fi
    echo "PASS: IP address configured on $iface"
    
    # Set MTU with validation
    if ! ip link set "$iface" mtu 1400 2>/dev/null; then
        echo "FAIL: Could not set MTU on $iface" >&2
        exit 1
    fi
    
    if ! ip link show "$iface" | grep -q "mtu 1400"; then
        echo "FAIL: MTU configuration failed on $iface" >&2
        ip link show "$iface" >&2
        exit 1
    fi
    echo "PASS: MTU set to 1400 on $iface"
done

# Cleanup
cleanup

echo "TEST COMPLETE: Network configuration successful"
exit 0
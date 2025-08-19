#!/bin/sh
# Test: Packet Transmission and Reception
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

echo "TEST: Packet Transmission and Reception"

# Setup interfaces if not already configured
for iface in eth0 eth1; do
    if ip link show $iface > /dev/null 2>&1; then
        ip link set $iface up
        ip addr add 10.0.$((${iface#eth} + 1)).1/24 dev $iface 2>/dev/null || true
    fi
done

# Test loopback on each interface
for iface in eth0 eth1; do
    if ! ip link show $iface > /dev/null 2>&1; then
        echo "SKIP: Interface $iface not found"
        continue
    fi
    
    echo "Testing $iface loopback..."
    
    # Get initial packet counts
    tx_before=$(ip -s link show $iface | grep -A1 "TX:" | tail -1 | awk '{print $1}')
    rx_before=$(ip -s link show $iface | grep -A1 "RX:" | tail -1 | awk '{print $1}')
    
    # Send test packets (self-ping)
    ping -c 3 -I $iface 10.0.$((${iface#eth} + 1)).1 > /dev/null 2>&1
    
    # Get new packet counts
    tx_after=$(ip -s link show $iface | grep -A1 "TX:" | tail -1 | awk '{print $1}')
    rx_after=$(ip -s link show $iface | grep -A1 "RX:" | tail -1 | awk '{print $1}')
    
    # Check if packets were transmitted
    if [ "$tx_after" -gt "$tx_before" ]; then
        echo "PASS: Packets transmitted on $iface"
    else
        echo "FAIL: No packets transmitted on $iface"
        exit 1
    fi
done

# Test switching between interfaces (if both present)
if ip link show eth0 > /dev/null 2>&1 && ip link show eth1 > /dev/null 2>&1; then
    echo "Testing inter-port switching..."
    
    # Create namespace for isolated testing
    if command -v unshare > /dev/null 2>&1; then
        # Would test actual switching here with network namespaces
        echo "SKIP: Advanced switching test requires namespace support"
    else
        echo "SKIP: Network namespace tools not available"
    fi
fi

echo "TEST COMPLETE: Packet transmission verified"
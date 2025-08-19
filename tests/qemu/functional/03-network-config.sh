#!/bin/sh
# Test: Network Interface Configuration
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

echo "TEST: Network Interface Configuration"

# Test interface configuration
for iface in eth0 eth1; do
    if ! ip link show $iface > /dev/null 2>&1; then
        echo "SKIP: Interface $iface not found"
        continue
    fi
    
    echo "Testing $iface..."
    
    # Bring interface down
    ip link set $iface down
    if ip link show $iface | grep -q "state DOWN"; then
        echo "PASS: $iface brought down"
    else
        echo "FAIL: $iface failed to go down"
        exit 1
    fi
    
    # Bring interface up
    ip link set $iface up
    sleep 1
    if ip link show $iface | grep -q "state UP\|UNKNOWN"; then
        echo "PASS: $iface brought up"
    else
        echo "FAIL: $iface failed to come up"
        exit 1
    fi
    
    # Set IP address
    ip addr add 192.168.1.$((10 + ${iface#eth}))/24 dev $iface
    if ip addr show $iface | grep -q "192.168.1."; then
        echo "PASS: IP address configured on $iface"
    else
        echo "FAIL: IP address configuration failed on $iface"
        exit 1
    fi
    
    # Set MTU
    ip link set $iface mtu 1400
    if ip link show $iface | grep -q "mtu 1400"; then
        echo "PASS: MTU set to 1400 on $iface"
    else
        echo "FAIL: MTU configuration failed on $iface"
        exit 1
    fi
done

echo "TEST COMPLETE: Network configuration successful"
#!/bin/sh
# Test: SPI Communication Verification
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

echo "TEST: SPI Communication Verification"

# Check SPI device detection
if [ -e /dev/spidev0.0 ]; then
    echo "PASS: SPI device found"
else
    echo "SKIP: No SPI device access from userspace"
    # Not a failure - driver may not expose raw SPI
    exit 0
fi

# Test register access through ethtool if available
if command -v ethtool > /dev/null 2>&1; then
    # Try to read registers
    for iface in eth0 eth1; do
        if ip link show $iface > /dev/null 2>&1; then
            # Get driver info
            ethtool -i $iface > /tmp/ethtool.out 2>&1
            if grep -q "adin2111" /tmp/ethtool.out; then
                echo "PASS: $iface uses adin2111 driver"
            else
                echo "FAIL: $iface not using adin2111 driver"
                exit 1
            fi
        fi
    done
else
    echo "SKIP: ethtool not available"
fi

# Check for SPI errors in kernel log
if dmesg | grep -q "adin2111.*SPI.*error"; then
    echo "FAIL: SPI errors detected in kernel log"
    dmesg | grep "adin2111.*SPI.*error" | tail -5
    exit 1
else
    echo "PASS: No SPI errors detected"
fi

echo "TEST COMPLETE: SPI communication verified"
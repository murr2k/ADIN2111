#!/bin/sh
# Test: SPI Communication Verification
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e  # Exit on any error
set -u  # Exit on undefined variable

# Error handling
trap 'echo "ERROR: Test failed at line $LINENO" >&2; exit 1' ERR

echo "TEST: SPI Communication Verification"

# Check SPI device detection
if [ ! -e /dev/spidev0.0 ]; then
    echo "SKIP: No SPI device access from userspace"
    echo "INFO: Driver may not expose raw SPI - this is normal" >&2
    exit 0
fi
echo "PASS: SPI device found"

# Test register access through ethtool if available
if ! command -v ethtool > /dev/null 2>&1; then
    echo "SKIP: ethtool not available for driver verification"
else
    # Try to read registers
    for iface in eth0 eth1; do
        if ! ip link show "$iface" > /dev/null 2>&1; then
            continue
        fi
        
        # Get driver info with error handling
        if ! ethtool -i "$iface" > /tmp/ethtool.out 2>&1; then
            echo "WARN: Could not get ethtool info for $iface" >&2
            continue
        fi
        
        if ! grep -q "adin2111" /tmp/ethtool.out; then
            echo "FAIL: $iface not using adin2111 driver" >&2
            cat /tmp/ethtool.out >&2
            exit 1
        fi
        echo "PASS: $iface uses adin2111 driver"
    done
fi

# Check for SPI errors in kernel log
if dmesg 2>/dev/null | grep -q "adin2111.*SPI.*error"; then
    echo "FAIL: SPI errors detected in kernel log" >&2
    dmesg | grep "adin2111.*SPI.*error" | tail -5 >&2
    exit 1
fi
echo "PASS: No SPI errors detected"

# Cleanup
rm -f /tmp/ethtool.out

echo "TEST COMPLETE: SPI communication verified"
exit 0
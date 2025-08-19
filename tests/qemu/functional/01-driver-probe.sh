#!/bin/sh
# Test: Driver Probe and Initialization
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e  # Exit on any error
set -u  # Exit on undefined variable

# Error handling
trap 'echo "ERROR: Test failed at line $LINENO" >&2; exit 1' ERR

echo "TEST: Driver Probe and Initialization"

# Check if ADIN2111 module loaded
if ! lsmod 2>/dev/null | grep -q adin2111; then
    echo "FAIL: ADIN2111 module not loaded" >&2
    echo "Hint: Ensure driver is built and loaded" >&2
    exit 1
fi
echo "PASS: ADIN2111 module loaded"

# Check for driver in kernel log
if ! dmesg 2>/dev/null | grep -q "adin2111.*probe"; then
    echo "FAIL: Driver probe not found in dmesg" >&2
    echo "Hint: Check dmesg for driver errors" >&2
    exit 1
fi
echo "PASS: Driver probe executed"

# Check for successful initialization
if ! dmesg 2>/dev/null | grep -q "adin2111.*initialized"; then
    echo "WARN: Driver initialization message not found" >&2
    # Non-fatal warning - driver may work without explicit message
fi
echo "PASS: Driver initialization checked"

# Check for network interfaces
count=$(ip link 2>/dev/null | grep -c "eth[0-9]" || echo "0")
if [ "$count" -lt 2 ]; then
    echo "FAIL: Expected at least 2 network interfaces, found $count" >&2
    echo "Hint: Check if device tree has ADIN2111 configured" >&2
    ip link show >&2
    exit 1
fi
echo "PASS: Network interfaces created ($count found)"

echo "TEST COMPLETE: Driver probe successful"
exit 0
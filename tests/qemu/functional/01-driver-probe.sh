#!/bin/sh
# Test: Driver Probe and Initialization
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

echo "TEST: Driver Probe and Initialization"

# Check if ADIN2111 module loaded
if lsmod | grep -q adin2111; then
    echo "PASS: ADIN2111 module loaded"
else
    echo "FAIL: ADIN2111 module not loaded"
    exit 1
fi

# Check for driver in kernel log
if dmesg | grep -q "adin2111.*probe"; then
    echo "PASS: Driver probe executed"
else
    echo "FAIL: Driver probe not found in dmesg"
    exit 1
fi

# Check for successful initialization
if dmesg | grep -q "adin2111.*initialized"; then
    echo "PASS: Driver initialized successfully"
else
    echo "FAIL: Driver initialization failed"
    exit 1
fi

# Check for network interfaces
count=$(ip link | grep -c "eth[0-9]")
if [ "$count" -ge 2 ]; then
    echo "PASS: Network interfaces created ($count found)"
else
    echo "FAIL: Expected at least 2 network interfaces, found $count"
    exit 1
fi

echo "TEST COMPLETE: Driver probe successful"
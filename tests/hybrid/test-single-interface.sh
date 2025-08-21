#!/bin/bash
# Test Single Interface Mode
# Validates that only one network interface is created in single interface mode

set -e

TEST_NAME="Single Interface Mode Test"
RESULT="FAIL"

echo "=== $TEST_NAME ==="

# Function to count ethernet interfaces
count_interfaces() {
    ip link show | grep -c "eth[0-9]:" || echo "0"
}

# Check initial state
INITIAL_COUNT=$(count_interfaces)
echo "Initial interface count: $INITIAL_COUNT"

# Load driver with single interface mode
if lsmod | grep -q adin2111_hybrid; then
    echo "Driver already loaded, removing..."
    rmmod adin2111_hybrid
    sleep 1
fi

echo "Loading driver with single_interface_mode=1..."
modprobe adin2111_hybrid single_interface_mode=1

sleep 2

# Count interfaces after loading
FINAL_COUNT=$(count_interfaces)
ADDED_COUNT=$((FINAL_COUNT - INITIAL_COUNT))

echo "Final interface count: $FINAL_COUNT"
echo "Interfaces added: $ADDED_COUNT"

# Verify single interface mode
if [ "$ADDED_COUNT" -eq 1 ]; then
    echo "✓ Single interface confirmed"
    
    # Check dmesg for confirmation
    if dmesg | tail -50 | grep -q "single interface mode"; then
        echo "✓ Driver reports single interface mode"
        
        # Check that no bridge is needed
        if command -v brctl &>/dev/null; then
            BRIDGES=$(brctl show 2>/dev/null | grep -c "^br" || echo "0")
            if [ "$BRIDGES" -eq 0 ]; then
                echo "✓ No software bridge required"
                RESULT="PASS"
            else
                echo "✗ Unexpected bridge found"
            fi
        else
            echo "⚠ brctl not available, skipping bridge check"
            RESULT="PASS"
        fi
    else
        echo "✗ Driver does not report single interface mode"
    fi
else
    echo "✗ Expected 1 interface, got $ADDED_COUNT"
fi

# Report result
echo ""
echo "Test Result: $RESULT"

if [ "$RESULT" = "PASS" ]; then
    exit 0
else
    exit 1
fi
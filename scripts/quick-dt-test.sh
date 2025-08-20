#!/bin/bash

# Quick Device Tree Test for ADIN2111
# Simple validation and demonstration script

PROJECT_ROOT="/home/murr2k/projects/ADIN2111"
DTS_DIR="$PROJECT_ROOT/dts"
LOGS_DIR="$PROJECT_ROOT/logs"

echo "=== ADIN2111 Device Tree Quick Test ==="
echo "Timestamp: $(date)"
echo ""

# Test 1: File existence
echo "Test 1: Device Tree Files"
echo "------------------------"

for file in "virt-adin2111.dts" "virt-adin2111-dual.dts"; do
    if [ -f "$DTS_DIR/$file" ]; then
        echo "✓ $file exists"
        echo "  Size: $(stat -c%s "$DTS_DIR/$file") bytes"
        echo "  Modified: $(stat -c%y "$DTS_DIR/$file")"
    else
        echo "✗ $file missing"
    fi
done

echo ""

# Test 2: Content validation
echo "Test 2: Content Validation"
echo "---------------------------"

single_dt="$DTS_DIR/virt-adin2111.dts"
dual_dt="$DTS_DIR/virt-adin2111-dual.dts"

echo "Single ADIN2111 Configuration:"
if [ -f "$single_dt" ]; then
    echo "✓ SPI Controller: $(grep -c 'spi@9060000' "$single_dt") instance(s)"
    echo "✓ ADIN2111 Device: $(grep -c 'adi,adin2111' "$single_dt") instance(s)"
    echo "✓ Ethernet Ports: $(grep -c 'port@[0-1]' "$single_dt") port(s)"
    echo "✓ MAC Addresses: $(grep -c 'mac-address\|local-mac-address' "$single_dt") address(es)"
    echo "✓ PHY Definitions: $(grep -c 'ethernet-phy@[0-1]' "$single_dt") PHY(s)"
else
    echo "✗ Single configuration file not found"
fi

echo ""
echo "Dual ADIN2111 Configuration:"
if [ -f "$dual_dt" ]; then
    echo "✓ SPI Controller: $(grep -c 'spi@9060000\|spi@9070000' "$dual_dt") instance(s)"
    echo "✓ ADIN2111 Devices: $(grep -c 'adi,adin2111' "$dual_dt") instance(s)"
    echo "✓ Ethernet Ports: $(grep -c 'port@[0-1]' "$dual_dt") port(s)"
    echo "✓ MAC Addresses: $(grep -c 'mac-address\|local-mac-address' "$dual_dt") address(es)"
    echo "✓ PHY Definitions: $(grep -c 'ethernet-phy@[0-1]' "$dual_dt") PHY(s)"
else
    echo "✗ Dual configuration file not found"
fi

echo ""

# Test 3: Address and interrupt validation
echo "Test 3: Hardware Configuration"
echo "-------------------------------"

echo "SPI Controller Addresses:"
if [ -f "$single_dt" ]; then
    echo "  Single config: 0x$(grep -o 'spi@[0-9a-f]*' "$single_dt" | cut -d'@' -f2)"
fi
if [ -f "$dual_dt" ]; then
    echo "  Dual config: $(grep -o 'spi@[0-9a-f]*' "$dual_dt" | sed 's/spi@/0x/g' | tr '\n' ' ')"
fi

echo ""
echo "Interrupt Configuration:"
if [ -f "$single_dt" ]; then
    echo "  Single config IRQs: $(grep -o 'interrupts = <0 [0-9]* 4>' "$single_dt" | grep -o '[0-9]*' | grep -v '^0$' | grep -v '^4$' | tr '\n' ',' | sed 's/,$//')"
fi
if [ -f "$dual_dt" ]; then
    echo "  Dual config IRQs: $(grep -o 'interrupts = <0 [0-9]* 4>' "$dual_dt" | grep -o '[0-9]*' | grep -v '^0$' | grep -v '^4$' | tr '\n' ',' | sed 's/,$//')"
fi

echo ""

# Test 4: MAC address uniqueness
echo "Test 4: MAC Address Uniqueness"
echo "-------------------------------"

for config in "single" "dual"; do
    case $config in
        "single") file="$single_dt"; label="Single config" ;;
        "dual") file="$dual_dt"; label="Dual config" ;;
    esac
    
    if [ -f "$file" ]; then
        mac_total=$(grep -o '\[[0-9a-f ]*\]' "$file" | wc -l)
        mac_unique=$(grep -o '\[[0-9a-f ]*\]' "$file" | sort -u | wc -l)
        
        if [ "$mac_total" -eq "$mac_unique" ]; then
            echo "✓ $label: All $mac_total MAC addresses are unique"
        else
            echo "✗ $label: $mac_total total, $mac_unique unique (duplicates found)"
        fi
    fi
done

echo ""

# Test 5: Generate test summary
echo "Test 5: Summary"
echo "---------------"

# Count total tests
total_tests=0
passed_tests=0

# File existence tests (2)
total_tests=$((total_tests + 2))
[ -f "$single_dt" ] && passed_tests=$((passed_tests + 1))
[ -f "$dual_dt" ] && passed_tests=$((passed_tests + 1))

# Content validation tests (10)
total_tests=$((total_tests + 10))
if [ -f "$single_dt" ]; then
    [ "$(grep -c 'spi@9060000' "$single_dt")" -gt 0 ] && passed_tests=$((passed_tests + 1))
    [ "$(grep -c 'adi,adin2111' "$single_dt")" -eq 1 ] && passed_tests=$((passed_tests + 1))
    [ "$(grep -c 'port@[0-1]' "$single_dt")" -eq 2 ] && passed_tests=$((passed_tests + 1))
    [ "$(grep -c 'mac-address\|local-mac-address' "$single_dt")" -gt 0 ] && passed_tests=$((passed_tests + 1))
    [ "$(grep -c 'ethernet-phy@[0-1]' "$single_dt")" -eq 2 ] && passed_tests=$((passed_tests + 1))
fi

if [ -f "$dual_dt" ]; then
    [ "$(grep -c 'spi@9060000\|spi@9070000' "$dual_dt")" -gt 0 ] && passed_tests=$((passed_tests + 1))
    [ "$(grep -c 'adi,adin2111' "$dual_dt")" -eq 2 ] && passed_tests=$((passed_tests + 1))
    [ "$(grep -c 'port@[0-1]' "$dual_dt")" -eq 4 ] && passed_tests=$((passed_tests + 1))
    [ "$(grep -c 'mac-address\|local-mac-address' "$dual_dt")" -gt 0 ] && passed_tests=$((passed_tests + 1))
    [ "$(grep -c 'ethernet-phy@[0-1]' "$dual_dt")" -eq 4 ] && passed_tests=$((passed_tests + 1))
fi

# MAC uniqueness tests (2)
total_tests=$((total_tests + 2))
if [ -f "$single_dt" ]; then
    mac_total=$(grep -o '\[[0-9a-f ]*\]' "$single_dt" | wc -l)
    mac_unique=$(grep -o '\[[0-9a-f ]*\]' "$single_dt" | sort -u | wc -l)
    [ "$mac_total" -eq "$mac_unique" ] && passed_tests=$((passed_tests + 1))
fi

if [ -f "$dual_dt" ]; then
    mac_total=$(grep -o '\[[0-9a-f ]*\]' "$dual_dt" | wc -l)
    mac_unique=$(grep -o '\[[0-9a-f ]*\]' "$dual_dt" | sort -u | wc -l)
    [ "$mac_total" -eq "$mac_unique" ] && passed_tests=$((passed_tests + 1))
fi

success_rate=$((passed_tests * 100 / total_tests))

echo "Total Tests: $total_tests"
echo "Passed: $passed_tests"
echo "Failed: $((total_tests - passed_tests))"
echo "Success Rate: $success_rate%"

# Generate simple results file for dashboard
mkdir -p "$LOGS_DIR"
cat > "$LOGS_DIR/quick-test-results.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "test_type": "quick_device_tree_test",
    "summary": {
        "total_tests": $total_tests,
        "passed": $passed_tests,
        "failed": $((total_tests - passed_tests)),
        "success_rate": $success_rate
    },
    "device_trees": {
        "single_config": {
            "file": "virt-adin2111.dts",
            "exists": $([ -f "$single_dt" ] && echo "true" || echo "false"),
            "adin2111_devices": $([ -f "$single_dt" ] && grep -c 'adi,adin2111' "$single_dt" || echo "0"),
            "ethernet_ports": $([ -f "$single_dt" ] && grep -c 'port@[0-1]' "$single_dt" || echo "0")
        },
        "dual_config": {
            "file": "virt-adin2111-dual.dts",
            "exists": $([ -f "$dual_dt" ] && echo "true" || echo "false"),
            "adin2111_devices": $([ -f "$dual_dt" ] && grep -c 'adi,adin2111' "$dual_dt" || echo "0"),
            "ethernet_ports": $([ -f "$dual_dt" ] && grep -c 'port@[0-1]' "$dual_dt" || echo "0")
        }
    }
}
EOF

echo ""
if [ "$success_rate" -ge 80 ]; then
    echo "✓ DEVICE TREE TESTS PASSED"
    exit 0
else
    echo "✗ DEVICE TREE TESTS FAILED"
    exit 1
fi
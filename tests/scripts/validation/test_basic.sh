#!/bin/bash

# ADIN2111 Basic Functionality Tests
# Copyright (C) 2025 Analog Devices Inc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERFACE="${1:-eth0}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

# Test result tracking
test_result() {
    local test_name="$1"
    local result="$2"
    local details="${3:-}"
    
    TESTS_TOTAL=$((TESTS_TOTAL + 1))
    
    if [[ "$result" == "PASS" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_success "Test '$test_name': PASSED $details"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "Test '$test_name': FAILED $details"
    fi
}

# Check if interface exists
test_interface_exists() {
    log_info "Testing if interface $INTERFACE exists..."
    
    if ip link show "$INTERFACE" &>/dev/null; then
        test_result "interface_exists" "PASS" "- Interface $INTERFACE found"
        return 0
    else
        test_result "interface_exists" "FAIL" "- Interface $INTERFACE not found"
        return 1
    fi
}

# Test interface state
test_interface_state() {
    log_info "Testing interface state..."
    
    local state
    state=$(ip link show "$INTERFACE" | grep -o "state [A-Z]*" | cut -d' ' -f2)
    
    if [[ "$state" == "UP" ]]; then
        test_result "interface_state" "PASS" "- Interface is UP"
        return 0
    else
        test_result "interface_state" "FAIL" "- Interface state is $state"
        return 1
    fi
}

# Test interface flags
test_interface_flags() {
    log_info "Testing interface flags..."
    
    local flags
    flags=$(ip link show "$INTERFACE" | grep -o "<[^>]*>")
    
    if echo "$flags" | grep -q "UP"; then
        test_result "interface_flags_up" "PASS" "- UP flag present"
    else
        test_result "interface_flags_up" "FAIL" "- UP flag missing"
    fi
    
    if echo "$flags" | grep -q "RUNNING"; then
        test_result "interface_flags_running" "PASS" "- RUNNING flag present"
    else
        test_result "interface_flags_running" "FAIL" "- RUNNING flag missing"
    fi
    
    log_info "Interface flags: $flags"
}

# Test MAC address
test_mac_address() {
    log_info "Testing MAC address..."
    
    local mac
    mac=$(ip link show "$INTERFACE" | grep -o "link/ether [a-f0-9:]*" | cut -d' ' -f2)
    
    if [[ -n "$mac" ]] && [[ "$mac" =~ ^([a-f0-9]{2}:){5}[a-f0-9]{2}$ ]]; then
        test_result "mac_address" "PASS" "- Valid MAC: $mac"
        
        # Check if it's not all zeros
        if [[ "$mac" != "00:00:00:00:00:00" ]]; then
            test_result "mac_address_valid" "PASS" "- MAC is not all zeros"
        else
            test_result "mac_address_valid" "FAIL" "- MAC is all zeros"
        fi
    else
        test_result "mac_address" "FAIL" "- Invalid or missing MAC address"
    fi
}

# Test MTU
test_mtu() {
    log_info "Testing MTU..."
    
    local mtu
    mtu=$(ip link show "$INTERFACE" | grep -o "mtu [0-9]*" | cut -d' ' -f2)
    
    if [[ -n "$mtu" ]] && [[ "$mtu" -ge 68 ]] && [[ "$mtu" -le 9000 ]]; then
        test_result "mtu" "PASS" "- MTU is $mtu"
        
        # Check for standard Ethernet MTU
        if [[ "$mtu" -eq 1500 ]]; then
            test_result "mtu_standard" "PASS" "- Standard Ethernet MTU (1500)"
        else
            test_result "mtu_standard" "WARN" "- Non-standard MTU: $mtu"
        fi
    else
        test_result "mtu" "FAIL" "- Invalid MTU: $mtu"
    fi
}

# Test link status using ethtool
test_link_status() {
    log_info "Testing link status with ethtool..."
    
    if ! command -v ethtool &> /dev/null; then
        test_result "link_status" "SKIP" "- ethtool not available"
        return 0
    fi
    
    local link_status
    if link_status=$(ethtool "$INTERFACE" 2>/dev/null); then
        if echo "$link_status" | grep -q "Link detected: yes"; then
            test_result "link_detected" "PASS" "- Link is up"
        else
            test_result "link_detected" "FAIL" "- Link is down"
        fi
        
        # Extract speed and duplex
        local speed duplex
        speed=$(echo "$link_status" | grep "Speed:" | awk '{print $2}')
        duplex=$(echo "$link_status" | grep "Duplex:" | awk '{print $2}')
        
        if [[ -n "$speed" ]] && [[ "$speed" != "Unknown!" ]]; then
            test_result "link_speed" "PASS" "- Speed: $speed"
        else
            test_result "link_speed" "FAIL" "- Speed unknown or not detected"
        fi
        
        if [[ -n "$duplex" ]] && [[ "$duplex" != "Unknown!" ]]; then
            test_result "link_duplex" "PASS" "- Duplex: $duplex"
        else
            test_result "link_duplex" "FAIL" "- Duplex unknown or not detected"
        fi
    else
        test_result "link_status" "FAIL" "- ethtool command failed"
    fi
}

# Test interface statistics
test_interface_statistics() {
    log_info "Testing interface statistics..."
    
    local stats_file="/sys/class/net/$INTERFACE/statistics"
    
    if [[ -d "$stats_file" ]]; then
        test_result "stats_available" "PASS" "- Statistics directory exists"
        
        # Check key statistics files
        local stat_files=("rx_packets" "tx_packets" "rx_bytes" "tx_bytes" "rx_errors" "tx_errors")
        
        for stat in "${stat_files[@]}"; do
            if [[ -f "$stats_file/$stat" ]]; then
                local value
                value=$(cat "$stats_file/$stat")
                test_result "stat_$stat" "PASS" "- $stat: $value"
            else
                test_result "stat_$stat" "FAIL" "- $stat file missing"
            fi
        done
    else
        test_result "stats_available" "FAIL" "- Statistics directory missing"
    fi
}

# Test driver information
test_driver_info() {
    log_info "Testing driver information..."
    
    if ! command -v ethtool &> /dev/null; then
        test_result "driver_info" "SKIP" "- ethtool not available"
        return 0
    fi
    
    local driver_info
    if driver_info=$(ethtool -i "$INTERFACE" 2>/dev/null); then
        local driver version
        driver=$(echo "$driver_info" | grep "driver:" | awk '{print $2}')
        version=$(echo "$driver_info" | grep "version:" | awk '{print $2}')
        
        if [[ -n "$driver" ]]; then
            test_result "driver_name" "PASS" "- Driver: $driver"
            
            # Check if it's ADIN2111 related
            if echo "$driver" | grep -qi "adin"; then
                test_result "driver_adin" "PASS" "- ADIN driver detected"
            else
                test_result "driver_adin" "WARN" "- Driver name doesn't contain 'adin'"
            fi
        else
            test_result "driver_name" "FAIL" "- Driver name not available"
        fi
        
        if [[ -n "$version" ]]; then
            test_result "driver_version" "PASS" "- Version: $version"
        else
            test_result "driver_version" "WARN" "- Driver version not available"
        fi
    else
        test_result "driver_info" "FAIL" "- Failed to get driver information"
    fi
}

# Test device tree information (if available)
test_device_tree() {
    log_info "Testing device tree information..."
    
    local dt_path="/sys/class/net/$INTERFACE/device/of_node"
    
    if [[ -d "$dt_path" ]]; then
        test_result "device_tree_available" "PASS" "- Device tree node exists"
        
        # Check for compatible string
        if [[ -f "$dt_path/compatible" ]]; then
            local compatible
            compatible=$(cat "$dt_path/compatible" 2>/dev/null | tr '\0' '\n')
            test_result "dt_compatible" "PASS" "- Compatible: $compatible"
            
            # Check for ADIN2111 compatible string
            if echo "$compatible" | grep -qi "adi.*adin"; then
                test_result "dt_adin_compatible" "PASS" "- ADIN compatible string found"
            else
                test_result "dt_adin_compatible" "WARN" "- ADIN compatible string not found"
            fi
        else
            test_result "dt_compatible" "FAIL" "- Compatible string not available"
        fi
    else
        test_result "device_tree_available" "SKIP" "- Device tree not available or not using DT"
    fi
}

# Test interface bring up/down
test_interface_toggle() {
    log_info "Testing interface bring up/down..."
    
    # Save original state
    local original_state
    original_state=$(ip link show "$INTERFACE" | grep -o "state [A-Z]*" | cut -d' ' -f2)
    
    # Try to bring interface down
    if ip link set "$INTERFACE" down 2>/dev/null; then
        sleep 1
        local down_state
        down_state=$(ip link show "$INTERFACE" | grep -o "state [A-Z]*" | cut -d' ' -f2)
        
        if [[ "$down_state" == "DOWN" ]]; then
            test_result "interface_down" "PASS" "- Interface brought down successfully"
        else
            test_result "interface_down" "FAIL" "- Interface state is $down_state after down command"
        fi
        
        # Try to bring interface back up
        if ip link set "$INTERFACE" up 2>/dev/null; then
            sleep 2
            local up_state
            up_state=$(ip link show "$INTERFACE" | grep -o "state [A-Z]*" | cut -d' ' -f2)
            
            if [[ "$up_state" == "UP" ]]; then
                test_result "interface_up" "PASS" "- Interface brought up successfully"
            else
                test_result "interface_up" "FAIL" "- Interface state is $up_state after up command"
            fi
        else
            test_result "interface_up" "FAIL" "- Failed to bring interface up"
        fi
    else
        test_result "interface_toggle" "FAIL" "- Failed to bring interface down"
    fi
}

# Test ADIN2111 specific sysfs entries
test_adin2111_sysfs() {
    log_info "Testing ADIN2111 specific sysfs entries..."
    
    local device_path="/sys/class/net/$INTERFACE/device"
    
    if [[ -d "$device_path" ]]; then
        # Look for SPI-related entries
        if [[ -f "$device_path/modalias" ]]; then
            local modalias
            modalias=$(cat "$device_path/modalias")
            if echo "$modalias" | grep -q "spi"; then
                test_result "spi_device" "PASS" "- SPI device detected: $modalias"
            else
                test_result "spi_device" "WARN" "- Not an SPI device: $modalias"
            fi
        fi
        
        # Look for vendor/device ID
        if [[ -f "$device_path/vendor" ]] && [[ -f "$device_path/device" ]]; then
            local vendor device
            vendor=$(cat "$device_path/vendor" 2>/dev/null || echo "unknown")
            device=$(cat "$device_path/device" 2>/dev/null || echo "unknown")
            test_result "vendor_device_id" "PASS" "- Vendor: $vendor, Device: $device"
        fi
        
        # Look for IRQ information
        if [[ -f "$device_path/irq" ]]; then
            local irq
            irq=$(cat "$device_path/irq")
            test_result "irq_assigned" "PASS" "- IRQ: $irq"
        fi
    else
        test_result "device_sysfs" "FAIL" "- Device sysfs path not found"
    fi
}

# Test module information
test_module_info() {
    log_info "Testing kernel module information..."
    
    if lsmod | grep -q adin; then
        local module_info
        module_info=$(lsmod | grep adin)
        test_result "adin_module_loaded" "PASS" "- ADIN module loaded: $module_info"
        
        # Get module details
        local module_name
        module_name=$(echo "$module_info" | awk '{print $1}')
        
        if [[ -n "$module_name" ]]; then
            if modinfo "$module_name" &>/dev/null; then
                local version description
                version=$(modinfo "$module_name" | grep "^version:" | cut -d' ' -f2-)
                description=$(modinfo "$module_name" | grep "^description:" | cut -d' ' -f2-)
                
                if [[ -n "$version" ]]; then
                    test_result "module_version" "PASS" "- Module version: $version"
                fi
                
                if [[ -n "$description" ]]; then
                    test_result "module_description" "PASS" "- Description: $description"
                fi
            fi
        fi
    else
        test_result "adin_module_loaded" "WARN" "- No ADIN module found in lsmod"
    fi
}

# Test basic connectivity
test_basic_connectivity() {
    log_info "Testing basic connectivity..."
    
    # Check if interface has an IP address
    local ip_addr
    ip_addr=$(ip addr show "$INTERFACE" | grep "inet " | awk '{print $2}' | head -n1)
    
    if [[ -n "$ip_addr" ]]; then
        test_result "ip_address" "PASS" "- IP address: $ip_addr"
        
        # Try to ping localhost through this interface
        if ping -c 1 -I "$INTERFACE" 127.0.0.1 &>/dev/null; then
            test_result "localhost_ping" "PASS" "- Localhost ping successful"
        else
            test_result "localhost_ping" "FAIL" "- Localhost ping failed"
        fi
    else
        test_result "ip_address" "WARN" "- No IP address assigned"
    fi
}

# Main test execution
main() {
    echo "=================================================="
    echo "ADIN2111 Basic Functionality Tests"
    echo "Copyright (C) 2025 Analog Devices Inc."
    echo "=================================================="
    echo
    echo "Testing interface: $INTERFACE"
    echo
    
    # Run all tests
    test_interface_exists || exit 1  # Exit early if interface doesn't exist
    test_interface_state
    test_interface_flags
    test_mac_address
    test_mtu
    test_link_status
    test_interface_statistics
    test_driver_info
    test_device_tree
    test_interface_toggle
    test_adin2111_sysfs
    test_module_info
    test_basic_connectivity
    
    # Print summary
    echo
    echo "=================================================="
    echo "Test Summary"
    echo "=================================================="
    echo "Total tests: $TESTS_TOTAL"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_success "All basic functionality tests passed!"
        exit 0
    else
        log_error "$TESTS_FAILED test(s) failed"
        exit 1
    fi
}

# Check if interface parameter is provided
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <interface>"
    echo "Example: $0 eth0"
    exit 1
fi

# Run main function
main
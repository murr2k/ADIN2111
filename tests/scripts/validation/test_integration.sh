#!/bin/bash

# ADIN2111 Integration Tests
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
        log_success "Integration test '$test_name': PASSED $details"
    elif [[ "$result" == "SKIP" ]]; then
        log_warn "Integration test '$test_name': SKIPPED $details"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "Integration test '$test_name': FAILED $details"
    fi
}

# Check if interface exists
check_interface() {
    if ! ip link show "$INTERFACE" &>/dev/null; then
        log_error "Interface $INTERFACE not found"
        exit 1
    fi
}

# Test device tree configuration
test_device_tree_config() {
    log_info "Testing device tree configuration..."
    
    local dt_path="/sys/class/net/$INTERFACE/device/of_node"
    
    if [[ ! -d "$dt_path" ]]; then
        test_result "device_tree_config" "SKIP" "- Device tree not available"
        return 0
    fi
    
    local issues=0
    local details=""
    
    # Check compatible string
    if [[ -f "$dt_path/compatible" ]]; then
        local compatible
        compatible=$(cat "$dt_path/compatible" 2>/dev/null | tr '\0' ' ')
        details="Compatible: $compatible"
        
        if echo "$compatible" | grep -qi "adi.*adin"; then
            log_info "Found ADIN compatible string: $compatible"
        else
            ((issues++))
            log_warn "ADIN compatible string not found"
        fi
    else
        ((issues++))
        details="No compatible string found"
    fi
    
    # Check SPI configuration
    if [[ -f "$dt_path/spi-max-frequency" ]]; then
        local max_freq
        max_freq=$(cat "$dt_path/spi-max-frequency" 2>/dev/null)
        log_info "SPI max frequency: $max_freq Hz"
        
        # ADIN2111 supports up to 25MHz
        if [[ $max_freq -gt 25000000 ]]; then
            ((issues++))
            log_warn "SPI frequency ($max_freq Hz) exceeds ADIN2111 maximum (25MHz)"
        fi
    fi
    
    # Check interrupt configuration
    if [[ -f "$dt_path/interrupts" ]]; then
        log_info "Interrupt configuration found"
    else
        ((issues++))
        log_warn "No interrupt configuration found"
    fi
    
    # Check reset GPIO
    if [[ -f "$dt_path/reset-gpios" ]]; then
        log_info "Reset GPIO configuration found"
    fi
    
    # Check power management
    if [[ -f "$dt_path/power-domains" ]]; then
        log_info "Power domain configuration found"
    fi
    
    if [[ $issues -eq 0 ]]; then
        test_result "device_tree_config" "PASS" "- $details"
        return 0
    else
        test_result "device_tree_config" "FAIL" "- $issues issues found, $details"
        return 1
    fi
}

# Test network stack integration
test_network_stack_integration() {
    log_info "Testing network stack integration..."
    
    local issues=0
    local details=""
    
    # Check if interface is registered with network stack
    if ip link show "$INTERFACE" >/dev/null 2>&1; then
        log_info "Interface registered with network stack"
    else
        ((issues++))
        log_error "Interface not registered with network stack"
    fi
    
    # Check netdev features
    if command -v ethtool >/dev/null 2>&1; then
        local features
        if features=$(ethtool -k "$INTERFACE" 2>/dev/null); then
            log_info "Network features available"
            
            # Check for specific features
            local feature_count=0
            while IFS= read -r line; do
                if echo "$line" | grep -q ": on\|: off"; then
                    ((feature_count++))
                fi
            done <<< "$features"
            
            details="$feature_count features configured"
            log_info "$details"
        else
            ((issues++))
            log_warn "Failed to read network features"
        fi
    fi
    
    # Check network statistics interface
    local stats_dir="/sys/class/net/$INTERFACE/statistics"
    if [[ -d "$stats_dir" ]]; then
        local stat_files
        stat_files=$(ls "$stats_dir" | wc -l)
        log_info "Network statistics interface available ($stat_files statistics)"
    else
        ((issues++))
        log_warn "Network statistics interface not available"
    fi
    
    # Check sysfs network interface
    local sysfs_dir="/sys/class/net/$INTERFACE"
    if [[ -d "$sysfs_dir" ]]; then
        log_info "Sysfs network interface available"
        
        # Check key sysfs files
        local sysfs_files=("address" "mtu" "flags" "operstate" "carrier")
        for file in "${sysfs_files[@]}"; do
            if [[ -f "$sysfs_dir/$file" ]]; then
                local value
                value=$(cat "$sysfs_dir/$file" 2>/dev/null)
                log_info "  $file: $value"
            else
                ((issues++))
                log_warn "Missing sysfs file: $file"
            fi
        done
    else
        ((issues++))
        log_error "Sysfs network interface not available"
    fi
    
    # Test basic socket operations
    if command -v nc >/dev/null 2>&1; then
        log_info "Testing basic socket operations..."
        
        # Test UDP socket binding to interface
        (
            timeout 5s nc -l -u -p 12350 >/dev/null 2>&1 &
            local nc_pid=$!
            sleep 1
            
            if echo "test" | timeout 2s nc -u 127.0.0.1 12350 >/dev/null 2>&1; then
                log_info "UDP socket operations successful"
            else
                ((issues++))
                log_warn "UDP socket operations failed"
            fi
            
            kill $nc_pid 2>/dev/null || true
        ) || true
    fi
    
    if [[ $issues -eq 0 ]]; then
        test_result "network_stack_integration" "PASS" "- $details"
        return 0
    else
        test_result "network_stack_integration" "FAIL" "- $issues issues found"
        return 1
    fi
}

# Test bridge compatibility (dual mode)
test_bridge_compatibility() {
    log_info "Testing bridge compatibility (dual mode simulation)..."
    
    # Check if bridge utilities are available
    if ! command -v brctl >/dev/null 2>&1 && ! command -v ip >/dev/null 2>&1; then
        test_result "bridge_compatibility" "SKIP" "- Bridge utilities not available"
        return 0
    fi
    
    local issues=0
    local test_bridge="test-adin2111-br"
    local cleanup_needed=false
    
    # Create a test bridge
    if ip link add name "$test_bridge" type bridge >/dev/null 2>&1; then
        cleanup_needed=true
        log_info "Created test bridge: $test_bridge"
        
        # Try to add interface to bridge
        if ip link set dev "$INTERFACE" master "$test_bridge" >/dev/null 2>&1; then
            log_info "Successfully added $INTERFACE to bridge"
            
            # Bring up the bridge
            if ip link set dev "$test_bridge" up >/dev/null 2>&1; then
                log_info "Bridge brought up successfully"
                
                # Check bridge status
                if ip link show "$test_bridge" | grep -q "state UP"; then
                    log_info "Bridge is in UP state"
                else
                    ((issues++))
                    log_warn "Bridge is not in UP state"
                fi
                
                # Check if interface is in bridge
                if ip link show "$INTERFACE" | grep -q "master $test_bridge"; then
                    log_info "Interface correctly shows bridge master"
                else
                    ((issues++))
                    log_warn "Interface does not show bridge master"
                fi
            else
                ((issues++))
                log_warn "Failed to bring up bridge"
            fi
            
            # Remove interface from bridge
            ip link set dev "$INTERFACE" nomaster >/dev/null 2>&1 || true
        else
            ((issues++))
            log_warn "Failed to add interface to bridge"
        fi
        
        # Clean up test bridge
        ip link set dev "$test_bridge" down >/dev/null 2>&1 || true
        ip link delete "$test_bridge" >/dev/null 2>&1 || true
    else
        ((issues++))
        log_warn "Failed to create test bridge"
    fi
    
    # Test bridge with brctl if available
    if command -v brctl >/dev/null 2>&1; then
        log_info "Testing brctl compatibility..."
        
        local bridge_list
        if bridge_list=$(brctl show 2>/dev/null); then
            log_info "brctl show command successful"
        else
            ((issues++))
            log_warn "brctl show command failed"
        fi
    fi
    
    # Test with systemd-networkd configuration (if available)
    if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
        log_info "systemd-networkd is active, testing compatibility..."
        
        # Check if there are any networkd configurations for this interface
        local networkd_configs="/etc/systemd/network"
        if [[ -d "$networkd_configs" ]]; then
            local config_files
            config_files=$(find "$networkd_configs" -name "*$INTERFACE*" -o -name "*adin*" 2>/dev/null | wc -l)
            if [[ $config_files -gt 0 ]]; then
                log_info "Found $config_files networkd configuration files"
            fi
        fi
    fi
    
    if [[ $issues -eq 0 ]]; then
        test_result "bridge_compatibility" "PASS" "- Bridge operations successful"
        return 0
    else
        test_result "bridge_compatibility" "FAIL" "- $issues issues found"
        return 1
    fi
}

# Test power management
test_power_management() {
    log_info "Testing power management features..."
    
    local pm_path="/sys/class/net/$INTERFACE/device/power"
    
    if [[ ! -d "$pm_path" ]]; then
        test_result "power_management" "SKIP" "- Power management not available"
        return 0
    fi
    
    local issues=0
    local details=""
    
    # Check power management control files
    local pm_files=("control" "runtime_status" "runtime_suspended_time" "runtime_active_time")
    local available_files=0
    
    for file in "${pm_files[@]}"; do
        if [[ -f "$pm_path/$file" ]]; then
            ((available_files++))
            local value
            value=$(cat "$pm_path/$file" 2>/dev/null)
            log_info "  $file: $value"
        fi
    done
    
    details="$available_files/$((${#pm_files[@]})) power management files available"
    
    # Check runtime power management
    if [[ -f "$pm_path/control" ]]; then
        local control_value
        control_value=$(cat "$pm_path/control" 2>/dev/null)
        
        if [[ "$control_value" == "auto" ]] || [[ "$control_value" == "on" ]]; then
            log_info "Power management control: $control_value"
        else
            ((issues++))
            log_warn "Unexpected power management control value: $control_value"
        fi
    fi
    
    # Check runtime status
    if [[ -f "$pm_path/runtime_status" ]]; then
        local runtime_status
        runtime_status=$(cat "$pm_path/runtime_status" 2>/dev/null)
        log_info "Runtime status: $runtime_status"
        
        if [[ "$runtime_status" != "active" ]] && [[ "$runtime_status" != "suspended" ]]; then
            ((issues++))
            log_warn "Unexpected runtime status: $runtime_status"
        fi
    fi
    
    # Test WoL (Wake-on-LAN) support if ethtool is available
    if command -v ethtool >/dev/null 2>&1; then
        local wol_info
        if wol_info=$(ethtool "$INTERFACE" 2>/dev/null | grep "Wake-on"); then
            log_info "Wake-on-LAN info: $wol_info"
        fi
    fi
    
    # Check for ADIN2111 specific power features
    local device_path="/sys/class/net/$INTERFACE/device"
    if [[ -f "$device_path/driver/module/parameters/power_save" ]]; then
        local power_save
        power_save=$(cat "$device_path/driver/module/parameters/power_save" 2>/dev/null)
        log_info "Driver power save parameter: $power_save"
    fi
    
    if [[ $issues -eq 0 ]]; then
        test_result "power_management" "PASS" "- $details"
        return 0
    else
        test_result "power_management" "FAIL" "- $issues issues found, $details"
        return 1
    fi
}

# Test ADIN2111 switch mode functionality
test_switch_mode_functionality() {
    log_info "Testing ADIN2111 switch mode functionality..."
    
    local issues=0
    local details=""
    
    # Check if driver supports switch mode
    local driver_path="/sys/class/net/$INTERFACE/device/driver"
    if [[ -d "$driver_path" ]]; then
        local driver_name
        driver_name=$(basename "$(readlink "$driver_path")" 2>/dev/null)
        log_info "Driver: $driver_name"
        
        if echo "$driver_name" | grep -qi "adin"; then
            log_info "ADIN driver detected"
        else
            ((issues++))
            log_warn "ADIN driver not detected: $driver_name"
        fi
    fi
    
    # Check for switch mode specific sysfs entries
    local sysfs_path="/sys/class/net/$INTERFACE/device"
    
    # Look for ADIN2111 specific attributes
    if [[ -f "$sysfs_path/modalias" ]]; then
        local modalias
        modalias=$(cat "$sysfs_path/modalias" 2>/dev/null)
        if echo "$modalias" | grep -q "spi"; then
            log_info "SPI device detected: $modalias"
        else
            ((issues++))
            log_warn "Not an SPI device: $modalias"
        fi
    fi
    
    # Check for single interface (switch mode) vs multiple interfaces (dual mode)
    local adin_interfaces
    adin_interfaces=$(ip link show | grep -c "eth" || echo "0")
    
    if [[ $adin_interfaces -eq 1 ]]; then
        log_info "Single interface detected - likely switch mode"
        details="Switch mode (single interface)"
    elif [[ $adin_interfaces -eq 2 ]]; then
        log_info "Two interfaces detected - likely dual mode"
        details="Dual mode (two interfaces)"
    else
        log_info "$adin_interfaces ethernet interfaces detected"
        details="$adin_interfaces interfaces"
    fi
    
    # Test hardware switching (no SPI traffic during forwarding)
    # This would require monitoring SPI traffic, which is complex
    # For now, we'll do a simple connectivity test
    log_info "Testing connectivity for switch functionality..."
    
    if ping -c 3 -W 2 -I "$INTERFACE" 127.0.0.1 >/dev/null 2>&1; then
        log_info "Loopback connectivity successful"
    else
        ((issues++))
        log_warn "Loopback connectivity failed"
    fi
    
    # Check for cut-through mode indicators (if available)
    if [[ -f "$sysfs_path/cut_through_mode" ]]; then
        local cut_through
        cut_through=$(cat "$sysfs_path/cut_through_mode" 2>/dev/null)
        log_info "Cut-through mode: $cut_through"
    fi
    
    # Check for store-and-forward mode indicators
    if [[ -f "$sysfs_path/store_forward_mode" ]]; then
        local store_forward
        store_forward=$(cat "$sysfs_path/store_forward_mode" 2>/dev/null)
        log_info "Store-and-forward mode: $store_forward"
    fi
    
    if [[ $issues -eq 0 ]]; then
        test_result "switch_mode_functionality" "PASS" "- $details"
        return 0
    else
        test_result "switch_mode_functionality" "FAIL" "- $issues issues found, $details"
        return 1
    fi
}

# Test VLAN support
test_vlan_support() {
    log_info "Testing VLAN support..."
    
    if ! command -v ip >/dev/null 2>&1; then
        test_result "vlan_support" "SKIP" "- ip command not available"
        return 0
    fi
    
    local issues=0
    local vlan_interface="${INTERFACE}.100"
    local cleanup_needed=false
    
    # Try to create a VLAN interface
    if ip link add link "$INTERFACE" name "$vlan_interface" type vlan id 100 >/dev/null 2>&1; then
        cleanup_needed=true
        log_info "VLAN interface created: $vlan_interface"
        
        # Try to bring up the VLAN interface
        if ip link set dev "$vlan_interface" up >/dev/null 2>&1; then
            log_info "VLAN interface brought up"
            
            # Check if VLAN interface is visible
            if ip link show "$vlan_interface" >/dev/null 2>&1; then
                log_info "VLAN interface visible in link list"
            else
                ((issues++))
                log_warn "VLAN interface not visible"
            fi
        else
            ((issues++))
            log_warn "Failed to bring up VLAN interface"
        fi
        
        # Clean up VLAN interface
        ip link set dev "$vlan_interface" down >/dev/null 2>&1 || true
        ip link delete "$vlan_interface" >/dev/null 2>&1 || true
    else
        ((issues++))
        log_warn "Failed to create VLAN interface"
    fi
    
    # Check ethtool VLAN features
    if command -v ethtool >/dev/null 2>&1; then
        local vlan_features
        if vlan_features=$(ethtool -k "$INTERFACE" 2>/dev/null | grep vlan); then
            log_info "VLAN features:"
            echo "$vlan_features" | while read -r line; do
                log_info "  $line"
            done
        fi
    fi
    
    if [[ $issues -eq 0 ]]; then
        test_result "vlan_support" "PASS" "- VLAN operations successful"
        return 0
    else
        test_result "vlan_support" "FAIL" "- $issues issues found"
        return 1
    fi
}

# Main test execution
main() {
    echo "=================================================="
    echo "ADIN2111 Integration Tests"
    echo "Copyright (C) 2025 Analog Devices Inc."
    echo "=================================================="
    echo
    echo "Testing interface: $INTERFACE"
    echo
    
    # Check prerequisites
    check_interface
    
    log_info "Starting ADIN2111 integration tests..."
    
    # Run integration tests
    test_device_tree_config
    test_network_stack_integration
    test_bridge_compatibility
    test_power_management
    test_switch_mode_functionality
    test_vlan_support
    
    # Print summary
    echo
    echo "=================================================="
    echo "Integration Test Summary"
    echo "=================================================="
    echo "Total tests: $TESTS_TOTAL"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_success "All integration tests passed!"
        exit 0
    else
        log_error "$TESTS_FAILED integration test(s) failed"
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
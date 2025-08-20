#!/bin/bash

# ADIN2111 Device Tree Validation Script
# This script validates the device tree files for QEMU ADIN2111 testing

set -e

PROJECT_ROOT="/home/murr2k/projects/ADIN2111"
DTS_DIR="$PROJECT_ROOT/dts"
LOG_FILE="$PROJECT_ROOT/logs/dt-validation-$(date +%Y%m%d-%H%M%S).log"

echo "=== ADIN2111 Device Tree Validation ===" | tee "$LOG_FILE"
echo "Timestamp: $(date)" | tee -a "$LOG_FILE"
echo "DTS Directory: $DTS_DIR" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# Function to log messages
log_message() {
    echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to validate DTS file structure
validate_dts_structure() {
    local file="$1"
    local basename=$(basename "$file")
    
    log_message "Validating $basename structure..."
    
    # Check for required components
    local required_components=(
        "/dts-v1/"
        "compatible"
        "spi@9060000"
        "adi,adin2111"
        "ethernet-ports"
        "mdio"
    )
    
    local missing_components=()
    
    for component in "${required_components[@]}"; do
        if ! grep -q "$component" "$file"; then
            missing_components+=("$component")
        fi
    done
    
    if [ ${#missing_components[@]} -eq 0 ]; then
        log_message "✓ $basename: All required components found"
        return 0
    else
        log_message "✗ $basename: Missing components: ${missing_components[*]}"
        return 1
    fi
}

# Function to check SPI configuration
validate_spi_config() {
    local file="$1"
    local basename=$(basename "$file")
    
    log_message "Validating $basename SPI configuration..."
    
    # Check SPI controller address
    if grep -q "spi@9060000" "$file"; then
        log_message "✓ $basename: Correct SPI controller address (0x09060000)"
    else
        log_message "✗ $basename: Incorrect or missing SPI controller address"
        return 1
    fi
    
    # Check SPI frequency
    if grep -q "spi-max-frequency = <25000000>" "$file"; then
        log_message "✓ $basename: Correct SPI frequency (25MHz)"
    else
        log_message "⚠ $basename: SPI frequency not set to 25MHz"
    fi
    
    # Check SPI mode flags
    if grep -q "spi-cpha" "$file" && grep -q "spi-cpol" "$file"; then
        log_message "✓ $basename: SPI mode flags set correctly"
    else
        log_message "⚠ $basename: SPI mode flags may be missing"
    fi
    
    return 0
}

# Function to validate MAC addresses
validate_mac_addresses() {
    local file="$1"
    local basename=$(basename "$file")
    
    log_message "Validating $basename MAC addresses..."
    
    local mac_count=$(grep -c "local-mac-address\|mac-address" "$file" || true)
    
    if [ "$mac_count" -gt 0 ]; then
        log_message "✓ $basename: Found $mac_count MAC address assignments"
        
        # Check for unique MAC addresses
        local mac_addresses=$(grep -o "\[.*\]" "$file" | grep -E "([0-9a-f]{2} ){5}[0-9a-f]{2}" || true)
        local unique_macs=$(echo "$mac_addresses" | sort -u | wc -l)
        local total_macs=$(echo "$mac_addresses" | wc -l)
        
        if [ "$unique_macs" -eq "$total_macs" ] && [ "$total_macs" -gt 0 ]; then
            log_message "✓ $basename: All MAC addresses are unique"
        else
            log_message "⚠ $basename: Duplicate MAC addresses detected"
        fi
    else
        log_message "✗ $basename: No MAC addresses found"
        return 1
    fi
    
    return 0
}

# Function to validate interrupt configuration
validate_interrupts() {
    local file="$1"
    local basename=$(basename "$file")
    
    log_message "Validating $basename interrupt configuration..."
    
    # Check for interrupt parent
    if grep -q "interrupt-parent = <&gic>" "$file"; then
        log_message "✓ $basename: Interrupt parent set to GIC"
    else
        log_message "✗ $basename: Missing or incorrect interrupt parent"
        return 1
    fi
    
    # Check for interrupt lines
    local irq_count=$(grep -c "interrupts = <0 [0-9]* 4>" "$file" || true)
    if [ "$irq_count" -gt 0 ]; then
        log_message "✓ $basename: Found $irq_count interrupt configurations"
    else
        log_message "✗ $basename: No valid interrupt configurations found"
        return 1
    fi
    
    return 0
}

# Main validation function
validate_device_tree() {
    local file="$1"
    local basename=$(basename "$file")
    
    log_message ""
    log_message "=== Validating $basename ==="
    
    if [ ! -f "$file" ]; then
        log_message "✗ $basename: File not found"
        return 1
    fi
    
    local validation_passed=true
    
    # Run all validation checks
    validate_dts_structure "$file" || validation_passed=false
    validate_spi_config "$file" || validation_passed=false
    validate_mac_addresses "$file" || validation_passed=false
    validate_interrupts "$file" || validation_passed=false
    
    if [ "$validation_passed" = true ]; then
        log_message "✓ $basename: All validations passed"
        return 0
    else
        log_message "✗ $basename: Some validations failed"
        return 1
    fi
}

# Function to generate summary report
generate_summary() {
    log_message ""
    log_message "=== Validation Summary ==="
    
    local total_files=0
    local passed_files=0
    
    for dts_file in "$DTS_DIR"/*.dts; do
        if [ -f "$dts_file" ]; then
            ((total_files++))
            if validate_device_tree "$dts_file"; then
                ((passed_files++))
            fi
        fi
    done
    
    log_message "Total files: $total_files"
    log_message "Passed: $passed_files"
    log_message "Failed: $((total_files - passed_files))"
    
    if [ "$passed_files" -eq "$total_files" ]; then
        log_message "✓ All device tree files passed validation"
        return 0
    else
        log_message "✗ Some device tree files failed validation"
        return 1
    fi
}

# Function to check if device tree compiler is available
check_dtc() {
    log_message "Checking for device tree compiler..."
    
    if command -v dtc &> /dev/null; then
        local dtc_version=$(dtc --version 2>&1 | head -1)
        log_message "✓ Device tree compiler found: $dtc_version"
        return 0
    else
        log_message "⚠ Device tree compiler (dtc) not found"
        log_message "  Install with: sudo apt-get install device-tree-compiler"
        return 1
    fi
}

# Function to compile device trees if dtc is available
compile_device_trees() {
    if ! check_dtc; then
        log_message "Skipping compilation due to missing dtc"
        return 0
    fi
    
    log_message ""
    log_message "=== Compiling Device Trees ==="
    
    local compiled=0
    local failed=0
    
    for dts_file in "$DTS_DIR"/*.dts; do
        if [ -f "$dts_file" ]; then
            local basename=$(basename "$dts_file" .dts)
            local dtb_file="$DTS_DIR/$basename.dtb"
            
            log_message "Compiling $basename.dts..."
            
            if dtc -I dts -O dtb -o "$dtb_file" "$dts_file" 2>&1 | tee -a "$LOG_FILE"; then
                log_message "✓ $basename.dts compiled successfully"
                ((compiled++))
            else
                log_message "✗ $basename.dts compilation failed"
                ((failed++))
            fi
        fi
    done
    
    log_message "Compilation summary: $compiled successful, $failed failed"
    
    if [ "$failed" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Main execution
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    
    log_message "Starting device tree validation..."
    
    # Check DTS directory
    if [ ! -d "$DTS_DIR" ]; then
        log_message "✗ DTS directory not found: $DTS_DIR"
        exit 1
    fi
    
    # List available DTS files
    log_message "Available DTS files:"
    for dts_file in "$DTS_DIR"/*.dts; do
        if [ -f "$dts_file" ]; then
            log_message "  - $(basename "$dts_file")"
        fi
    done
    
    # Run validation
    if generate_summary; then
        log_message ""
        log_message "✓ Device tree validation completed successfully"
        
        # Try to compile if dtc is available
        compile_device_trees
        
        exit 0
    else
        log_message ""
        log_message "✗ Device tree validation failed"
        exit 1
    fi
}

# Execute main function
main "$@"
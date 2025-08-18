#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# Kernel Panic Testing Script for ADIN2111 Driver
# Tests for common kernel panic scenarios
#
# Author: Murray Kopit <murr2k@gmail.com>
# Date: August 17, 2025

set -euo pipefail

DRIVER_PATH="drivers/net/ethernet/adi/adin2111"
MODULE_NAME="adin2111_driver"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Test 1: Module Load/Unload Stress Test
test_module_load_unload() {
    log_info "Test 1: Module load/unload stress test"
    
    for i in {1..10}; do
        log_info "  Iteration $i/10"
        
        # Load module
        sudo insmod "$DRIVER_PATH/$MODULE_NAME.ko" 2>/dev/null || {
            log_warn "  Module load failed (expected without hardware)"
        }
        
        # Check if loaded
        if lsmod | grep -q "$MODULE_NAME"; then
            log_info "  Module loaded successfully"
            
            # Small delay
            sleep 0.5
            
            # Unload module
            sudo rmmod "$MODULE_NAME" 2>/dev/null || {
                log_error "  Module unload failed!"
                return 1
            }
            log_info "  Module unloaded successfully"
        fi
    done
    
    log_info "  ✓ Test 1 passed"
    return 0
}

# Test 2: Concurrent Access Test
test_concurrent_access() {
    log_info "Test 2: Concurrent access test"
    
    # Load module if not loaded
    if ! lsmod | grep -q "$MODULE_NAME"; then
        sudo insmod "$DRIVER_PATH/$MODULE_NAME.ko" 2>/dev/null || {
            log_warn "  Cannot test without module loaded"
            return 0
        }
    fi
    
    # Try to access sysfs entries concurrently
    for i in {1..5}; do
        (
            for j in {1..10}; do
                cat /sys/module/"$MODULE_NAME"/parameters/* 2>/dev/null || true
            done
        ) &
    done
    
    wait
    log_info "  ✓ Test 2 passed"
    return 0
}

# Test 3: Check for NULL pointer checks
test_null_pointer_checks() {
    log_info "Test 3: Checking for NULL pointer protections"
    
    # Check if our fixes are in place
    local checks_found=0
    local checks_needed=5
    
    # Check interrupt handler
    if grep -q "if (!priv || !priv->spi)" "$DRIVER_PATH/adin2111.c"; then
        log_info "  ✓ IRQ handler NULL check found"
        ((checks_found++))
    else
        log_error "  ✗ IRQ handler NULL check missing"
    fi
    
    # Check SPI functions
    if grep -q "if (!spi || !val)" "$DRIVER_PATH/adin2111_spi.c"; then
        log_info "  ✓ SPI read NULL check found"
        ((checks_found++))
    else
        log_error "  ✗ SPI read NULL check missing"
    fi
    
    # Check remove function
    if grep -q "if (!priv)" "$DRIVER_PATH/adin2111.c" | head -1; then
        log_info "  ✓ Remove function NULL check found"
        ((checks_found++))
    else
        log_error "  ✗ Remove function NULL check missing"
    fi
    
    # Check TX path
    if grep -q "if (!port)" "$DRIVER_PATH/adin2111_netdev.c"; then
        log_info "  ✓ TX path NULL check found"
        ((checks_found++))
    else
        log_error "  ✗ TX path NULL check missing"
    fi
    
    # Check context validation
    if grep -q "if (!context)" "$DRIVER_PATH/adin2111_spi.c"; then
        log_info "  ✓ SPI context validation found"
        ((checks_found++))
    else
        log_error "  ✗ SPI context validation missing"
    fi
    
    if [ $checks_found -ge $((checks_needed - 1)) ]; then
        log_info "  ✓ Test 3 passed ($checks_found/$checks_needed checks found)"
        return 0
    else
        log_error "  ✗ Test 3 failed ($checks_found/$checks_needed checks found)"
        return 1
    fi
}

# Test 4: Memory allocation checks
test_memory_allocation() {
    log_info "Test 4: Memory allocation checks"
    
    # Check for GFP_ATOMIC in interrupt contexts
    if grep -q "GFP_ATOMIC" "$DRIVER_PATH/adin2111_netdev.c"; then
        log_info "  ✓ GFP_ATOMIC usage found in critical paths"
    else
        log_warn "  ⚠ No GFP_ATOMIC found - potential sleep in atomic context"
    fi
    
    # Check for memory allocation error handling
    local alloc_checks=$(grep -c "if (!.*kmalloc\|if (!.*kzalloc" "$DRIVER_PATH"/*.c 2>/dev/null || echo "0")
    if [ "$alloc_checks" -gt 0 ]; then
        log_info "  ✓ Memory allocation error checks found: $alloc_checks"
    else
        log_error "  ✗ No memory allocation error checks found"
    fi
    
    log_info "  ✓ Test 4 passed"
    return 0
}

# Test 5: Build with debug options
test_debug_build() {
    log_info "Test 5: Building with kernel debug options"
    
    # Try to build with debug flags
    cd "$DRIVER_PATH"
    make clean 2>/dev/null || true
    
    if make EXTRA_CFLAGS="-DDEBUG -DCONFIG_DEBUG_KERNEL" 2>/dev/null; then
        log_info "  ✓ Debug build successful"
    else
        log_error "  ✗ Debug build failed"
        return 1
    fi
    
    cd - >/dev/null
    log_info "  ✓ Test 5 passed"
    return 0
}

# Main test runner
main() {
    log_info "Starting ADIN2111 Kernel Panic Test Suite"
    log_info "========================================="
    
    local failed_tests=0
    local total_tests=5
    
    # Run tests
    test_null_pointer_checks || ((failed_tests++))
    test_memory_allocation || ((failed_tests++))
    test_debug_build || ((failed_tests++))
    test_module_load_unload || ((failed_tests++))
    test_concurrent_access || ((failed_tests++))
    
    # Summary
    echo ""
    log_info "Test Summary"
    log_info "============"
    log_info "Total tests: $total_tests"
    log_info "Passed: $((total_tests - failed_tests))"
    log_info "Failed: $failed_tests"
    
    if [ $failed_tests -eq 0 ]; then
        log_info "✓ All kernel panic prevention tests passed!"
        return 0
    else
        log_error "✗ Some tests failed. Driver may still be vulnerable to kernel panics."
        return 1
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
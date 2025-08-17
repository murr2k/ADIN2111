#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# ADIN2111 Test Framework - Shell Script Support
# Provides common test utilities and result tracking
#
# Author: Murray Kopit <murr2k@gmail.com>
# Date: August 16, 2025

# Test result tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0
WARNED_TESTS=0

# Colors for output (disabled in CI)
if [ -t 1 ] && [ -z "${CI:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Test result recording
test_result() {
    local test_name="$1"
    local result="$2"
    local details="${3:-}"
    
    ((TOTAL_TESTS++))
    
    case "$result" in
        PASS)
            ((PASSED_TESTS++))
            log_success "$test_name $details"
            ;;
        FAIL)
            ((FAILED_TESTS++))
            log_error "$test_name $details"
            ;;
        SKIP)
            ((SKIPPED_TESTS++))
            log_warn "$test_name SKIPPED $details"
            ;;
        WARN)
            ((WARNED_TESTS++))
            log_warn "$test_name WARNING $details"
            ;;
        *)
            log_error "$test_name UNKNOWN STATUS"
            ;;
    esac
}

# Initialize test framework
test_framework_init() {
    TOTAL_TESTS=0
    PASSED_TESTS=0
    FAILED_TESTS=0
    SKIPPED_TESTS=0
    WARNED_TESTS=0
    
    log_info "Test framework initialized"
}

# Print test summary
test_framework_summary() {
    echo ""
    echo "========================================"
    echo "Test Summary:"
    echo "  Total Tests: $TOTAL_TESTS"
    echo -e "  ${GREEN}Passed: $PASSED_TESTS${NC}"
    echo -e "  ${RED}Failed: $FAILED_TESTS${NC}"
    echo -e "  ${YELLOW}Skipped: $SKIPPED_TESTS${NC}"
    echo -e "  ${YELLOW}Warnings: $WARNED_TESTS${NC}"
    
    if [ $TOTAL_TESTS -gt 0 ]; then
        local pass_rate
        pass_rate=$(awk "BEGIN {printf \"%.1f\", $PASSED_TESTS*100/$TOTAL_TESTS}")
        echo "  Pass Rate: ${pass_rate}%"
    fi
    echo "========================================"
    
    # Return non-zero if any tests failed
    if [ $FAILED_TESTS -gt 0 ]; then
        return 1
    else
        return 0
    fi
}

# Check for required command
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command not found: $cmd"
        return 1
    fi
    return 0
}

# Safe command execution with error handling
safe_exec() {
    local cmd="$1"
    local description="${2:-Executing command}"
    
    log_info "$description"
    if eval "$cmd"; then
        return 0
    else
        local exit_code=$?
        log_error "Command failed with exit code $exit_code: $cmd"
        return $exit_code
    fi
}

# Export functions for use in test scripts
export -f log_info log_success log_error log_warn
export -f test_result test_framework_init test_framework_summary
export -f require_command safe_exec
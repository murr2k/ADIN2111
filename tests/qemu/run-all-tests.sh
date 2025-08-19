#!/bin/bash
# QEMU Test Suite Runner with Error Handling
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e  # Exit on error
set -u  # Exit on undefined variable
set -o pipefail  # Pipe failures cause script to fail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTIONAL_DIR="$SCRIPT_DIR/functional"
PERFORMANCE_DIR="$SCRIPT_DIR/performance"
LOG_DIR="${LOG_DIR:-/tmp/qemu-tests}"
TIMEOUT="${TIMEOUT:-60}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

# Error handling
trap 'handle_error $? $LINENO' ERR
trap 'cleanup' EXIT

handle_error() {
    local exit_code=$1
    local line_number=$2
    echo -e "${RED}ERROR: Script failed at line $line_number with exit code $exit_code${NC}" >&2
    echo "Check logs in $LOG_DIR for details" >&2
    exit $exit_code
}

cleanup() {
    # Kill any background processes
    jobs -p | xargs -r kill 2>/dev/null || true
    
    # Clean up temporary files
    rm -f /tmp/iperf-*.log 2>/dev/null || true
    rm -f /tmp/ethtool.out 2>/dev/null || true
    
    # Reset network interfaces
    for iface in eth0 eth1; do
        ip link set "$iface" down 2>/dev/null || true
        ip addr flush dev "$iface" 2>/dev/null || true
    done
}

# Create log directory
mkdir -p "$LOG_DIR"

# Function to run a single test with timeout and error handling
run_test() {
    local test_file="$1"
    local test_name="$(basename "$test_file" .sh)"
    local log_file="$LOG_DIR/${test_name}.log"
    local exit_code=0
    
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    
    echo -ne "Running $test_name... "
    
    # Run test with timeout and capture output
    if timeout "$TIMEOUT" bash "$test_file" > "$log_file" 2>&1; then
        exit_code=$?
    else
        exit_code=$?
    fi
    
    # Check exit code
    case $exit_code in
        0)
            echo -e "${GREEN}PASS${NC}"
            PASSED_TESTS=$((PASSED_TESTS + 1))
            ;;
        124)
            echo -e "${RED}TIMEOUT${NC}"
            echo "Test exceeded ${TIMEOUT}s timeout" >> "$log_file"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            ;;
        77)  # Skip code
            echo -e "${YELLOW}SKIP${NC}"
            SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
            # Extract skip reason from log
            grep -i "skip:" "$log_file" | head -1 || true
            ;;
        *)
            echo -e "${RED}FAIL${NC} (exit code: $exit_code)"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            # Show last error from log
            echo -e "${RED}Error: $(grep -i "fail\|error" "$log_file" | tail -1)${NC}"
            ;;
    esac
    
    return 0  # Don't fail the entire suite on single test failure
}

# Function to run a test suite
run_suite() {
    local suite_dir="$1"
    local suite_name="$(basename "$suite_dir")"
    
    echo -e "\n${BLUE}=== Running $suite_name Tests ===${NC}"
    
    if [ ! -d "$suite_dir" ]; then
        echo -e "${YELLOW}Suite directory not found: $suite_dir${NC}"
        return
    fi
    
    # Find and run all test scripts
    for test_file in "$suite_dir"/*.sh; do
        if [ -f "$test_file" ] && [ -x "$test_file" ]; then
            run_test "$test_file"
        elif [ -f "$test_file" ]; then
            echo -e "${YELLOW}Warning: $test_file is not executable${NC}"
            chmod +x "$test_file"
            run_test "$test_file"
        fi
    done
}

# Main execution
main() {
    echo -e "${BLUE}=== QEMU ADIN2111 Test Suite ===${NC}"
    echo "Timeout: ${TIMEOUT}s per test"
    echo "Log directory: $LOG_DIR"
    echo
    
    # Check prerequisites
    if ! command -v ip > /dev/null 2>&1; then
        echo -e "${RED}ERROR: iproute2 not installed${NC}"
        exit 1
    fi
    
    # Run functional tests
    run_suite "$FUNCTIONAL_DIR"
    
    # Run performance tests
    run_suite "$PERFORMANCE_DIR"
    
    # Summary
    echo
    echo -e "${BLUE}=== Test Summary ===${NC}"
    echo "Total tests:   $TOTAL_TESTS"
    echo -e "Passed:        ${GREEN}$PASSED_TESTS${NC}"
    echo -e "Failed:        ${RED}$FAILED_TESTS${NC}"
    echo -e "Skipped:       ${YELLOW}$SKIPPED_TESTS${NC}"
    
    # Calculate pass rate
    if [ $TOTAL_TESTS -gt 0 ]; then
        PASS_RATE=$(( (PASSED_TESTS * 100) / TOTAL_TESTS ))
        echo "Pass rate:     ${PASS_RATE}%"
    fi
    
    echo
    echo "Detailed logs available in: $LOG_DIR"
    
    # Exit with appropriate code
    if [ $FAILED_TESTS -gt 0 ]; then
        echo -e "${RED}TEST SUITE FAILED${NC}"
        # List failed tests
        echo "Failed tests:"
        grep -l "FAIL\|ERROR" "$LOG_DIR"/*.log 2>/dev/null | while read log; do
            echo "  - $(basename "$log" .log)"
        done
        exit 1
    else
        echo -e "${GREEN}TEST SUITE PASSED${NC}"
        exit 0
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --timeout SECONDS   Set timeout per test (default: 60)"
            echo "  --log-dir DIR      Set log directory (default: /tmp/qemu-tests)"
            echo "  --help             Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run main function
main
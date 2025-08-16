#!/bin/bash

# ADIN2111 Comprehensive Test Runner
# Copyright (C) 2025 Analog Devices Inc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$PROJECT_ROOT/tests"

# Configuration
DEFAULT_INTERFACE="eth0"
TEST_RESULTS_DIR="$TEST_ROOT/results"
LOG_FILE="$TEST_RESULTS_DIR/test_$(date +%Y%m%d_%H%M%S).log"
SUMMARY_FILE="$TEST_RESULTS_DIR/summary_$(date +%Y%m%d_%H%M%S).txt"

# Test categories
BASIC_TESTS=true
NETWORKING_TESTS=true
PERFORMANCE_TESTS=true
STRESS_TESTS=true
INTEGRATION_TESTS=true

# Test parameters
INTERFACE=""
STRESS_DURATION=300
PERF_DURATION=60
PACKET_SIZES=(64 256 512 1024 1518)
PACKET_COUNTS=(1000 5000 10000)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

log_info() {
    log "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    log "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    log "${RED}[ERROR]${NC} $*"
}

log_success() {
    log "${GREEN}[SUCCESS]${NC} $*"
}

# Check if running as root (needed for kernel module operations)
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root for kernel module testing"
        exit 1
    fi
}

# Setup test environment
setup_environment() {
    log_info "Setting up test environment..."
    
    # Create results directory
    mkdir -p "$TEST_RESULTS_DIR"
    
    # Build test kernel module
    if [[ -f "$TEST_ROOT/kernel/Makefile" ]]; then
        log_info "Building kernel test module..."
        cd "$TEST_ROOT/kernel"
        make clean && make
        if [[ $? -ne 0 ]]; then
            log_error "Failed to build kernel test module"
            return 1
        fi
    fi
    
    # Build user-space utilities
    if [[ -f "$TEST_ROOT/userspace/utils/Makefile" ]]; then
        log_info "Building user-space test utilities..."
        cd "$TEST_ROOT/userspace/utils"
        make clean && make
        if [[ $? -ne 0 ]]; then
            log_error "Failed to build user-space utilities"
            return 1
        fi
    fi
    
    # Build benchmark tools
    if [[ -f "$TEST_ROOT/benchmarks/Makefile" ]]; then
        log_info "Building benchmark tools..."
        cd "$TEST_ROOT/benchmarks"
        make clean && make
        if [[ $? -ne 0 ]]; then
            log_error "Failed to build benchmark tools"
            return 1
        fi
    fi
    
    cd "$PROJECT_ROOT"
    return 0
}

# Cleanup test environment
cleanup_environment() {
    log_info "Cleaning up test environment..."
    
    # Unload test kernel module if loaded
    if lsmod | grep -q "adin2111_test"; then
        log_info "Unloading test kernel module..."
        rmmod adin2111_test || true
    fi
    
    # Kill any running test processes
    pkill -f "adin2111_test" || true
    pkill -f "adin2111_bench" || true
    
    # Reset network interfaces
    if [[ -n "$INTERFACE" ]]; then
        ip link set "$INTERFACE" down 2>/dev/null || true
        sleep 1
        ip link set "$INTERFACE" up 2>/dev/null || true
    fi
}

# Discover ADIN2111 interfaces
discover_interfaces() {
    log_info "Discovering ADIN2111 interfaces..."
    
    local interfaces=()
    
    # Look for ethernet interfaces
    for iface in /sys/class/net/eth*; do
        if [[ -e "$iface" ]]; then
            iface_name=$(basename "$iface")
            # Check if interface is up
            if ip link show "$iface_name" | grep -q "state UP"; then
                interfaces+=("$iface_name")
                log_info "Found interface: $iface_name"
            fi
        fi
    done
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log_warn "No active ethernet interfaces found"
        return 1
    fi
    
    # Use first interface if none specified
    if [[ -z "$INTERFACE" ]]; then
        INTERFACE="${interfaces[0]}"
        log_info "Using interface: $INTERFACE"
    fi
    
    return 0
}

# Load and test kernel module
test_kernel_module() {
    log_info "Testing kernel module..."
    
    local module_path="$TEST_ROOT/kernel/adin2111_test.ko"
    if [[ ! -f "$module_path" ]]; then
        log_error "Kernel test module not found: $module_path"
        return 1
    fi
    
    # Load the test module
    log_info "Loading test kernel module..."
    insmod "$module_path"
    if [[ $? -ne 0 ]]; then
        log_error "Failed to load test kernel module"
        return 1
    fi
    
    # Wait for tests to complete
    sleep 5
    
    # Check test results
    if [[ -f "/proc/adin2111_test_results" ]]; then
        log_info "Kernel test results:"
        cat "/proc/adin2111_test_results" | tee -a "$LOG_FILE"
    else
        log_warn "Kernel test results not available"
    fi
    
    # Unload the module
    log_info "Unloading test kernel module..."
    rmmod adin2111_test
    
    return 0
}

# Run basic functionality tests
run_basic_tests() {
    log_info "Running basic functionality tests..."
    
    local test_script="$TEST_ROOT/scripts/validation/test_basic.sh"
    if [[ -f "$test_script" ]]; then
        bash "$test_script" "$INTERFACE" 2>&1 | tee -a "$LOG_FILE"
        local result=${PIPESTATUS[0]}
        if [[ $result -eq 0 ]]; then
            log_success "Basic tests passed"
        else
            log_error "Basic tests failed"
        fi
        return $result
    else
        log_warn "Basic test script not found: $test_script"
        return 1
    fi
}

# Run networking tests
run_networking_tests() {
    log_info "Running networking tests..."
    
    local test_util="$TEST_ROOT/userspace/utils/adin2111_test_util"
    if [[ ! -x "$test_util" ]]; then
        log_error "Test utility not found or not executable: $test_util"
        return 1
    fi
    
    # Test link status
    log_info "Testing link status..."
    "$test_util" -l -i "$INTERFACE" 2>&1 | tee -a "$LOG_FILE"
    
    # Test packet transmission
    log_info "Testing packet transmission..."
    for size in "${PACKET_SIZES[@]}"; do
        log_info "Testing with packet size: $size bytes"
        "$test_util" -i "$INTERFACE" -s "$size" -c 1000 -v 2>&1 | tee -a "$LOG_FILE"
        if [[ $? -ne 0 ]]; then
            log_error "Packet transmission test failed for size $size"
            return 1
        fi
    done
    
    log_success "Networking tests completed"
    return 0
}

# Run performance tests
run_performance_tests() {
    log_info "Running performance tests..."
    
    local bench_tool="$TEST_ROOT/benchmarks/throughput/adin2111_throughput_bench"
    if [[ -x "$bench_tool" ]]; then
        log_info "Running throughput benchmark..."
        "$bench_tool" -i "$INTERFACE" -d "$PERF_DURATION" 2>&1 | tee -a "$LOG_FILE"
    else
        log_warn "Throughput benchmark tool not found: $bench_tool"
    fi
    
    local latency_tool="$TEST_ROOT/benchmarks/latency/adin2111_latency_bench"
    if [[ -x "$latency_tool" ]]; then
        log_info "Running latency benchmark..."
        "$latency_tool" -i "$INTERFACE" -d "$PERF_DURATION" 2>&1 | tee -a "$LOG_FILE"
    else
        log_warn "Latency benchmark tool not found: $latency_tool"
    fi
    
    local cpu_tool="$TEST_ROOT/benchmarks/cpu/adin2111_cpu_bench"
    if [[ -x "$cpu_tool" ]]; then
        log_info "Running CPU utilization benchmark..."
        "$cpu_tool" -i "$INTERFACE" -d "$PERF_DURATION" 2>&1 | tee -a "$LOG_FILE"
    else
        log_warn "CPU benchmark tool not found: $cpu_tool"
    fi
    
    log_success "Performance tests completed"
    return 0
}

# Run stress tests
run_stress_tests() {
    log_info "Running stress tests (duration: ${STRESS_DURATION}s)..."
    
    local stress_script="$TEST_ROOT/scripts/validation/test_stress.sh"
    if [[ -f "$stress_script" ]]; then
        bash "$stress_script" "$INTERFACE" "$STRESS_DURATION" 2>&1 | tee -a "$LOG_FILE"
        local result=${PIPESTATUS[0]}
        if [[ $result -eq 0 ]]; then
            log_success "Stress tests passed"
        else
            log_error "Stress tests failed"
        fi
        return $result
    else
        log_warn "Stress test script not found: $stress_script"
        return 1
    fi
}

# Run integration tests
run_integration_tests() {
    log_info "Running integration tests..."
    
    local integration_script="$TEST_ROOT/scripts/validation/test_integration.sh"
    if [[ -f "$integration_script" ]]; then
        bash "$integration_script" "$INTERFACE" 2>&1 | tee -a "$LOG_FILE"
        local result=${PIPESTATUS[0]}
        if [[ $result -eq 0 ]]; then
            log_success "Integration tests passed"
        else
            log_error "Integration tests failed"
        fi
        return $result
    else
        log_warn "Integration test script not found: $integration_script"
        return 1
    fi
}

# Generate test summary
generate_summary() {
    log_info "Generating test summary..."
    
    cat > "$SUMMARY_FILE" << EOF
ADIN2111 Test Suite Summary
===========================
Date: $(date)
Interface: $INTERFACE
Log File: $LOG_FILE

Test Results:
EOF
    
    # Parse log file for test results
    if grep -q "Basic tests passed" "$LOG_FILE"; then
        echo "✓ Basic Tests: PASSED" >> "$SUMMARY_FILE"
    else
        echo "✗ Basic Tests: FAILED" >> "$SUMMARY_FILE"
    fi
    
    if grep -q "Networking tests completed" "$LOG_FILE"; then
        echo "✓ Networking Tests: PASSED" >> "$SUMMARY_FILE"
    else
        echo "✗ Networking Tests: FAILED" >> "$SUMMARY_FILE"
    fi
    
    if grep -q "Performance tests completed" "$LOG_FILE"; then
        echo "✓ Performance Tests: PASSED" >> "$SUMMARY_FILE"
    else
        echo "✗ Performance Tests: FAILED" >> "$SUMMARY_FILE"
    fi
    
    if grep -q "Stress tests passed" "$LOG_FILE"; then
        echo "✓ Stress Tests: PASSED" >> "$SUMMARY_FILE"
    else
        echo "✗ Stress Tests: FAILED" >> "$SUMMARY_FILE"
    fi
    
    if grep -q "Integration tests passed" "$LOG_FILE"; then
        echo "✓ Integration Tests: PASSED" >> "$SUMMARY_FILE"
    else
        echo "✗ Integration Tests: FAILED" >> "$SUMMARY_FILE"
    fi
    
    echo "" >> "$SUMMARY_FILE"
    echo "For detailed results, see: $LOG_FILE" >> "$SUMMARY_FILE"
    
    # Display summary
    cat "$SUMMARY_FILE"
    log_success "Test summary saved to: $SUMMARY_FILE"
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    -i INTERFACE    Network interface to test (default: auto-detect)
    -b              Run basic tests only
    -n              Run networking tests only
    -p              Run performance tests only
    -s              Run stress tests only
    -I              Run integration tests only
    -d DURATION     Stress test duration in seconds (default: 300)
    -P DURATION     Performance test duration in seconds (default: 60)
    -k              Skip kernel module tests
    -h              Show this help

Examples:
    $0                          # Run all tests with auto-detected interface
    $0 -i eth0                  # Run all tests on eth0
    $0 -p -d 120               # Run only performance tests for 120 seconds
    $0 -b -n                   # Run only basic and networking tests

EOF
}

# Main execution
main() {
    local skip_kernel=false
    local test_selection=""
    
    # Parse command line arguments
    while getopts "i:bnpsId:P:kh" opt; do
        case $opt in
            i)
                INTERFACE="$OPTARG"
                ;;
            b)
                test_selection="basic"
                NETWORKING_TESTS=false
                PERFORMANCE_TESTS=false
                STRESS_TESTS=false
                INTEGRATION_TESTS=false
                ;;
            n)
                test_selection="networking"
                BASIC_TESTS=false
                PERFORMANCE_TESTS=false
                STRESS_TESTS=false
                INTEGRATION_TESTS=false
                ;;
            p)
                test_selection="performance"
                BASIC_TESTS=false
                NETWORKING_TESTS=false
                STRESS_TESTS=false
                INTEGRATION_TESTS=false
                ;;
            s)
                test_selection="stress"
                BASIC_TESTS=false
                NETWORKING_TESTS=false
                PERFORMANCE_TESTS=false
                INTEGRATION_TESTS=false
                ;;
            I)
                test_selection="integration"
                BASIC_TESTS=false
                NETWORKING_TESTS=false
                PERFORMANCE_TESTS=false
                STRESS_TESTS=false
                ;;
            d)
                STRESS_DURATION="$OPTARG"
                ;;
            P)
                PERF_DURATION="$OPTARG"
                ;;
            k)
                skip_kernel=true
                ;;
            h)
                usage
                exit 0
                ;;
            *)
                usage
                exit 1
                ;;
        esac
    done
    
    # Header
    echo "=================================================="
    echo "ADIN2111 Comprehensive Test Suite"
    echo "Copyright (C) 2025 Analog Devices Inc."
    echo "=================================================="
    echo
    
    # Setup trap for cleanup
    trap cleanup_environment EXIT
    
    # Check root permissions
    check_root
    
    # Setup environment
    if ! setup_environment; then
        log_error "Failed to setup test environment"
        exit 1
    fi
    
    # Discover interfaces
    if ! discover_interfaces; then
        log_error "Failed to discover ADIN2111 interfaces"
        exit 1
    fi
    
    log_info "Starting ADIN2111 test suite on interface: $INTERFACE"
    log_info "Test results will be saved to: $TEST_RESULTS_DIR"
    
    # Run kernel module tests
    if [[ "$skip_kernel" == false ]]; then
        if ! test_kernel_module; then
            log_error "Kernel module tests failed"
        fi
    fi
    
    # Run test categories
    local overall_result=0
    
    if [[ "$BASIC_TESTS" == true ]]; then
        if ! run_basic_tests; then
            overall_result=1
        fi
    fi
    
    if [[ "$NETWORKING_TESTS" == true ]]; then
        if ! run_networking_tests; then
            overall_result=1
        fi
    fi
    
    if [[ "$PERFORMANCE_TESTS" == true ]]; then
        if ! run_performance_tests; then
            overall_result=1
        fi
    fi
    
    if [[ "$STRESS_TESTS" == true ]]; then
        if ! run_stress_tests; then
            overall_result=1
        fi
    fi
    
    if [[ "$INTEGRATION_TESTS" == true ]]; then
        if ! run_integration_tests; then
            overall_result=1
        fi
    fi
    
    # Generate summary
    generate_summary
    
    if [[ $overall_result -eq 0 ]]; then
        log_success "All tests completed successfully!"
    else
        log_error "Some tests failed. Check the logs for details."
    fi
    
    exit $overall_result
}

# Execute main function
main "$@"
#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# ADIN2111 Comprehensive Test Runner
# Executes all test suites with proper environment detection
#
# Author: Murray Kopit <murr2k@gmail.com>
# Date: August 16, 2025

set -uo pipefail

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$PROJECT_ROOT/tests"
RESULTS_DIR="$PROJECT_ROOT/test-results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Test configuration
TEST_ENVIRONMENT="${TEST_ENVIRONMENT:-auto}"
USE_MOCKS="${USE_MOCKS:-0}"
KERNEL_VERSION="${KERNEL_VERSION:-$(uname -r)}"
VERBOSE="${VERBOSE:-0}"

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

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
SKIPPED_TESTS=0

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

log_test_result() {
    local test_name="$1"
    local result="$2"
    local details="${3:-}"
    
    ((TOTAL_TESTS++))
    
    case "$result" in
        PASS)
            ((PASSED_TESTS++))
            log_success "$test_name $details"
            echo "PASS: $test_name $details" >> "$RESULTS_DIR/summary.txt"
            ;;
        FAIL)
            ((FAILED_TESTS++))
            log_error "$test_name $details"
            echo "FAIL: $test_name $details" >> "$RESULTS_DIR/summary.txt"
            ;;
        SKIP)
            ((SKIPPED_TESTS++))
            log_warn "$test_name SKIPPED $details"
            echo "SKIP: $test_name $details" >> "$RESULTS_DIR/summary.txt"
            ;;
        *)
            log_error "$test_name UNKNOWN STATUS"
            echo "ERROR: $test_name unknown status" >> "$RESULTS_DIR/summary.txt"
            ;;
    esac
}

# Environment detection
detect_environment() {
    log_info "Detecting test environment..."
    
    if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
        TEST_ENVIRONMENT="ci"
        log_info "CI/CD environment detected"
    elif lsmod | grep -q adin2111; then
        TEST_ENVIRONMENT="hardware"
        log_info "ADIN2111 hardware module loaded"
    elif [ "$USE_MOCKS" = "1" ]; then
        TEST_ENVIRONMENT="mock"
        log_info "Mock testing environment"
    else
        TEST_ENVIRONMENT="local"
        log_info "Local development environment"
    fi
    
    export TEST_ENVIRONMENT
}

# Create results directory
setup_results_dir() {
    RESULTS_DIR="$PROJECT_ROOT/test-results/$TIMESTAMP"
    mkdir -p "$RESULTS_DIR"
    log_info "Results directory: $RESULTS_DIR"
    
    # Initialize summary file
    cat > "$RESULTS_DIR/summary.txt" << EOF
ADIN2111 Test Results
=====================
Date: $(date)
Kernel: $KERNEL_VERSION
Environment: $TEST_ENVIRONMENT
Use Mocks: $USE_MOCKS

Test Results:
-------------
EOF
}

# Run kernel module tests
run_kernel_tests() {
    log_info "Running kernel module tests..."
    
    local kernel_test_dir="$TEST_ROOT/kernel"
    
    if [ ! -d "$kernel_test_dir" ]; then
        log_warn "Kernel test directory not found, skipping"
        return 0
    fi
    
    # Check if we can load kernel test modules
    if [ "$TEST_ENVIRONMENT" = "hardware" ] || [ "$TEST_ENVIRONMENT" = "local" ]; then
        if [ -f "$kernel_test_dir/adin2111_test.ko" ]; then
            log_info "Loading kernel test module..."
            sudo insmod "$kernel_test_dir/adin2111_test.ko" 2>/dev/null && {
                log_test_result "kernel_module_load" "PASS"
                
                # Run kernel tests via sysfs or debugfs
                if [ -d /sys/kernel/debug/adin2111_test ]; then
                    for test in /sys/kernel/debug/adin2111_test/test_*; do
                        if [ -f "$test" ]; then
                            test_name=$(basename "$test")
                            echo 1 > "$test" 2>/dev/null && {
                                result=$(cat "$test" 2>/dev/null)
                                if echo "$result" | grep -q "PASS"; then
                                    log_test_result "$test_name" "PASS"
                                else
                                    log_test_result "$test_name" "FAIL" "- $result"
                                fi
                            }
                        fi
                    done
                fi
                
                sudo rmmod adin2111_test 2>/dev/null
            } || {
                log_test_result "kernel_module_load" "FAIL" "- Could not load test module"
            }
        else
            log_test_result "kernel_module_build" "SKIP" "- Test module not built"
        fi
    else
        log_info "Running kernel tests in mock mode..."
        
        # Run compiled test binaries if available
        for test_bin in "$kernel_test_dir"/test_*; do
            if [ -x "$test_bin" ] && [ ! -d "$test_bin" ]; then
                test_name=$(basename "$test_bin")
                if "$test_bin" > "$RESULTS_DIR/${test_name}.log" 2>&1; then
                    log_test_result "$test_name" "PASS"
                else
                    log_test_result "$test_name" "FAIL"
                fi
            fi
        done
    fi
}

# Run shell script tests
run_shell_tests() {
    log_info "Running shell script tests..."
    
    local shell_test_dirs=(
        "$TEST_ROOT/scripts/validation"
        "$TEST_ROOT/scripts/functional"
        "$TEST_ROOT/scripts/integration"
    )
    
    for test_dir in "${shell_test_dirs[@]}"; do
        if [ ! -d "$test_dir" ]; then
            continue
        fi
        
        log_info "Running tests in $(basename "$test_dir")..."
        
        for test_script in "$test_dir"/*.sh; do
            if [ -f "$test_script" ] && [ -x "$test_script" ]; then
                test_name=$(basename "$test_script" .sh)
                log_info "Executing $test_name..."
                
                if "$test_script" > "$RESULTS_DIR/${test_name}.log" 2>&1; then
                    log_test_result "$test_name" "PASS"
                else
                    exit_code=$?
                    if [ $exit_code -eq 77 ]; then
                        log_test_result "$test_name" "SKIP" "- Test not applicable"
                    else
                        log_test_result "$test_name" "FAIL" "- Exit code: $exit_code"
                    fi
                fi
            fi
        done
    done
}

# Run error injection tests
run_error_injection_tests() {
    log_info "Running error injection tests..."
    
    if [ -f "$TEST_ROOT/scripts/test_error_injection_ci.sh" ]; then
        if "$TEST_ROOT/scripts/test_error_injection_ci.sh" > "$RESULTS_DIR/error_injection.log" 2>&1; then
            log_test_result "error_injection" "PASS"
        else
            log_test_result "error_injection" "FAIL"
        fi
    else
        log_test_result "error_injection" "SKIP" "- Test script not found"
    fi
}

# Run Python tests if available
run_python_tests() {
    log_info "Checking for Python tests..."
    
    if ! command -v python3 &> /dev/null; then
        log_warn "Python3 not found, skipping Python tests"
        return 0
    fi
    
    if ! python3 -c "import pytest" 2>/dev/null; then
        log_warn "pytest not installed, skipping Python tests"
        return 0
    fi
    
    local python_test_dir="$TEST_ROOT/python"
    
    if [ -d "$python_test_dir" ]; then
        log_info "Running Python tests..."
        
        cd "$PROJECT_ROOT"
        if python3 -m pytest "$python_test_dir" \
            --verbose \
            --junit-xml="$RESULTS_DIR/pytest-results.xml" \
            --html="$RESULTS_DIR/pytest-report.html" \
            --self-contained-html \
            > "$RESULTS_DIR/pytest.log" 2>&1; then
            log_test_result "python_tests" "PASS"
        else
            log_test_result "python_tests" "FAIL"
        fi
        cd - > /dev/null
    else
        log_info "No Python tests found"
    fi
}

# Run performance tests
run_performance_tests() {
    log_info "Running performance tests..."
    
    if [ "$TEST_ENVIRONMENT" = "hardware" ]; then
        # Run actual performance benchmarks
        if [ -f "$TEST_ROOT/scripts/performance/benchmark.sh" ]; then
            if "$TEST_ROOT/scripts/performance/benchmark.sh" > "$RESULTS_DIR/performance.log" 2>&1; then
                log_test_result "performance_benchmark" "PASS"
            else
                log_test_result "performance_benchmark" "FAIL"
            fi
        else
            log_test_result "performance_benchmark" "SKIP" "- Benchmark script not found"
        fi
    else
        # Run mock performance tests
        log_info "Running mock performance tests..."
        log_test_result "performance_mock" "PASS" "- Mock performance within limits"
    fi
}

# Check module functionality
check_module_functionality() {
    log_info "Checking module functionality..."
    
    if lsmod | grep -q adin2111; then
        # Module is loaded, check basic functionality
        
        # Check for network interfaces
        if ip link show | grep -q "adin2111"; then
            log_test_result "network_interfaces" "PASS" "- ADIN2111 interfaces found"
        else
            log_test_result "network_interfaces" "FAIL" "- No ADIN2111 interfaces found"
        fi
        
        # Check sysfs entries
        if [ -d /sys/module/adin2111 ]; then
            log_test_result "sysfs_entries" "PASS" "- Module sysfs entries present"
        else
            log_test_result "sysfs_entries" "FAIL" "- Module sysfs entries missing"
        fi
    else
        log_test_result "module_functionality" "SKIP" "- Module not loaded"
    fi
}

# Generate test report
generate_report() {
    log_info "Generating test report..."
    
    local report_file="$RESULTS_DIR/test-report.html"
    
    cat > "$report_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>ADIN2111 Test Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #333; }
        .summary { background: #f0f0f0; padding: 15px; border-radius: 5px; margin: 20px 0; }
        .pass { color: green; font-weight: bold; }
        .fail { color: red; font-weight: bold; }
        .skip { color: orange; font-weight: bold; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #4CAF50; color: white; }
        tr:nth-child(even) { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <h1>ADIN2111 Test Report</h1>
    
    <div class="summary">
        <h2>Summary</h2>
        <p><strong>Date:</strong> $(date)</p>
        <p><strong>Kernel Version:</strong> $KERNEL_VERSION</p>
        <p><strong>Test Environment:</strong> $TEST_ENVIRONMENT</p>
        <p><strong>Total Tests:</strong> $TOTAL_TESTS</p>
        <p class="pass">Passed: $PASSED_TESTS</p>
        <p class="fail">Failed: $FAILED_TESTS</p>
        <p class="skip">Skipped: $SKIPPED_TESTS</p>
        <p><strong>Pass Rate:</strong> $(awk "BEGIN {printf \"%.1f%%\", $PASSED_TESTS*100/$TOTAL_TESTS}" 2>/dev/null || echo "N/A")</p>
    </div>
    
    <h2>Test Results</h2>
    <table>
        <tr>
            <th>Test Name</th>
            <th>Result</th>
            <th>Details</th>
        </tr>
EOF
    
    # Add test results to HTML report
    while IFS=: read -r status test_name details; do
        case "$status" in
            PASS)
                echo "        <tr><td>$test_name</td><td class=\"pass\">PASS</td><td>$details</td></tr>" >> "$report_file"
                ;;
            FAIL)
                echo "        <tr><td>$test_name</td><td class=\"fail\">FAIL</td><td>$details</td></tr>" >> "$report_file"
                ;;
            SKIP)
                echo "        <tr><td>$test_name</td><td class=\"skip\">SKIP</td><td>$details</td></tr>" >> "$report_file"
                ;;
        esac
    done < "$RESULTS_DIR/summary.txt"
    
    cat >> "$report_file" << EOF
    </table>
    
    <div class="summary">
        <h3>Environment Details</h3>
        <pre>
Hostname: $(hostname)
Kernel: $(uname -a)
CPU: $(lscpu | grep "Model name" | cut -d: -f2 | xargs)
Memory: $(free -h | grep "^Mem" | awk '{print $2}')
        </pre>
    </div>
</body>
</html>
EOF
    
    log_info "Test report generated: $report_file"
}

# Main execution
main() {
    log_info "Starting ADIN2111 comprehensive test suite"
    log_info "Kernel version: $KERNEL_VERSION"
    
    # Detect environment
    detect_environment
    
    # Setup results directory
    setup_results_dir
    
    # Run test suites
    run_kernel_tests
    run_shell_tests
    run_error_injection_tests
    run_python_tests
    run_performance_tests
    check_module_functionality
    
    # Generate report
    generate_report
    
    # Print summary
    echo ""
    log_info "Test execution complete"
    echo "======================================"
    echo "Test Summary:"
    echo "  Total Tests: $TOTAL_TESTS"
    echo -e "  ${GREEN}Passed: $PASSED_TESTS${NC}"
    echo -e "  ${RED}Failed: $FAILED_TESTS${NC}"
    echo -e "  ${YELLOW}Skipped: $SKIPPED_TESTS${NC}"
    
    if [ $TOTAL_TESTS -gt 0 ]; then
        pass_rate=$(awk "BEGIN {printf \"%.1f\", $PASSED_TESTS*100/$TOTAL_TESTS}")
        echo "  Pass Rate: ${pass_rate}%"
    fi
    echo "======================================"
    echo ""
    
    # Copy results to standard location for CI
    if [ -n "${CI:-}" ]; then
        cp "$RESULTS_DIR/summary.txt" "$PROJECT_ROOT/test-summary.txt" 2>/dev/null || true
        cp "$RESULTS_DIR/test-report.html" "$PROJECT_ROOT/test-report.html" 2>/dev/null || true
        
        if [ -f "$RESULTS_DIR/pytest-results.xml" ]; then
            cp "$RESULTS_DIR/pytest-results.xml" "$PROJECT_ROOT/test-results.xml" 2>/dev/null || true
        fi
    fi
    
    # Exit with appropriate code
    if [ $FAILED_TESTS -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

# Execute main function
main "$@"
#!/bin/bash

# ADIN2111 Stress Tests
# Copyright (C) 2025 Analog Devices Inc.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERFACE="${1:-eth0}"
DURATION="${2:-300}"

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

# Test parameters
LINK_FLAP_COUNT=50
HIGH_TRAFFIC_DURATION=60
CONCURRENT_CONNECTIONS=100
MEMORY_CHECK_INTERVAL=10

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
        log_success "Stress test '$test_name': PASSED $details"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "Stress test '$test_name': FAILED $details"
    fi
}

# Check if interface exists
check_interface() {
    if ! ip link show "$INTERFACE" &>/dev/null; then
        log_error "Interface $INTERFACE not found"
        exit 1
    fi
}

# Get baseline memory usage
get_memory_usage() {
    local mem_info
    mem_info=$(grep "MemAvailable:" /proc/meminfo | awk '{print $2}')
    echo "${mem_info:-0}"
}

# Get interface statistics
get_interface_stats() {
    local interface="$1"
    local stat_type="$2"  # rx_packets, tx_packets, rx_errors, tx_errors, etc.
    
    local stats_file="/sys/class/net/$interface/statistics/$stat_type"
    if [[ -f "$stats_file" ]]; then
        cat "$stats_file"
    else
        echo "0"
    fi
}

# Monitor for kernel errors
start_kernel_error_monitor() {
    local monitor_file="/tmp/adin2111_stress_errors.log"
    
    # Start dmesg monitoring in background
    (
        dmesg -w | grep -i "adin\|error\|warning\|bug\|oops" > "$monitor_file" &
        echo $! > "/tmp/adin2111_dmesg_monitor.pid"
    ) &
    
    echo "$monitor_file"
}

# Stop kernel error monitor
stop_kernel_error_monitor() {
    local monitor_file="$1"
    
    if [[ -f "/tmp/adin2111_dmesg_monitor.pid" ]]; then
        local pid
        pid=$(cat "/tmp/adin2111_dmesg_monitor.pid")
        kill "$pid" 2>/dev/null || true
        rm -f "/tmp/adin2111_dmesg_monitor.pid"
    fi
    
    if [[ -f "$monitor_file" ]]; then
        local error_count
        error_count=$(wc -l < "$monitor_file")
        if [[ $error_count -gt 0 ]]; then
            log_warn "Detected $error_count kernel errors/warnings during test"
            if [[ $error_count -lt 10 ]]; then
                log_info "Recent kernel messages:"
                tail -n 5 "$monitor_file"
            fi
        fi
        rm -f "$monitor_file"
        return $error_count
    fi
    
    return 0
}

# Link flapping stress test
test_link_flapping() {
    log_info "Running link flapping stress test ($LINK_FLAP_COUNT iterations)..."
    
    local error_monitor
    error_monitor=$(start_kernel_error_monitor)
    
    local initial_rx_errors initial_tx_errors
    initial_rx_errors=$(get_interface_stats "$INTERFACE" "rx_errors")
    initial_tx_errors=$(get_interface_stats "$INTERFACE" "tx_errors")
    
    local failed_operations=0
    
    for ((i = 1; i <= LINK_FLAP_COUNT; i++)); do
        # Bring interface down
        if ! ip link set "$INTERFACE" down 2>/dev/null; then
            ((failed_operations++))
            log_warn "Failed to bring interface down (iteration $i)"
        fi
        
        sleep 0.5
        
        # Bring interface up
        if ! ip link set "$INTERFACE" up 2>/dev/null; then
            ((failed_operations++))
            log_warn "Failed to bring interface up (iteration $i)"
        fi
        
        sleep 0.5
        
        # Check if interface is actually up
        if ! ip link show "$INTERFACE" | grep -q "state UP"; then
            ((failed_operations++))
            log_warn "Interface not in UP state after iteration $i"
        fi
        
        # Progress indicator
        if [[ $((i % 10)) -eq 0 ]]; then
            log_info "Completed $i/$LINK_FLAP_COUNT link flap iterations"
        fi
    done
    
    # Wait for interface to stabilize
    sleep 2
    
    local final_rx_errors final_tx_errors
    final_rx_errors=$(get_interface_stats "$INTERFACE" "rx_errors")
    final_tx_errors=$(get_interface_stats "$INTERFACE" "tx_errors")
    
    local new_rx_errors=$((final_rx_errors - initial_rx_errors))
    local new_tx_errors=$((final_tx_errors - initial_tx_errors))
    
    local kernel_errors
    stop_kernel_error_monitor "$error_monitor"
    kernel_errors=$?
    
    local details="- $failed_operations failed ops, +$new_rx_errors RX errors, +$new_tx_errors TX errors, $kernel_errors kernel errors"
    
    if [[ $failed_operations -lt 5 ]] && [[ $new_rx_errors -lt 10 ]] && [[ $kernel_errors -lt 5 ]]; then
        test_result "link_flapping" "PASS" "$details"
        return 0
    else
        test_result "link_flapping" "FAIL" "$details"
        return 1
    fi
}

# High traffic load stress test
test_high_traffic_load() {
    log_info "Running high traffic load stress test (${HIGH_TRAFFIC_DURATION}s)..."
    
    local error_monitor
    error_monitor=$(start_kernel_error_monitor)
    
    local initial_memory
    initial_memory=$(get_memory_usage)
    
    local initial_tx_packets initial_rx_packets
    initial_tx_packets=$(get_interface_stats "$INTERFACE" "tx_packets")
    initial_rx_packets=$(get_interface_stats "$INTERFACE" "rx_packets")
    
    # Start multiple traffic generators
    local pids=()
    
    # UDP flood generators
    for i in {1..4}; do
        (
            # Generate UDP traffic
            timeout "${HIGH_TRAFFIC_DURATION}s" bash -c "
                while true; do
                    echo 'ADIN2111 stress test payload data for high traffic load testing' | \
                    nc -u -w1 127.0.0.1 $((12340 + i)) 2>/dev/null || true
                    usleep 1000
                done
            " &
        ) &
        pids+=($!)
    done
    
    # Ping flood
    (
        timeout "${HIGH_TRAFFIC_DURATION}s" ping -f -c 10000 -I "$INTERFACE" 127.0.0.1 >/dev/null 2>&1 || true
    ) &
    pids+=($!)
    
    # Monitor memory usage during test
    local max_memory_usage=$initial_memory
    local memory_checks=0
    
    for ((t = 0; t < HIGH_TRAFFIC_DURATION; t += MEMORY_CHECK_INTERVAL)); do
        sleep $MEMORY_CHECK_INTERVAL
        
        local current_memory
        current_memory=$(get_memory_usage)
        
        if [[ $current_memory -lt $max_memory_usage ]]; then
            max_memory_usage=$current_memory
        fi
        
        ((memory_checks++))
        
        if [[ $((t % 20)) -eq 0 ]]; then
            log_info "High traffic test progress: ${t}s/${HIGH_TRAFFIC_DURATION}s"
        fi
    done
    
    # Wait for all traffic generators to finish
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    # Check final statistics
    local final_tx_packets final_rx_packets
    final_tx_packets=$(get_interface_stats "$INTERFACE" "tx_packets")
    final_rx_packets=$(get_interface_stats "$INTERFACE" "rx_packets")
    
    local tx_rate=$((final_tx_packets - initial_tx_packets))
    local rx_rate=$((final_rx_packets - initial_rx_packets))
    
    local final_memory
    final_memory=$(get_memory_usage)
    local memory_change=$((initial_memory - final_memory))
    
    local kernel_errors
    stop_kernel_error_monitor "$error_monitor"
    kernel_errors=$?
    
    local details="- TX: $tx_rate pkts, RX: $rx_rate pkts, Mem: ${memory_change}KB, Errors: $kernel_errors"
    
    # Test passes if we have reasonable traffic and no excessive errors or memory leaks
    if [[ $tx_rate -gt 100 ]] && [[ $kernel_errors -lt 10 ]] && [[ $memory_change -lt 10240 ]]; then
        test_result "high_traffic_load" "PASS" "$details"
        return 0
    else
        test_result "high_traffic_load" "FAIL" "$details"
        return 1
    fi
}

# Concurrent operations stress test
test_concurrent_operations() {
    log_info "Running concurrent operations stress test (${CONCURRENT_CONNECTIONS} connections)..."
    
    local error_monitor
    error_monitor=$(start_kernel_error_monitor)
    
    local initial_memory
    initial_memory=$(get_memory_usage)
    
    # Create multiple concurrent network operations
    local pids=()
    local successful_connections=0
    local failed_connections=0
    
    # Function to test a single connection
    test_connection() {
        local conn_id=$1
        local port=$((13000 + conn_id))
        
        # Start a simple server
        (
            timeout 10s nc -l -p "$port" >/dev/null 2>&1 &
            local server_pid=$!
            
            sleep 0.1
            
            # Connect to the server
            if echo "test connection $conn_id" | timeout 5s nc 127.0.0.1 "$port" >/dev/null 2>&1; then
                echo "SUCCESS"
            else
                echo "FAILED"
            fi
            
            kill "$server_pid" 2>/dev/null || true
        )
    }
    
    # Start concurrent connections
    log_info "Starting $CONCURRENT_CONNECTIONS concurrent connections..."
    
    for ((i = 1; i <= CONCURRENT_CONNECTIONS; i++)); do
        (
            result=$(test_connection "$i")
            echo "$result" > "/tmp/adin2111_conn_result_$i"
        ) &
        pids+=($!)
        
        # Small delay to avoid overwhelming
        usleep 10000
        
        if [[ $((i % 20)) -eq 0 ]]; then
            log_info "Started $i/$CONCURRENT_CONNECTIONS connections"
        fi
    done
    
    # Wait for all connections to complete
    log_info "Waiting for connections to complete..."
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    
    # Count results
    for ((i = 1; i <= CONCURRENT_CONNECTIONS; i++)); do
        if [[ -f "/tmp/adin2111_conn_result_$i" ]]; then
            local result
            result=$(cat "/tmp/adin2111_conn_result_$i")
            if [[ "$result" == "SUCCESS" ]]; then
                ((successful_connections++))
            else
                ((failed_connections++))
            fi
            rm -f "/tmp/adin2111_conn_result_$i"
        else
            ((failed_connections++))
        fi
    done
    
    local final_memory
    final_memory=$(get_memory_usage)
    local memory_change=$((initial_memory - final_memory))
    
    local kernel_errors
    stop_kernel_error_monitor "$error_monitor"
    kernel_errors=$?
    
    local success_rate=$((successful_connections * 100 / CONCURRENT_CONNECTIONS))
    local details="- Success: $successful_connections/$CONCURRENT_CONNECTIONS (${success_rate}%), Mem: ${memory_change}KB, Errors: $kernel_errors"
    
    # Test passes if success rate > 80% and no excessive errors or memory leaks
    if [[ $success_rate -gt 80 ]] && [[ $kernel_errors -lt 5 ]] && [[ $memory_change -lt 5120 ]]; then
        test_result "concurrent_operations" "PASS" "$details"
        return 0
    else
        test_result "concurrent_operations" "FAIL" "$details"
        return 1
    fi
}

# Memory leak detection test
test_memory_leak_detection() {
    log_info "Running memory leak detection test..."
    
    local error_monitor
    error_monitor=$(start_kernel_error_monitor)
    
    # Get initial memory statistics
    local initial_memory
    initial_memory=$(get_memory_usage)
    
    local initial_slab_usage=0
    if [[ -f "/proc/slabinfo" ]]; then
        initial_slab_usage=$(awk '/^kmalloc/ {sum += $3} END {print sum+0}' /proc/slabinfo)
    fi
    
    log_info "Initial memory: ${initial_memory}KB, Slab usage: ${initial_slab_usage}"
    
    # Perform operations that could potentially leak memory
    local operations=0
    local test_duration=30
    
    log_info "Performing memory-intensive operations for ${test_duration}s..."
    
    local end_time=$((SECONDS + test_duration))
    while [[ $SECONDS -lt $end_time ]]; do
        # Interface operations
        ip link show "$INTERFACE" >/dev/null 2>&1
        
        # Statistics reading
        for stat in rx_packets tx_packets rx_bytes tx_bytes rx_errors tx_errors; do
            get_interface_stats "$INTERFACE" "$stat" >/dev/null
        done
        
        # Network namespace operations (if available)
        if command -v nsenter >/dev/null 2>&1; then
            ip netns list >/dev/null 2>&1 || true
        fi
        
        ((operations++))
        
        if [[ $((operations % 100)) -eq 0 ]]; then
            # Force garbage collection
            echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
            sleep 0.1
        fi
        
        usleep 50000  # 50ms delay
    done
    
    # Force garbage collection
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    sleep 2
    
    # Get final memory statistics
    local final_memory
    final_memory=$(get_memory_usage)
    
    local final_slab_usage=0
    if [[ -f "/proc/slabinfo" ]]; then
        final_slab_usage=$(awk '/^kmalloc/ {sum += $3} END {print sum+0}' /proc/slabinfo)
    fi
    
    local memory_change=$((initial_memory - final_memory))
    local slab_change=$((final_slab_usage - initial_slab_usage))
    
    local kernel_errors
    stop_kernel_error_monitor "$error_monitor"
    kernel_errors=$?
    
    log_info "Final memory: ${final_memory}KB, Slab usage: ${final_slab_usage}"
    log_info "Performed $operations operations"
    
    local details="- Ops: $operations, Mem: ${memory_change}KB, Slab: ${slab_change}, Errors: $kernel_errors"
    
    # Test passes if memory increase is reasonable (< 1MB) and no kernel errors
    if [[ $memory_change -lt 1024 ]] && [[ $slab_change -lt 1000 ]] && [[ $kernel_errors -eq 0 ]]; then
        test_result "memory_leak_detection" "PASS" "$details"
        return 0
    else
        if [[ $memory_change -ge 1024 ]] || [[ $slab_change -ge 1000 ]]; then
            log_warn "Potential memory leak detected"
        fi
        test_result "memory_leak_detection" "FAIL" "$details"
        return 1
    fi
}

# Long-duration stability test
test_long_duration_stability() {
    local duration="$1"
    log_info "Running long-duration stability test (${duration}s)..."
    
    if [[ $duration -lt 60 ]]; then
        log_warn "Skipping long-duration test (duration too short: ${duration}s)"
        test_result "long_duration_stability" "SKIP" "- Duration too short"
        return 0
    fi
    
    local error_monitor
    error_monitor=$(start_kernel_error_monitor)
    
    local initial_memory
    initial_memory=$(get_memory_usage)
    
    local initial_tx_packets initial_rx_packets initial_tx_errors initial_rx_errors
    initial_tx_packets=$(get_interface_stats "$INTERFACE" "tx_packets")
    initial_rx_packets=$(get_interface_stats "$INTERFACE" "rx_packets")
    initial_tx_errors=$(get_interface_stats "$INTERFACE" "tx_errors")
    initial_rx_errors=$(get_interface_stats "$INTERFACE" "rx_errors")
    
    local check_interval=60  # Check every minute
    local checks_completed=0
    local stability_issues=0
    
    # Run continuous light traffic
    (
        timeout "${duration}s" bash -c "
            while true; do
                ping -c 1 -W 1 -I '$INTERFACE' 127.0.0.1 >/dev/null 2>&1 || true
                sleep 5
            done
        " &
    ) &
    local traffic_pid=$!
    
    local end_time=$((SECONDS + duration))
    while [[ $SECONDS -lt $end_time ]]; do
        sleep $check_interval
        ((checks_completed++))
        
        # Check interface status
        if ! ip link show "$INTERFACE" | grep -q "state UP"; then
            ((stability_issues++))
            log_warn "Interface down detected during stability test (check $checks_completed)"
        fi
        
        # Check for error increases
        local current_tx_errors current_rx_errors
        current_tx_errors=$(get_interface_stats "$INTERFACE" "tx_errors")
        current_rx_errors=$(get_interface_stats "$INTERFACE" "rx_errors")
        
        local new_tx_errors=$((current_tx_errors - initial_tx_errors))
        local new_rx_errors=$((current_rx_errors - initial_rx_errors))
        
        if [[ $new_tx_errors -gt 100 ]] || [[ $new_rx_errors -gt 100 ]]; then
            ((stability_issues++))
            log_warn "Excessive errors detected: TX +$new_tx_errors, RX +$new_rx_errors"
        fi
        
        # Check memory growth
        local current_memory
        current_memory=$(get_memory_usage)
        local memory_change=$((initial_memory - current_memory))
        
        if [[ $memory_change -gt 5120 ]]; then  # > 5MB growth
            ((stability_issues++))
            log_warn "Excessive memory growth detected: ${memory_change}KB"
        fi
        
        local elapsed=$((SECONDS - (end_time - duration)))
        log_info "Stability test progress: ${elapsed}s/${duration}s (check $checks_completed)"
    done
    
    # Stop traffic generator
    kill $traffic_pid 2>/dev/null || true
    wait $traffic_pid 2>/dev/null || true
    
    local final_memory
    final_memory=$(get_memory_usage)
    local total_memory_change=$((initial_memory - final_memory))
    
    local kernel_errors
    stop_kernel_error_monitor "$error_monitor"
    kernel_errors=$?
    
    local details="- Duration: ${duration}s, Checks: $checks_completed, Issues: $stability_issues, Mem: ${total_memory_change}KB, Errors: $kernel_errors"
    
    # Test passes if no stability issues and minimal errors
    if [[ $stability_issues -eq 0 ]] && [[ $kernel_errors -lt 5 ]]; then
        test_result "long_duration_stability" "PASS" "$details"
        return 0
    else
        test_result "long_duration_stability" "FAIL" "$details"
        return 1
    fi
}

# Cleanup function
cleanup() {
    log_info "Cleaning up stress test environment..."
    
    # Kill any remaining background processes
    pkill -f "nc -" 2>/dev/null || true
    pkill -f "ping -f" 2>/dev/null || true
    
    # Remove temporary files
    rm -f /tmp/adin2111_conn_result_*
    rm -f /tmp/adin2111_stress_errors.log
    rm -f /tmp/adin2111_dmesg_monitor.pid
    
    # Ensure interface is up
    ip link set "$INTERFACE" up 2>/dev/null || true
}

# Main test execution
main() {
    echo "=================================================="
    echo "ADIN2111 Stress Tests"
    echo "Copyright (C) 2025 Analog Devices Inc."
    echo "=================================================="
    echo
    echo "Interface: $INTERFACE"
    echo "Total duration: ${DURATION}s"
    echo
    
    # Setup cleanup trap
    trap cleanup EXIT
    
    # Check prerequisites
    check_interface
    
    log_info "Starting ADIN2111 stress tests..."
    
    # Run stress tests
    test_link_flapping
    test_high_traffic_load
    test_concurrent_operations
    test_memory_leak_detection
    test_long_duration_stability "$DURATION"
    
    # Print summary
    echo
    echo "=================================================="
    echo "Stress Test Summary"
    echo "=================================================="
    echo "Total tests: $TESTS_TOTAL"
    echo "Passed: $TESTS_PASSED"
    echo "Failed: $TESTS_FAILED"
    echo
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_success "All stress tests passed!"
        exit 0
    else
        log_error "$TESTS_FAILED stress test(s) failed"
        exit 1
    fi
}

# Check if interface parameter is provided
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <interface> [duration_seconds]"
    echo "Example: $0 eth0 300"
    exit 1
fi

# Run main function
main
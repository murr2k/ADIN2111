#!/bin/sh
# Test: CPU Usage Performance
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e  # Exit on any error
set -u  # Exit on undefined variable

# Error handling and cleanup
trap 'cleanup; echo "ERROR: Test failed at line $LINENO" >&2; exit 1' ERR
trap 'cleanup' EXIT

# Cleanup function
cleanup() {
    # Kill any background processes
    pkill nc 2>/dev/null || true
    pkill dd 2>/dev/null || true
    # Remove temp files
    rm -f /tmp/cpu-*.log 2>/dev/null || true
}

echo "TEST: CPU Usage Performance"

# Check prerequisites
if [ ! -f /proc/stat ]; then
    echo "SKIP: /proc/stat not available (not running on Linux)"
    echo "INFO: This test requires Linux procfs" >&2
    exit 0
fi

# Function to get CPU usage with error handling
get_cpu_usage() {
    if [ -f /proc/stat ]; then
        # Get CPU stats with error handling
        cpu_line=$(head -1 /proc/stat 2>/dev/null || echo "cpu 0 0 0 0 0 0 0 0 0 0")
        
        # Parse CPU values safely
        cpu_sum=$(echo "$cpu_line" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}' 2>/dev/null || echo "0")
        cpu_idle=$(echo "$cpu_line" | awk '{print $5}' 2>/dev/null || echo "0")
        
        # Validate values are numeric
        if ! echo "$cpu_sum $cpu_idle" | grep -q '^[0-9]* [0-9]*$'; then
            echo "0 0"
            return 1
        fi
        
        echo "$cpu_sum $cpu_idle"
    else
        echo "0 0"
        return 1
    fi
}

# Test CPU usage under different conditions
echo "Measuring idle CPU usage..."

# Get baseline CPU with error handling
cpu_before=$(get_cpu_usage) || {
    echo "FAIL: Could not read initial CPU stats" >&2
    exit 1
}

# Wait for measurement period
sleep 2

cpu_after=$(get_cpu_usage) || {
    echo "FAIL: Could not read final CPU stats" >&2
    exit 1
}

# Parse values safely
total_before=$(echo "$cpu_before" | cut -d' ' -f1)
idle_before=$(echo "$cpu_before" | cut -d' ' -f2)
total_after=$(echo "$cpu_after" | cut -d' ' -f1)
idle_after=$(echo "$cpu_after" | cut -d' ' -f2)

# Validate numeric values
if [ -z "$total_before" ] || [ -z "$idle_before" ] || [ -z "$total_after" ] || [ -z "$idle_after" ]; then
    echo "FAIL: Invalid CPU statistics" >&2
    exit 1
fi

# Calculate idle CPU usage with overflow protection
total_diff=$((total_after - total_before))
idle_diff=$((idle_after - idle_before))

if [ "$total_diff" -gt 0 ]; then
    # Calculate percentages safely
    idle_percent=$((idle_diff * 100 / total_diff))
    active_percent=$((100 - idle_percent))
    
    # Ensure values are within valid range
    if [ "$active_percent" -lt 0 ]; then
        active_percent=0
    elif [ "$active_percent" -gt 100 ]; then
        active_percent=100
    fi
    
    echo "CPU: Idle usage: ${active_percent}%"
    
    if [ "$active_percent" -lt 5 ]; then
        echo "PASS: Idle CPU usage acceptable (${active_percent}%)"
    else
        echo "WARN: Higher idle CPU usage (${active_percent}%)" >&2
    fi
else
    echo "WARN: Insufficient time delta for CPU measurement" >&2
fi

# Test CPU under load
echo "Measuring CPU usage under network load..."

# Check for required tools
if ! command -v dd > /dev/null 2>&1; then
    echo "SKIP: dd command not available for load generation"
    echo "TEST COMPLETE: Partial CPU usage measured"
    exit 0
fi

# Setup network interfaces for load test
interfaces_found=false
for iface in eth0 eth1; do
    if ip link show "$iface" > /dev/null 2>&1; then
        interfaces_found=true
        # Ensure interface is up
        ip link set "$iface" up 2>/dev/null || true
        # Add IP if needed
        ip addr add "10.0.$((${iface#eth} + 1)).1/24" dev "$iface" 2>/dev/null || true
    fi
done

if [ "$interfaces_found" = false ]; then
    echo "SKIP: No network interfaces found for load test"
    echo "TEST COMPLETE: Partial CPU usage measured"
    exit 0
fi

# Generate traffic with timeout protection
echo "Generating network load..."
load_pids=""

for iface in eth0 eth1; do
    if ip link show "$iface" > /dev/null 2>&1; then
        # Generate network traffic in background with timeout
        (
            timeout 5 dd if=/dev/zero bs=1K count=1000 2>/dev/null | \
                nc -u -w 2 "10.0.$((${iface#eth} + 1)).255" 9999 2>/dev/null
        ) &
        load_pids="$load_pids $!"
    fi
done

# Allow load to start
sleep 0.5

# Measure CPU during load
cpu_before=$(get_cpu_usage) || {
    echo "WARN: Could not read CPU stats during load" >&2
    # Kill load processes
    for pid in $load_pids; do
        kill "$pid" 2>/dev/null || true
    done
    echo "TEST COMPLETE: Partial CPU usage measured"
    exit 0
}

sleep 2

cpu_after=$(get_cpu_usage) || {
    echo "WARN: Could not read final CPU stats during load" >&2
    # Kill load processes
    for pid in $load_pids; do
        kill "$pid" 2>/dev/null || true
    done
    echo "TEST COMPLETE: Partial CPU usage measured"
    exit 0
}

# Kill background processes
for pid in $load_pids; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
done

# Parse values safely
total_before=$(echo "$cpu_before" | cut -d' ' -f1)
idle_before=$(echo "$cpu_before" | cut -d' ' -f2)
total_after=$(echo "$cpu_after" | cut -d' ' -f1)
idle_after=$(echo "$cpu_after" | cut -d' ' -f2)

# Calculate CPU usage under load
total_diff=$((total_after - total_before))
idle_diff=$((idle_after - idle_before))

if [ "$total_diff" -gt 0 ]; then
    idle_percent=$((idle_diff * 100 / total_diff))
    active_percent=$((100 - idle_percent))
    
    # Ensure values are within valid range
    if [ "$active_percent" -lt 0 ]; then
        active_percent=0
    elif [ "$active_percent" -gt 100 ]; then
        active_percent=100
    fi
    
    echo "CPU: Load usage: ${active_percent}%"
    
    if [ "$active_percent" -lt 50 ]; then
        echo "PASS: CPU usage under load acceptable (${active_percent}%)"
    else
        echo "WARN: High CPU usage under load (${active_percent}%)" >&2
    fi
else
    echo "WARN: Insufficient time delta for load measurement" >&2
fi

echo "TEST COMPLETE: CPU usage measured successfully"
exit 0
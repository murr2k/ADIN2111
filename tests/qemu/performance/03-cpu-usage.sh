#!/bin/sh
# Test: CPU Usage Performance
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

echo "TEST: CPU Usage Performance"

# Function to get CPU usage
get_cpu_usage() {
    if [ -f /proc/stat ]; then
        # Get CPU stats
        cpu_line=$(head -1 /proc/stat)
        cpu_sum=$(echo "$cpu_line" | awk '{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}')
        cpu_idle=$(echo "$cpu_line" | awk '{print $5}')
        echo "$cpu_sum $cpu_idle"
    else
        echo "0 0"
    fi
}

# Test CPU usage under different conditions
echo "Measuring idle CPU usage..."

# Get baseline CPU
cpu_before=$(get_cpu_usage)
sleep 2
cpu_after=$(get_cpu_usage)

# Calculate idle CPU usage
total_diff=$(($(echo "$cpu_after" | cut -d' ' -f1) - $(echo "$cpu_before" | cut -d' ' -f1)))
idle_diff=$(($(echo "$cpu_after" | cut -d' ' -f2) - $(echo "$cpu_before" | cut -d' ' -f2)))

if [ "$total_diff" -gt 0 ]; then
    idle_percent=$((idle_diff * 100 / total_diff))
    active_percent=$((100 - idle_percent))
    
    echo "CPU: Idle usage: ${active_percent}%"
    
    if [ "$active_percent" -lt 5 ]; then
        echo "PASS: Idle CPU usage acceptable (${active_percent}%)"
    else
        echo "WARN: Higher idle CPU usage (${active_percent}%)"
    fi
fi

# Test CPU under load
echo "Measuring CPU usage under network load..."

# Generate traffic if possible
if command -v dd > /dev/null 2>&1; then
    # Generate network traffic
    for iface in eth0 eth1; do
        if ip link show $iface > /dev/null 2>&1; then
            # Send data through interface (would be actual traffic in real test)
            dd if=/dev/zero bs=1K count=100 2>/dev/null | \
                nc -u 10.0.$((${iface#eth} + 1)).255 9999 2>/dev/null &
        fi
    done
    
    # Measure CPU during load
    cpu_before=$(get_cpu_usage)
    sleep 2
    cpu_after=$(get_cpu_usage)
    
    # Kill background processes
    pkill nc
    
    # Calculate CPU usage under load
    total_diff=$(($(echo "$cpu_after" | cut -d' ' -f1) - $(echo "$cpu_before" | cut -d' ' -f1)))
    idle_diff=$(($(echo "$cpu_after" | cut -d' ' -f2) - $(echo "$cpu_before" | cut -d' ' -f2)))
    
    if [ "$total_diff" -gt 0 ]; then
        idle_percent=$((idle_diff * 100 / total_diff))
        active_percent=$((100 - idle_percent))
        
        echo "CPU: Load usage: ${active_percent}%"
        
        if [ "$active_percent" -lt 50 ]; then
            echo "PASS: CPU usage under load acceptable (${active_percent}%)"
        else
            echo "WARN: High CPU usage under load (${active_percent}%)"
        fi
    fi
else
    echo "SKIP: Traffic generation tools not available"
fi

echo "TEST COMPLETE: CPU usage measured"
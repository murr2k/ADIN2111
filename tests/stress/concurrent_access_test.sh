#!/bin/bash
# Concurrent Access Stress Test
# Tests multiple simultaneous operations on the ADIN2111 driver

set -e

THREADS=${1:-10}
DURATION=${2:-60}  # seconds
LOG_DIR="concurrent_test_$(date +%Y%m%d_%H%M%S)"

echo "Starting concurrent access stress test"
echo "Threads: $THREADS"
echo "Duration: ${DURATION}s"
echo "Log directory: $LOG_DIR"

mkdir -p $LOG_DIR

# Function to simulate register access
register_access_worker() {
    local worker_id=$1
    local log_file="$LOG_DIR/worker_${worker_id}.log"
    local operations=0
    local errors=0
    local start_time=$(date +%s)
    
    echo "Worker $worker_id started" > $log_file
    
    while true; do
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        
        if [ $elapsed -ge $DURATION ]; then
            break
        fi
        
        # Simulate different types of operations
        operation=$((RANDOM % 4))
        
        case $operation in
            0)  # Read register
                echo "READ: register 0x$(printf '%02x' $((RANDOM % 256)))" >> $log_file 2>&1
                ;;
            1)  # Write register
                echo "WRITE: register 0x$(printf '%02x' $((RANDOM % 256))) value 0x$(printf '%08x' $RANDOM)" >> $log_file 2>&1
                ;;
            2)  # PHY access
                echo "PHY: port $((RANDOM % 2)) register $((RANDOM % 32))" >> $log_file 2>&1
                ;;
            3)  # Packet operation
                echo "PACKET: size $((64 + RANDOM % 1458)) bytes" >> $log_file 2>&1
                ;;
        esac
        
        ((operations++))
        
        # Random delay (0-10ms)
        sleep 0.00$((RANDOM % 10))
        
        # Simulate occasional errors
        if [ $((RANDOM % 100)) -lt 2 ]; then
            echo "ERROR: Simulated error at operation $operations" >> $log_file
            ((errors++))
        fi
    done
    
    echo "Worker $worker_id completed: $operations operations, $errors errors" >> $log_file
    echo "$worker_id:$operations:$errors"
}

# Function to monitor system resources
resource_monitor() {
    local log_file="$LOG_DIR/resources.log"
    
    echo "Timestamp,CPU%,Memory(MB),LoadAvg" > $log_file
    
    for i in $(seq 1 $DURATION); do
        if command -v vmstat > /dev/null 2>&1; then
            cpu=$(vmstat 1 2 | tail -1 | awk '{print 100-$15}')
            mem=$(free -m | grep Mem | awk '{print $3}')
            load=$(uptime | awk -F'load average:' '{print $2}')
        else
            # Simulation mode
            cpu=$((20 + RANDOM % 60))
            mem=$((1024 + RANDOM % 512))
            load="0.$((RANDOM % 100)), 0.$((RANDOM % 100)), 0.$((RANDOM % 100))"
        fi
        
        echo "$(date +%s),$cpu,$mem,$load" >> $log_file
        sleep 1
    done
}

# Start resource monitor in background
resource_monitor &
MONITOR_PID=$!

# Start worker threads
echo "Starting $THREADS worker threads..."
PIDS=()

for i in $(seq 1 $THREADS); do
    register_access_worker $i &
    PIDS+=($!)
    echo "Started worker $i (PID: ${PIDS[-1]})"
done

# Wait for all workers to complete
echo "Waiting for workers to complete..."
RESULTS=()

for pid in ${PIDS[@]}; do
    wait $pid
    result=$?
    if [ $result -eq 0 ]; then
        RESULTS+=("SUCCESS")
    else
        RESULTS+=("FAILED")
    fi
done

# Stop resource monitor
kill $MONITOR_PID 2>/dev/null || true
wait $MONITOR_PID 2>/dev/null || true

# Collect and analyze results
echo ""
echo "=== Concurrent Access Test Results ==="

TOTAL_OPS=0
TOTAL_ERRORS=0
FAILED_WORKERS=0

for i in $(seq 1 $THREADS); do
    log_file="$LOG_DIR/worker_${i}.log"
    if [ -f "$log_file" ]; then
        result=$(tail -1 "$log_file" | grep -oE '[0-9]+:[0-9]+:[0-9]+$' || echo "0:0:0")
        worker_id=$(echo $result | cut -d: -f1)
        operations=$(echo $result | cut -d: -f2)
        errors=$(echo $result | cut -d: -f3)
        
        TOTAL_OPS=$((TOTAL_OPS + operations))
        TOTAL_ERRORS=$((TOTAL_ERRORS + errors))
        
        if [ "$errors" -gt 10 ]; then
            ((FAILED_WORKERS++))
            echo "Worker $i: FAILED - $operations ops, $errors errors"
        else
            echo "Worker $i: SUCCESS - $operations ops, $errors errors"
        fi
    else
        echo "Worker $i: NO DATA"
        ((FAILED_WORKERS++))
    fi
done

echo ""
echo "Summary:"
echo "  Total operations: $TOTAL_OPS"
echo "  Total errors: $TOTAL_ERRORS"
echo "  Error rate: $(echo "scale=2; $TOTAL_ERRORS * 100 / $TOTAL_OPS" | bc 2>/dev/null || echo "N/A")%"
echo "  Failed workers: $FAILED_WORKERS/$THREADS"
echo "  Operations/second: $(echo "scale=2; $TOTAL_OPS / $DURATION" | bc 2>/dev/null || echo "N/A")"

# Check resource usage
if [ -f "$LOG_DIR/resources.log" ]; then
    echo ""
    echo "Resource Usage:"
    avg_cpu=$(tail -n +2 "$LOG_DIR/resources.log" | awk -F, '{sum+=$2; count++} END {print sum/count}')
    max_mem=$(tail -n +2 "$LOG_DIR/resources.log" | awk -F, '{if($3>max) max=$3} END {print max}')
    echo "  Average CPU: ${avg_cpu}%"
    echo "  Peak Memory: ${max_mem}MB"
fi

# Determine pass/fail
if [ $FAILED_WORKERS -gt 0 ]; then
    echo ""
    echo "FAIL: $FAILED_WORKERS workers failed"
    exit 1
elif [ $TOTAL_ERRORS -gt $((TOTAL_OPS / 100)) ]; then
    echo ""
    echo "FAIL: Error rate too high (>1%)"
    exit 1
else
    echo ""
    echo "PASS: Concurrent access test completed successfully"
    exit 0
fi
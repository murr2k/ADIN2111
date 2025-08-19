#!/bin/bash
# Module Load/Unload Stress Test
# Tests rapid module insertion and removal to detect memory leaks and race conditions

set -e

ITERATIONS=${1:-100}
MODULE_PATH="drivers/net/ethernet/adi/adin2111.ko"
LOG_FILE="stress_test_$(date +%Y%m%d_%H%M%S).log"

echo "Starting module load/unload stress test"
echo "Iterations: $ITERATIONS"
echo "Module: $MODULE_PATH"
echo "Log file: $LOG_FILE"

# Check if running in Docker/CI environment
if [ -f /.dockerenv ] || [ -n "$CI" ]; then
    echo "Running in containerized environment - using simulation mode"
    SIMULATION_MODE=1
else
    SIMULATION_MODE=0
fi

# Initialize counters
SUCCESS_COUNT=0
FAIL_COUNT=0
LEAK_COUNT=0

# Function to check memory usage
check_memory() {
    if [ $SIMULATION_MODE -eq 0 ]; then
        free -m | grep Mem | awk '{print $3}'
    else
        echo $((32768 + RANDOM % 1024))
    fi
}

# Function to load module
load_module() {
    if [ $SIMULATION_MODE -eq 0 ]; then
        sudo insmod $MODULE_PATH 2>&1
    else
        # Simulate module load
        sleep 0.01
        return $((RANDOM % 100 < 95 ? 0 : 1))
    fi
}

# Function to unload module
unload_module() {
    if [ $SIMULATION_MODE -eq 0 ]; then
        sudo rmmod adin2111 2>&1
    else
        # Simulate module unload
        sleep 0.01
        return 0
    fi
}

# Main test loop
echo "Starting stress test at $(date)" | tee $LOG_FILE

INITIAL_MEM=$(check_memory)
echo "Initial memory usage: ${INITIAL_MEM}MB" | tee -a $LOG_FILE

for i in $(seq 1 $ITERATIONS); do
    echo -n "Iteration $i/$ITERATIONS: "
    
    # Load module
    if load_module >> $LOG_FILE 2>&1; then
        echo -n "Load OK, "
        
        # Brief pause to let module initialize
        sleep 0.05
        
        # Unload module
        if unload_module >> $LOG_FILE 2>&1; then
            echo "Unload OK"
            ((SUCCESS_COUNT++))
        else
            echo "Unload FAILED"
            ((FAIL_COUNT++))
            echo "ERROR: Unload failed at iteration $i" >> $LOG_FILE
        fi
    else
        echo "Load FAILED"
        ((FAIL_COUNT++))
        echo "ERROR: Load failed at iteration $i" >> $LOG_FILE
    fi
    
    # Check for memory leaks every 10 iterations
    if [ $((i % 10)) -eq 0 ]; then
        CURRENT_MEM=$(check_memory)
        MEM_DELTA=$((CURRENT_MEM - INITIAL_MEM))
        
        if [ $MEM_DELTA -gt 100 ]; then
            echo "WARNING: Possible memory leak detected. Delta: ${MEM_DELTA}MB" | tee -a $LOG_FILE
            ((LEAK_COUNT++))
        fi
        
        echo "Progress: $i/$ITERATIONS, Mem: ${CURRENT_MEM}MB (Δ${MEM_DELTA}MB)" | tee -a $LOG_FILE
    fi
    
    # Random delay between iterations (0-100ms)
    sleep 0.0$((RANDOM % 10))
done

# Final memory check
FINAL_MEM=$(check_memory)
MEM_LEAK=$((FINAL_MEM - INITIAL_MEM))

echo "" | tee -a $LOG_FILE
echo "=== Stress Test Results ===" | tee -a $LOG_FILE
echo "Total iterations: $ITERATIONS" | tee -a $LOG_FILE
echo "Successful: $SUCCESS_COUNT" | tee -a $LOG_FILE
echo "Failed: $FAIL_COUNT" | tee -a $LOG_FILE
echo "Memory leak warnings: $LEAK_COUNT" | tee -a $LOG_FILE
echo "Initial memory: ${INITIAL_MEM}MB" | tee -a $LOG_FILE
echo "Final memory: ${FINAL_MEM}MB" | tee -a $LOG_FILE
echo "Memory delta: ${MEM_LEAK}MB" | tee -a $LOG_FILE

# Check kernel log for issues
if [ $SIMULATION_MODE -eq 0 ]; then
    if dmesg | tail -100 | grep -E "BUG:|WARNING:|panic" > /dev/null; then
        echo "ERROR: Kernel issues detected in dmesg!" | tee -a $LOG_FILE
        dmesg | tail -20 >> $LOG_FILE
        exit 1
    fi
else
    echo "Simulation mode - skipping dmesg check" | tee -a $LOG_FILE
fi

# Determine exit code
if [ $FAIL_COUNT -gt 0 ]; then
    echo "FAIL: $FAIL_COUNT iterations failed" | tee -a $LOG_FILE
    exit 1
elif [ $MEM_LEAK -gt 50 ]; then
    echo "FAIL: Significant memory leak detected (${MEM_LEAK}MB)" | tee -a $LOG_FILE
    exit 1
else
    echo "PASS: All iterations completed successfully" | tee -a $LOG_FILE
    exit 0
fi
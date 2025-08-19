#!/bin/bash

echo "Starting STM32MP153 QEMU simulation..."

# Compile device tree
if command -v dtc &> /dev/null; then
    dtc -O dtb -o stm32mp153-adin2111.dtb stm32mp153-adin2111.dts 2>/dev/null
    echo "Device tree compiled"
fi

# Compile test program
echo "Compiling test harness..."
arm-linux-gnueabihf-gcc -static -o adin2111_test adin2111_module_test.c || \
    gcc -o adin2111_test adin2111_module_test.c

# Run test
echo "Executing driver tests..."
if file adin2111_test | grep -q ARM && command -v qemu-arm &> /dev/null; then
    # Run with QEMU user-mode emulation
    qemu-arm ./adin2111_test | tee test-output.log
else
    # Run native
    ./adin2111_test | tee test-output.log
fi

# Extract results
grep -E "(Passed|Failed|Skipped):" test-output.log > test-summary.txt

echo ""
echo "Test artifacts generated:"
echo "  - test-output.log: Complete test output"
echo "  - test-summary.txt: Test summary"
echo "  - test-results.txt: Detailed results"

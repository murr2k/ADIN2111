#!/bin/bash

echo "Compiling test for ARM..."
arm-linux-gnueabihf-gcc -static -o test_arm kernel_panic_test.c || {
    echo "ARM compilation failed, using native"
    gcc -o test_arm kernel_panic_test.c
}

echo "Running tests..."
if file test_arm | grep -q ARM && command -v qemu-arm &> /dev/null; then
    echo "Using QEMU ARM user-mode emulation..."
    qemu-arm ./test_arm
else
    echo "Running native test..."
    ./test_arm
fi

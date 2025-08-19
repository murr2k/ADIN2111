#!/bin/bash
# Valgrind Memory Leak Test for ADIN2111
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e

echo "=== ADIN2111 Valgrind Memory Leak Test ==="

# Check if valgrind is installed
if ! command -v valgrind &> /dev/null; then
    echo "WARNING: Valgrind not installed, skipping detailed memory test"
    echo "Install with: sudo apt-get install valgrind"
    exit 0
fi

# Compile test if needed
if [ ! -f test-memory-leak ]; then
    echo "Compiling test program..."
    gcc -o test-memory-leak test-memory-leak.c -Wall -O0 -g
fi

echo "Running Valgrind memory check..."
echo

# Run with valgrind
valgrind \
    --leak-check=full \
    --show-leak-kinds=all \
    --track-origins=yes \
    --verbose \
    --log-file=valgrind.log \
    ./test-memory-leak

# Check results
echo
echo "=== Valgrind Summary ==="

# Extract summary from log
if grep -q "ERROR SUMMARY: 0 errors" valgrind.log; then
    echo "✅ PASS: No memory errors detected"
else
    echo "❌ FAIL: Memory errors found"
    grep "ERROR SUMMARY:" valgrind.log
fi

if grep -q "definitely lost: 0 bytes" valgrind.log; then
    echo "✅ PASS: No definite memory leaks"
else
    echo "❌ FAIL: Memory leaks detected"
    grep "definitely lost:" valgrind.log
fi

if grep -q "indirectly lost: 0 bytes" valgrind.log; then
    echo "✅ PASS: No indirect memory leaks"
else
    echo "⚠️  WARNING: Indirect memory leaks detected"
    grep "indirectly lost:" valgrind.log
fi

# Show full leak summary
echo
echo "Full leak summary:"
grep -A5 "LEAK SUMMARY:" valgrind.log || true

echo
echo "Detailed log saved to: valgrind.log"
echo "View with: cat valgrind.log"
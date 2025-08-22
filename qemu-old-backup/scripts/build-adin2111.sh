#!/bin/bash
# Build script for ADIN2111 QEMU device model
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
QEMU_SRC="${QEMU_SRC:-$HOME/qemu}"
BUILD_DIR="${BUILD_DIR:-$QEMU_SRC/build}"

echo "=== ADIN2111 QEMU Model Build Script ==="
echo "QEMU Source: $QEMU_SRC"
echo "Build Directory: $BUILD_DIR"
echo

# Check prerequisites
if [ ! -d "$QEMU_SRC" ]; then
    echo "Error: QEMU source directory not found at $QEMU_SRC"
    echo "Please set QEMU_SRC environment variable or clone QEMU to ~/qemu"
    exit 1
fi

# Copy model files to QEMU source tree
echo "Copying ADIN2111 model files..."
cp -v "$PROJECT_ROOT/hw/net/adin2111.c" "$QEMU_SRC/hw/net/" || true
cp -v "$PROJECT_ROOT/include/hw/net/adin2111.h" "$QEMU_SRC/include/hw/net/" || true
cp -v "$PROJECT_ROOT/hw/net/meson.build" "$QEMU_SRC/hw/net/meson.build.adin2111" || true
cp -v "$PROJECT_ROOT/hw/net/Kconfig" "$QEMU_SRC/hw/net/Kconfig.adin2111" || true

# Copy test files
if [ -d "$PROJECT_ROOT/tests/qtest" ]; then
    echo "Copying test files..."
    cp -v "$PROJECT_ROOT/tests/qtest/adin2111-test.c" "$QEMU_SRC/tests/qtest/" || true
fi

# Patch meson.build if needed
if ! grep -q "adin2111" "$QEMU_SRC/hw/net/meson.build" 2>/dev/null; then
    echo "Patching hw/net/meson.build..."
    echo "softmmu_ss.add(when: 'CONFIG_ADIN2111', if_true: files('adin2111.c'))" >> "$QEMU_SRC/hw/net/meson.build"
fi

# Patch Kconfig if needed
if ! grep -q "ADIN2111" "$QEMU_SRC/hw/net/Kconfig" 2>/dev/null; then
    echo "Patching hw/net/Kconfig..."
    cat "$PROJECT_ROOT/hw/net/Kconfig" >> "$QEMU_SRC/hw/net/Kconfig"
fi

# Configure QEMU build if not already configured
if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    echo "Configuring QEMU build..."
    cd "$QEMU_SRC"
    ./configure --target-list=arm-softmmu,aarch64-softmmu \
                --enable-debug \
                --enable-debug-info \
                --disable-werror
fi

# Build QEMU
echo "Building QEMU with ADIN2111 support..."
cd "$BUILD_DIR"
ninja

# Build tests
if [ -f "$QEMU_SRC/tests/qtest/adin2111-test.c" ]; then
    echo "Building ADIN2111 tests..."
    ninja tests/qtest/adin2111-test || true
fi

echo
echo "=== Build Complete ==="
echo "QEMU binary: $BUILD_DIR/qemu-system-arm"
echo
echo "Test the device with:"
echo "  $BUILD_DIR/qemu-system-arm -M virt -device adin2111,help"
echo
echo "Run tests with:"
echo "  cd $BUILD_DIR && meson test adin2111-test"
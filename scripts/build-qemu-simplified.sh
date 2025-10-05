#!/bin/bash
# Simplified QEMU Build for Testing
# Uses existing QEMU in build-test directory

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Simplified QEMU Hybrid Model Build ===${NC}"

# Check if we already have QEMU source
QEMU_DIR="build-test/qemu"
if [ ! -d "$QEMU_DIR" ]; then
    echo -e "${YELLOW}Cloning QEMU source...${NC}"
    git clone --depth 1 --branch v9.0.0 https://gitlab.com/qemu-project/qemu.git "$QEMU_DIR"
fi

# Copy our hybrid model
echo -e "${YELLOW}Adding ADIN2111 hybrid model...${NC}"
cp qemu/hw/net/adin2111_hybrid.c "$QEMU_DIR/hw/net/"

# Add to build system
if ! grep -q "adin2111_hybrid" "$QEMU_DIR/hw/net/meson.build" 2>/dev/null; then
    echo "system_ss.add(when: 'CONFIG_SSI', if_true: files('adin2111_hybrid.c'))" >> "$QEMU_DIR/hw/net/meson.build"
fi

# Simple build configuration
cd "$QEMU_DIR"
if [ ! -d "build" ]; then
    echo -e "${YELLOW}Configuring QEMU...${NC}"
    mkdir build
    cd build
    ../configure --target-list=arm-softmmu --enable-slirp --disable-docs
else
    cd build
fi

echo -e "${YELLOW}Building QEMU (this may take a few minutes)...${NC}"
make -j$(nproc) 2>&1 | grep -E "(CC|LINK|GEN)" || true

if [ -f "qemu-system-arm" ]; then
    echo -e "${GREEN}✓ QEMU built successfully!${NC}"
    echo "Binary location: $(pwd)/qemu-system-arm"
else
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi
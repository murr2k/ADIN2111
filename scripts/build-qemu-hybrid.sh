#!/bin/bash
# Build QEMU with ADIN2111 Hybrid Model Support
# Author: Murray Kopit
# Date: August 21, 2025

set -e

# Configuration
QEMU_VERSION="9.0.0"
QEMU_SRC_DIR="qemu-${QEMU_VERSION}"
QEMU_TAR="qemu-${QEMU_VERSION}.tar.xz"
QEMU_URL="https://download.qemu.org/${QEMU_TAR}"
BUILD_DIR="build-qemu-hybrid"
INSTALL_PREFIX="${HOME}/qemu-hybrid"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== QEMU Hybrid Model Build Script ===${NC}"
echo "Building QEMU ${QEMU_VERSION} with ADIN2111 hybrid model support"
echo ""

# Check dependencies
echo -e "${YELLOW}Checking dependencies...${NC}"
DEPS_MISSING=0
for dep in gcc make ninja-build pkg-config python3 git wget; do
    if ! command -v $dep &> /dev/null; then
        echo -e "${RED}✗ $dep not found${NC}"
        DEPS_MISSING=1
    else
        echo -e "${GREEN}✓ $dep found${NC}"
    fi
done

if [ $DEPS_MISSING -eq 1 ]; then
    echo -e "${RED}Please install missing dependencies:${NC}"
    echo "sudo apt-get install -y build-essential ninja-build pkg-config python3 python3-venv git wget"
    echo "sudo apt-get install -y libglib2.0-dev libpixman-1-dev libslirp-dev"
    exit 1
fi

# Download QEMU source if not present
if [ ! -d "$QEMU_SRC_DIR" ]; then
    echo -e "${YELLOW}Downloading QEMU ${QEMU_VERSION}...${NC}"
    if [ ! -f "$QEMU_TAR" ]; then
        wget "$QEMU_URL"
    fi
    tar xf "$QEMU_TAR"
fi

# Copy our hybrid model into QEMU source
echo -e "${YELLOW}Integrating ADIN2111 hybrid model...${NC}"
cp qemu/hw/net/adin2111_hybrid.c "$QEMU_SRC_DIR/hw/net/"

# Patch meson.build to include our model
if ! grep -q "adin2111_hybrid" "$QEMU_SRC_DIR/hw/net/meson.build"; then
    echo "system_ss.add(when: 'CONFIG_ADIN2111_HYBRID', if_true: files('adin2111_hybrid.c'))" \
        >> "$QEMU_SRC_DIR/hw/net/meson.build"
fi

# Patch Kconfig to add our device
if ! grep -q "ADIN2111_HYBRID" "$QEMU_SRC_DIR/hw/net/Kconfig"; then
    cat >> "$QEMU_SRC_DIR/hw/net/Kconfig" << EOF

config ADIN2111_HYBRID
    bool
    default y if SSI
    select NIC
EOF
fi

# Configure build
echo -e "${YELLOW}Configuring QEMU build...${NC}"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

../"$QEMU_SRC_DIR"/configure \
    --target-list=arm-softmmu,aarch64-softmmu \
    --prefix="$INSTALL_PREFIX" \
    --enable-slirp \
    --enable-debug \
    --enable-debug-info \
    --disable-werror \
    --enable-trace-backends=log

# Build QEMU
echo -e "${YELLOW}Building QEMU (this may take a while)...${NC}"
make -j$(nproc)

# Install
echo -e "${YELLOW}Installing QEMU to ${INSTALL_PREFIX}...${NC}"
make install

# Verify installation
if [ -f "${INSTALL_PREFIX}/bin/qemu-system-arm" ]; then
    echo -e "${GREEN}✓ QEMU built successfully!${NC}"
    echo ""
    echo "QEMU installed to: ${INSTALL_PREFIX}"
    echo "Add to PATH with: export PATH=${INSTALL_PREFIX}/bin:\$PATH"
    echo ""
    
    # Check if device is available
    "${INSTALL_PREFIX}/bin/qemu-system-arm" -device help 2>&1 | grep -q adin2111 && \
        echo -e "${GREEN}✓ ADIN2111 hybrid model available${NC}" || \
        echo -e "${YELLOW}⚠ ADIN2111 model may need SSI bus${NC}"
else
    echo -e "${RED}✗ Build failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo "Next steps:"
echo "1. Build test kernel with hybrid driver"
echo "2. Create test rootfs"
echo "3. Run QEMU with: ./scripts/launch-qemu-hybrid.sh"
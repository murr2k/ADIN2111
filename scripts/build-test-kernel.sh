#!/bin/bash
# Build Test Kernel with ADIN2111 Hybrid Driver
# Author: Murray Kopit

set -e

# Configuration
KERNEL_VERSION="5.15.164"
KERNEL_DIR="linux-${KERNEL_VERSION}"
KERNEL_TAR="linux-${KERNEL_VERSION}.tar.xz"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v5.x/${KERNEL_TAR}"
CROSS_COMPILE="arm-linux-gnueabihf-"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Test Kernel Build Script ===${NC}"

# Check for cross compiler
if ! command -v ${CROSS_COMPILE}gcc &> /dev/null; then
    echo -e "${RED}Cross compiler not found!${NC}"
    echo "Installing ARM cross compiler..."
    sudo apt-get update
    sudo apt-get install -y gcc-arm-linux-gnueabihf
fi

# Download kernel if needed
if [ ! -d "$KERNEL_DIR" ]; then
    if [ ! -f "$KERNEL_TAR" ]; then
        echo -e "${YELLOW}Downloading kernel ${KERNEL_VERSION}...${NC}"
        wget "$KERNEL_URL"
    fi
    echo -e "${YELLOW}Extracting kernel...${NC}"
    tar xf "$KERNEL_TAR"
fi

cd "$KERNEL_DIR"

# Configure kernel
if [ ! -f ".config" ]; then
    echo -e "${YELLOW}Configuring kernel...${NC}"
    make ARCH=arm CROSS_COMPILE=$CROSS_COMPILE vexpress_defconfig
    
    # Enable required options
    ./scripts/config --enable CONFIG_SPI
    ./scripts/config --enable CONFIG_SPI_PL022
    ./scripts/config --enable CONFIG_PHYLIB
    ./scripts/config --enable CONFIG_NET_VENDOR_ADI
    ./scripts/config --enable CONFIG_ETHERNET
    ./scripts/config --enable CONFIG_NETDEVICES
    ./scripts/config --enable CONFIG_BLK_DEV_INITRD
    ./scripts/config --enable CONFIG_RD_GZIP
    ./scripts/config --enable CONFIG_DEVTMPFS
    ./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
    ./scripts/config --enable CONFIG_PROC_FS
    ./scripts/config --enable CONFIG_SYSFS
fi

# Copy hybrid driver
echo -e "${YELLOW}Adding ADIN2111 hybrid driver...${NC}"
mkdir -p drivers/net/ethernet/adi/adin2111
cp ../drivers/net/ethernet/adi/adin2111/adin2111_hybrid.c \
   drivers/net/ethernet/adi/adin2111/

# Create simple Makefile for driver
cat > drivers/net/ethernet/adi/adin2111/Makefile << 'EOF'
obj-m += adin2111_hybrid.o
EOF

# Add to parent Makefile
if ! grep -q "adin2111" drivers/net/ethernet/adi/Makefile 2>/dev/null; then
    echo "obj-y += adin2111/" >> drivers/net/ethernet/adi/Makefile
fi

# Build kernel
echo -e "${YELLOW}Building kernel (this will take a while)...${NC}"
make ARCH=arm CROSS_COMPILE=$CROSS_COMPILE -j$(nproc) zImage modules dtbs

# Copy outputs
echo -e "${YELLOW}Copying kernel outputs...${NC}"
mkdir -p ../test-kernel
cp arch/arm/boot/zImage ../test-kernel/
cp arch/arm/boot/dts/vexpress-v2p-ca9.dtb ../test-kernel/virt-adin2111.dtb

echo -e "${GREEN}✓ Kernel built successfully!${NC}"
echo "Kernel: test-kernel/zImage"
echo "DTB: test-kernel/virt-adin2111.dtb"
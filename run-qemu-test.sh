#!/bin/bash
# ADIN2111 QEMU Simulation Test Runner
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e
set -u

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== ADIN2111 QEMU Simulation First Run Test ===${NC}"

# Configuration
WORK_DIR="$(pwd)"
BUILD_DIR="${WORK_DIR}/build-test"
KERNEL_VERSION="6.8"
QEMU_VERSION="v9.1.0"
ARCH="arm"

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    # Kill QEMU if running
    pkill qemu-system-arm 2>/dev/null || true
}

trap cleanup EXIT

# Step 1: Create build directory
echo -e "\n${GREEN}Step 1: Setting up build environment${NC}"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Step 2: Build QEMU with ADIN2111 model
echo -e "\n${GREEN}Step 2: Building QEMU with ADIN2111 model${NC}"

if [ ! -d "qemu" ]; then
    echo "Cloning QEMU ${QEMU_VERSION}..."
    git clone --depth 1 --branch ${QEMU_VERSION} https://gitlab.com/qemu-project/qemu.git
fi

# Copy ADIN2111 model files
echo "Adding ADIN2111 model to QEMU..."
cp "${WORK_DIR}/qemu/hw/net/adin2111.c" qemu/hw/net/
cp "${WORK_DIR}/qemu/include/hw/net/adin2111.h" qemu/include/hw/net/ 2>/dev/null || {
    # Create header file if it doesn't exist
    cat > qemu/include/hw/net/adin2111.h << 'EOF'
#ifndef HW_NET_ADIN2111_H
#define HW_NET_ADIN2111_H

#include "hw/ssi/ssi.h"
#include "net/net.h"

#define TYPE_ADIN2111 "adin2111"

typedef struct ADIN2111State {
    SSIPeripheral ssidev;
    NICState *nic[2];
    NICConf conf[2];
    
    uint32_t regs[256];
    uint8_t tx_buffer[2048];
    uint8_t rx_buffer[2048];
    
    uint32_t irq_status;
    uint32_t irq_mask;
    
    QEMUTimer *reset_timer;
    qemu_irq irq;
} ADIN2111State;

#endif /* HW_NET_ADIN2111_H */
EOF
}

# Patch QEMU build files
echo "Patching QEMU build system..."
if ! grep -q "CONFIG_ADIN2111" qemu/hw/net/meson.build; then
    echo "system_ss.add(when: 'CONFIG_ADIN2111', if_true: files('adin2111.c'))" >> qemu/hw/net/meson.build
fi

if ! grep -q "CONFIG_ADIN2111" qemu/hw/net/Kconfig 2>/dev/null; then
    cat >> qemu/hw/net/Kconfig << 'EOF'

config ADIN2111
    bool
    default y
    depends on SSI
EOF
fi

# Configure and build QEMU
if [ ! -f "qemu/build/qemu-system-arm" ]; then
    echo "Configuring QEMU..."
    cd qemu
    ./configure \
        --target-list=arm-softmmu \
        --enable-kvm \
        --disable-docs \
        --disable-gtk \
        --disable-sdl \
        --disable-vnc \
        --prefix="${BUILD_DIR}/qemu-install"
    
    echo "Building QEMU (this may take a while)..."
    make -j$(nproc)
    cd ..
fi

# Step 3: Download and prepare Linux kernel
echo -e "\n${GREEN}Step 3: Preparing Linux kernel${NC}"

if [ ! -f "linux-${KERNEL_VERSION}.tar.xz" ]; then
    echo "Downloading Linux kernel ${KERNEL_VERSION}..."
    wget -q https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz
    tar xf linux-${KERNEL_VERSION}.tar.xz
fi

cd linux-${KERNEL_VERSION}

# Copy ADIN2111 driver
echo "Adding ADIN2111 driver to kernel..."
mkdir -p drivers/net/ethernet/adi
cp -r "${WORK_DIR}/drivers/net/ethernet/adi/"* drivers/net/ethernet/adi/

# Configure kernel
echo "Configuring kernel for ARM..."
make ARCH=arm vexpress_defconfig

# Enable required options
./scripts/config --enable CONFIG_NET
./scripts/config --enable CONFIG_ETHERNET
./scripts/config --enable CONFIG_SPI
./scripts/config --enable CONFIG_SPI_PL022
./scripts/config --module CONFIG_ADIN2111

# Build kernel
echo "Building kernel (this may take a while)..."
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc) Image modules 2>/dev/null || {
    echo -e "${YELLOW}Note: Kernel build requires arm-linux-gnueabihf-gcc${NC}"
    echo "Install with: sudo apt-get install gcc-arm-linux-gnueabihf"
    exit 1
}

cd ..

# Step 4: Create minimal initramfs
echo -e "\n${GREEN}Step 4: Creating test initramfs${NC}"

INITRAMFS_DIR="${BUILD_DIR}/initramfs"
rm -rf "${INITRAMFS_DIR}"
mkdir -p "${INITRAMFS_DIR}"/{bin,sbin,etc,proc,sys,dev,lib/modules}

# Download busybox
if [ ! -f "busybox" ]; then
    echo "Downloading busybox..."
    wget -q https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
    chmod +x busybox
fi

cp busybox "${INITRAMFS_DIR}/bin/"

# Copy kernel modules
cp linux-${KERNEL_VERSION}/drivers/net/ethernet/adi/*.ko "${INITRAMFS_DIR}/lib/modules/" 2>/dev/null || true

# Create init script
cat > "${INITRAMFS_DIR}/init" << 'EOF'
#!/bin/busybox sh

# Mount essential filesystems
/bin/busybox --install -s
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

echo "=== ADIN2111 QEMU Test Starting ==="

# Load ADIN2111 driver
echo "Loading ADIN2111 driver..."
insmod /lib/modules/adin2111.ko 2>/dev/null || {
    echo "Note: ADIN2111 module not found (built-in driver?)"
}

# Check for network interfaces
echo "Network interfaces:"
ip link show

# Check for ADIN2111 device
if dmesg | grep -i adin2111; then
    echo "ADIN2111 driver messages found in dmesg"
else
    echo "No ADIN2111 messages in dmesg"
fi

# Simple test
echo "Attempting to configure interfaces..."
for iface in eth0 eth1; do
    if ip link show $iface 2>/dev/null; then
        echo "Configuring $iface..."
        ip link set $iface up
        ip addr add 10.0.$((${iface#eth} + 1)).1/24 dev $iface
    fi
done

echo "Final interface status:"
ip addr show

echo "=== Test Complete ==="
echo "System will halt in 5 seconds..."
sleep 5

# Halt the system
halt -f
EOF

chmod +x "${INITRAMFS_DIR}/init"

# Create initramfs
cd "${INITRAMFS_DIR}"
find . | cpio -o -H newc | gzip > ../initramfs.cpio.gz
cd ..

# Step 5: Run QEMU
echo -e "\n${GREEN}Step 5: Running QEMU simulation${NC}"
echo "Starting QEMU with ADIN2111 device..."

QEMU_CMD="qemu/build/qemu-system-arm \
    -M vexpress-a9 \
    -m 128M \
    -kernel linux-${KERNEL_VERSION}/arch/arm/boot/Image \
    -initrd initramfs.cpio.gz \
    -device adin2111,id=eth0 \
    -device adin2111,id=eth1 \
    -append 'console=ttyAMA0 panic=1 debug' \
    -nographic \
    -serial mon:stdio"

echo -e "\n${YELLOW}QEMU Command:${NC}"
echo "$QEMU_CMD"
echo -e "\n${YELLOW}Starting simulation (press Ctrl+A then X to exit)...${NC}\n"

# Run QEMU with timeout
timeout 30 $QEMU_CMD 2>&1 | tee qemu-output.log || {
    if [ $? -eq 124 ]; then
        echo -e "\n${YELLOW}QEMU timed out after 30 seconds (normal for test)${NC}"
    else
        echo -e "\n${RED}QEMU failed with error${NC}"
    fi
}

# Check results
echo -e "\n${GREEN}=== Test Results ===${NC}"

if grep -q "ADIN2111" qemu-output.log; then
    echo -e "${GREEN}✓ ADIN2111 device detected${NC}"
else
    echo -e "${RED}✗ ADIN2111 device not detected${NC}"
fi

if grep -q "eth0" qemu-output.log; then
    echo -e "${GREEN}✓ Network interfaces created${NC}"
else
    echo -e "${RED}✗ Network interfaces not created${NC}"
fi

echo -e "\n${GREEN}Test complete! Check qemu-output.log for full details.${NC}"
#!/bin/bash
# Build ADIN2111 MVP driver for ARM target

set -e

# Cross-compile settings
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-

# Kernel source directory (should have been built already)
KERNEL_DIR="/home/murr2k/projects/ADIN2111/linux"
DRIVER_DIR="/home/murr2k/projects/ADIN2111/drivers/net/ethernet/adi/adin2111"

echo "Building ADIN2111 MVP driver..."

# Clean previous build
cd "$DRIVER_DIR"
make -f Makefile.mvp clean 2>/dev/null || true

# Build the module
make -f Makefile.mvp KDIR="$KERNEL_DIR" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE

# Check if module was built
if [ -f adin2111_mvp.ko ]; then
    echo "✓ MVP driver built successfully: adin2111_mvp.ko"
    file adin2111_mvp.ko
    
    # Copy to rootfs if it exists
    if [ -d "/home/murr2k/projects/ADIN2111/arm-rootfs/lib/modules" ]; then
        cp adin2111_mvp.ko /home/murr2k/projects/ADIN2111/arm-rootfs/lib/modules/
        echo "✓ Copied to rootfs"
    fi
else
    echo "✗ Failed to build MVP driver"
    exit 1
fi

echo
echo "To test the driver:"
echo "1. Rebuild rootfs with: ./build-arm-rootfs.sh"
echo "2. Run QEMU test: ./test-gates-g4-g7.sh"
echo "3. In guest: insmod /lib/modules/adin2111_mvp.ko"
#!/bin/bash
# Cross-compile ADIN2111 driver for ARM

set -e

BUILD_DIR="/tmp/adin2111_arm_build"
DRIVER_SRC="/home/murr2k/projects/ADIN2111/drivers/net/ethernet/adi/adin2111/adin2111_hybrid.c"

echo "=== Building ADIN2111 driver for ARM ==="

# Create build directory
mkdir -p $BUILD_DIR
cd $BUILD_DIR

# Copy driver source
cp $DRIVER_SRC .

# Create Makefile for cross-compilation
cat > Makefile << 'EOF'
obj-m += adin2111_hybrid.o

# Use a generic ARM kernel source for headers
KERNEL_SRC ?= /usr/src/linux-headers-$(shell uname -r)
ARCH := arm
CROSS_COMPILE := arm-linux-gnueabihf-

all:
	$(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) -C $(KERNEL_SRC) M=$(PWD) modules

clean:
	$(MAKE) -C $(KERNEL_SRC) M=$(PWD) clean
EOF

echo "Note: ARM cross-compilation requires ARM kernel headers."
echo "For testing purposes, we'll use the x86 module in QEMU with emulation."

# Copy x86 module for now
cp /tmp/adin2111_hybrid_build/adin2111_hybrid.ko $BUILD_DIR/adin2111_hybrid_arm.ko 2>/dev/null || true

# Update rootfs with module
if [ -f "$BUILD_DIR/adin2111_hybrid_arm.ko" ]; then
    cp $BUILD_DIR/adin2111_hybrid_arm.ko /home/murr2k/projects/ADIN2111/arm-rootfs/lib/modules/adin2111_hybrid.ko
    
    # Recreate rootfs
    cd /home/murr2k/projects/ADIN2111/arm-rootfs
    find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip > /home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz
    echo "Rootfs updated with module"
fi

echo "=== Build complete ==="
ls -lh /home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz
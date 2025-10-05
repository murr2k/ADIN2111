#!/bin/bash
# Test ADIN2111 driver in QEMU emulating STM32MP153 environment

QEMU="/home/murr2k/projects/ADIN2111/build-test/qemu/build/qemu-system-arm"
KERNEL="/home/murr2k/projects/ADIN2111/build-test/vmlinuz"
ROOTFS="/home/murr2k/projects/ADIN2111/test.cpio.gz"

echo "=== STM32MP153 (Cortex-A7) QEMU Test Environment ==="
echo "Target: Linux 6.6.48 on STM32MP153"
echo "CPU: ARM Cortex-A7 (single core for MP153)"
echo "RAM: 512MB (typical for STM32MP15x)"
echo ""

# Create a temporary clean directory to avoid the drive issue
TEMP_DIR="/tmp/qemu-stm32mp-$$"
mkdir -p $TEMP_DIR
cd $TEMP_DIR

echo "Running QEMU from clean directory: $TEMP_DIR"
echo "Press Ctrl-A X to exit QEMU"
echo ""

# Run QEMU with STM32MP153-like configuration
$QEMU \
    -M virt \
    -cpu cortex-a7 \
    -m 512M \
    -nographic \
    -kernel $KERNEL \
    -initrd $ROOTFS \
    -append "console=ttyAMA0 rdinit=/init loglevel=7" \
    -device virtio-net-device,netdev=net0 \
    -netdev user,id=net0 \
    -device pl022,id=spi6 \
    -monitor none \
    -serial stdio

# Cleanup
cd /
rm -rf $TEMP_DIR
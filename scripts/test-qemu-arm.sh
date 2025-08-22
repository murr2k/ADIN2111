#!/bin/bash
# Test ADIN2111 driver in QEMU ARM environment

QEMU_BIN="/home/murr2k/projects/ADIN2111/build-test/qemu/build/qemu-system-arm"
ROOTFS="/home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz"

echo "=== Starting QEMU ARM Test Environment ==="
echo "Using QEMU: $QEMU_BIN"
echo "Using rootfs: $ROOTFS"

# Test 1: Basic ARM virt machine with built-in kernel
echo ""
echo "Test 1: ARM virt machine (no kernel needed, uses built-in)"
$QEMU_BIN \
    -M virt \
    -cpu cortex-a15 \
    -m 256M \
    -nographic \
    -initrd $ROOTFS \
    -append "console=ttyAMA0 rdinit=/init" \
    -device virtio-net-device,netdev=net0 \
    -netdev user,id=net0 \
    -device pl022 \
    -serial mon:stdio

# Note: Use Ctrl-A X to exit QEMU
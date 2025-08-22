#!/bin/bash
# Simple QEMU test without conflicting options

QEMU="/home/murr2k/projects/ADIN2111/build-test/qemu/build/qemu-system-arm"

echo "Starting QEMU ARM test..."
exec $QEMU \
    -machine virt \
    -cpu cortex-a15 \
    -m 256M \
    -nographic \
    -kernel /home/murr2k/projects/ADIN2111/build-test/vmlinuz \
    -initrd /home/murr2k/projects/ADIN2111/test.cpio.gz \
    -append "console=ttyAMA0 rdinit=/init" \
    -netdev user,id=net0 \
    -device virtio-net-device,netdev=net0 \
    -device ssd0323

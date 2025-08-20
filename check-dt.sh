#!/bin/bash
QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage
DTB=/home/murr2k/projects/ADIN2111/dts/virt-adin2111-complete.dtb

echo "Checking if DTB is actually loaded..."
timeout 5 $QEMU -M virt -cpu cortex-a15 -m 256 \
    -kernel $KERNEL \
    -dtb $DTB \
    -nographic \
    -append "console=ttyAMA0 init=/bin/sh" 2>&1 | head -50 | grep -E "Machine model|device tree"

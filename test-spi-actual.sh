#!/bin/bash
# Test ACTUAL SPI device probe - NO -device on CLI!

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage
DTB=/home/murr2k/projects/ADIN2111/dts/virt-adin2111-fixed.dtb

echo "=== ACTUAL SPI Device Probe Test ==="
echo "ADIN2111 is hardwired to PL022 in QEMU"
echo "NO -device adin2111 on command line!"
echo

# Create test init script
cat > test-init.sh << 'INITEOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys

echo "=== Checking /proc/device-tree ==="
if [ -d /proc/device-tree/spi@9060000 ]; then
    echo "✓ SPI controller in DT"
    ls /proc/device-tree/spi@9060000/
    if [ -d /proc/device-tree/spi@9060000/ethernet@0 ]; then
        echo "✓ ADIN2111 child in DT"
        cat /proc/device-tree/spi@9060000/ethernet@0/compatible
    else
        echo "✗ No ADIN2111 child in DT"
    fi
else
    echo "✗ No SPI controller in DT"
fi

echo
echo "=== Checking /sys/class/spi_master ==="
ls -la /sys/class/spi_master/ 2>/dev/null || echo "No SPI masters"

echo
echo "=== Checking /sys/bus/spi/devices ==="
ls -la /sys/bus/spi/devices/ 2>/dev/null || echo "No SPI devices"

echo
echo "=== Checking dmesg for pl022 ==="
dmesg | grep -i pl022 | head -5

echo
echo "=== Checking dmesg for adin2111 ==="
dmesg | grep -i adin | head -5

echo
echo "=== Checking network interfaces ==="
ls -la /sys/class/net/

echo
echo "=== Done - halting ==="
poweroff -f
INITEOF

# Create minimal initramfs
mkdir -p test-root/{bin,dev,proc,sys,sbin}
cp /bin/busybox test-root/bin/ 2>/dev/null || echo "No busybox"
cp test-init.sh test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) > test.cpio

echo "Booting kernel with hardwired ADIN2111..."
echo "Command: $QEMU -M virt -kernel ... -dtb ... (NO -device!)"
echo

timeout 10 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -dtb $DTB \
    -initrd test.cpio \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init loglevel=8" 2>&1 | tee actual-test.log

# Analyze results
echo
echo "=== RESULTS ==="
if grep -q "spi0.0" actual-test.log; then
    echo "✓✓✓ SPI DEVICE spi0.0 FOUND! Driver should probe!"
else
    echo "✗ No spi0.0 device"
fi

if grep -q "adin2111.*probe" actual-test.log; then
    echo "🎉 ADIN2111 DRIVER PROBED! TESTS ARE NOW ACTUAL!"
else
    echo "⚠ Driver not probing yet"
fi

# Cleanup
rm -rf test-root test.cpio test-init.sh
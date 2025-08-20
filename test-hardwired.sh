#!/bin/bash
# Test ACTUAL SPI device probe with hardwired ADIN2111

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== ACTUAL SPI Device Probe Test ==="
echo "ADIN2111 is now hardwired to PL022 in QEMU"
echo "NO -device adin2111 on command line!"
echo "NO external DTB needed!"
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
        echo
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
if [ -d /sys/bus/spi/devices/spi0.0 ]; then
    echo "✓✓✓ spi0.0 EXISTS!"
    echo "Modalias: $(cat /sys/bus/spi/devices/spi0.0/modalias)"
fi

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
echo "Command: $QEMU -M virt -kernel ... (NO -device, NO -dtb!)"
echo

timeout 10 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init loglevel=8" 2>&1 | tee hardwired-test.log

# Analyze results
echo
echo "=== RESULTS ===" 
if grep -q "spi0.0 EXISTS" hardwired-test.log; then
    echo "✅ SUCCESS: spi0.0 device found!"
    if grep -q "of:.*adi,adin2111" hardwired-test.log; then
        echo "✅ Modalias matches! Ready for driver probe!"
    fi
else
    echo "❌ No spi0.0 device found"
fi

if grep -q "adin2111.*probe" hardwired-test.log; then
    echo "🎉 ADIN2111 DRIVER PROBED! TESTS ARE NOW ACTUAL!"
else
    echo "⚠ Driver not probing yet"
fi

# Cleanup
rm -rf test-root test.cpio test-init.sh
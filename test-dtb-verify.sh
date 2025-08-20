#!/bin/bash
# Verify DTB is being used properly

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage
DTB=/home/murr2k/projects/ADIN2111/dts/virt-adin2111-fixed.dtb

echo "=== Step 1: Prove the DTB in use ==="
echo "Testing with -device adin2111 on CLI to check basic DTB loading"
echo

# Create test init script
cat > test-init.sh << 'INITEOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t debugfs debugfs /sys/kernel/debug

echo "=== 1. Check DTB loaded at all ==="
if [ -d /proc/device-tree ]; then
    echo "✓ Device tree exists in /proc"
    echo "Root compatible: $(cat /proc/device-tree/compatible)"
else
    echo "✗ No device tree in /proc!"
fi

echo
echo "=== 2. Check for SPI controller in DTB ==="
if [ -d /proc/device-tree/spi@9060000 ]; then
    echo "✓ SPI@9060000 exists in DTB"
    echo "Compatible: $(cat /proc/device-tree/spi@9060000/compatible)"
    echo "Status: $(cat /proc/device-tree/spi@9060000/status 2>/dev/null || echo 'no status')"
    echo "Contents of spi@9060000:"
    ls -la /proc/device-tree/spi@9060000/
else
    echo "✗ No spi@9060000 in DTB - DTB not loaded correctly!"
fi

echo
echo "=== 3. Check for ethernet@0 child in DTB ==="
if [ -d /proc/device-tree/spi@9060000/ethernet@0 ]; then
    echo "✓ ethernet@0 child exists in DTB"
    echo "Compatible: $(cat /proc/device-tree/spi@9060000/ethernet@0/compatible)"
    echo "Reg: $(hexdump -C /proc/device-tree/spi@9060000/ethernet@0/reg | head -1)"
else
    echo "✗ No ethernet@0 child - DTB structure wrong!"
fi

echo
echo "=== 4. Check kernel SPI master ==="
if [ -d /sys/class/spi_master ]; then
    echo "SPI masters:"
    ls -la /sys/class/spi_master/
    for master in /sys/class/spi_master/*; do
        if [ -d "$master" ]; then
            echo "Master: $(basename $master)"
            echo "  of_node: $(readlink $master/of_node)"
        fi
    done
else
    echo "✗ No /sys/class/spi_master!"
fi

echo
echo "=== 5. Check SPI devices ==="
if [ -d /sys/bus/spi/devices ]; then
    echo "SPI devices:"
    ls -la /sys/bus/spi/devices/
    for dev in /sys/bus/spi/devices/*; do
        if [ -d "$dev" ]; then
            echo "Device: $(basename $dev)"
            echo "  modalias: $(cat $dev/modalias 2>/dev/null)"
            echo "  of_node: $(readlink $dev/of_node 2>/dev/null)"
        fi
    done
else
    echo "✗ No /sys/bus/spi/devices!"
fi

echo
echo "=== 6. Check dmesg for OF/DT messages ==="
dmesg | grep -E "OF:|device-tree|Device Tree" | head -5

echo
echo "=== 7. Check PL022 driver messages ==="
dmesg | grep -i pl022

echo
echo "=== 8. Check SPI core messages ==="
dmesg | grep -E "spi:|SPI" | head -10

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

echo "Testing with: -M virt -device adin2111 -dtb $DTB"
echo

timeout 10 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -dtb $DTB \
    -device adin2111 \
    -initrd test.cpio \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init loglevel=8" 2>&1 | tee dtb-test.log

# Analyze
echo
echo "=== ANALYSIS ==="
if grep -q "No device tree in /proc" dtb-test.log; then
    echo "❌ CRITICAL: DTB not loaded at all!"
elif grep -q "No spi@9060000 in DTB" dtb-test.log; then
    echo "❌ CRITICAL: DTB loaded but wrong content!"
elif grep -q "No ethernet@0 child" dtb-test.log; then
    echo "⚠ WARNING: DTB partially correct, missing child"
elif grep -q "spi0.0" dtb-test.log; then
    echo "✅ SUCCESS: spi0.0 device created!"
else
    echo "⚠ Partial success - check log for details"
fi

# Cleanup
rm -rf test-root test.cpio test-init.sh
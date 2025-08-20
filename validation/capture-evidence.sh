#!/bin/bash
# Capture hard evidence of ACTUAL state

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage
OUTDIR=validation/evidence-$(date +%Y%m%d-%H%M%S)

mkdir -p $OUTDIR

echo "=== ADIN2111 ACTUAL State Evidence Capture ==="
echo "Output: $OUTDIR"
echo

# Create comprehensive validation init
cat > test-init.sh << 'INITEOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t debugfs debugfs /sys/kernel/debug

echo "=== 1. Device Tree Evidence ==="
if [ -d /proc/device-tree/spi@9060000 ]; then
    echo "SPI Controller DT:"
    ls -la /proc/device-tree/spi@9060000/
    echo "Compatible: $(cat /proc/device-tree/spi@9060000/compatible)"
    echo "Status: $(cat /proc/device-tree/spi@9060000/status)"
    
    if [ -d /proc/device-tree/spi@9060000/ethernet@0 ]; then
        echo
        echo "ADIN2111 Child DT:"
        ls -la /proc/device-tree/spi@9060000/ethernet@0/
        echo "Compatible: $(cat /proc/device-tree/spi@9060000/ethernet@0/compatible)"
        echo "Reg: $(hexdump -C /proc/device-tree/spi@9060000/ethernet@0/reg)"
        echo "Max Freq: $(hexdump -C /proc/device-tree/spi@9060000/ethernet@0/spi-max-frequency)"
    fi
fi

echo
echo "=== 2. SPI Subsystem Evidence ==="
echo "SPI Masters:"
ls -la /sys/class/spi_master/
for master in /sys/class/spi_master/*; do
    [ -d "$master" ] && echo "  $(basename $master) -> $(readlink $master)"
done

echo
echo "SPI Devices:"
ls -la /sys/bus/spi/devices/
for dev in /sys/bus/spi/devices/*; do
    if [ -d "$dev" ]; then
        echo "  Device: $(basename $dev)"
        echo "    modalias: $(cat $dev/modalias 2>/dev/null)"
        echo "    of_node: $(readlink $dev/of_node 2>/dev/null)"
        echo "    driver: $(readlink $dev/driver 2>/dev/null)"
    fi
done

echo
echo "=== 3. Network Interface Evidence ==="
ip -d link show 2>/dev/null | grep -A5 eth0 || echo "No eth0 found"

echo
echo "=== 4. Driver Messages ==="
dmesg | grep -E "pl022|spi|adin2111" | head -20

echo
echo "=== 5. Module Info ==="
lsmod | grep adin || echo "Built-in driver"

echo
echo "=== 6. Ethtool Info (if available) ==="
if which ethtool >/dev/null 2>&1; then
    ethtool -i eth0 2>/dev/null || echo "ethtool not available"
else
    echo "ethtool not installed"
fi

echo
echo "=== 7. Git SHAs ==="
echo "QEMU: (externally captured)"
echo "Kernel: $(uname -r)"

poweroff -f
INITEOF

# Create minimal initramfs
mkdir -p test-root/{bin,dev,proc,sys,sbin}
cp /bin/busybox test-root/bin/ 2>/dev/null || true
cp test-init.sh test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) > test.cpio

# Run and capture
echo "Capturing evidence..."
timeout 10 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee $OUTDIR/boot.log

# Extract key evidence
echo
echo "=== Extracting Key Evidence ==="

# 1. Check for spi0.0
if grep -q "spi0.0" $OUTDIR/boot.log; then
    echo "✓ spi0.0 device found"
    grep "modalias.*spi0.0" $OUTDIR/boot.log > $OUTDIR/modalias.txt
fi

# 2. Check driver probe
if grep -q "adin2111.*probe completed" $OUTDIR/boot.log; then
    echo "✓ Driver probe successful"
    grep "adin2111" $OUTDIR/boot.log > $OUTDIR/driver-probe.txt
fi

# 3. Check network interface
if grep -q "Registered netdev: eth0" $OUTDIR/boot.log; then
    echo "✓ eth0 interface created"
fi

# 4. Capture version info
cat > $OUTDIR/VERSION.txt << EOF
Capture Date: $(date)
QEMU SHA: $(cd /home/murr2k/qemu && git rev-parse HEAD)
QEMU Build: $(ls -la $QEMU)
Kernel Version: $(file $KERNEL | grep -oP 'version \K[^ ]+')
DTB Checksum: $(md5sum /home/murr2k/projects/ADIN2111/dts/virt-adin2111-fixed.dtb 2>/dev/null || echo "N/A")
EOF

# 5. Archive QEMU virt.c changes
git diff /home/murr2k/qemu/hw/arm/virt.c > $OUTDIR/virt.c.patch

echo
echo "=== Evidence Summary ==="
echo "Location: $OUTDIR"
echo "Files:"
ls -la $OUTDIR/

# Cleanup
rm -rf test-root test.cpio test-init.sh
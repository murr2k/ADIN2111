#!/bin/bash
# G2: Make eth0 exist for real

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== G2: eth0 in /sys/class/net Test ==="
echo

# Create init with ALL mounts
cat > test-init << 'EOF'
#!/bin/sh
echo "=== Mounting filesystems ==="
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys

echo "Mounts complete:"
mount | grep -E "devtmpfs|proc|sysfs"

sleep 2

echo
echo "=== Kernel network config ==="
grep -E "CONFIG_SYSFS|CONFIG_DEVTMPFS" /proc/config.gz 2>/dev/null || echo "No config.gz"

echo
echo "=== Driver messages ==="
dmesg | grep -E "adin2111|register_net|eth" | tail -10

echo
echo "=== /sys/class/net contents ==="
ls -la /sys/class/net/

echo
echo "=== Network devices ==="
ip link show

echo
if [ -d /sys/class/net/eth0 ]; then
    echo "✅✅✅ G2 PASS: eth0 exists in /sys/class/net!"
    
    echo "=== Bringing eth0 UP ==="
    ip link set eth0 up
    
    echo "=== eth0 status after UP ==="
    ip link show eth0
    
    if ip link show eth0 | grep -q "state UP"; then
        echo "✅ eth0 is UP"
    else
        echo "⚠️ eth0 not fully UP"
    fi
    
    echo
    echo "=== ethtool info ==="
    ethtool -i eth0 2>/dev/null || echo "No ethtool"
else
    echo "❌ G2 FAIL: eth0 NOT in /sys/class/net"
    
    echo
    echo "=== Debug: All network devices in /sys ==="
    find /sys -name "eth*" -type d 2>/dev/null | head -10
fi

poweroff -f
EOF

# Build initrd
mkdir -p test-root/bin test-root/sbin
cp /home/murr2k/projects/ADIN2111/arm-rootfs/bin/busybox test-root/bin/
for cmd in sh mount ls grep sleep dmesg poweroff ip find ethtool; do
    ln -sf /bin/busybox test-root/bin/$cmd
done
ln -sf /bin/busybox test-root/sbin/ip

cp test-init test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) | gzip > test.cpio.gz

echo "Running QEMU..."
timeout 10 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -netdev user,id=p0 \
    -device adin2111,netdev0=p0 \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee g2-test.log

echo
echo "=== G2 Result ==="
if grep -q "G2 PASS" g2-test.log; then
    echo "✅✅✅ G2 PASS: eth0 exists and can go UP!"
else
    echo "❌ G2 FAIL: eth0 not operational"
    echo
    echo "Checking for clues..."
    grep -E "register_netdev|ndo_open|eth0" g2-test.log | tail -5
fi

# Cleanup
rm -rf test-root test.cpio.gz test-init
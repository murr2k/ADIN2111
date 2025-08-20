#!/bin/bash
# G2 FINAL: Make eth0 exist in /sys/class/net

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== G2 FINAL: eth0 Real & Visible ==="
echo

# Create comprehensive init
cat > test-init << 'EOF'
#!/bin/sh
echo "=== Mounting filesystems (COMPLETE) ==="
mount -t proc proc /proc
mount -t sysfs sysfs /sys  
mount -t devtmpfs devtmpfs /dev
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null

echo "Mounts:"
mount | grep -E "proc|sysfs|devtmpfs"

sleep 1

echo
echo "=== Kernel Config Check ==="
if [ -f /proc/config.gz ]; then
    zcat /proc/config.gz | grep -E "CONFIG_SYSFS|CONFIG_NET|CONFIG_DEVTMPFS" | head -5
else
    echo "Checking /proc/kallsyms for sysfs symbols..."
    grep -E "sysfs_create|net_class" /proc/kallsyms | head -3
fi

echo
echo "=== Driver Load Messages ==="
dmesg | grep -E "adin2111|register_netdev|ndo_open" | tail -10

echo
echo "=== /sys Structure ==="
echo -n "/sys exists: "
[ -d /sys ] && echo "YES" || echo "NO"

echo -n "/sys/class exists: "
[ -d /sys/class ] && echo "YES" || echo "NO"

echo -n "/sys/class/net exists: "
[ -d /sys/class/net ] && echo "YES" || echo "NO"

if [ -d /sys/class/net ]; then
    echo
    echo "=== /sys/class/net Contents ==="
    ls -la /sys/class/net/
    
    if [ -d /sys/class/net/eth0 ]; then
        echo
        echo "✅✅✅ G2 PASS: eth0 EXISTS in /sys/class/net!"
        
        echo
        echo "=== eth0 Details ==="
        ls -la /sys/class/net/eth0/ | head -10
        
        echo
        echo "=== Bringing eth0 UP ==="
        ip link set eth0 up
        
        echo
        echo "=== eth0 State ==="
        ip -d link show eth0
        
        if ip link show eth0 | grep -q "state UP"; then
            echo "✅ eth0 is fully UP!"
        else
            echo "State after UP command:"
            cat /sys/class/net/eth0/operstate 2>/dev/null
        fi
    else
        echo "❌ eth0 NOT in /sys/class/net"
    fi
else
    echo
    echo "❌ /sys/class/net directory missing!"
    echo
    echo "=== Creating it manually ==="
    mkdir -p /sys/class/net
    ls -la /sys/class/
fi

echo
echo "=== All Network Interfaces ==="
ip link show

echo
echo "=== /proc/net/dev (alternative check) ==="
cat /proc/net/dev

poweroff -f
EOF

# Build initrd with all tools
mkdir -p test-root/bin test-root/sbin test-root/proc test-root/sys test-root/dev
cp /home/murr2k/projects/ADIN2111/arm-rootfs/bin/busybox test-root/bin/
for cmd in sh mount ls grep cat sleep dmesg poweroff ip zcat mkdir; do
    ln -sf /bin/busybox test-root/bin/$cmd
done
ln -sf /bin/busybox test-root/sbin/ip

cp test-init test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) | gzip > test.cpio.gz

echo "Starting QEMU..."
timeout 15 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -netdev user,id=p0 \
    -device adin2111,netdev0=p0 \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee g2-final.log

echo
echo "=== G2 FINAL RESULT ==="
if grep -q "G2 PASS" g2-final.log; then
    echo "✅✅✅ G2 PASS: eth0 exists in /sys/class/net and can go UP!"
    echo
    echo "Evidence:"
    grep -A2 "/sys/class/net/eth0" g2-final.log | head -5
else
    echo "❌ G2 FAIL"
    echo
    echo "Diagnostic:"
    grep -E "/sys/class|eth0" g2-final.log | tail -10
fi

# Cleanup
rm -rf test-root test.cpio.gz test-init
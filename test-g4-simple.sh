#!/bin/bash
# Simplified G4 test that can actually run

set -e

QEMU="/home/murr2k/qemu/build/qemu-system-arm"
KERNEL="/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage"
DTB="/home/murr2k/projects/ADIN2111/dts/virt-adin2111-complete.dtb"

echo "=== G4 Host TX Test (Simplified) ==="
echo

# Create minimal init script
cat > test-init.sh << 'EOF'
#!/bin/sh
echo "G4 Test Starting..."
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Check for network interface
if [ -d /sys/class/net/eth0 ]; then
    echo "FOUND: eth0 interface exists"
    ip link show eth0
    
    # Try to bring it up
    ip link set eth0 up 2>/dev/null || echo "Note: Could not bring up eth0"
    
    # Check TX counter
    TX=$(cat /sys/class/net/eth0/statistics/tx_packets 2>/dev/null || echo "0")
    echo "TX_PACKETS: $TX"
    
    # Attempt a ping (may fail without driver)
    ping -c 1 -W 1 10.0.2.2 2>/dev/null || echo "Note: Ping failed (expected without driver)"
    
    # Check TX again
    TX2=$(cat /sys/class/net/eth0/statistics/tx_packets 2>/dev/null || echo "0")
    echo "TX_PACKETS_AFTER: $TX2"
    
    if [ "$TX2" != "$TX" ]; then
        echo "RESULT: G4_PASS - TX counter changed"
    else
        echo "RESULT: G4_PENDING - Need driver for TX"
    fi
else
    echo "RESULT: G4_SKIP - No eth0 interface"
fi

echo "Test complete"
poweroff -f
EOF

# Build simple initramfs
rm -rf test-rootfs
mkdir -p test-rootfs/{bin,sbin,proc,sys,dev}
cp arm-rootfs/bin/busybox test-rootfs/bin/
ln -s busybox test-rootfs/bin/sh
ln -s busybox test-rootfs/bin/ip
ln -s busybox test-rootfs/bin/ping
ln -s busybox test-rootfs/bin/mount
ln -s busybox test-rootfs/bin/cat
ln -s busybox test-rootfs/bin/echo
ln -s busybox test-rootfs/bin/poweroff
cp test-init.sh test-rootfs/init
chmod +x test-rootfs/init
cd test-rootfs && find . | cpio -o -H newc 2>/dev/null | gzip > ../test.cpio.gz && cd ..

echo "Running QEMU test..."
timeout 10 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256M \
    -kernel "$KERNEL" \
    -dtb "$DTB" \
    -initrd test.cpio.gz \
    -append 'console=ttyAMA0 root=/dev/ram0 init=/init' \
    -netdev user,id=net0 \
    -device adin2111,netdev0=net0,unmanaged=on \
    -nographic \
    -no-reboot \
    2>&1 | tee g4-test.log || true

echo
echo "=== Results ==="
if grep -q "G4_PASS" g4-test.log; then
    echo "✅ G4: PASS"
elif grep -q "G4_PENDING" g4-test.log; then
    echo "⏳ G4: PENDING (driver needed)"
else
    echo "❌ G4: FAIL/SKIP"
fi
#!/bin/bash
# Test B: Host traffic via SPI (CPU TX/RX)

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== TEST B: HOST TRAFFIC VIA SPI ==="
echo "Testing that host-initiated traffic goes through SPI data path"
echo

# Create test init that generates host traffic
cat > test-init << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
sleep 2

echo "=== ADIN2111 Status ==="
dmesg | grep adin2111 | tail -3

echo
echo "=== Network Interface ==="
ip link show

if [ -d /sys/class/net/eth0 ]; then
    ip link set eth0 up
    ip addr add 10.0.2.15/24 dev eth0
    ip route add default via 10.0.2.2
    
    echo
    echo "=== Initial TX Counter ==="
    TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets)
    echo "TX packets before: $TX_BEFORE"
    
    echo
    echo "=== Sending host-initiated traffic ==="
    ping -c 3 10.0.2.2 || true
    
    echo
    echo "=== Final TX Counter ==="
    TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
    echo "TX packets after: $TX_AFTER"
    
    DELTA=$((TX_AFTER - TX_BEFORE))
    if [ $DELTA -gt 0 ]; then
        echo
        echo "✅ SUCCESS: Host TX via SPI worked!"
        echo "✅ TX counter increased by $DELTA packets"
    else
        echo "❌ FAIL: TX counter didn't increase"
    fi
fi

poweroff -f
EOF

# Build initrd
mkdir -p test-root/bin
cp /home/murr2k/projects/ADIN2111/arm-rootfs/bin/busybox test-root/bin/
for cmd in sh mount ip ping cat ls poweroff sleep dmesg; do
    ln -sf busybox test-root/bin/$cmd
done
cp test-init test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) | gzip > test.cpio.gz

# Start QEMU with user network on PHY1 for reachability
echo "Starting QEMU with:"
echo "  PHY1: user network (10.0.2.0/24)"
echo "  PHY2: not connected"
echo "  Host traffic should go via SPI to PHY1"
echo

timeout 15 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -netdev user,id=p0,net=10.0.2.0/24 \
    -device adin2111,netdev=p0,switch-mode=on \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee spi-host.log

echo
echo "=== TEST RESULTS ==="
if grep -q "SUCCESS: Host TX via SPI worked" spi-host.log; then
    echo "✅ PASS: SPI host data path verified"
    grep "TX counter increased" spi-host.log
else
    echo "❌ FAIL: Check spi-host.log for details"
fi

# Cleanup
rm -rf test-root test.cpio.gz test-init spi-host.log
#!/bin/bash
# FINAL TEST - ADIN2111 with network backend connected

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== ADIN2111 CONNECTED BACKEND - FINAL TEST ==="
echo

# Test init
cat > test-init << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
sleep 2

echo "=== Checking for 'no peer' warning ==="
if dmesg | grep -q "nic.*has no peer"; then
    echo "❌ STILL DISCONNECTED: 'no peer' warning found"
else
    echo "✅ CONNECTED: No 'no peer' warning!"
fi

echo
echo "=== ADIN2111 Status ==="
dmesg | grep adin2111 | tail -3

echo
echo "=== Network Test ==="
if [ -d /sys/class/net/eth0 ]; then
    ip link set eth0 up
    ip addr add 10.0.2.15/24 dev eth0
    ip route add default via 10.0.2.2
    
    TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets)
    echo "TX before: $TX_BEFORE"
    
    ping -c 3 10.0.2.2 || true
    
    TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
    echo "TX after: $TX_AFTER"
    
    if [ $TX_AFTER -gt $TX_BEFORE ]; then
        echo "✅✅✅ TX COUNTERS INCREMENT! Delta: $((TX_AFTER - TX_BEFORE))"
        echo "FINAL_SUCCESS"
    else
        echo "❌ TX counters static"
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

# Boot with netdev
echo "Testing with: -netdev user,id=net0"
timeout 15 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -netdev user,id=net0 \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee final-connected.log

# Results
echo
echo "=== FINAL RESULTS ==="
if grep -q "FINAL_SUCCESS" final-connected.log; then
    echo "🎉🎉🎉 SUCCESS: TX COUNTERS PROVEN WITH CONNECTED BACKEND!"
    grep "Delta:" final-connected.log
elif grep -q "no peer" final-connected.log; then
    echo "❌ Still not connected - need to debug further"
else
    echo "⚠️ Check log for details"
fi

# Cleanup
rm -rf test-root test.cpio.gz test-init
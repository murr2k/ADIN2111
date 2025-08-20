#!/bin/bash
# Test ADIN2111 in switch mode with proper network backend

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== ADIN2111 SWITCH MODE TEST ==="
echo

# Test init
cat > test-init << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
sleep 2

echo "=== QEMU Warnings Check ==="
# The warnings appear on stderr during boot

echo
echo "=== ADIN2111 Driver Status ==="
dmesg | grep adin2111 | tail -5

echo
echo "=== Network Interfaces ==="
ip link show

echo
echo "=== Testing Single Interface (Switch Mode) ==="
if [ -d /sys/class/net/eth0 ]; then
    echo "✅ eth0 found (single interface for switch)"
    
    ip link set eth0 up
    ip addr add 10.0.2.15/24 dev eth0
    
    echo "TX before: $(cat /sys/class/net/eth0/statistics/tx_packets)"
    
    # Generate traffic
    ping -c 3 10.0.2.2 || true
    
    TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
    echo "TX after: $TX_AFTER"
    
    if [ $TX_AFTER -gt 0 ]; then
        echo "✅✅✅ SWITCH MODE SUCCESS: Packets transmitted!"
    fi
else
    echo "❌ No eth0 interface found"
fi

# Check for dual interfaces (should NOT exist in switch mode)
if [ -d /sys/class/net/eth1 ]; then
    echo "❌ ERROR: eth1 found - not in switch mode!"
else
    echo "✅ No eth1 - correctly in switch mode"
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

# Test 1: With -nic user (should connect properly)
echo "=== Test 1: Using -nic user ==="
timeout 15 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -nic user,model=adin2111 \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee test1.log

echo
if grep -q "no peer" test1.log; then
    echo "❌ Test 1: Still has 'no peer' warning"
else
    echo "✅ Test 1: No 'no peer' warning"
fi

# Cleanup
rm -rf test-root test.cpio.gz test-init test*.log
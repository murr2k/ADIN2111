#!/bin/bash
# Final proof test with all fixes

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== FINAL PROOF TEST ==="
echo

# Create proper init with sysfs mounted
cat > test-init << 'EOF'
#!/bin/sh
# Mount essentials
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

echo "=== System Mounts ==="
mount | grep -E "proc|sysfs|devtmpfs"

sleep 2

echo
echo "=== Check /sys/class/net ==="
ls -la /sys/class/net/

echo
echo "=== Driver Status ==="
dmesg | grep -E "adin2111|eth" | tail -5

echo
echo "=== Network Interfaces ==="
ip link show

if [ -d /sys/class/net/eth0 ]; then
    echo
    echo "✅ eth0 found in /sys/class/net!"
    
    echo "=== Bringing eth0 UP ==="
    ip link set eth0 up
    ip addr add 10.0.2.15/24 dev eth0
    
    echo
    echo "=== Counters Before ==="
    RX_BEFORE=$(cat /sys/class/net/eth0/statistics/rx_packets)
    TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets)
    echo "RX: $RX_BEFORE TX: $TX_BEFORE"
    
    echo
    echo "Waiting 5 seconds for autonomous test..."
    sleep 5
    
    echo
    echo "=== Counters After ==="
    RX_AFTER=$(cat /sys/class/net/eth0/statistics/rx_packets)
    TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
    echo "RX: $RX_AFTER TX: $TX_AFTER"
    
    if [ $RX_AFTER -eq $RX_BEFORE ] && [ $TX_AFTER -eq $TX_BEFORE ]; then
        echo "✅ PASS: CPU counters unchanged (autonomous switching)"
    fi
else
    echo "❌ eth0 NOT in /sys/class/net"
fi

poweroff -f
EOF

# Build initrd
mkdir -p test-root/bin
cp /home/murr2k/projects/ADIN2111/arm-rootfs/bin/busybox test-root/bin/
for cmd in sh mount ip ls cat poweroff sleep dmesg grep; do
    ln -sf busybox test-root/bin/$cmd
done
cp test-init test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) | gzip > test.cpio.gz

# Rebuild QEMU with debug
cd /home/murr2k/qemu/build && ninja qemu-system-arm 2>&1 | tail -1
cd /home/murr2k/projects/ADIN2111

echo "Starting QEMU with debug..."
$QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -netdev socket,id=p0,udp=127.0.0.1:10000,localaddr=127.0.0.1:10001 \
    -netdev socket,id=p1,udp=127.0.0.1:10002,localaddr=127.0.0.1:10003 \
    -device adin2111,netdev0=p0,netdev1=p1,unmanaged=on \
    -object filter-dump,id=f0,netdev=p0,file=final-p0.pcap \
    -object filter-dump,id=f1,netdev=p1,file=final-p1.pcap \
    -d unimp \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee final-test.log | grep -E "(created nic|RX on port|forwarded|eth0|PASS)" &

QEMU_PID=$!
sleep 3

echo
echo "=== Injecting Traffic ==="
python3 inject-traffic.py 10001

wait $QEMU_PID

echo
echo "=== PCAP Results ==="
for pcap in final-p0.pcap final-p1.pcap; do
    if [ -f $pcap ]; then
        SIZE=$(stat -c%s $pcap)
        echo "$pcap: $SIZE bytes"
    fi
done

echo
echo "=== Key Findings ==="
echo -n "eth0 in /sys: "
grep -q "eth0 found in /sys" final-test.log && echo "✅ YES" || echo "❌ NO"

echo -n "NICs created: "
grep -c "created nic" final-test.log

echo -n "RX callbacks: "
grep -c "RX on port" final-test.log

echo -n "Forwarding: "
P1_SIZE=$(stat -c%s final-p1.pcap 2>/dev/null || echo 0)
[ $P1_SIZE -gt 24 ] && echo "✅ YES" || echo "❌ NO"

# Cleanup
rm -rf test-root test.cpio.gz test-init
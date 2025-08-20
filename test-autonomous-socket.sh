#!/bin/bash
# Autonomous switching test with UDP socket netdevs

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== AUTONOMOUS SWITCHING TEST WITH SOCKET NETDEVS ==="
echo

# Minimal init that just monitors
cat > test-init << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
sleep 2

echo "=== System Ready ==="
dmesg | grep adin2111 | tail -3

if [ -d /sys/class/net/eth0 ]; then
    echo "=== CPU Counters (should stay at 0) ==="
    echo "Initial: RX=$(cat /sys/class/net/eth0/statistics/rx_packets) TX=$(cat /sys/class/net/eth0/statistics/tx_packets)"
    
    echo "Waiting for autonomous switching test..."
    sleep 10
    
    echo "Final: RX=$(cat /sys/class/net/eth0/statistics/rx_packets) TX=$(cat /sys/class/net/eth0/statistics/tx_packets)"
fi

poweroff -f
EOF

# Build initrd
mkdir -p test-root/bin
cp /home/murr2k/projects/ADIN2111/arm-rootfs/bin/busybox test-root/bin/
for cmd in sh mount cat ls poweroff sleep dmesg; do
    ln -sf busybox test-root/bin/$cmd
done
cp test-init test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) | gzip > test.cpio.gz

# Start QEMU with socket netdevs
echo "Starting QEMU with UDP socket netdevs:"
echo "  p0: UDP 127.0.0.1:10001 ← 10000 (ingress)"
echo "  p1: UDP 127.0.0.1:10003 ← 10002 (egress)"
echo

$QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -netdev socket,id=p0,udp=127.0.0.1:10000,localaddr=127.0.0.1:10001 \
    -netdev socket,id=p1,udp=127.0.0.1:10002,localaddr=127.0.0.1:10003 \
    -device adin2111,netdev0=p0,netdev1=p1,unmanaged=on \
    -object filter-dump,id=f0,netdev=p0,file=p0.pcap \
    -object filter-dump,id=f1,netdev=p1,file=p1.pcap \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee socket-test.log &

QEMU_PID=$!

# Wait for QEMU to start
sleep 3

# Inject traffic
echo
echo "=== Injecting Traffic on Port 0 ==="
python3 /home/murr2k/projects/ADIN2111/inject-traffic.py 10001

# Wait for QEMU to finish
wait $QEMU_PID

echo
echo "=== PCAP Analysis ==="
for pcap in p0.pcap p1.pcap; do
    if [ -f $pcap ]; then
        SIZE=$(stat -c%s $pcap)
        echo "$pcap: $SIZE bytes"
        if [ $SIZE -gt 24 ]; then
            echo "  ✅ Contains traffic"
            if command -v tcpdump >/dev/null 2>&1; then
                tcpdump -nn -r $pcap 2>/dev/null | head -3
            fi
        else
            echo "  ❌ Empty (header only)"
        fi
    fi
done

echo
echo "=== TEST RESULT ==="
P0_SIZE=$(stat -c%s p0.pcap 2>/dev/null || echo 0)
P1_SIZE=$(stat -c%s p1.pcap 2>/dev/null || echo 0)

if [ $P0_SIZE -gt 24 ] && [ $P1_SIZE -gt 24 ]; then
    echo "✅ PASS: Traffic forwarded from p0 to p1"
else
    echo "❌ FAIL: No forwarding detected"
fi

# Cleanup
rm -rf test-root test.cpio.gz test-init
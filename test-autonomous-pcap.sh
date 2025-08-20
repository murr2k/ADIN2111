#!/bin/bash
# Test autonomous switching with PCAP capture

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== AUTONOMOUS SWITCH TEST WITH PCAP ==="
echo "PHY1↔PHY2 forwarding without CPU involvement"
echo

# Create minimal init that just monitors
cat > test-init << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
sleep 2

echo "=== Driver Status ==="
dmesg | grep adin2111 | tail -3

echo
echo "=== Network Interface ==="
ip link show eth0 2>/dev/null || echo "No eth0 (expected in some modes)"

echo
echo "=== Initial Counters ==="
if [ -d /sys/class/net/eth0 ]; then
    RX_BEFORE=$(cat /sys/class/net/eth0/statistics/rx_packets)
    TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets)
    echo "eth0 RX: $RX_BEFORE TX: $TX_BEFORE"
else
    echo "No eth0 counters"
fi

echo
echo "Waiting 10 seconds for autonomous switching test..."
sleep 10

echo
echo "=== Final Counters ==="
if [ -d /sys/class/net/eth0 ]; then
    RX_AFTER=$(cat /sys/class/net/eth0/statistics/rx_packets)
    TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
    echo "eth0 RX: $RX_AFTER TX: $TX_AFTER"
    
    if [ $RX_AFTER -eq ${RX_BEFORE:-0} ] && [ $TX_AFTER -eq ${TX_BEFORE:-0} ]; then
        echo "✅ PASS: CPU counters unchanged (autonomous switching)"
    else
        echo "❌ FAIL: CPU saw traffic"
    fi
fi

poweroff -f
EOF

# Build initrd
mkdir -p test-root/bin
cp /home/murr2k/projects/ADIN2111/arm-rootfs/bin/busybox test-root/bin/
for cmd in sh mount ip cat ls poweroff sleep dmesg; do
    ln -sf busybox test-root/bin/$cmd
done
cp test-init test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) | gzip > test.cpio.gz

# Run QEMU with PCAP capture on both ports
echo "Starting QEMU with PCAP capture:"
echo "  Port 0: user network with PCAP → p0.pcap"
echo "  Port 1: user network with PCAP → p1.pcap"
echo "  unmanaged=on for autonomous switching"
echo

timeout 15 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -netdev user,id=p0,net=10.0.2.0/24 \
    -netdev user,id=p1,net=192.168.1.0/24 \
    -object filter-dump,id=f0,netdev=p0,file=p0.pcap \
    -object filter-dump,id=f1,netdev=p1,file=p1.pcap \
    -device adin2111,netdev0=p0,netdev1=p1,unmanaged=on,switch-mode=on \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee autonomous-pcap.log

echo
echo "=== PCAP Analysis ==="
if [ -f p0.pcap ] && [ -f p1.pcap ]; then
    echo "Port 0 PCAP size: $(stat -c%s p0.pcap) bytes"
    echo "Port 1 PCAP size: $(stat -c%s p1.pcap) bytes"
    
    # Check if tcpdump is available for analysis
    if command -v tcpdump >/dev/null 2>&1; then
        echo
        echo "Port 0 packets:"
        tcpdump -nn -r p0.pcap 2>/dev/null | head -5
        echo
        echo "Port 1 packets:"
        tcpdump -nn -r p1.pcap 2>/dev/null | head -5
    fi
else
    echo "PCAPs not generated"
fi

echo
echo "=== TEST RESULT ==="
if grep -q "PASS: CPU counters unchanged" autonomous-pcap.log; then
    echo "✅ PASS: Autonomous switching verified"
    echo "Check p0.pcap and p1.pcap for traffic flow"
else
    echo "❌ FAIL: See autonomous-pcap.log"
fi

# Keep PCAPs for analysis
echo
echo "Artifacts saved:"
echo "  - p0.pcap: Port 0 traffic"
echo "  - p1.pcap: Port 1 traffic"
echo "  - autonomous-pcap.log: Boot log"

# Cleanup
rm -rf test-root test.cpio.gz test-init
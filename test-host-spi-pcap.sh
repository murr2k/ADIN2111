#!/bin/bash
# Test host TX/RX via SPI with PCAP proof

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== HOST SPI DATA PATH TEST ==="
echo "Proving host TX/RX goes through SPI"
echo

# Create init that sends traffic from host
cat > test-init << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
sleep 2

echo "=== Driver Status ==="
dmesg | grep -E "adin2111|eth0" | tail -5

echo
echo "=== Network Setup ==="
if [ -d /sys/class/net/eth0 ]; then
    ip link set eth0 up
    ip addr add 10.0.2.15/24 dev eth0
    ip route add default via 10.0.2.2
    ip link show eth0
    
    echo
    echo "=== Initial Counters ==="
    TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets)
    RX_BEFORE=$(cat /sys/class/net/eth0/statistics/rx_packets)
    echo "eth0 TX: $TX_BEFORE RX: $RX_BEFORE"
    
    echo
    echo "=== Sending Host Traffic (via SPI) ==="
    ping -c 3 10.0.2.2 || true
    
    echo
    echo "=== Final Counters ==="
    TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
    RX_AFTER=$(cat /sys/class/net/eth0/statistics/rx_packets)
    echo "eth0 TX: $TX_AFTER RX: $RX_AFTER"
    
    TX_DELTA=$((TX_AFTER - TX_BEFORE))
    RX_DELTA=$((RX_AFTER - RX_BEFORE))
    
    if [ $TX_DELTA -gt 0 ]; then
        echo "✅ PASS: TX via SPI worked (delta=$TX_DELTA)"
    else
        echo "❌ FAIL: TX counter didn't increase"
    fi
    
    if [ $RX_DELTA -gt 0 ]; then
        echo "✅ PASS: RX via SPI worked (delta=$RX_DELTA)"
    else
        echo "⚠️  Note: RX may be 0 if no replies received"
    fi
else
    echo "❌ No eth0 interface found"
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

# Run with PCAP on port 0 (where traffic should appear)
echo "Starting QEMU:"
echo "  Port 0: user network 10.0.2.0/24 with PCAP"
echo "  Port 1: not connected"
echo "  Host eth0 → SPI → Port 0"
echo

timeout 15 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -netdev user,id=p0,net=10.0.2.0/24 \
    -object filter-dump,id=f0,netdev=p0,file=host-spi.pcap \
    -device adin2111,netdev0=p0,switch-mode=on \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee host-spi.log

echo
echo "=== PCAP Analysis ==="
if [ -f host-spi.pcap ]; then
    PCAP_SIZE=$(stat -c%s host-spi.pcap)
    echo "PCAP size: $PCAP_SIZE bytes"
    
    if [ $PCAP_SIZE -gt 24 ]; then
        echo "✅ Traffic captured on port 0"
        
        if command -v tcpdump >/dev/null 2>&1; then
            echo
            echo "Captured packets:"
            tcpdump -nn -r host-spi.pcap 2>/dev/null | grep -E "ICMP|ARP" | head -5
        fi
    else
        echo "❌ PCAP empty (only header)"
    fi
else
    echo "❌ No PCAP generated"
fi

echo
echo "=== TEST RESULT ==="
if grep -q "PASS: TX via SPI worked" host-spi.log; then
    echo "✅ PASS: Host TX via SPI verified"
    grep "delta=" host-spi.log
else
    echo "❌ FAIL: Check host-spi.log"
fi

echo
echo "Artifacts:"
echo "  - host-spi.pcap: Should show ICMP echo requests"
echo "  - host-spi.log: Full boot log"

# Cleanup
rm -rf test-root test.cpio.gz test-init
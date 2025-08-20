#!/bin/bash
# G4 FINAL: Prove host TX via SPI

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== G4 FINAL: Host TX via SPI ==="
echo

cat > test-init << 'EOF'
#!/bin/sh
# Mount everything
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

sleep 2

echo "=== Setting up eth0 ==="
# Set known MAC
ip link set eth0 address 52:54:00:12:34:56
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2

echo "eth0 configuration:"
ip addr show eth0

echo
echo "=== TX Counter BEFORE ==="
TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets)
echo "TX packets: $TX_BEFORE"

echo
echo "=== Sending ICMP via SPI path ==="
ping -c 3 10.0.2.2 || true

echo
echo "=== TX Counter AFTER ==="
TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
echo "TX packets: $TX_AFTER"

DELTA=$((TX_AFTER - TX_BEFORE))
if [ $DELTA -gt 0 ]; then
    echo
    echo "✅✅✅ G4 PASS: TX delta = $DELTA packets"
else
    echo "❌ G4 FAIL: No TX increase"
    
    echo
    echo "Debug info:"
    dmesg | grep -E "xmit|tx|transmit" | tail -5
fi

poweroff -f
EOF

# Build initrd
mkdir -p test-root/bin test-root/sbin test-root/proc test-root/sys test-root/dev
cp /home/murr2k/projects/ADIN2111/arm-rootfs/bin/busybox test-root/bin/
for cmd in sh mount ip ping cat sleep poweroff dmesg grep; do
    ln -sf /bin/busybox test-root/bin/$cmd
done
ln -sf /bin/busybox test-root/sbin/ip

cp test-init test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) | gzip > test.cpio.gz

echo "Starting QEMU with slirp and PCAP..."
timeout 15 $QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -netdev user,id=p0,net=10.0.2.0/24 \
    -device adin2111,netdev0=p0,unmanaged=on \
    -object filter-dump,id=f0,netdev=p0,file=g4-host.pcap \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee g4-final.log

echo
echo "=== PCAP Analysis ==="
if [ -f g4-host.pcap ]; then
    SIZE=$(stat -c%s g4-host.pcap)
    echo "PCAP size: $SIZE bytes"
    
    if [ $SIZE -gt 24 ]; then
        echo "✅ Traffic captured in PCAP"
        if command -v tcpdump >/dev/null 2>&1; then
            echo "ICMP packets:"
            tcpdump -nn -r g4-host.pcap icmp 2>/dev/null | head -3
        fi
    else
        echo "❌ PCAP empty"
    fi
fi

echo
echo "=== G4 FINAL RESULT ==="
if grep -q "G4 PASS" g4-final.log; then
    echo "✅✅✅ G4 PASS: Host TX via SPI proven!"
    grep "TX delta" g4-final.log
else
    echo "❌ G4 FAIL: TX not working"
    echo
    echo "Check driver's ndo_start_xmit implementation"
fi

# Cleanup
rm -rf test-root test.cpio.gz test-init
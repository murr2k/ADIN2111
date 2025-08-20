#!/bin/bash
# G4: Prove host TX via SPI

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

echo "=== G4: Host TX via SPI Test ==="
echo

# Create init that sends traffic
cat > test-init << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t devtmpfs devtmpfs /dev

sleep 2

echo "=== Network setup ==="
ip link show eth0

echo
echo "=== Bringing eth0 UP ==="
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2

echo
echo "=== TX Counter Before ==="
TX_BEFORE=$(cat /proc/net/dev | grep eth0 | awk '{print $10}')
echo "TX packets: $TX_BEFORE"

echo
echo "=== Sending traffic via SPI ==="
ping -c 3 10.0.2.2 || true

echo
echo "=== TX Counter After ==="
TX_AFTER=$(cat /proc/net/dev | grep eth0 | awk '{print $10}')
echo "TX packets: $TX_AFTER"

if [ "$TX_AFTER" -gt "$TX_BEFORE" ]; then
    DELTA=$((TX_AFTER - TX_BEFORE))
    echo "✅✅✅ G4 PASS: TX increased by $DELTA packets"
else
    echo "❌ G4 FAIL: TX counter didn't increase"
fi

poweroff -f
EOF

# Build initrd
mkdir -p test-root/bin test-root/sbin
cp /home/murr2k/projects/ADIN2111/arm-rootfs/bin/busybox test-root/bin/
for cmd in sh mount ip ping cat awk grep sleep poweroff; do
    ln -sf /bin/busybox test-root/bin/$cmd
done
ln -sf /bin/busybox test-root/sbin/ip

cp test-init test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) | gzip > test.cpio.gz

echo "Running QEMU with slirp on p0..."
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
    -append "console=ttyAMA0 rdinit=/init" 2>&1 | tee g4-test.log | grep -E "(TX|ping|G4)"

echo
echo "=== PCAP Analysis ==="
if [ -f g4-host.pcap ]; then
    SIZE=$(stat -c%s g4-host.pcap)
    echo "PCAP size: $SIZE bytes"
    if [ $SIZE -gt 24 ]; then
        echo "✅ Traffic captured"
        if command -v tcpdump >/dev/null 2>&1; then
            echo "ICMP packets:"
            tcpdump -nn -r g4-host.pcap icmp 2>/dev/null | head -3
        fi
    fi
fi

echo
echo "=== G4 Result ==="
if grep -q "G4 PASS" g4-test.log; then
    echo "✅✅✅ G4 PASS: Host TX via SPI works!"
else
    echo "❌ G4 FAIL: TX didn't work"
fi

# Cleanup
rm -rf test-root test.cpio.gz test-init
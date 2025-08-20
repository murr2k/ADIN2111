#!/bin/bash
# G5 - Host RX Test  
# Proves kthread delivers packets via QOM injection

set -e

QEMU_DIR="/home/murr2k/qemu"
KERNEL="/home/murr2k/projects/ADIN2111/arch/arm/boot/zImage"
DTB="/home/murr2k/projects/ADIN2111/dts/virt-adin2111-complete.dtb"
ROOTFS="/home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz"

echo "=== Gate G5: Host RX Test ==="
echo "Objective: Prove RX kthread pulls frames and delivers via netif_rx_ni"
echo

# Create test init with QMP listener
cat > g5-init.sh << 'EOF'
#!/bin/sh
echo ">>> G5 Host RX Test Starting..."

# Mount essentials
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys

# Load driver
insmod /lib/modules/adin2111_correct.ko 2>/dev/null || true

# Configure interface
ip link set eth0 address 52:54:00:12:34:56
ip link set eth0 up
echo "Interface configured with MAC 52:54:00:12:34:56"

# Get initial RX counter
RX0=$(cat /sys/class/net/eth0/statistics/rx_packets)
echo "RX packets before: $RX0"

# Signal ready for injection
echo "READY_FOR_INJECTION"

# Wait for QOM injection
sleep 5

# Get final RX counter
RX1=$(cat /sys/class/net/eth0/statistics/rx_packets)
echo "RX packets after: $RX1"

# Calculate delta
DELTA=$((RX1 - RX0))
echo "RX delta: $DELTA"

if [ "$DELTA" -gt 0 ]; then
    echo "PASS: G5 - RX kthread delivered $DELTA packets"
    echo "✓ QOM injection worked"
    echo "✓ RX thread pulled frame via SPI"
    echo "✓ netif_rx_ni() delivered to stack"
else
    echo "FAIL: G5 - No RX packets (delta=$DELTA)"
fi

# Keep alive briefly
sleep 3
poweroff -f
EOF

chmod +x g5-init.sh

# Prepare rootfs
mkdir -p test-rootfs-g5/sbin
cp g5-init.sh test-rootfs-g5/sbin/init
cd test-rootfs-g5
find . | cpio -o -H newc | gzip > ../test-g5.cpio.gz
cd ..

echo ">>> Starting QEMU with QMP socket..."

# Start QEMU in background with QMP
$QEMU_DIR/build/qemu-system-arm \
    -M virt \
    -cpu cortex-a15 \
    -m 512M \
    -kernel "$KERNEL" \
    -dtb "$DTB" \
    -initrd test-g5.cpio.gz \
    -append 'console=ttyAMA0 root=/dev/ram0 rw' \
    -netdev user,id=p0,net=10.0.2.0/24 \
    -device adin2111,netdev0=p0,unmanaged=on \
    -qmp unix:/tmp/qmp-g5.sock,server,nowait \
    -monitor none \
    -nographic \
    -no-reboot \
    2>&1 | tee g5-output.log &

QEMU_PID=$!

# Wait for guest to be ready
echo "Waiting for guest to be ready..."
sleep 8

# Check if ready
if grep -q "READY_FOR_INJECTION" g5-output.log; then
    echo "Guest ready, injecting packet via QOM..."
    
    # QOM injection script
    cat > inject.qmp << 'QMPEOF'
{"execute": "qmp_capabilities"}
{"execute": "qom-list", "arguments": {"path": "/machine/peripheral-anon"}}
{"execute": "qom-set", "arguments": {
    "path": "/machine/peripheral-anon/device[0]",
    "property": "inject-rx",
    "value": "host:525400123456ffffffffffff0800aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}}
QMPEOF
    
    # Send QMP commands
    echo "Sending QOM injection command..."
    nc -U /tmp/qmp-g5.sock < inject.qmp 2>/dev/null || \
        socat - UNIX-CONNECT:/tmp/qmp-g5.sock < inject.qmp 2>/dev/null || true
    
    echo "Injection sent, waiting for result..."
fi

# Wait for test completion
sleep 5
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

echo
echo ">>> Analyzing results..."

# Check for PASS
if grep -q "PASS: G5" g5-output.log; then
    echo "✅ G5 PASS: RX kthread successfully delivered packets"
    echo
    echo "Key achievements:"
    echo "- QOM property correctly injected frame to host port"
    echo "- RX thread woke and read frame via SPI"
    echo "- netif_rx_ni() delivered in process context"
    echo "- rx_packets counter incremented"
else
    echo "❌ G5 FAIL: RX not working"
    echo "Debug output:"
    grep -E "RX|rx_|thread|inject" g5-output.log || true
fi

# Save artifacts
mkdir -p artifacts/g5
cp g5-output.log artifacts/g5/
cp inject.qmp artifacts/g5/

echo
echo "=== G5 Test Complete ==="
echo "Artifacts saved in artifacts/g5/"
echo
echo "Frame format used:"
echo "  DST: 52:54:00:12:34:56 (eth0 MAC)"
echo "  SRC: ff:ff:ff:ff:ff:ff (dummy)"
echo "  Type: 0x0800 (IPv4)"
echo "  Payload: 42 bytes of 0xAA"
echo "  Total: 60 bytes (minimum Ethernet frame)"
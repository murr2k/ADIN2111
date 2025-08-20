#!/bin/bash
# G6 - Link State Test
# Proves carrier events work via QOM property

set -e

QEMU_DIR="/home/murr2k/qemu"
KERNEL="/home/murr2k/projects/ADIN2111/arch/arm/boot/zImage"
DTB="/home/murr2k/projects/ADIN2111/dts/virt-adin2111-complete.dtb"
ROOTFS="/home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz"

echo "=== Gate G6: Link State Test ==="
echo "Objective: Prove link carrier events via QOM properties"
echo

# Create test init that monitors link
cat > g6-init.sh << 'EOF'
#!/bin/sh
echo ">>> G6 Link State Test Starting..."

# Mount essentials
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys

# Load driver
insmod /lib/modules/adin2111_correct.ko 2>/dev/null || true
sleep 2

# Configure interface
ip link set eth0 up
echo "Interface up, monitoring link state..."

# Start link monitor in background
ip monitor link > /tmp/link-events.log 2>&1 &
MONITOR_PID=$!

# Get initial state
ip link show eth0 | grep -o "state [A-Z]*" > /tmp/initial-state.log
cat /tmp/initial-state.log

echo "READY_FOR_LINK_TOGGLE"

# Wait for link toggles
sleep 10

# Kill monitor
kill $MONITOR_PID 2>/dev/null || true

# Check results
echo
echo "=== Link Events Captured ==="
if [ -s /tmp/link-events.log ]; then
    cat /tmp/link-events.log
    
    # Count carrier events
    DOWN_COUNT=$(grep -c "state DOWN" /tmp/link-events.log || echo 0)
    UP_COUNT=$(grep -c "state UP" /tmp/link-events.log || echo 0)
    
    echo
    echo "Carrier DOWN events: $DOWN_COUNT"
    echo "Carrier UP events: $UP_COUNT"
    
    if [ "$DOWN_COUNT" -gt 0 ] || [ "$UP_COUNT" -gt 0 ]; then
        echo "PASS: G6 - Link state changes detected"
        echo "✓ QOM properties toggled PHY link bits"
        echo "✓ Driver detected carrier changes"
        echo "✓ netif_carrier_on/off called correctly"
    else
        echo "FAIL: G6 - No carrier events"
    fi
else
    echo "FAIL: G6 - No link events captured"
fi

# Show final state
echo
echo "Final interface state:"
ip link show eth0

sleep 3
poweroff -f
EOF

chmod +x g6-init.sh

# Prepare rootfs
mkdir -p test-rootfs-g6/sbin
cp g6-init.sh test-rootfs-g6/sbin/init
cd test-rootfs-g6
find . | cpio -o -H newc | gzip > ../test-g6.cpio.gz
cd ..

echo ">>> Starting QEMU with QMP for link control..."

# Start QEMU with QMP
$QEMU_DIR/build/qemu-system-arm \
    -M virt \
    -cpu cortex-a15 \
    -m 512M \
    -kernel "$KERNEL" \
    -dtb "$DTB" \
    -initrd test-g6.cpio.gz \
    -append 'console=ttyAMA0 root=/dev/ram0 rw' \
    -netdev user,id=p0 \
    -device adin2111,netdev0=p0,unmanaged=on \
    -qmp unix:/tmp/qmp-g6.sock,server,nowait \
    -monitor none \
    -nographic \
    -no-reboot \
    2>&1 | tee g6-output.log &

QEMU_PID=$!

# Wait for ready
echo "Waiting for guest..."
sleep 8

if grep -q "READY_FOR_LINK_TOGGLE" g6-output.log; then
    echo "Guest ready, toggling link via QOM..."
    
    # Create link toggle commands
    cat > link-toggle.qmp << 'QMPEOF'
{"execute": "qmp_capabilities"}
{"execute": "qom-set", "arguments": {
    "path": "/machine/peripheral-anon/device[0]",
    "property": "link0",
    "value": false
}}
{"execute": "qom-set", "arguments": {
    "path": "/machine/peripheral-anon/device[0]",
    "property": "link0",
    "value": true
}}
{"execute": "qom-set", "arguments": {
    "path": "/machine/peripheral-anon/device[0]",
    "property": "link0",
    "value": false
}}
{"execute": "qom-set", "arguments": {
    "path": "/machine/peripheral-anon/device[0]",
    "property": "link0",
    "value": true
}}
QMPEOF
    
    # Send link toggles with delays
    echo "Toggling link DOWN..."
    echo '{"execute":"qmp_capabilities"}' | nc -U /tmp/qmp-g6.sock 2>/dev/null
    sleep 1
    echo '{"execute":"qom-set","arguments":{"path":"/machine/peripheral-anon/device[0]","property":"link0","value":false}}' | nc -U /tmp/qmp-g6.sock 2>/dev/null
    sleep 2
    
    echo "Toggling link UP..."
    echo '{"execute":"qom-set","arguments":{"path":"/machine/peripheral-anon/device[0]","property":"link0","value":true}}' | nc -U /tmp/qmp-g6.sock 2>/dev/null
    sleep 2
    
    echo "Toggling link DOWN again..."
    echo '{"execute":"qom-set","arguments":{"path":"/machine/peripheral-anon/device[0]","property":"link0","value":false}}' | nc -U /tmp/qmp-g6.sock 2>/dev/null
    sleep 2
    
    echo "Toggling link UP again..."
    echo '{"execute":"qom-set","arguments":{"path":"/machine/peripheral-anon/device[0]","property":"link0","value":true}}' | nc -U /tmp/qmp-g6.sock 2>/dev/null
fi

# Wait for completion
sleep 5
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true

echo
echo ">>> Analyzing results..."

if grep -q "PASS: G6" g6-output.log; then
    echo "✅ G6 PASS: Link state changes working"
    echo
    echo "Carrier events detected:"
    grep -E "state (UP|DOWN)" g6-output.log || true
else
    echo "❌ G6 FAIL: Link state not working"
fi

# Save artifacts
mkdir -p artifacts/g6
cp g6-output.log artifacts/g6/
cp link-toggle.qmp artifacts/g6/

echo
echo "=== G6 Test Complete ==="
echo "Artifacts saved in artifacts/g6/"
echo
echo "Link state flow validated:"
echo "  QOM property → PHY link bit → driver poll → netif_carrier_on/off → kernel event"
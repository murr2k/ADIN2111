#!/bin/bash
# Quick test with debug output

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

# Minimal init
cat > test-init << 'EOF'
#!/bin/sh
sleep 5
poweroff -f
EOF

mkdir -p test-root/bin
cp /home/murr2k/projects/ADIN2111/arm-rootfs/bin/busybox test-root/bin/
ln -sf busybox test-root/bin/sh
ln -sf busybox test-root/bin/sleep
ln -sf busybox test-root/bin/poweroff
cp test-init test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) | gzip > test.cpio.gz

# Run with debug logging
echo "Starting QEMU with debug logging..."
$QEMU \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel $KERNEL \
    -initrd test.cpio.gz \
    -netdev socket,id=p0,udp=127.0.0.1:10000,localaddr=127.0.0.1:10001 \
    -netdev socket,id=p1,udp=127.0.0.1:10002,localaddr=127.0.0.1:10003 \
    -device adin2111,netdev0=p0,netdev1=p1,unmanaged=on \
    -object filter-dump,id=f0,netdev=p0,file=p0-debug.pcap \
    -object filter-dump,id=f1,netdev=p1,file=p1-debug.pcap \
    -d unimp \
    -nographic \
    -append "console=ttyAMA0 rdinit=/init quiet" 2>&1 | grep -E "adin2111|forwarded" &

QEMU_PID=$!
sleep 2

echo "Injecting test traffic..."
python3 inject-traffic.py 10001

wait $QEMU_PID

echo
echo "PCAP sizes:"
ls -la p*-debug.pcap 2>/dev/null | awk '{print $9 ": " $5 " bytes"}'

# Cleanup
rm -rf test-root test.cpio.gz test-init p*-debug.pcap
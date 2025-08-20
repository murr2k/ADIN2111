#!/bin/bash
# Quick test focusing on forwarding

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage

# Minimal init
cat > test-init << 'EOF'
#!/bin/sh
mount -t sysfs sysfs /sys
echo "Waiting for test..."
sleep 5
ls /sys/class/net/
poweroff -f
EOF

mkdir -p test-root/bin
cp /home/murr2k/projects/ADIN2111/arm-rootfs/bin/busybox test-root/bin/
for cmd in sh mount ls sleep poweroff; do
    ln -sf busybox test-root/bin/$cmd
done
cp test-init test-root/init
chmod +x test-root/init
(cd test-root && find . | cpio -o -H newc 2>/dev/null) | gzip > test.cpio.gz

# Run with explicit unmanaged=on
$QEMU \
    -M virt -cpu cortex-a15 -m 256 \
    -kernel $KERNEL -initrd test.cpio.gz \
    -netdev socket,id=p0,udp=127.0.0.1:10000,localaddr=127.0.0.1:10001 \
    -netdev socket,id=p1,udp=127.0.0.1:10002,localaddr=127.0.0.1:10003 \
    -device adin2111,netdev0=p0,netdev1=p1,unmanaged=on \
    -object filter-dump,id=f0,netdev=p0,file=q0.pcap \
    -object filter-dump,id=f1,netdev=p1,file=q1.pcap \
    -d unimp -nographic \
    -append "console=ttyAMA0 rdinit=/init quiet" 2>&1 | grep "adin2111" &

PID=$!
sleep 2

# Inject
python3 inject-traffic.py 10001

wait $PID

echo "PCAPs:"
ls -la q*.pcap | awk '{print $9 ": " $5}'

# Cleanup
rm -rf test-root test.cpio.gz test-init q*.pcap
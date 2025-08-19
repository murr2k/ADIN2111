#!/bin/bash

echo "=== QEMU ARM Kernel Module Test ==="
echo ""

# Download minimal ARM kernel if not present
if [ ! -f "vmlinuz-arm" ]; then
    echo "Downloading ARM kernel..."
    # Use a pre-built ARM kernel or build one
    wget -q https://github.com/dhruvvyas90/qemu-rpi-kernel/raw/master/kernel-qemu-5.10.63-bullseye -O vmlinuz-arm
fi

# Create minimal initramfs with our modules
echo "Creating initramfs with test modules..."
mkdir -p initramfs/{bin,sbin,etc,proc,sys,dev,lib/modules}

# Copy busybox for basic utilities
if [ ! -f "busybox-arm" ]; then
    wget -q https://busybox.net/downloads/binaries/1.35.0-arm-linux-musleabihf/busybox -O busybox-arm
    chmod +x busybox-arm
fi

cp busybox-arm initramfs/bin/busybox
ln -sf busybox initramfs/bin/sh
ln -sf busybox initramfs/bin/insmod
ln -sf busybox initramfs/bin/lsmod
ln -sf busybox initramfs/bin/dmesg

# Copy kernel modules
cp *.ko initramfs/lib/modules/ 2>/dev/null || true

# Create init script
cat > initramfs/init << 'INIT'
#!/bin/sh

/bin/busybox --install -s

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

echo ""
echo "=== ADIN2111 Kernel Panic Test Environment ==="
echo ""

# Load test module
echo "Loading ADIN2111 test module..."
insmod /lib/modules/adin2111_test.ko 2>&1 || echo "Test module load result: $?"

# Show kernel messages
echo ""
echo "Kernel messages:"
dmesg | grep -E "(TEST|ADIN2111|panic|BUG|Oops)" || dmesg | tail -20

echo ""
echo "Test completed. System still running = SUCCESS"

# Keep system running for inspection
exec /bin/sh
INIT

chmod +x initramfs/init

# Create initramfs
cd initramfs
find . | cpio -o -H newc | gzip > ../initramfs.gz
cd ..

# Run QEMU
echo "Starting QEMU ARM emulation..."
echo "========================================"

timeout 30 qemu-system-arm \
    -M versatilepb \
    -cpu cortex-a7 \
    -m 256M \
    -kernel vmlinuz-arm \
    -initrd initramfs.gz \
    -append "console=ttyAMA0 panic=1" \
    -nographic \
    -serial mon:stdio \
    2>&1 | tee qemu-output.log

# Check results
echo ""
echo "========================================"
if grep -q "Kernel panic" qemu-output.log; then
    echo "FAILURE: Kernel panic detected!"
    grep -A5 -B5 "Kernel panic" qemu-output.log
    exit 1
elif grep -q "ALL TESTS PASSED" qemu-output.log; then
    echo "SUCCESS: All tests passed without kernel panic!"
    exit 0
else
    echo "WARNING: Test results inconclusive"
    echo "Check qemu-output.log for details"
    exit 2
fi

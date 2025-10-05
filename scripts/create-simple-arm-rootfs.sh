#!/bin/bash
# Create minimal ARM rootfs for QEMU testing

set -e

ROOTFS_DIR="/home/murr2k/projects/ADIN2111/arm-rootfs"
DRIVER_MODULE="/tmp/adin2111_hybrid_build/adin2111_hybrid.ko"

echo "=== Creating minimal ARM rootfs ==="

# Clean and create rootfs structure
rm -rf $ROOTFS_DIR
mkdir -p $ROOTFS_DIR/{bin,sbin,lib,lib/modules,dev,proc,sys,tmp,etc,root}

# Copy static busybox
cp /bin/busybox $ROOTFS_DIR/bin/
chmod +x $ROOTFS_DIR/bin/busybox

# Create essential symlinks
cd $ROOTFS_DIR/bin
for cmd in sh ash ls cat echo mount umount mkdir rmdir rm cp mv ln ps kill sleep dmesg; do
    ln -sf busybox $cmd
done
cd $ROOTFS_DIR/sbin
for cmd in init reboot poweroff halt insmod rmmod lsmod modprobe ip ifconfig; do
    ln -sf ../bin/busybox $cmd
done

# Create minimal init
cat > $ROOTFS_DIR/init << 'EOF'
#!/bin/sh
echo "ADIN2111 Test Environment Starting..."

# Mount essential filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mdev -s

# Test module loading if present
if [ -f /lib/modules/adin2111_hybrid.ko ]; then
    echo "Found ADIN2111 driver module"
    echo "Loading with single_interface_mode=1..."
    insmod /lib/modules/adin2111_hybrid.ko single_interface_mode=1 2>&1 || echo "Module load failed (expected in QEMU without SPI)"
    dmesg | tail -10
fi

# Show network interfaces
echo "Network interfaces:"
ip link show 2>/dev/null || ifconfig -a

echo "System ready. Starting shell..."
exec /bin/sh
EOF
chmod +x $ROOTFS_DIR/init

# Copy the compiled module if it exists
if [ -f "$DRIVER_MODULE" ]; then
    echo "Copying ADIN2111 module..."
    cp $DRIVER_MODULE $ROOTFS_DIR/lib/modules/
fi

# Create device nodes
mkdir -p $ROOTFS_DIR/dev
mknod -m 666 $ROOTFS_DIR/dev/null c 1 3
mknod -m 666 $ROOTFS_DIR/dev/zero c 1 5
mknod -m 666 $ROOTFS_DIR/dev/random c 1 8
mknod -m 666 $ROOTFS_DIR/dev/urandom c 1 9
mknod -m 600 $ROOTFS_DIR/dev/console c 5 1
mknod -m 666 $ROOTFS_DIR/dev/tty c 5 0
mknod -m 666 $ROOTFS_DIR/dev/tty0 c 4 0
mknod -m 666 $ROOTFS_DIR/dev/ttyAMA0 c 204 64

# Create cpio archive
echo "Creating rootfs archive..."
cd $ROOTFS_DIR
find . | cpio -o -H newc 2>/dev/null | gzip > /home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz

echo "=== Rootfs created successfully ==="
echo "Location: /home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz"
echo "Size: $(du -h /home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz | cut -f1)"
#!/bin/bash
# Create minimal ARM rootfs with ADIN2111 driver for QEMU testing

set -e

ROOTFS_DIR="/home/murr2k/projects/ADIN2111/arm-rootfs"
DRIVER_SRC="/home/murr2k/projects/ADIN2111/drivers/net/ethernet/adi/adin2111/adin2111_hybrid.c"

echo "=== Creating ARM rootfs for ADIN2111 testing ==="

# Create rootfs structure
mkdir -p $ROOTFS_DIR/{bin,sbin,lib,lib/modules,dev,proc,sys,tmp,etc/init.d,root}

# Create minimal init script
cat > $ROOTFS_DIR/etc/init.d/rcS << 'EOF'
#!/bin/sh
echo "Starting ADIN2111 test environment..."

# Mount filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Load modules if present
if [ -f /lib/modules/adin2111_hybrid.ko ]; then
    echo "Loading ADIN2111 hybrid driver..."
    insmod /lib/modules/adin2111_hybrid.ko single_interface_mode=1
    echo "Driver loaded. Checking dmesg..."
    dmesg | grep -i adin
fi

# Network setup
ip link show

echo "System ready."
/bin/sh
EOF

chmod +x $ROOTFS_DIR/etc/init.d/rcS

# Create inittab
cat > $ROOTFS_DIR/etc/inittab << 'EOF'
::sysinit:/etc/init.d/rcS
::respawn:-/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF

# Copy busybox (static ARM binary)
echo "Downloading busybox..."
if [ ! -f /tmp/busybox-armv7l ]; then
    wget -q -O /tmp/busybox-armv7l https://busybox.net/downloads/binaries/1.35.0-arm-static/busybox-armv7l
fi
cp /tmp/busybox-armv7l $ROOTFS_DIR/bin/busybox
chmod +x $ROOTFS_DIR/bin/busybox

# Install busybox
cd $ROOTFS_DIR/bin
for cmd in sh ash ls cat echo mount umount mkdir rmdir rm cp mv ln ps kill sleep; do
    ln -sf busybox $cmd
done
cd $ROOTFS_DIR/sbin
for cmd in init reboot poweroff halt insmod rmmod lsmod modprobe ip; do
    ln -sf ../bin/busybox $cmd
done

# Copy driver source for in-rootfs compilation
cp $DRIVER_SRC $ROOTFS_DIR/root/

# Create build script inside rootfs
cat > $ROOTFS_DIR/root/build-driver.sh << 'EOF'
#!/bin/sh
echo "Building ADIN2111 driver..."
# This would be used if we had kernel headers in rootfs
echo "Driver source available at /root/adin2111_hybrid.c"
EOF
chmod +x $ROOTFS_DIR/root/build-driver.sh

# Create test script
cat > $ROOTFS_DIR/root/test-driver.sh << 'EOF'
#!/bin/sh
echo "=== ADIN2111 Driver Test ==="
echo "1. Checking module info:"
if [ -f /lib/modules/adin2111_hybrid.ko ]; then
    modinfo /lib/modules/adin2111_hybrid.ko 2>/dev/null || echo "modinfo not available"
fi

echo "2. Loading module with single_interface_mode:"
insmod /lib/modules/adin2111_hybrid.ko single_interface_mode=1 2>&1

echo "3. Checking dmesg:"
dmesg | tail -20

echo "4. Network interfaces:"
ip link show

echo "5. Module loaded:"
lsmod | grep adin
EOF
chmod +x $ROOTFS_DIR/root/test-driver.sh

# Create cpio archive
echo "Creating rootfs archive..."
cd $ROOTFS_DIR
find . | cpio -o -H newc | gzip > /home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz

echo "=== Rootfs created successfully ==="
echo "Rootfs: /home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz"
echo "Size: $(du -h /home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz | cut -f1)"
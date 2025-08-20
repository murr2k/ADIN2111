#!/bin/bash
# Build minimal ARM rootfs with busybox

set -e

BUSYBOX_VER=1.36.1
BUILDDIR=/home/murr2k/projects/ADIN2111/arm-rootfs-build
ROOTFS=/home/murr2k/projects/ADIN2111/arm-rootfs

echo "=== Building ARM Rootfs ==="

# Create build directory
mkdir -p $BUILDDIR
cd $BUILDDIR

# Download busybox if needed
if [ ! -f busybox-${BUSYBOX_VER}.tar.bz2 ]; then
    echo "Downloading busybox..."
    wget https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2
fi

# Extract
if [ ! -d busybox-${BUSYBOX_VER} ]; then
    tar xf busybox-${BUSYBOX_VER}.tar.bz2
fi

cd busybox-${BUSYBOX_VER}

# Configure for static ARM build
echo "Configuring busybox for ARM..."
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- defconfig

# Enable static linking
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config

# Build
echo "Building busybox..."
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j8

# Install to rootfs
echo "Installing to rootfs..."
rm -rf $ROOTFS
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- CONFIG_PREFIX=$ROOTFS install

# Create necessary directories
mkdir -p $ROOTFS/{dev,proc,sys,etc,tmp,var}
mkdir -p $ROOTFS/var/run

# Create essential device nodes
sudo mknod -m 666 $ROOTFS/dev/null c 1 3 2>/dev/null || true
sudo mknod -m 666 $ROOTFS/dev/console c 5 1 2>/dev/null || true
sudo mknod -m 666 $ROOTFS/dev/tty c 5 0 2>/dev/null || true

# Create minimal /etc files
cat > $ROOTFS/etc/inittab << 'EOF'
::sysinit:/etc/init.d/rcS
::respawn:-/bin/sh
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF

mkdir -p $ROOTFS/etc/init.d
cat > $ROOTFS/etc/init.d/rcS << 'EOF'
#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
echo "ARM rootfs ready"
EOF
chmod +x $ROOTFS/etc/init.d/rcS

# Create test script
cat > $ROOTFS/test-network.sh << 'EOF'
#!/bin/sh
echo "=== Network Counter Test ==="

# Bring up interface
ip link set eth0 up
sleep 1

# Check initial counters
TX_BEFORE=$(cat /sys/class/net/eth0/statistics/tx_packets)
RX_BEFORE=$(cat /sys/class/net/eth0/statistics/rx_packets)
echo "TX before: $TX_BEFORE"
echo "RX before: $RX_BEFORE"

# Configure IP
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2

# Try to ping gateway (slirp)
ping -c 3 10.0.2.2

# Check counters after
TX_AFTER=$(cat /sys/class/net/eth0/statistics/tx_packets)
RX_AFTER=$(cat /sys/class/net/eth0/statistics/rx_packets)
echo "TX after: $TX_AFTER"
echo "RX after: $RX_AFTER"

TX_DELTA=$((TX_AFTER - TX_BEFORE))
RX_DELTA=$((RX_AFTER - RX_BEFORE))

if [ $TX_DELTA -gt 0 ]; then
    echo "✅ TX_PASS: Sent $TX_DELTA packets"
else
    echo "❌ TX_FAIL: No packets sent"
fi

if [ $RX_DELTA -gt 0 ]; then
    echo "✅ RX_PASS: Received $RX_DELTA packets"
else
    echo "⚠️ RX_NONE: No packets received (expected with no backend)"
fi
EOF
chmod +x $ROOTFS/test-network.sh

# Create initramfs
echo "Creating initramfs..."
cd $ROOTFS
find . | cpio -o -H newc 2>/dev/null | gzip > /home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz

echo "✅ ARM rootfs built successfully"
echo "Location: /home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz"
echo "Size: $(du -h /home/murr2k/projects/ADIN2111/arm-rootfs.cpio.gz | cut -f1)"
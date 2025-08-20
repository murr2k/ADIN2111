#!/bin/bash
# Build minimal ARM root filesystem for ADIN2111 testing
# Uses BusyBox for minimal size with networking tools

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ROOTFS_DIR="$PROJECT_ROOT/rootfs"
BUILD_DIR="$ROOTFS_DIR/build"
ROOTFS_IMAGE="$ROOTFS_DIR/rootfs.ext4"

# Architecture settings
ARCH="arm"
CROSS_COMPILE="arm-linux-gnueabihf-"

# Versions
BUSYBOX_VERSION="1.36.1"
DROPBEAR_VERSION="2022.83"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

# Check dependencies
check_dependencies() {
    log "Checking build dependencies..."
    
    local missing_deps=()
    
    # Check for cross compiler
    if ! command -v ${CROSS_COMPILE}gcc &> /dev/null; then
        missing_deps+=("${CROSS_COMPILE}gcc (ARM cross compiler)")
    fi
    
    # Check for required tools
    for tool in make wget tar gzip cpio fakeroot; do
        if ! command -v $tool &> /dev/null; then
            missing_deps+=("$tool")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing_deps[*]}"
    fi
    
    log "All dependencies satisfied"
}

# Create directory structure
setup_directories() {
    log "Setting up directory structure..."
    
    mkdir -p "$BUILD_DIR"
    mkdir -p "$ROOTFS_DIR"
    
    # Clean previous build
    rm -rf "$BUILD_DIR"/*
    rm -f "$ROOTFS_IMAGE"
    
    log "Directory structure ready"
}

# Download and extract BusyBox
download_busybox() {
    log "Downloading BusyBox $BUSYBOX_VERSION..."
    
    cd "$BUILD_DIR"
    
    if [ ! -f "busybox-${BUSYBOX_VERSION}.tar.bz2" ]; then
        wget "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"
    fi
    
    if [ ! -d "busybox-${BUSYBOX_VERSION}" ]; then
        tar -xjf "busybox-${BUSYBOX_VERSION}.tar.bz2"
    fi
    
    log "BusyBox downloaded and extracted"
}

# Configure and build BusyBox
build_busybox() {
    log "Building BusyBox..."
    
    cd "$BUILD_DIR/busybox-${BUSYBOX_VERSION}"
    
    # Create minimal config
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} defconfig
    
    # Enable static linking
    sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    
    # Enable networking tools
    cat >> .config << EOF
CONFIG_FEATURE_IFUPDOWN_MAPPING=y
CONFIG_FEATURE_IFUPDOWN_EXTERNAL_DHCP=y
CONFIG_IFCONFIG=y
CONFIG_IFUPDOWN=y
CONFIG_INETD=y
CONFIG_IP=y
CONFIG_IPROUTE=y
CONFIG_NETSTAT=y
CONFIG_PING=y
CONFIG_PING6=y
CONFIG_ROUTE=y
CONFIG_TELNET=y
CONFIG_TELNETD=y
CONFIG_TFTP=y
CONFIG_TFTPD=y
CONFIG_WGET=y
CONFIG_ETHTOOL=y
CONFIG_TRACEROUTE=y
CONFIG_ARP=y
CONFIG_NSLOOKUP=y
CONFIG_NC=y
CONFIG_NTPD=y
EOF
    
    # Build
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} -j$(nproc)
    make ARCH=${ARCH} CROSS_COMPILE=${CROSS_COMPILE} CONFIG_PREFIX="$BUILD_DIR/rootfs_staging" install
    
    log "BusyBox built successfully"
}

# Download and build Dropbear SSH
build_dropbear() {
    log "Building Dropbear SSH server..."
    
    cd "$BUILD_DIR"
    
    if [ ! -f "dropbear-${DROPBEAR_VERSION}.tar.bz2" ]; then
        wget "https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VERSION}.tar.bz2"
    fi
    
    if [ ! -d "dropbear-${DROPBEAR_VERSION}" ]; then
        tar -xjf "dropbear-${DROPBEAR_VERSION}.tar.bz2"
    fi
    
    cd "dropbear-${DROPBEAR_VERSION}"
    
    # Configure for static linking
    ./configure --host=arm-linux-gnueabihf \
                --disable-zlib \
                --disable-lastlog \
                --disable-utmp \
                --disable-utmpx \
                --disable-wtmp \
                --disable-wtmpx \
                --disable-loginfunc \
                --disable-pututline \
                --disable-pututxline \
                LDFLAGS="-static"
    
    make PROGRAMS="dropbear dbclient dropbearkey scp" -j$(nproc)
    
    # Install to staging
    cp dropbear "$BUILD_DIR/rootfs_staging/usr/sbin/"
    cp dbclient "$BUILD_DIR/rootfs_staging/usr/bin/"
    cp dropbearkey "$BUILD_DIR/rootfs_staging/usr/bin/"
    cp scp "$BUILD_DIR/rootfs_staging/usr/bin/"
    
    log "Dropbear built successfully"
}

# Create root filesystem structure
create_rootfs() {
    log "Creating root filesystem structure..."
    
    cd "$BUILD_DIR"
    STAGING="$BUILD_DIR/rootfs_staging"
    
    # Create essential directories
    mkdir -p "$STAGING"/{dev,proc,sys,tmp,var,home,root,etc,lib,usr}
    mkdir -p "$STAGING"/var/{run,log,tmp}
    mkdir -p "$STAGING"/etc/{init.d,network}
    mkdir -p "$STAGING"/home/root
    
    # Create device nodes
    sudo mknod "$STAGING/dev/console" c 5 1
    sudo mknod "$STAGING/dev/null" c 1 3
    sudo mknod "$STAGING/dev/zero" c 1 5
    sudo mknod "$STAGING/dev/random" c 1 8
    sudo mknod "$STAGING/dev/urandom" c 1 9
    sudo mknod "$STAGING/dev/tty" c 5 0
    sudo mknod "$STAGING/dev/ttyAMA0" c 204 64
    
    # Create init script
    cat > "$STAGING/etc/init.d/rcS" << 'EOF'
#!/bin/sh

# Mount filesystems
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t tmpfs tmpfs /tmp
mount -t tmpfs tmpfs /var

# Create essential directories
mkdir -p /var/run /var/log /var/tmp

# Set hostname
hostname adin2111-test

# Configure network interfaces
echo "Setting up network interfaces..."
ip link set lo up

# Look for eth0 and eth1 (ADIN2111 ports)
for i in 0 1; do
    if ip link show eth$i > /dev/null 2>&1; then
        echo "Configuring eth$i..."
        ip link set eth$i up
        ip addr add 192.168.1.$((10+i))/24 dev eth$i
    fi
done

# Add default route via eth0 if available
if ip link show eth0 > /dev/null 2>&1; then
    ip route add default via 192.168.1.1 dev eth0
fi

echo "Network configuration complete"

# Start services
echo "Starting services..."

# Generate SSH host keys if not present
if [ ! -f /etc/dropbear_rsa_host_key ]; then
    dropbearkey -t rsa -f /etc/dropbear_rsa_host_key
fi

# Start SSH daemon
dropbear -p 22 -r /etc/dropbear_rsa_host_key

echo "Boot complete. Welcome to ADIN2111 test system!"
echo "IP addresses:"
ip addr show | grep "inet "

# Start shell
exec /bin/sh
EOF
    
    chmod +x "$STAGING/etc/init.d/rcS"
    
    # Create init symlink
    ln -sf /etc/init.d/rcS "$STAGING/init"
    
    # Create passwd file
    cat > "$STAGING/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF
    
    # Create group file
    cat > "$STAGING/etc/group" << EOF
root:x:0:
EOF
    
    # Create network test scripts
    cat > "$STAGING/usr/bin/test-network" << 'EOF'
#!/bin/sh
echo "=== ADIN2111 Network Test ==="
echo "Available interfaces:"
ip link show

echo -e "\nInterface status:"
for i in 0 1; do
    if ip link show eth$i > /dev/null 2>&1; then
        echo "eth$i: $(ip link show eth$i | grep -o 'state [A-Z]*' | cut -d' ' -f2)"
        ip addr show eth$i | grep "inet "
    fi
done

echo -e "\nPing test:"
ping -c 3 192.168.1.1 2>/dev/null && echo "Gateway reachable" || echo "Gateway not reachable"

echo -e "\nEthtool information:"
for i in 0 1; do
    if ip link show eth$i > /dev/null 2>&1; then
        echo "eth$i:"
        ethtool eth$i 2>/dev/null | head -10
    fi
done
EOF
    
    chmod +x "$STAGING/usr/bin/test-network"
    
    # Set proper ownership
    sudo chown -R root:root "$STAGING"
    
    log "Root filesystem structure created"
}

# Create ext4 filesystem image
create_image() {
    log "Creating ext4 filesystem image..."
    
    # Create 32MB image
    dd if=/dev/zero of="$ROOTFS_IMAGE" bs=1M count=32
    
    # Format as ext4
    mkfs.ext4 -F "$ROOTFS_IMAGE"
    
    # Mount and copy files
    MOUNT_POINT=$(mktemp -d)
    sudo mount "$ROOTFS_IMAGE" "$MOUNT_POINT"
    
    sudo cp -a "$BUILD_DIR/rootfs_staging"/* "$MOUNT_POINT/"
    
    # Unmount
    sudo umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    
    log "Root filesystem image created: $ROOTFS_IMAGE"
}

# Main execution
main() {
    log "Building minimal ARM root filesystem for ADIN2111 testing"
    
    check_dependencies
    setup_directories
    download_busybox
    build_busybox
    build_dropbear
    create_rootfs
    create_image
    
    log "Root filesystem build complete!"
    log "Image location: $ROOTFS_IMAGE"
    log "Size: $(ls -lh "$ROOTFS_IMAGE" | awk '{print $5}')"
    
    echo
    echo "To test with QEMU:"
    echo "  qemu-system-arm -M virt -m 256M -kernel zImage -append 'root=/dev/vda rw console=ttyAMA0' -drive file=$ROOTFS_IMAGE,format=raw,id=rootfs -device virtio-blk-device,drive=rootfs -nographic"
}

# Handle script arguments
case "${1:-}" in
    clean)
        log "Cleaning build directory..."
        rm -rf "$BUILD_DIR"
        rm -f "$ROOTFS_IMAGE"
        log "Clean complete"
        ;;
    *)
        main
        ;;
esac
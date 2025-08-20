#!/bin/bash
# Build minimal Alpine Linux root filesystem for ADIN2111 testing
# Faster and smaller than building from source

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ROOTFS_DIR="$PROJECT_ROOT/rootfs"
BUILD_DIR="$ROOTFS_DIR/build"
ROOTFS_IMAGE="$ROOTFS_DIR/rootfs.ext4"

# Alpine settings
ALPINE_VERSION="3.18"
ALPINE_ARCH="armhf"
ALPINE_MIRROR="http://dl-cdn.alpinelinux.org/alpine"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
    
    for tool in wget tar cpio qemu-arm-static; do
        if ! command -v $tool &> /dev/null; then
            missing_deps+=("$tool")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing_deps[*]}"
    fi
    
    log "All dependencies satisfied"
}

# Setup directories
setup_directories() {
    log "Setting up directory structure..."
    
    mkdir -p "$BUILD_DIR"
    mkdir -p "$ROOTFS_DIR"
    
    # Clean previous build
    rm -rf "$BUILD_DIR"/*
    rm -f "$ROOTFS_IMAGE"
    
    log "Directory structure ready"
}

# Download Alpine Linux mini root filesystem
download_alpine() {
    log "Downloading Alpine Linux $ALPINE_VERSION for $ALPINE_ARCH..."
    
    cd "$BUILD_DIR"
    
    local alpine_file="alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"
    local alpine_url="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${alpine_file}"
    
    if [ ! -f "$alpine_file" ]; then
        wget "$alpine_url"
    fi
    
    # Extract
    mkdir -p rootfs
    cd rootfs
    tar -xzf "../$alpine_file"
    
    log "Alpine Linux downloaded and extracted"
}

# Configure Alpine Linux
configure_alpine() {
    log "Configuring Alpine Linux..."
    
    local rootfs="$BUILD_DIR/rootfs"
    
    # Copy qemu static for chroot
    sudo cp /usr/bin/qemu-arm-static "$rootfs/usr/bin/"
    
    # Setup DNS
    echo "nameserver 8.8.8.8" | sudo tee "$rootfs/etc/resolv.conf" > /dev/null
    
    # Configure repositories
    cat << EOF | sudo tee "$rootfs/etc/apk/repositories" > /dev/null
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF
    
    # Create chroot script
    cat << 'EOF' > "$BUILD_DIR/setup_alpine.sh"
#!/bin/sh
set -e

# Update package index
apk update

# Install essential packages
apk add --no-cache \
    dropbear \
    dropbear-ssh \
    ethtool \
    iproute2 \
    iputils \
    net-tools \
    tcpdump \
    iperf3 \
    busybox-extras \
    nano \
    htop

# Setup services
rc-update add dropbear default

# Create network test script
cat > /usr/bin/test-network << 'SCRIPT_EOF'
#!/bin/sh
echo "=== ADIN2111 Network Test ==="
echo "Available interfaces:"
ip link show

echo -e "\nInterface status:"
for i in 0 1; do
    if ip link show eth$i > /dev/null 2>&1; then
        echo "eth$i: $(ip link show eth$i | grep -o 'state [A-Z]*' | cut -d' ' -f2)"
        ip addr show eth$i | grep "inet " || echo "  No IP address"
    fi
done

echo -e "\nPing test (if gateway available):"
if ip route | grep default > /dev/null; then
    gateway=$(ip route | grep default | awk '{print $3}')
    ping -c 3 $gateway 2>/dev/null && echo "Gateway $gateway reachable" || echo "Gateway $gateway not reachable"
else
    echo "No default gateway configured"
fi

echo -e "\nEthtool information:"
for i in 0 1; do
    if ip link show eth$i > /dev/null 2>&1; then
        echo "eth$i:"
        ethtool eth$i 2>/dev/null | head -10 || echo "  ethtool failed"
    fi
done

echo -e "\nARP table:"
arp -a 2>/dev/null || echo "No ARP entries"

echo -e "\nRouting table:"
ip route show
SCRIPT_EOF

chmod +x /usr/bin/test-network

# Create ADIN2111 specific network configuration
cat > /etc/init.d/adin2111-network << 'INIT_EOF'
#!/sbin/openrc-run

description="ADIN2111 Network Configuration"

depend() {
    need localmount
    after bootmisc
}

start() {
    ebegin "Configuring ADIN2111 network interfaces"
    
    # Configure eth0 and eth1 if they exist
    for i in 0 1; do
        if [ -e "/sys/class/net/eth$i" ]; then
            ip link set eth$i up
            ip addr add 192.168.1.$((10+i))/24 dev eth$i 2>/dev/null || true
            einfo "Configured eth$i with IP 192.168.1.$((10+i))"
        fi
    done
    
    # Set default route via eth0 if available
    if [ -e "/sys/class/net/eth0" ]; then
        ip route add default via 192.168.1.1 dev eth0 2>/dev/null || true
    fi
    
    eend $?
}

stop() {
    ebegin "Stopping ADIN2111 network configuration"
    eend 0
}
INIT_EOF

chmod +x /etc/init.d/adin2111-network
rc-update add adin2111-network default

# Set hostname
echo "adin2111-test" > /etc/hostname

# Configure getty on ttyAMA0 (ARM UART)
sed -i 's/tty1/ttyAMA0/' /etc/inittab

# Enable root login
passwd -d root

# Clean package cache
rm -rf /var/cache/apk/*

echo "Alpine configuration complete"
EOF
    
    chmod +x "$BUILD_DIR/setup_alpine.sh"
    
    # Run configuration in chroot
    sudo chroot "$rootfs" /setup_alpine.sh
    
    # Clean up
    sudo rm "$rootfs/usr/bin/qemu-arm-static"
    sudo rm "$rootfs/setup_alpine.sh"
    
    log "Alpine Linux configured"
}

# Create ext4 filesystem image
create_image() {
    log "Creating ext4 filesystem image..."
    
    local rootfs="$BUILD_DIR/rootfs"
    
    # Calculate required size (with 20% margin)
    local size_kb=$(sudo du -sk "$rootfs" | awk '{print int($1 * 1.2)}')
    local size_mb=$((size_kb / 1024 + 10))  # Add 10MB margin
    
    # Minimum 16MB
    if [ $size_mb -lt 16 ]; then
        size_mb=16
    fi
    
    log "Creating ${size_mb}MB image..."
    
    # Create image
    dd if=/dev/zero of="$ROOTFS_IMAGE" bs=1M count=$size_mb
    
    # Format as ext4
    mkfs.ext4 -F "$ROOTFS_IMAGE"
    
    # Mount and copy files
    local mount_point=$(mktemp -d)
    sudo mount "$ROOTFS_IMAGE" "$mount_point"
    
    sudo cp -a "$rootfs"/* "$mount_point/"
    
    # Set proper permissions
    sudo chown -R root:root "$mount_point"
    
    # Unmount
    sudo umount "$mount_point"
    rmdir "$mount_point"
    
    log "Root filesystem image created: $ROOTFS_IMAGE"
    log "Size: $(ls -lh "$ROOTFS_IMAGE" | awk '{print $5}')"
}

# Create QEMU test script
create_test_script() {
    log "Creating QEMU test script..."
    
    cat > "$ROOTFS_DIR/test-rootfs.sh" << EOF
#!/bin/bash
# Test the Alpine root filesystem with QEMU

ROOTFS_IMAGE="$ROOTFS_IMAGE"
PROJECT_ROOT="$PROJECT_ROOT"

# Check if kernel exists
if [ ! -f "\$PROJECT_ROOT/linux/arch/arm/boot/zImage" ]; then
    echo "Error: Kernel not found at \$PROJECT_ROOT/linux/arch/arm/boot/zImage"
    echo "Please build the kernel first"
    exit 1
fi

echo "Starting QEMU with Alpine root filesystem..."
echo "Login as root (no password)"
echo "Run 'test-network' to check ADIN2111 functionality"
echo "Press Ctrl+A, X to exit QEMU"
echo

qemu-system-arm \\
    -M virt \\
    -cpu cortex-a15 \\
    -m 256M \\
    -kernel "\$PROJECT_ROOT/linux/arch/arm/boot/zImage" \\
    -append "root=/dev/vda rw console=ttyAMA0 rootwait" \\
    -drive file="\$ROOTFS_IMAGE",format=raw,id=rootfs \\
    -device virtio-blk-device,drive=rootfs \\
    -netdev user,id=net0 \\
    -device virtio-net-device,netdev=net0 \\
    -nographic
EOF
    
    chmod +x "$ROOTFS_DIR/test-rootfs.sh"
    
    log "Test script created: $ROOTFS_DIR/test-rootfs.sh"
}

# Main execution
main() {
    log "Building minimal Alpine Linux root filesystem for ADIN2111 testing"
    
    check_dependencies
    setup_directories
    download_alpine
    configure_alpine
    create_image
    create_test_script
    
    log "Root filesystem build complete!"
    log "Image location: $ROOTFS_IMAGE"
    log "Test script: $ROOTFS_DIR/test-rootfs.sh"
    
    echo
    echo "To test the root filesystem:"
    echo "  $ROOTFS_DIR/test-rootfs.sh"
    echo
    echo "Or manually with QEMU:"
    echo "  qemu-system-arm -M virt -m 256M -kernel <kernel> -append 'root=/dev/vda rw console=ttyAMA0 rootwait' -drive file=$ROOTFS_IMAGE,format=raw,id=rootfs -device virtio-blk-device,drive=rootfs -nographic"
}

# Handle script arguments
case "${1:-}" in
    clean)
        log "Cleaning build directory..."
        rm -rf "$BUILD_DIR"
        rm -f "$ROOTFS_IMAGE"
        rm -f "$ROOTFS_DIR/test-rootfs.sh"
        log "Clean complete"
        ;;
    *)
        main
        ;;
esac
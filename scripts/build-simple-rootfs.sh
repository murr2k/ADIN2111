#!/bin/bash
# Build simple root filesystem for ADIN2111 testing
# No chroot or complex dependencies required

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ROOTFS_DIR="$PROJECT_ROOT/rootfs"
BUILD_DIR="$ROOTFS_DIR/build"
ROOTFS_IMAGE="$ROOTFS_DIR/rootfs.ext4"

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
    
    for tool in cpio tar gzip; do
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

# Create minimal root filesystem structure
create_minimal_rootfs() {
    log "Creating minimal root filesystem..."
    
    local rootfs="$BUILD_DIR/rootfs"
    
    # Create directory structure
    mkdir -p "$rootfs"/{bin,sbin,usr/{bin,sbin},etc,dev,proc,sys,tmp,var,home,root}
    mkdir -p "$rootfs"/var/{run,log,tmp}
    mkdir -p "$rootfs"/etc/{init.d,network}
    mkdir -p "$rootfs"/lib
    
    # Create essential device nodes (if possible)
    if [ -w "$rootfs/dev" ]; then
        # Try to create device nodes without sudo
        touch "$rootfs/dev/console"
        touch "$rootfs/dev/null"
        touch "$rootfs/dev/zero"
        touch "$rootfs/dev/tty"
        touch "$rootfs/dev/ttyAMA0"
    fi
    
    # Create init script
    cat > "$rootfs/init" << 'EOF'
#!/bin/sh

# Mount essential filesystems
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

# Create essential directories
mkdir -p /var/run /var/log /var/tmp

# Set hostname
hostname adin2111-test

echo "=== ADIN2111 Test System ==="
echo "Minimal root filesystem loaded"

# Configure basic networking
echo "Setting up basic networking..."

# Set loopback up
ip link set lo up 2>/dev/null || true

# Look for ADIN2111 interfaces (eth0, eth1)
for i in 0 1; do
    if [ -e "/sys/class/net/eth$i" ]; then
        echo "Found eth$i, configuring..."
        ip link set eth$i up 2>/dev/null || true
        ip addr add 192.168.1.$((10+i))/24 dev eth$i 2>/dev/null || true
        echo "  IP: 192.168.1.$((10+i))/24"
    fi
done

# Add default route via eth0 if available
if [ -e "/sys/class/net/eth0" ]; then
    ip route add default via 192.168.1.1 dev eth0 2>/dev/null || true
fi

echo
echo "Network interfaces:"
ip link show 2>/dev/null || echo "ip command not available"

echo
echo "Available commands:"
echo "  ls, cat, echo, mount, umount, ip (if available)"
echo "  /test-network - run network tests"
echo
echo "Type 'exit' to shutdown"

# Start a basic shell
exec /bin/sh
EOF
    
    chmod +x "$rootfs/init"
    
    # Create network test script
    cat > "$rootfs/test-network" << 'EOF'
#!/bin/sh
echo "=== ADIN2111 Network Test ==="

echo "Available network interfaces:"
if command -v ip >/dev/null 2>&1; then
    ip link show
else
    echo "ip command not available, trying ifconfig..."
    ifconfig -a 2>/dev/null || echo "No network tools available"
fi

echo
echo "Interface status:"
for i in 0 1; do
    if [ -e "/sys/class/net/eth$i" ]; then
        echo "eth$i: present"
        if [ -f "/sys/class/net/eth$i/operstate" ]; then
            state=$(cat /sys/class/net/eth$i/operstate)
            echo "  State: $state"
        fi
        if [ -f "/sys/class/net/eth$i/address" ]; then
            mac=$(cat /sys/class/net/eth$i/address)
            echo "  MAC: $mac"
        fi
    else
        echo "eth$i: not found"
    fi
done

echo
echo "Routing table:"
if command -v ip >/dev/null 2>&1; then
    ip route show 2>/dev/null || echo "No routes"
else
    route -n 2>/dev/null || echo "route command not available"
fi

echo
echo "Testing connectivity..."
if command -v ping >/dev/null 2>&1; then
    if ip route | grep default >/dev/null 2>&1; then
        gateway=$(ip route | grep default | awk '{print $3}' | head -1)
        echo "Pinging gateway $gateway..."
        ping -c 3 $gateway || echo "Gateway not reachable"
    else
        echo "No default gateway configured"
    fi
else
    echo "ping command not available"
fi
EOF
    
    chmod +x "$rootfs/test-network"
    
    # Create basic shell script utilities
    cat > "$rootfs/bin/sh" << 'EOF'
#!/bin/sh
# Minimal shell replacement
echo "Minimal shell loaded (built-in commands only)"
echo "Available: cd, pwd, echo, exit, help"

while true; do
    printf "adin2111-test# "
    read -r cmd args
    
    case "$cmd" in
        "help")
            echo "Built-in commands:"
            echo "  help - show this help"
            echo "  pwd - print working directory"
            echo "  cd <dir> - change directory"
            echo "  echo <text> - print text"
            echo "  ls - list files (basic)"
            echo "  cat <file> - show file contents"
            echo "  /test-network - run network tests"
            echo "  exit - exit shell"
            ;;
        "pwd")
            pwd
            ;;
        "cd")
            cd $args 2>/dev/null || echo "cd: cannot access '$args'"
            ;;
        "echo")
            echo $args
            ;;
        "ls")
            if [ -n "$args" ]; then
                ls -la $args 2>/dev/null || echo "ls: cannot access '$args'"
            else
                ls -la
            fi
            ;;
        "cat")
            if [ -f "$args" ]; then
                cat $args
            else
                echo "cat: $args: No such file"
            fi
            ;;
        "exit")
            echo "Goodbye!"
            exit 0
            ;;
        "")
            # Empty command, do nothing
            ;;
        *)
            if [ -x "$cmd" ]; then
                $cmd $args
            elif [ -x "/bin/$cmd" ]; then
                /bin/$cmd $args
            elif [ -x "/usr/bin/$cmd" ]; then
                /usr/bin/$cmd $args
            else
                echo "$cmd: command not found"
                echo "Type 'help' for available commands"
            fi
            ;;
    esac
done
EOF
    
    chmod +x "$rootfs/bin/sh"
    
    # Create basic passwd file
    cat > "$rootfs/etc/passwd" << EOF
root:x:0:0:root:/root:/bin/sh
EOF
    
    # Create basic group file
    cat > "$rootfs/etc/group" << EOF
root:x:0:
EOF
    
    # Create issue file
    cat > "$rootfs/etc/issue" << EOF
ADIN2111 Test System
Minimal Root Filesystem

Login: root (no password)

EOF
    
    log "Minimal root filesystem created"
}

# Create ext4 filesystem image
create_image() {
    log "Creating ext4 filesystem image..."
    
    local rootfs="$BUILD_DIR/rootfs"
    
    # Create 8MB image (minimal size)
    local size_mb=8
    
    log "Creating ${size_mb}MB image..."
    
    # Create image
    dd if=/dev/zero of="$ROOTFS_IMAGE" bs=1M count=$size_mb 2>/dev/null
    
    # Format as ext4
    mkfs.ext4 -F "$ROOTFS_IMAGE" >/dev/null 2>&1
    
    # Try to mount and copy files
    local mount_point=$(mktemp -d)
    
    if sudo mount "$ROOTFS_IMAGE" "$mount_point" 2>/dev/null; then
        sudo cp -a "$rootfs"/* "$mount_point/"
        sudo chown -R root:root "$mount_point"
        sudo umount "$mount_point"
        rmdir "$mount_point"
        log "Root filesystem image created with sudo"
    else
        # Fallback: create initramfs instead
        warn "Cannot mount image, creating initramfs instead..."
        cd "$rootfs"
        find . | cpio -o -H newc | gzip > "$ROOTFS_DIR/initramfs.cpio.gz"
        rm -f "$ROOTFS_IMAGE"
        log "Initramfs created: $ROOTFS_DIR/initramfs.cpio.gz"
        return
    fi
    
    log "Root filesystem image created: $ROOTFS_IMAGE"
    log "Size: $(ls -lh "$ROOTFS_IMAGE" | awk '{print $5}')"
}

# Create test scripts
create_test_scripts() {
    log "Creating test scripts..."
    
    # QEMU test script for ext4 image
    if [ -f "$ROOTFS_IMAGE" ]; then
        cat > "$ROOTFS_DIR/test-rootfs.sh" << EOF
#!/bin/bash
# Test the root filesystem with QEMU

ROOTFS_IMAGE="$ROOTFS_IMAGE"
PROJECT_ROOT="$PROJECT_ROOT"

echo "Starting QEMU with minimal root filesystem..."
echo "Login as root (no password)"
echo "Run '/test-network' to check ADIN2111 functionality"
echo "Press Ctrl+A, X to exit QEMU"
echo

qemu-system-arm \\
    -M virt \\
    -cpu cortex-a15 \\
    -m 128M \\
    -kernel "\$PROJECT_ROOT/linux/arch/arm/boot/zImage" \\
    -append "root=/dev/vda rw console=ttyAMA0 rootwait" \\
    -drive file="\$ROOTFS_IMAGE",format=raw,id=rootfs \\
    -device virtio-blk-device,drive=rootfs \\
    -nographic
EOF
    fi
    
    # QEMU test script for initramfs
    if [ -f "$ROOTFS_DIR/initramfs.cpio.gz" ]; then
        cat > "$ROOTFS_DIR/test-initramfs.sh" << EOF
#!/bin/bash
# Test the initramfs with QEMU

INITRAMFS="$ROOTFS_DIR/initramfs.cpio.gz"
PROJECT_ROOT="$PROJECT_ROOT"

echo "Starting QEMU with initramfs..."
echo "System will boot directly into the test environment"
echo "Run '/test-network' to check ADIN2111 functionality"
echo "Press Ctrl+A, X to exit QEMU"
echo

qemu-system-arm \\
    -M virt \\
    -cpu cortex-a15 \\
    -m 128M \\
    -kernel "\$PROJECT_ROOT/linux/arch/arm/boot/zImage" \\
    -initrd "\$INITRAMFS" \\
    -append "console=ttyAMA0" \\
    -nographic
EOF
        chmod +x "$ROOTFS_DIR/test-initramfs.sh"
    fi
    
    if [ -f "$ROOTFS_DIR/test-rootfs.sh" ]; then
        chmod +x "$ROOTFS_DIR/test-rootfs.sh"
    fi
    
    log "Test scripts created"
}

# Main execution
main() {
    log "Building minimal root filesystem for ADIN2111 testing"
    
    check_dependencies
    setup_directories
    create_minimal_rootfs
    create_image
    create_test_scripts
    
    log "Root filesystem build complete!"
    
    if [ -f "$ROOTFS_IMAGE" ]; then
        log "Image location: $ROOTFS_IMAGE"
        log "Test script: $ROOTFS_DIR/test-rootfs.sh"
    fi
    
    if [ -f "$ROOTFS_DIR/initramfs.cpio.gz" ]; then
        log "Initramfs location: $ROOTFS_DIR/initramfs.cpio.gz"
        log "Test script: $ROOTFS_DIR/test-initramfs.sh"
    fi
    
    echo
    echo "To test the root filesystem, run:"
    if [ -f "$ROOTFS_DIR/test-rootfs.sh" ]; then
        echo "  $ROOTFS_DIR/test-rootfs.sh"
    fi
    if [ -f "$ROOTFS_DIR/test-initramfs.sh" ]; then
        echo "  $ROOTFS_DIR/test-initramfs.sh"
    fi
}

# Handle script arguments
case "${1:-}" in
    clean)
        log "Cleaning build directory..."
        rm -rf "$BUILD_DIR"
        rm -f "$ROOTFS_IMAGE"
        rm -f "$ROOTFS_DIR/initramfs.cpio.gz"
        rm -f "$ROOTFS_DIR/test-rootfs.sh"
        rm -f "$ROOTFS_DIR/test-initramfs.sh"
        log "Clean complete"
        ;;
    *)
        main
        ;;
esac
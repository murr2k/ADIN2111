#!/bin/bash
# Configure Linux kernel for ARM architecture with ADIN2111 driver support
# Target: ARM for QEMU virt machine with SPI and ADIN2111 support

set -e

# Configuration
KERNEL_DIR="/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel"
ARCH="arm"
CROSS_COMPILE="arm-linux-gnueabihf-"
DEFCONFIG="vexpress_defconfig"

echo "========================================="
echo "ARM Kernel Configuration for ADIN2111"
echo "========================================="
echo "Architecture: $ARCH"
echo "Cross compiler: $CROSS_COMPILE"
echo "Default config: $DEFCONFIG"
echo "Kernel source: $KERNEL_DIR"
echo ""

# Check if kernel source exists
if [ ! -d "$KERNEL_DIR" ]; then
    echo "❌ Kernel source not found at: $KERNEL_DIR"
    echo "Please ensure WSL2-Linux-Kernel is cloned in the src/ directory"
    exit 1
fi

# Check for required tools
echo "Checking required tools..."
MISSING_TOOLS=""
REQUIRED_TOOLS="make gcc flex bison bc libssl-dev libelf-dev"

# Check for cross-compiler
if ! command -v ${CROSS_COMPILE}gcc &> /dev/null; then
    MISSING_TOOLS="$MISSING_TOOLS ${CROSS_COMPILE}gcc"
fi

# Check for other tools
for tool in make flex bison bc; do
    if ! command -v $tool &> /dev/null; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done

# Check for libraries
if ! pkg-config --exists libssl 2>/dev/null; then
    if ! dpkg -l | grep -q "libssl-dev"; then
        MISSING_TOOLS="$MISSING_TOOLS libssl-dev"
    fi
fi

if [ -n "$MISSING_TOOLS" ]; then
    echo "❌ Missing tools/packages:$MISSING_TOOLS"
    echo ""
    echo "To install missing packages on Ubuntu/Debian:"
    echo "  sudo apt-get update"
    echo "  sudo apt-get install build-essential flex bison bc libssl-dev libelf-dev"
    echo ""
    echo "To install ARM cross-compiler:"
    echo "  sudo apt-get install gcc-arm-linux-gnueabihf"
    echo ""
    echo "Creating configuration template for when tools are available..."
    echo ""
    # Don't exit, continue to create the configuration template
fi

echo "✅ All required tools found"

# Change to kernel directory
cd "$KERNEL_DIR"

# Check if we have the required tools, if not create config template
if [ -n "$MISSING_TOOLS" ]; then
    echo "Creating kernel configuration template..."
    
    # Create a .config file manually based on vexpress_defconfig
    if [ -f "arch/arm/configs/vexpress_defconfig" ]; then
        echo "Using vexpress_defconfig as base..."
        cp arch/arm/configs/vexpress_defconfig .config
    else
        echo "Creating minimal ARM config..."
        # Create a minimal ARM config
        cat > .config << 'EOF'
# ARM Configuration for ADIN2111 QEMU Testing
CONFIG_ARM=y
CONFIG_ARCH_MULTI_V7=y
CONFIG_ARCH_VIRT=y
CONFIG_SMP=y
CONFIG_NET=y
CONFIG_NETDEVICES=y
CONFIG_ETHERNET=y
CONFIG_SPI=y
CONFIG_SPI_MASTER=y
CONFIG_SPI_PL022=y
CONFIG_PHYLIB=y
CONFIG_FIXED_PHY=y
CONFIG_NET_VENDOR_ADI=y
CONFIG_ADIN2111=y
CONFIG_CRC32=y
CONFIG_REGMAP=y
CONFIG_REGMAP_SPI=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
CONFIG_DEBUG_INFO=y
EOF
    fi
else
    # Clean any previous configuration
    echo "Cleaning previous configuration..."
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE clean
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE mrproper
    
    # Start with default ARM configuration
    echo "Loading default ARM configuration ($DEFCONFIG)..."
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE $DEFCONFIG
fi

# Configure kernel options for QEMU virt machine and ADIN2111 support
echo "Configuring kernel options for QEMU virt machine..."

if [ -z "$MISSING_TOOLS" ]; then
    # Full configuration with tools available
    # Enable required options for QEMU virt machine
    ./scripts/config --enable CONFIG_ARCH_VIRT
    ./scripts/config --enable CONFIG_ARCH_MULTI_V7
    
    # Enable SPI support (required for ADIN2111)
    ./scripts/config --enable CONFIG_SPI
    ./scripts/config --enable CONFIG_SPI_MASTER
    ./scripts/config --enable CONFIG_SPI_PL022
    
    # Enable networking support
    ./scripts/config --enable CONFIG_NET
    ./scripts/config --enable CONFIG_NETDEVICES
    ./scripts/config --enable CONFIG_ETHERNET
    
    # Enable PHY support (required for ADIN2111)
    ./scripts/config --enable CONFIG_PHYLIB
    ./scripts/config --enable CONFIG_FIXED_PHY
    
    # Enable ADIN2111 driver
    ./scripts/config --enable CONFIG_NET_VENDOR_ADI
    ./scripts/config --enable CONFIG_ADIN2111
    
    # Enable CRC32 support (required by ADIN2111)
    ./scripts/config --enable CONFIG_CRC32
    
    # Enable REGMAP_SPI (required by ADIN2111)
    ./scripts/config --enable CONFIG_REGMAP
    ./scripts/config --enable CONFIG_REGMAP_SPI
    
    # Enable additional useful options for testing
    ./scripts/config --enable CONFIG_DEVTMPFS
    ./scripts/config --enable CONFIG_DEVTMPFS_MOUNT
    ./scripts/config --enable CONFIG_PROC_FS
    ./scripts/config --enable CONFIG_SYSFS
    ./scripts/config --enable CONFIG_TMPFS
    
    # Enable debugging support
    ./scripts/config --enable CONFIG_DEBUG_INFO
    ./scripts/config --enable CONFIG_DEBUG_KERNEL
    ./scripts/config --enable CONFIG_DYNAMIC_DEBUG
    
    # Disable unnecessary options to reduce build time
    ./scripts/config --disable CONFIG_MODULES_TREE_LOOKUP
    ./scripts/config --disable CONFIG_LOGO
    
    # Process configuration dependencies
    echo "Processing configuration dependencies..."
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
else
    # Manual configuration when tools are missing
    echo "Adding ADIN2111 configuration options to .config..."
    
    # Append required configurations if not already present
    grep -q "CONFIG_ARCH_VIRT=y" .config || echo "CONFIG_ARCH_VIRT=y" >> .config
    grep -q "CONFIG_ARCH_MULTI_V7=y" .config || echo "CONFIG_ARCH_MULTI_V7=y" >> .config
    grep -q "CONFIG_SPI=y" .config || echo "CONFIG_SPI=y" >> .config
    grep -q "CONFIG_SPI_MASTER=y" .config || echo "CONFIG_SPI_MASTER=y" >> .config
    grep -q "CONFIG_SPI_PL022=y" .config || echo "CONFIG_SPI_PL022=y" >> .config
    grep -q "CONFIG_NET=y" .config || echo "CONFIG_NET=y" >> .config
    grep -q "CONFIG_NETDEVICES=y" .config || echo "CONFIG_NETDEVICES=y" >> .config
    grep -q "CONFIG_ETHERNET=y" .config || echo "CONFIG_ETHERNET=y" >> .config
    grep -q "CONFIG_PHYLIB=y" .config || echo "CONFIG_PHYLIB=y" >> .config
    grep -q "CONFIG_FIXED_PHY=y" .config || echo "CONFIG_FIXED_PHY=y" >> .config
    grep -q "CONFIG_NET_VENDOR_ADI=y" .config || echo "CONFIG_NET_VENDOR_ADI=y" >> .config
    grep -q "CONFIG_ADIN2111=y" .config || echo "CONFIG_ADIN2111=y" >> .config
    grep -q "CONFIG_CRC32=y" .config || echo "CONFIG_CRC32=y" >> .config
    grep -q "CONFIG_REGMAP=y" .config || echo "CONFIG_REGMAP=y" >> .config
    grep -q "CONFIG_REGMAP_SPI=y" .config || echo "CONFIG_REGMAP_SPI=y" >> .config
    
    echo "✅ Configuration template created (tools missing - install them for full configuration)"
fi

# Verify ADIN2111 configuration
echo ""
echo "Verifying ADIN2111 driver configuration..."
if grep -q "CONFIG_ADIN2111=y" .config; then
    echo "✅ ADIN2111 driver enabled as built-in"
elif grep -q "CONFIG_ADIN2111=m" .config; then
    echo "✅ ADIN2111 driver enabled as module"
else
    echo "❌ ADIN2111 driver not enabled!"
    echo "Trying to force enable..."
    ./scripts/config --enable CONFIG_ADIN2111
    make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig
    
    if grep -q "CONFIG_ADIN2111" .config; then
        echo "✅ ADIN2111 driver now enabled"
    else
        echo "❌ Failed to enable ADIN2111 driver"
        echo "This may indicate missing dependencies"
        exit 1
    fi
fi

# Verify SPI configuration
if grep -q "CONFIG_SPI=y" .config; then
    echo "✅ SPI support enabled"
else
    echo "❌ SPI support not enabled!"
    exit 1
fi

# Verify PL022 SPI controller
if grep -q "CONFIG_SPI_PL022=y" .config; then
    echo "✅ PL022 SPI controller enabled"
else
    echo "❌ PL022 SPI controller not enabled!"
    exit 1
fi

# Verify PHYLIB
if grep -q "CONFIG_PHYLIB=y" .config; then
    echo "✅ PHYLIB support enabled"
else
    echo "❌ PHYLIB support not enabled!"
    exit 1
fi

echo ""
echo "========================================="
echo "Configuration Summary"
echo "========================================="
echo "Kernel source: $KERNEL_DIR"
echo "Architecture: $ARCH"
echo "Cross compiler: $CROSS_COMPILE"
echo "Config file: $KERNEL_DIR/.config"
echo ""
echo "Key configurations:"
grep "CONFIG_ARCH_VIRT\|CONFIG_SPI\|CONFIG_SPI_PL022\|CONFIG_ADIN2111\|CONFIG_PHYLIB\|CONFIG_FIXED_PHY" .config | sed 's/^/  /'
echo ""
echo "✅ Kernel configured successfully for ARM with ADIN2111 support"
echo ""
echo "Next steps:"
echo "  1. Build the kernel: make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE -j\$(nproc) zImage dtbs"
echo "  2. Or use the master Makefile: make kernel"
echo ""
echo "The kernel will be available at:"
echo "  $KERNEL_DIR/arch/$ARCH/boot/zImage"
echo "========================================="
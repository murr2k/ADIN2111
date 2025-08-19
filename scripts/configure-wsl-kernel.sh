#!/bin/bash
# Configure WSL2 kernel source for module building
# Requires: flex bison libelf-dev

set -e

KERNEL_DIR="$HOME/projects/ADIN2111/src/WSL2-Linux-Kernel"

echo "========================================="
echo "WSL2 Kernel Configuration for ADIN2111"
echo "========================================="

# Check if kernel source exists
if [ ! -d "$KERNEL_DIR" ]; then
    echo "❌ Kernel source not found at: $KERNEL_DIR"
    echo "Please clone: git clone https://github.com/microsoft/WSL2-Linux-Kernel.git"
    exit 1
fi

cd "$KERNEL_DIR"

# Check for required tools
echo "Checking required tools..."
MISSING_TOOLS=""
for tool in flex bison gcc make; do
    if ! command -v $tool &> /dev/null; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done

if [ -n "$MISSING_TOOLS" ]; then
    echo "❌ Missing tools:$MISSING_TOOLS"
    echo "Please install with: sudo apt-get install flex bison build-essential libelf-dev"
    exit 1
fi

echo "✅ All required tools found"

# Use running kernel config if available
if [ -f /proc/config.gz ]; then
    echo "Extracting running kernel configuration..."
    zcat /proc/config.gz > .config
    echo "✅ Extracted config from /proc/config.gz"
elif [ -f arch/x86/configs/config-wsl ]; then
    echo "Using WSL default configuration..."
    cp arch/x86/configs/config-wsl .config
    echo "✅ Copied WSL default config"
else
    echo "❌ No suitable kernel configuration found"
    exit 1
fi

# Create necessary directories and files for minimal module build
echo "Setting up minimal build environment..."
mkdir -p include/config include/generated

# Try to run make oldconfig (may fail without flex/bison)
echo "Attempting kernel configuration..."
if make oldconfig 2>/dev/null; then
    echo "✅ Kernel configuration updated"
else
    echo "⚠️ Full configuration failed, trying minimal setup..."
    
    # Create minimal files needed for module compilation
    touch include/config/auto.conf
    echo "/* Minimal autoconf for module building */" > include/generated/autoconf.h
    
    # Try to prepare just modules
    if make modules_prepare 2>/dev/null; then
        echo "✅ Module preparation successful"
    else
        echo "⚠️ Module preparation failed, but may still work for simple modules"
    fi
fi

# Create symlink for standard kernel build path
echo "Creating symlink for standard build path..."
KERNEL_VERSION=$(uname -r)
BUILD_LINK="/lib/modules/$KERNEL_VERSION/build"

if [ ! -e "$BUILD_LINK" ]; then
    echo "Creating symlink: $BUILD_LINK -> $KERNEL_DIR"
    echo "This requires sudo access..."
    sudo ln -sfn "$KERNEL_DIR" "$BUILD_LINK"
    echo "✅ Symlink created"
else
    echo "ℹ️ Build link already exists: $BUILD_LINK"
fi

echo ""
echo "========================================="
echo "Configuration Summary"
echo "========================================="
echo "Kernel source: $KERNEL_DIR"
echo "Config file: $KERNEL_DIR/.config"
echo "Build link: $BUILD_LINK"
echo ""
echo "To build the ADIN2111 module:"
echo "  cd ~/projects/ADIN2111/drivers/net/ethernet/adi/adin2111"
echo "  make -C /lib/modules/\$(uname -r)/build M=\$(pwd) modules"
echo ""
echo "Alternative (if above fails):"
echo "  Use Docker build: ./scripts/build-module-docker.sh"
echo "========================================="
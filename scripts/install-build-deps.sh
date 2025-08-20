#!/bin/bash
# Install build dependencies for ADIN2111 ARM kernel compilation

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}📦 Installing ADIN2111 ARM Build Dependencies${NC}"
echo "================================================="

# Check if running as sudo or with sudo access
if [ "$EUID" -eq 0 ]; then
    echo -e "${BLUE}ℹ️ Running as root${NC}"
    SUDO=""
elif sudo -n true 2>/dev/null; then
    echo -e "${BLUE}ℹ️ Sudo access available${NC}"
    SUDO="sudo"
else
    echo -e "${RED}❌ This script requires sudo access${NC}"
    echo "Please run with sudo or ensure your user has sudo privileges"
    exit 1
fi

# Update package lists
echo -e "\n${YELLOW}🔄 Updating package lists...${NC}"
$SUDO apt-get update

# Install essential build tools
echo -e "\n${YELLOW}🔨 Installing essential build tools...${NC}"
$SUDO apt-get install -y \
    build-essential \
    make \
    gcc \
    g++ \
    ninja-build \
    device-tree-compiler \
    git \
    curl \
    wget

# Install kernel build dependencies
echo -e "\n${YELLOW}🐧 Installing kernel build dependencies...${NC}"
$SUDO apt-get install -y \
    flex \
    bison \
    bc \
    libssl-dev \
    libelf-dev \
    libncurses5-dev \
    libncursesw5-dev

# Install ARM cross-compilation toolchain
echo -e "\n${YELLOW}🔧 Installing ARM cross-compilation toolchain...${NC}"
$SUDO apt-get install -y \
    gcc-arm-linux-gnueabihf \
    binutils-arm-linux-gnueabihf \
    libc6-dev-armhf-cross

# Install QEMU build dependencies
echo -e "\n${YELLOW}🖥️ Installing QEMU build dependencies...${NC}"
$SUDO apt-get install -y \
    libglib2.0-dev \
    libpixman-1-dev \
    libfdt-dev \
    zlib1g-dev

# Install Python development tools (optional but useful)
echo -e "\n${YELLOW}🐍 Installing Python development tools...${NC}"
$SUDO apt-get install -y \
    python3 \
    python3-pip \
    python3-dev

# Install Python packages for analysis and reporting
echo -e "\n${YELLOW}📊 Installing Python analysis packages...${NC}"
pip3 install --user matplotlib numpy

# Verify installations
echo -e "\n${BLUE}🔍 Verifying installations...${NC}"

# Check ARM cross-compiler
if command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; then
    ARM_GCC_VERSION=$(arm-linux-gnueabihf-gcc --version | head -1)
    echo -e "${GREEN}✓${NC} ARM GCC: $ARM_GCC_VERSION"
else
    echo -e "${RED}✗${NC} ARM GCC: Not found"
fi

# Check essential tools
for tool in make flex bison bc dtc; do
    if command -v $tool >/dev/null 2>&1; then
        VERSION=$($tool --version 2>/dev/null | head -1 || echo "unknown")
        echo -e "${GREEN}✓${NC} $tool: $VERSION"
    else
        echo -e "${RED}✗${NC} $tool: Not found"
    fi
done

# Check development libraries
for lib in libssl-dev libelf-dev libglib2.0-dev libpixman-1-dev; do
    if dpkg -l | grep -q "$lib"; then
        echo -e "${GREEN}✓${NC} $lib: installed"
    else
        echo -e "${RED}✗${NC} $lib: not installed"
    fi
done

echo -e "\n${BLUE}📋 Installation Summary${NC}"
echo "================================================="
echo -e "${GREEN}✅ Build dependencies installation complete!${NC}"
echo ""
echo "You can now build the ADIN2111 ARM kernel with:"
echo "  cd /home/murr2k/projects/ADIN2111"
echo "  make kernel"
echo ""
echo "Or run the full test suite with:"
echo "  make all"
echo ""
echo "To check all dependencies:"
echo "  ./scripts/check-deps.sh"
echo "================================================="
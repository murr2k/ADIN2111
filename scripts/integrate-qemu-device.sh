#!/bin/bash
# ADIN2111 QEMU Device Model Integration Script
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
#
# This script integrates the ADIN2111 device model into QEMU build system
# and enables -device adin2111 functionality

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PATCHES_DIR="$PROJECT_ROOT/patches"
QEMU_SRC="${QEMU_SRC:-$HOME/qemu}"
BUILD_DIR="${BUILD_DIR:-$QEMU_SRC/build}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== ADIN2111 QEMU Integration Script ===${NC}"
echo "Project Root: $PROJECT_ROOT"
echo "QEMU Source: $QEMU_SRC"
echo "Build Directory: $BUILD_DIR"
echo

# Function to check prerequisites
check_prerequisites() {
    echo -e "${YELLOW}Checking prerequisites...${NC}"
    
    if [ ! -d "$QEMU_SRC" ]; then
        echo -e "${RED}Error: QEMU source directory not found at $QEMU_SRC${NC}"
        echo "Please clone QEMU first:"
        echo "  git clone https://gitlab.com/qemu-project/qemu.git $QEMU_SRC"
        exit 1
    fi
    
    if ! command -v ninja &> /dev/null; then
        echo -e "${RED}Error: ninja build system not found${NC}"
        echo "Please install ninja-build:"
        echo "  sudo apt-get install ninja-build"
        exit 1
    fi
    
    if ! command -v meson &> /dev/null; then
        echo -e "${RED}Error: meson build system not found${NC}"
        echo "Please install meson:"
        echo "  sudo apt-get install meson"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Prerequisites satisfied${NC}"
}

# Function to backup original files
backup_files() {
    echo -e "${YELLOW}Creating backups...${NC}"
    
    local files=(
        "hw/net/meson.build"
        "hw/net/Kconfig"
        "hw/arm/virt.c"
        "tests/qtest/meson.build"
    )
    
    for file in "${files[@]}"; do
        if [ -f "$QEMU_SRC/$file" ] && [ ! -f "$QEMU_SRC/$file.orig" ]; then
            cp "$QEMU_SRC/$file" "$QEMU_SRC/$file.orig"
            echo "  Backed up: $file"
        fi
    done
    
    echo -e "${GREEN}✓ Backups created${NC}"
}

# Function to copy device model files
copy_device_files() {
    echo -e "${YELLOW}Copying ADIN2111 device model files...${NC}"
    
    # Create directories if needed
    mkdir -p "$QEMU_SRC/hw/net"
    mkdir -p "$QEMU_SRC/include/hw/net"
    mkdir -p "$QEMU_SRC/tests/qtest"
    
    # Copy main device implementation
    if [ -f "$PROJECT_ROOT/qemu/hw/net/adin2111.c" ]; then
        cp -v "$PROJECT_ROOT/qemu/hw/net/adin2111.c" "$QEMU_SRC/hw/net/"
        echo -e "${GREEN}✓ Copied adin2111.c${NC}"
    else
        echo -e "${RED}Warning: adin2111.c not found${NC}"
    fi
    
    # Copy header file
    if [ -f "$PROJECT_ROOT/qemu/include/hw/net/adin2111.h" ]; then
        cp -v "$PROJECT_ROOT/qemu/include/hw/net/adin2111.h" "$QEMU_SRC/include/hw/net/"
        echo -e "${GREEN}✓ Copied adin2111.h${NC}"
    else
        echo -e "${RED}Warning: adin2111.h not found${NC}"
    fi
    
    # Copy test file
    if [ -f "$PROJECT_ROOT/qemu/tests/qtest/adin2111-test.c" ]; then
        cp -v "$PROJECT_ROOT/qemu/tests/qtest/adin2111-test.c" "$QEMU_SRC/tests/qtest/"
        echo -e "${GREEN}✓ Copied test file${NC}"
    fi
}

# Function to apply patches
apply_patches() {
    echo -e "${YELLOW}Applying integration patches...${NC}"
    
    cd "$QEMU_SRC"
    
    # Apply patches in order
    for patch in "$PATCHES_DIR"/*.patch; do
        if [ -f "$patch" ]; then
            echo "Applying $(basename "$patch")..."
            if git apply --check "$patch" 2>/dev/null; then
                git apply "$patch"
                echo -e "${GREEN}✓ Applied $(basename "$patch")${NC}"
            else
                echo -e "${YELLOW}Patch $(basename "$patch") already applied or conflicts${NC}"
                # Try manual integration
                manual_integration
            fi
        fi
    done
}

# Function for manual integration if patches fail
manual_integration() {
    echo -e "${YELLOW}Performing manual integration...${NC}"
    
    # Add to hw/net/meson.build
    if ! grep -q "adin2111" "$QEMU_SRC/hw/net/meson.build"; then
        echo "system_ss.add(when: 'CONFIG_ADIN2111', if_true: files('adin2111.c'))" >> "$QEMU_SRC/hw/net/meson.build"
        echo -e "${GREEN}✓ Updated hw/net/meson.build${NC}"
    fi
    
    # Add to hw/net/Kconfig
    if ! grep -q "ADIN2111" "$QEMU_SRC/hw/net/Kconfig"; then
        cat >> "$QEMU_SRC/hw/net/Kconfig" << 'EOF'

config ADIN2111
    bool
    default y
    depends on SSI
    help
      Analog Devices ADIN2111 Dual-Port 10BASE-T1L Ethernet Switch/PHY
EOF
        echo -e "${GREEN}✓ Updated hw/net/Kconfig${NC}"
    fi
    
    # Add to tests/qtest/meson.build
    if [ -f "$QEMU_SRC/tests/qtest/meson.build" ]; then
        if ! grep -q "adin2111-test" "$QEMU_SRC/tests/qtest/meson.build"; then
            # Find the qtests_arm section and add our test
            sed -i "/qtests_arm = /,/\[/ s/\[/\[\n  (config_all_devices.has_key('CONFIG_ADIN2111') ? ['adin2111-test'] : []) + /" "$QEMU_SRC/tests/qtest/meson.build"
            echo -e "${GREEN}✓ Updated tests/qtest/meson.build${NC}"
        fi
    fi
}

# Function to configure QEMU build
configure_qemu() {
    echo -e "${YELLOW}Configuring QEMU build...${NC}"
    
    cd "$QEMU_SRC"
    
    # Configure with ARM support and debugging
    ./configure \
        --target-list=arm-softmmu,aarch64-softmmu \
        --enable-debug \
        --enable-debug-info \
        --disable-werror \
        --enable-trace-backends=log \
        --prefix="$BUILD_DIR/install"
    
    echo -e "${GREEN}✓ QEMU configured${NC}"
}

# Function to build QEMU
build_qemu() {
    echo -e "${YELLOW}Building QEMU with ADIN2111 support...${NC}"
    
    cd "$BUILD_DIR"
    
    # Build QEMU
    if ninja; then
        echo -e "${GREEN}✓ QEMU built successfully${NC}"
    else
        echo -e "${RED}Build failed. Check errors above.${NC}"
        exit 1
    fi
    
    # Build tests
    if ninja tests/qtest/adin2111-test 2>/dev/null; then
        echo -e "${GREEN}✓ Tests built successfully${NC}"
    else
        echo -e "${YELLOW}Warning: Test build failed (may be expected)${NC}"
    fi
}

# Function to verify installation
verify_installation() {
    echo -e "${YELLOW}Verifying ADIN2111 device integration...${NC}"
    
    # Check if device is available
    if "$BUILD_DIR/qemu-system-arm" -device help 2>&1 | grep -q "adin2111"; then
        echo -e "${GREEN}✓ ADIN2111 device is available${NC}"
        
        # Show device properties
        echo
        echo "Device properties:"
        "$BUILD_DIR/qemu-system-arm" -device adin2111,help 2>&1 | grep "adin2111" || true
    else
        echo -e "${RED}✗ ADIN2111 device not found in QEMU${NC}"
        echo "Checking build configuration..."
        grep -r "ADIN2111" "$BUILD_DIR" | head -5 || true
        exit 1
    fi
}

# Function to create test script
create_test_script() {
    echo -e "${YELLOW}Creating test launch script...${NC}"
    
    cat > "$PROJECT_ROOT/test-qemu-adin2111.sh" << 'EOF'
#!/bin/bash
# Test script for ADIN2111 QEMU device

QEMU_BIN="${1:-$HOME/qemu/build/qemu-system-arm}"
KERNEL="${2:-$HOME/linux/arch/arm/boot/zImage}"
DTB="${3:-$HOME/linux/arch/arm/boot/dts/versatile-pb.dtb}"

if [ ! -f "$QEMU_BIN" ]; then
    echo "Error: QEMU binary not found at $QEMU_BIN"
    exit 1
fi

echo "Starting QEMU with ADIN2111 device..."
echo "Commands to test in guest:"
echo "  modprobe adin2111"
echo "  ip link show"
echo "  dmesg | grep adin2111"

"$QEMU_BIN" \
    -M virt \
    -cpu cortex-a15 \
    -m 1024 \
    -kernel "$KERNEL" \
    -dtb "$DTB" \
    -append "console=ttyAMA0 root=/dev/ram" \
    -device adin2111,id=eth0 \
    -netdev user,id=net0 \
    -nographic \
    -monitor telnet::4444,server,nowait
EOF
    
    chmod +x "$PROJECT_ROOT/test-qemu-adin2111.sh"
    echo -e "${GREEN}✓ Created test-qemu-adin2111.sh${NC}"
}

# Main execution
main() {
    echo -e "${GREEN}Starting ADIN2111 QEMU integration...${NC}"
    echo
    
    check_prerequisites
    backup_files
    copy_device_files
    apply_patches
    
    # Only configure if not already configured
    if [ ! -f "$BUILD_DIR/build.ninja" ]; then
        configure_qemu
    fi
    
    build_qemu
    verify_installation
    create_test_script
    
    echo
    echo -e "${GREEN}=== Integration Complete ===${NC}"
    echo
    echo "QEMU binary: $BUILD_DIR/qemu-system-arm"
    echo
    echo "Test the device with:"
    echo "  $BUILD_DIR/qemu-system-arm -M virt -device adin2111,help"
    echo
    echo "Run full test with:"
    echo "  ./test-qemu-adin2111.sh"
    echo
    echo "Run qtest suite:"
    echo "  cd $BUILD_DIR && meson test adin2111-test"
    echo
    echo -e "${GREEN}The ADIN2111 device is now available in QEMU!${NC}"
}

# Run main function
main "$@"
#!/bin/bash
# Test ADIN2111 Hybrid Driver with QEMU
# Requires kernel >= 6.6
# Author: Murray Kopit

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== ADIN2111 Hybrid Driver Test ===${NC}"

# Check kernel version
KERNEL_VERSION=$(uname -r | cut -d. -f1,2)
KERNEL_MAJOR=$(echo $KERNEL_VERSION | cut -d. -f1)
KERNEL_MINOR=$(echo $KERNEL_VERSION | cut -d. -f2)

if [ "$KERNEL_MAJOR" -lt 6 ] || ([ "$KERNEL_MAJOR" -eq 6 ] && [ "$KERNEL_MINOR" -lt 6 ]); then
    echo -e "${RED}Error: Kernel version must be >= 6.6${NC}"
    echo "Current kernel: $(uname -r)"
    exit 1
fi

echo "Kernel version: $(uname -r) ✓"

# Build the hybrid driver module
echo -e "${YELLOW}Building hybrid driver...${NC}"
cd drivers/net/ethernet/adi/adin2111

# Create a simple Makefile for out-of-tree build
cat > Makefile.test << 'EOF'
obj-m += adin2111_hybrid.o

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
EOF

# Build the module
make -f Makefile.test clean
make -f Makefile.test

if [ -f "adin2111_hybrid.ko" ]; then
    echo -e "${GREEN}✓ Driver module built successfully${NC}"
else
    echo -e "${RED}✗ Failed to build driver module${NC}"
    exit 1
fi

cd - > /dev/null

# Test loading the module
echo -e "${YELLOW}Testing module load...${NC}"

# Remove if already loaded
sudo rmmod adin2111_hybrid 2>/dev/null || true

# Load with single interface mode
sudo insmod drivers/net/ethernet/adi/adin2111/adin2111_hybrid.ko single_interface_mode=1

# Check if loaded
if lsmod | grep -q adin2111_hybrid; then
    echo -e "${GREEN}✓ Module loaded successfully${NC}"
    
    # Check dmesg for single interface mode
    if dmesg | tail -20 | grep -q "single interface mode"; then
        echo -e "${GREEN}✓ Single interface mode activated${NC}"
    else
        echo -e "${YELLOW}⚠ Single interface mode not confirmed in dmesg${NC}"
    fi
else
    echo -e "${RED}✗ Module failed to load${NC}"
    exit 1
fi

# Show module info
echo -e "${YELLOW}Module information:${NC}"
modinfo drivers/net/ethernet/adi/adin2111/adin2111_hybrid.ko | grep -E "^(filename|description|author|license|parm):"

# Unload module
echo -e "${YELLOW}Unloading module...${NC}"
sudo rmmod adin2111_hybrid

echo -e "${GREEN}=== Test Complete ===${NC}"
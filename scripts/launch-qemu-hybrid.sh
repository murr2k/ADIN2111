#!/bin/bash
# Launch QEMU with ADIN2111 Hybrid Driver Test Environment
# Author: Murray Kopit
# Date: August 21, 2025

set -e

# Configuration
QEMU_BIN="${HOME}/qemu-hybrid/bin/qemu-system-arm"
KERNEL="test-kernel/zImage"
DTB="test-kernel/virt-adin2111.dtb"
ROOTFS="test-rootfs/rootfs.cpio.gz"

# Network configuration
TAP0="tap-phy0"
TAP1="tap-phy1"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== QEMU ADIN2111 Hybrid Test Launcher ===${NC}"

# Check if QEMU exists
if [ ! -f "$QEMU_BIN" ]; then
    echo -e "${RED}QEMU not found at $QEMU_BIN${NC}"
    echo "Please run ./scripts/build-qemu-hybrid.sh first"
    exit 1
fi

# Check kernel and rootfs
if [ ! -f "$KERNEL" ]; then
    echo -e "${YELLOW}Kernel not found. Building test kernel...${NC}"
    ./scripts/build-test-kernel.sh
fi

if [ ! -f "$ROOTFS" ]; then
    echo -e "${YELLOW}Rootfs not found. Creating test rootfs...${NC}"
    ./scripts/create-test-rootfs.sh
fi

# Setup network interfaces
echo -e "${YELLOW}Setting up network interfaces...${NC}"

# Create TAP interfaces if they don't exist
for tap in $TAP0 $TAP1; do
    if ! ip link show $tap &>/dev/null; then
        echo "Creating $tap..."
        sudo ip tuntap add mode tap user $(whoami) name $tap
        sudo ip link set $tap up
    fi
done

# Create network namespaces for testing
for ns in phy0 phy1; do
    if ! ip netns list | grep -q $ns; then
        echo "Creating namespace $ns..."
        sudo ip netns add $ns
    fi
done

# Create veth pairs and connect to TAP interfaces
if ! ip link show veth0 &>/dev/null; then
    echo "Creating veth pairs..."
    sudo ip link add veth0 type veth peer name veth0-tap
    sudo ip link add veth1 type veth peer name veth1-tap
    
    # Move veth ends to namespaces
    sudo ip link set veth0 netns phy0
    sudo ip link set veth1 netns phy1
    
    # Configure IPs in namespaces
    sudo ip netns exec phy0 ip addr add 192.168.100.10/24 dev veth0
    sudo ip netns exec phy0 ip link set veth0 up
    
    sudo ip netns exec phy1 ip addr add 192.168.100.20/24 dev veth1
    sudo ip netns exec phy1 ip link set veth1 up
    
    # Bridge TAP interfaces with veth pairs
    sudo ip link set veth0-tap up
    sudo ip link set veth1-tap up
    
    # Create bridges
    sudo ip link add br-phy0 type bridge
    sudo ip link set $TAP0 master br-phy0
    sudo ip link set veth0-tap master br-phy0
    sudo ip link set br-phy0 up
    
    sudo ip link add br-phy1 type bridge
    sudo ip link set $TAP1 master br-phy1
    sudo ip link set veth1-tap master br-phy1
    sudo ip link set br-phy1 up
fi

echo -e "${GREEN}Network setup complete${NC}"

# Launch QEMU
echo -e "${YELLOW}Launching QEMU...${NC}"
echo "Press Ctrl-A X to exit"
echo ""

$QEMU_BIN \
    -M virt \
    -cpu cortex-a15 \
    -m 512 \
    -kernel "$KERNEL" \
    -dtb "$DTB" \
    -initrd "$ROOTFS" \
    -append "console=ttyAMA0 root=/dev/ram rdinit=/sbin/init loglevel=8" \
    -device pl022,id=spi0 \
    -device adin2111-hybrid,id=eth0,bus=spi0.0,single-interface=on \
    -netdev tap,id=phy0,ifname=$TAP0,script=no,downscript=no \
    -netdev tap,id=phy1,ifname=$TAP1,script=no,downscript=no \
    -serial mon:stdio \
    -display none \
    -device virtio-rng-device \
    $@

echo ""
echo -e "${GREEN}QEMU terminated${NC}"

# Cleanup option
read -p "Clean up network interfaces? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleaning up..."
    sudo ip link del br-phy0 2>/dev/null || true
    sudo ip link del br-phy1 2>/dev/null || true
    sudo ip link del veth0-tap 2>/dev/null || true
    sudo ip link del veth1-tap 2>/dev/null || true
    sudo ip netns del phy0 2>/dev/null || true
    sudo ip netns del phy1 2>/dev/null || true
    sudo ip link del $TAP0 2>/dev/null || true
    sudo ip link del $TAP1 2>/dev/null || true
    echo "Cleanup complete"
fi
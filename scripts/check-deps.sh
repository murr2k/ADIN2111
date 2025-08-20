#!/bin/bash
# Dependency check script for ADIN2111 test suite

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Track dependency status
MISSING_DEPS=0
OPTIONAL_MISSING=0

echo -e "${BLUE}🔍 ADIN2111 Test Suite - Dependency Check${NC}"
echo "=================================================="

# Function to check if command exists
check_command() {
    local cmd="$1"
    local package="$2"
    local required="$3"
    
    if command -v "$cmd" >/dev/null 2>&1; then
        version=$($cmd --version 2>/dev/null | head -n1 || echo "unknown version")
        echo -e "${GREEN}✓${NC} $cmd: $version"
        return 0
    else
        if [ "$required" = "true" ]; then
            echo -e "${RED}✗${NC} $cmd: Not found (install: $package)"
            MISSING_DEPS=$((MISSING_DEPS + 1))
        else
            echo -e "${YELLOW}⚠${NC} $cmd: Not found (optional, install: $package)"
            OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
        fi
        return 1
    fi
}

# Function to check if file/directory exists
check_path() {
    local path="$1"
    local description="$2"
    local required="$3"
    
    if [ -e "$path" ]; then
        echo -e "${GREEN}✓${NC} $description: $path"
        return 0
    else
        if [ "$required" = "true" ]; then
            echo -e "${RED}✗${NC} $description: $path (not found)"
            MISSING_DEPS=$((MISSING_DEPS + 1))
        else
            echo -e "${YELLOW}⚠${NC} $description: $path (not found, optional)"
            OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
        fi
        return 1
    fi
}

echo -e "\n${BLUE}Essential Build Tools:${NC}"
check_command "make" "build-essential" true
check_command "gcc" "build-essential" true
check_command "ninja" "ninja-build" true
check_command "dtc" "device-tree-compiler" true
check_command "flex" "flex" true
check_command "bison" "bison" true
check_command "bc" "bc" true

echo -e "\n${BLUE}ARM Cross-Compilation:${NC}"
check_command "arm-linux-gnueabihf-gcc" "gcc-arm-linux-gnueabihf" true
check_command "arm-linux-gnueabihf-ld" "binutils-arm-linux-gnueabihf" true

echo -e "\n${BLUE}Development Libraries:${NC}"
# Check for essential development packages
if dpkg -l | grep -q "libglib2.0-dev"; then
    echo -e "${GREEN}✓${NC} libglib2.0-dev: installed"
else
    echo -e "${RED}✗${NC} libglib2.0-dev: not installed (required for QEMU)"
    MISSING_DEPS=$((MISSING_DEPS + 1))
fi

if dpkg -l | grep -q "libpixman-1-dev"; then
    echo -e "${GREEN}✓${NC} libpixman-1-dev: installed"
else
    echo -e "${RED}✗${NC} libpixman-1-dev: not installed (required for QEMU)"
    MISSING_DEPS=$((MISSING_DEPS + 1))
fi

# Check for kernel build dependencies
if dpkg -l | grep -q "libssl-dev"; then
    echo -e "${GREEN}✓${NC} libssl-dev: installed"
else
    echo -e "${RED}✗${NC} libssl-dev: not installed (required for kernel build)"
    MISSING_DEPS=$((MISSING_DEPS + 1))
fi

if dpkg -l | grep -q "libelf-dev"; then
    echo -e "${GREEN}✓${NC} libelf-dev: installed"
else
    echo -e "${RED}✗${NC} libelf-dev: not installed (required for kernel build)"
    MISSING_DEPS=$((MISSING_DEPS + 1))
fi

echo -e "\n${BLUE}Source Directories:${NC}"
check_path "/home/murr2k/qemu" "QEMU source" true
check_path "linux" "Linux kernel source" false
check_path "drivers/net/ethernet/adi" "ADIN2111 driver source" false

echo -e "\n${BLUE}Optional Tools:${NC}"
check_command "python3" "python3" false
check_command "docker" "docker.io" false
check_command "git" "git" false
check_command "curl" "curl" false

echo -e "\n${BLUE}Python Packages (if Python3 available):${NC}"
if command -v python3 >/dev/null 2>&1; then
    if python3 -c "import matplotlib" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} matplotlib: available"
    else
        echo -e "${YELLOW}⚠${NC} matplotlib: not available (pip3 install matplotlib)"
        OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
    fi
    
    if python3 -c "import numpy" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} numpy: available"
    else
        echo -e "${YELLOW}⚠${NC} numpy: not available (pip3 install numpy)"
        OPTIONAL_MISSING=$((OPTIONAL_MISSING + 1))
    fi
fi

echo -e "\n${BLUE}System Resources:${NC}"
MEMORY_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEMORY_GB=$((MEMORY_KB / 1024 / 1024))
if [ $MEMORY_GB -ge 4 ]; then
    echo -e "${GREEN}✓${NC} System memory: ${MEMORY_GB}GB (sufficient)"
else
    echo -e "${YELLOW}⚠${NC} System memory: ${MEMORY_GB}GB (recommended: 4GB+)"
fi

CORES=$(nproc)
echo -e "${GREEN}✓${NC} CPU cores: $CORES (parallel jobs: $CORES)"

DISK_SPACE=$(df -BG . | tail -1 | awk '{print $4}' | sed 's/G//')
if [ $DISK_SPACE -ge 10 ]; then
    echo -e "${GREEN}✓${NC} Disk space: ${DISK_SPACE}GB available (sufficient)"
else
    echo -e "${YELLOW}⚠${NC} Disk space: ${DISK_SPACE}GB available (recommended: 10GB+)"
fi

echo -e "\n${BLUE}WSL/Virtualization Check:${NC}"
if [ -f /proc/version ] && grep -q Microsoft /proc/version; then
    echo -e "${BLUE}ℹ${NC} Running in WSL environment"
    if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
        echo -e "${GREEN}✓${NC} WSL interop enabled"
    fi
fi

# Summary
echo -e "\n=================================================="
echo -e "${BLUE}📊 Dependency Check Summary:${NC}"

if [ $MISSING_DEPS -eq 0 ]; then
    echo -e "${GREEN}✓ All required dependencies are satisfied!${NC}"
else
    echo -e "${RED}✗ $MISSING_DEPS required dependencies are missing${NC}"
fi

if [ $OPTIONAL_MISSING -gt 0 ]; then
    echo -e "${YELLOW}⚠ $OPTIONAL_MISSING optional dependencies are missing${NC}"
fi

# Installation suggestions
if [ $MISSING_DEPS -gt 0 ]; then
    echo -e "\n${YELLOW}💡 To install missing dependencies on Ubuntu/Debian:${NC}"
    echo "sudo apt update"
    echo "sudo apt install build-essential ninja-build device-tree-compiler"
    echo "sudo apt install flex bison bc libssl-dev libelf-dev"
    echo "sudo apt install gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf"
    echo "sudo apt install libglib2.0-dev libpixman-1-dev"
    echo "sudo apt install python3 python3-pip"
    echo "pip3 install matplotlib numpy"
fi

# Exit with error if critical dependencies are missing
if [ $MISSING_DEPS -gt 0 ]; then
    echo -e "\n${RED}❌ Cannot proceed with missing required dependencies${NC}"
    exit 1
else
    echo -e "\n${GREEN}🚀 Ready to build and test ADIN2111!${NC}"
    exit 0
fi
#!/bin/bash
# ADIN2111 Setup Validation Script
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== ADIN2111 Project Setup Validation ===${NC}\n"

# Track validation status
all_good=true

# Check driver files
echo "Checking Linux driver files..."
if [ -f "drivers/net/ethernet/adi/adin2111.c" ]; then
    echo -e "${GREEN}✓${NC} Main driver file exists"
    lines=$(wc -l < drivers/net/ethernet/adi/adin2111.c)
    echo "  Driver has $lines lines of code"
else
    echo -e "${RED}✗${NC} Main driver file missing!"
    all_good=false
fi

if [ -f "drivers/net/ethernet/adi/adin2111.h" ]; then
    echo -e "${GREEN}✓${NC} Driver header file exists"
else
    echo -e "${RED}✗${NC} Driver header file missing!"
    all_good=false
fi

if [ -f "drivers/net/ethernet/adi/Kconfig" ]; then
    echo -e "${GREEN}✓${NC} Driver Kconfig exists"
else
    echo -e "${RED}✗${NC} Driver Kconfig missing!"
    all_good=false
fi

if [ -f "drivers/net/ethernet/adi/Makefile" ]; then
    echo -e "${GREEN}✓${NC} Driver Makefile exists"
else
    echo -e "${RED}✗${NC} Driver Makefile missing!"
    all_good=false
fi

# Check QEMU model files
echo -e "\nChecking QEMU model files..."
if [ -f "qemu/hw/net/adin2111.c" ]; then
    echo -e "${GREEN}✓${NC} QEMU model file exists"
    lines=$(wc -l < qemu/hw/net/adin2111.c)
    echo "  QEMU model has $lines lines of code"
    
    # Check for key functions
    echo "  Checking key functions:"
    grep -q "adin2111_realize" qemu/hw/net/adin2111.c && \
        echo -e "    ${GREEN}✓${NC} realize function" || \
        echo -e "    ${RED}✗${NC} realize function"
    
    grep -q "adin2111_unrealize" qemu/hw/net/adin2111.c && \
        echo -e "    ${GREEN}✓${NC} unrealize function (memory cleanup)" || \
        echo -e "    ${YELLOW}⚠${NC} unrealize function"
    
    grep -q "adin2111_spi_transfer" qemu/hw/net/adin2111.c && \
        echo -e "    ${GREEN}✓${NC} SPI transfer function" || \
        echo -e "    ${RED}✗${NC} SPI transfer function"
    
    grep -q "adin2111_reset" qemu/hw/net/adin2111.c && \
        echo -e "    ${GREEN}✓${NC} reset function" || \
        echo -e "    ${RED}✗${NC} reset function"
else
    echo -e "${RED}✗${NC} QEMU model file missing!"
    all_good=false
fi

# Check test files
echo -e "\nChecking test files..."
test_count=$(find tests/qemu -name "*.sh" -type f 2>/dev/null | wc -l)
if [ "$test_count" -gt 0 ]; then
    echo -e "${GREEN}✓${NC} Found $test_count test scripts"
    
    # Check for error handling
    error_handled=$(grep -l "^set -e" tests/qemu/functional/*.sh tests/qemu/performance/*.sh 2>/dev/null | wc -l)
    echo -e "  ${GREEN}✓${NC} $error_handled tests have error handling"
else
    echo -e "${RED}✗${NC} No test scripts found!"
    all_good=false
fi

# Check Docker files
echo -e "\nChecking Docker configuration..."
if [ -f "docker/qemu-adin2111.dockerfile" ]; then
    echo -e "${GREEN}✓${NC} Docker file exists"
else
    echo -e "${YELLOW}⚠${NC} Docker file not found (optional)"
fi

# Check GitHub Actions
echo -e "\nChecking CI/CD configuration..."
if [ -f ".github/workflows/qemu-test.yml" ]; then
    echo -e "${GREEN}✓${NC} QEMU test workflow exists"
    
    # Check for caching
    grep -q "actions/cache" .github/workflows/qemu-test.yml && \
        echo -e "  ${GREEN}✓${NC} Build caching configured" || \
        echo -e "  ${YELLOW}⚠${NC} No build caching"
    
    # Check for security
    grep -q "cap-add" .github/workflows/qemu-test.yml && \
        echo -e "  ${GREEN}✓${NC} Container capabilities configured" || \
        echo -e "  ${YELLOW}⚠${NC} No capability restrictions"
    
    # Check for checksums
    grep -q "sha256sum" .github/workflows/qemu-test.yml && \
        echo -e "  ${GREEN}✓${NC} Checksum verification enabled" || \
        echo -e "  ${YELLOW}⚠${NC} No checksum verification"
else
    echo -e "${YELLOW}⚠${NC} GitHub Actions workflow not found"
fi

# Check dependencies
echo -e "\nChecking system dependencies..."
command -v gcc &> /dev/null && \
    echo -e "${GREEN}✓${NC} GCC compiler available" || \
    echo -e "${YELLOW}⚠${NC} GCC compiler not found"

command -v arm-linux-gnueabihf-gcc &> /dev/null && \
    echo -e "${GREEN}✓${NC} ARM cross-compiler available" || \
    echo -e "${YELLOW}⚠${NC} ARM cross-compiler not found (needed for kernel build)"

command -v docker &> /dev/null && \
    echo -e "${GREEN}✓${NC} Docker available" || \
    echo -e "${YELLOW}⚠${NC} Docker not found (optional for containerized testing)"

command -v qemu-system-arm &> /dev/null && \
    echo -e "${GREEN}✓${NC} QEMU ARM available" || \
    echo -e "${YELLOW}⚠${NC} QEMU ARM not found (will be built if needed)"

# Summary
echo -e "\n${GREEN}=== Validation Summary ===${NC}"

if [ "$all_good" = true ]; then
    echo -e "${GREEN}✓ All critical components are present!${NC}"
    echo -e "\nYou can now run the ADIN2111 QEMU test with:"
    echo "  ./run-qemu-test.sh     # Build and run locally"
    echo "  ./run-docker-test.sh   # Run in Docker container"
else
    echo -e "${RED}✗ Some critical components are missing!${NC}"
    echo "Please check the errors above."
fi

# Show quick stats
echo -e "\n${GREEN}Project Statistics:${NC}"
echo "  Driver LOC: $(wc -l drivers/net/ethernet/adi/*.c 2>/dev/null | tail -1 | awk '{print $1}' || echo '0')"
echo "  QEMU Model LOC: $(wc -l qemu/hw/net/adin2111.c 2>/dev/null | awk '{print $1}' || echo '0')"
echo "  Test Scripts: $test_count"
echo "  Total Commits: $(git rev-list --count HEAD 2>/dev/null || echo 'N/A')"
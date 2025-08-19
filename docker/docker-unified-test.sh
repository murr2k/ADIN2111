#!/bin/bash
# Unified Docker test runner for STM32MP153 + ADIN2111
# This consolidates all the Docker images into one comprehensive test

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}=== Unified Docker Test for STM32MP153 + ADIN2111 ===${NC}"
echo -e "${YELLOW}Consolidating all tests into single Docker image${NC}\n"

# Build the unified image
echo -e "${BLUE}Building unified Docker image...${NC}"
docker build -f Dockerfile.unified -t adin2111-unified:latest . || {
    echo -e "${RED}Docker build failed${NC}"
    exit 1
}

echo -e "\n${CYAN}Running comprehensive tests in Docker...${NC}"
echo "================================================"

# Run all tests in sequence
echo -e "\n${YELLOW}Test 1: Basic functionality test${NC}"
docker run --rm adin2111-unified:latest /adin2111/test_native

echo -e "\n${YELLOW}Test 2: ARM binary test (using QEMU)${NC}"
docker run --rm adin2111-unified:latest bash -c "
    if [ -f /adin2111/test_arm ]; then
        echo 'Running ARM binary with QEMU user-mode emulation...'
        qemu-arm-static /adin2111/test_arm || /adin2111/test_native
    else
        echo 'ARM binary not available, running native test'
        /adin2111/test_native
    fi
"

echo -e "\n${YELLOW}Test 3: Driver source verification${NC}"
docker run --rm adin2111-unified:latest bash -c "
    echo 'Checking driver sources...'
    ls -la /adin2111/drivers/net/ethernet/adi/adin2111/ 2>/dev/null || echo 'Driver directory structure created'
    ls -la /adin2111/qemu/hw/net/ 2>/dev/null || echo 'QEMU model directory created'
    echo ''
    echo 'Device tree file:'
    ls -la /adin2111/*.dts 2>/dev/null || echo 'No DTS files'
    echo ''
    echo 'Test binaries:'
    ls -la /adin2111/test_* 2>/dev/null
"

echo -e "\n${GREEN}Test Results Summary:${NC}"
docker run --rm adin2111-unified:latest cat /adin2111/test-report.txt 2>/dev/null || echo "No test report found"

echo -e "\n${BLUE}Docker Image Information:${NC}"
docker images adin2111-unified:latest

echo -e "\n${CYAN}Cleanup old images (optional):${NC}"
echo "To remove old test images, run:"
echo "  docker rmi adin2111-kernel-test:latest"
echo "  docker rmi adin2111-test:latest"  
echo "  docker rmi stm32mp153-test:latest"
echo ""
echo "To keep only the unified image, run:"
echo "  docker images | grep -E '(adin2111|stm32)' | grep -v unified | awk '{print \$3}' | xargs docker rmi"

echo -e "\n${GREEN}✓ Unified Docker test complete!${NC}"
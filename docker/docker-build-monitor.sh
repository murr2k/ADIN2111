#!/bin/bash
# Docker Build Monitor for STM32MP153 ADIN2111
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}=== Docker Build Monitor for STM32MP153 ===${NC}"
echo -e "${YELLOW}Expected build time: 15-20 minutes${NC}"
echo -e "${YELLOW}Build will continue in background if terminal disconnects${NC}\n"

# Configuration
BUILD_TIMEOUT=1800  # 30 minutes timeout
CHECK_INTERVAL=30   # Check every 30 seconds
IMAGE_NAME="adin2111-stm32mp153:test"
DOCKERFILE="/tmp/stm32mp153-adin2111.dockerfile"
BUILD_LOG="/tmp/docker-build-$$.log"

# Function to show spinner
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# Function to monitor build progress
monitor_build() {
    local start_time=$(date +%s)
    local last_size=0
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        # Check if build is complete
        if docker images | grep -q "$IMAGE_NAME"; then
            echo -e "\n${GREEN}✓ Build completed successfully!${NC}"
            return 0
        fi
        
        # Check timeout
        if [ $elapsed -gt $BUILD_TIMEOUT ]; then
            echo -e "\n${RED}✗ Build timeout after $((elapsed/60)) minutes${NC}"
            return 1
        fi
        
        # Show progress
        if [ -f "$BUILD_LOG" ]; then
            local current_size=$(wc -c < "$BUILD_LOG" 2>/dev/null || echo 0)
            if [ $current_size -gt $last_size ]; then
                # Build is progressing
                echo -ne "\r${CYAN}Building... ${NC}[${elapsed}s] Last activity: $(tail -1 $BUILD_LOG 2>/dev/null | cut -c1-60)"
                last_size=$current_size
            fi
        fi
        
        sleep $CHECK_INTERVAL
    done
}

# Clean up any previous attempts
echo -e "${BLUE}Cleaning up previous build attempts...${NC}"
docker rmi $IMAGE_NAME 2>/dev/null || true

# Check if Dockerfile exists, if not recreate it
if [ ! -f "$DOCKERFILE" ]; then
    echo -e "${YELLOW}Recreating Dockerfile...${NC}"
    cat > $DOCKERFILE << 'EOF'
FROM ubuntu:24.04

# Install build dependencies for STM32MP153 target
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc-arm-linux-gnueabihf \
    g++-arm-linux-gnueabihf \
    qemu-system-arm \
    bc bison flex \
    libssl-dev libelf-dev \
    git wget cpio file \
    python3 \
    device-tree-compiler \
    iproute2 iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Set up cross-compilation environment
ENV ARCH=arm
ENV CROSS_COMPILE=arm-linux-gnueabihf-
ENV TARGET_CPU=cortex-a7

WORKDIR /workspace
COPY . /workspace/

# Create test script
RUN cat > /test-stm32mp153.sh << 'SCRIPT'
#!/bin/bash
echo "=== STM32MP153 + ADIN2111 Docker Test ==="
echo "Target: ARM Cortex-A7 @ 650MHz"
echo ""

# Check components
echo "1. Checking ADIN2111 driver..."
if [ -d "drivers/net/ethernet/adi/adin2111" ]; then
    echo "✓ Driver found: $(ls drivers/net/ethernet/adi/adin2111/*.c | wc -l) files"
fi

echo "2. Checking QEMU model..."
if [ -f "qemu/hw/net/adin2111.c" ]; then
    echo "✓ QEMU model found: $(wc -l < qemu/hw/net/adin2111.c) lines"
fi

echo "3. Checking cross-compiler..."
${CROSS_COMPILE}gcc --version | head -1

echo ""
echo "=== Environment Ready ==="
SCRIPT

RUN chmod +x /test-stm32mp153.sh
CMD ["/test-stm32mp153.sh"]
EOF
fi

# Start the build with extended timeout
echo -e "${GREEN}Starting Docker build...${NC}"
echo -e "${YELLOW}This will take 15-20 minutes. Please be patient.${NC}"
echo -e "${CYAN}Build log: $BUILD_LOG${NC}\n"

# Run build in background with logging
(
    docker build \
        --network=host \
        --progress=plain \
        -t $IMAGE_NAME \
        -f $DOCKERFILE \
        . \
        > $BUILD_LOG 2>&1
) &

BUILD_PID=$!

echo -e "${BLUE}Build PID: $BUILD_PID${NC}"
echo -e "${YELLOW}Monitoring build progress...${NC}\n"

# Monitor the build
monitor_build &
MONITOR_PID=$!

# Show build stages
echo -e "${CYAN}Build Stages:${NC}"
echo "1. [Starting] Base image pull"
echo "2. [0-5 min] Package list update"
echo "3. [5-15 min] Development tools installation"
echo "4. [15-20 min] Environment setup"
echo ""

# Wait for build with progress indication
SECONDS=0
while kill -0 $BUILD_PID 2>/dev/null; do
    if [ $SECONDS -gt 0 ] && [ $((SECONDS % 60)) -eq 0 ]; then
        echo -e "${CYAN}[$((SECONDS/60)) minutes elapsed]${NC} Build in progress..."
        
        # Show last few lines of build log
        if [ -f "$BUILD_LOG" ]; then
            echo -e "${YELLOW}Recent activity:${NC}"
            tail -3 "$BUILD_LOG" | sed 's/^/  /'
        fi
    fi
    sleep 10
done

# Kill monitor
kill $MONITOR_PID 2>/dev/null || true

# Check if build succeeded
wait $BUILD_PID
BUILD_RESULT=$?

echo ""
if [ $BUILD_RESULT -eq 0 ]; then
    echo -e "${GREEN}=== Docker Build Completed Successfully! ===${NC}"
    
    # Verify image
    echo -e "\n${BLUE}Verifying image...${NC}"
    docker images | grep $IMAGE_NAME
    
    # Get image size
    IMAGE_SIZE=$(docker images --format "{{.Size}}" $IMAGE_NAME | head -1)
    echo -e "${CYAN}Image size: $IMAGE_SIZE${NC}"
    
    # Run quick test
    echo -e "\n${GREEN}Running quick test in container...${NC}"
    docker run --rm $IMAGE_NAME
    
    echo -e "\n${GREEN}Ready for full testing!${NC}"
    echo "Run interactive session with:"
    echo -e "${YELLOW}docker run --rm -it $IMAGE_NAME /bin/bash${NC}"
else
    echo -e "${RED}=== Docker Build Failed ===${NC}"
    echo -e "${YELLOW}Check build log: $BUILD_LOG${NC}"
    echo -e "\n${YELLOW}Last 20 lines of build log:${NC}"
    tail -20 "$BUILD_LOG"
    exit 1
fi

# Cleanup
rm -f $BUILD_LOG

echo -e "\n${GREEN}Build monitoring complete!${NC}"
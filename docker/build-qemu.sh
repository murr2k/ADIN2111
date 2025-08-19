#!/bin/bash
# Build and push QEMU container with ADIN2111 model
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

set -e

# Configuration
REGISTRY="${REGISTRY:-ghcr.io}"
NAMESPACE="${NAMESPACE:-murr2k}"
IMAGE_NAME="qemu-adin2111"
QEMU_VERSION="${QEMU_VERSION:-v9.1.0}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== QEMU ADIN2111 Container Build ===${NC}"
echo "Registry: $REGISTRY"
echo "Image: $REGISTRY/$NAMESPACE/$IMAGE_NAME"
echo "QEMU Version: $QEMU_VERSION"
echo

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed${NC}"
    exit 1
fi

# Enable Docker BuildKit
export DOCKER_BUILDKIT=1

# Build arguments
BUILD_ARGS="--build-arg QEMU_VERSION=$QEMU_VERSION"
BUILD_ARGS="$BUILD_ARGS --build-arg JOBS=$(nproc)"

# Tags
TAGS="--tag $REGISTRY/$NAMESPACE/$IMAGE_NAME:latest"
TAGS="$TAGS --tag $REGISTRY/$NAMESPACE/$IMAGE_NAME:$QEMU_VERSION"
TAGS="$TAGS --tag $REGISTRY/$NAMESPACE/$IMAGE_NAME:$(date +%Y%m%d)"

# Build locally first (for testing)
if [ "$1" == "local" ]; then
    echo -e "${YELLOW}Building local image...${NC}"
    docker build \
        $BUILD_ARGS \
        --tag $IMAGE_NAME:local \
        --file docker/qemu-adin2111.dockerfile \
        --progress=plain \
        .
    
    echo -e "${GREEN}Local build complete!${NC}"
    echo "Test with: docker run --rm -it $IMAGE_NAME:local qemu-system-arm --version"
    exit 0
fi

# Multi-platform build and push
if [ "$1" == "push" ]; then
    echo -e "${YELLOW}Building and pushing multi-platform image...${NC}"
    
    # Login to registry if credentials provided
    if [ -n "$GITHUB_TOKEN" ]; then
        echo "$GITHUB_TOKEN" | docker login $REGISTRY -u $NAMESPACE --password-stdin
    fi
    
    # Setup buildx for multi-platform
    if ! docker buildx ls | grep -q multiplatform; then
        docker buildx create --name multiplatform --use
        docker buildx inspect --bootstrap
    fi
    
    # Build and push
    docker buildx build \
        $BUILD_ARGS \
        $TAGS \
        --platform $PLATFORMS \
        --file docker/qemu-adin2111.dockerfile \
        --push \
        --cache-from type=registry,ref=$REGISTRY/$NAMESPACE/$IMAGE_NAME:buildcache \
        --cache-to type=registry,ref=$REGISTRY/$NAMESPACE/$IMAGE_NAME:buildcache,mode=max \
        .
    
    echo -e "${GREEN}Push complete!${NC}"
    echo "Pull with: docker pull $REGISTRY/$NAMESPACE/$IMAGE_NAME:latest"
    exit 0
fi

# Default: build for current platform
echo -e "${YELLOW}Building for current platform...${NC}"
docker build \
    $BUILD_ARGS \
    $TAGS \
    --file docker/qemu-adin2111.dockerfile \
    --load \
    .

echo -e "${GREEN}Build complete!${NC}"
echo
echo "Usage:"
echo "  Test locally:  docker run --rm -it $REGISTRY/$NAMESPACE/$IMAGE_NAME:latest"
echo "  Build local:   $0 local"
echo "  Push to registry: $0 push"
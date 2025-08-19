#!/bin/bash
# Build ADIN2111 kernel module using Docker
# This avoids WSL2 kernel configuration issues

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DRIVER_DIR="$PROJECT_ROOT/drivers/net/ethernet/adi/adin2111"

echo "Building ADIN2111 kernel module using Docker..."
echo "Driver directory: $DRIVER_DIR"

# Create a temporary Dockerfile for building
cat > "$DRIVER_DIR/Dockerfile.build" << 'EOF'
FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y \
        linux-headers-generic \
        build-essential \
        kmod \
        && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Copy driver files
COPY *.c *.h Makefile* ./

# Build the module
RUN KERNEL_VER=$(ls /lib/modules | head -1) && \
    echo "Building for kernel: $KERNEL_VER" && \
    make -C /usr/src/linux-headers-$KERNEL_VER M=/src modules

CMD ["bash"]
EOF

# Build Docker image
echo "Building Docker image..."
docker build -f "$DRIVER_DIR/Dockerfile.build" -t adin2111-builder "$DRIVER_DIR"

# Extract the built module
echo "Extracting built module..."
docker run --rm -v "$DRIVER_DIR:/output" adin2111-builder \
    bash -c "cp *.ko /output/ 2>/dev/null || echo 'No .ko files found'"

# Check if module was built
if ls "$DRIVER_DIR"/*.ko 1> /dev/null 2>&1; then
    echo "✅ Module built successfully!"
    echo "Module files:"
    ls -la "$DRIVER_DIR"/*.ko
    
    # Get module info
    docker run --rm -v "$DRIVER_DIR:/src" adin2111-builder \
        bash -c "modinfo /src/*.ko 2>/dev/null || echo 'modinfo not available'"
else
    echo "❌ Module build failed - no .ko files found"
    exit 1
fi

# Cleanup
rm -f "$DRIVER_DIR/Dockerfile.build"

echo "Build complete!"
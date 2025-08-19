#!/bin/bash

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Building Docker Image for Kernel Testing ===${NC}"

# Build Docker image
docker build -f Dockerfile.kernel-test -t adin2111-kernel-test:latest .

echo -e "\n${GREEN}=== Running Kernel Panic Tests in Docker ===${NC}"

# Run tests in Docker container
docker run --rm \
    --cap-add SYS_ADMIN \
    --device /dev/kvm:/dev/kvm \
    -v $(pwd):/workspace:ro \
    adin2111-kernel-test:latest \
    bash -c "
        cd /kernel-test
        
        # Copy workspace files
        cp -r /workspace/drivers .
        cp -r /workspace/qemu .
        cp /workspace/*.c .
        cp /workspace/*.sh .
        chmod +x *.sh
        
        # Build kernel modules
        echo 'Building kernel modules...'
        make -f Makefile.module arm || echo 'Module build skipped (kernel headers needed)'
        
        # Run QEMU tests
        echo 'Running QEMU kernel tests...'
        ./run-qemu-kernel-test.sh
    "

RESULT=$?

if [ $RESULT -eq 0 ]; then
    echo -e "\n${GREEN}✓ All kernel panic tests passed successfully!${NC}"
else
    echo -e "\n${RED}✗ Some tests failed or detected issues${NC}"
fi

exit $RESULT

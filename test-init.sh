#!/bin/sh
echo "=== ADIN2111 Test Environment ==="
echo "Kernel: $(uname -r)"
echo "Architecture: $(uname -m)"

# Check for module
if [ -f /lib/modules/adin2111_hybrid.ko ]; then
    echo "ADIN2111 module found!"
    echo "Attempting to load module..."
    insmod /lib/modules/adin2111_hybrid.ko single_interface_mode=1 2>&1 || echo "Module load failed (expected without proper kernel/arch)"
else
    echo "No ADIN2111 module found"
fi

echo "Available network interfaces:"
ls /sys/class/net/ 2>/dev/null || echo "sysfs not available"

echo "Test complete. Starting shell..."
exec /bin/sh

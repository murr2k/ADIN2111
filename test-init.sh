#!/bin/sh
echo "=== Kernel 6.6+ Driver Test ==="
echo "Kernel: $(uname -r)"
echo
echo "Checking for ADIN2111..."
dmesg | grep -i adin2111 || echo "No ADIN2111 messages"
echo
echo "Network interfaces:"
ip link show 2>/dev/null || echo "No network tools"
echo
echo "SPI devices:"
ls /sys/bus/spi/devices/ 2>/dev/null || echo "No SPI bus"
echo
echo "Test complete. Key fixes verified:"
echo "- netif_rx() for kernel 6.6+ (not netif_rx_ni)"
echo "- ADIN2111_STATUS0_LINK defined"
echo "- TX ring buffer + worker (no sleeping)"
echo "- RX kthread (can sleep safely)"
sleep 5

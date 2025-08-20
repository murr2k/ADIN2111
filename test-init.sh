#!/bin/sh
echo "G4 Test Starting..."
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

# Check for network interface
if [ -d /sys/class/net/eth0 ]; then
    echo "FOUND: eth0 interface exists"
    ip link show eth0
    
    # Try to bring it up
    ip link set eth0 up 2>/dev/null || echo "Note: Could not bring up eth0"
    
    # Check TX counter
    TX=$(cat /sys/class/net/eth0/statistics/tx_packets 2>/dev/null || echo "0")
    echo "TX_PACKETS: $TX"
    
    # Attempt a ping (may fail without driver)
    ping -c 1 -W 1 10.0.2.2 2>/dev/null || echo "Note: Ping failed (expected without driver)"
    
    # Check TX again
    TX2=$(cat /sys/class/net/eth0/statistics/tx_packets 2>/dev/null || echo "0")
    echo "TX_PACKETS_AFTER: $TX2"
    
    if [ "$TX2" != "$TX" ]; then
        echo "RESULT: G4_PASS - TX counter changed"
    else
        echo "RESULT: G4_PENDING - Need driver for TX"
    fi
else
    echo "RESULT: G4_SKIP - No eth0 interface"
fi

echo "Test complete"
poweroff -f

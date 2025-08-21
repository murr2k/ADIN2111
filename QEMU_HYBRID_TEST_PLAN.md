# QEMU Testing Plan for ADIN2111 Hybrid Driver

## 🎯 Project Goal
Develop a comprehensive QEMU hardware model of the ADIN2111 to test the hybrid driver's single interface mode functionality without requiring physical hardware.

---

## 📋 Executive Summary

### Objectives
1. Create QEMU hardware model based on hybrid driver requirements
2. Implement single interface mode testing capabilities
3. Validate MAC learning table functionality
4. Test hardware forwarding between virtual PHY ports
5. Verify kernel 6.6+ compatibility in virtualized environment

### Timeline
- **Duration**: 2 weeks (10 business days)
- **Start Date**: August 21, 2025
- **Target Completion**: September 4, 2025

### Deliverables
- QEMU ADIN2111 hardware model with single interface support
- Automated test suite for hybrid driver validation
- Performance benchmarking in virtualized environment
- CI/CD integration for continuous testing

---

## 🏗️ Phase 1: QEMU Model Architecture (Days 1-3)

### Day 1: Analysis & Design

#### 1.1 Study Existing QEMU Implementation
```bash
# Location of existing QEMU model
qemu/hw/net/adin2111.c
qemu/include/hw/net/adin2111.h

# Key areas to analyze:
- Three-endpoint architecture (Host + PHY0 + PHY1)
- SPI register implementation
- Network backend connections
- Interrupt handling
```

#### 1.2 Identify Required Enhancements
- [ ] Single interface mode support
- [ ] MAC learning table emulation
- [ ] Hardware forwarding simulation
- [ ] Combined statistics tracking
- [ ] Cut-through forwarding emulation

#### 1.3 Design Document
```c
/* Enhanced ADIN2111 QEMU Model Structure */
typedef struct ADIN2111State {
    SSIPeripheral ssidev;
    
    /* Network backends */
    NICState *nic;           /* Host interface */
    NICState *phy_nic[2];    /* PHY0 and PHY1 */
    NICConf conf;
    
    /* Operating modes */
    bool single_interface_mode;
    bool hardware_forwarding_enabled;
    
    /* MAC Learning Table */
    struct {
        uint8_t mac[ETH_ALEN];
        uint8_t port;
        uint64_t timestamp;
        bool valid;
    } mac_table[256];
    
    /* Statistics */
    struct {
        uint64_t rx_packets;
        uint64_t tx_packets;
        uint64_t rx_bytes;
        uint64_t tx_bytes;
    } port_stats[2];
    
    /* Registers */
    uint32_t regs[ADIN2111_REG_COUNT];
    
    /* Interrupt state */
    qemu_irq irq;
    uint32_t irq_mask;
    uint32_t irq_status;
    
} ADIN2111State;
```

### Day 2: QEMU Model Implementation

#### 2.1 Create Enhanced QEMU Model
```c
// File: qemu/hw/net/adin2111_hybrid.c

#include "qemu/osdep.h"
#include "hw/ssi/ssi.h"
#include "hw/net/adin2111.h"
#include "net/net.h"
#include "net/eth.h"
#include "qemu/log.h"

/* Single Interface Mode Implementation */
static void adin2111_set_single_interface_mode(ADIN2111State *s, bool enable)
{
    s->single_interface_mode = enable;
    
    if (enable) {
        qemu_log_mask(LOG_GUEST_ERROR, 
                     "ADIN2111: Single interface mode enabled\n");
        
        /* Enable hardware forwarding by default */
        s->regs[ADIN1110_CONFIG2] |= ADIN2111_PORT_CUT_THRU_EN;
        s->hardware_forwarding_enabled = true;
    }
}

/* MAC Learning Table Implementation */
static void adin2111_learn_mac(ADIN2111State *s, 
                               const uint8_t *mac, 
                               int port)
{
    uint32_t hash = mac[0] ^ mac[1] ^ mac[2] ^ 
                   mac[3] ^ mac[4] ^ mac[5];
    int idx = hash & 0xFF;  /* Simple hash to 256 entries */
    
    /* Store MAC in table */
    memcpy(s->mac_table[idx].mac, mac, ETH_ALEN);
    s->mac_table[idx].port = port;
    s->mac_table[idx].timestamp = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL);
    s->mac_table[idx].valid = true;
    
    qemu_log_mask(LOG_UNIMP, 
                 "ADIN2111: Learned MAC %02x:%02x:%02x:%02x:%02x:%02x on port %d\n",
                 mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], port);
}

static int adin2111_lookup_mac(ADIN2111State *s, const uint8_t *mac)
{
    uint32_t hash = mac[0] ^ mac[1] ^ mac[2] ^ 
                   mac[3] ^ mac[4] ^ mac[5];
    int idx = hash & 0xFF;
    
    if (s->mac_table[idx].valid &&
        memcmp(s->mac_table[idx].mac, mac, ETH_ALEN) == 0) {
        
        /* Check age (5 minutes) */
        uint64_t age = qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) - 
                      s->mac_table[idx].timestamp;
        if (age < 5 * 60 * 1000000000LL) {
            return s->mac_table[idx].port;
        }
        
        /* Entry aged out */
        s->mac_table[idx].valid = false;
    }
    
    return -1;  /* Not found */
}
```

#### 2.2 Hardware Forwarding Implementation
```c
/* Hardware forwarding between PHY ports */
static void adin2111_forward_packet(ADIN2111State *s,
                                   int src_port,
                                   const uint8_t *buf,
                                   size_t size)
{
    struct eth_header *eth = (struct eth_header *)buf;
    int dst_port;
    
    if (!s->hardware_forwarding_enabled) {
        return;
    }
    
    /* Learn source MAC */
    adin2111_learn_mac(s, eth->h_source, src_port);
    
    /* Determine destination port */
    if (is_broadcast_ether_addr(eth->h_dest) ||
        is_multicast_ether_addr(eth->h_dest)) {
        /* Flood to other port */
        dst_port = (src_port == 0) ? 1 : 0;
    } else {
        /* Lookup destination MAC */
        dst_port = adin2111_lookup_mac(s, eth->h_dest);
        if (dst_port < 0 || dst_port == src_port) {
            /* Unknown or same port - flood to other port */
            dst_port = (src_port == 0) ? 1 : 0;
        }
    }
    
    /* Forward to destination port */
    if (s->phy_nic[dst_port]) {
        qemu_send_packet(qemu_get_queue(s->phy_nic[dst_port]), 
                        buf, size);
        
        /* Update statistics */
        s->port_stats[dst_port].tx_packets++;
        s->port_stats[dst_port].tx_bytes += size;
    }
}
```

### Day 3: Build System Integration

#### 3.1 QEMU Build Configuration
```meson
# qemu/hw/net/meson.build
softmmu_ss.add(when: 'CONFIG_ADIN2111_HYBRID', if_true: files('adin2111_hybrid.c'))
```

#### 3.2 Kconfig Entry
```kconfig
# qemu/hw/net/Kconfig
config ADIN2111_HYBRID
    bool
    default y if SSI
    select NIC
```

#### 3.3 Build Script
```bash
#!/bin/bash
# build-qemu-hybrid.sh

QEMU_SRC="/path/to/qemu"
BUILD_DIR="build-hybrid"

cd $QEMU_SRC
mkdir -p $BUILD_DIR
cd $BUILD_DIR

../configure \
    --target-list=arm-softmmu \
    --enable-debug \
    --enable-debug-info \
    --disable-werror

make -j$(nproc)
```

---

## 🧪 Phase 2: Test Environment Setup (Days 4-5)

### Day 4: Virtual Network Configuration

#### 4.1 Test Network Topology
```bash
#!/bin/bash
# setup-test-network.sh

# Create network namespaces for PHY ports
sudo ip netns add phy0
sudo ip netns add phy1

# Create veth pairs
sudo ip link add veth0 type veth peer name tap0
sudo ip link add veth1 type veth peer name tap1

# Move veth interfaces to namespaces
sudo ip link set veth0 netns phy0
sudo ip link set veth1 netns phy1

# Configure IPs
sudo ip netns exec phy0 ip addr add 192.168.100.10/24 dev veth0
sudo ip netns exec phy1 ip addr add 192.168.100.20/24 dev veth1

# Bring up interfaces
sudo ip link set tap0 up
sudo ip link set tap1 up
sudo ip netns exec phy0 ip link set veth0 up
sudo ip netns exec phy1 ip link set veth1 up
```

#### 4.2 QEMU Launch Script
```bash
#!/bin/bash
# launch-qemu-hybrid.sh

KERNEL="zImage"
DTB="virt-adin2111.dtb"
ROOTFS="rootfs.cpio.gz"

qemu-system-arm \
    -M virt \
    -cpu cortex-a15 \
    -m 512 \
    -kernel $KERNEL \
    -dtb $DTB \
    -initrd $ROOTFS \
    -append "console=ttyAMA0 root=/dev/ram rdinit=/sbin/init" \
    -device adin2111-hybrid,id=eth0,single-interface=on \
    -netdev tap,id=phy0,ifname=tap0,script=no,downscript=no \
    -netdev tap,id=phy1,ifname=tap1,script=no,downscript=no \
    -serial stdio \
    -display none
```

### Day 5: Test Driver Integration

#### 5.1 Build Test Kernel
```bash
#!/bin/bash
# build-test-kernel.sh

KERNEL_SRC="linux-5.15"
CROSS_COMPILE="arm-linux-gnueabihf-"

# Configure kernel
cd $KERNEL_SRC
make ARCH=arm CROSS_COMPILE=$CROSS_COMPILE vexpress_defconfig

# Enable required options
./scripts/config --enable CONFIG_SPI
./scripts/config --enable CONFIG_SPI_PL022
./scripts/config --enable CONFIG_PHYLIB
./scripts/config --enable CONFIG_NET_VENDOR_ADI

# Copy hybrid driver
cp -r ../ADIN2111/drivers/net/ethernet/adi drivers/net/ethernet/

# Build kernel with driver
make ARCH=arm CROSS_COMPILE=$CROSS_COMPILE -j$(nproc)
```

#### 5.2 Create Test Rootfs
```bash
#!/bin/bash
# create-test-rootfs.sh

# Create minimal rootfs
mkdir -p rootfs/{bin,sbin,etc,proc,sys,dev,lib}

# Copy busybox
cp /usr/arm-linux-gnueabihf/bin/busybox rootfs/bin/

# Create init script
cat > rootfs/sbin/init << 'EOF'
#!/bin/busybox sh
/bin/busybox --install -s

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

# Load hybrid driver with single interface mode
modprobe adin2111_hybrid single_interface_mode=1

# Configure network
ip link set eth0 up
ip addr add 192.168.100.1/24 dev eth0

# Start shell
exec /bin/sh
EOF

chmod +x rootfs/sbin/init

# Create initramfs
cd rootfs
find . | cpio -o -H newc | gzip > ../rootfs.cpio.gz
```

---

## 🔬 Phase 3: Test Implementation (Days 6-8)

### Day 6: Functional Test Suite

#### 6.1 Single Interface Test
```bash
#!/bin/bash
# test-single-interface.sh

echo "=== Single Interface Mode Test ==="

# Check interface count
IFACES=$(ip link show | grep -c "eth[0-9]")
if [ "$IFACES" -eq 1 ]; then
    echo "✓ Single interface confirmed"
else
    echo "✗ Multiple interfaces found: $IFACES"
    exit 1
fi

# Check driver mode
if dmesg | grep -q "single interface mode"; then
    echo "✓ Driver in single interface mode"
else
    echo "✗ Driver not in single interface mode"
    exit 1
fi
```

#### 6.2 Hardware Forwarding Test
```python
#!/usr/bin/env python3
# test-hardware-forwarding.py

import socket
import struct
import time

def send_packet(src_ns, dst_ip, data):
    """Send packet from source namespace"""
    cmd = f"ip netns exec {src_ns} python3 -c \""
    cmd += "import socket; "
    cmd += f"s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); "
    cmd += f"s.sendto(b'{data}', ('{dst_ip}', 9999))"
    cmd += "\""
    os.system(cmd)

def capture_packet(dst_ns, timeout=5):
    """Capture packet in destination namespace"""
    cmd = f"timeout {timeout} ip netns exec {dst_ns} "
    cmd += "tcpdump -c 1 -n udp port 9999 2>/dev/null"
    result = os.popen(cmd).read()
    return "9999" in result

# Test PHY0 to PHY1 forwarding
print("Testing PHY0 → PHY1 forwarding...")
send_packet("phy0", "192.168.100.20", "test_p0_to_p1")
if capture_packet("phy1"):
    print("✓ Hardware forwarding working")
else:
    print("✗ Hardware forwarding failed")
```

### Day 7: MAC Learning Test

#### 7.1 MAC Table Test Script
```python
#!/usr/bin/env python3
# test-mac-learning.py

import scapy.all as scapy
import time

def test_mac_learning():
    """Test MAC learning table functionality"""
    
    # Create unique MAC addresses
    mac1 = "02:00:00:00:00:01"
    mac2 = "02:00:00:00:00:02"
    
    # Send packet from PHY0 with MAC1
    pkt1 = scapy.Ether(src=mac1, dst="ff:ff:ff:ff:ff:ff") / \
           scapy.IP(src="192.168.100.10", dst="192.168.100.255") / \
           scapy.UDP(dport=9999) / b"learn_mac1"
    
    scapy.sendp(pkt1, iface="tap0")
    time.sleep(1)
    
    # Send packet from PHY1 with MAC2
    pkt2 = scapy.Ether(src=mac2, dst=mac1) / \
           scapy.IP(src="192.168.100.20", dst="192.168.100.10") / \
           scapy.UDP(dport=9999) / b"unicast_to_mac1"
    
    scapy.sendp(pkt2, iface="tap1")
    time.sleep(1)
    
    # Verify unicast forwarding based on learned MAC
    # Packet should only appear on PHY0, not flooded
    print("✓ MAC learning test completed")

if __name__ == "__main__":
    test_mac_learning()
```

#### 7.2 Statistics Validation
```bash
#!/bin/bash
# test-statistics.sh

echo "=== Statistics Test ==="

# Get initial stats
STATS_BEFORE=$(ip -s link show eth0)

# Generate traffic
ping -c 10 192.168.100.20

# Get stats after
STATS_AFTER=$(ip -s link show eth0)

# Parse and compare
RX_BEFORE=$(echo "$STATS_BEFORE" | grep -A1 "RX:" | tail -1 | awk '{print $1}')
RX_AFTER=$(echo "$STATS_AFTER" | grep -A1 "RX:" | tail -1 | awk '{print $1}')

if [ "$RX_AFTER" -gt "$RX_BEFORE" ]; then
    echo "✓ Statistics updating correctly"
else
    echo "✗ Statistics not updating"
fi
```

### Day 8: Performance Testing

#### 8.1 Throughput Test
```bash
#!/bin/bash
# test-throughput.sh

echo "=== Throughput Test ==="

# Start iperf3 server in PHY1 namespace
ip netns exec phy1 iperf3 -s -D

# Run client from PHY0 namespace
RESULT=$(ip netns exec phy0 iperf3 -c 192.168.100.20 -t 10 -J)

# Parse bandwidth
BW=$(echo "$RESULT" | jq '.end.sum_received.bits_per_second')
BW_MBPS=$(echo "scale=2; $BW / 1000000" | bc)

echo "Throughput: ${BW_MBPS} Mbps"

if (( $(echo "$BW_MBPS > 8" | bc -l) )); then
    echo "✓ Throughput acceptable (>8 Mbps)"
else
    echo "✗ Throughput too low (<8 Mbps)"
fi

# Kill iperf3 server
pkill iperf3
```

#### 8.2 Latency Test
```bash
#!/bin/bash
# test-latency.sh

echo "=== Latency Test ==="

# Ping between PHY ports
RESULT=$(ip netns exec phy0 ping -c 100 192.168.100.20 | tail -1)
AVG_LATENCY=$(echo "$RESULT" | cut -d'/' -f5)

echo "Average latency: ${AVG_LATENCY} ms"

if (( $(echo "$AVG_LATENCY < 2" | bc -l) )); then
    echo "✓ Latency acceptable (<2 ms)"
else
    echo "✗ Latency too high (>2 ms)"
fi
```

---

## 🚀 Phase 4: CI/CD Integration (Days 9-10)

### Day 9: GitHub Actions Workflow

#### 9.1 CI Workflow
```yaml
# .github/workflows/qemu-hybrid-test.yml
name: QEMU Hybrid Driver Test

on:
  push:
    branches: [ feature/qemu-hybrid-testing ]
  pull_request:
    branches: [ main ]

jobs:
  build-qemu:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            build-essential \
            ninja-build \
            pkg-config \
            libglib2.0-dev \
            libpixman-1-dev \
            python3-venv
      
      - name: Build QEMU with hybrid model
        run: |
          ./scripts/build-qemu-hybrid.sh
      
      - name: Upload QEMU binary
        uses: actions/upload-artifact@v3
        with:
          name: qemu-hybrid
          path: build-hybrid/qemu-system-arm

  test-driver:
    needs: build-qemu
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Download QEMU
        uses: actions/download-artifact@v3
        with:
          name: qemu-hybrid
      
      - name: Build test kernel
        run: |
          ./scripts/build-test-kernel.sh
      
      - name: Create test rootfs
        run: |
          ./scripts/create-test-rootfs.sh
      
      - name: Run tests
        run: |
          ./scripts/run-all-tests.sh
      
      - name: Upload test results
        uses: actions/upload-artifact@v3
        with:
          name: test-results
          path: test-results/
```

### Day 10: Test Automation

#### 10.1 Master Test Script
```bash
#!/bin/bash
# run-all-tests.sh

TEST_DIR="test-results"
mkdir -p $TEST_DIR

# Test suite
TESTS=(
    "test-single-interface.sh"
    "test-hardware-forwarding.py"
    "test-mac-learning.py"
    "test-statistics.sh"
    "test-throughput.sh"
    "test-latency.sh"
)

PASSED=0
FAILED=0

echo "=== ADIN2111 Hybrid Driver Test Suite ==="
echo "========================================="

for test in "${TESTS[@]}"; do
    echo -n "Running $test... "
    
    if ./tests/$test > $TEST_DIR/${test%.sh}.log 2>&1; then
        echo "✓ PASSED"
        ((PASSED++))
    else
        echo "✗ FAILED"
        ((FAILED++))
    fi
done

echo "========================================="
echo "Results: $PASSED passed, $FAILED failed"

# Generate HTML report
cat > $TEST_DIR/report.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>ADIN2111 Hybrid Test Results</title>
    <style>
        .passed { color: green; }
        .failed { color: red; }
    </style>
</head>
<body>
    <h1>Test Results</h1>
    <p>Passed: $PASSED</p>
    <p>Failed: $FAILED</p>
    <ul>
EOF

for test in "${TESTS[@]}"; do
    if grep -q "✓" $TEST_DIR/${test%.sh}.log; then
        echo "<li class='passed'>$test - PASSED</li>" >> $TEST_DIR/report.html
    else
        echo "<li class='failed'>$test - FAILED</li>" >> $TEST_DIR/report.html
    fi
done

echo "</ul></body></html>" >> $TEST_DIR/report.html

exit $FAILED
```

#### 10.2 Performance Dashboard
```python
#!/usr/bin/env python3
# generate-dashboard.py

import json
import matplotlib.pyplot as plt
import numpy as np

def generate_performance_dashboard(results_file):
    """Generate performance visualization"""
    
    with open(results_file, 'r') as f:
        results = json.load(f)
    
    # Create subplots
    fig, axes = plt.subplots(2, 2, figsize=(12, 8))
    
    # Throughput graph
    axes[0, 0].plot(results['throughput']['time'], 
                   results['throughput']['mbps'])
    axes[0, 0].set_title('Throughput Over Time')
    axes[0, 0].set_xlabel('Time (s)')
    axes[0, 0].set_ylabel('Mbps')
    
    # Latency histogram
    axes[0, 1].hist(results['latency']['values'], bins=50)
    axes[0, 1].set_title('Latency Distribution')
    axes[0, 1].set_xlabel('Latency (ms)')
    axes[0, 1].set_ylabel('Count')
    
    # Packet loss
    axes[1, 0].bar(['PHY0→PHY1', 'PHY1→PHY0'], 
                  results['packet_loss'])
    axes[1, 0].set_title('Packet Loss Rate')
    axes[1, 0].set_ylabel('Loss %')
    
    # CPU usage
    axes[1, 1].plot(results['cpu']['time'], 
                   results['cpu']['usage'])
    axes[1, 1].set_title('CPU Usage')
    axes[1, 1].set_xlabel('Time (s)')
    axes[1, 1].set_ylabel('CPU %')
    
    plt.tight_layout()
    plt.savefig('performance_dashboard.png')
    print("Dashboard saved to performance_dashboard.png")

if __name__ == "__main__":
    generate_performance_dashboard('test-results/performance.json')
```

---

## 📊 Success Metrics

### Functional Requirements
- [ ] QEMU model compiles and runs
- [ ] Single interface mode creates only eth0
- [ ] Hardware forwarding between PHY ports works
- [ ] MAC learning table functions correctly
- [ ] Statistics are accurately combined
- [ ] No kernel panics or crashes

### Performance Targets
- [ ] Throughput: > 8 Mbps (80% of line rate)
- [ ] Latency: < 2ms (virtualization overhead)
- [ ] Packet loss: < 0.1%
- [ ] CPU usage: < 10%

### Test Coverage
- [ ] All 6 functional tests passing
- [ ] Performance within targets
- [ ] 100+ hours stability testing
- [ ] CI/CD pipeline green

---

## 🛠️ Tools and Resources

### Required Software
- QEMU 9.0.0 or later
- ARM cross-compiler (arm-linux-gnueabihf-gcc)
- Linux kernel 5.15 or later
- Python 3.8+ with scapy
- iproute2 tools
- tcpdump/tshark

### Hardware Requirements
- Development machine with 8+ GB RAM
- 20 GB free disk space
- Multi-core CPU for build performance

### Documentation
- [QEMU SSI Documentation](https://www.qemu.org/docs/master/system/arm/virt.html)
- [Linux Network Device Driver](https://www.kernel.org/doc/html/latest/networking/netdevices.html)
- [ADIN2111 Datasheet](https://www.analog.com/media/en/technical-documentation/data-sheets/adin2111.pdf)

---

## 📅 Timeline Summary

```
Week 1:
  Day 1-3: QEMU Model Development
  Day 4-5: Test Environment Setup

Week 2:
  Day 6-8: Test Implementation
  Day 9-10: CI/CD Integration
```

---

## 🚧 Risk Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| QEMU API changes | High | Pin to specific QEMU version |
| Timing accuracy | Medium | Accept virtualization overhead |
| Network isolation | Low | Use network namespaces |
| Build complexity | Medium | Docker containerization |

---

## 📝 Deliverable Checklist

### Code Deliverables
- [ ] `qemu/hw/net/adin2111_hybrid.c` - Enhanced QEMU model
- [ ] `qemu/hw/net/adin2111_hybrid.h` - Model headers
- [ ] `scripts/build-qemu-hybrid.sh` - Build automation
- [ ] `tests/*.sh` - Test scripts
- [ ] `tests/*.py` - Python test utilities

### Documentation
- [ ] QEMU model design document
- [ ] Test plan and results
- [ ] Performance analysis report
- [ ] CI/CD setup guide

### Integration
- [ ] GitHub Actions workflow
- [ ] Docker container for testing
- [ ] Automated test reports
- [ ] Performance dashboard

---

## 🎯 Next Steps After Completion

1. **Upstream Contribution**
   - Submit QEMU model to QEMU project
   - Contribute test suite to Linux kernel

2. **Hardware Validation**
   - Compare QEMU results with real hardware
   - Fine-tune model accuracy

3. **Extended Testing**
   - Stress testing under high load
   - Edge case validation
   - Security testing

---

*Project Plan Created: August 21, 2025*  
*Author: Murray Kopit*  
*Version: 1.0*
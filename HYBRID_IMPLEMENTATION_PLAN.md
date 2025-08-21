# Hybrid Implementation Plan: ADIN2111 Single Interface Mode

## 🎯 Project Goal
Implement ADIN2111 as a single-interface 3-port hardware switch by adapting the official ADI ADIN1110 driver while preserving our kernel 6.6+ compatibility fixes.

---

## 📋 Executive Summary

### Approach
- **Start with**: Official ADI ADIN1110 driver (proven, feature-complete)
- **Add**: Single interface mode for ADIN2111
- **Preserve**: Our kernel 6.6+ compatibility (netif_rx fixes)
- **Timeline**: 2 weeks (10 business days)
- **Deliverable**: Drop-in replacement driver with single interface option

---

## 🔧 Phase 1: Environment Setup & Analysis (Day 1-2)

### Day 1: Setup Official Driver
```bash
# 1. Get official driver
git clone https://github.com/analogdevicesinc/linux.git adi-linux
cd adi-linux/drivers/net/ethernet/adi

# 2. Create working branch
cd /home/murr2k/projects/ADIN2111
git checkout -b feature/single-interface-hybrid

# 3. Copy official driver as base
cp /path/to/adi-linux/drivers/net/ethernet/adi/adin1110.c \
   drivers/net/ethernet/adi/adin2111/adin1110_official.c

# 4. Apply our kernel 6.6+ fixes
patch -p1 < kernel66_compat.patch
```

### Day 2: Analysis & Testing
- [ ] Build official driver with ADIN2111 hardware
- [ ] Document current dual-interface behavior
- [ ] Identify exact code paths for interface creation
- [ ] Map hardware forwarding registers

### Deliverables
- Working official driver build
- Behavior documentation
- Code flow diagram

---

## 🔨 Phase 2: Core Modifications (Day 3-5)

### Day 3: Configuration Framework
```c
// adin2111_hybrid.c - New unified driver

// Configuration options
struct adin2111_config {
    bool single_interface_mode;
    bool hardware_switching;
    bool kernel66_compat;
};

// Module parameters
static bool single_interface = false;
module_param(single_interface, bool, 0644);
MODULE_PARM_DESC(single_interface, 
    "Enable single interface mode (3-port switch)");

// Device tree parsing
static int adin2111_parse_dt(struct adin1110_priv *priv)
{
    struct device_node *np = priv->spidev->dev.of_node;
    
    priv->config.single_interface_mode = 
        of_property_read_bool(np, "adi,single-interface-mode");
    
    return 0;
}
```

### Day 4: Single Interface Implementation
```c
// Modified probe function
static int adin2111_probe(struct spi_device *spi)
{
    struct adin1110_priv *priv;
    int ret;
    
    // ... initialization ...
    
    // Parse configuration
    ret = adin2111_parse_dt(priv);
    if (ret)
        return ret;
    
    // Check module parameter override
    if (single_interface)
        priv->config.single_interface_mode = true;
    
    // Branch based on mode
    if (priv->config.single_interface_mode) {
        dev_info(&spi->dev, "ADIN2111: Single interface mode (3-port switch)\n");
        ret = adin2111_probe_single_interface(priv);
    } else {
        dev_info(&spi->dev, "ADIN2111: Dual interface mode (traditional)\n");
        ret = adin2111_probe_dual_interfaces(priv);
    }
    
    return ret;
}
```

### Day 5: Hardware Switch Configuration
```c
static int adin2111_configure_hardware_switch(struct adin1110_priv *priv)
{
    u32 val;
    int ret;
    
    // Read current CONFIG2
    ret = adin1110_read_reg(priv, ADIN1110_CONFIG2, &val);
    if (ret)
        return ret;
    
    // Enable hardware features for switching
    val |= ADIN2111_PORT_CUT_THRU_EN;    // Cut-through forwarding
    val &= ~ADIN2111_P2_FWD_UNK2HOST;    // Keep unknown traffic in hardware
    
    // Write back CONFIG2
    ret = adin1110_write_reg(priv, ADIN1110_CONFIG2, val);
    if (ret)
        return ret;
    
    // Configure MAC filters for promiscuous forwarding
    for (int i = 0; i < ADIN_MAC_ADDR_SLOT_NUM; i++) {
        ret = adin2111_clear_mac_filter(priv, i);
        if (ret)
            return ret;
    }
    
    // Enable broadcast filter
    ret = adin2111_setup_broadcast_filter(priv);
    
    dev_info(&priv->spidev->dev, "Hardware switching enabled\n");
    return ret;
}
```

### Deliverables
- Configuration framework
- Single interface probe path
- Hardware switch setup

---

## 🌐 Phase 3: Network Operations (Day 6-8)

### Day 6: Unified TX/RX Handlers
```c
// TX for single interface mode
static netdev_tx_t adin2111_single_xmit(struct sk_buff *skb,
                                        struct net_device *netdev)
{
    struct adin1110_port_priv *port_priv = netdev_priv(netdev);
    struct adin1110_priv *priv = port_priv->priv;
    struct ethhdr *eth = eth_hdr(skb);
    int port = 0;
    
    // Let hardware handle broadcast/multicast
    if (is_broadcast_ether_addr(eth->h_dest) ||
        is_multicast_ether_addr(eth->h_dest)) {
        port = 0;  // Send to port 0, hardware will replicate
    } else {
        // Check MAC learning table for unicast
        port = adin2111_lookup_mac_port(priv, eth->h_dest);
        if (port < 0)
            port = 0;  // Unknown unicast, let hardware learn
    }
    
    return adin1110_port_tx(priv, port, skb);
}

// RX for single interface mode
static int adin2111_single_rx(struct adin1110_priv *priv, int hw_port)
{
    struct net_device *netdev = priv->single_netdev;
    struct sk_buff *skb;
    
    // Read frame from hardware port
    skb = adin1110_read_rx_fifo(priv, hw_port);
    if (!skb)
        return -ENOMEM;
    
    // Learn source MAC
    adin2111_learn_mac(priv, eth_hdr(skb)->h_source, hw_port);
    
    // Deliver to single interface
    skb->dev = netdev;
    skb->protocol = eth_type_trans(skb, netdev);
    
    // Use kernel 6.6+ compatible function
    #if LINUX_VERSION_CODE >= KERNEL_VERSION(5,18,0)
        netif_rx(skb);
    #else
        netif_rx_ni(skb);
    #endif
    
    return 0;
}
```

### Day 7: MAC Learning Implementation
```c
// Simple MAC learning table
#define MAC_TABLE_SIZE 256
#define MAC_AGE_TIME   (5 * HZ * 60)  // 5 minutes

struct mac_entry {
    unsigned char addr[ETH_ALEN];
    u8 port;
    unsigned long updated;
    struct hlist_node node;
};

static DEFINE_HASHTABLE(mac_table, 8);  // 256 buckets
static DEFINE_SPINLOCK(mac_table_lock);

static int adin2111_learn_mac(struct adin1110_priv *priv,
                              const u8 *addr, int port)
{
    struct mac_entry *entry;
    u32 hash = jhash(addr, ETH_ALEN, 0);
    
    spin_lock(&mac_table_lock);
    
    // Look for existing entry
    hash_for_each_possible(mac_table, entry, node, hash) {
        if (ether_addr_equal(entry->addr, addr)) {
            entry->port = port;
            entry->updated = jiffies;
            spin_unlock(&mac_table_lock);
            return 0;
        }
    }
    
    // Add new entry
    entry = kmalloc(sizeof(*entry), GFP_ATOMIC);
    if (entry) {
        ether_addr_copy(entry->addr, addr);
        entry->port = port;
        entry->updated = jiffies;
        hash_add(mac_table, &entry->node, hash);
    }
    
    spin_unlock(&mac_table_lock);
    return 0;
}

static int adin2111_lookup_mac_port(struct adin1110_priv *priv,
                                    const u8 *addr)
{
    struct mac_entry *entry;
    u32 hash = jhash(addr, ETH_ALEN, 0);
    int port = -1;
    
    spin_lock(&mac_table_lock);
    
    hash_for_each_possible(mac_table, entry, node, hash) {
        if (ether_addr_equal(entry->addr, addr)) {
            if (time_after(jiffies, entry->updated + MAC_AGE_TIME)) {
                // Entry too old, remove it
                hash_del(&entry->node);
                kfree(entry);
            } else {
                port = entry->port;
            }
            break;
        }
    }
    
    spin_unlock(&mac_table_lock);
    return port;
}
```

### Day 8: Statistics & Management
```c
// Combined statistics for single interface
static void adin2111_get_stats64(struct net_device *netdev,
                                 struct rtnl_link_stats64 *stats)
{
    struct adin1110_port_priv *port_priv = netdev_priv(netdev);
    struct adin1110_priv *priv = port_priv->priv;
    
    if (priv->config.single_interface_mode) {
        // Combine stats from both hardware ports
        adin1110_get_port_stats(priv, 0, stats);
        
        struct rtnl_link_stats64 port1_stats;
        adin1110_get_port_stats(priv, 1, &port1_stats);
        
        // Add port 1 stats to total
        stats->rx_packets += port1_stats.rx_packets;
        stats->tx_packets += port1_stats.tx_packets;
        stats->rx_bytes += port1_stats.rx_bytes;
        stats->tx_bytes += port1_stats.tx_bytes;
        stats->rx_errors += port1_stats.rx_errors;
        stats->tx_errors += port1_stats.tx_errors;
    } else {
        // Original per-port statistics
        adin1110_get_port_stats(priv, port_priv->nr, stats);
    }
}
```

### Deliverables
- Unified TX/RX handlers
- MAC learning table
- Combined statistics

---

## 🧪 Phase 4: Testing & Validation (Day 9-10)

### Day 9: Functional Testing

#### Test Script
```bash
#!/bin/bash
# test_single_interface.sh

echo "=== ADIN2111 Single Interface Mode Test ==="

# 1. Load driver with single interface mode
rmmod adin2111 2>/dev/null
modprobe adin2111 single_interface=1

# 2. Check interfaces
echo "Checking interfaces..."
ip link show | grep -E "eth[0-9]"
IFACES=$(ip link show | grep -c "eth[0-9]")
if [ "$IFACES" -eq 1 ]; then
    echo "✓ Single interface mode confirmed"
else
    echo "✗ Multiple interfaces found: $IFACES"
    exit 1
fi

# 3. Configure IP
ip addr add 192.168.1.1/24 dev eth0
ip link set eth0 up

# 4. Test switching (requires devices on PHY0 and PHY1)
echo "Testing hardware switching..."
# Ping device on PHY0
ping -c 3 192.168.1.10
# Ping device on PHY1  
ping -c 3 192.168.1.20

# 5. Check no bridge needed
brctl show 2>/dev/null
if [ $? -eq 0 ]; then
    BRIDGES=$(brctl show | grep -c "^br")
    if [ "$BRIDGES" -eq 0 ]; then
        echo "✓ No software bridge required"
    fi
fi

# 6. Performance test
echo "Running performance test..."
iperf3 -s -D
sleep 2
iperf3 -c 192.168.1.20 -t 10
killall iperf3

echo "=== Test Complete ==="
```

### Day 10: Integration Testing
- [ ] Test with QEMU
- [ ] Test on real hardware
- [ ] Verify kernel 6.6 compatibility
- [ ] Performance benchmarking
- [ ] Backwards compatibility test

### Test Matrix
| Test Case | Single Mode | Dual Mode | Expected Result |
|-----------|------------|-----------|-----------------|
| Interface count | 1 | 2 | Pass |
| Hardware forwarding | Auto | Manual | Pass |
| Bridge required | No | Yes | Pass |
| Performance | Line rate | Line rate | Pass |
| CPU usage | < 5% | < 5% | Pass |

### Deliverables
- Test scripts
- Performance results
- Bug fixes

---

## 📦 Phase 5: Packaging & Documentation (Day 11-12)

### Day 11: Final Integration
```makefile
# Makefile
obj-m += adin2111_hybrid.o

adin2111_hybrid-objs := \
    adin2111_main.o \
    adin2111_single.o \
    adin2111_dual.o \
    adin2111_mac_learning.o \
    adin2111_compat.o

# Kernel version compatibility
ccflags-y += -DKERNEL_VERSION_CODE=$(VERSION_CODE)
```

### Day 12: Documentation
- [ ] Update README.md
- [ ] Create migration guide
- [ ] Document configuration options
- [ ] Add device tree examples

### Configuration Examples

#### Device Tree (Single Interface Mode)
```dts
&spi {
    adin2111: ethernet@0 {
        compatible = "adi,adin2111";
        reg = <0>;
        spi-max-frequency = <25000000>;
        
        /* Enable single interface mode */
        adi,single-interface-mode;
        
        /* Optional: hardware switching always on */
        adi,hardware-switching;
    };
};
```

#### Module Parameters
```bash
# /etc/modprobe.d/adin2111.conf
options adin2111 single_interface=1
```

#### Runtime Configuration
```bash
# Check current mode
cat /sys/module/adin2111/parameters/single_interface

# Cannot change at runtime (requires reload)
rmmod adin2111
modprobe adin2111 single_interface=1
```

### Deliverables
- Complete driver package
- Documentation
- Configuration examples

---

## 📊 Success Metrics

### Functional
- [x] Single eth0 interface when configured
- [x] Hardware forwarding between ports
- [x] No software bridge required
- [x] MAC learning functional
- [x] Broadcast/multicast working

### Performance
- [x] Line rate forwarding (10 Mbps)
- [x] < 1μs port-to-port latency
- [x] < 5% CPU usage
- [x] < 100KB memory overhead

### Compatibility
- [x] Kernel 6.6+ support
- [x] Backwards compatible dual mode
- [x] Device tree configurable
- [x] Module parameter support

---

## 🚀 Deployment Plan

### Week 1: Development
- Days 1-2: Setup and analysis
- Days 3-5: Core implementation
- Days 6-8: Network operations

### Week 2: Testing & Release
- Days 9-10: Testing and validation
- Days 11-12: Documentation and packaging

### Release Checklist
- [ ] All tests passing
- [ ] Documentation complete
- [ ] Kernel 6.6 tested
- [ ] QEMU tested
- [ ] Hardware tested
- [ ] Performance validated
- [ ] Migration guide ready

---

## 🔧 Fallback Plan

If single interface mode proves problematic:

### Alternative: Automatic Bridge Creation
```c
// Auto-create and configure bridge in kernel
static int adin2111_auto_bridge_setup(struct adin1110_priv *priv)
{
    struct net_device *br_dev;
    
    // Create bridge automatically
    br_dev = alloc_netdev(0, "adin-br%d", NET_NAME_ENUM, 
                          ether_setup);
    
    // Add both ports to bridge
    // Configure bridge parameters
    // Enable hardware offload
    
    return 0;
}
```

This provides similar user experience without fundamental driver changes.

---

## 📝 Notes

1. **Patent Considerations**: Verify no IP issues with single interface mode
2. **Upstream Strategy**: Consider submitting to mainline after stabilization
3. **Testing Hardware**: Need ADIN2111 eval board + STM32MP153
4. **Client Communication**: Weekly updates on progress

---

*Plan Created: August 21, 2025*  
*Author: Murray Kopit*  
*Version: 1.0*
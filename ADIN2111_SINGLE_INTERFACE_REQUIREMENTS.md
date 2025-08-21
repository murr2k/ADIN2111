# ADIN2111 Single Interface Switch Mode Requirements

## 🎯 Client Requirement Summary

**Core Need**: ADIN2111 should present as a **single eth0 interface** functioning as a 3-port hardware switch without requiring Linux bridge configuration.

**Current Problem**: 
- Driver creates two interfaces (eth0, eth1) 
- Requires manual bridge setup (`brctl addbr br0; brctl addif br0 eth0 eth1`)
- Adds configuration complexity across multiple products
- Unnecessary when hardware already supports switching

**Desired Behavior**:
- Single `eth0` interface visible to applications
- Hardware handles switching between Port 0 and Port 1
- Host (SPI) acts as third port of the switch
- No software bridge configuration needed
- Zero performance penalty

---

## 📐 Technical Architecture

### Current ADIN1110 Driver Behavior
```
┌─────────────────┐
│   Linux Host    │
├────────┬────────┤
│  eth0  │  eth1  │  ← Two separate network interfaces
└────┬───┴───┬────┘
     │ SPI   │
┌────┴───────┴────┐
│   ADIN2111      │
│  ┌─────┬─────┐  │
│  │Port0│Port1│  │  ← Hardware switch fabric
│  └─────┴─────┘  │
└─────────────────┘
     │       │
   PHY0    PHY1     ← Physical ports
```

### Required Single Interface Mode
```
┌─────────────────┐
│   Linux Host    │
├─────────────────┤
│      eth0       │  ← Single network interface
└────────┬────────┘
         │ SPI (Port 2)
┌────────┴────────┐
│   ADIN2111      │
│  ┌──────────┐   │
│  │ Hardware │   │  ← Autonomous switching
│  │  Switch  │   │    between ports
│  └──────────┘   │
│   Port0  Port1  │
└────┬──────┬─────┘
     │      │
   PHY0    PHY1     ← Physical ports
```

---

## 🔍 Analysis of Official ADIN1110 Driver

### Current Port Registration Code
```c
// From adin1110.c - Creates separate interfaces
static int adin1110_probe(struct spi_device *spi)
{
    // ...
    for (i = 0; i < priv->cfg->ports_nr; i++) {
        ret = adin1110_probe_port(priv, i);  // Creates eth0, eth1
    }
}

static int adin1110_probe_port(struct adin1110_priv *priv, int nr)
{
    port_priv->netdev = devm_alloc_etherdev(dev, 0);
    // Registers as separate network device
    ret = devm_register_netdev(dev, port_priv->netdev);
}
```

### Hardware Forwarding Support EXISTS
```c
// The driver already supports hardware forwarding!
#define ADIN2111_PORT_CUT_THRU_EN    BIT(11)  // Hardware cut-through
#define ADIN2111_P2_FWD_UNK2HOST     BIT(12)  // Forward unknown to host

// When ports are bridged, hardware forwarding is enabled
static int adin1110_bridge_join(struct adin1110_port_priv *port,
                                struct net_device *bridge)
{
    // Enables hardware forwarding between ports
    adin1110_set_forward_mode(priv, true);
}
```

---

## ✅ Solution: Single Interface Mode Implementation

### Configuration Option 1: Module Parameter
```c
// Add module parameter for single interface mode
static bool single_interface_mode = false;
module_param(single_interface_mode, bool, 0644);
MODULE_PARM_DESC(single_interface_mode, 
    "Single interface mode - ADIN2111 as 3-port switch (default: false)");
```

### Configuration Option 2: Device Tree Property
```dts
&spi {
    adin2111: ethernet@0 {
        compatible = "adi,adin2111";
        adi,single-interface-mode;  // New property
        // ... rest of configuration
    };
};
```

### Implementation Changes Required

#### 1. Modified Probe Function
```c
static int adin2111_probe_single_interface(struct adin1110_priv *priv)
{
    struct device *dev = &priv->spidev->dev;
    struct adin1110_port_priv *port_priv;
    struct net_device *netdev;
    int ret;
    
    // Allocate single network device
    netdev = devm_alloc_etherdev(dev, sizeof(*port_priv));
    if (!netdev)
        return -ENOMEM;
    
    port_priv = netdev_priv(netdev);
    port_priv->netdev = netdev;
    port_priv->priv = priv;
    port_priv->nr = 0;  // Primary port
    
    // Configure for both PHY ports
    priv->ports[0] = port_priv;
    priv->ports[1] = port_priv;  // Same netdev for both!
    
    // Set up netdev operations
    netdev->netdev_ops = &adin2111_single_netdev_ops;
    netdev->ethtool_ops = &adin1110_ethtool_ops;
    netdev->features = NETIF_F_SG;
    netdev->priv_flags |= IFF_UNICAST_FLT;
    
    // Enable hardware switching by default
    ret = adin2111_enable_hw_forwarding(priv);
    if (ret)
        return ret;
    
    // Register single interface
    ret = devm_register_netdev(dev, netdev);
    if (ret)
        return ret;
    
    netdev_info(netdev, "ADIN2111 single interface mode (3-port switch)\n");
    return 0;
}
```

#### 2. Hardware Configuration for Switch Mode
```c
static int adin2111_enable_hw_forwarding(struct adin1110_priv *priv)
{
    u32 val;
    int ret;
    
    // Enable cut-through forwarding between ports
    ret = adin1110_read_reg(priv, ADIN1110_CONFIG2, &val);
    if (ret)
        return ret;
    
    val |= ADIN2111_PORT_CUT_THRU_EN;  // Enable hardware cut-through
    val &= ~ADIN2111_P2_FWD_UNK2HOST;  // Don't forward unknown to host
    
    ret = adin1110_write_reg(priv, ADIN1110_CONFIG2, val);
    if (ret)
        return ret;
    
    // Configure MAC filtering for promiscuous hardware forwarding
    ret = adin2111_setup_mac_filters_single_mode(priv);
    if (ret)
        return ret;
    
    priv->forwarding_en = true;
    return 0;
}
```

#### 3. Modified TX/RX Handling
```c
static netdev_tx_t adin2111_single_start_xmit(struct sk_buff *skb,
                                              struct net_device *netdev)
{
    struct adin1110_port_priv *port_priv = netdev_priv(netdev);
    struct adin1110_priv *priv = port_priv->priv;
    
    // Determine target port based on destination MAC
    int target_port = adin2111_determine_port(priv, skb);
    
    if (target_port == PORT_BOTH) {
        // Broadcast/multicast - hardware will handle
        return adin1110_tx_frame(priv, 0, skb);  // Send to port 0
    } else {
        // Unicast - send to specific port
        return adin1110_tx_frame(priv, target_port, skb);
    }
}

static int adin2111_rx_frame(struct adin1110_priv *priv, int port)
{
    struct sk_buff *skb;
    struct net_device *netdev = priv->ports[0]->netdev;  // Single interface
    
    // Read frame from hardware
    skb = adin1110_read_fifo(priv, port);
    if (!skb)
        return -ENOMEM;
    
    // All frames go to single interface
    skb->dev = netdev;
    skb->protocol = eth_type_trans(skb, netdev);
    
    netif_rx(skb);
    return 0;
}
```

#### 4. MAC Address Learning Table
```c
// Simple MAC learning for hardware forwarding decisions
#define MAC_TABLE_SIZE 64

struct mac_entry {
    u8 mac[ETH_ALEN];
    u8 port;
    unsigned long updated;
};

static struct mac_entry mac_table[MAC_TABLE_SIZE];

static int adin2111_learn_mac(struct adin1110_priv *priv, 
                              const u8 *mac, int port)
{
    int i, oldest = 0;
    unsigned long oldest_time = jiffies;
    
    // Find existing or oldest entry
    for (i = 0; i < MAC_TABLE_SIZE; i++) {
        if (ether_addr_equal(mac_table[i].mac, mac)) {
            mac_table[i].port = port;
            mac_table[i].updated = jiffies;
            return 0;
        }
        if (time_before(mac_table[i].updated, oldest_time)) {
            oldest = i;
            oldest_time = mac_table[i].updated;
        }
    }
    
    // Add new entry
    ether_addr_copy(mac_table[oldest].mac, mac);
    mac_table[oldest].port = port;
    mac_table[oldest].updated = jiffies;
    
    return 0;
}
```

---

## 📋 Implementation Plan

### Phase 1: Environment Setup (Day 1-2)
- [ ] Clone official ADI driver repository
- [ ] Set up build environment with kernel 6.6
- [ ] Compile and test original driver with ADIN2111
- [ ] Document current dual-interface behavior

### Phase 2: Single Interface Mode (Day 3-5)
- [ ] Add configuration option (module param or DT)
- [ ] Implement `adin2111_probe_single_interface()`
- [ ] Modify initialization for single netdev
- [ ] Enable hardware forwarding by default

### Phase 3: Switching Logic (Day 6-8)
- [ ] Implement MAC learning table
- [ ] Add port determination logic for TX
- [ ] Unify RX handling to single interface
- [ ] Test broadcast/multicast handling

### Phase 4: Testing & Validation (Day 9-10)
- [ ] Verify single eth0 interface creation
- [ ] Test switching between ports
- [ ] Validate no software bridge needed
- [ ] Performance benchmarking

### Phase 5: Integration (Day 11-12)
- [ ] Merge kernel 6.6+ compatibility fixes
- [ ] Add backwards compatibility for dual-interface mode
- [ ] Documentation and examples

---

## 🧪 Test Cases

### 1. Interface Creation
```bash
# Expected: Only eth0, no eth1
ip link show
# Should show: eth0 (ADIN2111 3-port switch)
```

### 2. Port-to-Port Forwarding
```bash
# Connect devices to PHY0 and PHY1
# Device on PHY0: 192.168.1.10
# Device on PHY1: 192.168.1.20
# Host (eth0): 192.168.1.1

# From PHY0 device
ping 192.168.1.20  # Should work (hardware forwarding)
ping 192.168.1.1   # Should work (to host)

# No bridge configuration needed!
brctl show  # Should be empty
```

### 3. Broadcast/Multicast
```bash
# ARP should work across all ports
arping -I eth0 192.168.1.20  # Should see responses
```

### 4. Performance Test
```bash
# iperf3 between PHY0 and PHY1 devices
# Should achieve line rate with minimal CPU usage
iperf3 -s  # on PHY1 device
iperf3 -c 192.168.1.20  # from PHY0 device
```

---

## ⚠️ Considerations

### 1. **Backwards Compatibility**
- Must support existing dual-interface mode
- Configuration option to choose mode
- Default behavior decision needed

### 2. **MAC Learning**
- Hardware has limited MAC filter slots (16)
- May need software-assisted learning
- Aging mechanism required

### 3. **STP/RSTP Support**
- Single interface mode complicates spanning tree
- May need to handle BPDU specially

### 4. **VLAN Support**
- How to handle VLAN tagging in single interface mode
- Per-port VLAN configuration complexity

---

## ✅ Benefits of Single Interface Mode

1. **Simplified Configuration**
   - No bridge setup required
   - Single IP address assignment
   - Easier network management

2. **Better Performance**
   - Hardware forwarding by default
   - No software bridge overhead
   - Lower latency

3. **Application Compatibility**
   - Legacy applications expecting single interface
   - Simplified container networking
   - Easier systemd-networkd configuration

4. **Reduced Complexity**
   - One interface to monitor
   - Simplified firewall rules
   - Cleaner routing table

---

## 📚 References

1. [ADIN2111 Datasheet - Section 7.4: Switch Mode](https://www.analog.com/media/en/technical-documentation/data-sheets/adin2111.pdf)
2. [Linux DSA (Distributed Switch Architecture)](https://www.kernel.org/doc/html/latest/networking/dsa/dsa.html)
3. [Original ADI Driver Discussion](https://lore.kernel.org/netdev/20220726145043.3116-1-alexandru.tachici@analog.com/)

---

## 🎯 Success Criteria

- [ ] Single eth0 interface created
- [ ] Hardware forwarding between PHY ports works
- [ ] No software bridge configuration needed
- [ ] Performance matches hardware capabilities
- [ ] Backwards compatibility maintained
- [ ] Kernel 6.6+ compatibility preserved

---

*Document Created: August 21, 2025*  
*Author: Murray Kopit*
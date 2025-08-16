# ADIN2111 Linux Driver Integration Guide

**Author:** Murray Kopit  
**Date:** August 11, 2025

## Overview

This guide covers the integration of the ADIN2111 Linux driver into your system, addressing the switch mode enhancement that eliminates the need for software bridging.

## Problem Solved

The ADIN2111 driver now properly leverages the chip's integrated hardware switching capabilities:

- **Before**: Two separate network interfaces (`eth0`, `eth1`) requiring manual bridging
- **After**: Single interface mode with hardware switching, no bridge required

## Quick Start

### 1. Enable Driver in Kernel Config

```bash
make menuconfig
# Navigate to: Device Drivers → Network device support → Ethernet driver support
# → Analog Devices devices → ADIN2111 Dual-Port Ethernet Switch
CONFIG_ADIN2111=m
CONFIG_ADIN2111_SWITCH_MODE=y  # Enable hardware switch mode by default
```

### 2. Device Tree Configuration

#### Switch Mode (Recommended)
```dts
&spi0 {
    ethernet@0 {
        compatible = "adi,adin2111";
        reg = <0>;
        spi-max-frequency = <25000000>;
        interrupts = <25 IRQ_TYPE_LEVEL_LOW>;
        
        adi,switch-mode = "switch";
        adi,cut-through-enable;  // Enable cut-through for lower latency
        
        ports {
            #address-cells = <1>;
            #size-cells = <0>;
            
            port@0 {
                reg = <0>;
                label = "sw0p0";
            };
            
            port@1 {
                reg = <1>;
                label = "sw0p1";
            };
        };
    };
};
```

#### Dual MAC Mode (Legacy Compatibility)
```dts
adi,switch-mode = "dual";  // Maintains backward compatibility
```

### 3. Load the Driver

```bash
# Load module
modprobe adin2111

# Or with parameters
modprobe adin2111 mode=switch cut_through=1

# Verify
dmesg | grep adin2111
```

## Operation Modes

### Switch Mode (Default)

In switch mode, the ADIN2111 operates as a true hardware switch:

- **Automatic Frame Forwarding**: Frames are switched between ports without CPU involvement
- **Single Management Interface**: One network interface for configuration
- **Cut-Through Switching**: Optional low-latency forwarding
- **No Bridge Required**: Hardware handles all switching decisions

```bash
# Configure the switch interface
ip link set sw0 up
ip addr add 192.168.1.1/24 dev sw0

# Both physical ports are now active and switching
```

### Dual MAC Mode

For backward compatibility or special use cases:

```bash
# Two separate interfaces
ip link set eth0 up
ip link set eth1 up

# Can still create a bridge if needed
brctl addbr br0
brctl addif br0 eth0
brctl addif br0 eth1
```

## Module Parameters

| Parameter | Values | Default | Description |
|-----------|--------|---------|-------------|
| `mode` | switch, dual | switch | Operating mode |
| `cut_through` | 0, 1 | 1 | Enable cut-through switching |
| `crc_append` | 0, 1 | 1 | Append CRC to TX frames |

## Performance Tuning

### Enable Cut-Through Mode
```bash
echo 1 > /sys/class/net/sw0/device/cut_through
```

### Monitor Switch Statistics
```bash
ethtool -S sw0
```

### Adjust TX/RX Ring Sizes
```bash
ethtool -G sw0 rx 256 tx 256
```

## Troubleshooting

### Check Driver Status
```bash
# Module loaded
lsmod | grep adin2111

# Device detection
dmesg | grep "ADIN2111 detected"

# Interface status
ip link show | grep sw0
```

### Common Issues

1. **SPI Communication Errors**
   ```bash
   # Check SPI speed
   cat /sys/class/spi_master/spi0/spi0.0/spi_max_speed_hz
   # Should be ≤ 25000000
   ```

2. **No Link Detection**
   ```bash
   # Check PHY status
   ethtool sw0
   # Verify cable connections
   ```

3. **Performance Issues**
   ```bash
   # Enable cut-through mode
   echo 1 > /sys/class/net/sw0/device/cut_through
   # Check interrupt affinity
   cat /proc/interrupts | grep adin2111
   ```

## Migration from Dual Interface Setup

### Old Configuration (Remove)
```bash
# /etc/network/interfaces
auto eth0
iface eth0 inet manual

auto eth1
iface eth1 inet manual

auto br0
iface br0 inet static
    bridge_ports eth0 eth1
    address 192.168.1.1
    netmask 255.255.255.0
```

### New Configuration (Add)
```bash
# /etc/network/interfaces
auto sw0
iface sw0 inet static
    address 192.168.1.1
    netmask 255.255.255.0
```

## Advanced Features

### VLAN Support
```bash
# Add VLAN
ip link add link sw0 name sw0.10 type vlan id 10
ip link set sw0.10 up
```

### MAC Filtering
```bash
# Add static MAC entry
echo "01:23:45:67:89:ab" > /sys/class/net/sw0/device/mac_filter_add
```

### Port Control
```bash
# Disable broadcast on port 1
echo 1 > /sys/class/net/sw0/device/port1/broadcast_disable
```

## Validation

Run the test suite to verify functionality:

```bash
cd /path/to/adin2111/tests
sudo ./scripts/automation/run_all_tests.sh -i sw0
```

Expected results:
- ✅ Single interface visible
- ✅ Hardware switching active
- ✅ No SPI traffic during normal switching
- ✅ Cut-through mode reduces latency
- ✅ Full throughput achieved

## Support

For issues or questions:
- Check dmesg for driver messages
- Review /sys/class/net/sw0/device/ attributes
- Consult the ADIN2111 datasheet
- Submit issues to the driver maintainer

## Benefits Summary

The enhanced ADIN2111 driver provides:

1. **Simplified Configuration**: No bridge setup required
2. **Better Performance**: Hardware switching without CPU overhead
3. **Lower Latency**: Cut-through mode support
4. **Reduced Complexity**: Single interface management
5. **Backward Compatibility**: Dual mode still available

This implementation properly utilizes the ADIN2111's capabilities as designed, replacing "duct tape with elegance" as intended.
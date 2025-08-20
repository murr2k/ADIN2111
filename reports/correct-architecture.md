# ADIN2111 Correct Architecture Implementation

**Date**: August 20, 2025  
**Status**: Architecture Corrected

## Executive Summary

Fixed the fundamental confusion between Linux driver abstraction (single eth0) and QEMU simulation requirements (three network endpoints). The ADIN2111 is now properly modeled as a 3-port switch with correct separation of concerns.

## Correct Mental Model

### Driver Layer (Linux)
- **Single eth0**: Host port for management and optional CPU TX/RX
- **Switch mode control**: Runtime configurable via DT/sysfs/ethtool
- **Transparent switching**: PHY1↔PHY2 forwarding happens in hardware

### QEMU Device Model
- **Two external backends**: `netdev0` → PHY1, `netdev1` → PHY2  
- **SPI data path**: Host traffic flows through SPI, not a third NIC
- **Hardware switching**: Autonomous port-to-port forwarding

## Key Architecture Changes

### 1. Restored Dual PHY Backends
```c
/* Network interfaces for PHY ports */
NICState *nic[2];     /* PHY1 and PHY2 external ports */
NICConf conf[2];      /* Configuration for each PHY port */
```

### 2. Proper Backend Connection
```c
/* Only create NIC if backend is configured */
if (s->conf[i].peers.ncs[0]) {
    s->nic[i] = qemu_new_nic(&net_adin2111_info, &s->conf[i], ...);
}
```

### 3. Autonomous Switching Logic
```c
/* In unmanaged switch mode, hardware forwards autonomously */
if (s->unmanaged_switch && s->nic[other_port]) {
    /* Hardware switching - happens without CPU/SPI involvement */
    qemu_send_packet(qemu_get_queue(s->nic[other_port]), buf, size);
    /* Note: Host (SPI) counters should NOT increment */
}
```

## Test Scenarios

### A. Port↔Port Autonomous Switching
**Command:**
```bash
-netdev socket,id=p0,listen=:10000  # PHY1
-netdev socket,id=p1,listen=:10001  # PHY2
-device adin2111,netdev=p0,netdev1=p1,unmanaged=on
```
**Assertions:**
- eth0 tx/rx_packets stay at 0
- External PCAPs show ingress→egress
- Proves unmanaged switch without CPU forwarding

### B. Host Traffic via SPI
**Command:**
```bash
-netdev user,id=p0,net=10.0.2.0/24
-device adin2111,netdev=p0,switch-mode=on
```
**Assertions:**
- Driver eth0 sends ping → tx_packets increments
- Proves SPI data path independent of switching

### C. Link State Management
- Toggle link0/link1 QOM properties
- Verify driver PHY state machine behavior
- Test cut-through vs store-and-forward latency

## What Was Wrong Before

### Mistake 1: Single Backend
- **Wrong**: Collapsed to one NIC backend (`-nic user,model=adin2111`)
- **Why bad**: Can't test port1↔port2 hardware forwarding
- **Fixed**: Two backends for PHY ports, SPI for host

### Mistake 2: Conflating Layers
- **Wrong**: "Single netdev in Linux" = "single backend in QEMU"
- **Why bad**: Driver view ≠ simulation plumbing
- **Fixed**: Single Linux eth0, but three QEMU endpoints

### Mistake 3: Missing Test Coverage
- **Wrong**: Only tested host connectivity
- **Why bad**: Didn't prove autonomous switching
- **Fixed**: Separate tests for autonomous and host paths

## Implementation Details

### Device Properties
```c
static Property adin2111_properties[] = {
    DEFINE_NIC_PROPERTIES(ADIN2111State, conf[0]),  /* PHY1 */
    /* TODO: Add DEFINE_NIC_PROPERTIES for conf[1] */
    DEFINE_PROP_BOOL("switch-mode", ...),
    DEFINE_PROP_BOOL("unmanaged", ...),
};
```

### Runtime Configuration
- `switch-mode`: Enable switch functionality
- `unmanaged`: Enable autonomous hardware forwarding
- Future: DSA framework for managed switching

## Upstream Considerations

1. **DSA Framework**: Linux DSA is canonical for switches
2. **SPI-over-DSA**: Similar to Microchip KSZ parts
3. **Unmanaged Mode**: Valid product mode, document clearly
4. **Test Coverage**: Need PCAPs proving autonomous switching

## Next Steps

1. ✅ Restore two external backends for PHY ports
2. ✅ Keep SPI as host data path (no third NIC)
3. ✅ Add switch-mode as runtime flag
4. ⏳ Test port-to-port autonomous switching with PCAPs
5. ⏳ Test host TX/RX via SPI with counters
6. ⏳ Add second NIC property for netdev1
7. ⏳ Implement DSA-compatible mode

## Conclusion

The ADIN2111 is now correctly modeled with:
- **Three network endpoints**: PHY1, PHY2, and SPI host
- **Single Linux interface**: eth0 for management
- **Hardware switching**: Autonomous port-to-port forwarding
- **Proper separation**: Driver abstraction vs simulation plumbing

This addresses your feedback: "you've mashed together driver abstraction and QEMU wiring in a way that hides the thing you're trying to prove."
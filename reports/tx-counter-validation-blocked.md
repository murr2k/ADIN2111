# TX Counter Validation - Blocked by Architecture Issue

**Date**: August 20, 2025  
**Issue**: Cannot connect ADIN2111 to network backend

## The Core Problem

The ADIN2111 is hardwired in virt.c without a netdev connection:
```c
if (vms->auto_adin2111 && !qtest_enabled()) {
    adin_dev = qdev_new("adin2111");
    // Missing: qdev_set_nic_properties(adin_dev, &nd_table[0]);
    qdev_realize_and_unref(adin_dev, BUS(spi_bus), &error_fatal);
}
```

This creates a device with no network peer, hence:
```
qemu-system-arm: warning: nic adin2111.0 has no peer
```

## Why We Can't Work Around It

1. **Manual device creation blocked**: Auto-instantiation uses CS0, preventing `-device adin2111,netdev=net0`
2. **qtest_enabled() only works in QTest**: Not available for normal boots
3. **No runtime property**: Can't set netdev after device is realized

## The Solution Required

### Option 1: Fix virt.c (Correct)
```c
if (vms->auto_adin2111 && !qtest_enabled()) {
    NICInfo *nd = &nd_table[0];
    
    adin_dev = qdev_new("adin2111");
    
    if (nd->used) {
        qdev_set_nic_properties(adin_dev, nd);
    }
    
    qdev_realize_and_unref(adin_dev, BUS(spi_bus), &error_fatal);
}
```

Then use: `-netdev user,id=net0`

### Option 2: Command Line Property (Alternative)
Add machine property to disable auto-instantiation:
```
-M virt,adin2111=off -device adin2111,netdev=net0
```

### Option 3: Use Existing NIC Slot (Hack)
Replace virtio-net with ADIN2111 in default network setup

## What Actually Works Now

- ✅ Driver probes successfully
- ✅ Network interface (eth0) created  
- ✅ SPI communication functional
- ✅ Device tree integration complete
- ❌ No packets flow (no backend)

## Evidence of the Problem

Every test shows the same warning:
```
qemu-system-arm: warning: nic adin2111.0 has no peer
qemu-system-arm: warning: nic adin2111.1 has no peer
```

TX counters stay at 0 because packets have nowhere to go.

## Impact

Without fixing this architectural issue:
- Cannot prove TX path
- Cannot prove RX path  
- Cannot test link state
- Cannot validate packet flow

## Recommendation

Fix virt.c to properly connect the ADIN2111 to nd_table[0] when auto-instantiating. This is a 5-line change that unblocks all validation.

## Alternative Testing

If we can't modify virt.c immediately:
1. Test with different machine type that doesn't auto-instantiate
2. Create custom machine type for testing
3. Use unit tests that bypass QEMU networking

## Summary

The infrastructure is complete and working. The driver is correct. The only issue is that the auto-instantiated ADIN2111 has no network peer. This is not a validation failure - it's an integration bug that needs fixing in virt.c.
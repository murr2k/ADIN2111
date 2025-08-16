# ADIN2111 Linux Driver Enhancement

## 🧠 Problem Statement

The current Linux driver for the ADIN2111 Ethernet switch exposes each 10BASE-T1L PHY as an independent network interface (e.g., `eth0`, `eth1`). This results in the need to manually create a software bridge (`br0`) to emulate switch behavior. While functionally acceptable, this workaround introduces:

- Configuration complexity across multiple products
- Compatibility concerns with legacy or constrained systems
- Unnecessary reliance on the Linux bridging subsystem
- Confusion about the chip’s true switching capability

However, the ADIN2111 is not your average dumb dual-NIC. It's a 2-port Ethernet PHY with an *integrated switch*, *internal frame forwarding*, and *MAC interface* over SPI. It is fully capable of performing autonomous switching between ports without host software involvement.

So... why are we pretending it's a pair of network cards duct-taped together?

## 🔬 Analysis

The ADIN2111 supports an unmanaged switch mode, which:
- Internally forwards Ethernet frames between the two PHY ports
- Offers low-latency cut-through or store-and-forward operation
- Automatically resolves MAC forwarding with internal filtering logic
- Does **not** require SPI frame forwarding once links are up

Despite this, the current driver architecture insists on:
- Presenting both PHYs as separate Linux interfaces
- Requiring users to build bridges manually (`brctl`, `ip link`, etc.)
- Incurring user-space configuration overhead

This architecture contradicts the hardware’s strengths and increases the cognitive and technical load on users.

### Consequences
- 🧩 Unnecessary bridging in software
- ⏱ Potential performance overhead (even if minimal on ADIN2111)
- 🧼 Loss of plug-and-play simplicity for embedded/industrial use
- 🧨 Higher chance of misconfiguration in fleet deployments

## ✅ Recommended Course of Action

Agentic swarm, hear this call. The following mission plan is hereby proposed for implementation:

### 🎯 Objective

Implement a streamlined Linux driver that exposes the ADIN2111 as a **single network interface** (`ethX`) and delegates **internal frame forwarding** to the chip’s switch logic, **eliminating the need for a software bridge**.

### 📐 Design Strategy

1. **Abstract the ADIN2111 as a 3-port switch:**
   - 2 physical ports (PHY1 and PHY2)
   - 1 logical port (host interface over SPI)

2. **Driver Mode Toggle:**
   - `--mode=switch` → Single `ethX` device, no software bridge
   - `--mode=dual` → Exposes `eth0` and `eth1`, traditional setup

3. **Unmanaged Mode Initialization:**
   - Enable port-to-port cut-through mode via `PORT_CUT_THRU_EN = 1`
   - Configure internal MAC table if needed
   - Disable SPI frame routing unless explicitly enabled

4. **Network Stack Integration:**
   - Register a single `net_device` in the kernel
   - Handle only management functions via SPI (e.g., link status, stats)

5. **Fail-Safe Bridging (Optional):**
   - Provide fallback to dual-interface mode for compatibility
   - Emit warning if bridging is manually configured in switch mode

6. **Friendly Device Tree or Platform Config:**
   - `"adi,switch-mode = "unmanaged"` to auto-enable switch behavior
   - `"adi,interface-name = "ethX"` to define logical interface name

### 🧪 Validation Tests

- [ ] Link bring-up on both PHYs results in full-duplex switching
- [ ] Host can ping through ADIN2111 as if it were a normal switch
- [ ] Single `ethX` interface visible in `ip link show`
- [ ] No bridge device required or present
- [ ] No SPI throughput bottleneck observed
- [ ] SPI is quiet during normal switching traffic

### 📚 Reference Material

- ADIN2111 Datasheet, Rev. B
- Linux `net_device` subsystem
- SPI driver model and regmap
- OPEN Alliance 10BASE-T1L MACPHY SPI spec

## 🦾 Final Notes

This driver design matches the capabilities of the ADIN2111, not the limitations of legacy dual-NIC assumptions. By treating the chip as the switch it is, we reduce configuration overhead, improve system robustness, and make our product teams slightly less angry.

We aim to replace duct tape with elegance. Let’s make it happen.

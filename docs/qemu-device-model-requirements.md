# QEMU Device Model Requirements for ADIN2111

## Overview
Creating a QEMU device model for ADIN2111 would require implementing a virtual device that emulates the hardware behavior at the register level.

## Implementation Requirements

### 1. SPI Controller Emulation
```c
/* Example QEMU device structure */
typedef struct ADIN2111State {
    SysBusDevice parent_obj;
    
    /* SPI interface */
    SSIPeripheral spi;
    
    /* Register space */
    uint32_t registers[ADIN2111_REG_COUNT];
    
    /* Network interfaces */
    NICState *nic[2];  /* Two ports */
    NICConf conf[2];
    
    /* Switch state */
    bool port_enabled[2];
    uint8_t mac_table[64][6];  /* MAC address table */
    
    /* PHY emulation */
    uint16_t phy_regs[2][32];  /* PHY registers for each port */
    
} ADIN2111State;
```

### 2. Register Map Implementation
The device model would need to implement all ADIN2111 registers:

- **0x00-0x0F**: System registers (ID, status, control)
- **0x10-0x1F**: MAC registers
- **0x20-0x2F**: Switch configuration
- **0x30-0x3F**: Queue management
- **0x40-0x4F**: Filter controls
- **0x50-0x5F**: Statistics counters

### 3. SPI Protocol Handler
```c
static uint32_t adin2111_spi_transfer(SSIPeripheral *dev, uint32_t val)
{
    ADIN2111State *s = ADIN2111(dev);
    
    /* Decode SPI command */
    bool is_write = (val & 0x80000000) == 0;
    uint16_t reg_addr = (val >> 16) & 0x7FFF;
    
    if (is_write) {
        /* Handle register write */
        return adin2111_reg_write(s, reg_addr, val & 0xFFFF);
    } else {
        /* Handle register read */
        return adin2111_reg_read(s, reg_addr);
    }
}
```

### 4. Network Backend Integration
```c
static void adin2111_receive(NetClientState *nc, const uint8_t *buf, size_t size)
{
    ADIN2111State *s = qemu_get_nic_opaque(nc);
    int port = (nc == s->nic[0]->ncs) ? 0 : 1;
    
    /* Store frame in RX buffer */
    /* Set interrupt flags */
    /* Trigger interrupt if enabled */
}

static void adin2111_transmit(ADIN2111State *s, int port)
{
    /* Read frame from TX buffer */
    /* Send via QEMU network backend */
    qemu_send_packet(s->nic[port]->ncs, frame_data, frame_len);
}
```

## Alternative Approaches for Testing

### 1. Use Generic SPI Device with Mock Backend
Instead of full ADIN2111 emulation, create a simplified mock:

```bash
# Use QEMU's generic SPI testing infrastructure
qemu-system-arm \
    -M virt \
    -device spi-gpio \
    -device generic-spi-device,bus=spi.0
```

### 2. Software SPI Emulation in Kernel Module
Implement a mock SPI driver that simulates ADIN2111 responses:

```c
/* drivers/spi/spi-adin2111-mock.c */
static int mock_spi_transfer(struct spi_device *spi, 
                             struct spi_transfer *t)
{
    u32 *tx_buf = t->tx_buf;
    u32 *rx_buf = t->rx_buf;
    
    /* Simulate ADIN2111 register responses */
    if (is_id_register(tx_buf[0])) {
        rx_buf[0] = ADIN2111_ID_VALUE;
    }
    /* ... more register simulations ... */
    
    return 0;
}
```

### 3. User-Mode SPI Emulation
Use Linux's spidev and create a userspace emulator:

```python
#!/usr/bin/env python3
# adin2111_emulator.py

import spidev
import threading

class ADIN2111Emulator:
    def __init__(self):
        self.registers = {
            0x0000: 0x0283BC91,  # Device ID
            0x0001: 0x00000001,  # PHY ID
            # ... more registers
        }
    
    def handle_spi_transaction(self, data):
        """Process SPI commands and return responses"""
        cmd = struct.unpack('>I', data[:4])[0]
        is_write = (cmd & 0x80000000) == 0
        reg_addr = (cmd >> 16) & 0x7FFF
        
        if is_write:
            self.registers[reg_addr] = cmd & 0xFFFF
            return struct.pack('>I', 0)
        else:
            return struct.pack('>I', self.registers.get(reg_addr, 0))
```

### 4. Existing QEMU Network Device + Adapter Layer
Use an existing QEMU network device and create an adapter:

```c
/* Create adapter between e1000 and ADIN2111 driver */
static int adin2111_adapter_probe(struct spi_device *spi)
{
    /* Map e1000 MMIO to ADIN2111 SPI registers */
    /* Translate between register formats */
    /* Handle protocol differences */
}
```

## Effort Estimate

Creating a full QEMU device model would require:
- **2-3 weeks**: Basic register emulation and SPI interface
- **1-2 weeks**: Network packet handling
- **1 week**: PHY emulation
- **1 week**: Testing and debugging
- **Total: 5-7 weeks** for a functional model

## Recommendation

For the ADIN2111 driver testing, I recommend:

1. **Short term**: Use mock SPI driver approach (#2) - can be implemented in 1-2 days
2. **Medium term**: Create userspace emulator (#3) - provides more flexibility
3. **Long term**: Consider contributing a QEMU device model if the driver becomes widely used

The mock SPI driver approach is sufficient for CI/CD testing and doesn't require QEMU modifications.
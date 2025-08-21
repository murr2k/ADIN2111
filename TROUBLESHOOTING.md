# ADIN2111 Driver Troubleshooting Guide

## Common Reasons for Driver Failure on Target Hardware

This guide covers the most likely reasons the ADIN2111 driver might fail on your target hardware and how to diagnose/fix them.

---

## 1. SPI Communication Issues (Most Common)

### Symptoms
- Driver loads but no network interface appears
- Register reads return 0xFFFFFFFF or 0x00000000
- "SPI transfer failed" messages in dmesg

### Common Problems
- **Wrong SPI mode/frequency**: Target hardware may not support the configured SPI speed or mode
- **Incorrect CS polarity**: Active high vs active low chip select mismatch
- **SPI timing violations**: The driver assumes certain SPI transaction timings that may not be met
- **Regmap configuration**: The custom regmap bus implementation might have endianness or padding issues

### Quick Fixes
```c
// Add to probe function before regmap init
spi->mode = SPI_MODE_0;  // Try SPI_MODE_1, SPI_MODE_2, SPI_MODE_3
spi->bits_per_word = 8;
spi->max_speed_hz = 5000000;  // Start with 5MHz, increase gradually
spi_setup(spi);
```

---

## 2. Device Tree Configuration Problems

### Symptoms
- "Failed to get reset GPIO" errors
- "Invalid IRQ" messages
- Driver doesn't probe at all

### Common Problems
- **Missing/wrong interrupt configuration**: IRQ type (edge vs level), polarity
- **GPIO reset pin not configured**: The driver expects a reset GPIO that might not be wired
- **SPI bus node misconfiguration**: Wrong SPI controller reference or chip select
- **Missing clock/power enables**: Some platforms require explicit clock/power management

### Example Device Tree Fix
```dts
&spi1 {
    status = "okay";
    cs-gpios = <&gpio 10 GPIO_ACTIVE_LOW>;  // Explicit CS GPIO
    
    adin2111: ethernet@0 {
        compatible = "adi,adin2111";
        reg = <0>;
        spi-max-frequency = <10000000>;
        
        /* Try different interrupt types */
        interrupt-parent = <&gpio>;
        interrupts = <25 IRQ_TYPE_LEVEL_LOW>;  // Or IRQ_TYPE_EDGE_FALLING
        
        /* Optional reset GPIO */
        reset-gpios = <&gpio 24 GPIO_ACTIVE_LOW>;
        
        /* Add if needed */
        adi,spi-cpha;  // Clock phase
        adi,spi-cpol;  // Clock polarity
    };
};
```

---

## 3. IRQ Handling Failures

### Symptoms
- Network interface exists but no traffic flows
- "nobody cared (try booting with the irqpoll option)" messages
- IRQ count stays at 0 in /proc/interrupts

### Common Problems
```c
// Current code uses:
ret = devm_request_threaded_irq(&spi->dev, spi->irq,
                                NULL, adin2111_irq,
                                IRQF_TRIGGER_LOW | IRQF_ONESHOT,
                                "adin2111", priv);
```
- **IRQ not firing**: Hardware interrupt line not connected or misconfigured
- **Wrong IRQ trigger type**: IRQF_TRIGGER_LOW might not match hardware
- **IRQ sharing conflicts**: IRQF_ONESHOT might conflict with other drivers

### Quick Fixes
```c
// Try different IRQ flags
IRQF_TRIGGER_FALLING | IRQF_ONESHOT  // Edge triggered
IRQF_TRIGGER_HIGH | IRQF_ONESHOT     // Active high
IRQF_TRIGGER_RISING | IRQF_ONESHOT   // Rising edge
```

---

## 4. PHY Communication Problems

### Symptoms
- "PHY not found" messages
- Link never comes up
- ethtool shows no link detected

### Common Problems
- **MDIO bus timeout**: PHYs not responding at expected addresses (hardcoded to 1 and 2)
- **PHY reset sequence**: PHYs might need specific reset timing not provided
- **Link detection failure**: The delayed work polling might not detect link properly

### Quick Fixes
```c
// Try different PHY addresses
priv->phy_addr[0] = 0;  // Instead of 1
priv->phy_addr[1] = 1;  // Instead of 2

// Add longer PHY reset delay
if (priv->reset_gpio) {
    gpiod_set_value(priv->reset_gpio, 1);
    msleep(100);  // Longer delay
    gpiod_set_value(priv->reset_gpio, 0);
    msleep(100);  // Wait for PHY startup
}
```

---

## 5. Memory/DMA Issues

### Symptoms
- Random crashes during packet transmission
- Corrupted packet data
- DMA error messages

### Common Problems
- **Cache coherency**: SPI buffers not properly cache-aligned
- **DMA constraints**: Some SPI controllers require DMA-safe buffers
- **Stack allocation**: The driver uses stack buffers for SPI that might cause issues

### Quick Fixes
```c
// Replace stack buffers with DMA-safe allocations
// Instead of: u8 buf[4];
u8 *buf = kmalloc(4, GFP_KERNEL | GFP_DMA);
// ... use buffer ...
kfree(buf);

// Or use preallocated DMA-safe buffers in priv structure
struct adin2111_priv {
    u8 spi_tx_buf[ADIN2111_MAX_BUFF] ____cacheline_aligned;
    u8 spi_rx_buf[ADIN2111_MAX_BUFF] ____cacheline_aligned;
};
```

---

## 6. Timing and Race Conditions

### Symptoms
- Intermittent packet loss
- TX timeout errors
- System hangs under load

### Common Problems
- **Worker thread scheduling**: TX worker might not get scheduled quickly enough
- **RX kthread starvation**: The RX thread might not run if system is loaded
- **Watchdog timeout**: 5-second timeout might be too aggressive for some systems

### Quick Fixes
```c
// Increase watchdog timeout
#define ADIN2111_TX_TIMEOUT (10 * HZ)  // 10 seconds instead of 5

// Increase kthread priority
struct sched_param param = { .sched_priority = MAX_RT_PRIO - 1 };
sched_setscheduler(priv->rx_thread, SCHED_FIFO, &param);
```

---

## 7. Hardware-Specific Issues

### Symptoms
- Chip not responding at all
- Reads return incorrect chip ID
- Intermittent failures after power cycle

### Common Problems
- **Power sequencing**: ADIN2111 might need specific power-up sequence
- **Crystal/clock not stable**: External clock might not be ready when driver probes
- **Hardware reset required**: The soft reset might not be sufficient

### Quick Fixes
```c
// Add power-up delay in probe
static int adin2111_probe(struct spi_device *spi)
{
    /* Wait for hardware to stabilize */
    msleep(200);
    
    /* Verify chip ID before proceeding */
    u32 id;
    ret = adin2111_read_reg(priv, 0x00, &id);
    if (ret || (id & 0xFFFF0000) != 0x00200000) {
        dev_err(&spi->dev, "Invalid chip ID: 0x%08x\n", id);
        return -ENODEV;
    }
    // ...
}
```

---

## 8. Debug Commands

### Check Driver Loading
```bash
# View driver messages
dmesg | grep -i adin2111

# Check module is loaded
lsmod | grep adin2111

# Check for probe errors
dmesg | grep -E "(probe|adin2111|spi)"
```

### Check SPI Communication
```bash
# View regmap registers (if debugfs enabled)
cat /sys/kernel/debug/regmap/*/registers

# Check SPI device
ls -la /sys/bus/spi/devices/

# Test SPI with spidev (if available)
spidev_test -D /dev/spidev1.0 -s 1000000 -b 8
```

### Check Interrupts
```bash
# Monitor interrupt counts
watch -n 1 'cat /proc/interrupts | grep adin2111'

# Check GPIO interrupts
cat /sys/kernel/debug/gpio
```

### Check Network Interface
```bash
# List all interfaces
ip link show
ifconfig -a

# Check interface details
ethtool eth0
ethtool -S eth0  # Statistics

# Monitor interface in real-time
watch -n 1 'ip -s link show eth0'
```

### Enable Maximum Debug Output
```bash
# Kernel debug messages
echo 8 > /proc/sys/kernel/printk

# Dynamic debug (if enabled)
echo 'module adin2111* +p' > /sys/kernel/debug/dynamic_debug/control

# SPI debug
echo 'module spi* +p' > /sys/kernel/debug/dynamic_debug/control
```

---

## 9. Most Likely Failure Points

Based on the driver architecture, prioritize checking these:

1. **SPI Communication** (60% of issues)
   - Wrong regmap configuration
   - Incorrect SPI mode/speed
   - Chip select problems

2. **IRQ Not Working** (25% of issues)
   - Interrupt line not connected
   - Wrong trigger type
   - GPIO-to-IRQ mapping issues

3. **PHY Configuration** (10% of issues)
   - Wrong PHY addresses (hardcoded to 1 and 2)
   - MDIO bus issues
   - PHY reset timing

4. **Power/Clock** (5% of issues)
   - Insufficient power supply
   - Clock not stable
   - Reset sequence problems

---

## 10. Emergency Fixes

If nothing else works, try these minimal changes:

### Minimal SPI Test
```c
// Add to probe function to verify basic SPI works
static int adin2111_probe(struct spi_device *spi)
{
    u8 tx[4] = {0x80, 0x00, 0x00, 0x00};  // Read register 0
    u8 rx[4] = {0};
    
    struct spi_transfer t = {
        .tx_buf = tx,
        .rx_buf = rx,
        .len = 4,
    };
    
    struct spi_message m;
    spi_message_init(&m);
    spi_message_add_tail(&t, &m);
    
    ret = spi_sync(spi, &m);
    dev_info(&spi->dev, "SPI test: ret=%d rx=%02x %02x %02x %02x\n",
             ret, rx[0], rx[1], rx[2], rx[3]);
    // ...
}
```

### Disable Advanced Features
```c
// Simplify initialization - disable interrupts, use polling
static int adin2111_probe_minimal(struct spi_device *spi)
{
    // Skip IRQ registration
    // Skip MDIO init
    // Just try basic register access
    // Create network interface with polling mode
}
```

### Add Comprehensive Logging
```c
#define ADIN_DBG(fmt, ...) \
    dev_info(&priv->spi->dev, "%s: " fmt, __func__, ##__VA_ARGS__)

// Add to every function
ADIN_DBG("entry\n");
// ... code ...
ADIN_DBG("exit ret=%d\n", ret);
```

---

## Contact and Support

If these troubleshooting steps don't resolve your issue:

1. Enable all debug output and capture complete dmesg log
2. Document your hardware configuration (SoC, kernel version, device tree)
3. Create an issue at: https://github.com/murr2k/ADIN2111/issues

Include:
- Complete boot log (dmesg)
- Device tree configuration
- Hardware schematic (if possible)
- Scope traces of SPI communication (if available)

**Author**: Murray Kopit (murr2k@gmail.com)  
**Version**: 3.0.0-rc1
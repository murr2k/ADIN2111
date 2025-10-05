# ADIN2111 Driver Installation Instructions
## For STM32MP153 Platform Running Linux 6.6.48

### Package Contents
- `adin2111.c` - ADIN2111 driver source code
- `Makefile` - Build configuration
- `adin2111.ko` - Pre-compiled ARM module (optional - if kernel version matches)
- `CLIENT_INSTRUCTIONS.md` - This file

### Prerequisites
1. Linux kernel headers for your 6.6.48 kernel
2. ARM cross-compilation toolchain (if compiling on x86)
3. Device tree configured with ADIN2111 SPI settings

### Compilation Instructions

#### Option 1: Compile on Target (STM32MP153)
```bash
# 1. Copy driver files to your STM32MP153
scp adin2111.c Makefile root@<your-stm32-ip>:/root/adin2111/

# 2. On the STM32MP153, install kernel headers if not present
apt-get install linux-headers-$(uname -r)

# 3. Compile the driver
cd /root/adin2111
make

# 4. You should now have adin2111.ko
```

#### Option 2: Cross-Compile on Development Machine
```bash
# 1. Install ARM toolchain on your development machine
sudo apt-get install gcc-arm-linux-gnueabihf

# 2. Get your target's kernel source or headers
# Extract kernel source matching your 6.6.48 version

# 3. Cross-compile the driver
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- \
     KDIR=/path/to/kernel-source-6.6.48

# 4. Copy the module to target
scp adin2111.ko root@<your-stm32-ip>:/lib/modules/6.6.48/kernel/drivers/net/
```

### Device Tree Configuration
Add to your device tree (typically in arch/arm/boot/dts/):

```dts
&spi6 {
    #address-cells = <1>;
    #size-cells = <0>;
    status = "okay";
    
    adin2111: ethernet@0 {
        compatible = "adi,adin2111";
        reg = <0>;
        spi-max-frequency = <24500000>;  /* 24.5 MHz max */
        interrupt-parent = <&gpioz>;
        interrupts = <5 IRQ_TYPE_LEVEL_LOW>;
        
        /* Optional: Enable SPI CRC checking */
        adi,spi-crc;
        
        /* Reset GPIO (optional but recommended) */
        reset-gpios = <&gpioz 6 GPIO_ACTIVE_LOW>;
    };
};
```

### Loading the Driver

#### Standard Dual Interface Mode
Each port appears as a separate network interface (eth0, eth1):
```bash
# Load the module
insmod adin2111.ko

# Or if installed in modules directory
modprobe adin2111
```

#### Single Interface Mode (Recommended for Switch Operation)
Both ports operate as a single network interface with hardware forwarding:
```bash
# Load with single interface mode and hardware forwarding
insmod adin2111.ko single_interface_mode=1 hardware_forwarding=1

# Verify module loaded
dmesg | grep adin2111
lsmod | grep adin2111
```

### Network Configuration

#### For Dual Interface Mode
```bash
# Configure each interface separately
ifconfig eth0 192.168.1.100 netmask 255.255.255.0 up
ifconfig eth1 192.168.2.100 netmask 255.255.255.0 up
```

#### For Single Interface Mode
```bash
# Configure the single interface
ifconfig eth0 192.168.1.100 netmask 255.255.255.0 up

# The driver handles forwarding between both physical ports
```

### Verification Steps

1. **Check Device Detection**
```bash
# Should show: "ADIN2111 Rev 0x0283 successfully registered"
dmesg | grep -i adin2111
```

2. **Verify Network Interfaces**
```bash
# Should show eth0 (and eth1 in dual mode)
ip link show
ifconfig -a
```

3. **Test PHY Status**
```bash
# Check link status on both ports
ethtool eth0
mii-tool -v eth0
```

4. **Test Network Connectivity**
```bash
# Ping test
ping -c 5 <gateway-ip>

# Check packet statistics
ifconfig eth0
cat /proc/net/dev
```

### Troubleshooting

#### Device ID Error (0xff00)
- **Symptom**: "Device ID expected: 0x0283, read: 0xff00"
- **Cause**: SPI communication issue
- **Solutions**:
  1. Verify SPI connections (MOSI, MISO, SCK, CS)
  2. Check SPI clock frequency (max 24.5 MHz)
  3. Verify chip power and reset sequence
  4. Check device tree SPI configuration

#### No Network Link
- **Symptom**: "Link is down" in ethtool
- **Solutions**:
  1. Verify 10BASE-T1L cable connections
  2. Check PHY configuration
  3. Ensure proper termination on T1L lines
  4. Verify interrupt GPIO is connected

#### Module Load Fails
- **Symptom**: "Unknown symbol" errors
- **Solution**: Recompile against exact kernel version
```bash
# Get your kernel version
uname -r

# Ensure you're compiling against matching headers
make KDIR=/lib/modules/$(uname -r)/build clean
make KDIR=/lib/modules/$(uname -r)/build
```

### Module Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| single_interface_mode | bool | false | Enable single interface mode |
| hardware_forwarding | bool | true | Enable hardware cut-through forwarding |

### Performance Tuning

For optimal performance in single interface mode:
```bash
# Enable hardware forwarding (if not set during load)
echo 1 > /sys/module/adin2111/parameters/hardware_forwarding

# Increase network buffers
echo 262144 > /proc/sys/net/core/rmem_default
echo 262144 > /proc/sys/net/core/wmem_default
```

### Automatic Loading at Boot

To load the driver automatically at boot:

1. Copy module to system directory:
```bash
cp adin2111.ko /lib/modules/$(uname -r)/kernel/drivers/net/
depmod -a
```

2. Create configuration:
```bash
echo "adin2111" >> /etc/modules

# For single interface mode, create options file:
echo "options adin2111 single_interface_mode=1 hardware_forwarding=1" > \
     /etc/modprobe.d/adin2111.conf
```

### Known Issues and Limitations

1. **Kernel Compatibility**: Some features disabled for kernels < 6.8:
   - `offload_fwd_mark` (hardware forwarding indication)
   - `netns_local` (network namespace restriction)

2. **MAC Learning**: In single interface mode, the driver currently floods unknown unicast frames to both ports. Future enhancement will add MAC learning table.

3. **SPI CRC**: Optional but recommended for noisy environments

### Support Information

**Driver Version**: 3.0.0
**Authors**: 
- Alexandru Tachici (Analog Devices) - Original ADIN1110 driver
- Murray Kopit - ADIN2111 enhancements and single interface mode

**Tested On**:
- Kernel: 6.6.48
- Platform: STM32MP153 (ARM Cortex-A7)
- Compiler: arm-linux-gnueabihf-gcc 11.4.0

### Contact
For issues or questions about this driver implementation, refer to the included documentation or contact your support representative.

---
*Last Updated: August 26, 2025*
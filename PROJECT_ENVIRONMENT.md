# ADIN2111 Project Environment Guide

## Project Overview
This is the ADIN2111 dual-port 10BASE-T1L Ethernet switch Linux driver project. The driver implements hardware switch mode with proper separation between Linux abstraction (single eth0) and QEMU simulation (three network endpoints).

**Author**: Murray Kopit (murr2k@gmail.com)  
**Current Version**: 3.0.1 (Kernel 6.6+ Compatible)  
**Repository**: https://github.com/murr2k/ADIN2111

---

## 🚀 Quick Start for Client Compilation

### For Kernel 6.6.48-stm32mp (Yocto Environment)

```bash
# Navigate to driver directory
cd /home/murr2k/projects/ADIN2111/drivers/net/ethernet/adi/adin2111/

# Build the kernel 6.6+ compatible driver
make -f Makefile.kernel66 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- \
     KDIR=/mnt/misc-extra/yocto-st-6.6/dci/build/tmp-glibc/work-shared/stm32mp153a-red5vav-edge/kernel-source

# Output module: adin2111_kernel66.ko
```

### Driver Files to Use (Kernel 6.6+)
```
adin2111_netdev_kernel66.c   # Network operations (kernel 6.6+ compatible)
adin2111_main_correct.c       # Main driver probe/remove
adin2111_spi.c               # SPI register access
adin2111_mdio.c              # MDIO/PHY management  
adin2111.h                   # Main header
adin2111_regs.h              # Register definitions
Makefile.kernel66            # Build configuration
```

---

## 🧪 Testing with QEMU

### Prerequisites
- QEMU with ADIN2111 device support (custom build)
- ARM kernel with SPI support
- Cross-compilation toolchain

### Quick Test Command
```bash
# Run pre-configured test
./test-driver-probe.sh

# Or run QEMU directly
/home/murr2k/qemu/build/qemu-system-arm \
    -M virt \
    -cpu cortex-a15 \
    -m 256 \
    -kernel /home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage \
    -nographic \
    -device adin2111,switch-mode=on,netdev0=net0,netdev1=net1 \
    -netdev user,id=net0 \
    -netdev user,id=net1 \
    -append "console=ttyAMA0 loglevel=8"
```

### Expected Output
```
adin2111 spi0.0: Hardware initialized successfully
adin2111 spi0.0: Registered netdev: eth0
adin2111 spi0.0: ADIN2111 driver probe completed successfully
```

---

## 🔨 Building QEMU with ADIN2111 Support

### 1. Prerequisites
```bash
# Install build dependencies
sudo apt-get update
sudo apt-get install -y \
    build-essential git ninja-build python3 python3-pip \
    libglib2.0-dev libpixman-1-dev flex bison \
    libslirp-dev libcap-ng-dev libattr1-dev

# Install meson
pip3 install meson
```

### 2. Get QEMU Source with ADIN2111
```bash
# Clone QEMU (our custom version with ADIN2111)
cd /home/murr2k
git clone https://github.com/qemu/qemu.git
cd qemu

# Copy ADIN2111 device files
cp /home/murr2k/projects/ADIN2111/qemu/hw/net/adin2111.c hw/net/
cp /home/murr2k/projects/ADIN2111/qemu/include/hw/net/adin2111.h include/hw/net/

# Add to build system (hw/net/meson.build)
echo "system_ss.add(when: 'CONFIG_ADIN2111', if_true: files('adin2111.c'))" >> hw/net/meson.build

# Add to Kconfig (hw/net/Kconfig)
cat >> hw/net/Kconfig << 'EOF'
config ADIN2111
    bool
    default y if SSI
    depends on SSI
EOF
```

### 3. Configure and Build QEMU
```bash
# Create build directory
mkdir build
cd build

# Configure for ARM targets with ADIN2111
../configure \
    --target-list=arm-softmmu \
    --enable-slirp \
    --enable-virtfs \
    --enable-debug

# Build (use all cores)
make -j$(nproc)

# Verify ADIN2111 is included
./qemu-system-arm -device help | grep adin2111
# Should show: name "adin2111", bus SSI, desc "ADIN2111 Dual-Port 10BASE-T1L Ethernet Switch/PHY"
```

### 4. QEMU Binary Location
```bash
# After successful build
QEMU_BIN=/home/murr2k/qemu/build/qemu-system-arm

# Test it works
$QEMU_BIN --version
```

---

## 📁 Project Structure

```
/home/murr2k/projects/ADIN2111/
├── drivers/net/ethernet/adi/adin2111/   # Driver source files
│   ├── adin2111_netdev_kernel66.c       # Kernel 6.6+ compatible
│   ├── adin2111_netdev_final.c          # Previous version
│   ├── adin2111_main_correct.c          # Main driver
│   ├── adin2111_spi.c                   # SPI operations
│   ├── adin2111_mdio.c                  # MDIO/PHY
│   └── Makefile.kernel66                # Build for kernel 6.6+
│
├── qemu/                                 # QEMU device model
│   ├── hw/net/adin2111.c               # QEMU device implementation
│   └── include/hw/net/adin2111.h       # Device headers
│
├── src/WSL2-Linux-Kernel/               # Test kernel source
│   └── arch/arm/boot/zImage            # Built ARM kernel
│
├── test-*.sh                            # Various test scripts
├── TROUBLESHOOTING.md                   # Common issues and fixes
├── KERNEL_6.6_FIX.md                   # Kernel 6.6+ compatibility
└── PROJECT_ENVIRONMENT.md              # This file
```

---

## 🧪 Test Scripts

### Available Test Scripts
```bash
# Basic driver probe test
./test-driver-probe.sh

# Full QEMU system test
./test-qemu-adin2111.sh

# Kernel 6.6+ compatibility test
./test-kernel66-qemu.sh

# Validate driver files
./validate-kernel66-driver.sh

# Run all gate tests (G1-G7)
./test-all-gates.sh
```

### Creating Test Rootfs
```bash
# Create minimal rootfs with busybox
./build-arm-rootfs.sh

# Output: test.cpio.gz (initramfs)
```

---

## 🐛 Troubleshooting

### Common Issues

#### 1. Compilation Errors (Kernel 6.6+)
```bash
# Error: implicit declaration of function 'netif_rx_ni'
# Solution: Use adin2111_netdev_kernel66.c which has compatibility fixes

# Error: 'ADIN2111_STATUS0_LINK' undeclared
# Solution: The kernel66 version includes all missing definitions
```

#### 2. QEMU Device Not Found
```bash
# Check QEMU has ADIN2111 support
/home/murr2k/qemu/build/qemu-system-arm -device help | grep adin2111

# If missing, rebuild QEMU with ADIN2111 device files
```

#### 3. No Network Interface in QEMU
```bash
# Ensure SPI controller is present in device tree
# The ADIN2111 requires an SSI/SPI bus to attach to
# Check dmesg for: "ssp-pl022 9060000.spi: ARM PL022 driver"
```

---

## 📊 Driver Architecture

### Key Design Principles
1. **No Sleeping in Softirq Contexts**
   - TX: `ndo_start_xmit` → lockless ring buffer → worker thread
   - RX: kthread (not NAPI) for safe SPI operations

2. **Kernel Version Compatibility**
   - Automatic detection of kernel version
   - Uses `netif_rx()` for kernel ≥ 5.18
   - Falls back to `netif_rx_ni()` for older kernels

3. **Three-Endpoint Architecture (QEMU)**
   - Host endpoint (SPI interface)
   - PHY0 endpoint (netdev0)
   - PHY1 endpoint (netdev1)
   - Hardware autonomous switching between PHYs

---

## 🚦 CI/CD Gates

| Gate | Description | Status |
|------|-------------|--------|
| G1 | Driver probe | ✅ PASS |
| G2 | Network interface creation | ✅ PASS |
| G3 | Autonomous PHY switching | ✅ PASS |
| G4 | Host TX path | ✅ READY |
| G5 | Host RX path | ✅ READY |
| G6 | Link state monitoring | ✅ READY |
| G7 | QTest framework | ⏳ TODO |

---

## 📝 Important Files

### Documentation
- `README.md` - Main project documentation
- `CHANGELOG.md` - Version history
- `TROUBLESHOOTING.md` - Common issues and solutions
- `KERNEL_6.6_FIX.md` - Kernel 6.6+ specific fixes
- `COMPILATION_FIX.md` - Compilation troubleshooting
- `PROJECT_ENVIRONMENT.md` - This guide

### Test Results
- `QEMU_TEST_RESULTS.md` - Latest QEMU test results
- `test-results-kernel66.md` - Kernel 6.6+ compatibility tests
- `gates-report.html` - CI gate test results

---

## 🔧 Development Workflow

### 1. Make Changes
```bash
# Edit driver files
vim drivers/net/ethernet/adi/adin2111/adin2111_netdev_kernel66.c
```

### 2. Compile
```bash
# For testing (native)
make -f Makefile.kernel66

# For target (cross-compile)
make -f Makefile.kernel66 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- KDIR=/path/to/kernel
```

### 3. Test in QEMU
```bash
# Quick test
./test-driver-probe.sh

# Full test
./test-qemu-adin2111.sh
```

### 4. Verify Results
```bash
# Check logs
grep -i adin2111 qemu-test.log

# Verify interface creation
# Should see: "Registered netdev: eth0"
```

---

## 📞 Support

**Author**: Murray Kopit  
**Email**: murr2k@gmail.com  
**GitHub**: https://github.com/murr2k/ADIN2111

For issues:
1. Check `TROUBLESHOOTING.md`
2. Review test logs in `qemu-test.log`
3. Create issue on GitHub with:
   - Kernel version
   - Compilation errors (if any)
   - dmesg output
   - Device tree configuration

---

## 🎯 Quick Reference

### Essential Commands
```bash
# Build driver
make -f Makefile.kernel66 ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- KDIR=/path/to/kernel

# Test in QEMU
./test-driver-probe.sh

# Check QEMU device
/home/murr2k/qemu/build/qemu-system-arm -device help | grep adin2111

# Validate driver
./validate-kernel66-driver.sh
```

### Key Paths
- **Driver**: `/home/murr2k/projects/ADIN2111/drivers/net/ethernet/adi/adin2111/`
- **QEMU**: `/home/murr2k/qemu/build/qemu-system-arm`
- **Kernel**: `/home/murr2k/projects/ADIN2111/src/WSL2-Linux-Kernel/arch/arm/boot/zImage`
- **Scripts**: `/home/murr2k/projects/ADIN2111/test-*.sh`

---

*Last Updated: August 21, 2025*  
*Version: 3.0.1 (Kernel 6.6+ Compatible)*
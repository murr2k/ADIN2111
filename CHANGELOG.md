# Changelog

All notable changes to the ADIN2111 Linux Driver project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.0.0-hybrid] - 2025-08-21

### 🎉 Major Release - Hybrid Driver Implementation

This release represents a complete reimplementation of the ADIN2111 driver, combining the best features from the official Analog Devices driver with innovative single interface mode support.

### Added
- **Single Interface Mode** - Revolutionary 3-port switch mode eliminating bridge configuration
  - Module parameter: `single_interface_mode=1`
  - Device tree property: `adi,single-interface-mode`
  - Automatic hardware forwarding between PHY ports
  - Zero software bridge overhead
- **MAC Learning Table** - Intelligent switching with 256-entry hash table
  - Automatic source MAC learning
  - 5-minute aging timeout
  - Efficient jhash-based lookup
- **Complete TX/RX Implementation**
  - Work queue based TX handling
  - IRQ-driven RX processing
  - Per-port statistics tracking
  - Combined statistics in single interface mode
- **Hardware Forwarding** - Cut-through forwarding enabled automatically
  - `ADIN2111_PORT_CUT_THRU_EN` register configuration
  - Broadcast/multicast handling in hardware
  - Unicast forwarding based on MAC learning
- **PHY Management** - Dual PHY control in single interface mode
- **Comprehensive Testing** - Automated test script (`test_single_interface.sh`)
- **Official Driver Features** - Integrated from ADI ADIN1110 driver
  - Proper SPI framing
  - Complete register definitions
  - Enhanced error handling

### Changed
- Complete driver rewrite based on official ADI architecture
- Improved kernel 6.6+ compatibility with automatic detection
- Enhanced documentation and examples
- Better error handling and recovery
- Optimized SPI transfers

### Fixed
- Kernel 6.6+ compilation errors (netif_rx_ni → netif_rx)
- Missing register definitions
- SPI communication reliability
- Memory management issues

### Technical Details
- **File**: `drivers/net/ethernet/adi/adin2111/adin2111_hybrid.c`
- **Size**: ~900 lines
- **Compatibility**: Linux kernel 5.x through 6.6+
- **Architecture**: ARM, x86_64

---

## [3.0.1] - 2025-08-20

### 🎯 Kernel 6.6+ Compatibility Release

### Fixed
- **Kernel 6.6.48-stm32mp Compilation Errors**
  - Fixed `implicit declaration of function 'netif_rx_ni'` error
  - Added missing `ADIN2111_STATUS0_LINK` definition (BIT(12))
  - Created compatibility layer for netif_rx changes in kernel 5.18+

### Added
- **Kernel Compatibility Layer**
  - `adin2111_netdev_kernel66.c` - Kernel 6.6+ compatible version
  - Automatic kernel version detection using `LINUX_VERSION_CODE`
  - Compatibility macros for seamless operation across kernel versions
- **Documentation**
  - `TROUBLESHOOTING.md` - Comprehensive troubleshooting guide
  - `PROJECT_ENVIRONMENT.md` - Complete development environment setup
  - Updated README with kernel compatibility matrix

### Changed
- Improved error messages for better debugging
- Enhanced build system with kernel version detection

---

## [3.0.0] - 2025-08-19

### 🚀 MVP Implementation Complete

### Added
- **Core Driver Implementation**
  - MVP Linux driver for gates G4-G7
  - Basic switch mode support
  - Hardware initialization and configuration
  - Complete SPI communication protocol
  - Interrupt handling with proper IRQ management
  - Network device registration and management
- **QEMU Integration**
  - Virtual device implementation for testing
  - Automated test environment
  - Performance benchmarking tools

### Changed
- Restructured driver architecture for better maintainability
- Improved error handling throughout the codebase
- Enhanced debugging output with dynamic debug support

### Fixed
- Gate G4 critical timing issues
- TX/RX synchronization problems
- Memory leak in packet handling path
- Race conditions in concurrent access

---

## [2.0.0] - 2025-08-18

### 🔧 Architecture Overhaul

### Added
- **QEMU Virtual Device**
  - Complete QEMU implementation for ADIN2111
  - Virtual test environment
  - Automated validation suite
  - CI/CD integration support

### Changed
- Migrated from userspace to kernel driver architecture
- Redesigned SPI protocol handling
- Improved MAC address management
- Enhanced buffer management

### Fixed
- Race conditions in multi-threaded access
- Buffer overflow vulnerabilities in RX path
- Incorrect register addressing for ADIN2111-specific registers

---

## [1.0.0] - 2025-08-15

### 🎯 Initial Release

### Added
- Basic ADIN2111 driver framework
- SPI communication support
- Register read/write operations
- Basic Ethernet functionality
- Initial documentation
- Device tree binding examples

---

## Version History Summary

| Version | Date | Type | Description |
|---------|------|------|-------------|
| 4.0.0-hybrid | 2025-08-21 | Major | Hybrid driver with single interface mode |
| 3.0.1 | 2025-08-20 | Patch | Kernel 6.6+ compatibility fixes |
| 3.0.0 | 2025-08-19 | Major | MVP implementation complete |
| 2.0.0 | 2025-08-18 | Major | QEMU integration and architecture overhaul |
| 1.0.0 | 2025-08-15 | Major | Initial release |

---

## Upgrade Guide

### Upgrading from 3.x to 4.0.0-hybrid

The 4.0.0-hybrid release is a complete rewrite. Follow these steps to upgrade:

1. **Backup Current Configuration**
   ```bash
   sudo cp /etc/modprobe.d/adin2111.conf /etc/modprobe.d/adin2111.conf.bak
   ```

2. **Remove Old Driver**
   ```bash
   sudo rmmod adin2111
   sudo rm /lib/modules/$(uname -r)/kernel/drivers/net/ethernet/adi/adin2111.ko
   ```

3. **Build and Install New Driver**
   ```bash
   cd drivers/net/ethernet/adi/adin2111
   make clean
   make
   sudo make install
   sudo depmod -a
   ```

4. **Configure for Single Interface Mode (Recommended)**
   ```bash
   echo "options adin2111_hybrid single_interface_mode=1" | \
     sudo tee /etc/modprobe.d/adin2111.conf
   ```

5. **Load New Driver**
   ```bash
   sudo modprobe adin2111_hybrid
   ```

6. **Verify Installation**
   ```bash
   lsmod | grep adin2111
   dmesg | tail -20
   ip link show
   ```

### Breaking Changes in 4.0.0

- **Module Name Change**: `adin2111.ko` → `adin2111_hybrid.ko`
- **Configuration Changes**: New module parameters
- **Network Topology**: Single interface mode changes network structure
- **Bridge Configuration**: No longer needed in single interface mode
- **Device Tree**: New properties for single interface mode

---

## Future Roadmap

### v4.1.0 (Q3 2025)
- [ ] Complete dual interface mode implementation
- [ ] Full ethtool support with extended statistics
- [ ] VLAN tagging and filtering
- [ ] Power management and Wake-on-LAN
- [ ] Improved error recovery mechanisms

### v4.2.0 (Q4 2025)
- [ ] Performance optimizations
- [ ] DMA support investigation
- [ ] Hardware timestamping
- [ ] Advanced QoS features
- [ ] Netlink configuration interface

### v5.0.0 (2026)
- [ ] Upstream Linux kernel submission
- [ ] DSA (Distributed Switch Architecture) integration
- [ ] TSN (Time-Sensitive Networking) features
- [ ] Multi-chip cascading support
- [ ] Advanced diagnostics and monitoring

---

## Support Matrix

| Feature | v1.0.0 | v2.0.0 | v3.0.0 | v3.0.1 | v4.0.0 |
|---------|--------|--------|--------|--------|--------|
| Basic Ethernet | ✅ | ✅ | ✅ | ✅ | ✅ |
| SPI Communication | ✅ | ✅ | ✅ | ✅ | ✅ |
| QEMU Support | ❌ | ✅ | ✅ | ✅ | ✅ |
| Kernel 6.6+ | ❌ | ❌ | ❌ | ✅ | ✅ |
| Single Interface | ❌ | ❌ | ❌ | ❌ | ✅ |
| MAC Learning | ❌ | ❌ | ❌ | ❌ | ✅ |
| Hardware Forwarding | ❌ | ❌ | Partial | Partial | ✅ |

---

## Contributors

- **Murray Kopit** (@murr2k) - Lead Developer & Maintainer
- **Analog Devices** - Reference driver and hardware specifications
- **Linux Kernel Community** - Reviews and guidance

### Special Thanks
- STMicroelectronics for STM32MP153 platform support
- QEMU developers for virtualization framework
- All beta testers and bug reporters

---

## How to Contribute

We welcome contributions! Please follow these steps:

1. Check [open issues](https://github.com/murr2k/ADIN2111/issues)
2. Fork the repository
3. Create a feature branch (`git checkout -b feature/AmazingFeature`)
4. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
5. Update CHANGELOG.md with your changes
6. Push to the branch (`git push origin feature/AmazingFeature`)
7. Open a Pull Request

### Contribution Guidelines
- Follow kernel coding style
- Add appropriate documentation
- Include test cases where applicable
- Update relevant documentation
- Sign-off your commits (`git commit -s`)

---

## Bug Reports

Please report bugs through [GitHub Issues](https://github.com/murr2k/ADIN2111/issues) with:
- Kernel version (`uname -r`)
- Driver version
- Hardware platform
- Detailed description
- Steps to reproduce
- Kernel logs (`dmesg`)

---

## License

This project is licensed under the GNU General Public License v2.0. See [LICENSE](LICENSE) for details.

---

*For detailed commit history, see [GitHub Commits](https://github.com/murr2k/ADIN2111/commits/main)*
*For release binaries, see [GitHub Releases](https://github.com/murr2k/ADIN2111/releases)*
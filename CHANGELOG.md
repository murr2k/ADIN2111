# Changelog

All notable changes to the ADIN2111 Linux Driver project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-08-11

### Added
- Initial release of ADIN2111 Linux driver with hardware switch mode
- Single network interface abstraction (sw0) eliminating need for software bridge
- Hardware cut-through switching with <2μs latency
- Dual MAC mode for backward compatibility
- Comprehensive test suite with 20+ test scenarios
- Complete documentation including Theory of Operation
- Device tree binding support (YAML schema)
- SPI interface up to 25 MHz
- NAPI polling for efficient packet processing
- Hardware CRC calculation and validation
- MAC address filtering (16 slots per port)
- Per-port statistics collection
- Module parameters for runtime configuration
- Integration guide for migration from dual-interface setup

### Features
- **Switch Mode**: Autonomous hardware switching between ports
- **Cut-Through Mode**: PORT_CUT_THRU_EN for minimal latency
- **Zero CPU Switching**: No CPU involvement for inter-port traffic
- **Performance**: Line-rate throughput with negligible CPU usage
- **Compatibility**: Works with kernel 5.10+

### Technical Details
- Driver Architecture: 7 core source files
- Register Definitions: Complete ADIN2111 register map
- Test Coverage: 95% with automated test suite
- Documentation: Theory of Operation with 15+ Mermaid diagrams

### Author
- Murray Kopit (murr2k@gmail.com)

### License
- GPL v2+ (Linux kernel compatible)

---

## Future Releases

### [Planned Features]
- DMA support for improved performance
- Advanced VLAN tagging and filtering
- Hardware timestamping (IEEE 1588)
- Wake-on-LAN support
- Traffic shaping and QoS
- Extended ethtool support
- Power management optimizations

### [Known Issues]
- None in initial release

---

For detailed commit history, see the git log.
# ADIN2111 Driver Build Instructions

## Current Branch and Version
**Branch:** `feature/qemu-hybrid-testing`  
**Version:** v3.0.4 (Critical lockup fix)

## Getting the Latest Code

```bash
# Clone or update the repository
git clone https://github.com/murr2k/ADIN2111.git
cd ADIN2111

# Switch to the correct branch
git checkout feature/qemu-hybrid-testing

# Pull latest changes
git pull origin feature/qemu-hybrid-testing
```

## Building the Driver

### Option 1: Using the Driver Package (Recommended)
```bash
# Navigate to the pre-configured driver package
cd adin2111_driver_package/

# Build using the included Makefile
make clean
make

# The module will be: adin2111.ko
```

### Option 2: Building from Source Directory
```bash
# Navigate to the driver source
cd drivers/net/ethernet/adi/adin2111/

# Build using the Makefile
make clean
make

# The module will be: adin2111.ko
```

## Loading the Module

```bash
# Load with single interface mode (recommended for your platform)
sudo modprobe adin2111 single_interface_mode=1

# Or with insmod
sudo insmod adin2111.ko single_interface_mode=1
```

## Important Notes

1. **Always use branch:** `feature/qemu-hybrid-testing` (not main/master)
2. **Makefile location:** `adin2111_driver_package/Makefile` (recommended)
3. **Latest stable version:** v3.0.4 with critical lockup fix
4. **Cross-compilation:** Use your ARM toolchain as before

## Version History
- **v3.0.4**: Fixed critical SPI bus deadlock causing system lockup
- **v3.0.3**: Complete rewrite based on ADI baseline driver
- **v3.0.2**: Initial production release

## Quick Build Commands
```bash
# Complete sequence from fresh clone
git clone https://github.com/murr2k/ADIN2111.git
cd ADIN2111
git checkout feature/qemu-hybrid-testing
cd adin2111_driver_package/
make clean && make
# Your module is ready: adin2111.ko
```
# Requirements for Testing Kernel Panic Fixes in QEMU/Docker

## Prerequisites

### 1. Docker Environment
- Docker installed and running
- Sufficient disk space (~2GB)
- Internet connection for downloading dependencies

### 2. Required Files
- ADIN2111 driver source code (drivers/net/ethernet/adi/adin2111/)
- QEMU device model (qemu/hw/net/adin2111.c)
- Test scripts (created by this setup)

## Components Created

### Test Infrastructure
1. **Dockerfile.kernel-test** - Ubuntu 24.04 with ARM cross-compilation tools
2. **adin2111_test.c** - Kernel module with 8 panic test scenarios
3. **Makefile.module** - Build configuration for kernel modules
4. **run-qemu-kernel-test.sh** - QEMU ARM emulation script
5. **docker-run-kernel-test.sh** - Docker orchestration script

### Test Scenarios Covered

| Test # | Scenario | Expected Result |
|--------|----------|-----------------|
| 1 | NULL SPI device | Return -EINVAL |
| 2 | Missing SPI controller | Return -ENODEV |
| 3 | IRQ registration failure | Fall back to polling |
| 4 | Memory allocation failure | Graceful cleanup |
| 5 | Concurrent access | Mutex protection |
| 6 | Work queue race | Proper initialization |
| 7 | PHY init failure | Clean shutdown |
| 8 | Regmap NULL | Validation check |

## Running the Tests

### Quick Test (Docker + QEMU)
```bash
# One command to test everything
./docker-run-kernel-test.sh
```

### Manual Steps
```bash
# 1. Build Docker image
docker build -f Dockerfile.kernel-test -t adin2111-kernel-test:latest .

# 2. Run container interactively
docker run --rm -it --cap-add SYS_ADMIN adin2111-kernel-test:latest

# 3. Inside container, run tests
./run-qemu-kernel-test.sh
```

### Expected Output
```
=== ADIN2111 Kernel Panic Test Environment ===

Loading ADIN2111 test module...
TEST 1: Testing NULL SPI device handling...
TEST 1: PASS - NULL SPI handled correctly
TEST 2: Testing missing SPI controller...
TEST 2: PASS - Missing controller handled
...
TEST 8: PASS - Regmap NULL check working

==============================================
ALL TESTS PASSED - No kernel panics detected!
==============================================
```

## What Gets Tested

### Driver Robustness
- Input validation in probe function
- Error handling paths
- Resource cleanup on failure
- Fallback mechanisms (IRQ → polling)

### Kernel Stability
- No panics under error conditions
- Proper error codes returned
- Clean module unload
- No memory leaks

### Integration Points
- SPI subsystem interaction
- IRQ subsystem handling
- Network device registration
- PHY management

## Success Criteria

✅ All 8 test scenarios pass
✅ No kernel panics or oops
✅ Clean module load/unload
✅ Proper error messages in dmesg
✅ System remains stable after tests

## Troubleshooting

### If Docker build fails:
- Check internet connection
- Verify Docker daemon is running
- Ensure sufficient disk space

### If QEMU tests fail:
- Check kernel module compilation
- Verify ARM cross-compiler installation
- Review qemu-output.log for details

### If kernel panic occurs:
- The fixes haven't been applied correctly
- Review dmesg output for panic location
- Check driver source for missing validations

## Next Steps After Testing

1. **If all tests pass:**
   - Deploy to actual STM32MP153 hardware
   - Run performance benchmarks
   - Begin stress testing

2. **If tests fail:**
   - Review specific failing test
   - Check corresponding code section
   - Apply additional fixes as needed

## Files Generated During Testing

- `vmlinuz-arm` - ARM kernel for QEMU
- `busybox-arm` - Minimal userspace utilities
- `initramfs.gz` - Test environment filesystem
- `qemu-output.log` - Complete test output
- `*.ko` - Compiled kernel modules

---
*Created: January 19, 2025*
*Purpose: Validate ADIN2111 kernel panic fixes before hardware deployment*

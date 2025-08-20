# 🧪 ADIN2111 QEMU Comprehensive Test Plan for WSL Environment

## Overview
Establish a complete testing framework for the ADIN2111 device model in QEMU, including driver validation, timing verification, and CI/CD integration. This plan provides a structured approach to validate both the virtual device model and Linux kernel driver in a WSL2 environment.

## 📋 Test Plan Components

### 1. Development Environment Setup (WSL2)
**Objective:** Configure complete build environment for cross-compilation and testing

#### Tasks:
- [ ] Install ARM cross-compiler toolchain (`arm-linux-gnueabihf-gcc`)
- [ ] Install QEMU build dependencies (`libglib2.0-dev`, `libpixman-1-dev`, `meson`, `ninja-build`)
- [ ] Install device tree compiler (`dtc`)
- [ ] Set up QTest framework dependencies
- [ ] Configure Python environment for test automation

```bash
# Setup script location: scripts/setup-dev-env.sh
sudo apt-get update
sudo apt-get install -y \
    gcc-arm-linux-gnueabihf \
    g++-arm-linux-gnueabihf \
    device-tree-compiler \
    libglib2.0-dev \
    libpixman-1-dev \
    python3-pip \
    ninja-build
pip3 install meson
```

### 2. Project Directory Structure
**Objective:** Organize test artifacts and build outputs

```
adin2111-test/
├── qemu/                 # Patched QEMU with ADIN2111 model
├── linux/                # Linux kernel with ADIN2111 driver
├── dts/                  # Device tree sources
│   ├── virt-adin2111.dts
│   └── virt-adin2111-dual.dts
├── rootfs/              # Root filesystem images
│   └── rootfs.ext4
├── tests/               # Test suites
│   ├── qtest/          # QEMU unit tests
│   ├── functional/    # Functional tests
│   └── timing/        # Timing validation
├── scripts/            # Automation scripts
├── logs/              # Test outputs
└── Makefile           # Master build orchestration
```

### 3. QEMU virt Machine SPI Integration
**Objective:** Add SPI controller support to ARM virt machine

#### Implementation Steps:
- [ ] Modify `hw/arm/virt.c` to add PL022 SPI controller
- [ ] Add SPI controller to virt machine device tree
- [ ] Configure SSI bus for ADIN2111 attachment
- [ ] Rebuild QEMU with SPI-enabled virt machine

```c
// Patch location: patches/0002-virt-add-spi-controller.patch
// Add to virt.c:
static void create_spi(const VirtMachineState *vms, MemoryRegion *mem)
{
    hwaddr base = vms->memmap[VIRT_SPI].base;
    hwaddr size = vms->memmap[VIRT_SPI].size;
    int irq = vms->irqmap[VIRT_SPI];
    
    sysbus_create_simple("pl022", base, qdev_get_gpio_in(vms->gic, irq));
}
```

### 4. Linux Kernel Configuration
**Objective:** Build kernel with ADIN2111 driver support

#### Configuration Requirements:
- [ ] Enable CONFIG_SPI=y
- [ ] Enable CONFIG_SPI_PL022=y
- [ ] Enable CONFIG_ADIN2111=y
- [ ] Enable CONFIG_PHYLIB=y
- [ ] Enable CONFIG_FIXED_PHY=y

```bash
# Kernel config script: scripts/configure-kernel.sh
cd linux/
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- vexpress_defconfig
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- menuconfig
# Enable SPI and ADIN2111 driver
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc) zImage dtbs
```

### 5. Device Tree Configuration
**Objective:** Define ADIN2111 hardware topology

```dts
// File: dts/virt-adin2111.dts
/dts-v1/;
/include/ "virt.dtsi"

&spi0 {
    status = "okay";
    
    adin2111: ethernet@0 {
        compatible = "adi,adin2111";
        reg = <0>;
        spi-max-frequency = <25000000>;
        spi-cpha;
        spi-cpol;
        
        interrupt-parent = <&gic>;
        interrupts = <GIC_SPI 48 IRQ_TYPE_LEVEL_HIGH>;
        
        mac-address = [52 54 00 12 34 56];
        
        phy0: ethernet-phy@0 {
            reg = <0>;
        };
        
        phy1: ethernet-phy@1 {
            reg = <1>;
        };
    };
};
```

### 6. QEMU Launch Configuration
**Objective:** Boot virtual machine with ADIN2111 device

```bash
#!/bin/bash
# File: scripts/run-qemu.sh

QEMU=/home/murr2k/qemu/build/qemu-system-arm
KERNEL=linux/arch/arm/boot/zImage
DTB=dts/virt-adin2111.dtb
ROOTFS=rootfs/rootfs.ext4

$QEMU \
    -M virt \
    -cpu cortex-a7 \
    -m 512M \
    -nographic \
    -kernel $KERNEL \
    -dtb $DTB \
    -append "console=ttyAMA0 root=/dev/vda2 rw loglevel=8" \
    -drive file=$ROOTFS,format=raw,if=none,id=hd \
    -device virtio-blk-device,drive=hd \
    -netdev user,id=net0 \
    -device adin2111,id=eth0,netdev=net0,mac=52:54:00:12:34:56 \
    -serial mon:stdio \
    2>&1 | tee logs/qemu-boot-$(date +%Y%m%d-%H%M%S).log
```

### 7. Functional Test Suite
**Objective:** Validate ADIN2111 driver and device model functionality

#### Test Cases:
- [ ] **TC001**: Device Probe - Verify driver loads and detects ADIN2111
- [ ] **TC002**: Interface Creation - Check eth0/eth1 interfaces created
- [ ] **TC003**: Link State - Test link up/down detection
- [ ] **TC004**: Basic Connectivity - Ping test through device
- [ ] **TC005**: Dual Port Operation - Test both ports simultaneously
- [ ] **TC006**: MAC Filtering - Verify MAC address filtering
- [ ] **TC007**: Statistics - Check packet counters
- [ ] **TC008**: Error Handling - Test error conditions

```bash
#!/bin/bash
# File: tests/functional/run-tests.sh

echo "=== ADIN2111 Functional Test Suite ==="

# TC001: Device Probe
dmesg | grep -q "adin2111" && echo "✓ TC001: Device probed" || echo "✗ TC001: Device not found"

# TC002: Interface Creation
ip link show eth0 && echo "✓ TC002: eth0 created" || echo "✗ TC002: eth0 missing"

# TC003: Link State
ip link set eth0 up
sleep 2
ip link show eth0 | grep -q "UP" && echo "✓ TC003: Link up" || echo "✗ TC003: Link down"

# TC004: Basic Connectivity
ip addr add 192.168.1.10/24 dev eth0
ping -c 3 192.168.1.1 && echo "✓ TC004: Ping successful" || echo "✗ TC004: Ping failed"
```

### 8. QTest Implementation
**Objective:** Unit test ADIN2111 QEMU device model

```c
// File: tests/qtest/adin2111-test.c
#include "qemu/osdep.h"
#include "libqtest.h"
#include "qapi/qmp/qdict.h"

static void test_adin2111_probe(void)
{
    QTestState *qts;
    qts = qtest_init("-M virt -device adin2111,id=eth0");
    
    // Verify device exists
    QDict *resp = qtest_qmp(qts, "{ 'execute': 'qom-list', "
                                  "'arguments': { 'path': '/machine/peripheral/eth0' }}");
    g_assert(resp != NULL);
    
    qtest_quit(qts);
}

static void test_adin2111_registers(void)
{
    QTestState *qts;
    qts = qtest_init("-M virt -device adin2111,id=eth0");
    
    // Test CHIP_ID register (0x2111)
    uint32_t chip_id = qtest_readl(qts, ADIN2111_BASE + ADIN2111_REG_CHIP_ID);
    g_assert_cmpint(chip_id, ==, 0x2111);
    
    qtest_quit(qts);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);
    
    qtest_add_func("/adin2111/probe", test_adin2111_probe);
    qtest_add_func("/adin2111/registers", test_adin2111_registers);
    
    return g_test_run();
}
```

### 9. Timing Validation Tests
**Objective:** Verify timing specifications match datasheet

#### Timing Requirements (from datasheet Rev. B):
- [ ] Reset time: 50ms ± 5%
- [ ] PHY RX latency: 6.4µs ± 10%
- [ ] PHY TX latency: 3.2µs ± 10%
- [ ] Switch latency: 12.6µs ± 10%
- [ ] Power-on time: 43ms ± 5%

```python
#!/usr/bin/env python3
# File: tests/timing/validate_timing.py

import time
import subprocess
import re

def measure_reset_time():
    """Measure device reset timing"""
    start = time.time()
    # Trigger reset via SPI command
    subprocess.run(["./spi-tool", "reset"])
    # Wait for ready signal
    while not check_ready():
        time.sleep(0.001)
    elapsed = (time.time() - start) * 1000  # Convert to ms
    
    assert 47.5 <= elapsed <= 52.5, f"Reset time {elapsed}ms out of spec"
    print(f"✓ Reset time: {elapsed:.1f}ms (spec: 50ms ± 5%)")

def measure_packet_latency():
    """Measure packet switching latency"""
    # Implementation for packet latency measurement
    pass
```

### 10. Master Makefile
**Objective:** Orchestrate entire build and test pipeline

```makefile
# Master Makefile for ADIN2111 Test Suite
ARCH      := arm
CROSS     := arm-linux-gnueabihf-
JOBS      := $(shell nproc)
KERNELDIR := linux
QEMUDIR   := qemu
DTS       := dts/virt-adin2111.dts
DTB       := dts/virt-adin2111.dtb
ZIMAGE    := $(KERNELDIR)/arch/$(ARCH)/boot/zImage
ROOTFS    := rootfs/rootfs.ext4
QEMU      := $(QEMUDIR)/build/qemu-system-arm
LOGDIR    := logs

# Color output
RED       := \033[0;31m
GREEN     := \033[0;32m
YELLOW    := \033[0;33m
NC        := \033[0m

.PHONY: all deps kernel qemu dtb rootfs test-functional test-qtest test-timing clean report

all: deps qemu kernel dtb test-functional test-qtest test-timing report

deps:
	@echo "$(YELLOW)📦 Checking dependencies...$(NC)"
	@./scripts/check-deps.sh

kernel:
	@echo "$(YELLOW)🔨 Building Linux kernel with ADIN2111 driver...$(NC)"
	@cd $(KERNELDIR) && \
	make ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) vexpress_defconfig && \
	./scripts/config --enable CONFIG_ADIN2111 && \
	make ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) -j$(JOBS) zImage dtbs
	@echo "$(GREEN)✓ Kernel built$(NC)"

qemu:
	@echo "$(YELLOW)🏗️ Building QEMU with ADIN2111 support...$(NC)"
	@cd $(QEMUDIR) && \
	./configure --target-list=arm-softmmu --enable-debug && \
	cd build && ninja -j$(JOBS)
	@echo "$(GREEN)✓ QEMU built$(NC)"

dtb:
	@echo "$(YELLOW)🌳 Compiling device tree...$(NC)"
	@dtc -I dts -O dtb -o $(DTB) $(DTS)
	@echo "$(GREEN)✓ Device tree compiled$(NC)"

rootfs:
	@echo "$(YELLOW)💾 Preparing root filesystem...$(NC)"
	@./scripts/build-rootfs.sh
	@echo "$(GREEN)✓ Root filesystem ready$(NC)"

test-functional: kernel qemu dtb
	@echo "$(YELLOW)🧪 Running functional tests...$(NC)"
	@mkdir -p $(LOGDIR)
	@./scripts/run-qemu.sh &
	@sleep 10
	@./tests/functional/run-tests.sh | tee $(LOGDIR)/functional-test.log
	@echo "$(GREEN)✓ Functional tests complete$(NC)"

test-qtest: qemu
	@echo "$(YELLOW)🔬 Running QTest suite...$(NC)"
	@cd $(QEMUDIR)/build && \
	QTEST_QEMU_BINARY=$(QEMU) ./tests/qtest/adin2111-test | tee ../../$(LOGDIR)/qtest.log
	@echo "$(GREEN)✓ QTest complete$(NC)"

test-timing:
	@echo "$(YELLOW)⏱️ Running timing validation...$(NC)"
	@python3 tests/timing/validate_timing.py | tee $(LOGDIR)/timing-test.log
	@echo "$(GREEN)✓ Timing tests complete$(NC)"

report:
	@echo "$(YELLOW)📊 Generating test report...$(NC)"
	@./scripts/generate-report.sh > $(LOGDIR)/test-report-$(shell date +%Y%m%d-%H%M%S).html
	@echo "$(GREEN)✓ Test report generated$(NC)"

clean:
	@echo "$(YELLOW)🧹 Cleaning build artifacts...$(NC)"
	@cd $(KERNELDIR) && make ARCH=$(ARCH) clean
	@cd $(QEMUDIR)/build && ninja clean
	@rm -f $(DTB) $(LOGDIR)/*.log
	@echo "$(GREEN)✓ Clean complete$(NC)"

# CI/CD targets
ci-test: all
	@echo "$(YELLOW)🚀 Running CI/CD test pipeline...$(NC)"
	@./scripts/ci-runner.sh

docker-test:
	@echo "$(YELLOW)🐳 Running tests in Docker...$(NC)"
	@docker build -t adin2111-test .
	@docker run --rm -v $(PWD):/workspace adin2111-test make all
```

### 11. CI/CD Integration
**Objective:** Automate testing in GitHub Actions

```yaml
# File: .github/workflows/test-adin2111.yml
name: ADIN2111 Test Suite

on:
  push:
    branches: [ main, develop ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ubuntu-22.04
    
    steps:
    - uses: actions/checkout@v3
    
    - name: Setup dependencies
      run: |
        sudo apt-get update
        sudo apt-get install -y \
          gcc-arm-linux-gnueabihf \
          device-tree-compiler \
          libglib2.0-dev \
          libpixman-1-dev \
          ninja-build
    
    - name: Build QEMU
      run: make qemu
    
    - name: Build Kernel
      run: make kernel
    
    - name: Run QTest
      run: make test-qtest
    
    - name: Upload test results
      uses: actions/upload-artifact@v3
      with:
        name: test-results
        path: logs/
```

### 12. Success Criteria
**Objective:** Define pass/fail criteria for test suite

#### Minimum Requirements:
- [ ] All functional tests pass (8/8)
- [ ] QTest suite passes (100%)
- [ ] Timing within datasheet specifications
- [ ] No kernel panics or QEMU crashes
- [ ] Network throughput > 10 Mbps
- [ ] Memory leak test passes (valgrind)

### 13. Test Artifacts
**Objective:** Document and store test outputs

#### Required Artifacts:
- [ ] Boot logs with driver probe messages
- [ ] Network interface configuration dumps
- [ ] Packet capture files (pcap)
- [ ] Timing measurement data
- [ ] QTest XML results
- [ ] Code coverage reports
- [ ] Performance benchmarks

### 14. Known Issues and Limitations

#### Current Limitations:
- WSL2 may have timing precision limitations
- virt machine requires SPI controller patch
- No hardware loopback testing possible
- Limited to single QEMU instance testing

### 15. Future Enhancements

#### Roadmap:
- [ ] Multi-instance testing (multiple ADIN2111 devices)
- [ ] Stress testing with iperf3
- [ ] Power management testing
- [ ] Hot-plug/unplug scenarios
- [ ] Integration with real hardware via USB-SPI bridge

## Deliverables

1. **Test Framework**: Complete test suite with automation
2. **Documentation**: Test procedures and results
3. **CI/CD Pipeline**: Automated testing on commits
4. **Makefile**: One-command test execution
5. **Reports**: HTML test reports with pass/fail status

## Timeline

- **Week 1**: Environment setup and QEMU patches
- **Week 2**: Kernel driver integration and device tree
- **Week 3**: Functional and timing tests
- **Week 4**: CI/CD integration and documentation

## Dependencies

- QEMU v9.0.0+ with ADIN2111 model
- Linux kernel 5.15+ with ADIN2111 driver
- WSL2 with Ubuntu 22.04
- ARM cross-compilation toolchain

## References

- [ADIN2111 Datasheet Rev. B](https://www.analog.com/media/en/technical-documentation/data-sheets/adin2111.pdf)
- [QEMU Testing Documentation](https://www.qemu.org/docs/master/devel/testing.html)
- [Linux SPI Framework](https://www.kernel.org/doc/html/latest/driver-api/spi.html)

---
*Test plan version: 1.0*
*Created: August 2025*
*Target: ADIN2111 QEMU Virtual Device Model*
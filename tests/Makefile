# ADIN2111 Test Suite Makefile
# Copyright (C) 2025 Analog Devices Inc.

# Kernel build directory
KERNEL_DIR ?= /lib/modules/$(shell uname -r)/build

# Build directories
BUILD_DIR := build
KERNEL_BUILD_DIR := $(BUILD_DIR)/kernel
USERSPACE_BUILD_DIR := $(BUILD_DIR)/userspace
BENCHMARK_BUILD_DIR := $(BUILD_DIR)/benchmarks

# Source directories
KERNEL_SRC_DIR := kernel
USERSPACE_SRC_DIR := userspace
BENCHMARK_SRC_DIR := benchmarks
SCRIPTS_DIR := scripts

# Compiler flags
CC := gcc
CFLAGS := -Wall -Wextra -O2 -std=gnu99
LDFLAGS := -pthread

# Target binaries
USERSPACE_TARGETS := \
	$(USERSPACE_BUILD_DIR)/utils/adin2111_test_util

BENCHMARK_TARGETS := \
	$(BENCHMARK_BUILD_DIR)/throughput/adin2111_throughput_bench \
	$(BENCHMARK_BUILD_DIR)/latency/adin2111_latency_bench \
	$(BENCHMARK_BUILD_DIR)/cpu/adin2111_cpu_bench

KERNEL_MODULE := $(KERNEL_BUILD_DIR)/adin2111_test.ko

# All targets
ALL_TARGETS := $(USERSPACE_TARGETS) $(BENCHMARK_TARGETS) $(KERNEL_MODULE)

.PHONY: all clean kernel userspace benchmarks install test help

# Default target
all: $(ALL_TARGETS)

# Help target
help:
	@echo "ADIN2111 Test Suite Build System"
	@echo "================================"
	@echo ""
	@echo "Targets:"
	@echo "  all        - Build all components (kernel module, userspace tools, benchmarks)"
	@echo "  kernel     - Build kernel test module"
	@echo "  userspace  - Build userspace test utilities"
	@echo "  benchmarks - Build performance benchmark tools"
	@echo "  install    - Install test suite (requires root)"
	@echo "  test       - Run basic validation tests"
	@echo "  clean      - Clean all build artifacts"
	@echo "  help       - Show this help message"
	@echo ""
	@echo "Variables:"
	@echo "  KERNEL_DIR - Kernel build directory (default: /lib/modules/\$$(uname -r)/build)"
	@echo "  CC         - C compiler (default: gcc)"
	@echo "  CFLAGS     - C compiler flags"
	@echo ""
	@echo "Examples:"
	@echo "  make all                    # Build everything"
	@echo "  make kernel                 # Build only kernel module"
	@echo "  make KERNEL_DIR=/path/to/kernel kernel  # Use custom kernel"
	@echo "  make install               # Install test suite"

# Create build directories
$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)
	@mkdir -p $(KERNEL_BUILD_DIR)
	@mkdir -p $(USERSPACE_BUILD_DIR)/utils
	@mkdir -p $(BENCHMARK_BUILD_DIR)/throughput
	@mkdir -p $(BENCHMARK_BUILD_DIR)/latency
	@mkdir -p $(BENCHMARK_BUILD_DIR)/cpu

# Kernel module build
$(KERNEL_MODULE): $(KERNEL_SRC_DIR)/adin2111_test.c | $(BUILD_DIR)
	@echo "Building kernel test module..."
	@cp $(KERNEL_SRC_DIR)/adin2111_test.c $(KERNEL_BUILD_DIR)/
	@echo "obj-m := adin2111_test.o" > $(KERNEL_BUILD_DIR)/Makefile
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD)/$(KERNEL_BUILD_DIR) modules
	@echo "Kernel module built: $(KERNEL_MODULE)"

# Userspace utilities
$(USERSPACE_BUILD_DIR)/utils/adin2111_test_util: $(USERSPACE_SRC_DIR)/utils/adin2111_test_util.c | $(BUILD_DIR)
	@echo "Building userspace test utility..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@echo "Built: $@"

# Benchmark tools
$(BENCHMARK_BUILD_DIR)/throughput/adin2111_throughput_bench: $(BENCHMARK_SRC_DIR)/throughput/adin2111_throughput_bench.c | $(BUILD_DIR)
	@echo "Building throughput benchmark..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) -lm
	@echo "Built: $@"

$(BENCHMARK_BUILD_DIR)/latency/adin2111_latency_bench: $(BENCHMARK_SRC_DIR)/latency/adin2111_latency_bench.c | $(BUILD_DIR)
	@echo "Building latency benchmark..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) -lm
	@echo "Built: $@"

$(BENCHMARK_BUILD_DIR)/cpu/adin2111_cpu_bench: $(BENCHMARK_SRC_DIR)/cpu/adin2111_cpu_bench.c | $(BUILD_DIR)
	@echo "Building CPU benchmark..."
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)
	@echo "Built: $@"

# Target groups
kernel: $(KERNEL_MODULE)

userspace: $(USERSPACE_TARGETS)

benchmarks: $(BENCHMARK_TARGETS)

# Install target
install: all
	@echo "Installing ADIN2111 test suite..."
	@if [ "$$(id -u)" != "0" ]; then \
		echo "Error: Installation requires root privileges"; \
		exit 1; \
	fi
	
	# Install kernel module
	@mkdir -p /lib/modules/$(shell uname -r)/extra
	@cp $(KERNEL_MODULE) /lib/modules/$(shell uname -r)/extra/
	@depmod -a
	@echo "Kernel module installed"
	
	# Install userspace binaries
	@mkdir -p /usr/local/bin
	@cp $(USERSPACE_TARGETS) /usr/local/bin/
	@cp $(BENCHMARK_TARGETS) /usr/local/bin/
	@chmod +x /usr/local/bin/adin2111_*
	@echo "Userspace tools installed to /usr/local/bin"
	
	# Install scripts
	@mkdir -p /usr/local/share/adin2111-tests/scripts
	@cp -r $(SCRIPTS_DIR)/* /usr/local/share/adin2111-tests/scripts/
	@chmod +x /usr/local/share/adin2111-tests/scripts/automation/*.sh
	@chmod +x /usr/local/share/adin2111-tests/scripts/validation/*.sh
	@echo "Scripts installed to /usr/local/share/adin2111-tests/scripts"
	
	# Create symlink for main test runner
	@ln -sf /usr/local/share/adin2111-tests/scripts/automation/run_all_tests.sh /usr/local/bin/adin2111-test-suite
	@echo "Test suite symlink created: /usr/local/bin/adin2111-test-suite"
	
	@echo "Installation complete!"

# Uninstall target
uninstall:
	@echo "Uninstalling ADIN2111 test suite..."
	@if [ "$$(id -u)" != "0" ]; then \
		echo "Error: Uninstallation requires root privileges"; \
		exit 1; \
	fi
	
	# Remove kernel module
	@rm -f /lib/modules/$(shell uname -r)/extra/adin2111_test.ko
	@depmod -a
	
	# Remove userspace binaries
	@rm -f /usr/local/bin/adin2111_*
	@rm -f /usr/local/bin/adin2111-test-suite
	
	# Remove scripts
	@rm -rf /usr/local/share/adin2111-tests
	
	@echo "Uninstallation complete!"

# Test target
test: all
	@echo "Running basic validation tests..."
	@if [ ! -x "$(USERSPACE_BUILD_DIR)/utils/adin2111_test_util" ]; then \
		echo "Error: Test utilities not built"; \
		exit 1; \
	fi
	
	# Test utility help
	@echo "Testing utility help output..."
	@$(USERSPACE_BUILD_DIR)/utils/adin2111_test_util -h > /dev/null
	@echo "✓ Utility help works"
	
	# Test benchmark help
	@echo "Testing benchmark help output..."
	@$(BENCHMARK_BUILD_DIR)/throughput/adin2111_throughput_bench -h > /dev/null
	@$(BENCHMARK_BUILD_DIR)/latency/adin2111_latency_bench -h > /dev/null
	@$(BENCHMARK_BUILD_DIR)/cpu/adin2111_cpu_bench -h > /dev/null
	@echo "✓ Benchmark help works"
	
	# Test script syntax
	@echo "Testing script syntax..."
	@bash -n $(SCRIPTS_DIR)/automation/run_all_tests.sh
	@bash -n $(SCRIPTS_DIR)/validation/test_basic.sh
	@bash -n $(SCRIPTS_DIR)/validation/test_stress.sh
	@bash -n $(SCRIPTS_DIR)/validation/test_integration.sh
	@echo "✓ Script syntax is valid"
	
	@echo "Basic validation tests passed!"

# Development targets
debug: CFLAGS += -g -DDEBUG
debug: all

static: CFLAGS += -static
static: userspace benchmarks

# Clean target
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR)
	@rm -f *.o *.ko *.mod.c modules.order Module.symvers
	@echo "Clean complete"

# Kernel module specific targets
kernel-clean:
	@echo "Cleaning kernel module build..."
	@rm -rf $(KERNEL_BUILD_DIR)
	@echo "Kernel clean complete"

kernel-install: kernel
	@if [ "$$(id -u)" != "0" ]; then \
		echo "Error: Kernel module installation requires root privileges"; \
		exit 1; \
	fi
	@mkdir -p /lib/modules/$(shell uname -r)/extra
	@cp $(KERNEL_MODULE) /lib/modules/$(shell uname -r)/extra/
	@depmod -a
	@echo "Kernel module installed"

kernel-load: kernel-install
	@if lsmod | grep -q adin2111_test; then \
		echo "Unloading existing module..."; \
		rmmod adin2111_test; \
	fi
	@echo "Loading kernel test module..."
	@modprobe adin2111_test
	@echo "Kernel module loaded"

kernel-unload:
	@if lsmod | grep -q adin2111_test; then \
		echo "Unloading kernel test module..."; \
		rmmod adin2111_test; \
		echo "Kernel module unloaded"; \
	else \
		echo "Kernel module not loaded"; \
	fi

# Package target for distribution
package: all
	@echo "Creating distribution package..."
	@mkdir -p dist/adin2111-test-suite
	@cp -r $(BUILD_DIR)/* dist/adin2111-test-suite/
	@cp -r $(SCRIPTS_DIR) dist/adin2111-test-suite/
	@cp -r docs dist/adin2111-test-suite/
	@cp Makefile dist/adin2111-test-suite/
	@tar -czf adin2111-test-suite.tar.gz -C dist adin2111-test-suite
	@echo "Package created: adin2111-test-suite.tar.gz"

# Show build info
info:
	@echo "ADIN2111 Test Suite Build Information"
	@echo "===================================="
	@echo "Kernel directory: $(KERNEL_DIR)"
	@echo "Kernel version: $(shell uname -r)"
	@echo "Compiler: $(CC)"
	@echo "Compiler flags: $(CFLAGS)"
	@echo "Linker flags: $(LDFLAGS)"
	@echo "Build directory: $(BUILD_DIR)"
	@echo ""
	@echo "Targets to build:"
	@echo "  Kernel module: $(KERNEL_MODULE)"
	@echo "  Userspace tools: $(words $(USERSPACE_TARGETS)) binaries"
	@echo "  Benchmark tools: $(words $(BENCHMARK_TARGETS)) binaries"

# Check dependencies
check-deps:
	@echo "Checking build dependencies..."
	@which $(CC) > /dev/null || (echo "Error: $(CC) not found" && exit 1)
	@[ -d "$(KERNEL_DIR)" ] || (echo "Error: Kernel build directory not found: $(KERNEL_DIR)" && exit 1)
	@[ -f "$(KERNEL_DIR)/Makefile" ] || (echo "Error: Kernel Makefile not found" && exit 1)
	@which make > /dev/null || (echo "Error: make not found" && exit 1)
	@echo "✓ All build dependencies satisfied"

# Runtime dependency check
check-runtime-deps:
	@echo "Checking runtime dependencies..."
	@which ip > /dev/null || echo "Warning: ip command not found (required for network tests)"
	@which ethtool > /dev/null || echo "Warning: ethtool not found (optional for advanced tests)"
	@which nc > /dev/null || echo "Warning: nc (netcat) not found (required for some tests)"
	@which ping > /dev/null || echo "Warning: ping not found (required for connectivity tests)"
	@echo "Runtime dependency check complete"

# Validate build
validate: all test check-runtime-deps
	@echo "Build validation complete!"

.PRECIOUS: $(BUILD_DIR)
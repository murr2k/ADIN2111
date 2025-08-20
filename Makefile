# Master Makefile for ADIN2111 Test Suite
ARCH      := arm
CROSS     := arm-linux-gnueabihf-
JOBS      := $(shell nproc)
KERNELDIR := linux
QEMUDIR   := /home/murr2k/qemu
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
BLUE      := \033[0;34m
NC        := \033[0m

.PHONY: all deps kernel qemu dtb rootfs test-functional test-qtest test-timing clean report help

all: deps qemu kernel dtb test-functional test-qtest test-timing report

deps:
	@echo "$(YELLOW)📦 Checking dependencies...$(NC)"
	@./scripts/check-deps.sh

kernel:
	@echo "$(YELLOW)🔨 Building Linux kernel with ADIN2111 driver...$(NC)"
	@if [ ! -d "$(KERNELDIR)" ]; then \
		echo "$(RED)❌ Kernel directory $(KERNELDIR) not found!$(NC)"; \
		echo "$(BLUE)💡 Please clone Linux kernel or adjust KERNELDIR variable$(NC)"; \
		exit 1; \
	fi
	@echo "$(BLUE)🔧 Configuring kernel...$(NC)"
	@./scripts/configure-kernel.sh
	@echo "$(BLUE)🔨 Building kernel...$(NC)"
	@cd $(KERNELDIR) && \
	make ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) -j$(JOBS) zImage dtbs
	@echo "$(GREEN)✓ Kernel built$(NC)"

qemu:
	@echo "$(YELLOW)🏗️ Building QEMU with ADIN2111 support...$(NC)"
	@if [ ! -d "$(QEMUDIR)" ]; then \
		echo "$(RED)❌ QEMU directory $(QEMUDIR) not found!$(NC)"; \
		echo "$(BLUE)💡 Please check QEMU installation path$(NC)"; \
		exit 1; \
	fi
	@cd $(QEMUDIR) && \
	if [ ! -f "build/build.ninja" ]; then \
		echo "$(BLUE)🔧 Configuring QEMU...$(NC)"; \
		./configure --target-list=arm-softmmu --enable-debug; \
	fi && \
	cd build && ninja -j$(JOBS)
	@echo "$(GREEN)✓ QEMU built$(NC)"

dtb:
	@echo "$(YELLOW)🌳 Compiling device tree...$(NC)"
	@if [ ! -f "$(DTS)" ]; then \
		echo "$(RED)❌ Device tree source $(DTS) not found!$(NC)"; \
		echo "$(BLUE)💡 Creating basic device tree template...$(NC)"; \
		mkdir -p dts; \
		./scripts/create-device-tree.sh > $(DTS); \
	fi
	@dtc -I dts -O dtb -o $(DTB) $(DTS)
	@echo "$(GREEN)✓ Device tree compiled$(NC)"

rootfs:
	@echo "$(YELLOW)💾 Preparing root filesystem...$(NC)"
	@if [ ! -f "scripts/build-rootfs.sh" ]; then \
		echo "$(BLUE)🔧 Creating rootfs build script...$(NC)"; \
		./scripts/create-rootfs-script.sh; \
	fi
	@./scripts/build-rootfs.sh
	@echo "$(GREEN)✓ Root filesystem ready$(NC)"

test-functional: kernel qemu dtb
	@echo "$(YELLOW)🧪 Running functional tests...$(NC)"
	@mkdir -p $(LOGDIR)
	@if [ ! -f "tests/functional/run-tests.sh" ]; then \
		echo "$(BLUE)🔧 Creating functional test script...$(NC)"; \
		./scripts/create-functional-tests.sh; \
	fi
	@echo "$(BLUE)🚀 Starting QEMU in background...$(NC)"
	@./tests/qemu/run-qemu-test.sh > $(LOGDIR)/qemu-boot.log 2>&1 &
	@sleep 10
	@./tests/functional/run-tests.sh | tee $(LOGDIR)/functional-test.log
	@echo "$(GREEN)✓ Functional tests complete$(NC)"

test-qtest: qemu
	@echo "$(YELLOW)🔬 Running QTest suite...$(NC)"
	@mkdir -p $(LOGDIR)
	@if [ -f "$(QEMUDIR)/build/tests/qtest/adin2111-test" ]; then \
		cd $(QEMUDIR)/build && \
		QTEST_QEMU_BINARY=$(QEMU) ./tests/qtest/adin2111-test | tee ../../$(LOGDIR)/qtest.log; \
	else \
		echo "$(BLUE)🔧 QTest for ADIN2111 not available, running basic connectivity test...$(NC)"; \
		./tests/qemu/qemu-ci-test.sh | tee $(LOGDIR)/qtest.log; \
	fi
	@echo "$(GREEN)✓ QTest complete$(NC)"

test-timing:
	@echo "$(YELLOW)⏱️ Running timing validation...$(NC)"
	@mkdir -p $(LOGDIR)
	@if [ ! -f "tests/timing/validate_timing.py" ]; then \
		echo "$(BLUE)🔧 Creating timing validation script...$(NC)"; \
		./scripts/create-timing-tests.sh; \
	fi
	@if command -v python3 >/dev/null 2>&1; then \
		python3 tests/timing/validate_timing.py | tee $(LOGDIR)/timing-test.log; \
	else \
		echo "$(BLUE)🔧 Python3 not available, using shell timing test...$(NC)"; \
		./tests/qemu/timing-validation.sh | tee $(LOGDIR)/timing-test.log; \
	fi
	@echo "$(GREEN)✓ Timing tests complete$(NC)"

report:
	@echo "$(YELLOW)📊 Generating test report...$(NC)"
	@mkdir -p $(LOGDIR)
	@if [ ! -f "scripts/generate-report.sh" ]; then \
		echo "$(BLUE)🔧 Creating report generation script...$(NC)"; \
		./scripts/create-report-script.sh; \
	fi
	@./scripts/generate-report.sh > $(LOGDIR)/test-report-$(shell date +%Y%m%d-%H%M%S).html
	@echo "$(GREEN)✓ Test report generated in $(LOGDIR)/$(NC)"

clean:
	@echo "$(YELLOW)🧹 Cleaning build artifacts...$(NC)"
	@if [ -d "$(KERNELDIR)" ]; then \
		cd $(KERNELDIR) && make ARCH=$(ARCH) clean; \
	fi
	@if [ -d "$(QEMUDIR)/build" ]; then \
		cd $(QEMUDIR)/build && ninja clean; \
	fi
	@rm -f $(DTB) $(LOGDIR)/*.log
	@echo "$(GREEN)✓ Clean complete$(NC)"

# CI/CD targets
ci-test: all
	@echo "$(YELLOW)🚀 Running CI/CD test pipeline...$(NC)"
	@if [ ! -f "scripts/ci-runner.sh" ]; then \
		echo "$(BLUE)🔧 Creating CI runner script...$(NC)"; \
		./scripts/create-ci-script.sh; \
	fi
	@./scripts/ci-runner.sh

docker-test:
	@echo "$(YELLOW)🐳 Running tests in Docker...$(NC)"
	@if [ ! -f "Dockerfile" ]; then \
		echo "$(BLUE)🔧 Creating Dockerfile...$(NC)"; \
		./scripts/create-dockerfile.sh; \
	fi
	@docker build -t adin2111-test .
	@docker run --rm -v $(PWD):/workspace adin2111-test make all

# Development targets
kernel-config:
	@echo "$(YELLOW)⚙️ Configuring kernel...$(NC)"
	@cd $(KERNELDIR) && \
	make ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) menuconfig

qemu-debug:
	@echo "$(YELLOW)🐛 Starting QEMU with GDB server...$(NC)"
	@$(QEMU) -M virt -cpu cortex-a15 -m 512M -nographic \
		-kernel $(ZIMAGE) -dtb $(DTB) \
		-s -S -monitor stdio

# Status and information targets
status:
	@echo "$(BLUE)📋 Build Status:$(NC)"
	@echo "  Kernel: $(if $(wildcard $(ZIMAGE)),$(GREEN)✓ Built$(NC),$(RED)✗ Not built$(NC))"
	@echo "  QEMU:   $(if $(wildcard $(QEMU)),$(GREEN)✓ Built$(NC),$(RED)✗ Not built$(NC))"
	@echo "  DTB:    $(if $(wildcard $(DTB)),$(GREEN)✓ Built$(NC),$(RED)✗ Not built$(NC))"
	@echo "  RootFS: $(if $(wildcard $(ROOTFS)),$(GREEN)✓ Ready$(NC),$(RED)✗ Not ready$(NC))"
	@echo "  ADIN2111: $(if $(shell grep -q 'CONFIG_ADIN2111=y' $(KERNELDIR)/.config 2>/dev/null && echo yes),$(GREEN)✓ Integrated$(NC),$(RED)✗ Not integrated$(NC))"
	@echo "  Cross-compiler: $(if $(shell command -v $(CROSS)gcc 2>/dev/null),$(GREEN)✓ Available$(NC),$(YELLOW)⚠ Install $(CROSS)gcc$(NC))"

help:
	@echo "$(BLUE)ADIN2111 Test Suite - Available Targets:$(NC)"
	@echo ""
	@echo "$(YELLOW)Main Targets:$(NC)"
	@echo "  all              - Build everything and run all tests"
	@echo "  deps             - Check build dependencies"
	@echo "  kernel           - Build Linux kernel with ADIN2111 driver"
	@echo "  qemu             - Build QEMU with ADIN2111 support"
	@echo "  dtb              - Compile device tree"
	@echo "  rootfs           - Prepare root filesystem"
	@echo ""
	@echo "$(YELLOW)Test Targets:$(NC)"
	@echo "  test-functional  - Run functional tests"
	@echo "  test-qtest       - Run QEMU unit tests"
	@echo "  test-timing      - Run timing validation"
	@echo "  report           - Generate test report"
	@echo ""
	@echo "$(YELLOW)Maintenance:$(NC)"
	@echo "  clean            - Clean build artifacts"
	@echo "  status           - Show build status"
	@echo "  help             - Show this help"
	@echo ""
	@echo "$(YELLOW)Development:$(NC)"
	@echo "  kernel-config    - Configure kernel (menuconfig)"
	@echo "  qemu-debug       - Start QEMU with GDB server"
	@echo ""
	@echo "$(YELLOW)CI/CD:$(NC)"
	@echo "  ci-test          - Run full CI/CD pipeline"
	@echo "  docker-test      - Run tests in Docker container"
	@echo ""
	@echo "$(BLUE)Environment Variables:$(NC)"
	@echo "  ARCH=$(ARCH)      - Target architecture"
	@echo "  CROSS=$(CROSS)    - Cross-compiler prefix"
	@echo "  JOBS=$(JOBS)      - Parallel build jobs"
	@echo "  KERNELDIR=$(KERNELDIR)  - Kernel source directory"
	@echo "  QEMUDIR=$(QEMUDIR)    - QEMU source directory"
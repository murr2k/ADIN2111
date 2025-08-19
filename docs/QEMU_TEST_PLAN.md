# ADIN2111 QEMU Testing Plan for CI/CD Pipeline

## Executive Summary

This document outlines the integration of QEMU-based testing for the ADIN2111 Linux driver into our CI/CD pipeline. The plan leverages our custom QEMU device model to provide comprehensive hardware emulation testing without physical devices.

## Objectives

1. **Automated Hardware Testing**: Test driver functionality in emulated hardware environment
2. **CI/CD Integration**: Seamless integration with GitHub Actions workflow
3. **Performance Validation**: Benchmark driver performance metrics in QEMU
4. **Regression Prevention**: Catch driver issues before deployment
5. **Cost Reduction**: Eliminate need for physical hardware in CI/CD

## Architecture Overview

```
┌──────────────────────────────────────────────┐
│           GitHub Actions Runner              │
├──────────────────────────────────────────────┤
│                                              │
│  ┌────────────────────────────────────────┐ │
│  │         Docker Container                │ │
│  ├────────────────────────────────────────┤ │
│  │                                        │ │
│  │  ┌──────────────┐  ┌────────────────┐ │ │
│  │  │ QEMU + Model │  │ Linux Kernel   │ │ │
│  │  │   ADIN2111   │  │ + ADIN2111     │ │ │
│  │  │              │  │   Driver       │ │ │
│  │  └──────────────┘  └────────────────┘ │ │
│  │                                        │ │
│  │  ┌────────────────────────────────┐   │ │
│  │  │    Test Harness & Scripts      │   │ │
│  │  └────────────────────────────────┘   │ │
│  └────────────────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

## Implementation Phases

### Phase 1: QEMU Build Infrastructure (Week 1)

**Goal**: Establish containerized QEMU build with ADIN2111 model

**Tasks**:
1. Create Dockerfile for QEMU build environment
2. Integrate ADIN2111 model into QEMU source
3. Build and cache QEMU binary with model
4. Validate model functionality

**Deliverables**:
- `docker/qemu-adin2111.dockerfile`
- Docker image: `ghcr.io/murr2k/qemu-adin2111:latest`
- Build workflow: `.github/workflows/build-qemu.yml`

### Phase 2: Kernel Test Environment (Week 1-2)

**Goal**: Create minimal Linux environment for driver testing

**Tasks**:
1. Configure minimal kernel with ADIN2111 driver
2. Create initramfs with test utilities
3. Build device tree for QEMU virt machine
4. Package test environment

**Deliverables**:
- Kernel configuration: `configs/qemu_test_defconfig`
- Test initramfs: `tests/qemu/initramfs.cpio.gz`
- Device tree: `tests/qemu/adin2111-test.dts`

### Phase 3: Test Suite Development (Week 2)

**Goal**: Comprehensive automated test suite

**Test Categories**:

#### 3.1 Basic Functionality Tests
- Driver probe and initialization
- SPI communication verification
- Register read/write operations
- Interrupt handling

#### 3.2 Network Tests
- Interface creation and configuration
- Packet transmission and reception
- Switch mode operation
- MAC filtering

#### 3.3 Stress Tests
- High traffic load
- Rapid configuration changes
- Error injection and recovery
- Memory leak detection

#### 3.4 Performance Tests
- Throughput measurement
- Latency profiling
- CPU usage monitoring
- Switch forwarding performance

**Deliverables**:
- Test scripts: `tests/qemu/functional/`
- Performance benchmarks: `tests/qemu/performance/`
- Test runner: `tests/qemu/run-tests.sh`

### Phase 4: CI/CD Integration (Week 3)

**Goal**: Seamless GitHub Actions integration

**Workflow Structure**:
```yaml
name: QEMU Hardware Testing

on:
  push:
    paths:
      - 'drivers/**'
      - 'qemu/**'
  pull_request:
  workflow_dispatch:

jobs:
  qemu-test:
    runs-on: ubuntu-latest
    container: ghcr.io/murr2k/qemu-adin2111:latest
    steps:
      - checkout
      - build-kernel
      - run-qemu-tests
      - upload-results
```

**Features**:
- Parallel test execution
- Result aggregation
- Performance trend tracking
- Failure notifications

**Deliverables**:
- Workflow: `.github/workflows/qemu-test.yml`
- Test matrix configuration
- Result visualization

### Phase 5: Performance Benchmarking (Week 3-4)

**Goal**: Establish performance baselines and regression detection

**Metrics**:
- Packet throughput (Mbps)
- Switching latency (μs)
- CPU utilization (%)
- Memory usage (MB)
- Interrupt rate (IRQ/s)

**Tools**:
- iperf3 for throughput
- pktgen for packet generation
- perf for profiling
- Custom latency measurement

**Deliverables**:
- Benchmark suite: `tests/qemu/benchmarks/`
- Performance dashboard
- Regression detection scripts

### Phase 6: Advanced Testing (Week 4-5)

**Goal**: Edge cases and advanced scenarios

**Test Scenarios**:
1. **Power Management**
   - Suspend/resume cycles
   - Runtime PM testing
   - Wake-on-LAN

2. **Error Conditions**
   - SPI communication errors
   - Memory allocation failures
   - Interrupt storms

3. **Configuration Testing**
   - Module parameters
   - Device tree variations
   - Multiple device instances

4. **Integration Testing**
   - Network stack integration
   - ethtool operations
   - Network namespaces

**Deliverables**:
- Advanced test suite
- Error injection framework
- Configuration matrix

## Technical Implementation Details

### Docker Container Structure

```dockerfile
FROM ubuntu:22.04 AS qemu-builder

# Build dependencies
RUN apt-get update && apt-get install -y \
    build-essential ninja-build pkg-config \
    libglib2.0-dev libpixman-1-dev python3

# Build QEMU with ADIN2111
COPY qemu/ /qemu-source/
RUN cd /qemu-source && \
    ./configure --target-list=arm-softmmu,aarch64-softmmu && \
    make -j$(nproc)

FROM ubuntu:22.04
# Runtime environment
COPY --from=qemu-builder /qemu-source/build/qemu-system-* /usr/local/bin/
```

### Test Execution Framework

```bash
#!/bin/bash
# tests/qemu/run-tests.sh

run_qemu_test() {
    local test_name=$1
    local timeout=${2:-60}
    
    qemu-system-arm \
        -M virt \
        -kernel $KERNEL \
        -initrd $INITRD \
        -device adin2111,id=eth0 \
        -append "console=ttyAMA0 test=$test_name" \
        -nographic \
        -monitor none \
        -serial stdio \
        -timeout $timeout
}

# Execute test suite
for test in tests/qemu/functional/*.sh; do
    run_qemu_test $(basename $test .sh)
done
```

### GitHub Actions Workflow

```yaml
name: QEMU Hardware Tests

on: [push, pull_request]

jobs:
  build-qemu:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Build QEMU Container
        run: |
          docker build -f docker/qemu-adin2111.dockerfile \
            -t ghcr.io/murr2k/qemu-adin2111:${{ github.sha }} .
      
      - name: Push Container
        if: github.ref == 'refs/heads/main'
        run: |
          docker push ghcr.io/murr2k/qemu-adin2111:${{ github.sha }}

  test-driver:
    needs: build-qemu
    runs-on: ubuntu-latest
    container: ghcr.io/murr2k/qemu-adin2111:${{ github.sha }}
    
    strategy:
      matrix:
        kernel: [5.15, 6.1, 6.6, 6.8]
        test-suite: [functional, performance, stress]
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Build Kernel
        run: |
          make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- \
            qemu_test_defconfig
          make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc)
      
      - name: Run Tests
        run: |
          ./tests/qemu/run-tests.sh --suite ${{ matrix.test-suite }}
      
      - name: Upload Results
        uses: actions/upload-artifact@v3
        with:
          name: test-results-${{ matrix.kernel }}-${{ matrix.test-suite }}
          path: test-results/
```

## Success Criteria

### Functional Requirements
- [ ] 100% driver probe success rate in QEMU
- [ ] All register operations verified
- [ ] Network traffic forwarding functional
- [ ] Interrupt handling validated

### Performance Requirements
- [ ] Throughput: ≥8 Mbps (80% of 10BASE-T1L)
- [ ] Latency: <100μs port-to-port
- [ ] CPU usage: <5% idle, <50% under load
- [ ] Memory: <10MB driver footprint

### CI/CD Requirements
- [ ] Test execution time: <10 minutes
- [ ] Parallel execution support
- [ ] Automatic regression detection
- [ ] Result visualization

## Risk Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| QEMU timing inaccuracy | False test failures | Implement timing tolerance in tests |
| Container size | Slow CI/CD | Multi-stage builds, layer caching |
| Test flakiness | False positives | Retry logic, increased timeouts |
| Performance variance | Inconsistent benchmarks | Multiple runs, statistical analysis |

## Maintenance Plan

### Weekly Tasks
- Review test results and failures
- Update test suite for new features
- Performance trend analysis

### Monthly Tasks
- QEMU and kernel version updates
- Container image optimization
- Test coverage analysis

### Quarterly Tasks
- Performance baseline updates
- Test infrastructure review
- Documentation updates

## Timeline

| Week | Phase | Deliverables |
|------|-------|--------------|
| 1 | QEMU Build | Docker container, QEMU binary |
| 1-2 | Kernel Environment | Test kernel, initramfs |
| 2 | Test Suite | Functional tests |
| 3 | CI/CD Integration | GitHub Actions workflow |
| 3-4 | Performance | Benchmark suite |
| 4-5 | Advanced Testing | Edge case coverage |

## Conclusion

This comprehensive QEMU testing plan provides:
- Automated hardware-level testing without physical devices
- Continuous validation of driver functionality
- Performance regression detection
- Scalable CI/CD integration

The implementation will significantly improve driver quality while reducing testing costs and time-to-market.
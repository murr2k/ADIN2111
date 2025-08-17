# ADIN2111 Test Environment Strategy

## Overview

This document outlines the strategy for implementing environment-aware testing with proper mocking to resolve false positives and improve test reliability.

## Test Environment Categories

### 1. Hardware Environments

#### Real Hardware (Production)
- **Target:** Actual ADIN2111 hardware on target platform
- **Capabilities:** Full hardware validation, real SPI communication, actual network traffic
- **Tests:** All tests run with real hardware interaction
- **Validation:** Complete end-to-end functionality

#### Development Hardware (Dev Board)
- **Target:** ADIN2111 evaluation board
- **Capabilities:** Full hardware validation with development tools
- **Tests:** All tests with additional debug instrumentation
- **Validation:** Development and debugging focused

### 2. Software Environments

#### CI/CD Environment (Mock)
- **Target:** Automated testing without hardware
- **Capabilities:** Unit testing, integration testing with mocks
- **Tests:** Logic validation, error handling, state management
- **Validation:** Code quality and behavior verification

#### Local Development (Hybrid)
- **Target:** Developer workstation with optional hardware
- **Capabilities:** Unit testing + optional hardware testing
- **Tests:** Development workflow testing
- **Validation:** Quick feedback and validation

## Environment Detection Strategy

### Environment Detection Logic

```c
enum test_environment {
    TEST_ENV_HARDWARE_PRODUCTION,    // Real hardware, production use
    TEST_ENV_HARDWARE_DEVELOPMENT,   // Dev board with debug capabilities  
    TEST_ENV_SOFTWARE_CI,            // CI/CD without hardware
    TEST_ENV_SOFTWARE_LOCAL          // Local development
};

struct test_environment_capabilities {
    bool has_real_hardware;          // Actual ADIN2111 present
    bool has_spi_bus;               // SPI bus available
    bool has_network_interfaces;    // Network interfaces available
    bool has_debug_tools;           // Debug/monitoring tools available
    bool can_inject_errors;         // Error injection capabilities
    bool is_automated;              // Running in automation
};
```

### Detection Methods

1. **Hardware Detection**
   - Check for ADIN2111 device in /sys/bus/spi/devices/
   - Validate SPI communication
   - Verify network interface presence

2. **Environment Detection**
   - Check for CI environment variables
   - Detect debug tool availability
   - Validate required dependencies

3. **Capability Assessment**
   - Test SPI bus accessibility
   - Check network stack availability
   - Validate performance measurement tools

## Mocking Strategy by Test Category

### 1. Hardware Interface Tests

#### Tests That MUST Be Mocked in No-Hardware Environment:
- **SPI Communication Tests**
  - Mock SPI register reads/writes
  - Simulate device responses
  - Test error conditions

- **Hardware Reset Tests**
  - Mock GPIO operations
  - Simulate reset sequences
  - Test timeout handling

- **PHY Management Tests**
  - Mock MDIO operations
  - Simulate PHY state changes
  - Test link status detection

#### Implementation Approach:
```c
// Hardware abstraction layer for testing
struct adin2111_hw_ops {
    int (*spi_read)(u32 reg, u32 *val);
    int (*spi_write)(u32 reg, u32 val);
    int (*reset_assert)(void);
    int (*reset_deassert)(void);
};

// Real hardware implementation
extern struct adin2111_hw_ops adin2111_hw_ops_real;

// Mock implementation for testing
extern struct adin2111_hw_ops adin2111_hw_ops_mock;
```

### 2. Network Stack Tests

#### Tests That Can Use Real Network Stack:
- **Interface Registration**
  - Use real netdev operations
  - Test with dummy network interfaces
  - Validate kernel integration

- **Packet Processing Logic**
  - Use real skb structures
  - Test with loopback interfaces
  - Validate protocol handling

#### Tests That MUST Be Mocked:
- **Hardware Packet Transmission**
  - Mock actual hardware TX
  - Simulate transmission completion
  - Test error scenarios

- **Hardware Packet Reception**  
  - Mock hardware RX interrupts
  - Simulate packet arrival
  - Test buffer management

### 3. Performance Tests

#### Tests That MUST Be Mocked:
- **Throughput Measurement**
  - Mock packet transmission timing
  - Simulate realistic performance data
  - Test performance degradation detection

- **Latency Measurement**
  - Mock timestamp capture
  - Simulate latency variations
  - Test latency threshold detection

- **SPI Bus Utilization**
  - Mock SPI transaction monitoring
  - Simulate bus congestion
  - Test optimization effectiveness

#### Implementation Strategy:
```c
struct perf_measurement_ops {
    u64 (*get_timestamp)(void);
    void (*start_measurement)(const char *name);
    void (*end_measurement)(const char *name);
    u64 (*get_throughput)(void);
    u32 (*get_latency_us)(void);
};
```

### 4. Stress Tests

#### Tests That Can Run in Any Environment:
- **Memory Management**
  - Use real kernel memory allocation
  - Test actual leak detection
  - Validate cleanup procedures

- **Concurrent Operations**
  - Use real kernel locking
  - Test actual race conditions
  - Validate synchronization

#### Tests That Need Environment Adaptation:
- **Link Flapping**
  - Real hardware: Actual link changes
  - Mock: Simulate link events
  - Test: State machine robustness

- **High Traffic Load**
  - Real hardware: Actual network load
  - Mock: Simulated packet bursts
  - Test: Buffer management and flow control

## Test Implementation Framework

### Environment-Aware Test Structure

```c
struct test_context {
    enum test_environment env_type;
    struct test_environment_capabilities caps;
    struct adin2111_hw_ops *hw_ops;
    struct perf_measurement_ops *perf_ops;
    bool mock_mode;
};

// Test function signature
typedef int (*test_func_t)(struct test_context *ctx);

// Test descriptor
struct test_descriptor {
    const char *name;
    test_func_t func;
    u32 required_caps;      // Bitmask of required capabilities
    u32 mock_fallback;      // Whether mock version exists
    u32 critical_level;     // How critical is real hardware
};
```

### Test Execution Logic

```c
int run_test_with_environment_awareness(struct test_descriptor *test, 
                                       struct test_context *ctx)
{
    // Check if test can run in current environment
    if ((test->required_caps & ctx->caps) != test->required_caps) {
        if (test->mock_fallback && !ctx->caps.has_real_hardware) {
            // Run with mocks
            ctx->mock_mode = true;
            log_info("Running %s with mocks", test->name);
        } else {
            // Skip test with clear reason
            log_warn("Skipping %s - insufficient capabilities", test->name);
            return TEST_RESULT_SKIP;
        }
    }
    
    return test->func(ctx);
}
```

## Mock Implementation Details

### 1. SPI Mock Implementation

```c
// Mock SPI state
struct spi_mock_state {
    u32 registers[0x2000];     // Mock register space
    bool error_injection;       // Error simulation
    u32 error_rate;            // Error frequency
    u64 transaction_count;      // Statistics
};

int spi_mock_read(u32 reg, u32 *val) {
    struct spi_mock_state *mock = get_spi_mock();
    
    // Simulate errors if enabled
    if (mock->error_injection && should_inject_error(mock->error_rate)) {
        return -EIO;
    }
    
    *val = mock->registers[reg];
    mock->transaction_count++;
    return 0;
}
```

### 2. Network Performance Mock

```c
struct network_perf_mock {
    u64 simulated_throughput_bps;
    u32 simulated_latency_us;
    u32 packet_loss_rate;
    bool degradation_mode;
};

u64 mock_measure_throughput(void) {
    struct network_perf_mock *mock = get_perf_mock();
    
    if (mock->degradation_mode) {
        return mock->simulated_throughput_bps / 2;  // Simulate degradation
    }
    
    return mock->simulated_throughput_bps;
}
```

### 3. Hardware State Mock

```c
struct hardware_state_mock {
    bool link_up;
    u32 link_speed;
    bool switch_mode;
    u32 port_status[2];
    u64 packet_counts[2];
};

bool mock_get_link_status(int port) {
    struct hardware_state_mock *mock = get_hw_mock();
    return mock->link_up;
}
```

## Testing Best Practices Implementation

### 1. Intentional Skipping vs Default Skipping

**Before (Default Skip):**
```bash
if ! command -v ethtool &> /dev/null; then
    test_result "link_status" "SKIP" "- ethtool not available"
    return 0
fi
```

**After (Environment Aware):**
```bash
check_test_environment() {
    local required_tools=("ethtool" "ip" "bridge")
    local missing_tools=()
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        if [[ "$TEST_ENVIRONMENT" == "CI" ]]; then
            log_error "Missing required tools in CI: ${missing_tools[*]}"
            exit 1  # Fail CI if tools missing
        else
            log_warn "Missing tools: ${missing_tools[*]} - using mocks"
            export USE_NETWORK_MOCKS=1
        fi
    fi
}
```

### 2. Proper Error Injection

```c
// Test error conditions explicitly
int test_spi_error_handling(struct test_context *ctx) {
    int ret;
    
    if (ctx->mock_mode) {
        // Enable error injection in mock
        enable_spi_error_injection(ctx->hw_ops, 50); // 50% error rate
    }
    
    // Test that driver handles SPI errors correctly
    ret = adin2111_read_reg(ctx->priv, ADIN2111_STATUS0, &val);
    if (ret != -EIO) {
        return TEST_FAIL; // Should have failed
    }
    
    // Test recovery mechanism
    ret = adin2111_recover_from_spi_error(ctx->priv);
    if (ret != 0) {
        return TEST_FAIL;
    }
    
    return TEST_PASS;
}
```

### 3. Environment-Specific Test Variants

```c
// Hardware-specific test
int test_hardware_switching_real(struct test_context *ctx) {
    // Send real packets between ports
    // Monitor actual SPI traffic
    // Verify hardware forwarding
}

// Mock-based test  
int test_hardware_switching_mock(struct test_context *ctx) {
    // Simulate packet injection
    // Mock SPI monitoring 
    // Verify logical forwarding behavior
}

// Combined test descriptor
struct test_descriptor hardware_switching_test = {
    .name = "hardware_switching",
    .func_real = test_hardware_switching_real,
    .func_mock = test_hardware_switching_mock,
    .required_caps = CAP_REAL_HARDWARE | CAP_SPI_BUS,
    .mock_fallback = true,
    .critical_level = TEST_CRITICAL_HIGH
};
```

## Implementation Priority

### Phase 1: Infrastructure
1. Environment detection framework
2. Mock interface definitions
3. Test execution framework

### Phase 2: Critical Test Fixes
1. SPI communication tests with mocking
2. Network interface tests with proper validation
3. Performance tests with realistic mocking

### Phase 3: Advanced Features
1. Error injection framework
2. Hardware-in-loop test support
3. Comprehensive test coverage metrics

This strategy ensures that tests provide real validation while being executable in any environment, eliminating false positives through proper mocking rather than hardcoded success paths.
// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Test Environment Framework Implementation
 * Environment detection and mock infrastructure
 *
 * Copyright 2025 Analog Devices Inc.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/spi/spi.h>
#include <linux/fs.h>
#include <linux/proc_fs.h>
#include <linux/ktime.h>
#include <linux/random.h>
#include <linux/delay.h>

#include "test_environment.h"

/* Mock state structures */
struct spi_mock_state {
    u32 registers[0x2000];         /* Mock register space */
    bool error_injection;           /* Error simulation enabled */
    u32 error_rate;                /* Error frequency (0-100%) */
    u64 transaction_count;          /* Transaction statistics */
    char last_error[64];           /* Last error type */
    struct mutex lock;              /* Protect mock state */
};

struct network_perf_mock {
    u64 simulated_throughput_bps;   /* Simulated throughput */
    u32 simulated_latency_us;       /* Simulated latency */
    u32 packet_loss_rate;           /* Packet loss percentage */
    bool degradation_mode;          /* Performance degradation simulation */
    ktime_t measurement_start;      /* Measurement timing */
    u64 packet_count;               /* Packet counter */
};

struct hardware_state_mock {
    bool link_up[2];                /* Link status per port */
    u32 link_speed[2];             /* Link speed per port */
    bool switch_mode;               /* Switch vs dual mode */
    u32 port_status[2];            /* Port status flags */
    u64 tx_packets[2];             /* TX packet counts */
    u64 rx_packets[2];             /* RX packet counts */
    u64 tx_errors[2];              /* TX error counts */
    u64 rx_errors[2];              /* RX error counts */
};

/* Global mock state */
static struct spi_mock_state g_spi_mock;
static struct network_perf_mock g_perf_mock;
static struct hardware_state_mock g_hw_mock;

/* Environment detection implementation */
int test_environment_detect(struct test_context *ctx)
{
    struct test_environment_capabilities *caps = &ctx->caps;
    
    /* Initialize capabilities */
    memset(caps, 0, sizeof(*caps));
    
    /* Check for CI environment */
    if (getenv("CI") || getenv("GITHUB_ACTIONS") || getenv("BUILD_ID")) {
        ctx->env_type = TEST_ENV_SOFTWARE_CI;
        caps->is_automated = true;
        caps->flags |= TEST_CAP_AUTOMATED;
        strncpy(caps->environment_info, "CI/CD Environment", 
                sizeof(caps->environment_info) - 1);
    } else {
        ctx->env_type = TEST_ENV_SOFTWARE_LOCAL;
        strncpy(caps->environment_info, "Local Development", 
                sizeof(caps->environment_info) - 1);
    }
    
    /* Check for real hardware by looking for ADIN2111 devices */
    if (test_detect_adin2111_hardware(caps)) {
        if (ctx->env_type == TEST_ENV_SOFTWARE_LOCAL) {
            ctx->env_type = TEST_ENV_HARDWARE_DEVELOPMENT;
        } else {
            ctx->env_type = TEST_ENV_HARDWARE_PRODUCTION;
        }
        caps->has_real_hardware = true;
        caps->flags |= TEST_CAP_REAL_HARDWARE;
    }
    
    /* Check for SPI bus availability */
    if (test_detect_spi_bus()) {
        caps->has_spi_bus = true;
        caps->flags |= TEST_CAP_SPI_BUS;
    }
    
    /* Check for network interfaces */
    if (test_detect_network_interfaces()) {
        caps->has_network_interfaces = true;
        caps->flags |= TEST_CAP_NETWORK_INTERFACES;
    }
    
    /* Check for debug tools */
    if (test_detect_debug_tools()) {
        caps->has_debug_tools = true;
        caps->flags |= TEST_CAP_DEBUG_TOOLS;
    }
    
    /* Error injection is always available in software */
    caps->can_inject_errors = true;
    caps->flags |= TEST_CAP_ERROR_INJECTION;
    
    /* Performance tools detection */
    if (test_detect_performance_tools()) {
        caps->has_performance_tools = true;
        caps->flags |= TEST_CAP_PERFORMANCE_TOOLS;
    }
    
    /* Select appropriate hardware and performance operations */
    if (caps->has_real_hardware) {
        ctx->hw_ops = &adin2111_hw_ops_real;
        ctx->perf_ops = &perf_ops_real;
        ctx->mock_mode = false;
    } else {
        ctx->hw_ops = &adin2111_hw_ops_mock;
        ctx->perf_ops = &perf_ops_mock;
        ctx->mock_mode = true;
        
        /* Initialize mock state */
        test_init_mock_state();
    }
    
    return 0;
}

/* Hardware detection helper */
static bool test_detect_adin2111_hardware(struct test_environment_capabilities *caps)
{
    struct file *file;
    char path[256];
    bool found = false;
    
    /* Check common SPI device paths */
    const char *spi_paths[] = {
        "/sys/bus/spi/devices/spi0.0",
        "/sys/bus/spi/devices/spi1.0", 
        "/sys/bus/spi/devices/spi2.0",
        NULL
    };
    
    for (int i = 0; spi_paths[i]; i++) {
        snprintf(path, sizeof(path), "%s/modalias", spi_paths[i]);
        file = filp_open(path, O_RDONLY, 0);
        if (!IS_ERR(file)) {
            char modalias[64];
            loff_t pos = 0;
            
            if (kernel_read(file, modalias, sizeof(modalias) - 1, &pos) > 0) {
                modalias[pos] = '\0';
                if (strstr(modalias, "adin2111")) {
                    strncpy(caps->hardware_version, modalias, 
                           sizeof(caps->hardware_version) - 1);
                    found = true;
                }
            }
            filp_close(file, NULL);
            
            if (found) break;
        }
    }
    
    return found;
}

/* SPI Mock Implementation */
static int spi_mock_read(void *context, u32 reg, u32 *val)
{
    struct spi_mock_state *mock = &g_spi_mock;
    
    mutex_lock(&mock->lock);
    
    /* Simulate error injection */
    if (mock->error_injection && should_inject_error(mock->error_rate)) {
        strncpy(mock->last_error, "SPI_READ_ERROR", sizeof(mock->last_error) - 1);
        mutex_unlock(&mock->lock);
        return -EIO;
    }
    
    /* Return mock register value */
    if (reg < ARRAY_SIZE(mock->registers)) {
        *val = mock->registers[reg];
    } else {
        *val = 0xDEADBEEF; /* Invalid register marker */
    }
    
    mock->transaction_count++;
    mutex_unlock(&mock->lock);
    
    return 0;
}

static int spi_mock_write(void *context, u32 reg, u32 val)
{
    struct spi_mock_state *mock = &g_spi_mock;
    
    mutex_lock(&mock->lock);
    
    /* Simulate error injection */
    if (mock->error_injection && should_inject_error(mock->error_rate)) {
        strncpy(mock->last_error, "SPI_WRITE_ERROR", sizeof(mock->last_error) - 1);
        mutex_unlock(&mock->lock);
        return -EIO;
    }
    
    /* Store mock register value */
    if (reg < ARRAY_SIZE(mock->registers)) {
        mock->registers[reg] = val;
    }
    
    mock->transaction_count++;
    mutex_unlock(&mock->lock);
    
    return 0;
}

static int spi_mock_reset_assert(void *context)
{
    struct spi_mock_state *mock = &g_spi_mock;
    
    /* Simulate reset by clearing certain registers */
    mutex_lock(&mock->lock);
    memset(mock->registers, 0, sizeof(u32) * 0x100); /* Clear first 256 registers */
    mutex_unlock(&mock->lock);
    
    return 0;
}

static int spi_mock_reset_deassert(void *context)
{
    struct spi_mock_state *mock = &g_spi_mock;
    
    /* Simulate post-reset register initialization */
    mutex_lock(&mock->lock);
    mock->registers[0x00] = 0x0283; /* Mock chip ID */
    mock->registers[0x01] = 0x0001; /* Mock status */
    mutex_unlock(&mock->lock);
    
    return 0;
}

static int hw_mock_get_link_status(void *context, int port, bool *up)
{
    struct hardware_state_mock *mock = &g_hw_mock;
    
    if (port < 0 || port >= 2) {
        return -EINVAL;
    }
    
    *up = mock->link_up[port];
    return 0;
}

static int hw_mock_get_statistics(void *context, int port, u64 *tx_packets, u64 *rx_packets)
{
    struct hardware_state_mock *mock = &g_hw_mock;
    
    if (port < 0 || port >= 2) {
        return -EINVAL;
    }
    
    *tx_packets = mock->tx_packets[port];
    *rx_packets = mock->rx_packets[port];
    
    /* Simulate some traffic */
    mock->tx_packets[port] += get_random_u32_below(100);
    mock->rx_packets[port] += get_random_u32_below(100);
    
    return 0;
}

static void hw_mock_inject_error(void *context, const char *error_type)
{
    struct spi_mock_state *spi_mock = &g_spi_mock;
    struct hardware_state_mock *hw_mock = &g_hw_mock;
    
    if (strcmp(error_type, "spi_error") == 0) {
        spi_mock->error_injection = true;
        spi_mock->error_rate = 50; /* 50% error rate */
    } else if (strcmp(error_type, "link_down") == 0) {
        hw_mock->link_up[0] = false;
        hw_mock->link_up[1] = false;
    } else if (strcmp(error_type, "packet_loss") == 0) {
        g_perf_mock.packet_loss_rate = 10; /* 10% packet loss */
    }
}

/* Performance Mock Implementation */
static u64 perf_mock_get_timestamp(void)
{
    return ktime_get_ns();
}

static void perf_mock_start_measurement(const char *name)
{
    g_perf_mock.measurement_start = ktime_get();
    g_perf_mock.packet_count = 0;
}

static void perf_mock_end_measurement(const char *name)
{
    /* Measurement ended - data available via other functions */
}

static u64 perf_mock_get_throughput_bps(void)
{
    struct network_perf_mock *mock = &g_perf_mock;
    
    if (mock->degradation_mode) {
        return mock->simulated_throughput_bps / 2;
    }
    
    /* Add some realistic variance */
    u64 variance = get_random_u32_below(mock->simulated_throughput_bps / 10);
    return mock->simulated_throughput_bps + variance - (variance / 2);
}

static u32 perf_mock_get_latency_us(void)
{
    struct network_perf_mock *mock = &g_perf_mock;
    
    /* Add realistic latency jitter */
    u32 jitter = get_random_u32_below(mock->simulated_latency_us / 4);
    return mock->simulated_latency_us + jitter;
}

static u32 perf_mock_get_cpu_usage_percent(void)
{
    /* Simulate realistic CPU usage between 5-25% */
    return 5 + get_random_u32_below(20);
}

static u64 perf_mock_get_spi_transaction_count(void)
{
    return g_spi_mock.transaction_count;
}

/* Hardware operations structures */
struct adin2111_hw_ops adin2111_hw_ops_mock = {
    .name = "mock",
    .spi_read = spi_mock_read,
    .spi_write = spi_mock_write,
    .reset_assert = spi_mock_reset_assert,
    .reset_deassert = spi_mock_reset_deassert,
    .get_link_status = hw_mock_get_link_status,
    .get_statistics = hw_mock_get_statistics,
    .inject_error = hw_mock_inject_error,
};

struct perf_measurement_ops perf_ops_mock = {
    .name = "mock",
    .get_timestamp = perf_mock_get_timestamp,
    .start_measurement = perf_mock_start_measurement,
    .end_measurement = perf_mock_end_measurement,
    .get_throughput_bps = perf_mock_get_throughput_bps,
    .get_latency_us = perf_mock_get_latency_us,
    .get_cpu_usage_percent = perf_mock_get_cpu_usage_percent,
    .get_spi_transaction_count = perf_mock_get_spi_transaction_count,
};

/* Test execution framework */
int run_test_with_environment_awareness(struct test_descriptor *test, 
                                       struct test_context *ctx)
{
    int result;
    test_func_t test_func;
    
    /* Validate test can run in current environment */
    if ((test->required_caps & ctx->caps.flags) != test->required_caps) {
        if (test->func_mock && !ctx->caps.has_real_hardware) {
            /* Use mock implementation */
            test_func = test->func_mock;
            ctx->mock_mode = true;
            pr_info("Running %s with mocks", test->name);
        } else if (test->criticality <= TEST_CRITICAL_MEDIUM) {
            /* Skip non-critical test */
            pr_warn("Skipping %s - insufficient capabilities", test->name);
            return TEST_RESULT_SKIP;
        } else {
            /* Fail critical test */
            pr_err("Cannot run critical test %s - insufficient capabilities", test->name);
            return TEST_RESULT_ERROR;
        }
    } else {
        /* Use real implementation */
        test_func = test->func_real;
        ctx->mock_mode = false;
    }
    
    /* Execute the test */
    pr_info("Executing test: %s (%s mode)", test->name, 
            ctx->mock_mode ? "mock" : "real");
    
    result = test_func(ctx);
    
    pr_info("Test %s completed with result: %s", test->name,
            result == TEST_RESULT_PASS ? "PASS" :
            result == TEST_RESULT_FAIL ? "FAIL" :
            result == TEST_RESULT_SKIP ? "SKIP" : "ERROR");
    
    return result;
}

/* Mock control functions */
void mock_enable_error_injection(struct test_context *ctx, const char *error_type, u32 rate)
{
    if (ctx->mock_mode && ctx->hw_ops->inject_error) {
        ctx->hw_ops->inject_error(ctx->hw_ops->private_data, error_type);
        g_spi_mock.error_rate = min(rate, 100U);
        ctx->error_injection_enabled = true;
    }
}

void mock_disable_error_injection(struct test_context *ctx)
{
    if (ctx->mock_mode) {
        g_spi_mock.error_injection = false;
        g_spi_mock.error_rate = 0;
        ctx->error_injection_enabled = false;
    }
}

void mock_set_performance_params(struct test_context *ctx, u64 throughput, u32 latency)
{
    if (ctx->mock_mode) {
        g_perf_mock.simulated_throughput_bps = throughput;
        g_perf_mock.simulated_latency_us = latency;
    }
}

void mock_set_hardware_state(struct test_context *ctx, bool link_up, u32 speed)
{
    if (ctx->mock_mode) {
        g_hw_mock.link_up[0] = link_up;
        g_hw_mock.link_up[1] = link_up;
        g_hw_mock.link_speed[0] = speed;
        g_hw_mock.link_speed[1] = speed;
    }
}

/* Utility functions */
static bool should_inject_error(u32 error_rate)
{
    return get_random_u32_below(100) < error_rate;
}

static void test_init_mock_state(void)
{
    /* Initialize SPI mock */
    memset(&g_spi_mock, 0, sizeof(g_spi_mock));
    mutex_init(&g_spi_mock.lock);
    
    /* Initialize performance mock with realistic defaults */
    g_perf_mock.simulated_throughput_bps = 100000000; /* 100 Mbps */
    g_perf_mock.simulated_latency_us = 100;           /* 100 μs */
    g_perf_mock.packet_loss_rate = 0;
    g_perf_mock.degradation_mode = false;
    
    /* Initialize hardware mock with reasonable defaults */
    g_hw_mock.link_up[0] = true;
    g_hw_mock.link_up[1] = true;
    g_hw_mock.link_speed[0] = 100; /* 100 Mbps */
    g_hw_mock.link_speed[1] = 100;
    g_hw_mock.switch_mode = true;
}

/* Context management */
void test_context_init(struct test_context *ctx)
{
    memset(ctx, 0, sizeof(*ctx));
    test_environment_detect(ctx);
}

void test_context_cleanup(struct test_context *ctx)
{
    mock_disable_error_injection(ctx);
    memset(ctx, 0, sizeof(*ctx));
}

const char *test_environment_name(enum test_environment env)
{
    switch (env) {
    case TEST_ENV_HARDWARE_PRODUCTION:
        return "Hardware Production";
    case TEST_ENV_HARDWARE_DEVELOPMENT:
        return "Hardware Development";
    case TEST_ENV_SOFTWARE_CI:
        return "Software CI/CD";
    case TEST_ENV_SOFTWARE_LOCAL:
        return "Software Local";
    default:
        return "Unknown";
    }
}

void test_environment_print_info(struct test_context *ctx)
{
    pr_info("Test Environment: %s", test_environment_name(ctx->env_type));
    pr_info("Capabilities: 0x%08x", ctx->caps.flags);
    pr_info("Hardware Operations: %s", ctx->hw_ops->name);
    pr_info("Performance Operations: %s", ctx->perf_ops->name);
    pr_info("Mock Mode: %s", ctx->mock_mode ? "enabled" : "disabled");
    
    if (strlen(ctx->caps.hardware_version) > 0) {
        pr_info("Hardware Version: %s", ctx->caps.hardware_version);
    }
    
    pr_info("Environment Info: %s", ctx->caps.environment_info);
}
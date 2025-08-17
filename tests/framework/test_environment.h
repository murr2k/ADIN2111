/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * ADIN2111 Test Environment Framework
 * Environment detection and mock infrastructure for comprehensive testing
 *
 * Copyright 2025 Analog Devices Inc.
 */

#ifndef _ADIN2111_TEST_ENVIRONMENT_H_
#define _ADIN2111_TEST_ENVIRONMENT_H_

#include <linux/types.h>
#include <linux/device.h>
#include <linux/netdevice.h>

/* Test environment types */
enum test_environment {
    TEST_ENV_HARDWARE_PRODUCTION,    /* Real hardware, production use */
    TEST_ENV_HARDWARE_DEVELOPMENT,   /* Dev board with debug capabilities */
    TEST_ENV_SOFTWARE_CI,            /* CI/CD without hardware */
    TEST_ENV_SOFTWARE_LOCAL          /* Local development */
};

/* Environment capability flags */
#define TEST_CAP_REAL_HARDWARE      BIT(0)  /* Actual ADIN2111 present */
#define TEST_CAP_SPI_BUS           BIT(1)  /* SPI bus available */
#define TEST_CAP_NETWORK_INTERFACES BIT(2)  /* Network interfaces available */
#define TEST_CAP_DEBUG_TOOLS       BIT(3)  /* Debug/monitoring tools available */
#define TEST_CAP_ERROR_INJECTION   BIT(4)  /* Error injection capabilities */
#define TEST_CAP_PERFORMANCE_TOOLS BIT(5)  /* Performance measurement tools */
#define TEST_CAP_AUTOMATED         BIT(6)  /* Running in automation */

/* Test environment capabilities */
struct test_environment_capabilities {
    u32 flags;                       /* Capability flags */
    bool has_real_hardware;          /* Actual ADIN2111 present */
    bool has_spi_bus;               /* SPI bus available */
    bool has_network_interfaces;    /* Network interfaces available */
    bool has_debug_tools;           /* Debug/monitoring tools available */
    bool can_inject_errors;         /* Error injection capabilities */
    bool has_performance_tools;     /* Performance measurement available */
    bool is_automated;              /* Running in automation */
    char hardware_version[32];      /* Hardware version if available */
    char environment_info[128];     /* Additional environment info */
};

/* Hardware abstraction layer for testing */
struct adin2111_hw_ops {
    const char *name;
    int (*spi_read)(void *context, u32 reg, u32 *val);
    int (*spi_write)(void *context, u32 reg, u32 val);
    int (*reset_assert)(void *context);
    int (*reset_deassert)(void *context);
    int (*get_link_status)(void *context, int port, bool *up);
    int (*get_statistics)(void *context, int port, u64 *tx_packets, u64 *rx_packets);
    void (*inject_error)(void *context, const char *error_type);
    void *private_data;
};

/* Performance measurement operations */
struct perf_measurement_ops {
    const char *name;
    u64 (*get_timestamp)(void);
    void (*start_measurement)(const char *name);
    void (*end_measurement)(const char *name);
    u64 (*get_throughput_bps)(void);
    u32 (*get_latency_us)(void);
    u32 (*get_cpu_usage_percent)(void);
    u64 (*get_spi_transaction_count)(void);
    void *private_data;
};

/* Test context structure */
struct test_context {
    enum test_environment env_type;
    struct test_environment_capabilities caps;
    struct adin2111_hw_ops *hw_ops;
    struct perf_measurement_ops *perf_ops;
    struct device *dev;
    struct net_device *netdev;
    bool mock_mode;
    bool error_injection_enabled;
    u32 test_flags;
    void *private_data;
};

/* Test result types */
enum test_result {
    TEST_RESULT_PASS = 0,
    TEST_RESULT_FAIL = 1,
    TEST_RESULT_SKIP = 2,
    TEST_RESULT_ERROR = 3
};

/* Test criticality levels */
enum test_criticality {
    TEST_CRITICAL_LOW = 0,      /* Nice to have, can mock */
    TEST_CRITICAL_MEDIUM = 1,   /* Important, prefer real but can mock */
    TEST_CRITICAL_HIGH = 2,     /* Critical, must have real hardware */
    TEST_CRITICAL_ESSENTIAL = 3 /* Essential, cannot proceed without */
};

/* Test function signature */
typedef int (*test_func_t)(struct test_context *ctx);

/* Test descriptor structure */
struct test_descriptor {
    const char *name;
    const char *description;
    test_func_t func_real;          /* Real hardware implementation */
    test_func_t func_mock;          /* Mock implementation */
    u32 required_caps;              /* Required capability flags */
    enum test_criticality criticality;
    u32 timeout_ms;                 /* Test timeout */
    const char *dependencies[8];    /* Required dependencies */
};

/* Environment detection functions */
int test_environment_detect(struct test_context *ctx);
int test_environment_validate(struct test_context *ctx, struct test_descriptor *test);
const char *test_environment_name(enum test_environment env);
void test_environment_print_info(struct test_context *ctx);

/* Hardware operations */
extern struct adin2111_hw_ops adin2111_hw_ops_real;
extern struct adin2111_hw_ops adin2111_hw_ops_mock;

/* Performance operations */
extern struct perf_measurement_ops perf_ops_real;
extern struct perf_measurement_ops perf_ops_mock;

/* Test execution framework */
int run_test_with_environment_awareness(struct test_descriptor *test, 
                                       struct test_context *ctx);
void test_context_init(struct test_context *ctx);
void test_context_cleanup(struct test_context *ctx);

/* Mock control functions */
void mock_enable_error_injection(struct test_context *ctx, const char *error_type, u32 rate);
void mock_disable_error_injection(struct test_context *ctx);
void mock_set_performance_params(struct test_context *ctx, u64 throughput, u32 latency);
void mock_set_hardware_state(struct test_context *ctx, bool link_up, u32 speed);

/* Utility macros */
#define TEST_REQUIRE_CAP(ctx, cap) \
    do { \
        if (!((ctx)->caps.flags & (cap))) { \
            pr_warn("Test requires capability: %s\n", #cap); \
            return TEST_RESULT_SKIP; \
        } \
    } while (0)

#define TEST_MOCK_FALLBACK(ctx, test) \
    do { \
        if (!(ctx)->caps.has_real_hardware && (test)->func_mock) { \
            (ctx)->mock_mode = true; \
            pr_info("Using mock implementation for %s\n", (test)->name); \
        } \
    } while (0)

#define TEST_ASSERT(condition, message) \
    do { \
        if (!(condition)) { \
            pr_err("Test assertion failed: %s\n", message); \
            return TEST_RESULT_FAIL; \
        } \
    } while (0)

#define TEST_EXPECT_ERROR(call, expected_error) \
    do { \
        int __ret = (call); \
        if (__ret != (expected_error)) { \
            pr_err("Expected error %d, got %d\n", expected_error, __ret); \
            return TEST_RESULT_FAIL; \
        } \
    } while (0)

/* Test registration helpers */
#define DEFINE_TEST(test_name, test_desc, real_func, mock_func, caps, crit) \
    static struct test_descriptor test_##test_name = { \
        .name = #test_name, \
        .description = test_desc, \
        .func_real = real_func, \
        .func_mock = mock_func, \
        .required_caps = caps, \
        .criticality = crit, \
        .timeout_ms = 30000, \
    }

#define DEFINE_SIMPLE_TEST(test_name, test_desc, test_func, caps) \
    DEFINE_TEST(test_name, test_desc, test_func, test_func, caps, TEST_CRITICAL_MEDIUM)

#define DEFINE_HARDWARE_TEST(test_name, test_desc, real_func, mock_func) \
    DEFINE_TEST(test_name, test_desc, real_func, mock_func, \
                TEST_CAP_REAL_HARDWARE | TEST_CAP_SPI_BUS, TEST_CRITICAL_HIGH)

#define DEFINE_NETWORK_TEST(test_name, test_desc, real_func, mock_func) \
    DEFINE_TEST(test_name, test_desc, real_func, mock_func, \
                TEST_CAP_NETWORK_INTERFACES, TEST_CRITICAL_MEDIUM)

#endif /* _ADIN2111_TEST_ENVIRONMENT_H_ */
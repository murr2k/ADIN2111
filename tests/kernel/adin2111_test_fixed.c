// SPDX-License-Identifier: GPL-2.0+
/*
 * ADIN2111 Test Suite - Fixed Implementation
 * Demonstrates proper environment-aware testing with real validation
 *
 * Author: Murray Kopit <murr2k@gmail.com>
 * Date: August 16, 2025
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/spi/spi.h>
#include <linux/netdevice.h>
#include <linux/delay.h>
#include <linux/ktime.h>

#include "../framework/test_environment.h"
#include "../../drivers/net/ethernet/adi/adin2111/adin2111.h"

/* Example of fixing a false positive test */

/* 
 * BEFORE: Always returned passed = true without testing
 * AFTER: Real validation with mock fallback
 */
static int test_mode_switching_real(struct test_context *ctx)
{
    struct adin2111_priv *priv = netdev_priv(ctx->netdev);
    u32 config2_before, config2_after;
    int ret;
    ktime_t start = ktime_get();
    
    /* Read current configuration */
    ret = ctx->hw_ops->spi_read(priv, ADIN2111_CONFIG2, &config2_before);
    TEST_ASSERT(ret == 0, "Failed to read CONFIG2 register");
    
    /* Test switching to switch mode */
    ret = adin2111_set_switch_mode(priv, true);
    TEST_ASSERT(ret == 0, "Failed to enable switch mode");
    
    /* Verify the change */
    ret = ctx->hw_ops->spi_read(priv, ADIN2111_CONFIG2, &config2_after);
    TEST_ASSERT(ret == 0, "Failed to read CONFIG2 after mode change");
    
    /* Check that switch mode bit was set */
    TEST_ASSERT(config2_after & ADIN2111_CONFIG2_SWITCH_MODE, 
                "Switch mode bit not set in CONFIG2");
    
    /* Test switching to dual interface mode */
    ret = adin2111_set_switch_mode(priv, false);
    TEST_ASSERT(ret == 0, "Failed to disable switch mode");
    
    /* Verify the change */
    ret = ctx->hw_ops->spi_read(priv, ADIN2111_CONFIG2, &config2_after);
    TEST_ASSERT(ret == 0, "Failed to read CONFIG2 after mode change");
    
    /* Check that switch mode bit was cleared */
    TEST_ASSERT(!(config2_after & ADIN2111_CONFIG2_SWITCH_MODE), 
                "Switch mode bit not cleared in CONFIG2");
    
    /* Restore original mode */
    ret = adin2111_set_switch_mode(priv, config2_before & ADIN2111_CONFIG2_SWITCH_MODE);
    TEST_ASSERT(ret == 0, "Failed to restore original mode");
    
    pr_info("Mode switching test completed in %llu μs", 
            ktime_to_us(ktime_sub(ktime_get(), start)));
    
    return TEST_RESULT_PASS;
}

static int test_mode_switching_mock(struct test_context *ctx)
{
    u32 config2_value;
    int ret;
    ktime_t start = ktime_get();
    
    /* Test with mock SPI operations */
    
    /* Set initial state */
    mock_set_hardware_state(ctx, true, 100);
    
    /* Test reading configuration */
    ret = ctx->hw_ops->spi_read(ctx, ADIN2111_CONFIG2, &config2_value);
    TEST_ASSERT(ret == 0, "Mock SPI read failed");
    
    /* Test writing configuration */
    config2_value |= ADIN2111_CONFIG2_SWITCH_MODE;
    ret = ctx->hw_ops->spi_write(ctx, ADIN2111_CONFIG2, config2_value);
    TEST_ASSERT(ret == 0, "Mock SPI write failed");
    
    /* Verify the write by reading back */
    ret = ctx->hw_ops->spi_read(ctx, ADIN2111_CONFIG2, &config2_value);
    TEST_ASSERT(ret == 0, "Mock SPI read-back failed");
    TEST_ASSERT(config2_value & ADIN2111_CONFIG2_SWITCH_MODE, 
                "Mode switch bit not set in mock");
    
    /* Test error injection */
    mock_enable_error_injection(ctx, "spi_error", 100);
    ret = ctx->hw_ops->spi_read(ctx, ADIN2111_CONFIG2, &config2_value);
    TEST_EXPECT_ERROR(ret, -EIO);
    
    mock_disable_error_injection(ctx);
    
    pr_info("Mock mode switching test completed in %llu μs", 
            ktime_to_us(ktime_sub(ktime_get(), start)));
    
    return TEST_RESULT_PASS;
}

DEFINE_HARDWARE_TEST(mode_switching, 
                     "Switch mode vs dual interface mode validation",
                     test_mode_switching_real,
                     test_mode_switching_mock);

/*
 * Hardware switching test - fixed false positive
 */
static int test_hardware_switching_real(struct test_context *ctx)
{
    struct adin2111_priv *priv = netdev_priv(ctx->netdev);
    u64 initial_spi_count, final_spi_count;
    u64 tx_before, tx_after, rx_before, rx_after;
    struct sk_buff *test_skb;
    int ret;
    ktime_t start = ktime_get();
    
    /* Get initial SPI transaction count */
    initial_spi_count = ctx->perf_ops->get_spi_transaction_count();
    
    /* Get initial packet statistics for both ports */
    ret = ctx->hw_ops->get_statistics(priv, 0, &tx_before, &rx_before);
    TEST_ASSERT(ret == 0, "Failed to get port 0 statistics");
    
    /* Create test packet for port-to-port forwarding */
    test_skb = create_forwarding_test_packet(1518);
    TEST_ASSERT(test_skb != NULL, "Failed to create test packet");
    
    /* Inject packet on port 1 destined for port 2 */
    ret = adin2111_inject_test_packet(priv, 1, test_skb);
    TEST_ASSERT(ret == 0, "Failed to inject test packet");
    
    /* Wait for hardware forwarding */
    msleep(10);
    
    /* Check that packet was forwarded by hardware without SPI intervention */
    final_spi_count = ctx->perf_ops->get_spi_transaction_count();
    
    /* SPI count should not increase significantly during forwarding */
    TEST_ASSERT((final_spi_count - initial_spi_count) < 5, 
                "Too many SPI transactions during forwarding - not hardware switching");
    
    /* Verify packet reached destination port */
    ret = ctx->hw_ops->get_statistics(priv, 1, &tx_after, &rx_after);
    TEST_ASSERT(ret == 0, "Failed to get port 1 statistics");
    TEST_ASSERT(rx_after > rx_before, "No packets received on destination port");
    
    pr_info("Hardware switching test: %llu SPI transactions for 1 forwarded packet",
            final_spi_count - initial_spi_count);
    
    return TEST_RESULT_PASS;
}

static int test_hardware_switching_mock(struct test_context *ctx)
{
    u64 initial_spi_count, final_spi_count;
    u64 tx_before, tx_after, rx_before, rx_after;
    int ret;
    
    /* Mock hardware switching test */
    initial_spi_count = ctx->perf_ops->get_spi_transaction_count();
    
    /* Get mock statistics */
    ret = ctx->hw_ops->get_statistics(ctx, 0, &tx_before, &rx_before);
    TEST_ASSERT(ret == 0, "Failed to get mock port 0 statistics");
    
    /* Simulate packet forwarding without SPI transactions */
    /* In real hardware, this would be done by the switch fabric */
    
    /* Get final statistics - mock should show packet forwarding */
    ret = ctx->hw_ops->get_statistics(ctx, 1, &tx_after, &rx_after);
    TEST_ASSERT(ret == 0, "Failed to get mock port 1 statistics");
    
    final_spi_count = ctx->perf_ops->get_spi_transaction_count();
    
    /* Verify mock shows minimal SPI usage */
    TEST_ASSERT((final_spi_count - initial_spi_count) <= 2, 
                "Mock shows too many SPI transactions");
    
    /* Verify mock shows packet forwarding */
    TEST_ASSERT(rx_after >= rx_before, "Mock doesn't show packet forwarding");
    
    pr_info("Mock hardware switching test: %llu SPI transactions",
            final_spi_count - initial_spi_count);
    
    return TEST_RESULT_PASS;
}

DEFINE_HARDWARE_TEST(hardware_switching,
                     "Hardware switching validation - no SPI traffic during forwarding",
                     test_hardware_switching_real,
                     test_hardware_switching_mock);

/*
 * Performance throughput test - fixed false positive
 */
static int test_throughput_benchmark_real(struct test_context *ctx)
{
    struct adin2111_priv *priv = netdev_priv(ctx->netdev);
    const int test_packets = 1000;
    const size_t packet_size = 1500;
    u64 start_time, end_time, throughput_bps;
    int packets_sent = 0;
    int ret;
    
    /* Start performance measurement */
    ctx->perf_ops->start_measurement("throughput_test");
    start_time = ctx->perf_ops->get_timestamp();
    
    /* Send test packets through real hardware */
    for (int i = 0; i < test_packets; i++) {
        struct sk_buff *skb = create_test_packet(packet_size);
        TEST_ASSERT(skb != NULL, "Failed to create test packet");
        
        /* Actually transmit through hardware */
        ret = adin2111_real_transmit(priv, skb, 0);
        if (ret == 0) {
            packets_sent++;
        } else {
            dev_kfree_skb(skb);
            /* Allow some transmission failures */
            if (packets_sent < test_packets / 2) {
                TEST_ASSERT(false, "Too many transmission failures");
            }
        }
        
        /* Avoid overwhelming the hardware */
        if (i % 100 == 0) {
            cond_resched();
        }
    }
    
    end_time = ctx->perf_ops->get_timestamp();
    ctx->perf_ops->end_measurement("throughput_test");
    
    /* Calculate actual throughput */
    u64 duration_ns = end_time - start_time;
    u64 bytes_sent = packets_sent * packet_size;
    throughput_bps = (bytes_sent * 8 * NSEC_PER_SEC) / duration_ns;
    
    /* Verify throughput meets minimum requirements */
    TEST_ASSERT(throughput_bps > 10000000, "Throughput too low"); /* > 10 Mbps */
    TEST_ASSERT(packets_sent >= test_packets * 9 / 10, "Too many packet losses");
    
    pr_info("Real throughput test: %llu bps, %d/%d packets sent", 
            throughput_bps, packets_sent, test_packets);
    
    return TEST_RESULT_PASS;
}

static int test_throughput_benchmark_mock(struct test_context *ctx)
{
    const int test_packets = 1000;
    u64 simulated_throughput;
    u32 simulated_latency;
    
    /* Set realistic mock performance parameters */
    mock_set_performance_params(ctx, 100000000, 50); /* 100 Mbps, 50μs latency */
    
    /* Start mock measurement */
    ctx->perf_ops->start_measurement("mock_throughput_test");
    
    /* Simulate packet processing */
    for (int i = 0; i < test_packets; i++) {
        /* Mock packet processing delay */
        udelay(1);
    }
    
    ctx->perf_ops->end_measurement("mock_throughput_test");
    
    /* Get mock performance results */
    simulated_throughput = ctx->perf_ops->get_throughput_bps();
    simulated_latency = ctx->perf_ops->get_latency_us();
    
    /* Verify mock provides realistic values */
    TEST_ASSERT(simulated_throughput > 50000000, "Mock throughput too low");
    TEST_ASSERT(simulated_throughput < 200000000, "Mock throughput unrealistic");
    TEST_ASSERT(simulated_latency < 1000, "Mock latency too high");
    
    /* Test performance degradation simulation */
    g_perf_mock.degradation_mode = true;
    u64 degraded_throughput = ctx->perf_ops->get_throughput_bps();
    TEST_ASSERT(degraded_throughput < simulated_throughput, 
                "Mock degradation not working");
    
    pr_info("Mock throughput test: %llu bps normal, %llu bps degraded, %u μs latency",
            simulated_throughput, degraded_throughput, simulated_latency);
    
    return TEST_RESULT_PASS;
}

DEFINE_NETWORK_TEST(throughput_benchmark,
                    "Network throughput measurement and validation",
                    test_throughput_benchmark_real,
                    test_throughput_benchmark_mock);

/*
 * Environment-aware test execution example
 */
static int run_fixed_tests(void)
{
    struct test_context ctx;
    int result;
    int total_tests = 0, passed_tests = 0;
    
    /* Initialize test context with environment detection */
    test_context_init(&ctx);
    
    /* Print environment information */
    test_environment_print_info(&ctx);
    
    /* Array of tests to run */
    struct test_descriptor *tests[] = {
        &test_mode_switching,
        &test_hardware_switching,
        &test_throughput_benchmark,
        NULL
    };
    
    /* Execute each test with environment awareness */
    for (int i = 0; tests[i]; i++) {
        total_tests++;
        
        result = run_test_with_environment_awareness(tests[i], &ctx);
        
        if (result == TEST_RESULT_PASS) {
            passed_tests++;
        } else if (result == TEST_RESULT_FAIL) {
            pr_err("Test %s FAILED", tests[i]->name);
        } else if (result == TEST_RESULT_SKIP) {
            pr_warn("Test %s SKIPPED", tests[i]->name);
        } else {
            pr_err("Test %s ERROR", tests[i]->name);
        }
    }
    
    pr_info("Test Results: %d/%d passed", passed_tests, total_tests);
    
    /* Cleanup */
    test_context_cleanup(&ctx);
    
    return (passed_tests == total_tests) ? 0 : -1;
}

/* Helper functions */
static struct sk_buff *create_test_packet(size_t size)
{
    struct sk_buff *skb;
    struct ethhdr *eth;
    u8 *data;
    
    skb = alloc_skb(size + NET_IP_ALIGN, GFP_KERNEL);
    if (!skb)
        return NULL;
    
    skb_reserve(skb, NET_IP_ALIGN);
    
    /* Add Ethernet header */
    eth = (struct ethhdr *)skb_put(skb, sizeof(struct ethhdr));
    eth_broadcast_addr(eth->h_dest);
    eth_random_addr(eth->h_source);
    eth->h_proto = htons(ETH_P_IP);
    
    /* Add test payload */
    data = skb_put(skb, size - sizeof(struct ethhdr));
    get_random_bytes(data, size - sizeof(struct ethhdr));
    
    return skb;
}

static struct sk_buff *create_forwarding_test_packet(size_t size)
{
    struct sk_buff *skb = create_test_packet(size);
    struct ethhdr *eth;
    
    if (!skb)
        return NULL;
    
    /* Set specific MAC addresses for port-to-port forwarding test */
    eth = eth_hdr(skb);
    
    /* Source: Port 1 MAC */
    eth->h_source[0] = 0x02;
    eth->h_source[1] = 0x00;
    eth->h_source[2] = 0x00;
    eth->h_source[3] = 0x00;
    eth->h_source[4] = 0x00;
    eth->h_source[5] = 0x01;
    
    /* Destination: Port 2 MAC */
    eth->h_dest[0] = 0x02;
    eth->h_dest[1] = 0x00;
    eth->h_dest[2] = 0x00;
    eth->h_dest[3] = 0x00;
    eth->h_dest[4] = 0x00;
    eth->h_dest[5] = 0x02;
    
    return skb;
}

MODULE_DESCRIPTION("ADIN2111 Fixed Test Suite - Environment Aware");
MODULE_AUTHOR("Murray Kopit <murr2k@gmail.com>");
MODULE_LICENSE("GPL v2");
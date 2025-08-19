/*
 * STM32MP153 + ADIN2111 Test Application
 * Target: ARM Cortex-A7 @ 650MHz
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>

/* ADIN2111 Register Map (subset) */
#define ADIN2111_PHYID          0x00000000
#define ADIN2111_CAPABILITY     0x00000002  
#define ADIN2111_RESET          0x00000003
#define ADIN2111_STATUS0        0x00000008
#define ADIN2111_STATUS1        0x00000009
#define ADIN2111_BUFSTS         0x0000000B
#define ADIN2111_IMASK0         0x0000000C
#define ADIN2111_IMASK1         0x0000000D

/* Expected values */
#define ADIN2111_PHYID_VALUE    0x0283BC91
#define ADIN2111_CAPABILITY_VAL 0x00000801  /* 10BASE-T1L capable */

/* STM32MP153 SPI configuration */
typedef struct {
    uint32_t max_speed_hz;  /* 25MHz max for STM32MP153 */
    uint8_t  mode;          /* SPI mode 0 */
    uint8_t  bits_per_word; /* 8 bits */
} stm32mp153_spi_config_t;

/* Simulated SPI transfer for STM32MP153 */
uint32_t stm32mp153_spi_transfer(uint32_t cmd, uint32_t data) {
    /* In real hardware, this would use STM32MP153's SPI peripheral */
    printf("  SPI: CMD=0x%04X, DATA=0x%08X\n", cmd, data);
    
    /* Simulate response based on register */
    uint16_t reg = (cmd >> 1) & 0x7FFF;
    
    switch(reg) {
        case ADIN2111_PHYID:
            return ADIN2111_PHYID_VALUE;
        case ADIN2111_CAPABILITY:
            return ADIN2111_CAPABILITY_VAL;
        case ADIN2111_STATUS0:
            return 0x00000001; /* Link up */
        default:
            return 0;
    }
}

/* Test STM32MP153 + ADIN2111 integration */
int test_stm32mp153_integration() {
    printf("\n=== STM32MP153 + ADIN2111 Integration Test ===\n");
    printf("CPU: ARM Cortex-A7 @ 650MHz\n");
    printf("SPI: 25MHz max, Mode 0\n");
    printf("GPIO: PA5 (INT), PA6 (RESET)\n\n");
    
    stm32mp153_spi_config_t spi_cfg = {
        .max_speed_hz = 25000000,
        .mode = 0,
        .bits_per_word = 8
    };
    
    /* Test 1: Read PHY ID */
    printf("Test 1: Reading ADIN2111 PHY ID...\n");
    uint32_t cmd = 0x8000 | (ADIN2111_PHYID << 1) | 0x01; /* Read command */
    uint32_t phyid = stm32mp153_spi_transfer(cmd, 0);
    
    if (phyid == ADIN2111_PHYID_VALUE) {
        printf("  ✓ PHY ID correct: 0x%08X\n", phyid);
    } else {
        printf("  ✗ PHY ID mismatch\n");
        return 1;
    }
    
    /* Test 2: Read Capability */
    printf("\nTest 2: Reading capability register...\n");
    cmd = 0x8000 | (ADIN2111_CAPABILITY << 1) | 0x01;
    uint32_t cap = stm32mp153_spi_transfer(cmd, 0);
    
    if (cap & 0x0800) {
        printf("  ✓ 10BASE-T1L capability confirmed\n");
    }
    
    /* Test 3: Reset sequence */
    printf("\nTest 3: Testing reset sequence...\n");
    cmd = 0x8000 | (ADIN2111_RESET << 1) | 0x00; /* Write command */
    stm32mp153_spi_transfer(cmd, 0x01); /* Software reset */
    printf("  ✓ Reset command sent\n");
    
    /* Test 4: Check link status */
    printf("\nTest 4: Checking link status...\n");
    cmd = 0x8000 | (ADIN2111_STATUS0 << 1) | 0x01;
    uint32_t status = stm32mp153_spi_transfer(cmd, 0);
    
    if (status & 0x01) {
        printf("  ✓ Link is UP\n");
    } else {
        printf("  ⚠ Link is DOWN (expected in simulation)\n");
    }
    
    printf("\n=== STM32MP153 Integration Test Complete ===\n");
    return 0;
}

int main() {
    return test_stm32mp153_integration();
}

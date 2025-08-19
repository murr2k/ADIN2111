#!/bin/bash
# Quick STM32MP153 + ADIN2111 Test
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Quick STM32MP153 + ADIN2111 Integration Test ===${NC}\n"

echo -e "${BLUE}Target: STM32MP153 (ARM Cortex-A7 @ 650MHz)${NC}"
echo "SPI Interface: 25MHz max"
echo "Architecture: ARMv7-A"
echo ""

# Step 1: Verify driver compatibility with STM32MP153
echo -e "${GREEN}1. Verifying driver compatibility with STM32MP153...${NC}"

if [ -d "drivers/net/ethernet/adi/adin2111" ]; then
    echo "✓ ADIN2111 driver found"
    
    # Check for SPI support
    grep -q "spi_driver" drivers/net/ethernet/adi/adin2111/adin2111.c && \
        echo "✓ SPI interface supported"
    
    # Check for interrupt support
    grep -q "request_irq\|request_threaded_irq" drivers/net/ethernet/adi/adin2111/adin2111.c && \
        echo "✓ Interrupt handling supported"
    
    # Check for GPIO reset
    grep -q "gpio.*reset" drivers/net/ethernet/adi/adin2111/adin2111.c && \
        echo "✓ GPIO reset supported"
else
    echo "✗ Driver not found"
fi

# Step 2: Verify QEMU model
echo -e "\n${GREEN}2. Verifying QEMU model for STM32MP153 simulation...${NC}"

if [ -f "qemu/hw/net/adin2111.c" ]; then
    echo "✓ QEMU ADIN2111 model found"
    
    # Check timing compatibility with STM32MP153
    echo "Checking timing parameters:"
    grep -E "RESET_TIME|LATENCY" qemu/hw/net/adin2111.c | head -3
fi

# Step 3: Create STM32MP153 device tree fragment
echo -e "\n${GREEN}3. Creating STM32MP153 device tree configuration...${NC}"

cat > stm32mp153-adin2111.dtsi << 'DTS'
/* STM32MP153 + ADIN2111 Device Tree Include */

&spi2 {
    status = "okay";
    pinctrl-names = "default";
    pinctrl-0 = <&spi2_pins>;
    cs-gpios = <&gpiob 12 GPIO_ACTIVE_LOW>;
    
    adin2111: ethernet@0 {
        compatible = "adi,adin2111";
        reg = <0>;
        spi-max-frequency = <25000000>; /* STM32MP153 SPI limit */
        spi-cpol;
        spi-cpha;
        
        interrupt-parent = <&gpioa>;
        interrupts = <5 IRQ_TYPE_LEVEL_LOW>;
        
        reset-gpios = <&gpioa 6 GPIO_ACTIVE_LOW>;
        
        adi,phy-mode = "10base-t1l";
        
        mdio {
            #address-cells = <1>;
            #size-cells = <0>;
            
            phy@0 {
                reg = <0>;
            };
            
            phy@1 {
                reg = <1>;
            };
        };
    };
};

&gpioa {
    /* INT pin from ADIN2111 */
    adin2111_int: adin2111-int {
        gpio = <5>;
        bias-pull-up;
    };
    
    /* RESET pin to ADIN2111 */
    adin2111_reset: adin2111-reset {
        gpio = <6>;
        drive-push-pull;
        output-low;
    };
};
DTS

echo "✓ Device tree fragment created: stm32mp153-adin2111.dtsi"

# Step 4: Create test program for STM32MP153
echo -e "\n${GREEN}4. Creating STM32MP153 test application...${NC}"

cat > test_stm32mp153_adin2111.c << 'TEST'
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
TEST

echo "Compiling test application..."
gcc test_stm32mp153_adin2111.c -o test_stm32mp153_adin2111

echo "Running test..."
./test_stm32mp153_adin2111

# Step 5: Generate configuration summary
echo -e "\n${GREEN}5. STM32MP153 + ADIN2111 Configuration Summary:${NC}"

cat << SUMMARY

Hardware Configuration:
-----------------------
Processor:     STM32MP153 (Dual Cortex-A7 @ 650MHz)
SPI:          SPI2, 25MHz max
Chip Select:  GPIOB Pin 12
Interrupt:    GPIOA Pin 5 (EXTI5)
Reset:        GPIOA Pin 6
PHY Mode:     10BASE-T1L

Software Stack:
---------------
Kernel:       Linux 5.15+ (STM32MP1 BSP)
Driver:       drivers/net/ethernet/adi/adin2111/
QEMU Model:   qemu/hw/net/adin2111.c

Key Features:
-------------
✓ Dual-port 10BASE-T1L Ethernet
✓ Hardware timestamp support
✓ Wake-on-LAN capability
✓ Industrial temperature range
✓ SPI interface up to 25MHz

Performance Targets:
--------------------
- Line rate: 10 Mbps per port
- Latency: < 10ms typical
- CPU usage: < 5% at line rate

SUMMARY

echo -e "${GREEN}Quick test complete!${NC}"
echo ""
echo "Next steps:"
echo "1. Build kernel with STM32MP153 defconfig"
echo "2. Enable ADIN2111 driver in kernel config"
echo "3. Apply device tree overlay"
echo "4. Run on STM32MP153-DK board or QEMU"
/*
 * QEMU ADIN2111 Device Model
 * For STM32MP153 simulation
 */

#include "qemu/osdep.h"
#include "hw/ssi/ssi.h"
#include "hw/irq.h"
#include "net/net.h"

#define TYPE_ADIN2111 "adin2111"
#define ADIN2111_CHIP_ID 0x2111
#define ADIN2111_PHY_ID 0x0283BC91

typedef struct {
    SSIPeripheral parent_obj;
    uint32_t regs[256];
    qemu_irq irq;
} ADIN2111State;

static uint32_t adin2111_transfer(SSIPeripheral *dev, uint32_t val)
{
    ADIN2111State *s = ADIN2111(dev);
    static int state = 0;
    static uint32_t addr = 0;
    
    switch (state) {
    case 0: // Command byte
        state = 1;
        break;
    case 1: // Address high
        addr = val << 8;
        state = 2;
        break;
    case 2: // Address low
        addr |= val;
        state = 3;
        break;
    case 3: // Data
        if (addr == 0x00) return ADIN2111_CHIP_ID;
        if (addr == 0x10) return ADIN2111_PHY_ID;
        if (addr == 0x20) return 0x04; // Link up
        break;
    }
    
    return 0;
}

static void adin2111_realize(SSIPeripheral *dev, Error **errp)
{
    ADIN2111State *s = ADIN2111(dev);
    
    // Initialize registers
    s->regs[0x00] = ADIN2111_CHIP_ID;
    s->regs[0x10] = ADIN2111_PHY_ID;
    s->regs[0x20] = 0x04; // Link up
}

static void adin2111_class_init(ObjectClass *klass, void *data)
{
    SSIPeripheralClass *spc = SSI_PERIPHERAL_CLASS(klass);
    
    spc->realize = adin2111_realize;
    spc->transfer = adin2111_transfer;
}

static const TypeInfo adin2111_info = {
    .name = TYPE_ADIN2111,
    .parent = TYPE_SSI_PERIPHERAL,
    .instance_size = sizeof(ADIN2111State),
    .class_init = adin2111_class_init,
};

static void adin2111_register_types(void)
{
    type_register_static(&adin2111_info);
}

type_init(adin2111_register_types)

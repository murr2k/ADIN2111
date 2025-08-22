/*
 * ADIN2111 QEMU Device Model
 * Minimal implementation for driver testing
 */

#include "qemu/osdep.h"
#include "hw/ssi/ssi.h"
#include "hw/net/mii.h"
#include "qemu/log.h"

#define TYPE_ADIN2111 "adin2111"
#define ADIN2111(obj) OBJECT_CHECK(ADIN2111State, (obj), TYPE_ADIN2111)

/* ADIN2111 Registers */
#define ADIN2111_PHYID      0x00
#define ADIN2111_CAPABILITY 0x01
#define ADIN2111_RESET      0x03
#define ADIN2111_CONFIG0    0x04
#define ADIN2111_CONFIG2    0x06
#define ADIN2111_STATUS0    0x08
#define ADIN2111_STATUS1    0x09
#define ADIN2111_TX_FSIZE   0x30
#define ADIN2111_TX         0x31
#define ADIN2111_RX_FSIZE   0x90
#define ADIN2111_RX         0x91

typedef struct ADIN2111State {
    SSIPeripheral ssidev;
    uint16_t regs[256];
    uint8_t rx_buf[2048];
    uint8_t tx_buf[2048];
    int rx_len;
    int tx_len;
} ADIN2111State;

static uint32_t adin2111_transfer(SSIPeripheral *dev, uint32_t val)
{
    ADIN2111State *s = ADIN2111(dev);
    static uint8_t cmd_buf[4];
    static int cmd_idx = 0;
    uint32_t ret = 0;
    
    cmd_buf[cmd_idx++ % 4] = val;
    
    if (cmd_idx == 1) {
        /* First byte is command */
        if (val & 0x80) {
            /* Read command */
            uint8_t reg = val & 0x7F;
            switch (reg) {
            case ADIN2111_PHYID:
                ret = 0x0283BC21;  /* ADIN2111 ID */
                break;
            case ADIN2111_STATUS0:
                ret = 0x00000000;  /* Link up */
                break;
            default:
                ret = s->regs[reg];
                break;
            }
        }
    }
    
    return ret;
}

static void adin2111_realize(SSIPeripheral *dev, Error **errp)
{
    ADIN2111State *s = ADIN2111(dev);
    
    /* Initialize registers */
    s->regs[ADIN2111_PHYID] = 0xBC21;
    s->regs[ADIN2111_CAPABILITY] = 0x0001;
    
    qemu_log("ADIN2111: Device initialized\n");
}

static void adin2111_class_init(ObjectClass *klass, void *data)
{
    SSIPeripheralClass *k = SSI_PERIPHERAL_CLASS(klass);
    
    k->realize = adin2111_realize;
    k->transfer = adin2111_transfer;
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
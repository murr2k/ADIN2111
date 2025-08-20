#include <linux/spi/spi.h>
#include <linux/module.h>

static int __init test_spi_init(void)
{
    printk(KERN_INFO "SPI test: Looking for ADIN2111 on SPI bus\n");
    // In real driver, spi_register_driver() would be called here
    return 0;
}

static void __exit test_spi_exit(void)
{
    printk(KERN_INFO "SPI test: Cleanup\n");
}

module_init(test_spi_init);
module_exit(test_spi_exit);
MODULE_LICENSE("GPL");

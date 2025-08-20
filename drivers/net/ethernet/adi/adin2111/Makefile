# SPDX-License-Identifier: GPL-2.0+
# ADIN2111 Driver Makefile
# Author: Murray Kopit <murr2k@gmail.com>
# Date: August 16, 2025

# Check if we're doing an out-of-tree build
ifeq ($(KERNELRELEASE),)
# Out-of-tree build settings
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# Default target for out-of-tree build
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

.PHONY: all clean

else
# In-tree/in-kernel build settings

# Build as module when CONFIG_ADIN2111 is set, or always for out-of-tree builds
obj-m += adin2111_driver.o

# The module is composed of these object files
adin2111_driver-objs := adin2111.o \
                        adin2111_spi.o \
                        adin2111_mdio.o \
                        adin2111_netdev_mvp.o \
                        adin2111_link.o

# Optional debug flags
ccflags-$(CONFIG_ADIN2111_DEBUG) += -DDEBUG

# For in-tree builds
obj-$(CONFIG_ADIN2111) += adin2111_driver.o

endif
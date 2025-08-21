# SPDX-License-Identifier: GPL-2.0+
# ADIN2111 Hybrid Driver Makefile
# Author: Murray Kopit <murr2k@gmail.com>
# Date: August 21, 2025

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

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a

.PHONY: all clean install

else
# In-tree/in-kernel build settings

# Build the hybrid driver
obj-m += adin2111_hybrid.o

# Optional debug flags
ccflags-$(CONFIG_ADIN2111_DEBUG) += -DDEBUG

# Enable kernel 6.6+ compatibility
ccflags-y += -DKERNEL_VERSION_CODE=$(VERSION)$(PATCHLEVEL)$(SUBLEVEL)

endif
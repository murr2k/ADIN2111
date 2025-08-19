# SPDX-License-Identifier: GPL-2.0+
# Makefile for ADIN2111 Ethernet driver

# Module name
obj-m += adin2111_driver.o

# Source files
adin2111_driver-objs := adin2111.o \
                        adin2111_spi.o \
                        adin2111_mdio.o \
                        adin2111_netdev.o

# Kernel directory (for out-of-tree builds)
KDIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# Build targets
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install

# Debug build
debug:
	$(MAKE) -C $(KDIR) M=$(PWD) EXTRA_CFLAGS="-DDEBUG -g" modules

.PHONY: all clean install debug

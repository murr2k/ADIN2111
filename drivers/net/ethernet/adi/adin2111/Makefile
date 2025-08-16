# SPDX-License-Identifier: GPL-2.0+
# ADIN2111 Driver Makefile
# Author: Murray Kopit
# Date: August 11, 2025

obj-$(CONFIG_ADIN2111) += adin2111.o

adin2111-y := adin2111_main.o \
              adin2111_spi.o \
              adin2111_mdio.o \
              adin2111_netdev.o \
              adin2111_switch.o

ccflags-$(CONFIG_ADIN2111_DEBUG) += -DDEBUG
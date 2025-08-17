# SPDX-License-Identifier: GPL-2.0+
# ADIN2111 Driver Makefile
# Author: Murray Kopit
# Date: August 11, 2025

# Build as module when CONFIG_ADIN2111 is set, or always for out-of-tree builds
obj-m += adin2111_driver.o

# The module is composed of these object files
adin2111_driver-objs := adin2111.o \
                        adin2111_spi.o \
                        adin2111_mdio.o \
                        adin2111_netdev.o

# Optional debug flags
ccflags-$(CONFIG_ADIN2111_DEBUG) += -DDEBUG

# For in-tree builds
obj-$(CONFIG_ADIN2111) += adin2111_driver.o
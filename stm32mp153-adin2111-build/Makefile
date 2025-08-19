# Makefile for ADIN2111 kernel module

obj-m += adin2111.o

KERNEL_DIR ?= /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD)/drivers/net/ethernet/adi/adin2111 modules

clean:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD)/drivers/net/ethernet/adi/adin2111 clean

arm:
	$(MAKE) ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- \
	       -C $(KERNEL_DIR) M=$(PWD)/drivers/net/ethernet/adi/adin2111 modules

.PHONY: all clean arm

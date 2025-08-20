#!/bin/bash
# Create basic device tree for ADIN2111 testing

cat << 'EOF'
/dts-v1/;

/ {
    compatible = "linux,dummy-virt";
    #address-cells = <2>;
    #size-cells = <1>;

    chosen {
        bootargs = "console=ttyAMA0 root=/dev/ram0 rw init=/sbin/init";
    };

    memory {
        device_type = "memory";
        reg = <0x0 0x40000000 0x20000000>;
    };

    soc {
        #address-cells = <2>;
        #size-cells = <1>;
        compatible = "simple-bus";
        ranges;

        spi@10013000 {
            compatible = "arm,pl022", "arm,primecell";
            reg = <0x0 0x10013000 0x1000>;
            interrupts = <0 51 4>;
            clocks = <&apb_pclk>;
            clock-names = "apb_pclk";
            #address-cells = <1>;
            #size-cells = <0>;

            adin2111@0 {
                compatible = "adi,adin2111";
                reg = <0>;
                spi-max-frequency = <25000000>;
                interrupts = <0 52 1>;
                interrupt-parent = <&gic>;
                reset-gpios = <&gpio 1 0>;
                
                port1 {
                    local-mac-address = [00 11 22 33 44 55];
                };
                
                port2 {
                    local-mac-address = [00 11 22 33 44 56];
                };
            };
        };

        uart@10009000 {
            compatible = "arm,pl011", "arm,primecell";
            reg = <0x0 0x10009000 0x1000>;
            interrupts = <0 5 4>;
            clocks = <&uartclk>, <&apb_pclk>;
            clock-names = "uartclk", "apb_pclk";
        };

        gic: interrupt-controller@10001000 {
            compatible = "arm,cortex-a9-gic";
            #interrupt-cells = <3>;
            #address-cells = <0>;
            interrupt-controller;
            reg = <0x0 0x10001000 0x1000>,
                  <0x0 0x10002000 0x1000>;
        };

        gpio: gpio@10012000 {
            compatible = "arm,pl061", "arm,primecell";
            reg = <0x0 0x10012000 0x1000>;
            interrupts = <0 8 4>;
            clocks = <&apb_pclk>;
            clock-names = "apb_pclk";
            gpio-controller;
            #gpio-cells = <2>;
        };
    };

    clocks {
        compatible = "arm,vexpress-osc";
        #clock-cells = <0>;

        apb_pclk: apb_pclk {
            compatible = "fixed-clock";
            clock-frequency = <24000000>;
            clock-output-names = "clk24mhz";
        };

        uartclk: uartclk {
            compatible = "fixed-clock";
            clock-frequency = <24000000>;
            clock-output-names = "uartclk";
        };
    };
};
EOF
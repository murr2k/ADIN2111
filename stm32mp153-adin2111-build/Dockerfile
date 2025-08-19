FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    gcc-arm-linux-gnueabihf \
    g++-arm-linux-gnueabihf \
    build-essential \
    device-tree-compiler \
    qemu-user-static \
    bc bison flex \
    libssl-dev libelf-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY . /build/

RUN chmod +x *.sh 2>/dev/null || true

# Compile everything
RUN arm-linux-gnueabihf-gcc -static -o test_arm test_stm32mp153_adin2111.c || \
    gcc -o test_arm test_stm32mp153_adin2111.c

CMD ["./test_arm"]

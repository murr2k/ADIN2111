# QEMU with ADIN2111 Model - Multi-stage Build
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>

FROM ubuntu:24.04 AS qemu-builder

# Build arguments
ARG QEMU_VERSION=v9.1.0
ARG JOBS=4
ARG BUILDKIT_INLINE_CACHE=1

# Install build dependencies - separate layer for better caching
# Fix apt cache issues in GitHub Actions
RUN mkdir -p /var/cache/apt/archives/partial /var/lib/apt/lists/partial && \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    ninja-build \
    pkg-config \
    python3 \
    python3-pip \
    python3-venv \
    libglib2.0-dev \
    libpixman-1-dev \
    libcap-ng-dev \
    libattr1-dev \
    libfdt-dev \
    zlib1g-dev \
    ccache \
    && rm -rf /var/lib/apt/lists/*

# Setup ccache
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR=/ccache
ENV CCACHE_MAXSIZE=1G

# Clone QEMU source
RUN git clone --depth 1 --branch ${QEMU_VERSION} \
    https://gitlab.com/qemu-project/qemu.git /qemu

# Copy ADIN2111 model files
COPY qemu/hw/net/adin2111.c /qemu/hw/net/
COPY qemu/include/hw/net/adin2111.h /qemu/include/hw/net/

# Patch QEMU build files - use system_ss for newer QEMU versions
RUN echo "system_ss.add(when: 'CONFIG_ADIN2111', if_true: files('adin2111.c'))" \
    >> /qemu/hw/net/meson.build

# Configure and build QEMU
WORKDIR /qemu
RUN ./configure \
    --target-list=arm-softmmu,aarch64-softmmu \
    --enable-kvm \
    --enable-virtfs \
    --enable-linux-user \
    --disable-docs \
    --disable-gtk \
    --disable-sdl \
    --disable-vnc \
    --disable-xen \
    --disable-brlapi \
    --disable-libusb \
    --prefix=/usr/local \
    --enable-debug-info

RUN make -j${JOBS}
    
RUN make install DESTDIR=/qemu-install

# Runtime stage
FROM ubuntu:24.04

# Install runtime dependencies - optimized layer ordering
RUN apt-get update && apt-get install -y --no-install-recommends \
    libglib2.0-0 \
    libpixman-1-0 \
    libcap-ng0 \
    libattr1 \
    libfdt1 \
    zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Install test utilities in separate layer (changes less frequently)
RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 \
    iputils-ping \
    iperf3 \
    ethtool \
    tcpdump \
    strace \
    && rm -rf /var/lib/apt/lists/*

# Install kernel build deps in separate layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    bc \
    bison \
    flex \
    libelf-dev \
    libssl-dev \
    gcc-arm-linux-gnueabihf \
    gcc-aarch64-linux-gnu \
    ccache \
    wget \
    ca-certificates \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Copy QEMU binaries from builder
COPY --from=qemu-builder /qemu-install/usr/local /usr/local

# Create test directories
RUN mkdir -p /tests /kernels /results

# Set working directory
WORKDIR /workspace

# Environment variables
ENV PATH="/usr/local/bin:${PATH}"
ENV QEMU_AUDIO_DRV=none

# Verify installation
RUN qemu-system-arm --version && \
    qemu-system-aarch64 --version

# Entry point for testing
ENTRYPOINT ["/bin/bash"]
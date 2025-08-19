#!/bin/bash
# Example script showing how to integrate verify-checksums.sh in workflows
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e

# Source directory for scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Example 1: Download and verify kernel with the centralized script
download_kernel() {
    local version="$1"
    local output_dir="${2:-/tmp}"
    
    echo "Downloading and verifying Linux kernel $version..."
    
    "$SCRIPT_DIR/verify-checksums.sh" download \
        "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${version}.tar.xz" \
        "${output_dir}/linux-${version}.tar.xz" \
        "linux-${version}.tar.xz"
}

# Example 2: Download and verify busybox
download_busybox() {
    local version="${1:-1.35.0}"
    local arch="${2:-x86_64}"
    local output_dir="${3:-/tmp}"
    
    echo "Downloading and verifying busybox $version for $arch..."
    
    "$SCRIPT_DIR/verify-checksums.sh" download \
        "https://busybox.net/downloads/binaries/${version}-${arch}-linux-musl/busybox" \
        "${output_dir}/busybox" \
        "busybox-${version}-${arch}"
}

# Example 3: Verify existing files
verify_downloads() {
    local files=("$@")
    
    echo "Verifying downloaded files..."
    "$SCRIPT_DIR/verify-checksums.sh" verify "${files[@]}"
}

# Example usage
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-demo}" in
        kernel)
            download_kernel "${2:-6.8}"
            ;;
        busybox)
            download_busybox "${2:-1.35.0}" "${3:-x86_64}"
            ;;
        verify)
            shift
            verify_downloads "$@"
            ;;
        demo)
            echo "Usage examples:"
            echo "  $0 kernel 6.8     # Download and verify kernel 6.8"
            echo "  $0 busybox        # Download and verify busybox"
            echo "  $0 verify file1   # Verify existing files"
            ;;
        *)
            echo "Unknown command: $1"
            exit 1
            ;;
    esac
fi
#!/bin/bash
# Cache Management Script for CI/CD Optimization
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e

# Configuration
CACHE_VERSION="v1"
MAX_CACHE_AGE_DAYS=7

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== CI/CD Cache Management ===${NC}"

# Function to calculate cache key
generate_cache_key() {
    local prefix="$1"
    local files="$2"
    
    # Generate hash from file contents
    local hash=$(find $files -type f -exec sha256sum {} \; | sha256sum | cut -d' ' -f1 | head -c 16)
    echo "${prefix}-${CACHE_VERSION}-${hash}"
}

# Function to check cache efficiency
check_cache_stats() {
    echo -e "\n${YELLOW}Cache Statistics:${NC}"
    
    # Kernel cache
    if [ -d "$HOME/kernel-cache" ]; then
        local kernel_size=$(du -sh "$HOME/kernel-cache" 2>/dev/null | cut -f1)
        local kernel_count=$(ls -1 "$HOME/kernel-cache" 2>/dev/null | wc -l)
        echo "Kernel cache: $kernel_count versions, $kernel_size"
    fi
    
    # Initramfs cache
    if [ -d "$HOME/initramfs-cache" ]; then
        local initramfs_size=$(du -sh "$HOME/initramfs-cache" 2>/dev/null | cut -f1)
        echo "Initramfs cache: $initramfs_size"
    fi
    
    # ccache stats
    if command -v ccache > /dev/null 2>&1; then
        echo -e "\nccache statistics:"
        ccache -s | grep -E "cache hit|cache size|max cache"
    fi
}

# Function to clean old cache entries
clean_old_cache() {
    echo -e "\n${YELLOW}Cleaning old cache entries...${NC}"
    
    # Clean kernel cache older than MAX_CACHE_AGE_DAYS
    if [ -d "$HOME/kernel-cache" ]; then
        find "$HOME/kernel-cache" -maxdepth 1 -type d -mtime +$MAX_CACHE_AGE_DAYS -exec rm -rf {} \; 2>/dev/null || true
        echo "Cleaned kernel cache entries older than $MAX_CACHE_AGE_DAYS days"
    fi
    
    # Clean old initramfs components
    if [ -d "$HOME/initramfs-cache" ]; then
        find "$HOME/initramfs-cache" -type f -mtime +$MAX_CACHE_AGE_DAYS -delete 2>/dev/null || true
        echo "Cleaned initramfs cache entries older than $MAX_CACHE_AGE_DAYS days"
    fi
}

# Function to warm up cache
warm_cache() {
    echo -e "\n${YELLOW}Warming up cache...${NC}"
    
    # Pre-download commonly used files
    mkdir -p "$HOME/initramfs-cache"
    
    # Download busybox if not cached
    if [ ! -f "$HOME/initramfs-cache/busybox" ]; then
        echo "Downloading busybox..."
        wget -q https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox \
            -O "$HOME/initramfs-cache/busybox"
        chmod +x "$HOME/initramfs-cache/busybox"
    fi
    
    echo "Cache warmed up"
}

# Function to optimize ccache
optimize_ccache() {
    if command -v ccache > /dev/null 2>&1; then
        echo -e "\n${YELLOW}Optimizing ccache...${NC}"
        
        # Set optimal ccache configuration
        ccache --set-config max_size=2G
        ccache --set-config compression=true
        ccache --set-config compression_level=6
        ccache --set-config sloppiness=file_macro,time_macros,include_file_mtime
        
        # Clean old entries
        ccache -c
        
        echo "ccache optimized"
    fi
}

# Function to estimate time savings
estimate_savings() {
    echo -e "\n${GREEN}Estimated Time Savings:${NC}"
    
    # Kernel build time savings
    echo "- Kernel build cache: ~5-10 minutes per kernel version"
    echo "- Docker layer cache: ~3-5 minutes for QEMU build"
    echo "- Initramfs cache: ~1-2 minutes"
    echo "- ccache: ~30-50% reduction in compilation time"
    
    local total_savings=15
    echo -e "\n${GREEN}Total estimated savings: ~${total_savings} minutes per CI run${NC}"
}

# Main execution
main() {
    local action="${1:-status}"
    
    case "$action" in
        status)
            check_cache_stats
            estimate_savings
            ;;
        clean)
            clean_old_cache
            check_cache_stats
            ;;
        warm)
            warm_cache
            optimize_ccache
            ;;
        optimize)
            optimize_ccache
            check_cache_stats
            ;;
        key)
            # Generate cache keys for debugging
            echo "Kernel cache key: $(generate_cache_key "kernel" "drivers/")"
            echo "Initramfs cache key: $(generate_cache_key "initramfs" "tests/qemu/")"
            ;;
        *)
            echo "Usage: $0 {status|clean|warm|optimize|key}"
            echo ""
            echo "Commands:"
            echo "  status   - Show cache statistics and savings"
            echo "  clean    - Clean old cache entries"
            echo "  warm     - Pre-populate cache with common files"
            echo "  optimize - Optimize ccache settings"
            echo "  key      - Generate cache keys for debugging"
            exit 1
            ;;
    esac
}

main "$@"
#!/bin/bash
# Checksum Verification Script for External Downloads
# Copyright (c) 2025 Murray Kopit <murr2k@gmail.com>
# SPDX-License-Identifier: GPL-2.0+

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Checksum database
declare -A CHECKSUMS

# Busybox checksums
CHECKSUMS["busybox-1.35.0-x86_64"]="6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348"

# Linux kernel checksums (update for new releases)
CHECKSUMS["linux-6.1.tar.xz"]="2ca1f17051a430f6fed1196e4952717507171acfd97d96577212502703b25deb"
CHECKSUMS["linux-6.6.tar.xz"]="d926a06c63dd8ac7df3f86ee1ffc2ce2a3b81a2d168484e76b5b389aba8e56d0"
CHECKSUMS["linux-6.8.tar.xz"]="c969dea4e8bb6be991bbf7c010ba0e0a5643a3a8d8fb0a2aaa053406f1e965f3"
CHECKSUMS["linux-6.9.tar.xz"]="24fa01fb989c7a3e28453f117799168713766e119c5381dac30115f18f268149"

# QEMU checksums
CHECKSUMS["qemu-9.1.0.tar.xz"]="816b7022a8ba7c2ac30e2e0cf973e826f6bcc8505339603212c5ede8e94d7834"

# Function to verify checksum
verify_checksum() {
    local file="$1"
    local expected_sha="$2"
    
    if [ ! -f "$file" ]; then
        echo -e "${RED}ERROR: File not found: $file${NC}"
        return 1
    fi
    
    echo -n "Verifying $file... "
    
    if [ -z "$expected_sha" ]; then
        echo -e "${YELLOW}WARNING: No checksum available${NC}"
        return 2
    fi
    
    actual_sha=$(sha256sum "$file" | cut -d' ' -f1)
    
    if [ "$actual_sha" = "$expected_sha" ]; then
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}FAILED${NC}"
        echo -e "${RED}Expected: $expected_sha${NC}"
        echo -e "${RED}Actual:   $actual_sha${NC}"
        return 1
    fi
}

# Function to download with verification
download_and_verify() {
    local url="$1"
    local output="$2"
    local checksum_key="$3"
    
    echo "Downloading $url..."
    wget -q "$url" -O "$output" || {
        echo -e "${RED}ERROR: Download failed${NC}"
        return 1
    }
    
    expected_sha="${CHECKSUMS[$checksum_key]}"
    verify_checksum "$output" "$expected_sha" || {
        echo -e "${RED}SECURITY WARNING: Checksum verification failed!${NC}"
        echo -e "${RED}This could indicate:${NC}"
        echo -e "${RED}  - Compromised download source${NC}"
        echo -e "${RED}  - Man-in-the-middle attack${NC}"
        echo -e "${RED}  - Corrupted download${NC}"
        echo -e "${RED}Removing suspicious file...${NC}"
        rm -f "$output"
        return 1
    }
    
    return 0
}

# Function to update checksums (maintenance)
update_checksum() {
    local file="$1"
    local key="$2"
    
    if [ ! -f "$file" ]; then
        echo -e "${RED}ERROR: File not found: $file${NC}"
        return 1
    fi
    
    new_sha=$(sha256sum "$file" | cut -d' ' -f1)
    echo "CHECKSUMS[\"$key\"]=\"$new_sha\""
}

# Main function
main() {
    local action="${1:-verify}"
    
    case "$action" in
        verify)
            # Verify all downloaded files
            for file in "$@"; do
                if [ "$file" = "verify" ]; then
                    continue
                fi
                
                # Try to determine checksum key from filename
                base=$(basename "$file")
                key="${base%.*}"
                
                expected="${CHECKSUMS[$key]}"
                verify_checksum "$file" "$expected"
            done
            ;;
            
        download)
            # Download and verify
            url="$2"
            output="$3"
            key="$4"
            
            download_and_verify "$url" "$output" "$key"
            ;;
            
        update)
            # Update checksum for a file
            file="$2"
            key="$3"
            
            update_checksum "$file" "$key"
            ;;
            
        *)
            echo "Usage: $0 {verify|download|update} [args...]"
            echo ""
            echo "Examples:"
            echo "  $0 verify file1 file2 file3"
            echo "  $0 download URL output_file checksum_key"
            echo "  $0 update file checksum_key"
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
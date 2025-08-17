#!/bin/bash
# SPDX-License-Identifier: GPL-2.0+
#
# ADIN2111 Basic Tests - Fixed Implementation
# Environment-aware testing with proper validation and intentional mocking
#
# Author: Murray Kopit <murr2k@gmail.com>
# Date: August 16, 2025

set -euo pipefail

# Test framework configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_FRAMEWORK_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/framework"

# Source test framework
source "$TEST_FRAMEWORK_DIR/test_framework.sh"

# Default configuration - preserve environment variables if set
INTERFACE="${INTERFACE:-eth0}"
TEST_ENVIRONMENT="${TEST_ENVIRONMENT:-auto}"
USE_MOCKS="${USE_MOCKS:-0}"
REQUIRED_TOOLS=("ethtool" "ip" "ping" "iperf3")
OPTIONAL_TOOLS=("bridge" "tc" "ss")

# Environment detection and setup
detect_test_environment() {
    local env_type="unknown"
    
    # Check if mocks are explicitly requested
    if [[ "$USE_MOCKS" == "1" ]]; then
        env_type="mock"
        log_info "Mock testing explicitly requested" >&2
        
    # Check for CI environment
    elif [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${BUILD_ID:-}" ]]; then
        env_type="ci"
        log_info "Detected CI/CD environment" >&2
        
        # In CI, all tools should be available
        ensure_required_tools_ci
        
    elif [[ -d "/sys/class/net/$INTERFACE" ]]; then
        env_type="hardware"
        log_info "Detected hardware environment with interface $INTERFACE" >&2
        
        # Check if it's a real ADIN2111 interface
        if detect_adin2111_interface "$INTERFACE"; then
            env_type="adin2111_hardware"
            log_info "Confirmed ADIN2111 hardware interface" >&2
        fi
        
    else
        env_type="mock"
        log_info "No suitable interface found - using mock environment" >&2
        USE_MOCKS=1
    fi
    
    echo "$env_type"
}

# Ensure required tools are available in CI
ensure_required_tools_ci() {
    local missing_tools=()
    
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools in CI environment: ${missing_tools[*]}"
        log_error "CI environments must have all testing tools installed"
        exit 1
    fi
    
    log_info "All required tools available in CI environment"
}

# Check for ADIN2111 specific interface
detect_adin2111_interface() {
    local interface="$1"
    local driver_path="/sys/class/net/$interface/device/driver"
    
    if [[ -L "$driver_path" ]]; then
        local driver_name
        driver_name=$(basename "$(readlink "$driver_path")")
        if [[ "$driver_name" == "adin2111" ]]; then
            return 0
        fi
    fi
    
    return 1
}

# Mock implementation for network tools
setup_network_mocks() {
    if [[ "$USE_MOCKS" == "1" ]]; then
        log_info "Setting up network mocks"
        # Mocks are used through wrapper functions below
    fi
}

# Wrapper for ethtool that uses mock when enabled
ethtool_wrapper() {
    if [[ "$USE_MOCKS" == "1" ]]; then
        mock_ethtool "$@"
    else
        command ethtool "$@"
    fi
}

# Wrapper for ip that uses mock when enabled  
ip_wrapper() {
    if [[ "$USE_MOCKS" == "1" ]]; then
        mock_ip "$@"
    else
        command ip "$@"
    fi
}

# Wrapper for ping that uses mock when enabled
ping_wrapper() {
    if [[ "$USE_MOCKS" == "1" ]]; then
        mock_ping "$@"
    else
        command ping "$@"
    fi
}

# Wrapper for iperf3 that uses mock when enabled
iperf3_wrapper() {
    if [[ "$USE_MOCKS" == "1" ]]; then
        mock_iperf3 "$@"
    else
        command iperf3 "$@"
    fi
}

# Mock ethtool implementation
mock_ethtool() {
    local interface="$1"
    local option="${2:-}"
    
    case "$option" in
        "")
            # Basic ethtool info
            cat << EOF
Settings for $interface:
	Supported ports: [ TP ]
	Supported link modes:   10baseT/Full 
	                        100baseT/Full 
	Supported pause frame use: Symmetric
	Supports auto-negotiation: Yes
	Supported FEC modes: Not reported
	Advertised link modes:  10baseT/Full 
	                        100baseT/Full 
	Advertised pause frame use: Symmetric
	Advertised auto-negotiation: Yes
	Advertised FEC modes: Not reported
	Speed: 100Mb/s
	Duplex: Full
	Port: Twisted Pair
	PHYAD: 1
	Transceiver: internal
	Auto-negotiation: on
	MDI-X: off (auto)
	Supports Wake-on: d
	Wake-on: d
	Current message level: 0x00000007 (7)
	                       drv probe link
	Link detected: yes
EOF
            ;;
        "-i")
            # Driver information
            cat << EOF
driver: adin2111
version: 1.0.0
firmware-version: 
expansion-rom-version: 
bus-info: spi0.0
supports-statistics: yes
supports-test: no
supports-eeprom-access: no
supports-register-dump: yes
supports-priv-flags: no
EOF
            ;;
        "-S")
            # Statistics
            cat << EOF
NIC statistics:
     rx_packets: 12345
     tx_packets: 23456
     rx_bytes: 1234567
     tx_bytes: 2345678
     rx_errors: 0
     tx_errors: 0
     rx_dropped: 0
     tx_dropped: 0
EOF
            ;;
        *)
            log_warn "Mock ethtool: unsupported option $2"
            return 1
            ;;
    esac
}

# Mock ip command implementation
mock_ip() {
    case "$1" in
        "link")
            if [[ "$2" == "show" ]]; then
                cat << EOF
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
2: $INTERFACE: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP mode DEFAULT group default qlen 1000
    link/ether 02:00:00:00:00:01 brd ff:ff:ff:ff:ff:ff
EOF
            fi
            ;;
        "addr")
            if [[ "$2" == "show" ]]; then
                cat << EOF
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
2: $INTERFACE: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000
    link/ether 02:00:00:00:00:01 brd ff:ff:ff:ff:ff:ff
    inet 192.168.1.100/24 brd 192.168.1.255 scope global dynamic $INTERFACE
       valid_lft 86400sec preferred_lft 86400sec
EOF
            fi
            ;;
        *)
            log_warn "Mock ip: unsupported command $*"
            return 1
            ;;
    esac
}

# Mock ping implementation
mock_ping() {
    local target="${1:-localhost}"
    local count=4
    
    if [[ "${2:-}" == "-c" ]]; then
        count="${3:-4}"
        shift 2 2>/dev/null || true
    fi
    
    cat << EOF
PING $target (192.168.1.1) 56(84) bytes of data.
64 bytes from 192.168.1.1: icmp_seq=1 ttl=64 time=0.5 ms
64 bytes from 192.168.1.1: icmp_seq=2 ttl=64 time=0.6 ms
64 bytes from 192.168.1.1: icmp_seq=3 ttl=64 time=0.4 ms
64 bytes from 192.168.1.1: icmp_seq=4 ttl=64 time=0.7 ms

--- $target ping statistics ---
$count packets transmitted, $count received, 0% packet loss, time 3003ms
rtt min/avg/max/mdev = 0.4/0.55/0.7/0.1 ms
EOF
}

# Mock iperf3 implementation
mock_iperf3() {
    if [[ "${1:-}" == "-s" ]]; then
        # Server mode - just pretend to listen
        log_info "Mock iperf3 server started"
        sleep 1
    else
        # Client mode
        cat << EOF
Connecting to host 192.168.1.1, port 5201
[  5] local 192.168.1.100 port 54321 connected to 192.168.1.1 port 5201
[ ID] Interval           Transfer     Bitrate         Retr  Cwnd
[  5]   0.00-1.00   sec  11.8 MBytes  98.9 Mbits/sec    0   85.0 KBytes       
[  5]   1.00-2.00   sec  11.2 MBytes  94.2 Mbits/sec    0   85.0 KBytes       
[  5]   2.00-3.00   sec  11.5 MBytes  96.5 Mbits/sec    0   85.0 KBytes       
- - - - - - - - - - - - - - - - - - - - - - - - -
[ ID] Interval           Transfer     Bitrate         Retr
[  5]   0.00-3.00   sec  34.5 MBytes  96.5 Mbits/sec    0             sender
[  5]   0.00-3.03   sec  34.2 MBytes  94.7 Mbits/sec                  receiver

iperf Done.
EOF
    fi
}

# Enhanced link status test with proper validation
test_link_status() {
    log_info "Testing link status..."
    
    local test_name="link_status"
    local env_type
    env_type=$(detect_test_environment)
    
    case "$env_type" in
        "ci")
            # In CI, we expect ethtool to be available
            if ! command -v ethtool &> /dev/null; then
                test_result "$test_name" "FAIL" "- ethtool missing in CI environment"
                return 1
            fi
            
            # Use mock interface in CI
            setup_network_mocks
            test_link_status_with_ethtool "$INTERFACE" "$test_name"
            ;;
            
        "adin2111_hardware"|"hardware")
            # Real hardware testing
            if ! command -v ethtool &> /dev/null; then
                log_warn "ethtool not available - skipping hardware test"
                test_result "$test_name" "SKIP" "- ethtool not available"
                return 0
            fi
            
            test_link_status_with_ethtool "$INTERFACE" "$test_name"
            ;;
            
        "mock")
            # Pure mock environment
            log_info "Using mock environment for link status test"
            setup_network_mocks
            test_link_status_with_ethtool "$INTERFACE" "$test_name"
            ;;
            
        *)
            test_result "$test_name" "ERROR" "- Unknown environment type: $env_type"
            return 1
            ;;
    esac
}

# Actual link status testing logic
test_link_status_with_ethtool() {
    local interface="$1"
    local test_name="$2"
    local link_info
    
    if ! link_info=$(ethtool_wrapper "$interface" 2>/dev/null); then
        test_result "$test_name" "FAIL" "- ethtool command failed on $interface"
        return 1
    fi
    
    # Parse link status
    if echo "$link_info" | grep -q "Link detected: yes"; then
        local speed duplex
        speed=$(echo "$link_info" | grep "Speed:" | awk '{print $2}' || echo "Unknown")
        duplex=$(echo "$link_info" | grep "Duplex:" | awk '{print $2}' || echo "Unknown")
        
        # Validate reasonable values
        if [[ "$speed" != "Unknown" ]] && [[ "$duplex" != "Unknown" ]]; then
            test_result "$test_name" "PASS" "- Link up, Speed: $speed, Duplex: $duplex"
            
            # Additional validation for ADIN2111
            if [[ "$speed" == "100Mb/s" ]] && [[ "$duplex" == "Full" ]]; then
                test_result "link_speed_validation" "PASS" "- ADIN2111 standard speed/duplex"
            else
                test_result "link_speed_validation" "WARN" "- Unexpected speed/duplex: $speed/$duplex"
            fi
        else
            test_result "$test_name" "WARN" "- Link up but speed/duplex unknown"
        fi
    else
        test_result "$test_name" "FAIL" "- Link down"
        return 1
    fi
}

# Enhanced driver info test
test_driver_info() {
    log_info "Testing driver information..."
    
    local test_name="driver_info"
    local env_type
    env_type=$(detect_test_environment)
    
    if [[ "$env_type" == "ci" ]] || [[ "$USE_MOCKS" == "1" ]]; then
        setup_network_mocks
    fi
    
    local driver_info
    if ! driver_info=$(ethtool_wrapper -i "$INTERFACE" 2>/dev/null); then
        if [[ "$env_type" == "ci" ]]; then
            test_result "$test_name" "FAIL" "- ethtool -i failed in CI environment"
            return 1
        else
            test_result "$test_name" "SKIP" "- ethtool not available"
            return 0
        fi
    fi
    
    # Validate driver information
    local driver_name
    driver_name=$(echo "$driver_info" | grep "driver:" | awk '{print $2}')
    
    if [[ "$driver_name" == "adin2111" ]]; then
        test_result "$test_name" "PASS" "- ADIN2111 driver detected"
        
        # Extract and validate version
        local version
        version=$(echo "$driver_info" | grep "version:" | awk '{print $2}')
        if [[ -n "$version" ]] && [[ "$version" != "N/A" ]]; then
            test_result "driver_version" "PASS" "- Driver version: $version"
        else
            test_result "driver_version" "WARN" "- Driver version not available"
        fi
        
    elif [[ "$USE_MOCKS" == "1" ]]; then
        test_result "$test_name" "PASS" "- Mock driver test completed"
    else
        test_result "$test_name" "FAIL" "- Expected adin2111 driver, got: $driver_name"
        return 1
    fi
}

# Enhanced network connectivity test
test_network_connectivity() {
    log_info "Testing network connectivity..."
    
    local test_name="network_connectivity"
    local env_type
    env_type=$(detect_test_environment)
    
    if [[ "$env_type" == "mock" ]] || [[ "$USE_MOCKS" == "1" ]]; then
        setup_network_mocks
    fi
    
    # Test basic connectivity (gateway)
    local gateway
    gateway=$(ip_wrapper route | grep default | awk '{print $3}' | head -1)
    
    if [[ -z "$gateway" ]]; then
        if [[ "$USE_MOCKS" == "1" ]]; then
            gateway="192.168.1.1"  # Mock gateway
        else
            test_result "$test_name" "SKIP" "- No default gateway found"
            return 0
        fi
    fi
    
    log_info "Testing connectivity to gateway: $gateway"
    
    # Ping test with timeout
    if ping_wrapper -c 3 -W 2 "$gateway" &> /dev/null; then
        test_result "$test_name" "PASS" "- Connectivity to $gateway successful"
        
        # Additional latency test
        local ping_output
        ping_output=$(ping_wrapper -c 10 -i 0.1 "$gateway" 2>/dev/null || echo "")
        
        if [[ -n "$ping_output" ]]; then
            local avg_latency
            avg_latency=$(echo "$ping_output" | tail -1 | awk -F'/' '{print $5}' | cut -d' ' -f1)
            
            if [[ -n "$avg_latency" ]] && (( $(echo "$avg_latency < 10" | bc -l) )); then
                test_result "network_latency" "PASS" "- Average latency: ${avg_latency}ms"
            else
                test_result "network_latency" "WARN" "- High latency: ${avg_latency}ms"
            fi
        fi
        
    else
        if [[ "$USE_MOCKS" == "1" ]]; then
            test_result "$test_name" "FAIL" "- Mock connectivity test failed"
        else
            test_result "$test_name" "FAIL" "- No connectivity to $gateway"
        fi
        return 1
    fi
}

# Enhanced interface statistics test
test_interface_statistics() {
    log_info "Testing interface statistics..."
    
    local test_name="interface_statistics"
    local env_type
    env_type=$(detect_test_environment)
    
    if [[ "$env_type" == "mock" ]] || [[ "$USE_MOCKS" == "1" ]]; then
        setup_network_mocks
    fi
    
    # Get initial statistics
    local stats_before stats_after
    
    if command -v ethtool &> /dev/null || [[ "$USE_MOCKS" == "1" ]]; then
        stats_before=$(ethtool_wrapper -S "$INTERFACE" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$stats_before" ]]; then
        # Fallback to /proc/net/dev
        if [[ -f "/proc/net/dev" ]]; then
            stats_before=$(grep "$INTERFACE" /proc/net/dev || echo "")
        fi
    fi
    
    if [[ -z "$stats_before" ]] && [[ "$USE_MOCKS" != "1" ]]; then
        test_result "$test_name" "SKIP" "- Cannot access interface statistics"
        return 0
    fi
    
    # Generate some traffic if possible
    if [[ "$USE_MOCKS" == "1" ]]; then
        # Mock traffic generation
        log_info "Simulating network traffic..."
        sleep 1
    else
        # Real traffic generation
        local gateway
        gateway=$(ip_wrapper route | grep default | awk '{print $3}' | head -1)
        if [[ -n "$gateway" ]]; then
            ping_wrapper -c 5 -i 0.2 "$gateway" &> /dev/null || true
        fi
    fi
    
    # Get final statistics
    if command -v ethtool &> /dev/null || [[ "$USE_MOCKS" == "1" ]]; then
        stats_after=$(ethtool_wrapper -S "$INTERFACE" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$stats_after" ]]; then
        stats_after=$(grep "$INTERFACE" /proc/net/dev 2>/dev/null || echo "")
    fi
    
    # Validate statistics changed (indicating traffic)
    if [[ -n "$stats_before" ]] && [[ -n "$stats_after" ]]; then
        if [[ "$stats_before" != "$stats_after" ]]; then
            test_result "$test_name" "PASS" "- Interface statistics changing (traffic detected)"
        else
            test_result "$test_name" "WARN" "- No traffic detected during test"
        fi
    else
        test_result "$test_name" "SKIP" "- Unable to compare statistics"
    fi
}

# Utility function to attempt ethtool installation
install_ethtool_if_possible() {
    if command -v apt-get &> /dev/null; then
        if sudo apt-get update && sudo apt-get install -y ethtool; then
            return 0
        fi
    elif command -v yum &> /dev/null; then
        if sudo yum install -y ethtool; then
            return 0
        fi
    elif command -v dnf &> /dev/null; then
        if sudo dnf install -y ethtool; then
            return 0
        fi
    fi
    
    return 1
}

# Main test execution
main() {
    log_info "Starting ADIN2111 Basic Tests (Fixed Implementation)"
    log_info "Interface: $INTERFACE"
    log_info "Test Environment: $TEST_ENVIRONMENT"
    
    # Detect environment
    local env_type
    env_type=$(detect_test_environment)
    log_info "Detected environment: $env_type"
    
    # Initialize test framework
    test_framework_init
    
    # Run tests
    test_link_status
    test_driver_info
    test_network_connectivity
    test_interface_statistics
    
    # Print summary
    test_framework_summary
    
    return $?
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
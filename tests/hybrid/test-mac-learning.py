#!/usr/bin/env python3
"""
MAC Learning Table Test
Tests that the driver correctly learns MAC addresses and forwards unicast traffic
"""

import subprocess
import time
import sys
import os

# Add scapy to path if needed
try:
    from scapy.all import *
except ImportError:
    print("Installing scapy...")
    subprocess.run([sys.executable, "-m", "pip", "install", "scapy"])
    from scapy.all import *

def run_in_namespace(namespace, command):
    """Execute command in network namespace"""
    cmd = f"sudo ip netns exec {namespace} {command}"
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def send_packet_from_namespace(namespace, src_mac, dst_mac, src_ip, dst_ip, data):
    """Send a packet from a specific namespace"""
    script = f"""
import sys
sys.path.append('/usr/local/lib/python3.10/dist-packages')
from scapy.all import *
pkt = Ether(src='{src_mac}', dst='{dst_mac}') / IP(src='{src_ip}', dst='{dst_ip}') / UDP(dport=9999) / Raw(b'{data}')
sendp(pkt, iface='veth0' if '{namespace}' == 'phy0' else 'veth1', verbose=0)
"""
    cmd = f"sudo ip netns exec {namespace} python3 -c \"{script}\""
    subprocess.run(cmd, shell=True)

def capture_packets(namespace, count=1, timeout=5):
    """Capture packets in namespace"""
    iface = 'veth0' if namespace == 'phy0' else 'veth1'
    cmd = f"timeout {timeout} sudo ip netns exec {namespace} tcpdump -i {iface} -c {count} -n udp port 9999 2>/dev/null"
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return result.stdout

def test_mac_learning():
    """Test MAC learning and forwarding"""
    print("=== MAC Learning Table Test ===")
    
    results = []
    
    # Test 1: Broadcast from PHY0 should reach PHY1
    print("\n1. Testing broadcast forwarding...")
    send_packet_from_namespace('phy0', 
                              '02:00:00:00:00:01',  # src MAC
                              'ff:ff:ff:ff:ff:ff',  # broadcast
                              '192.168.100.10',
                              '192.168.100.255',
                              'broadcast_test')
    
    time.sleep(1)
    capture = capture_packets('phy1', count=1, timeout=2)
    
    if '9999' in capture and 'broadcast_test' in capture:
        print("✓ Broadcast forwarding works")
        results.append(True)
    else:
        print("✗ Broadcast forwarding failed")
        results.append(False)
    
    # Test 2: Learn MAC on PHY0, then send unicast from PHY1
    print("\n2. Testing MAC learning...")
    
    # Send packet from PHY0 to learn its MAC
    send_packet_from_namespace('phy0',
                              '02:00:00:00:00:01',  # MAC to learn
                              'ff:ff:ff:ff:ff:ff',
                              '192.168.100.10',
                              '192.168.100.255',
                              'learn_mac')
    time.sleep(1)
    
    # Now send unicast from PHY1 to learned MAC
    send_packet_from_namespace('phy1',
                              '02:00:00:00:00:02',
                              '02:00:00:00:00:01',  # To learned MAC
                              '192.168.100.20',
                              '192.168.100.10',
                              'unicast_to_learned')
    
    time.sleep(1)
    capture = capture_packets('phy0', count=1, timeout=2)
    
    if '9999' in capture and 'unicast_to_learned' in capture:
        print("✓ MAC learning and unicast forwarding works")
        results.append(True)
    else:
        print("✗ MAC learning or unicast forwarding failed")
        results.append(False)
    
    # Test 3: Unknown unicast should be flooded
    print("\n3. Testing unknown unicast flooding...")
    
    # Send to unknown MAC
    send_packet_from_namespace('phy0',
                              '02:00:00:00:00:03',
                              '02:00:00:00:99:99',  # Unknown MAC
                              '192.168.100.10',
                              '192.168.100.30',
                              'unknown_unicast')
    
    time.sleep(1)
    capture = capture_packets('phy1', count=1, timeout=2)
    
    if '9999' in capture:
        print("✓ Unknown unicast flooding works")
        results.append(True)
    else:
        print("✗ Unknown unicast flooding failed")
        results.append(False)
    
    # Report results
    print("\n" + "="*40)
    passed = sum(results)
    total = len(results)
    print(f"Results: {passed}/{total} tests passed")
    
    if passed == total:
        print("Test Result: PASS")
        return 0
    else:
        print("Test Result: FAIL")
        return 1

if __name__ == "__main__":
    # Check if running in QEMU environment
    if not os.path.exists('/sys/class/net/eth0'):
        print("Error: eth0 not found. Is the driver loaded?")
        sys.exit(1)
    
    # Check if namespaces exist
    result = subprocess.run("ip netns list", shell=True, capture_output=True, text=True)
    if 'phy0' not in result.stdout or 'phy1' not in result.stdout:
        print("Error: Network namespaces phy0/phy1 not found")
        print("Run ./scripts/launch-qemu-hybrid.sh to set up the environment")
        sys.exit(1)
    
    sys.exit(test_mac_learning())
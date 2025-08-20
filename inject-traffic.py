#!/usr/bin/env python3
"""
UDP packet injector for testing ADIN2111 autonomous switching
Sends raw Ethernet frames to QEMU socket netdev
"""

import socket
import struct
import sys
import time

def create_ethernet_frame(src_mac="52:54:00:12:34:56", 
                          dst_mac="52:54:00:65:43:21",
                          ethertype=0x0800,
                          payload=b"TEST PACKET"):
    """Create a raw Ethernet frame"""
    # Convert MAC addresses to bytes
    src = bytes.fromhex(src_mac.replace(":", ""))
    dst = bytes.fromhex(dst_mac.replace(":", ""))
    
    # Build frame: dst_mac(6) + src_mac(6) + ethertype(2) + payload
    frame = dst + src + struct.pack("!H", ethertype) + payload
    
    # Pad to minimum Ethernet frame size (64 bytes including CRC)
    # We send 60 bytes, assuming 4-byte CRC added by hardware
    if len(frame) < 60:
        frame += b'\x00' * (60 - len(frame))
    
    return frame

def send_to_qemu_socket(frame, host="127.0.0.1", port=10001):
    """Send frame to QEMU socket netdev"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.sendto(frame, (host, port))
    sock.close()
    print(f"Sent {len(frame)} bytes to {host}:{port}")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        port = int(sys.argv[1])
    else:
        port = 10001  # Default to p0 ingress
    
    print(f"=== ADIN2111 Traffic Injector ===")
    print(f"Sending to UDP port {port} (QEMU socket netdev)")
    
    # Send test frames
    for i in range(3):
        frame = create_ethernet_frame(
            src_mac=f"02:00:00:00:00:{i:02x}",
            dst_mac="ff:ff:ff:ff:ff:ff",  # Broadcast
            payload=f"AUTONOMOUS TEST {i}".encode()
        )
        send_to_qemu_socket(frame, port=port)
        time.sleep(0.5)
    
    print("Done - check p0.pcap and p1.pcap for forwarding proof")
# ADIN2111 Driver Theory of Operation

## Table of Contents
1. [Overview](#overview)
2. [Hardware Architecture](#hardware-architecture)
3. [Driver Architecture](#driver-architecture)
4. [SPI Communication Protocol](#spi-communication-protocol)
5. [Operating Modes](#operating-modes)
6. [Data Flow](#data-flow)
7. [Initialization Sequence](#initialization-sequence)
8. [Packet Transmission](#packet-transmission)
9. [Packet Reception](#packet-reception)
10. [MAC Learning and Forwarding](#mac-learning-and-forwarding)
11. [Interrupt Handling](#interrupt-handling)
12. [Link Management](#link-management)

## Overview

The ADIN2111 is a dual-port 10BASE-T1L Ethernet switch with an SPI host interface. This driver implements a Linux network driver that can operate the device in two modes:
- **Dual Interface Mode**: Each port appears as a separate network interface (eth0, eth1)
- **Single Interface Mode**: Both ports operate as a unified switch with one network interface

## Hardware Architecture

```mermaid
graph TB
    subgraph Host[Host Processor - STM32MP153]
        CPU[ARM Cortex-A7 CPU]
        KERNEL[Linux Kernel 6.6.48]
        DRIVER[ADIN2111 Driver]
    end
    
    subgraph Chip[ADIN2111 Chip]
        SPI_IF[SPI Interface]
        MAC[Ethernet MAC]
        SWITCH[Switch Fabric]
        PORT1[PHY Port 1]
        PORT2[PHY Port 2]
        TXFIFO[TX FIFO<br/>2KB]
        RXFIFO[RX FIFO<br/>2KB]
        REGS[Control Registers]
    end
    
    subgraph Physical[Physical Layer]
        T1L1[10BASE-T1L Cable 1]
        T1L2[10BASE-T1L Cable 2]
    end
    
    DRIVER -->|SPI Bus<br/>24.5MHz Max| SPI_IF
    SPI_IF --> REGS
    SPI_IF --> TXFIFO
    RXFIFO --> SPI_IF
    
    REGS --> MAC
    MAC --> SWITCH
    
    SWITCH --> PORT1
    SWITCH --> PORT2
    
    TXFIFO --> SWITCH
    SWITCH --> RXFIFO
    
    PORT1 --> T1L1
    PORT2 --> T1L2
    
    SPI_IF -->|INT line| DRIVER
```

### Key Hardware Components

| Component | Description | Details |
|-----------|-------------|---------|
| SPI Interface | Host communication | Up to 24.5 MHz, supports optional CRC |
| TX FIFO | Transmit buffer | 2KB, register 0x31 |
| RX FIFO | Receive buffer | 2KB, register 0x91 |
| Switch Fabric | L2 switching logic | Hardware cut-through forwarding |
| PHY Ports | Physical layer interfaces | 10BASE-T1L, up to 1700m reach |
| MAC Table | Address learning | 256 entries, 5-minute aging |

## Driver Architecture

```mermaid
classDiagram
    class adin1110_priv {
        +struct spi_device *spidev
        +struct mutex lock
        +struct sk_buff_head txq
        +u32 tx_space
        +bool single_interface_mode
        +bool hardware_forwarding
        +struct adin1110_port_priv *ports[]
    }
    
    class adin1110_port_priv {
        +struct net_device *netdev
        +struct phy_device *phydev
        +struct work_struct tx_work
        +u32 flags
        +u64 rx_bytes
        +u64 tx_bytes
    }
    
    class net_device {
        <<kernel structure>>
        +netdev_ops
        +ethtool_ops
        +dev_addr[]
    }
    
    class phy_device {
        <<kernel structure>>
        +link status
        +speed/duplex
        +autoneg
    }
    
    adin1110_priv "1" --> "1..2" adin1110_port_priv
    adin1110_port_priv --> net_device
    adin1110_port_priv --> phy_device
```

## SPI Communication Protocol

The ADIN2111 uses a specific SPI protocol format:

```mermaid
sequenceDiagram
    participant Host
    participant ADIN2111
    
    Note over Host,ADIN2111: Register Read Operation
    Host->>ADIN2111: Command Byte (0x80 | reg_addr)
    Host->>ADIN2111: Turn-Around Byte (0x00)
    ADIN2111->>Host: Register Value (32-bit)
    Host->>ADIN2111: CRC (optional)
    
    Note over Host,ADIN2111: Register Write Operation
    Host->>ADIN2111: Command Byte (reg_addr)
    Host->>ADIN2111: Register Value (32-bit)
    Host->>ADIN2111: CRC (optional)
    
    Note over Host,ADIN2111: TX FIFO Write
    Host->>ADIN2111: Write TX_FSIZE register
    Host->>ADIN2111: Command Byte (0xA0)
    Host->>ADIN2111: Frame Header (16-bit)
    Host->>ADIN2111: Ethernet Frame Data
    Host->>ADIN2111: Padding to 64-byte min
```

### SPI Transaction Format

| Field | Size | Description |
|-------|------|-------------|
| Command Byte | 1 byte | Bit 7: R/W, Bits 6-0: Address |
| Turn-Around | 1 byte | Only for reads (0x00) |
| Data | 4 bytes | Register value (BE) |
| CRC | 1 byte | Optional, if enabled |

## Operating Modes

### Dual Interface Mode (Default)

```mermaid
graph LR
    subgraph NetworkStack[Linux Network Stack]
        ETH0[eth0 interface]
        ETH1[eth1 interface]
    end
    
    subgraph Driver[ADIN2111 Driver]
        PORT0[Port 0 Handler]
        PORT1[Port 1 Handler]
    end
    
    subgraph Hardware1[Hardware]
        PHY0[PHY Port 1]
        PHY1[PHY Port 2]
    end
    
    ETH0 --> PORT0
    ETH1 --> PORT1
    PORT0 --> PHY0
    PORT1 --> PHY1
```

### Single Interface Mode

```mermaid
graph LR
    subgraph NetworkStack2[Linux Network Stack]
        ETH0[eth0 interface<br/>Single unified interface]
    end
    
    subgraph Driver2[ADIN2111 Driver]
        HANDLER[Unified Port Handler]
        FORWARD[MAC Learning Table]
    end
    
    subgraph Hardware2[Hardware]
        SWITCH[Hardware Switch]
        PHY0[PHY Port 1]
        PHY1[PHY Port 2]
    end
    
    ETH0 --> HANDLER
    HANDLER --> FORWARD
    FORWARD --> SWITCH
    SWITCH --> PHY0
    SWITCH --> PHY1
    
    PHY0 -->|Cut-through| PHY1
```

## Data Flow

### Overall Packet Flow

```mermaid
flowchart TB
    subgraph TX[Transmit Path]
        APP[Application] -->|send| SOCKET[Socket Layer]
        SOCKET --> IP[IP Stack]
        IP --> NETDEV[Network Device]
        NETDEV -->|ndo_start_xmit| DRIVER_TX[Driver TX Handler]
        DRIVER_TX -->|Queue SKB| TXQ[TX Queue]
        TXQ -->|Work Queue| TX_WORK[tx_work handler]
        TX_WORK -->|SPI Write| TX_FIFO[TX FIFO]
        TX_FIFO --> WIRE_TX[Physical Wire]
    end
    
    subgraph RX[Receive Path]
        WIRE_RX[Physical Wire] --> RX_FIFO[RX FIFO]
        RX_FIFO -->|Interrupt| IRQ[IRQ Handler]
        IRQ -->|SPI Read| DRIVER_RX[Driver RX Handler]
        DRIVER_RX -->|alloc_skb| SKB[Socket Buffer]
        SKB -->|netif_rx| NETSTACK[Network Stack]
        NETSTACK --> APP2[Application]
    end
```

## Initialization Sequence

```mermaid
stateDiagram-v2
    [*] --> ProbeStart: SPI Probe
    
    ProbeStart --> AllocMemory: Allocate Private Data
    AllocMemory --> InitSPI: Configure SPI
    InitSPI --> HWReset: Hardware Reset (GPIO)
    
    HWReset --> PollReady: Poll Device Ready
    PollReady --> CheckID: Read Device ID
    
    CheckID --> IDValid: ID == 0x0283?
    CheckID --> IDInvalid: ID != 0x0283
    
    IDValid --> SWReset: Software Reset
    SWReset --> PollReady2: Poll Ready Again
    PollReady2 --> Configure: Configure Device
    
    Configure --> SingleMode: single_interface_mode?
    Configure --> DualMode: dual interface mode
    
    SingleMode --> EnableForward: Enable HW Forwarding
    EnableForward --> RegisterNet1: Register Single netdev
    
    DualMode --> RegisterNet2: Register Two netdevs
    
    RegisterNet1 --> SetupPHY: Setup PHY
    RegisterNet2 --> SetupPHY
    
    SetupPHY --> RegisterIRQ: Register IRQ Handler
    RegisterIRQ --> Success: Probe Complete
    
    IDInvalid --> Fail: Probe Failed
    
    Success --> [*]
    Fail --> [*]
```

### Device Ready Polling Algorithm

```mermaid
flowchart TB
    START[Reset Device] --> WAIT[Wait 10ms]
    WAIT --> READ[Read Device ID Register]
    READ --> CHECK{ID == 0x0283?}
    CHECK -->|Yes| READY[Device Ready]
    CHECK -->|No| COUNT{Attempts < 20?}
    COUNT -->|Yes| WAIT
    COUNT -->|No| TIMEOUT[Timeout Error]
    READY --> LOG[Log ready time]
    LOG --> CONTINUE[Continue Init]
    TIMEOUT --> FAIL[Return -ETIMEDOUT]
```

## Packet Transmission

### TX Path in Single Interface Mode

```mermaid
flowchart TB
    START[ndo_start_xmit] --> GETDEST[Extract Dest MAC]
    GETDEST --> ISMCAST{Is Multicast?}
    
    ISMCAST -->|Yes| FLOOD[Set port_bits = 0x3<br/>Send to both ports]
    ISMCAST -->|No| LOOKUP[MAC Table Lookup]
    
    LOOKUP --> FOUND{Entry Found?}
    FOUND -->|Yes| SPECIFIC[Set port_bits per table]
    FOUND -->|No| FLOOD2[Set port_bits = 0x3<br/>Flood to both]
    
    FLOOD --> HEADER[Build Frame Header]
    SPECIFIC --> HEADER
    FLOOD2 --> HEADER
    
    HEADER --> FORMAT[Header Format:<br/>Bits 13:12 = port_bits<br/>Bits 11:0 = frame_len]
    
    FORMAT --> QUEUE[Queue to txq]
    QUEUE --> SCHEDULE[Schedule tx_work]
    SCHEDULE --> WORK[tx_work handler]
    
    WORK --> WRITESIZE[Write TX_FSIZE]
    WRITESIZE --> WRITECMD[Send SPI Command 0xA0]
    WRITECMD --> WRITEHEADER[Write Frame Header]
    WRITEHEADER --> WRITEDATA[Write Ethernet Data]
    WRITEDATA --> PAD[Pad to 64 bytes min]
    PAD --> DONE[TX Complete]
```

### Frame Header Format

```
Bit Position:  15  14  13  12  11  10  9  8  7  6  5  4  3  2  1  0
              +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
Frame Header: | 0 | 0 | P1| P0|            Frame Length (bytes)              |
              +---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+

P1:P0 Port Selection:
- 00: No ports (invalid)
- 01: Port 1 only
- 10: Port 2 only  
- 11: Both ports (flooding/multicast)
```

## Packet Reception

### RX Interrupt Flow

```mermaid
flowchart TB
    IRQ[Hardware Interrupt] --> READ_STATUS[Read STATUS1 Register]
    READ_STATUS --> CHECK{RX_RDY set?}
    
    CHECK -->|No| EXIT[Exit ISR]
    CHECK -->|Yes| LOOP[For each port]
    
    LOOP --> READ_SIZE[Read RX_FSIZE]
    READ_SIZE --> VALID{Size > 0?}
    
    VALID -->|No| NEXT[Next Port]
    VALID -->|Yes| ALLOC[Allocate SKB]
    
    ALLOC --> READ_FIFO[Read from RX FIFO]
    READ_FIFO --> PARSE[Parse Frame Header]
    
    PARSE --> EXTRACT[Extract Port Info]
    EXTRACT --> COPY[Copy to SKB]
    
    COPY --> SETPROT[eth_type_trans]
    SETPROT --> DELIVER[netif_rx]
    
    DELIVER --> STATS[Update Statistics]
    STATS --> NEXT
    
    NEXT --> MORE{More Ports?}
    MORE -->|Yes| LOOP
    MORE -->|No| CLEAR[Clear Interrupt]
    CLEAR --> EXIT
```

## MAC Learning and Forwarding

### MAC Learning Table Implementation

```mermaid
classDiagram
    class MacEntry {
        +u8 mac[6]
        +u8 port_mask
        +unsigned long last_seen
        +struct hlist_node node
    }
    
    class MacTable {
        +DECLARE_HASHTABLE(entries, 8)
        +spinlock_t lock
        +struct timer_list age_timer
        +learn_mac()
        +lookup_mac()
        +age_entries()
    }
    
    MacTable "1" --> "0..256" MacEntry : contains
```

### MAC Learning Algorithm

```mermaid
flowchart TB
    RX[Frame Received] --> EXTRACT[Extract Source MAC and Port]
    EXTRACT --> HASH[Calculate Hash<br/>jhash - mac addr - 6 bytes]
    HASH --> LOOKUP[Lookup in Table]
    
    LOOKUP --> EXISTS{Entry Exists?}
    EXISTS -->|Yes| UPDATE[Update port_mask<br/>Update last_seen]
    EXISTS -->|No| FULL{Table Full?}
    
    FULL -->|Yes| EVICT[Find Oldest Entry]
    FULL -->|No| ADD[Add New Entry]
    
    EVICT --> REPLACE[Replace with New]
    ADD --> DONE[Learning Complete]
    UPDATE --> DONE
    REPLACE --> DONE
```

### Forwarding Decision

```mermaid
flowchart TB
    TX[Frame to Transmit] --> DEST[Destination MAC]
    DEST --> BCAST{Broadcast?}
    
    BCAST -->|Yes| FLOOD_BC[Forward to All Ports]
    BCAST -->|No| MCAST{Multicast?}
    
    MCAST -->|Yes| FLOOD_MC[Forward to All Ports]
    MCAST -->|No| UNICAST[Lookup MAC Table]
    
    UNICAST --> FOUND{Entry Found?}
    FOUND -->|Yes| CHECK_AGE{Entry Fresh?}
    FOUND -->|No| FLOOD_UNK[Flood Unknown]
    
    CHECK_AGE -->|Yes| FORWARD[Forward to Ports]
    CHECK_AGE -->|No| FLOOD_AGED[Flood Aged Out]
    
    FLOOD_BC --> SEND[Send Frame]
    FLOOD_MC --> SEND
    FLOOD_UNK --> SEND
    FLOOD_AGED --> SEND
    FORWARD --> SEND
```

## Interrupt Handling

### Interrupt Sources and Processing

```mermaid
stateDiagram-v2
    [*] --> Idle: No Activity
    
    Idle --> IRQ_Assert: Event Occurs
    IRQ_Assert --> Read_Status: Read STATUS1 Reg
    
    Read_Status --> Check_P1_RX: P1_RX_RDY?
    Check_P1_RX --> Process_P1_RX: Yes
    Check_P1_RX --> Check_P2_RX: No
    
    Process_P1_RX --> Check_P2_RX: Done
    
    Check_P2_RX --> Process_P2_RX: P2_RX_RDY?
    Check_P2_RX --> Check_TX: No
    Process_P2_RX --> Check_TX: Done
    
    Check_TX --> Process_TX: TX_RDY?
    Check_TX --> Check_Link: No
    Process_TX --> Check_Link: Done
    
    Check_Link --> Process_Link: LINK_CHANGE?
    Check_Link --> Clear_IRQ: No
    Process_Link --> Clear_IRQ: Done
    
    Clear_IRQ --> Write_Status: Write STATUS1
    Write_Status --> Idle: Complete
```

### Interrupt Status Register (STATUS1)

| Bit | Name | Description |
|-----|------|-------------|
| 0 | P1_RX_RDY | Port 1 RX FIFO has data |
| 1 | P2_RX_RDY | Port 2 RX FIFO has data |
| 2 | TX_RDY | TX FIFO space available |
| 3 | LINK_CHANGE | PHY link status changed |
| 4 | P1_PHYINT | Port 1 PHY interrupt |
| 5 | P2_PHYINT | Port 2 PHY interrupt |
| 6 | TX_ERR | Transmit error occurred |
| 7 | RX_ERR | Receive error occurred |

## Link Management

### PHY Link State Machine

```mermaid
stateDiagram-v2
    [*] --> Down: Initial State
    
    Down --> Detecting: Cable Connected
    Detecting --> Autoneg: Start Autoneg
    
    Autoneg --> WaitAN: Negotiating
    WaitAN --> CheckAN: Check Status
    
    CheckAN --> Complete: Success
    CheckAN --> Failed: Timeout
    
    Complete --> Up: Link Established
    Failed --> Down: Retry
    
    Up --> Monitor: Monitor Link
    Monitor --> Up: Link OK
    Monitor --> Down: Link Lost
    
    Down --> [*]: Cable Disconnected
```

### Link Status Processing

```mermaid
flowchart TB
    PHYINT[PHY Interrupt] --> READ[Read PHY Status]
    READ --> CHANGED{Link Changed?}
    
    CHANGED -->|No| EXIT[Exit]
    CHANGED -->|Yes| ISUP{Link Up?}
    
    ISUP -->|Yes| GETSPEED[Read Speed/Duplex]
    ISUP -->|No| LINKDOWN[Process Link Down]
    
    GETSPEED --> UPDATE[Update carrier_on]
    UPDATE --> PRINT[phy_print_status]
    
    LINKDOWN --> CARRIER[netif_carrier_off]
    CARRIER --> STOP[Stop TX Queue]
    
    PRINT --> LOG[Log Status]
    STOP --> LOG
    LOG --> EXIT
```

## Performance Optimizations

### Hardware Cut-Through Forwarding

When enabled in single interface mode, the ADIN2111 can forward frames between ports without CPU intervention:

```mermaid
graph LR
    subgraph NoCutThrough[Without Cut-Through]
        RX1[RX Port 1] --> CPU1[CPU Processing]
        CPU1 --> TX2[TX Port 2]
    end
    
    subgraph WithCutThrough[With Cut-Through]
        RX1B[RX Port 1] --> HW[Hardware Forward]
        HW --> TX2B[TX Port 2]
        HW -->|Copy to| CPU2[CPU Monitor]
    end
```

### TX Queue Management

```mermaid
flowchart TB
    XMIT[ndo_start_xmit] --> CHECK{TX Space?}
    CHECK -->|Yes| QUEUE[Add to txq]
    CHECK -->|No| STOP[netif_stop_queue]
    
    QUEUE --> WORK[Schedule Work]
    STOP --> DROP[Return BUSY]
    
    WORK --> SEND[Send via SPI]
    SEND --> UPDATE[Update tx_space]
    UPDATE --> SPACE{Space > threshold?}
    
    SPACE -->|Yes| WAKE[netif_wake_queue]
    SPACE -->|No| WAIT[Wait for TX_RDY]
    
    WAIT --> IRQ[TX_RDY Interrupt]
    IRQ --> WAKE
```

## Error Handling

### Error Recovery State Machine

```mermaid
stateDiagram-v2
    [*] --> Normal: Operating
    
    Normal --> Error: Error Detected
    Error --> Identify: Log Error Type
    
    Identify --> SPI_Err: SPI Error
    Identify --> CRC_Err: CRC Error
    Identify --> FIFO_Err: FIFO Overflow
    
    SPI_Err --> Reset_SPI: Reset SPI
    CRC_Err --> Retry: Retry Operation
    FIFO_Err --> Clear_FIFO: Clear FIFOs
    
    Reset_SPI --> Recover
    Retry --> Check: Success?
    Clear_FIFO --> Recover
    
    Check --> Recover: No
    Check --> Normal: Yes
    
    Recover --> SW_Reset: Software Reset
    SW_Reset --> Reinit: Reinitialize
    Reinit --> Normal: Complete
```

## Module Parameters

### Configuration Flow

```mermaid
flowchart TB
    MODULE[Module Load] --> PARAMS[Read Parameters]
    PARAMS --> SINGLE{single_interface_mode?}
    
    SINGLE -->|Yes| SMODE[Single Mode Setup]
    SINGLE -->|No| DMODE[Dual Mode Setup]
    
    SMODE --> HWF{hardware_forwarding?}
    HWF -->|Yes| ENABLE[Enable Cut-Through]
    HWF -->|No| DISABLE[Software Forwarding]
    
    ENABLE --> CONFIG[Write CONFIG Registers]
    DISABLE --> CONFIG
    DMODE --> CONFIG
    
    CONFIG --> DONE[Configuration Complete]
```

## Summary

The ADIN2111 driver implements a complete Linux network driver for a dual-port 10BASE-T1L Ethernet switch. Key features include:

1. **Flexible Operation**: Supports both dual interface and single interface modes
2. **Hardware Acceleration**: Leverages hardware cut-through forwarding
3. **Robust Communication**: Implements proper SPI protocol with CRC support
4. **Intelligent Reset**: Polls for device readiness instead of fixed delays
5. **MAC Learning**: Software-based MAC table for intelligent forwarding
6. **Error Recovery**: Comprehensive error handling and recovery mechanisms
7. **Performance Optimized**: Minimizes CPU overhead through hardware features

The driver bridges the gap between the Linux network stack and the ADIN2111 hardware, providing a reliable and efficient networking solution for industrial and automotive applications requiring long-reach Ethernet connectivity.

---
*Theory of Operation v1.0 - August 2025*  
*Authors: Alexandru Tachici (ADI), Murray Kopit*
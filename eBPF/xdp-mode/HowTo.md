# HOWTO: XDP Probing & Live Packet Monitoring with Aya

xdp-mode` probes network interface drivers to discover the strongest supported **eBPF XDP (eXtress Data Path)** mode, 
attaches at that execution hook, and captures live packet metrics.

---

## 1. XDP Execution Architecture & Hook Points

The eBPF program source remains identical regardless of configuration, the kernel hook point where the
bytecode executes changes fundamentally based on the attached `XdpMode`.

```text
[ Incoming Frame from Wire / PHY ]
               │
               ▼
   ┌───────────────────────┐
   │ 1. Hardware / SmartNIC│  <─── XdpMode::Offload
   │    (eBPF on ASIC/NPU) │      (Processed before system RAM/CPU)
   └───────────┬───────────┘
               │ (DMA to Host RAM)
               ▼
   ┌───────────────────────┐
   │ 2. NIC Driver Ring    │  <─── XdpMode::Driver (Native)
   │    (RX Clean Loop)    │      (Processed before sk_buff allocation)
   └───────────┬───────────┘
               │ (Allocates sk_buff metadata)
               ▼
   ┌───────────────────────┐
   │ 3. Linux Network Core │  <─── XdpMode::Skb (Generic)
   │    (netif_receive_skb)│      (Processed after SKB creation)
   └───────────┬───────────┘
               │
               ▼
   [ TC ingress / IP Stack / Sockets ]

```

---

## 2. XDP Modes Comparison

The program probes these three modes sequentially in order of performance priority: **Offload → Driver (Native) → Skb (Generic)**.

| Trait | `XdpMode::Offload` | `XdpMode::Driver` (Native) | `XdpMode::Skb` (Generic) |
| --- | --- | --- | --- |
| **Hook Location** | **Network Interface Card (NIC) NPU/ASIC** | **NIC Driver's RX Ring Buffer** | **Kernel Network Core (`netif_receive_skb`)** |
| **Host Resource Cost** | **Zero Host CPU**; executes in SmartNIC hardware memory. | Extremely low; operates on raw DMA descriptors. | Higher; consumes host CPU cycles & allocates `sk_buff` structs. |
| **Execution Point** | Before DMA transfer to Host RAM. | After DMA transfer, **before `sk_buff` allocation**. | **After `sk_buff` allocation** and network stack setup. |
| **Hardware Requirements** | Dedicated SmartNIC (e.g., Netronome, AMD Pensando, Mellanox Cx6). | Driver must support `XDP` / `ndo_bpf` operations. | Works on **any** network driver (generic fallback). |
| **Netlink Flag** | `XDP_FLAGS_HW_MODE` | `XDP_FLAGS_DRV_MODE` | `XDP_FLAGS_SKB_MODE` |

---

## 3. How Aya Handles Attachment Internally

`aya` handles the kernel setup as follows:

1. Translates `XdpMode` (`Offload`, `Driver`, or `Skb`) into low-level Netlink flags.
2. Issues an `RTM_SETLINK` command via Netlink to the Linux kernel containing the interface index
   (`ifindex`) and program File Descriptor (FD).
3. The kernel negotiates with the network driver:
* **Offload:** Offloads bytecode to the SmartNIC JIT compiler.
* **Driver:** Attaches directly to the driver's RX polling loop (`ndo_bpf`).
* **Skb:** Binds to generic socket buffer hooks in the core Linux network stack.

i.e 
`program.attach_to_iface("eth0", mode)` in Aya: 

translates the `XdpMode` to Netlink Kernel Flags:
    - XdpMode::Offload → XDP_FLAGS_HW_MODE
    - XdpMode::Driver → XDP_FLAGS_DRV_MODE
    - XdpMode::Skb → XDP_FLAGS_SKB_MODE

Aya sends a Netlink command (RTM_SETLINK) to the kernel containing the interface index (ifindex) and the
loaded eBPF program File Descriptor (FD).

- Offload: Kernel passes the eBPF bytecode to the NIC's vendor driver, which JIT-compiles it into 
           machine code directly executable by the SmartNIC's NPU processors.

- Driver: Kernel binds the eBPF program FD to the driver’s NDO (`net_device_ops.ndo_bpf`) hook.

- Skb: Kernel attaches eBPF program to the generic `dev_change_xdp_fd` hook in the main networking stack.


Note: Because the hook points are fundamentally different, not all eBPF helper functions or map types work
      in all modes:
      1. Offload Limitations: HW NPU memory is restricted. Advanced helpers (like `bpf_trace_printk`, 
         helper calls that query kernel state, or dynamic map allocations) are rejected by the in-kernel 
         JIT verifier when attempting to attach in Offload mode.
      2. Driver vs. Generic Return Actions:
        - In Driver and Offload modes, `XDP_REDIRECT` bypasses host memory overhead completely, sending
           packets directly out another physical interface or into AF_XDP sockets.
        - In Skb mode, `XDP_REDIRECT` still incurs performance penalties because `sk_buff structures have
          already been instantiated in host memory before redirection occurs.

---

## 4. Build and Run Instructions

### Prerequisites

* Rust toolchain (nightly channel required for eBPF targets)
* `cargo-generate` (`cargo install cargo-generate`)
* `bpf-linker` (`cargo install bpf-linker`)

### Building

`aya-build` automatically compiles the eBPF bytecode via `build.rs` during the standard build workflow:

```bash
# Build both user-space binary and kernel eBPF bytecode
cargo build

```

### Execution Examples

#### 1. Quick Driver Capability Probe

Probe the network interface driver to print the strongest supported mode and exit immediately:

```bash
RUST_LOG=info sudo -E ./target/debug/hello_xdp --iface eth0

```

#### 2. Watch Mode (Live Packet Metrics)

Stay attached in the strongest supported mode and continuously report live total packets and live rates (p/s) until `Ctrl+C` is pressed:

```bash
RUST_LOG=info sudo -E ./target/debug/hello_xdp --iface eth0 --watch

```

**Example Output:**

```text
==========================================
Interface      : eth0
Strongest Mode : Driver
==========================================

Watch mode enabled. Printing live metrics (Ctrl+C to exit)...

[eth0] Total Packets: 14502        | Live Rate:    1240.50 p/s
[eth0] Total Packets: 15810        | Live Rate:    1308.00 p/s
^C
Ctrl+C received. Detaching XDP program and exiting...


## Kernel Logic 

From Aya's documentation: https://docs.rs/aya/0.14.0/aya/programs/xdp/enum.XdpMode.html

```rust 
    pub enum XdpMode {
        Default,
        Skb,
        Driver,
        Hardware,
    }
```

Default: Default Variant lets the kernel choose the mode.

At kernel :

### The Kernel's In-Driver Negotiation Logic

When an `RTM_SETLINK` command arrives without explicit mode flags:
    `XDP_FLAGS_SKB_MODE`, 
    `XDP_FLAGS_DRV_MODE`, or 
    `XDP_FLAGS_HW_MODE`, 
the kernel executes the following evaluation sequence:

```text 
User Requests XDP Load (flags = 0)
                               │
                               ▼
            Does Driver Support `ndo_bpf` Hook?
                         /           \
                       YES            NO
                       /               \
       Attempts Native/Driver Attach   Fallback to Generic / SKB Mode
             /               \           (`netif_receive_skb`)
          SUCCESS          FAILURE
            /                 \
     Attached Native      Fallback to Generic / SKB Mode

```

#### 1. The Kernel Implementation (`dev_change_xdp_fd`)

In the Linux kernel source tree (net/core/dev.c), setting up XDP executes through `dev_change_xdp_fd()`. 
Simplified, the kernel performs this exact check:

```c 
// Simplified Linux Kernel logic for XDP mode negotiation
int dev_change_xdp_fd(struct net_device *dev, struct netlink_ext_ack *extack,
                      int fd, int expected_fd, u32 flags)
{
    const struct net_device_ops *ops = dev->netdev_ops;
    
    // 1. Explicit Hardware Mode Requested
    if (flags & XDP_FLAGS_HW_MODE)
        return dev_xdp_attach_hw(dev, extack, fd, expected_fd, flags);

    // 2. Explicit Driver/Native Mode Requested
    if (flags & XDP_FLAGS_DRV_MODE)
        return dev_xdp_attach_drv(dev, extack, fd, expected_fd, flags);

    // 3. Explicit Generic/SKB Mode Requested
    if (flags & XDP_FLAGS_SKB_MODE)
        return dev_xdp_attach_skb(dev, extack, fd, expected_fd, flags);

    // =========================================================
    // DEFAULT / FALLBACK MECHANISM (flags == 0)
    // =========================================================

    // Step A: Try Native Driver mode first if the driver implements ndo_bpf
    if (ops->ndo_bpf) {
        err = dev_xdp_attach_drv(dev, extack, fd, expected_fd, flags);
        if (!err)
            return 0; // Successfully attached in Native mode!
    }

    // Step B: Fallback to Generic SKB mode if Driver mode isn't supported or fails
    return dev_xdp_attach_skb(dev, extack, fd, expected_fd, flags);
}
```

#### Key Mechanism Characteristics

1. Hardware Offload Is Never Automatic:
   The kernel never selects Hardware (Offload) mode automatically when using `XdpMode::Default`. 
   Hardware offload requires explicit user consent (`XDP_FLAGS_HW_MODE`) because offloading compiles 
   bytecode directly into SmartNIC NPU memory, which carries device-specific constraints and memory limits.

2. Native/Driver Preference (ndo_bpf):
   The kernel first checks if the NIC driver implements the `ndo_bpf` function pointer in its 
   `net_device_ops struct`. If implemented, it attempts to load the program into the driver's RX ring buffer
   loop.

3. Silent Generic Fallback:
   If the driver lacks `ndo_bpf` support, or if allocating ring buffers for Native XDP fails (e.g., due to 
   insufficient MTU or queue configuration), the kernel silently falls back to `XDP_FLAGS_SKB_MODE` without
   returning an error to user-space.



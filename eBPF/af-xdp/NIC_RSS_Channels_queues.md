# RSS 

Receive Side Scaling is a NIC hardware mechanism that **takes incoming packets, hashes their flow
information, and maps each flow to one of several RX queues**, allowing different CPU cores to process
different flows concurrently.

NOTE:
-----
The flow information here means the pkt header field that identfies which network conversation the pkt
belongs to 
For typical TCP/UDP RSS, this is a 5-tuple:
    - SRC IP 
    - DST IP 
    - SRC Port 
    - DST Port 
    - Protocol 

for ex:
```text 
Src IP       : 192.168.1.10
Dst IP       : 10.0.0.20
Src Port     : 52341
Dst Port     : 443
Protocol     : TCP
```
The NIC uses these fields to calculate an RSS hash:
```text 
        192.168.1.10
        10.0.0.20
        52341
        443
        TCP
           │
           ▼
      RSS hash function
           │
           ▼
        0x8A32...
           │
           ▼
      RX Queue 3
```
So another packet with the same 5-tuple:

```text 

192.168.1.10:52341
        ↓
10.0.0.20:443
        TCP
```
will normally produce the same RSS hash → same RX queue.

=> it gives you per-flow CPU affinity.

ex:
```text 
Flow A ──► hash ──► Queue 0 ──► CPU 0
Flow B ──► hash ──► Queue 3 ──► CPU 3
Flow C ──► hash ──► Queue 1 ──► CPU 1
Flow D ──► hash ──► Queue 0 ──► CPU 0
```

Notice that Flow A and Flow D can share a queue, but packets belonging to one flow normally stay on the same
queue.
Also, RSS can be configured to hash on different fields depending on the NIC/driver. For example, some
configurations use only: SRC and DST IP's 
----------

### 1. Without RSS

Imagine a 100-Gbps NIC receiving packets:

```
                  NIC
                   │
          Incoming packets
                   │
                   ▼
              RX Queue 0
                   │
                IRQ 0
                   │
                   ▼
                CPU 0
```

If all packets arrive through one RX queue, one CPU becomes the bottleneck even though the machine has
many cores.

RSS changes this to:

```
                         NIC
                          │
              ┌───────────┴───────────┐
              │   RSS Hash Engine     │
              └───────────┬───────────┘
                          │
       ┌──────────────────┼──────────────────┐
       ▼                  ▼                  ▼
    RX Queue 0         RX Queue 1        RX Queue 2 ...
       │                  │                  │
     IRQ 0              IRQ 1              IRQ 2
       │                  │                  │
     CPU 0              CPU 1              CPU 2
```

So the NIC itself performs the initial distribution **before the packet reaches the CPU**.

### 2. What does the NIC hash?

Typically the NIC extracts fields such as:

```
Source IP
Destination IP
Source TCP/UDP port
Destination TCP/UDP port
```

For example:

```
10.0.0.10:50000 → 10.0.0.20:443
```

The NIC computes a hash, commonly using **Toeplitz hashing** for traditional RSS:

```
hash = RSS_hash(IPs, ports, RSS_key)
```

Then the hash is mapped to an RX queue:

```
hash
  │
  ▼
RSS indirection table
  │
  ├── 0 → Queue 0
  ├── 1 → Queue 2
  ├── 2 → Queue 1
  ├── 3 → Queue 3
  └── ...
```

The important point is that **the NIC doesn't normally assign each packet independently to a random CPU**.

Instead, packets belonging to the same flow produce the same hash and therefore normally go to the same
queue.

### 3. Why must packets from one flow stay together?

Consider TCP:

```
Client ───────────────► Server

packet 1
packet 2
packet 3
packet 4
```

If packet 1 went to CPU 0 and packet 2 to CPU 7, packets could be processed concurrently by different CPUs.

That creates problems:

- TCP state is shared.
- Packets can be processed out of order.
- Cache locality becomes worse.
- Synchronization/locking becomes necessary.

RSS therefore aims for:

```
Flow A ──► Queue 0 ──► CPU 0

Flow B ──► Queue 1 ──► CPU 1

Flow C ──► Queue 2 ──► CPU 2
```

while preserving:

```
Flow A packet 1 ──► CPU 0
Flow A packet 2 ──► CPU 0
Flow A packet 3 ──► CPU 0
```

This is often called **flow affinity**.

### 4. RX queues are more than just packet lists

An RX queue is typically backed by a ring of DMA descriptors.

Conceptually:

```
                NIC
                 │
                 │ DMA
                 ▼
        ┌─────────────────┐
        │ RX descriptor   │
        │ ring            │
        ├─────────────────┤
        │ desc 0 → buffer │
        │ desc 1 → buffer │
        │ desc 2 → buffer │
        │ ...             │
        └─────────────────┘
                 │
                 ▼
                RAM
```

The driver allocates packet buffers and gives their DMA addresses to the NIC.

When a packet arrives:

```
Packet
  │
  ▼
NIC
  │
  ├─ RSS hash
  │
  ├─ choose RX queue
  │
  └─ DMA packet into buffer
```

The NIC then updates the corresponding RX descriptor to tell the driver:

> "A packet has arrived in this buffer."

### 5. Where do IRQs enter?

Each RX queue can be associated with an interrupt vector.

For example:

```
RX Queue 0 ──► MSI-X vector 32 ──► CPU 0
RX Queue 1 ──► MSI-X vector 33 ──► CPU 1
RX Queue 2 ──► MSI-X vector 34 ──► CPU 2
RX Queue 3 ──► MSI-X vector 35 ──► CPU 3
```

Modern NICs generally use **MSI-X**, which supports many independent interrupt vectors.

The OS can configure interrupt affinity:

```
IRQ 32 → CPU 0
IRQ 33 → CPU 1
IRQ 34 → CPU 2
IRQ 35 → CPU 3
```

So the complete path becomes:

```
                 Ethernet
                    │
                    ▼
              ┌───────────┐
              │    NIC    │
              │           │
              │ RSS hash  │
              └─────┬─────┘
                    │
       ┌────────────┼────────────┐
       ▼            ▼            ▼
    Queue 0      Queue 1      Queue 2
       │            │            │
      IRQ          IRQ          IRQ
       │            │            │
     CPU 0        CPU 1        CPU 2
       │            │            │
       └────────────┼────────────┘
                    ▼
              Network stack
```

### 6. One subtle but important distinction

**RSS does not itself mean "one queue = one CPU."**

There are separate mappings:

```
RSS hash
   ↓
RSS indirection table
   ↓
RX queue
   ↓
MSI-X interrupt vector
   ↓
CPU affinity
```

 For example, you could have:

```
Queue 0 ──► CPU 4
Queue 1 ──► CPU 5
Queue 2 ──► CPU 6
Queue 3 ──► CPU 7
```

The OS/network driver controls much of this configuration.

### 7. What happens at 100/200/400 GbE?

 This becomes increasingly important as NIC bandwidth increases.

 A 100-Gbps NIC might have dozens of RX queues:

```
                    100 GbE NIC
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
    Queue 0           Queue 1          Queue 2 ...
       │                 │                 │
     CPU 0             CPU 1             CPU 2
```

 The NIC can therefore spread network processing over many cores.

 However, **RSS isn't the whole performance story**. Modern high-speed networking also involves:

 - NAPI polling
- MSI-X
- interrupt moderation
- NUMA locality
- RPS/RFS
- XDP
- GRO/GSO
- receive/transmit descriptor rings
- hardware offloads
- multiple TX queues
- queue/core affinity

 The key mental model is:

 > **RSS is the NIC's hardware steering mechanism that converts packet headers → hash → RX queue, while the OS maps those queues/interrupts onto CPUs.**

 That separation is important when understanding how a modern 100/200/400-GbE NIC can feed many CPU cores simultaneously.

### Understanding Network Channels (Queues)

Network interface cards (NICs) like Mellanox ConnectX use **channels** specifically divided into
**Receive (RX)** and **Transmit (TX)** queues—as direct hardware pathways between the physical network port
and your computer's CPU.

* **Single-Queue Bottleneck:** If you have `combined 1`, all incoming packets hit a single RX queue, and a
  single CPU core must process every single packet. This creates a severe CPU bottleneck at high line rates
  (e.g., 10Gbps, 25Gbps, or 100Gbps).

* **Multi-Queue Scaling:** Modern NICs support multiple channels (e.g., 8, 16, or more). Using a feature
  called **Receive Side Scaling (RSS)**, the hardware hashes incoming packet headers (IPs, ports) and
  distributes packets across multiple RX queues. Each queue triggers hardware interrupts (IRQs) handled by
  different CPU cores, enabling parallel packet processing.

---

### How AF_XDP Uses Channels

**AF_XDP** (Address Family XDP) is a high-performance socket address family built for high-speed packet processing. It interacts directly with these hardware channels to bypass the traditional Linux networking stack:

1. **Queue Binding:** An AF_XDP socket (`xsk`) does not listen on a network interface broadly; it binds strictly to a **specific RX queue ID** on a specific interface.
2. **Direct Memory Access (Zero-Copy):** On capable hardware like Mellanox ConnectX cards, when a packet arrives on a specific RX queue, the NIC's DMA engine writes the packet directly into a user-space memory region (`UMEM`) shared with your application, completely bypassing `sk_buff` allocation and kernel overhead.
3. **Multi-Queue Application Design:** To scale an AF_XDP application across multiple CPU cores, you typically launch multiple application worker threads. Each thread creates its own AF_XDP socket and binds it to a *unique* RX queue channel (e.g., Thread 0 binds to Queue 0, Thread 1 binds to Queue 1).

---

### How to Inspect and Verify Your Setup

1. **Check available and active channels:** Ethtool.
To see the maximum supported channels and your currently active channel counts, run:

```bash
ethtool -l enp1s0f0np0

```

*Verification:* Look at the "Current hardware settings" section to confirm your RX and TX channel counts match your multi-queue requirements.


2. **Check CPU interrupt distribution:** Procfs.
To verify which CPU cores are handling the interrupts (IRQs) for your card's queues, check the system interrupt stats:

```bash
cat /proc/interrupts | grep enp1s0f0np0

```

*Verification:* Ensure you see separate IRQ lines spreading across different CPU cores rather than slamming a single core (like CPU 0).


------------------

How can I manually tune the RSS indirection table to control traffic distribution across queues?


You can manually tune the Receive Side Scaling (RSS) indirection table using the `ethtool` command. The indirection table maps the hashed incoming network flows to specific hardware RX queues. By customizing this table, you can explicitly control which queues receive specific traffic distributions.

### 1. View the Current Indirection Table

Before making changes, inspect how traffic is currently distributed across your queues:

```bash
ethtool -x enp1s0f0np0

```

*Verification:* Review the printed index mapping table (e.g., `0: 0 1 2 3...`) to see which queue IDs currently correspond to each hash bucket entry.

### 2. Modify the Table Distribution

You can change how entries map to your queues using the `ethtool -X` command.

* **To evenly distribute traffic across a specific number of queues (e.g., queues 0 through 3):**
```bash
sudo ethtool -X enp1s0f0np0 equal 4

```


*Verification:* Re-run `ethtool -x enp1s0f0np0` and check that the indirection table entries rotate exclusively between queues `0`, `1`, `2`, and `3`.
* **To assign custom weights or isolate specific queues:**
If you want to bias traffic toward certain queues (for example, leaving queue 0 for regular OS traffic and routing the rest to application queues), you can specify custom weights for each queue index:
```bash
sudo ethtool -X enp1s0f0np0 weight 0 1 1 1

```


*(This example assigns a weight of 0 to queue 0, and a weight of 1 to queues 1, 2, and 3).*

------------
1. How can i Reset RSS settings to Default 
2. how can I Bind AF_XDP socket to queue

### 1. Resetting RSS Settings to Default

To revert your RSS indirection table back to its original driver default distribution, use the `default` keyword with `ethtool`:

```bash
sudo ethtool -X enp1s0f0np0 default

```

*Verification:* Run `ethtool -x enp1s0f0np0` and check that the indirection table map indices have returned to their default multi-core balancing sequence.

---

### 2. Binding an AF_XDP Socket to a Specific Queue

When writing an AF_XDP application using `libbpf` or `libxdp`, binding to a specific hardware queue is handled directly via the `queue_id` parameter in the `xsk_socket__create()` function.

#### Using `libbpf` (`xsk_socket__create`)

```c
struct xsk_socket *xsk;
struct xsk_ring_cons rx;
struct xsk_ring_prod tx;
struct xsk_umem *umem;
__u32 queue_id = 1; // Set this to the specific queue index your thread handles

int ret = xsk_socket__create(&xsk, 
                             "enp1s0f0np0", 
                             queue_id, // <-- Explicit queue binding
                             umem, 
                             &rx, 
                             &tx, 
                             NULL);
if (ret) {
    // Handle socket creation error
}

```

*Verification:* Monitor your application logs or check packet arrival counters to confirm that traffic hits the designated queue socket.

#### Using Raw Sockets (`bind`)

If you are implementing the binding manually using low-level sockets instead of `libbpf`, populate the `sxdp_queue_id` field in the `sockaddr_xdp` structure:

```c
#include <linux/if_xdp.h>
#include <sys/socket.h>
#include <net/if.h>

struct sockaddr_xdp sxdp = {0};
int sock = socket(AF_XDP, SOCK_RAW, 0);

sxdp.sxdp_family = PF_XDP;
sxdp.sxdp_ifindex = if_nametoindex("enp1s0f0np0");
sxdp.sxdp_queue_id = 1; // Target hardware queue ID

int ret = bind(sock, (struct sockaddr *)&sxdp, sizeof(sxdp));
if (ret) {
    // Handle bind error
}

```

*Verification:* Check that the `bind()` call returns `0` without throwing an `ENXIO` or `EINVAL` error (which occurs if the specified queue index exceeds the card's active queue count).

---------------------

1. How to configure XDP zero-copy mode
2. How to setup an XDP redirect map


### 1. Configuring XDP Zero-Copy Mode

By default, AF_XDP can operate in **copy mode** (using standard memory copies between the kernel and user space). To achieve maximum line-rate performance on Mellanox ConnectX cards, you must enable **zero-copy mode**, which forces the NIC's DMA engine to write packets directly into your user-space `UMEM` memory.

Zero-copy mode is requested during the AF_XDP socket creation flags. When using `libbpf`, you configure this in the `xsk_socket_config` structure:

```c
struct xsk_socket_config cfg;
struct xsk_socket *xsk;
__u32 queue_id = 1;

memset(&cfg, 0, sizeof(cfg));
cfg.rx_size = XSK_RING_CONS__DEFAULT_NUM_DESCS;
cfg.tx_size = XSK_RING_PROD__DEFAULT_NUM_DESCS;
cfg.libbpf_flags = 0;
// Force zero-copy mode. Note: If the driver/NIC doesn't support it,
// socket creation will fail instead of silently falling back to copy mode.
cfg.xdp_flags = XDP_FLAGS_UPDATE_IF_NOEXIST;
cfg.bind_flags = XDP_ZEROCOPY; // <-- Request zero-copy

int ret = xsk_socket__create(&xsk, "enp1s0f0np0", queue_id, umem, &rx, &tx, &cfg);
if (ret) {
    // Handle error (e.g., driver doesn't support zero-copy on this queue)
}

```

*Verification:* Check your application startup logs to ensure `xsk_socket__create()` returns `0`. You can also verify that zero-copy is active by checking `ethtool -S enp1s0f0np0` for driver-specific XDP allocation counters or monitoring memory consumption.

---

### 2. Setting Up an XDP Redirect Map

To scale an AF_XDP application across multiple queues, your eBPF program needs a way to pass packets from the kernel driver straight to the correct user-space socket ring. This is done using an **`XDP_MAP_TYPE_XSKMAP`** (often called `xsks_map`).

#### Step A: Define the Map in your eBPF C Code

```c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

// Define an XSK map sized to hold entries for your hardware queues
struct {
    __uint(type, BPF_MAP_TYPE_XSKMAP);
    __uint(max_entries, 64); // Match or exceed your max queue count
    __type(key, __u32);     // Key is the queue ID
    __type(value, int);     // Value is the socket file descriptor
} xsks_map SEC(".maps");

SEC("xdp")
int xdp_sock_prog(struct xdp_md *ctx) {
    __u32 queue_index = ctx->rx_queue_index;

    // Redirect packet to the user-space socket bound to this specific queue
    return bpf_redirect_map(&xsks_map, queue_index, XDP_PASS);
}

char _license[] SEC("license") = "GPL";

```

#### Step B: Populate the Map from User-Space (`libbpf`)

After creating your AF_XDP sockets and loading your eBPF program, you must insert each socket's file descriptor into the `xsks_map` using its corresponding queue ID as the key:

```c
int map_fd = bpf_object__find_map_fd_by_name(obj, "xsks_map");
int sock_fd = xsk_socket__fd(xsk); // Get the raw socket FD
__u32 queue_id = 1;

int ret = bpf_map_update_elem(map_fd, &queue_id, &sock_fd, BPF_ANY);
if (ret) {
    // Handle map update error
}

```

*Verification:* Ensure `bpf_map_update_elem()` returns `0`. You can inspect loaded BPF maps using `bpftool map show` and verify traffic is successfully hitting your user space ring buffers using `bpftool map dump`.

-----------
1. How to handle packets poling (XSK rings)
2. Optimize driver ring size

### 1. Handling Packet Polling (XSK Rings)

To receive and transmit packets using AF_XDP, your user-space application must poll the ring buffers (`RX` and `Fill` rings for receiving; `TX` and `Completion` rings for transmitting). This is typically done using the standard `poll()` system call on the AF_XDP socket file descriptor, combined with ring consumer/producer helper functions from `libbpf`.

#### Polling and Receiving Packets (`RX` Ring)

```c
#poll.h>
#include <poll.h>
#include <bpf/xsk.h>

struct pollfd fds[1];
fds[0].fd = xsk_socket__fd(xsk);
fds[0].events = POLLIN;

// Wait for incoming packets on this queue's socket
int ret = poll(fds, 1, 1000); // 1000ms timeout
if (ret <= 0) {
    // Handle timeout or error
}

// Consume packets from the RX ring
__u32 idx_rx = 0;
__u32 rcvd = xsk_ring_cons__peek(&rx, 32, &idx_rx); // Peek up to 32 descriptors

if (rcvd > 0) {
    for (int i = 0; i < rcvd; i++) {
        const struct xdp_desc *desc = xsk_ring_cons__rx_desc(&rx, idx_rx + i);
        __u64 addr = desc->addr;
        __u32 len = desc->len;
        
        // Access packet data directly from UMEM buffer
        void *pkt_data = xsk_umem__get_data(umem_area, addr);
        
        // Process your packet here...
    }

    // Release the consumed entries back to the RX ring
    xsk_ring_cons__release(&rx, rcvd);
}

```

*Verification:* Check that `poll()` unblocks and returns a positive integer when network traffic hits the interface, and verify that `xsk_ring_cons__peek()` successfully returns a non-zero packet count.

---

### 2. Optimizing Driver Ring Sizes

To prevent packet drops during heavy bursts of traffic before your AF_XDP application can consume them, you should ensure your network driver's hardware ring buffer sizes are properly scaled using `ethtool`.

#### Step A: Check Maximum and Current Driver Ring Sizes

```c
ethtool -g enp1s0f0np0

```

*Verification:* Note the pre-set maximum values allowed by your NIC driver (e.g., Mellanox ConnectX cards often support up to 4096 or 8192 descriptors).

#### Step B: Increase the RX and TX Ring Sizes

Set the ring buffer sizes to their maximum supported values to provide a larger hardware buffer for packet spikes:

```c
sudo ethtool -G enp1s0f0np0 rx 4096 tx 4096

```

*Verification:* Re-run `ethtool -g enp1s0f0np0` and confirm that the "Current hardware settings" for RX and TX reflect your newly updated values.
--------------

1. How to configure multi-buffer AF_XDP
2. How to monitor XDP drop statistics

### 1. Configuring Multi-Buffer AF_XDP

By default, standard AF_XDP handles single frames (packets that fit within a single UMEM chunk, typically 2048 or 4096 bytes). To support jumbo frames or packets spanning multiple descriptors (multi-buffer packets), you must explicitly enable multi-buffer support via socket options during initialization.

#### Step A: Enable Multi-Buffer via Socket Flag

When setting up your AF_XDP socket, pass the `XDP_USE_NEED_WAKEUP` or specific multi-buffer parsing flags depending on your kernel version. More importantly, configure your UMEM chunk size to handle your maximum expected frame payload, and ensure your eBPF program is compiled to handle multi-buffer contexts (`xdp_buff` chain parsing).

```c
struct xsk_socket_config cfg;
memset(&cfg, 0, sizeof(cfg));
cfg.rx_size = XSK_RING_CONS__DEFAULT_NUM_DESCS;
cfg.tx_size = XSK_RING_PROD__DEFAULT_NUM_DESCS;

// Enable multi-buffer support flag (if supported by kernel/driver)
cfg.xdp_flags = XDP_FLAGS_UPDATE_IF_NOEXIST;
// Note: libbpf handles multi-buffer descriptor chaining automatically 
// when parsing sequential entries from xsk_ring_cons if enabled on socket.

```

*Verification:* Check that `xsk_socket__create()` succeeds when processing larger MTU sizes (e.g., 9000-byte jumbo frames) without dropping packets due to size mismatch errors.

---

### 2. Monitoring XDP Drop Statistics

When tracking performance or diagnosing packet loss in high-speed pipelines, monitoring software and hardware drop counters is essential. You can query drop metrics using both system tools and `ethtool`.

#### Step A: Check Driver-Level and XDP Statistics

Use `ethtool` to view interface-specific statistics, which expose driver drops, ring overruns, and XDP-specific drop counters:

```bash
ethtool -S enp1s0f0np0 | grep -E "xdp|drop|over"

```

*Verification:* Look for counters like `rx_xdp_drop`, `rx_dropped`, or driver-specific ring drop counters to see if frames are being discarded before or during eBPF execution.

#### Step B: Monitor XDP Socket Statistics via Program Maps or `bpftool`

If you track drops directly inside your eBPF program, you can map drop reasons using a BPF array map. You can inspect map counters programmatically or via CLI:

```bash
sudo bpftool map show

```

*Verification:* Dump the specific drop map counters using `bpftool map dump id <MAP_ID>` to read real-time drop counters categorized by your eBPF logic.

--------------------

1. how to tune rind buffer sizes
2. How to analyze eBPF map performance

### 1. Tuning Network Driver Ring Buffer Sizes

Network interface card (NIC) ring buffers act as circular descriptor queues between the hardware and the host. Tuning them helps prevent packet drops during traffic bursts.

1. **Check maximum and current ring sizes:** Ethtool.
View the supported maximum and currently active descriptor ring sizes for your ConnectX interface:

```bash
ethtool -g enp1s0f0np0

```

*Verification:* Look at the "Pre-set maximums" section to see the highest ring size your driver and hardware support.


2. **Resize the RX and TX rings:** Ethtool.
Increase or adjust your ring buffer sizes to handle high-throughput workloads (e.g., setting them to 4096 descriptors, depending on your hardware limits):

```bash
sudo ethtool -G enp1s0f0np0 rx 4096 tx 4096

```

*Verification:* Re-run `ethtool -g enp1s0f0np0` and verify that the "Current hardware settings" match your newly assigned values. Note that this operation briefly resets the link interface.


---

### 2. Analyzing eBPF Map Performance

To check how efficiently your eBPF maps are performing (such as lookup overhead, memory consumption, and hit/miss ratios), you can use `bpftool` alongside kernel performance counters.

1. **Enable BPF performance statistics:** Kernel Sysctl.
By default, detailed execution time statistics for BPF programs and maps are disabled to save overhead. Enable them via sysctl:

```bash
sudo sysctl -w kernel.bpf_stats_enabled=1

```

*Verification:* Run `sysctl kernel.bpf_stats_enabled` to confirm it returns `1`.


2. **Inspect map memory usage and metadata:** Bpftool.
List all active maps on your system to find your XSK map or lookup tables, checking their ID, type, and reserved memory (`memlock`):

```bash
sudo bpftool map show

```

*Verification:* Locate your target map ID and review its `max_entries` and memory allocation to ensure it isn't hitting capacity limits.


3. **Profile program execution time:** Bpftool.
Measure the CPU cycles and instruction counts spent executing your eBPF program and interacting with its maps:

```bash
sudo bpftool prog profile id <PROG_ID> duration 5 cycles instructions

```

*Verification:* Review the output metrics to verify that map lookups and filter paths are maintaining low latency per packet invocation.

-----------

How do I pin network interface IRQs to dedicated CPU cores?

To pin network interface interrupts (IRQs) to dedicated CPU cores, you can use the system's interrupt mapping configuration in `/proc/interrupts` combined with the `irqbalance` daemon settings or manual affinity masks. Pinning IRQs prevents CPU context switching and ensures that the specific cores handling your NIC interrupts match the cores running your AF_XDP polling threads.

1. **Identify the IRQ numbers for your interface:** Procfs.
Find the specific IRQ numbers associated with your network interface (`enp1s0f0np0`):

```bash
grep enp1s0f0np0 /proc/interrupts

```

*Verification:* Review the output to note the IRQ numbers (usually listed in the first column, e.g., `32:` or `145:`) assigned to your card's receive and transmit queues.


2. **Disable automatic IRQ balancing (Optional):** Stop Irqbalance.
By default, the `irqbalance` service dynamically moves interrupts around, which will override your manual pinning. For high-performance setups, disable or configure it:

```bash
sudo systemctl stop irqbalance
sudo systemctl disable irqbalance

```

*Verification:* Run `sudo systemctl status irqbalance` to confirm it is stopped and disabled. *(Note: If you need irqbalance running for other system devices, you can alternatively add your interface to its blacklist configuration).*


3. **Manually assign CPU affinity:** Procfs.
Write a hexadecimal CPU bitmask to the `smp_affinity` file for each specific IRQ. For example, to pin an IRQ to **CPU core 2** (where bit 2 is `4`), run:

```bash
sudo sh -c 'echo 4 > /proc/irq/<IRQ_NUMBER>/smp_affinity'

```

*(Replace `<IRQ_NUMBER>` with your actual IRQ number from Step 1).*
*Verification:* Read the affinity file back using `cat /proc/irq/<IRQ_NUMBER>/smp_affinity` and ensure it outputs your expected core mask.

------
1. how to tune kernel network parameters 
2. How to monitor CPU interrupt load

### 1. Tuning Kernel Network Parameters for High Performance

To handle high-throughput packet processing and AF_XDP pipelines, you should tune key Linux kernel sysctl network parameters. These adjustments increase socket buffer limits, memory allocations, and network backlog queues.

1. **Create or edit a custom sysctl configuration file:** Sysctl Configuration.
Create a new configuration file under `/etc/sysctl.d/99-networking.conf` using a text editor:

```bash
sudo nano /etc/sysctl.d/99-networking.conf

```

Paste the following performance tuning parameters:

```ini
# Increase maximum socket receive and send buffer sizes
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144

# Increase the maximum number of packets queued on the input queue
net.core.netdev_max_backlog = 10000

# Increase socket listen backlog for high connection rates
net.core.somaxconn = 4096

```

*Verification:* Save and close the file, then apply the changes immediately by running:

```bash
sudo sysctl --system

```

Verify that the parameters loaded correctly using `sysctl net.core.rmem_max`.


---

### 2. Monitoring CPU Interrupt Load

When pinning network interface IRQs to specific cores, you need to monitor the CPU interrupt load to ensure traffic is balanced evenly and cores aren't becoming oversaturated.

1. **Monitor real-time interrupt increments:** Watch and Procfs.
Use `watch` to continuously check the `/proc/interrupts` file, focusing on your network card interface:

```bash
watch -n 1 "grep enp1s0f0np0 /proc/interrupts"

```

*Verification:* Watch the counter columns corresponding to your pinned CPU cores to ensure they increment steadily under network load.


2. **Check per-CPU interrupt overhead:** Sysstat (mpstat).
Install `sysstat` (if not already installed) and use `mpstat` to view software (`%soft`) and hardware (`%irq`) CPU utilization:

```bash
sudo apt install sysstat -y
mpstat -P ALL 1 1

```

*Verification:* Review the `%soft` column in the output to check if specific CPU cores are spending excessive time processing software interrupts.

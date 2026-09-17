# AF_XDP ICMP Redirect Example (C)

A minimal AF_XDP application: Based on `xdp-tutorial/advanced03-AF_XDP` lesson, 
- It redirects IPv4 ICMP packets from the kernel into userspace via an `XSKMAP`, 
- counts them, and 
- recycles buffers through the UMEM Fill ring. 

No packet inspection or response logic is implemented in userspace.
Focus on counting/plumbing exercise, not to ICMP response. 

## Goal

- IPv4 ICMP packets are redirected to userspace through an `XSKMAP` +
  AF_XDP socket.

- All other traffic returns `XDP_PASS` and continues through the normal
  Linux networking stack untouched.

- Userspace receives redirected ICMP frames, increments a counter, and
  prints the running total once per second.

- Every received UMEM frame is correctly recycled back onto the Fill
  ring after being counted, so RX never stalls.

- The kernel program does no ICMP parsing beyond classifying the IP
  protocol number — no type/code inspection, no reply construction.

## Files

| File                        | Purpose                                            |
|-----------------------------|-----------------------------------------------------|
| `xdp_afxdp_icmp_kern.c`     | Kernel-side XDP program (eBPF)                      |
| `afxdp_icmp_user.c`         | Userspace loader + AF_XDP receive loop              |
| `Makefile`                  | Builds both of the above                            |
| `./setup_veth.sh`,`./setup_mlx.sh` | Test network setup for virtual and phy ifaces |


## Setup

Requires a XDP Native supported NIC, ex: Mellanox (`mlx5`) NIC, 
using one port to send and the other (in a separate network namespace) to
receive/redirect. 

The traffic actually crosses the wire between two interfaces rather than staying entirely on-host. 

Or Two - Hosts connected via a physical DAC can be used. 

Or A veth pair works too for a fully virtual test, with one caveat noted below.

### Physical NIC setup (two ports, e.g. `enp1s0f0np0` / `enp1s0f1np1`)

```bash
# Move one port into its own namespace so its address isn't "local"
# to this host (otherwise ICMP is short-circuited internally and
# never actually triggers RX/XDP on the other port).
sudo ip netns add ns1
sudo ip link set enp1s0f1np1 netns ns1

# Host-side port: this is the one the XDP program attaches to.
sudo ip link set enp1s0f0np0 up
sudo ip addr add 192.168.100.10/24 dev enp1s0f0np0

# Namespaced port: the "client" side generating traffic.
sudo ip netns exec ns1 ip link set enp1s0f1np1 up
sudo ip netns exec ns1 ip addr add 192.168.100.12/24 dev enp1s0f1np1
sudo ip netns exec ns1 ip link set lo up
```

**Multi-queue NICs — important:** real NICs typically spread RX across
several hardware queues via RSS. Since ICMP has no L4 ports, its RSS
hash is IP-address-only and won't reliably land on queue 0, which is
what this program binds to by default. Force single-queue for testing:

```bash
sudo ethtool -L enp1s0f0np0 combined 1
```

(Restore the original queue count afterward if this NIC is used for
anything else: `sudo ethtool -L enp1s0f0np0 combined <N>`.)

### veth alternative (fully virtual, single-queue by nature)

```bash
sudo ip link add veth0 type veth peer name veth1
sudo ip link set veth0 up
sudo ip netns add ns1
sudo ip link set veth1 netns ns1
sudo ip netns exec ns1 ip link set veth1 up
sudo ip addr add 10.0.0.1/24 dev veth0
sudo ip netns exec ns1 ip addr add 10.0.0.2/24 dev veth1
```

veth generally doesn't support **native** XDP — use `XDP_FLAGS_SKB_MODE`
instead of `XDP_FLAGS_DRV_MODE` (both occurrences, in the attach call
and the socket config) if testing this way.

### Dependencies

- `clang`/`llvm` (compiling the BPF object)
- `libbpf` + `libbpf-devel`/`libbpf-dev`
- `libxdp` + `libxdp-devel`/`libxdp-dev` — **required** on libbpf 1.0+,
  since the AF_XDP socket API (`xsk.h`, `xsk_umem__create`,
  `xsk_socket__create`, ring helpers) moved out of libbpf and into
  libxdp. On Fedora: `sudo dnf install libbpf-devel libxdp-devel`.
- `xdp-loader` (optional, from `xdp-tools`) — handy for checking attach
  state: `sudo xdp-loader status`.

## Program logic — kernel

The kernel program (`xdp_afxdp_icmp_kern.c`) has exactly two jobs, and
nothing else:

1. **Classify.** Check the Ethernet header's EtherType is IPv4, then
   check the IPv4 header's protocol field is `IPPROTO_ICMP`. Both
   checks are bounds-checked against `data_end` before any field is
   read — required for the eBPF verifier to accept the program.
   Classification stops at the protocol number; ICMP type/code/payload
   are never inspected.
2. **Redirect or pass.** `ctx->rx_queue_index` (the hardware RX queue
   the packet arrived on) is used as the key into `xsks_map`, a
   `BPF_MAP_TYPE_XSKMAP`. `bpf_redirect_map()` performs this lookup: if
   a userspace AF_XDP socket is registered for that queue, the packet
   is redirected to it (`XDP_REDIRECT`); if not (no socket bound yet,
   or a queue-index mismatch), it falls back to `XDP_PASS` so the
   packet still reaches the normal ICMP stack rather than being
   silently dropped.

The kernel program never touches `xsks_map`'s contents — only
userspace writes to it (see below). The program is direction-agnostic
and queue-count-agnostic; it simply asks "is there a socket for *this*
queue" on every packet.

### Packet path, NIC → userspace

1. NIC driver (native/driver XDP mode) hands the raw frame to the XDP
   program before an skb is allocated, per received frame, per RX
   queue.
2. Program classifies IPv4/ICMP and looks up `xsks_map[rx_queue_index]`.
3. On a hit, `bpf_redirect_map()` returns `XDP_REDIRECT`; the kernel's
   redirect machinery copies (copy mode) or hands ownership (zero-copy
   mode) of the frame into a UMEM frame — memory userspace registered
   when it created the AF_XDP socket.
4. A descriptor (address + length) for that UMEM frame is placed on
   the socket's **RX ring** — a lock-free ring shared via mmap between
   kernel and userspace.
5. Userspace consumes the RX ring, reads the packet directly out of
   the UMEM frame (no further copy), and processes it — here, just
   incrementing a counter.
6. Userspace **must** post the frame's address back onto the UMEM's
   **Fill ring** once done with it, so the kernel can reuse that frame
   for a future incoming packet. Frames not recycled are permanently
   lost from the pool; once the Fill ring empties, that RX queue has
   nowhere left to place new packets and effectively stalls.

## Program logic — userspace

The userspace loader (`afxdp_icmp_user.c`) does essentially all of the
non-trivial work, in this order:

1. **Load + attach.** Open and load the compiled BPF object, attach
   its XDP program to the target interface (native mode by default),
   and locate `xsks_map`'s file descriptor by name.
2. **UMEM setup.** Allocate a page-aligned memory region sized
   `NUM_FRAMES * FRAME_SIZE`, register it with the kernel as a UMEM,
   and create its **Fill** and **Completion** rings. The Fill ring is
   sized to hold every UMEM frame at once (since there's no separate
   TX free-list needed — this program never transmits), and is fully
   pre-populated with every frame's address so the kernel has buffers
   to write into from the very first received packet.
3. **AF_XDP socket setup.** Create a socket bound to a specific
   (interface, queue) pair, sharing the UMEM from step 2, with its own
   RX and TX rings. Critically, this sets
   `XSK_LIBXDP_FLAGS_INHIBIT_PROG_LOAD` — telling libxdp *not* to load
   its own default XDP program on this interface, since step 1 already
   attached a custom one. Skipping this flag would install a second,
   conflicting program.
4. **Wire socket to map.** Insert the socket's fd into `xsks_map` at
   its bound queue index — this is what actually connects the kernel
   program's redirect decision to this specific socket.
5. **RX loop.** Poll the socket's fd for readability; on each wakeup,
   drain available RX descriptors in a batch, increment the counter
   once per frame, and immediately return each frame's address to the
   Fill ring (recycle). No header/payload parsing happens here at all
   — classification was already done in the kernel.
6. **Stats.** Once per second (checked via `clock_gettime`, independent
   of RX activity), print the running counter.
7. **Shutdown.** On `SIGINT`/`SIGTERM`, cleanly delete the socket, free
   the UMEM, detach the XDP program from the interface, and print a
   final count.

## Implementation notes / gotchas hit during development

- **`xsk.h` moved.** On libbpf 1.0+, `#include <bpf/xsk.h>` no longer
  exists — the AF_XDP socket API lives in libxdp's
  `#include <xdp/xsk.h>` instead. Link both `-lbpf -lxdp`.
- **Config field rename.** libxdp renamed `xsk_socket_config`'s
  `libbpf_flags` field to `libxdp_flags`, and the flag constant from
  `XSK_LIBBPF_FLAGS__INHIBIT_PROG_LOAD` to
  `XSK_LIBXDP_FLAGS_INHIBIT_PROG_LOAD`.
- **`XDP_FLAGS_*` constants** (`XDP_FLAGS_DRV_MODE` etc.) come from
  `<linux/if_link.h>`, not from any libbpf/libxdp header — easy to miss.
- **Fill ring sizing.** `xsk_ring_prod__reserve()` can never reserve
  more entries than the ring's own capacity. The ring size passed at
  UMEM creation must be ≥ the number of frames you intend to
  pre-populate in one call, or the reserve fails outright.
- **`errno`/`EINTR`** require `<errno.h>`, easy to forget alongside the
  `poll()` error-handling path.
- **Address locality.** If testing on two physical ports of the same
  host, put one port's address in a separate network namespace. If
  both addresses live in the default namespace, one becomes "local" to
  the host and ICMP to it is short-circuited internally — it never
  actually goes out over the wire or triggers a genuine RX/XDP event on
  the other port.
- **Multi-queue RSS.** On a real multi-queue NIC, ICMP won't reliably
  hash to queue 0. Force `ethtool -L <iface> combined 1` for a
  deterministic single-queue test, or generalize the program to bind a
  socket per queue.
- **`pkg-config` surprises.** `pkg-config --cflags libbpf libxdp` can
  resolve unexpected flags (e.g. from an unrelated `.pc` file matching
  by name) depending on what else is installed — worth running that
  command standalone to sanity-check what it actually returns.

## Build

```bash
make            # produces xdp_afxdp_icmp_kern.o and afxdp_icmp_user
make clean      # removes both
```

## Run / test

1. Bring up the topology (see **Setup** above — physical NIC or veth).

2. Start the loader, bound to the interface + queue you configured:
   ```bash
   sudo ./afxdp_icmp_user <ifname> <queue_id> xdp_afxdp_icmp_kern.o
   # e.g.
   sudo ./afxdp_icmp_user enp1s0f0np0 0 xdp_afxdp_icmp_kern.o
   ```
   Confirm attach succeeded, independently, with:
   ```bash
   sudo xdp-loader status
   CURRENT XDP PROGRAM STATUS:
   Interface        Prio  Program name      Mode     ID   Tag               Chain actions
   --------------------------------------------------------------------------------------
   lo                     <No XDP program loaded!>
   enp3s0                 <No XDP program loaded!>
   enp1s0f0np0            xdp_afxdp_icmp_redirect native   909  e0e940007691979e
   ```

   Confirm that pkts are actually hitting the interface:

   ```bash 
   sudo xdpdump -x -i enp1s0f0np0
   listening on enp1s0f0np0, ingress XDP program ID 929 func xdp_afxdp_icmp_redirect, capture mode entry, capture size 262144 bytes
   1789630372.698442452: xdp_afxdp_icmp_redirect()@entry: packet size 98 bytes, captured 98 bytes on if_index 3, rx queue 0, id 1
   0x0000:  6c b3 11 88 55 b4 6c b3 11 88 55 b5 08 00 45 00  l...U.l...U...E.
   0x0010:  00 54 3f 33 40 00 40 01 b2 0e c0 a8 64 0c c0 a8  .T?3@.@.....d...
   0x0020:  64 0a 08 00 16 47 e2 d9 00 1f a5 97 ab 6a 00 00  d....G.......j..
   0x0030:  00 00 ec ea 02 00 00 00 00 00 10 11 12 13 14 15  ................
   0x0040:  16 17 18 19 1a 1b 1c 1d 1e 1f 20 21 22 23 24 25  .......... !"#$%
   0x0050:  26 27 28 29 2a 2b 2c 2d 2e 2f 30 31 32 33 34 35  &'()*+,-./012345
   0x0060:  36 37                                            67
   1789630373.722449640: xdp_afxdp_icmp_redirect()@entry: packet size 98 bytes, captured 98 bytes on if_index 3, rx queue 0, id 2
   0x0000:  6c b3 11 88 55 b4 6c b3 11 88 55 b5 08 00 45 00  l...U.l...U...E.
   0x0010:  00 54 42 29 40 00 40 01 af 18 c0 a8 64 0c c0 a8  .TB)@.@.....d...
   0x0020:  64 0a 08 00 5b e8 e2 d9 00 20 a6 97 ab 6a 00 00  d...[.... ...j..
   0x0030:  00 00 a5 48 03 00 00 00 00 00 10 11 12 13 14 15  ...H............
   0x0040:  16 17 18 19 1a 1b 1c 1d 1e 1f 20 21 22 23 24 25  .......... !"#$%
   0x0050:  26 27 28 29 2a 2b 2c 2d 2e 2f 30 31 32 33 34 35  &'()*+,-./012345
   0x0060:  36 37
   ```


3. **Positive test — ICMP should increment the counter:**
   ```bash
   sudo ip netns exec ns1 ping 192.168.100.10
   # or, higher rate:
   sudo ip netns exec ns1 hping3 --icmp --fast 192.168.100.10
   ```

4. **Negative test — non-ICMP should NOT increment the counter,**
   confirming the classification logic isn't over-matching:
   ```bash
   sudo ip netns exec ns1 hping3 -S --fast 192.168.100.10   # TCP SYN
   ```
   (hping3's default mode, with no `--icmp`/`-1`, is TCP — useful as an
   accidental negative-path test if you forget the flag.)

5. If the counter stays at zero when it shouldn't:
   - `sudo tcpdump -i <ifname> icmp -n` — confirm packets are actually
     arriving on the interface at all.
   - `sudo xdp-loader status` — confirm the program is attached in the
     expected mode (native vs. SKB) on the expected interface.
   - `ethtool -l <ifname>` — check queue count; force `combined 1` if
     greater than 1 and the loader is bound to a single queue.

6. Stop the loader with `Ctrl-C` — it prints a final count, unbinds
   the socket, frees the UMEM, and detaches the XDP program. Verify
   clean detach with `sudo xdp-loader status` afterward; if a prior run
   crashed instead of exiting cleanly, detach manually:
   ```bash
   sudo ip link set dev <ifname> xdp off
   ```

7. Tear down the test topology (namespace, addresses, restored queue
   count) once done.

## Next steps

This C version is a working baseline intended to be ported to Rust
using the `aya` framework (`aya-ebpf` for the kernel program,
`xsk-rs` for the AF_XDP socket/UMEM/ring management in userspace,
since Aya itself only handles eBPF loading/maps, not AF_XDP sockets).

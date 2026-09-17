/* -----------------------------------------------------------------------
 * PART 1 (C) — Kernel-side XDP program
 *
 * Behavior:
 *   - IPv4 ICMP packets  -> redirected to userspace via XSKMAP (AF_XDP)
 *   - everything else    -> XDP_PASS (normal stack)
 *
 * This program deliberately does NOT parse ICMP payload, build replies,
 * or touch packet contents beyond the Ethernet/IPv4 headers needed to
 * classify the packet. All ICMP handling happens in userspace.
 *
 * Build like the other xdp-tutorial lessons: clang -target bpf ...
 * ----------------------------------------------------------------------- */

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>

#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/* ---------------------------------------------------------------------
 * XSKS_MAP: BPF_MAP_TYPE_XSKMAP
 *
 * One entry per RX queue on the NIC. Userspace populates this map at
 * runtime: entry[queue_index] = fd of the AF_XDP socket bound to that
 * queue. The kernel program never writes to this map, only reads it
 * (implicitly, via bpf_redirect_map()).
 *
 * max_entries should be set to (at least) the number of RX queues the
 * NIC exposes; 64 here is a generous default if the exact count isn't
 * known at compile time.
 * --------------------------------------------------------------------- */
struct {
    __uint(type, BPF_MAP_TYPE_XSKMAP);
    __type(key, __u32);
    __type(value, __u32);
    __uint(max_entries, 64);
} xsks_map SEC(".maps");

SEC("xdp")
int xdp_afxdp_icmp_redirect(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data     = (void *)(long)ctx->data;

    /* -------------------------------------------------------------
     * Q: How does the XDP program determine whether a packet is
     *    ICMP?
     * A: Two header checks, both bounds-checked against data_end
     *    before any field is read (required for the eBPF verifier
     *    to accept the program):
     *      1. Ethernet header's h_proto must be ETH_P_IP (IPv4).
     *         Anything else (ARP, IPv6, VLAN-tagged, etc.) is not
     *         our concern here and falls through to XDP_PASS.
     *      2. IPv4 header's protocol field must be IPPROTO_ICMP.
     *    No ICMP header fields themselves (type/code/checksum/
     *    payload) are inspected — classification stops at the IP
     *    protocol number.
     * ------------------------------------------------------------- */
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *iph = (void *)(eth + 1);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    if (iph->protocol != IPPROTO_ICMP)
        return XDP_PASS;

    /* -------------------------------------------------------------
     * Q: How is ctx->rx_queue_index used to select the AF_XDP
     *    socket?
     * A: rx_queue_index identifies which of the NIC's hardware RX
     *    queues this packet was received on. xsks_map is keyed by
     *    that same queue index, because an AF_XDP socket is bound
     *    to one specific (interface, queue) pair. Looking the queue
     *    index up in xsks_map tells us *which* userspace socket, if
     *    any, owns this queue's traffic. This is why userspace must
     *    insert its socket fd into xsks_map at exactly the queue
     *    index it bound to — a mismatch here silently means packets
     *    never reach it.
     * ------------------------------------------------------------- */
    __u32 rx_queue_index = ctx->rx_queue_index;

    /* -------------------------------------------------------------
     * Q: What happens when no XSK is registered for the packet's RX
     *    queue?
     * A: bpf_redirect_map() performs the xsks_map lookup internally.
     *    If there is no socket registered for rx_queue_index (empty
     *    slot, or userspace hasn't bound/registered a socket for
     *    that queue yet), the redirect fails and the helper returns
     *    XDP_ABORTED-style failure internally, which here we treat
     *    explicitly: we check the return value and fall back to
     *    XDP_PASS ourselves rather than let the packet be dropped.
     *    This means the packet still reaches the normal Linux ICMP
     *    stack instead of vanishing. This also matters during
     *    startup/shutdown races, when the program may be attached
     *    slightly before or after userspace has finished populating
     *    the map.
     * ------------------------------------------------------------- */
    return bpf_redirect_map(&xsks_map, rx_queue_index, XDP_PASS);
}

char _license[] SEC("license") = "GPL";

/* -----------------------------------------------------------------------
 * Path of an ICMP packet, NIC -> userspace (full picture):
 *
 *  1. NIC driver, in native/driver XDP mode, hands the raw frame to this
 *     eBPF program *before* an skb is allocated — this program runs in
 *     driver context, per received frame, per RX queue.
 *  2. This program classifies the frame as IPv4/ICMP (Ethernet + IPv4
 *     header checks above) and looks up xsks_map[rx_queue_index].
 *  3. bpf_redirect_map() finds a bound AF_XDP socket for that queue and
 *     returns XDP_REDIRECT. The kernel's XDP redirect machinery then
 *     copies (copy mode) or flips ownership of (zero-copy mode) the
 *     frame's memory into a UMEM frame — the shared memory region that
 *     userspace registered with the kernel when it created the AF_XDP
 *     socket.
 *  4. The descriptor for that UMEM frame (address + length) is placed
 *     on the socket's RX ring — a lock-free single-producer/single-
 *     consumer ring shared between kernel and userspace via mmap.
 *  5. Userspace, polling/consuming the RX ring, sees the new descriptor,
 *     reads the ICMP packet directly out of the UMEM frame at that
 *     address (no further copy), and processes it (Part 2: counts it).
 *  6. Once userspace is done with that frame, it must recycle it by
 *     posting the frame's address back onto the UMEM's Fill ring —
 *     this tells the kernel "this UMEM frame is free, use it for a
 *     future RX." If frames are never recycled, the Fill ring empties
 *     and the kernel has nowhere to place new incoming packets on that
 *     queue, effectively stalling RX.
 *
 * Note the asymmetry: this kernel program only ever produces step 3's
 * decision (via the third argument to bpf_redirect_map, the fallback
 * action on lookup miss). Steps 4-6 (UMEM, RX ring, Fill ring mechanics)
 * are entirely kernel-generic AF_XDP infrastructure plus userspace
 * bookkeeping — nothing here in the XDP program is ICMP- or UMEM-aware
 * beyond issuing the redirect.
 * ----------------------------------------------------------------------- */

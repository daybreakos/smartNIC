1. Map definition ( 'xsks_map' )

Ref: [map_xskmap](https://docs.kernel.org/bpf/map_xskmap.html)
Definition: `/usr/include/linux/bpf.h` 

- This map is defined globalle in the  kernel, our program declared as instance of it  using 
`SEC(".maps)`.
- User-space  interacts with this map via a file descriptor `map_fd` using standard `libbpf` helper finctions
like `bpf_map_update_elem()` to bind socket file descriptor to specific queue indices. 

- `struct xdp_md` (XDP metadata context) is the context structure passed automatically by the kernel as an
  argument to any function tagged with `SEC("xdp")` 

  When a packet arrives at the NIC driver, the kernel wraps essential a pkt pointers and hw meta-data into
  `struct xdp_md` before executing the eBPF code. 

  - key fields of `struct xdp_md`:
    - `__u32 data` : starting memory addr of the raw packet data. 
    - `__u32 data_end` : The ending memory addr of the packet buffer ( Casting these two to `void * ` allows
      to safely perform bounds-checking before reading headers.)

    - `__u32 data_meta`: ptr used to pass custom metadata backwards from XDP to higher layers like traffic
      control `tc`.

    - `__u32 ingress_ifindex` : Network interface index ( `ifindex` ) that received the pkt. 

    - `__u32 rx_queue_index` : specific HW Recv (RX) Queue index that caught the packet. 
      (This is key for `AF_XDP` as  it tells the prog which queue/socket mapping to look up in the XSKMAP).  


```C
struct {
    __uint(type, BPF_MAP_TYPE_XSKMAP);
    __type(key, __u32);
    __type(value, __u32);
    __uint(max_entries, 64);
} xsks_map SEC(".maps");
```

- This create a BPF map of type `BPF_MAP_TYPE_XSKMAP`. 
- The map acts as bridge between kernel <=> user-space. 
- User-space populates it so the XDP program knows which socket to send matching packet to. 

- Key:value =
    - key: `__u32` representing the NIC's RX queue Index 
    - value: `__u32` representing file descriptor of the `AF_XDP` socket bound to that queue. 


2. Bounds checking ( eBPF verifier ): 

```C 
void *data_end = (void *)(long)ctx->data_end;
    void *data     = (void *)(long)ctx->data;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;
```

- The kernel eBPF verifier is strict => will refuse to load prog that might read out-of bounds memory ( that
  is to prevent kernel crash or leak data )

- Before reading any byte of the pkt, program compares the header ptr (`eth + 1`) against `data_end`. If the
  pkt is too short to contain Ethernet header, it returns `XDP_PASS` ( forward to kernel network stack)

3. pkt classification ( Ethernet & IPv4 ICMP checking )

```C 
if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *iph = (void *)(eth + 1);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    if (iph->protocol != IPPROTO_ICMP)
        return XDP_PASS;
```
- Checks the Ethernet hdr to ensure the protocol is `IPv4` (`ETH_P_IP`). If it's `ARP`, `IPv6`, or anything
  else, it ignores it (`XDP_PASS`).

- It bounds-checks the IPv4 header (`iph + 1`).

- Inspects the IP protocol field ( `iph->protocol` ) to see if it `IPPROTO_ICMP`.

This is like a filter: selecting only `ICMP` ( `IPv4` ) are selected for `AF_XDP` redirection, everything
else flows normally through the standard Linux networking stack. 
No ICMP payload check is ignored, => doesn't care about echo requests vs replies. i.e it's a protocol
filter.

4. Redirection ( `bpf_redirect_map` )

```C 
    __u32 rx_queue_index = ctx->rx_queue_index;

    return bpf_redirect_map(&xsks_map, rx_queue_index, XDP_PASS);
```

- `ctx->rx_queue_index` finds out which HW receive queue the packet arrived on. 
- calls `bpf_redirect_map()` this looks up `rx_queue_index` inside `xsks_map`.

- Fallback mechanism `XDP_PASS` 3rd argument: If user-space hasn't registered a socket for this queue ( or
  if there is a startup race condition ) the map lookup will fail. Instead of dropping pkt or causing a hard
  error, the helper falls back to `XDP_PASS` , so the pkt still reaches normal Linux ICMP stack.




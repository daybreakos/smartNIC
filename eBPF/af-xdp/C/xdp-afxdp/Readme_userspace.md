1. Loading + Attaching xdp program  

- Open the compiled BPF obj file using: `bpf_object__open_file()`  ( `libbpf.h` ) and loads it into tjthe
  kernel using `bpf_object__load()`

- Attach the program to the network interface `ifindex` using `bpf_xdp_attach()` ( falls back to
  XDP_FLAG_SKB_MODE if XDP_FLAG_DRV_MODE is not supported )

- Locates and returns the file descriptor (`map_fd`) for the `xsks_map` to user-space can write to it later.


2. Allocating and Pre-Filling UMEM: ( `configure_umem` )

- Allocates a large, page-aligned block of shared memory ( `buffer` ) using `posix_memalign()` split into
  4096-byte frames ( `NUM_FRAMES * FRAME_SIZE` ). This memory region is called UMEM. 

- Registers this UMEM with kernel via `xsk_umem__create()` which sets up two primary rings:
    - Fill Ring: user-space telling the kernel which frames are free to receive new packets 
    - Completion Ring: used for TX, through unused here.

- Pre-fills the Fill Ring: It immediately reserves all 4096 frame slots and hands their address to the
  kernel. Without this step the kernel has Zero memory buffers to write incoming pkts into, and Rx would
  instantly stall. 


3. Create the AF_XDP Socket ( `configure_socket` )

- Creates an `AF_XDP` socket using `xsk_socket__create()` bound to a specific network interface and receive
  queue (`ifname`, `queue_id`), sharing the UMEM created in above step 2.

- Uses the configuration flag `XSK_LIBXDP_FLAGS__INHIBIT_PROG_LOAD`. 
  This tells the helper library: "Do not load a default XDP prog; I already loaded my custom one in stepp 1"

- Sets up the socket's dedicated RX Ring (where the kernel drops descriptors of packets that matched our
  filter).

4. Registering the Socket into the XSKMAP (main)

- Retrieves the socket's internal file descriptor (`xsk_socket__fd`).

- Calls `bpf_map_update_elem()` to insert this file descriptor into `xsks_map` using the queue_id as the key.

- The Connection Point: This is the exact moment the kernel program and userspace meet. 
    - When a packet arrives on `queue_id`, the eBPF kernel program looks up `xsks_map[queue_id]`, 
      finds this socket descriptor, and redirects the packet directly into this socket's `UMEM` frames.

5. The Polling, RX, and Recycling Loop (handle_rx & main)

- Polling: Uses standard poll() on the socket's file descriptor with a 200ms timeout to wake up when new
  packets arrive without burning 100% CPU.

- Consuming RX: When data is ready, `xsk_ring_cons__peek()` checks the RX ring to see how many frames 
  arrived.
- Counting: It iterates through the received descriptors and increments `g_icmp_count`. Because the kernel 
  program already filtered for ICMP, no payload inspection is required.

- Recycling (Crucial): Every consumed frame address is immediately pushed right back onto the Fill Ring
  `(*xsk_ring_prod__fill_addr(...))`. If you don't recycle frames instantly, the Fill ring empties, the 
  Kernel runs out of write buffers, and packet collection permanently stops.

- Printing: Every second, it prints the running total of received ICMP packets to the console.

6. cleanup:

- On press `Ctrl+C` (triggered by SIGINT), the prog exits the loop.
  It deletes the `AF_XDP` socket ( `xsk_socket__delete` ), unregisters the UMEM, detaches the XDP program 
  from the interface (`bpf_xdp_attach` with `-1` ), and closes the BPF object.

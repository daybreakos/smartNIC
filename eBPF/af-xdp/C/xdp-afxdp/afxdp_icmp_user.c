/* -----------------------------------------------------------------------
 * PART 2 (C) — Userspace AF_XDP loader / receive loop
 *
 * Responsibilities (see the numbered comments inline):
 *   A. Load + attach the XDP program (xdp_afxdp_icmp_kern.o) to an iface
 *   B. Set up UMEM (shared packet-buffer region) + Fill/Completion rings
 *   C. Create an AF_XDP socket bound to (iface, queue), with RX/TX rings
 *   D. Register the socket's fd into xsks_map at the bound queue index
 *   E. RX loop: for every received frame, just count it and recycle the
 *      buffer back onto the Fill ring — no packet inspection/response.
 *   F. Print the running counter once per second.
 *
 * This intentionally skips TX entirely: we never build or send a reply,
 * we only consume + recycle. That's what "do not process the packets"
 * means here.
 *
 * Build against libbpf (bpf/libbpf.h, bpf/xsk.h) the same way the other
 * xdp-tutorial lessons do.
 * ----------------------------------------------------------------------- */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <poll.h>
#include <time.h>
#include <errno.h>
#include <net/if.h>
#include <linux/if_link.h>   /* XDP_FLAGS_DRV_MODE / SKB_MODE / etc. */

#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include <xdp/xsk.h>   /* moved out of libbpf into libxdp as of libbpf 1.0+ */

#define NUM_FRAMES        4096
#define FRAME_SIZE        XSK_UMEM__DEFAULT_FRAME_SIZE   /* 4096 bytes */
/* Fill ring must be able to hold every UMEM frame at once, since we
 * pre-populate it fully in configure_umem() below (there's no separate
 * TX free-list here — we never transmit). Must be a power of two. */
#define FILL_RING_SIZE    NUM_FRAMES
#define COMP_RING_SIZE    XSK_RING_CONS__DEFAULT_NUM_DESCS
#define RX_RING_SIZE      XSK_RING_CONS__DEFAULT_NUM_DESCS
#define TX_RING_SIZE      XSK_RING_PROD__DEFAULT_NUM_DESCS
#define RX_BATCH_SIZE     64
#define XSKS_MAP_NAME     "xsks_map"

struct xsk_umem_info {
    struct xsk_ring_prod fill;   /* userspace -> kernel: frames free for RX  */
    struct xsk_ring_cons comp;   /* kernel -> userspace: frames TX'd (unused here) */
    struct xsk_umem *umem;
    void *buffer;                /* the raw UMEM memory region              */
};

struct xsk_socket_info {
    struct xsk_ring_cons rx;     /* kernel -> userspace: received frames     */
    struct xsk_ring_prod tx;     /* unused: we never transmit                */
    struct xsk_umem_info *umem;
    struct xsk_socket *xsk;
};

static volatile sig_atomic_t g_stop;
static unsigned long g_icmp_count;   /* E: the packet counter */

static void handle_sigint(int sig)
{
    (void)sig;
    g_stop = 1;
}

/* -----------------------------------------------------------------------
 * A. Load the compiled XDP object and attach it natively to `ifindex`.
 *    Returns the fd of xsks_map so it can be populated in step D.
 * ----------------------------------------------------------------------- */
static int load_and_attach_xdp(const char *obj_path, int ifindex,
                                struct bpf_object **obj_out)
{
    struct bpf_object *obj;
    struct bpf_program *prog;
    int prog_fd, map_fd;

    obj = bpf_object__open_file(obj_path, NULL);
    if (libbpf_get_error(obj)) {
        fprintf(stderr, "ERR: opening BPF object %s failed\n", obj_path);
        return -1;
    }

    if (bpf_object__load(obj)) {
        fprintf(stderr, "ERR: loading BPF object failed\n");
        return -1;
    }

    prog = bpf_object__next_program(obj, NULL);
    if (!prog) {
        fprintf(stderr, "ERR: no program found in object\n");
        return -1;
    }
    prog_fd = bpf_program__fd(prog);

    /* Native (driver) mode; swap to SKB mode for testing on interfaces
     * without native XDP support (e.g. veth in some configs). */
    if (bpf_xdp_attach(ifindex, prog_fd, XDP_FLAGS_DRV_MODE, NULL) < 0) {
        fprintf(stderr, "ERR: attaching XDP program to ifindex %d failed\n",
                ifindex);
        return -1;
    }

    map_fd = bpf_object__find_map_fd_by_name(obj, XSKS_MAP_NAME);
    if (map_fd < 0) {
        fprintf(stderr, "ERR: could not find map '%s'\n", XSKS_MAP_NAME);
        return -1;
    }

    *obj_out = obj;
    return map_fd;
}

/* -----------------------------------------------------------------------
 * B. Allocate the UMEM buffer and register it with the kernel, creating
 *    the Fill and Completion rings. Then pre-populate the Fill ring so
 *    the kernel has somewhere to place the very first received frames —
 *    without this, RX simply has no buffers to write into and nothing
 *    ever arrives.
 * ----------------------------------------------------------------------- */
static struct xsk_umem_info *configure_umem(void)
{
    struct xsk_umem_info *u = calloc(1, sizeof(*u));
    struct xsk_umem_config cfg = {
        .fill_size = FILL_RING_SIZE,
        .comp_size = COMP_RING_SIZE,
        .frame_size = FRAME_SIZE,
        .frame_headroom = XSK_UMEM__DEFAULT_FRAME_HEADROOM,
        .flags = 0,
    };
    int ret;

    if (posix_memalign(&u->buffer, getpagesize(),
                        NUM_FRAMES * FRAME_SIZE)) {
        fprintf(stderr, "ERR: posix_memalign for UMEM failed\n");
        exit(EXIT_FAILURE);
    }

    ret = xsk_umem__create(&u->umem, u->buffer, NUM_FRAMES * FRAME_SIZE,
                            &u->fill, &u->comp, &cfg);
    if (ret) {
        fprintf(stderr, "ERR: xsk_umem__create failed (%d)\n", ret);
        exit(EXIT_FAILURE);
    }

    /* Pre-fill: hand every UMEM frame to the kernel as RX-available.
     * Frame addresses are simply i * FRAME_SIZE offsets into the UMEM. */
    __u32 idx;
    ret = xsk_ring_prod__reserve(&u->fill, NUM_FRAMES, &idx);
    if (ret != NUM_FRAMES) {
        fprintf(stderr, "ERR: could not reserve fill ring entries\n");
        exit(EXIT_FAILURE);
    }
    for (__u32 i = 0; i < NUM_FRAMES; i++)
        *xsk_ring_prod__fill_addr(&u->fill, idx + i) = i * FRAME_SIZE;
    xsk_ring_prod__submit(&u->fill, NUM_FRAMES);

    return u;
}

/* -----------------------------------------------------------------------
 * C. Create the AF_XDP socket bound to (ifname, queue_id), sharing the
 *    UMEM from step B. XSK_LIBXDP_FLAGS_INHIBIT_PROG_LOAD is critical
 *    here: it tells libxdp NOT to load/attach its own default XDP
 *    program on this interface, because we already loaded and attached
 *    our own custom one in step A. Without this flag, libxdp would
 *    install a second program that conflicts with ours.
 * ----------------------------------------------------------------------- */
static struct xsk_socket_info *configure_socket(struct xsk_umem_info *umem,
                                                  const char *ifname,
                                                  int queue_id)
{
    struct xsk_socket_info *xsk = calloc(1, sizeof(*xsk));
    struct xsk_socket_config cfg = {
        .rx_size = RX_RING_SIZE,
        .tx_size = TX_RING_SIZE,
        .libxdp_flags = XSK_LIBXDP_FLAGS__INHIBIT_PROG_LOAD, //XSK_LIBXDP_FLAGS_INHIBIT_PROG_LOAD,
        .xdp_flags = XDP_FLAGS_DRV_MODE,
        .bind_flags = XDP_USE_NEED_WAKEUP,
    };
    int ret;

    xsk->umem = umem;
    ret = xsk_socket__create(&xsk->xsk, ifname, queue_id, umem->umem,
                              &xsk->rx, &xsk->tx, &cfg);
    if (ret) {
        fprintf(stderr, "ERR: xsk_socket__create failed (%d)\n", ret);
        exit(EXIT_FAILURE);
    }

    return xsk;
}

/* -----------------------------------------------------------------------
 * E. RX loop body: drain whatever frames are currently on the RX ring.
 *    For each: bump the counter (no header/payload inspection at all —
 *    the kernel program already guaranteed these are ICMP), then
 *    immediately return that frame's address to the Fill ring so the
 *    kernel can reuse it for a future incoming packet.
 *
 *    This recycling step is mandatory: the Fill ring holds a strictly
 *    limited number of frame slots (NUM_FRAMES). Every frame consumed
 *    from RX and not returned to Fill is a slot permanently lost —
 *    after NUM_FRAMES such leaks, the kernel has no buffers left to
 *    place new packets in and RX on this queue effectively stalls.
 * ----------------------------------------------------------------------- */
static void handle_rx(struct xsk_socket_info *xsk)
{
    __u32 idx_rx, idx_fq;
    unsigned int rcvd = xsk_ring_cons__peek(&xsk->rx, RX_BATCH_SIZE, &idx_rx);

    if (!rcvd)
        return;

    /* Reserve an equal number of Fill ring slots before consuming RX,
     * so recycling always has room (same pattern as the tutorial). */
    unsigned int ret = xsk_ring_prod__reserve(&xsk->umem->fill, rcvd, &idx_fq);
    while (ret != rcvd)
        ret = xsk_ring_prod__reserve(&xsk->umem->fill, rcvd, &idx_fq);

    for (unsigned int i = 0; i < rcvd; i++) {
        __u64 addr = xsk_ring_cons__rx_desc(&xsk->rx, idx_rx + i)->addr;

        /* No parsing, no response — just count. The kernel program
         * already established this frame is IPv4/ICMP. */
        g_icmp_count++;

        /* Recycle: this frame's address goes straight back onto the
         * Fill ring, unchanged, so the kernel can write a new packet
         * into it on a future RX. */
        *xsk_ring_prod__fill_addr(&xsk->umem->fill, idx_fq + i) = addr;
    }

    xsk_ring_prod__submit(&xsk->umem->fill, rcvd);
    xsk_ring_cons__release(&xsk->rx, rcvd);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <ifname> [queue_id] [bpf_obj_path]\n",
                argv[0]);
        return EXIT_FAILURE;
    }

    const char *ifname   = argv[1];
    int queue_id         = (argc > 2) ? atoi(argv[2]) : 0;
    const char *obj_path = (argc > 3) ? argv[3] : "xdp_afxdp_icmp_kern.o";

    int ifindex = if_nametoindex(ifname);
    if (!ifindex) {
        fprintf(stderr, "ERR: unknown interface %s\n", ifname);
        return EXIT_FAILURE;
    }

    signal(SIGINT, handle_sigint);
    signal(SIGTERM, handle_sigint);

    /* A: load + attach kernel program, get xsks_map fd */
    struct bpf_object *bpf_obj;
    int xsks_map_fd = load_and_attach_xdp(obj_path, ifindex, &bpf_obj);
    if (xsks_map_fd < 0)
        return EXIT_FAILURE;

    /* B: UMEM + Fill/Completion rings, pre-filled */
    struct xsk_umem_info *umem = configure_umem();

    /* C: AF_XDP socket bound to (ifname, queue_id) over that UMEM */
    struct xsk_socket_info *xsk = configure_socket(umem, ifname, queue_id);

    /* -----------------------------------------------------------------
     * D. Register this socket's fd into xsks_map at `queue_id`. This is
     *    the step that actually connects the kernel program's redirect
     *    decision to this specific socket: from now on, ICMP packets
     *    arriving on RX queue `queue_id` will be redirected here.
     * ----------------------------------------------------------------- */
    int xsk_fd = xsk_socket__fd(xsk->xsk);
    if (bpf_map_update_elem(xsks_map_fd, &queue_id, &xsk_fd, 0)) {
        fprintf(stderr, "ERR: updating xsks_map failed\n");
        return EXIT_FAILURE;
    }

    printf("Listening for ICMP on %s queue %d (Ctrl-C to stop)...\n",
           ifname, queue_id);

    struct pollfd pfd = { .fd = xsk_fd, .events = POLLIN };
    struct timespec last_print, now;
    clock_gettime(CLOCK_MONOTONIC, &last_print);

    /* E + F: poll for RX activity, recycle via Fill ring, print once/sec */
    while (!g_stop) {
        int ret = poll(&pfd, 1, 200 /* ms timeout, so we still wake to print */);
        if (ret < 0 && errno != EINTR) {
            fprintf(stderr, "ERR: poll failed\n");
            break;
        }

        if (ret > 0 && (pfd.revents & POLLIN))
            handle_rx(xsk);

        clock_gettime(CLOCK_MONOTONIC, &now);
        double elapsed = (now.tv_sec - last_print.tv_sec) +
                          (now.tv_nsec - last_print.tv_nsec) / 1e9;
        if (elapsed >= 1.0) {
            printf("ICMP packets received: %lu\n", g_icmp_count);
            last_print = now;
        }
    }

    /* Cleanup: unbind socket, free UMEM, detach program. */
    xsk_socket__delete(xsk->xsk);
    xsk_umem__delete(umem->umem);
    free(umem->buffer);
    bpf_xdp_attach(ifindex, -1, XDP_FLAGS_DRV_MODE, NULL);
    bpf_object__close(bpf_obj);

    printf("Final ICMP count: %lu\n", g_icmp_count);
    return 0;
}

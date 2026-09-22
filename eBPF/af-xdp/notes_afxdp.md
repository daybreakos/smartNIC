# AF_XDP: 

AF_XDP: A Linux Socket to kernel by-pass packet processing:


## 1. What is AF_XDP?

**AF_XDP (Address Family XDP)** : It'a a Linux socket interface designed for **high-performance packet
processing from user-space**.

The idea behind is not simply: 

> "AF_XDP is a faster socket."

A better description is:

> **AF_XDP provides a socket-based interface through which packets received by an XDP program can be
> redirected directly into user-space-managed packet buffers, avoiding the normal Linux networking stack for
> those packets.**

This gives us a path like:

```text
Normal networking:                  With AF_XDP:             
-----------------                   ------------                                                             
    NIC                                 NIC                  
    │                                   │                   
    ▼                                   ▼                   
    Driver                              Driver               
    │                                   │                   
    ▼                                   ▼                   
    Kernel networking stack             XDP                  
    │                                   │                   
    ▼                                   ▼                   
    TCP/IP                              XSKMAP               
    │                                   │                   
    ▼                                   ▼                   
    socket()                            AF_XDP socket        
    │                                   │                   
    ▼                                   ▼                   
    Application                         `UMEM`                 
                                        │                   
                                        ▼                   
                                        user-space application

```

AF_XDP therefore sits at the boundary between:
    * The Linux networking subsystem,
    * XDP/eBPF,
    * and user-space packet processing.

---

## 2. Start with the traditional Linux `socket()`

Before understanding `AF_XDP`, it is useful to understand what this(`socket()`) familiar call means:
A socket is a programming function that tells the OS to create a communication endpoint, it returns a file
descriptor ( a unique ID ) so the program can send and receive data across a network or local system.
In this process the OS network stack does all the heavy lifting leaving the programmer to focus on this
program logic. 
The socket acts as a two way bi-directional pipe for sending and receiving bytes between two different
programs or devices. 

In C, C++, Python calling `socket()` triggers the OS to setup the SW structures required for networking. 
```c
int fd = socket(AF_INET, SOCK_STREAM, 0);
```
Arguments:
    - Domain ( Address family ): Specified communication realm.
        * AF_INET: for IPv4 internet protocol 
        * AF_UNIX: or (AF_LOCAL) for Local communication on the same physical machine. 
        * AF_XDP: A high high-performance Linux socket add-family optimized for raw pkt processing that
          bypasses most of the traditional OS network stack.
        The list is long covering. 
    - Type: Specifies communication semantics.
        * SOCK_STREAM: for reliable, ordered, connection-oriented streams like TCP.
        * SOCK_DGRAM: for connectionless, best-effort datagrams using UDP.
    - Protocol: Specifies a particular protocol to use with the socket ( usually its '0' to pick the default
      choice for the chosen domain and type.)

## 3. Address Family 

**Address family** tells the kernel what kind of addressing/networking domain the socket belongs to.
The family and socket type are separate concepts.
Conceptually:

```text
    socket()
       │
       ├── address family
       │       │
       │       └── AF_INET   ( socket belongs to IPv4 networking family)
       │
       ├── socket type
       │       │
       │       └── SOCK_STREAM 
       │
       └── protocol
               │
               └── TCP
```

---

## 4. Types of Linux address families

Linux supports many address families.

Some common ones are:

```text
AF_INET       IPv4
AF_INET6      IPv6
AF_UNIX       local Unix-domain communication
AF_NETLINK    kernel/user-space networking communication
AF_PACKET     raw link-layer packet access
AF_XDP        XDP packet processing
```

The family determines which kernel networking subsystem will handle the socket.

This is an important concept:

> **`socket()` is a generic API, but the address family determines what the socket actually represents.**

---

## 5. What happens inside the kernel?

Consider:

```c
int fd = socket(AF_INET, SOCK_STREAM, 0);
```

The application is asking the kernel:

> "Create a socket object representing an IPv4 TCP endpoint and give me a file descriptor through which I
> can interact with it."

The simplified flow is:

```text
    Application
         │
         │ socket()
         ▼
    User/kernel boundary
         │
         ▼
    Linux socket subsystem
         │
         ▼
    AF_INET implementation
         │
         ▼
    TCP subsystem
         │
         ▼
    socket object
         │
         ▼
    file descriptor
```

The returned integer:

```c
fd
```

is **not the network connection itself**.

It is a file descriptor referring to a kernel socket object.

---

## 6. What happens when data arrives?

Suppose an Ethernet packet arrives:

```text
             NIC
              │
              ▼
         NIC driver
              │
              ▼
          RX buffer
              │
              ▼
       Linux networking
          subsystem
              │
              ▼
       protocol processing
              │
       ┌──────┴───────┐
       ▼              ▼
      IPv4            IPv6
       │
       ▼
      TCP
       │
       ▼
   TCP socket
       │
       ▼
   socket receive
       │
       ▼
    user-space
```

The application eventually calls:

```c
recv(fd, buffer, size, 0);
```

or:

```c
read(fd, buffer, size);
```

The kernel finds data associated with that socket and copies or otherwise transfers the data into user-space
memory.

---

## 7. The traditional socket abstraction

From the application's perspective:

```text
socket()
   │
   ▼
file descriptor
   │
   ├── bind()
   ├── listen()
   ├── connect()
   ├── send()
   ├── recv()
   └── close()
```

The kernel hides a lot of complexity.

The application doesn't normally need to know:

* which NIC received the packet,
* which RX queue received it,
* which DMA descriptor was used,
* where the NIC DMA'd the packet,
* how the driver's RX ring works,
* how the packet moved through the network stack.

The kernel owns all of that.
That abstraction is extremely useful.
But it also means that a packet goes through substantial kernel processing before the application sees it.

---

## 8. Why is this expensive for high-speed packet processing?

Consider a packet-processing application that doesn't actually need TCP/IP.

For example:

> Receive an Ethernet frame, inspect it, modify the MAC address, and transmit it.

Using a traditional socket, the packet may travel through:

```text
    NIC
     │
     ▼
    NIC driver
     │
     ▼
    RX processing
     │
     ▼
    XDP/SKB/network stack
     │
     ▼
    Ethernet processing
     │
     ▼
    IP processing
     │
     ▼
    TCP/UDP processing
     │
     ▼
    socket layer
     │
     ▼
    user-space
```

But our application may only need:

```text
    Ethernet frame
          │
          ▼
    user-space
          │
          ▼
    Ethernet frame
```

The traditional socket abstraction is therefore doing work that our application doesn't necessarily need.

---

## 9. What about `AF_PACKET`?

Linux already provides:

```c
socket(AF_PACKET, ...);
```

which gives user-space access to packets at the link layer.

This is useful for things such as:

* packet capture,
* network monitoring,
* raw packet generation,
* tools such as packet analyzers.

The path is conceptually closer to:

```text
    NIC
    │
    ▼
    driver
    │
    ▼
    Linux packet processing
    │
    ▼
    AF_PACKET
    │
    ▼
    user-space
```

But `AF_PACKET` still operates within the traditional Linux packet-processing architecture.

For extremely high packet rates, the kernel/user-space interaction and packet-buffer handling can become
significant.

This is where `XDP` and `AF_XDP` become interesting.

---

## 10. XDP

**XDP (eXpress Data Path)** allows an eBPF program to run very early in the receive path.

Conceptually:

```text
    NIC
    │
    ▼
    NIC driver
    │
    ▼
    +------------------+
    |       XDP        |
    |     eBPF code    |
    +------------------+
    │
    ├── XDP_DROP
    ├── XDP_PASS
    ├── XDP_TX
    └── XDP_REDIRECT
```

This gives us an early decision point.

For example:

```c
    SEC("xdp")
    int my_xdp(struct xdp_md *ctx)
    {
    return XDP_DROP;
    }
```

Packets can be dropped without going through the normal networking stack.

Or:

```c
return XDP_PASS;
```

allows the packet to continue toward the normal Linux networking stack.

---

## 11. XDP is not AF_XDP

This distinction is extremely important.

**XDP** is an execution mechanism:

```text
    NIC packet
        ↓
    XDP/eBPF program
        ↓
    decision
```

**AF_XDP** is a user-space packet-delivery mechanism:

```text
    XDP
      ↓
    AF_XDP socket
      ↓
    user-space
```

`AF_XDP` uses `XDP` as the mechanism for deciding:

> "This packet should go to this user-space socket."

---

## 12. What does AF_XDP add?

`AF_XDP` introduces another address family:

```text
AF_XDP
```

So user-space can create:

```c
socket(AF_XDP, SOCK_RAW, 0);
```

The exact APIs used around the socket are more involved than a traditional TCP socket, but conceptually:

```text
AF_XDP socket
      │
      ▼
XDP packet redirect
      │
      ▼
user-space packet buffer
```

This is the key extension.

Instead of asking:

> "Give me bytes from a TCP/UDP connection."

we are effectively asking:

> "Give me access to packets redirected from an XDP program."

---

## 13. What makes the AF_XDP socket special?

A normal socket is primarily an abstraction around a kernel protocol endpoint.

An AF_XDP socket is tightly connected to:

    ```text
    XDP
     +
    XSK
     +
    `UMEM`
     +
    rings
     +
    NIC RX/TX queues
```

The socket therefore participates in a much more explicit packet-buffer life-cycle.

The major components are:

```text
                  AF_XDP
                     │
         ┌───────────┼───────────┐
         │           │           │
       XSK         `UMEM`        Rings
         │           │           │
         │           │      ┌────┴─────┐
         │           │      │          │
         │           │     RX         TX
         │           │
         │      ┌────┴─────┐
         │      │          │
         │    FILL    COMPLETION
         │
         ▼
      XSKMAP
         │
         ▼
       XDP
```

---

## 14. What is `UMEM`?

``UMEM`` is the memory region used for packet buffers.

Instead of the kernel allocating an arbitrary packet buffer and then copying packet data into an
application's buffer, the application provides a region of memory divided into frames.

For example:

```text
`UMEM`

+--------+--------+--------+--------+--------+
| frame0 | frame1 | frame2 | frame3 | frame4 |
+--------+--------+--------+--------+--------+
```

Each frame can hold a packet.

For example:

```text
frame 0
+--------------------------------------+
| Ethernet | IP | TCP | payload        |
+--------------------------------------+
```

The important idea is:

> **user-space owns the packet-buffer memory and participates in its life-cycle.**

This is fundamentally different from a traditional socket where the kernel largely manages packet buffers
internally.

---

## 15. Why do we need rings?

user-space and the kernel need a very efficient way to communicate:

> "Here are buffers."

and:

> "Here are received packets."

and:

> "These transmitted buffers are finished."

Instead of repeatedly calling:

```text
syscall
syscall
syscall
syscall
```

`AF_XDP` uses shared producer/consumer rings.

There are four important rings:

```text
             user-space              Kernel

               │
               │ FILL
               ├──────────────────►
               │
               │
               │              RX
               │◄──────────────────
               │
               │
               │ TX
               ├──────────────────►
               │
               │
               │ COMPLETION
               │◄──────────────────
```

The four rings are:

```text
   - FILL
   - RX
   - TX
   - COMPLETION
```

---

## 16. FILL ring

The Fill ring answers:

> "Which `UMEM` frames may the kernel use for receiving packets?"

For example:

```text
user-space

frame 0 ─┐
frame 1 ─┤
frame 2 ─┼──► FILL ring ──► Kernel/NIC
frame 3 ─┤
frame 4 ─┘
```

The kernel can then place incoming packets into those frames.

---

## 17. RX ring

The RX ring tells user-space:

> "Packets have arrived in these `UMEM` frames."

For example:

```text
    NIC
     │
     ▼
    frame 3
     │
     ▼
    RX descriptor
     │
     ▼
    RX ring
     │
     ▼
    user-space
```

The RX descriptor contains information allowing user-space to locate the packet inside `UMEM`.

Conceptually:

```text
RX descriptor

    address ──► `UMEM` frame
    length  ──► packet length
    options ──► descriptor metadata
```

---

## 18. TX ring

user-space can also send packets.

It puts descriptors onto the TX ring:

```text
    user-space
       │
       ▼
    `UMEM` frame
       │
       ▼
    TX descriptor
       │
       ▼
    TX ring
       │
       ▼
    kernel / NIC
```

This allows user-space to prepare a packet in `UMEM` and tell the kernel:

> "Transmit this frame."

---

## 19. Completion ring

After transmission completes, the kernel needs to tell user-space:

> "This `UMEM` frame is available again."

That's the Completion ring:

```text
    TX
    │
    ▼
    NIC
    │
    ▼
    transmission completed
    │
    ▼
    COMPLETION ring
    │
    ▼
    user-space
    │
    ▼
    reuse frame
```

So the four rings together implement a buffer life-cycle.

---

## 20. The important difference from traditional sockets

Traditional socket:

```text
    Application
         │
         │ recv()
         ▼
    Kernel socket buffers
         │
         ▼
    kernel networking stack
         │
         ▼
    NIC
```

AF_XDP:

```text
                       `UMEM`
                         │
                         │
NIC ──► XDP ──► XSK ─────┼────► user-space
                         │
                         │
                    shared buffers
```

The application gets much more direct control over packet memory and packet movement.

---

## 21. How does the XDP program find the correct `AF_XDP` socket?

This is where `XSKMAP` enters.

Suppose the NIC has:

```text
RX queue 0
RX queue 1
RX queue 2
RX queue 3
```

user-space creates:

```text
XSK0 → queue 0
XSK1 → queue 1
XSK2 → queue 2
XSK3 → queue 3
```

The XSKMAP might look conceptually like:

```text
XSKMAP

    key       value
    -------------------
      0       XSK0
      1       XSK1
      2       XSK2
      3       XSK3
```

Then the XDP program does:

```text
    packet
       │
       ▼
    RX queue = 2
       │
       ▼
    XSKMAP[2]
       │
       ▼
    XSK2
```

and redirects the packet there.

---

## 22. Why doesn't XDP need to understand `UMEM`?

Because the responsibilities are deliberately separated.

XDP knows:

```text
    packet
      +
    RX queue
      +
    XSKMAP
```

user-space knows:

```text
    `UMEM`
      +
    frames
      +
    rings
      +
    packet processing
```

So:

```text
              Kernel
                 │
       ┌─────────┴─────────┐
       │                   │
      XDP                AF_XDP
       │                   │
  "where should       "how should
   packet go?"          packet be
                         processed?"
       │                   │
       └─────────┬─────────┘
                 │
              XSKMAP
                 │
                 ▼
             user-space
```

This separation is one of the most important concepts in `AF_XDP`.

---

## 23. What does `socket()` really "extend" in AF_XDP?

It is tempting to think:

> "AF_XDP adds some options to a normal socket."

That's only partially correct.

It does use the Linux socket abstraction:

```c
socket(AF_XDP, ...)
```

and therefore gets a file descriptor.

But AF_XDP extends the socket concept into a **packet I/O endpoint backed by shared memory and rings**.

The resulting abstraction is closer to:

```text
                socket FD
                    │
              ┌─────┴─────┐
              │           │
           control       data
              │           │
          socket API     rings
              │           │
              │          `UMEM`
              │           │
              └─────┬─────┘
                    │
                   XDP
                    │
                   NIC
```

The socket FD is still important for:

* binding,
* configuration,
* polling,
* wakeups,
* life-cycle.

But **the high-volume packet data path is primarily driven through `UMEM` and rings rather than
`recv()`/`send()` for every packet.**

That distinction is crucial.

---

## 24. Why is this useful?

The design targets applications that want to process packets themselves.

Examples include:

```text
    packet capture
    DDoS filtering
    firewalls
    load balancers
    L2/L3 forwarding
    telemetry
    packet classification
    network appliances
    high-speed protocol processing
```

Instead of:

```text
    NIC
    ↓
    kernel networking
    ↓
    socket buffers
    ↓
    user-space
```

an application can construct:

```text
    NIC
     ↓
    XDP
     ↓
    AF_XDP
     ↓
    user-space
```

and therefore avoid portions of the normal networking stack.

---

## 25. But AF_XDP is not "the kernel is bypassed completely"

This is an important qualification.

`AF_XDP` is often described as "kernel bypass", but that can be misleading.

The NIC driver and kernel are still involved.

Conceptually:

```text
                Kernel
               │
  ┌────────────┼─────────────┐
  │            │             │
driver        XDP         AF_XDP
  │            │             │
  └────────────┼─────────────┘
               │
              NIC
```

What is bypassed is primarily the **normal networking stack for redirected packets**.

The kernel still participates in:

* `XDP` execution
* `NIC` driver interaction
* `UMEM`/ring management
* `AF_XDP` socket management
* wakeups
* packet transmission
* resource management

So a more precise statement is:

> **AF_XDP provides a low-overhead path for XDP-redirected packets between the NIC/XDP path and user-space,
> bypassing much of the conventional networking stack.**

---

## 26. The complete picture

Putting everything together:

```text
                         user-space
 ┌────────────────────────────────────────────────────┐
 │                                                    │
 │              AF_XDP application                    │
 │                                                    │
 │  ┌──────────────┐        ┌──────────────────────┐  │
 │  │ Packet logic │        │ AF_XDP socket        │  │
 │  └──────────────┘        └──────────┬───────────┘  │
 │                                     │              │
 │              ┌──────────────────────┼─────────┐    │
 │              │                      │         │    │
 │              UMEM                  RX/TX      FILL
 │                                    rings    /COMP  │
 └──────────────┼──────────────────────┼──────────────┘
                │                      │
                │                      │
════════════════╪══════════════════════╪════════════════
                │       KERNEL         │
                │                      │
                ▼                      │
          ┌─────────────┐              │
          │    XSK      │◄─────────────┘
          └──────┬──────┘
                 │
                 ▼
             XSKMAP
                 ▲
                 │
          bpf_redirect_map()
                 │
                 │
          ┌──────┴──────┐
          │ XDP program │
          └──────┬──────┘
                 │
                 ▼
              RX queue
                 │
                 ▼
              NIC driver
                 │
                 ▼
                NIC
```

And this gives us the fundamental division:

```text
              XDP / Kernel
                   │
                   │
             "Where does
             this packet go?"
                   │
                   ▼
                XSKMAP
                   │
                   ▼
              AF_XDP XSK
                   │
                   │
              "How do I
             process it?"
                   │
                   ▼
              user-space
```

---

## 27. Relating this directly to your implementation plan

Your earlier implementation plan now becomes much easier to understand.

### Kernel side

```text
XDP program
    │
    ├── obtain RX queue
    │
    ├── XSKMAP lookup
    │
    ├── redirect
    │
    └── PASS/DROP
```

### user-space setup

```text
    load XDP
        │
        ▼
    find XSKMAP
        │
        ▼
    allocate UMEM
        │
        ▼
    create rings
        │
        ▼
    create AF_XDP socket
        │
        ▼
    bind(interface, queue)
        │
        ▼
    insert XSK into XSKMAP
        │
        ▼
    populate FILL
```

### user-space runtime

```text
              RX ring
                 │
                 ▼
              packet
                 │
                 ▼
               UMEM
                 │
                 ▼
           packet processing
             /         \
          DROP          TX
                         │
                         ▼
                      TX ring
                         │
                         ▼
                        NIC
                         │
                         ▼
                    completion
                         │
                         ▼
                       FILL
```

That is essentially **AF_XDP in one picture**.

---

## 28. The key mental model

If you remember only five things, remember these:

### 1. `AF_INET`

```text
    socket()
    ↓    
    normal network protocol endpoint
``` 

The kernel largely manages packet processing and buffering.

### 2. `AF_PACKET`

```text
    socket()
       ↓
    link-layer packet access
```

More direct packet access, but still within the Linux packet-processing architecture.

### 3. XDP

```text
    NIC → driver → XDP
```

An early programmable decision point in the receive path.

### 4. AF_XDP

```text
    NIC → driver → XDP → XSK → user-space
```

Provides a high-performance user-space packet I/O path.

### 5. `UMEM` + rings

```text
    UMEM
      +
    FILL
      +
    RX
      +
    TX
      +
    COMPLETION
```

These provide the packet-buffer/data path between the kernel/NIC and user-space.

---

### The most important conceptual transition

The progression is:

```text
Traditional socket

        Application
             │
          recv()
             │
             ▼
        kernel socket
             │
             ▼
       network stack
             │
             ▼
            NIC
```

becomes:

```text
AF_XDP

        Application
             │
        packet loop
             │
       ┌─────┴─────┐
       │   UMEM    │
       │   rings   │
       └─────┬─────┘
             │
          AF_XDP
           socket
             │
           XSKMAP
             │
            XDP
             │
            NIC
```

So **AF_XDP doesn't eliminate the socket abstraction; it repurposes the socket abstraction as the
control/life-cycle endpoint for a much more explicit shared-memory packet I/O mechanism.**

That is the foundation for understanding why your eventual architecture has a relatively tiny Aya XDP
program but a substantially more complicated Rust user-space application.

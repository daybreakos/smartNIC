# OVS: 

## Introduction:

OVS is a multi-layer SW switch, Its designed to operate a virtual switch within Hypervisor and Container
environments such as KVM, Xen, Proxmox, to handle traffic between VM's and external physical networks. 

Since Hypervisor ( KVM ) and containers ( docker ) are built on top of standard Linux networking, "OVS" runs as native system daemon directly on the host OS. 

You can use Open vSwitch on standard Linux bare-metal server or desktop to replace or augment the
traditional Linux bridge ( `bridge-utils` / `ip link add br0 type bridge` ).


### Where Open-vSwitch can run:

- **Standard Linux Bare-metal**: 

    Runs as regular system service ( `ovs-vswitchd` and `ovsdb-server` ) on distributions like
    Ubuntu, Debian, RHEL, CentOs ..

- **Other OS's**: 

    `OVS` is ported to FreeBSD, and Microsoft ( Hyper-V )

- **SmartNICs / HW Switches**: 

    OVS runs on HW acceleration platforms and smart NICs using DPDK ( Data Plane Development kit ) or
    HW offloading.


### OVS over Linux Bridge:

Default Linux Switch is simple and light-weight and works excellently for simple setups, but lacks other
features like programmatic control, advance tunneling, enhanced monitoring. 

- **programmatic Control**: If you want to use a SDN controller to inject OpenFlow rules directly into
  host networking. 

- **Advanced tunneling**: If the host needs to act as gateway terminating `VXLAN` or `GRE` tunnels from 
other parts of the data center. 

- **Enhanced Monitoring**: If you require fine-grain traffic analytics via `sFlow` or `Netflow` directly from
  the host interface.



### Key Features: 

- `L2/L3 Switching`: Supports std bridging, MAC address learning, 802.1Q VLAN tagging, and trunking

- `Tunneling Protocols`: Built-in support for overlay networks using VXLAN, GRE, Geneve, and ERSPAN to
  connect VMs across different physical hosts.

- `OpenFlow Support`: Exposes programmatic control interfaces, allowing an SDN controller to dynamically
  manage and modify packet-forwarding rules

`Note`: 
--- 
- OpenFlow: 
    It's a vendor-neutral, southbound communication standard in SDN that separates the control plane
    from the data plane. It lets a centralized controller program the forwarding and flow tables of
    physical or virtual switches.
--- 

- **Network Visibility & QoS**: Integrates monitoring tools like NetFlow, sFlow, and RSPAN, alongside
  per-interface traffic policing and Quality of Service (QoS) controls


## Core Architecture:

**OVS** separates its components across the kernel and user space for performance and flexibility:

- `ovs-vswitchd`: The core user-space daemon that implements the switch logic and communicates with
  OpenFlow controllers.
- `ovsdb-server`: A lightweight JSON database daemon that stores configuration data persistently across
  system reboots.
- `Kernel Module`: Caches packet matches and actions for high-speed “fast path” forwarding, punting
  unmatched “slow path” packets up to user space (ovs-vswitchd).

### Basic management commands:

OVS bridges and ports can be managed using tools like `ovs-vsctl`:

- Create a bridge:

    `ovs-vsctl add-br br0`

- Add a port to a bridge: 
    
    `ovs-vsctl add-port br0 eth0`

## OVS overview:

OVS vSwitch consists of 3 main components that work together to move packets:


1. **Ports ( the doors )**: 
    - These are connection points where packets enter/leave. They can be physical cards on your
      server, or virtual ports connected to individual VMs or containers. 

2. **The Kernel Datapath ( The Fast Gate/ Worker )**: 
    - This lives inside the kernel and handles heavy lifting. Its job is to move packets as fast as
      possible using quick-reference list ( the `Megaflow cache` ). Most packets never leave this layer. 

3. **The user-space daemon / `ovs-vswitched` ( The brain/ Main office):
    - This runs in userspace (outside the kernel). It holds the big, complex rulebook called OpenFlow
      tables. The datapath only talks to this department when it doesn’t know what to do with a new
      kind of packet.

### **The Full Journey of a Packet**

When a packet flows through OVS from input to output, it takes this exact path:

1. **Arrival:** A packet arrives at an **Input Port** (e.g., from a VM or physical cable).
2. **The Fast Check:** The **Kernel Datapath** immediately checks its quick-reference list.
* **If it knows the rule:** It instantly applies the action (like modifying headers or forwarding) and
  shoots the packet out the **Output Port**. *Journey ends here for 99% of normal traffic.*


3. **The Unknown Packet (The Upcall):**
* **If it doesn't know the rule:** The datapath pauses, packages up the packet header, and sends an
  "upcall" message up to the **Userspace Daemon (`ovs-vswitchd`)**.


4. **The Brain Decides:**
* The userspace daemon looks at the packet, runs it through its complex **OpenFlow tables**, and figures
  out the master policy for where this packet should go.


5. **Learning for Next Time:**
* The daemon tells the kernel datapath: *"Send this packet to Port B, and remember this rule for next time
  so you don't have to call me again."*


6. **Departure:** The packet is sent out through the designated **Output Port**.

    | OVS Architecture |
    | :---: |
    | ![OVS Architecture](https://github.com/prk-2023/vork_area/blob/main/2026/Karyalayam/OVS/OVS-arch.jpg?raw=true =480x) |


---

## Core components of Open vSwitch (OVS):


### **1. Ports and Interfaces (The Entry and Exit Points)**

* **What they are:** These are the physical or virtual connection points where packets enter and leave the
  switch.
* **Types:**
* **Physical Ports:** Real network interface cards (NICs) on the host machine (e.g., `eth0`).
* **Virtual Ports (VIFs / TAP devices):** Interfaces connected to virtual machines, containers, or
  namespaces.
* **Tunnel Ports:** Virtual ports used to encapsulate traffic (like VXLAN or GRE) to send packets across
  physical networks to other servers.

---

### **2. `ovsdb-server` (The Configuration Database)**

* **What it is:** The persistent storage system for OVS. It holds all the configuration data—such as what
  bridges exist, which ports belong to which bridge, and what controllers are connected.
* **How it works:** When you run commands like `ovs-vsctl add-br br0`, you are talking directly to
  `ovsdb-server`. The OVS daemon (`ovs-vswitchd`) reads this database to know how the switch is supposed
  to be structured.

---

### **3. `ovs-vswitchd` (The Userspace Daemon / The Brain)**

* **What it is:** The main software daemon that runs in userspace (standard operating system space,
  outside the Linux kernel).
* **How it works:** It acts as the manager and bridge controller. It implements the standard **OpenFlow
  protocol**, talks to external SDN controllers if configured, and computes packet paths when the kernel
  doesn't know what to do with a packet.

---

### **4. OpenFlow Flow Tables (The Master Rulebook)**

* **What they are:** A set of structured, prioritized tables managed inside the `ovs-vswitchd` daemon.
* **How they works:** Unlike simple switches, OpenFlow allows deep, programmable control. A table contains
  rules that say: *"If a packet matches criteria X, perform actions Y (like rewrite headers, send to port
  Z, or pass to table 2)."* This is where complex networking policies live.

---

### **5. The Kernel Datapath (`ovs_kernel` module or Userspace `netdev` / DPDK)**

* **What it is:** The high-performance packet-processing engine. In standard Linux deployments, it runs
  directly inside the **Linux kernel** to process packets as fast as possible without context-switching to
  userspace. (If using DPDK, it runs in userspace but bypasses the OS kernel for extreme speed).
* **How it works:** It acts as the fast-path forwarding engine. It checks incoming packets against active
  rules and forwards them instantly.

---

### **6. The Megaflow Cache (The Fast-Reference List)**

* **What it is:** A temporary, wildcarded cache maintained inside the kernel Datapath.
* **How it works:** Instead of sending every single packet up to the heavy OpenFlow pipeline
  (`ovs-vswitchd`), the datapath checks this cache. If a packet matches an active entry, it is forwarded
  instantly in microseconds.

---

### **The Complete Component Checklist**

#### **1. Ports and Interfaces (The Entry/Exit Gates)**

* **Physical NICs, TAP devices, veth pairs, or VIFs:** Where packets physically or virtually enter and
  leave the switch.

#### **2. Alternative Datapaths (How Packets Are Handled at the Lowest Level)**

* **The Kernel Datapath (`ovs_kernel`):** The default module running inside the Linux kernel, using
  standard kernel packet buffers.
* **DPDK (Data Plane Development Kit):** A userspace datapath framework that bypasses the OS kernel
  entirely, polling NICs directly via PMD (Poll Mode Driver) threads for extreme raw performance.
* **AF_XDP (Address Family eXpress Data Path) — *(The High-Performance Linux Alternative)*:**
* *What it is:* A modern Linux socket-based mechanism built on eBPF (Extended Berkeley Packet Filter).
* *Where it fits:* It acts as a specialized netdev datapath type (`type=afxdp`) that hooks directly into
  an XDP program on the network card driver.
* *Why it’s used:* It provides ultra-fast packet movement between the driver/kernel and userspace with
  zero-copy options, matching much of DPDK's high throughput while still allowing you to use standard
  Linux networking tools (like `ip` commands).

#### **3. The Megaflow Cache (The Fast-Reference List)**

* A wildcarded cache kept right at the datapath layer. If a packet matches an entry here, it is forwarded
  instantly without waking up the main userspace brain.

#### **4. `ovsdb-server` (The Configuration Database)**

* The persistent backend database holding the structural blueprint of your switch (bridges, ports,
  configurations, controller IPs).

#### **5. `ovs-vswitchd` (The Userspace Daemon / The Brain)**

* The core management daemon running in userspace. It processes "flow misses" sent up from the datapath
  and drives the control plane.

#### **6. OpenFlow Flow Tables (The Master Rulebook)**

* Structured, prioritized rule sets housed inside `ovs-vswitchd` that handle complex matching criteria,
  tunneling, and forwarding policies.

---

### **The Full End-to-End Packet Journey**

When you combine every piece into a single timeline, a packet moves through the system like this:

1. **Arrival at the Port:** A packet hits a physical card, a virtual container interface, or an **AF_XDP /
   DPDK** accelerated queue.
2. **The Fast Check:** The low-level datapath checks its active **Megaflow Cache**.
* *If found:* The action executes instantly, and the packet leaves through the output port. (Fast path
  complete).
* *If missing:* A **Flow Miss Upcall** is triggered.


3. **The Upcall to Userspace:** The packet header is sent up to the **`ovs-vswitchd`** daemon.
4. **OpenFlow Pipeline Evaluation:** The daemon evaluates the packet against the master **OpenFlow Flow
Tables** to determine the exact policy.
5. **Caching for the Future:** `ovs-vswitchd` translates that policy into a generalized wildcard rule and
pushes it down into the **Megaflow Cache**.
6. **Departure:** The packet is sent out through the designated **Output Port**.


### Recap:

- `ovs-vsctl`: configures what you want.
- `ovsdb-server`: Stores the configuration.
- `ovs-vswitchd`: Programs the switching behaviour.
- **Kernel Datapath**: Forwards packets ( implemented by the kernel module )

**Inspect Configuration**

- `ovs-vsctl show`
- `ovs-vsctl list-br`
- `ovs-vsctl list-ports br0`
- `ovs-vsctl list-ports br1`

Inspect individual interfaces:

- `ovs-vsctl list interface`

Inspect forwarding database:

- `ovs-appctl fdb/show br0` ( this is  similar to `bridge fdb show` )

Show Interface stats:

- `ovs-ofctl dump-ports br0`

Create bridge, add interface, remove interface , delete bridge , list bridges and ports:

- `ovs-vsctl add-br br0`
- `ovs-vsctl add-port br0 eth0`
- `ovs-vsctl del-port br0 eth0`
- `ovs-vsctl deb-br br0`
- `ovs-vsctl list-br`
- `ovs-vsctl list-ports br0`


#### OVS-ports : access vs trunk

Suppose you have
```text 
      	     br0
       ┌──────────────┐
       │              │
     eth0           tap0
       │              │
       └──────────────┘
```

By default, an OVS port is a trunk port.

That means it can carry traffic from multiple VLANs.

**Access port**

For example, put `tap0` in `VLAN 100`:

`ovs-vsctl add-port br0 tap0 tag=100`

Frames entering `tap0` are associated with `VLAN 100`.

**Trunk port**
Allow VLANs 100, 200 and 300:

`ovs-vsctl set port eth0 trunks=100,200,300`

**Inspect VLAN configuration**

`ovs-vsctl list port`

#### OVS internal interfaces

This is another important concept, especially if you want to assign an IP address to an OVS bridge.

With Linux bridges, you commonly assign an IP to br0.

OVS also supports this:

`ovs-vsctl add-br br0`

This automatically creates an internal interface named br0.

You can configure it:

```bash
ip addr add 192.168.10.1/24 dev br0
ip link set br0 up
```
The distinction:

- Physical port: forwards packets through a physical NIC.

- Internal port: represents the bridge inside the Linux network stack.

This is useful for host management, routing and network namespaces.

#### OVS patch ports

Patch ports are effectively virtual Ethernet cables between two OVS bridges.

For example:

```text
       br0                  br1
   ┌──────────┐         ┌──────────┐
   │          │         │          │
   │ eth0     │         │ eth1     │
   │          │         │          │
   │ patch0 ──┼─────────┼── patch1 │
   │          │         │          │
   └──────────┘         └──────────┘

```
Configuration:

```bash
ovs-vsctl \
  -- add-port br0 patch0 \
  -- set interface patch0 type=patch options:peer=patch1 \
  -- add-port br1 patch1 \
  -- set interface patch1 type=patch options:peer=patch0
```

This is entirely internal to OVS.

#### OpenFlow: where OVS becomes powerful:

The above discussion is OVS as normal switch.

But OVS can also operate using explicit OpenFlow rules.

For example, inspect the current flow table:
`ovs-ofctl dump-flows br0`

A normal standalone bridge generally has a default flow that invokes normal switching behavior.

You can inspect its ports:  
`ovs-ofctl show br0`

OpenFlow allows you to express rules such as:
    - Forward packets from port 1 to port 2.
    - Drop packets from a particular MAC address.
    - Forward packets based on VLAN ID.
    - Redirect traffic to another port.
    - Mirror traffic.
    - Apply packet modifications.

The Linux kernel OVS datapath handles forwarding, while OpenFlow provides a programmable way to control
forwarding decisions

---

Todo: Order of reading

- Bridge and port management (ovs-vsctl).  [x]
- Internal interfaces and IP addressing.   [x] 
- Access ports, trunks and VLANs.          [x]
- Network namespaces and veth integration. [x]
- Patch ports and multiple bridges.        [x]
- OpenFlow rules (ovs-ofctl).          
- Datapath inspection and performance (ovs-appctl, ovs-dpctl).
- DPDK and hardware offloading.

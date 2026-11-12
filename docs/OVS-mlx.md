# OVS Mellanox HW Flag offloading 


When OVS wants to offload a flow, how does the request enter the Mellanox driver, which functions process
it, and how does it eventually become a hardware rule inside the NIC?

The key is to follow the kernel call chain, starting at `ndo_setup_tc()`.

## 1. First, understand what `ndo_setup_tc()` actually does

Linux network drivers register a collection of callbacks through `struct net_device_ops`.

A simplified example:

```c
static const struct net_device_ops mlx5e_netdev_ops = {
    .ndo_open       = mlx5e_open,
    .ndo_stop       = mlx5e_close,
    .ndo_start_xmit = mlx5e_xmit,
    .ndo_setup_tc   = mlx5e_setup_tc,
};
```

The important callback is:

```c
.ndo_setup_tc = mlx5e_setup_tc
```

**This is the entry point through which the Linux networking stack can ask the driver to configure traffic-control functionality**.

However, `ndo_setup_tc()` is not exclusively an OVS callback.

It can receive requests for:

- TC flower classifier offloading.
- Queueing disciplines.
- Traffic-class configuration.
- Other TC-related operations supported by the driver.

For our investigation, we're interested specifically in the TC flower flow-offload path.

One important distinction: OVS doesn't directly call `mlx5e_setup_tc()`. OVS submits a flow configuration through the kernel's TC/Netlink infrastructure, and the kernel eventually invokes the driver's callback.

## 2. The actual mlx5 driver call chain

For your ConnectX-6 Dx, the interesting source files are:

| Source file | Responsibility |
| --- | --- |
| `drivers/net/ethernet/mellanox/mlx5/core/en_main.c` | Registers and implements `ndo_setup_tc` |
| `drivers/net/ethernet/mellanox/mlx5/core/en_tc.c` | Parses TC flower rules and translates them into mlx5 flows |
| `drivers/net/ethernet/mellanox/mlx5/core/eswitch_offloads.c` | eSwitch hardware offload |
| `drivers/net/ethernet/mellanox/mlx5/core/fs_core.c` | Flow steering infrastructure |
| `drivers/net/ethernet/mellanox/mlx5/core/fs_cmd.c` | Flow steering command operations |

These are upstream Linux kernel source locations. Fedora may have additional patches.

Let's follow the important functions.

The call chain

1. `mlx5e_setup_tc()`
   `en_main.c`
   Driver's `ndo_setup_tc` callback.
2. `mlx5e_setup_tc_block_cb()`
   `en_tc.c`
   Registers the driver's callback for a TC flow block.
3. `mlx5e_setup_tc_cls_flower()`
   `en_tc.c`
   Dispatches the flower operation: replace, destroy or stats.
4. `mlx5e_configure_flower()`
   `en_tc.c`
   Receives a new flow installation request.
5. `mlx5e_tc_add_flow()`
   `en_tc.c`
   Selects the NIC or eSwitch flow installation path.
6. `mlx5e_add_nic_flow()` / `mlx5e_add_fdb_flow()`
   `en_tc.c`
   Parses the match and actions and prepares the hardware flow.
7. `mlx5e_add_offloaded_nic_rule()` / eSwitch flow insertion
   Creates the hardware steering rule using mlx5 flow-steering APIs.
8. `mlx5_add_flow_rules()`
   `fs_core` flow-steering infrastructure
   Adds a rule to a hardware flow table.

Function names are from the upstream implementation; some internal details can vary between kernel versions.

[Sources](https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/mellanox/mlx5/core/en_main.c)

## 3. Step 1: `mlx5e_setup_tc()`

Let's start with the actual driver callback.

In `en_main.c`, the driver implements something conceptually equivalent to:

```c
static int mlx5e_setup_tc(
    struct net_device *dev,
    enum tc_setup_type type,
    void *type_data)
{
    struct mlx5e_priv *priv = netdev_priv(dev);

    switch (type) {

    case TC_SETUP_BLOCK:
    {
        struct flow_block_offload *f = type_data;

        f->unlocked_driver_cb = true;

        return flow_block_cb_setup_simple(
            type_data,
            &mlx5e_block_cb_list,
            mlx5e_setup_tc_block_cb,
            priv,
            priv,
            true);
    }

    default:
        return -EOPNOTSUPP;
    }
}
```

This is a simplified illustration of the relevant current upstream implementation.

Let's understand what happens.

A. `dev`

This is the Linux network device receiving the TC configuration request.

For example:

```text
enp1s0f0np0
```

B. `type`

This identifies the kind of TC configuration.

For our purposes:

```c
TC_SETUP_BLOCK
```

The kernel is establishing or configuring a TC flow block.

C. `type_data`

This points to the configuration structure associated with the request.

For `TC_SETUP_BLOCK`, it is a:

```c
struct flow_block_offload
```

D. `flow_block_cb_setup_simple()`

This is particularly interesting.

It registers the driver's callback with the TC flow-block infrastructure.

The callback being registered is:

```c
mlx5e_setup_tc_block_cb
```

This is the bridge between the generic Linux TC subsystem and the Mellanox-specific flower implementation.

Notice something important:

`mlx5e_setup_tc()` does not itself parse the TCP/IP headers or create a NIC flow-table entry.

It establishes the callback mechanism.

## 4. Step 2: `mlx5e_setup_tc_block_cb()`

Now we enter `en_tc.c`.

The upstream implementation contains this logic:

```c
int mlx5e_setup_tc_block_cb(
    enum tc_setup_type type,
    void *type_data,
    void *cb_priv)
{
    unsigned long flags = MLX5_TC_FLAG(INGRESS);
    struct mlx5e_priv *priv = cb_priv;

    if (!priv->netdev ||
        !netif_device_present(priv->netdev))
        return -EOPNOTSUPP;

    if (mlx5e_is_uplink_rep(priv))
        flags |= MLX5_TC_FLAG(ESW_OFFLOAD);
    else
        flags |= MLX5_TC_FLAG(NIC_OFFLOAD);

    switch (type) {
    case TC_SETUP_CLSFLOWER:
        return mlx5e_setup_tc_cls_flower(
            priv, type_data, flags);

    default:
        return -EOPNOTSUPP;
    }
}
```

Source: [mlx5/core/en\_tc.c](<https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux.git/%2B/9b9eaee9828fe98b030cf43ac50065a54a2f5d52/drivers/net/ethernet/mellanox/mlx5/core/en_tc.c>).

There are two interesting things happening.

First: direction

```c
MLX5_TC_FLAG(INGRESS)
```

The driver is identifying this as ingress traffic processing.

Second: which hardware steering domain to use

```c
if (mlx5e_is_uplink_rep(priv))
    flags |= MLX5_TC_FLAG(ESW_OFFLOAD);
else
    flags |= MLX5_TC_FLAG(NIC_OFFLOAD);
```

This distinction is extremely important.

| Flag | Meaning |
| --- | --- |
| `NIC_OFFLOAD` | Offload through the NIC's own packet-processing flow tables |
| `ESW_OFFLOAD` | Offload through the embedded switch's flow tables |

This leads to an important clarification about your current `legacy` mode.

Legacy mode does not categorically prevent TC flower hardware offloading.

The mlx5 driver has a NIC flow-offload path as well. Switchdev is particularly important when we want the eSwitch representor and FDB architecture for hardware switching between ports, VFs and other eSwitch endpoints.

So we can investigate some of the driver flow-offload implementation without immediately changing your NIC to switchdev mode.

## 5. Step 3: `mlx5e_setup_tc_cls_flower()`

This function dispatches the operation requested by TC.

Conceptually:

```c
static int mlx5e_setup_tc_cls_flower(
    struct mlx5e_priv *priv,
    struct flow_cls_offload *cls_flower,
    unsigned long flags)
{
    switch (cls_flower->command) {

    case FLOW_CLS_REPLACE:
        return mlx5e_configure_flower(
            priv->netdev,
            priv,
            cls_flower,
            flags);

    case FLOW_CLS_DESTROY:
        return mlx5e_delete_flower(
            priv->netdev,
            priv,
            cls_flower,
            flags);

    case FLOW_CLS_STATS:
        return mlx5e_stats_flower(
            priv->netdev,
            priv,
            cls_flower,
            flags);

    default:
        return -EOPNOTSUPP;
    }
}
```

There are three operations:

| TC operation | Driver operation |
| --- | --- |
| Replace | Install a new flow |
| Destroy | Remove an existing flow |
| Stats | Retrieve flow counters |

This is important because hardware offloading isn't just about installing rules. The driver must also maintain their lifecycle and report statistics.

## 6. Step 4: `mlx5e_configure_flower()`

Now we reach the actual flow installation process.

The driver receives:

```c
struct flow_cls_offload *f
```

This structure contains information about the requested flow.

Among other things, it contains:

- Match keys.
- Match masks.
- Actions.
- Flow priority.
- Chain information.
- Flow cookie.
- Extended acknowledgment information.

For example, TC might submit a flower rule equivalent to:

```bash
tc filter add dev eth0 ingress \
    protocol ip flower \
    src_ip 192.168.1.10 \
    dst_ip 192.168.2.20 \
    ip_proto tcp \
    dst_port 443 \
    skip_sw \
    action drop
```

The driver doesn't receive this shell command as a string.

It receives structured kernel data representing the classifier and its actions.

The important function is:

```c
mlx5e_configure_flower()
```

Inside this function, the driver:

1. Checks whether the flow already exists.
2. Checks the device and offload state.
3. Calls `mlx5e_tc_add_flow()`.
4. Stores the resulting flow in its internal flow database.

An interesting detail is the flow cookie.

The driver uses a hash table to track installed flows. This allows it to find the corresponding hardware flow when TC later requests deletion or statistics.

Source: [mlx5e\_configure\_flower implementation](<https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux.git/%2B/9b9eaee9828fe98b030cf43ac50065a54a2f5d52/drivers/net/ethernet/mellanox/mlx5/core/en_tc.c>).

## 7. Step 5: Where the actual translation happens

This is probably the most important stage for your learning objective.

The function:

```c
mlx5e_tc_add_flow()
```

decides whether the request belongs to the NIC flow domain or the eSwitch flow domain.

The upstream code contains this logic:

```c
if (esw && esw->mode == MLX5_ESWITCH_OFFLOADS)
    err = mlx5e_add_fdb_flow(
        priv, f, flow_flags, filter_dev, flow);
else
    err = mlx5e_add_nic_flow(
        priv, f, flow_flags, filter_dev, flow);
```

Source: [mlx5e\_tc\_add\_flow implementation](<https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux.git/%2B/9b9eaee9828fe98b030cf43ac50065a54a2f5d52/drivers/net/ethernet/mellanox/mlx5/core/en_tc.c>).

Let's concentrate on the NIC path first because it is relevant to your current legacy configuration.

### `mlx5e_add_nic_flow()`

This function does several important things.

A. Parse match fields

```c
parse_cls_flower(
    flow->priv,
    flow,
    &parse_attr->spec,
    f,
    filter_dev);
```

This translates generic TC flower matching information into an mlx5-specific flow specification.

For example:

```text
TC flower:
    src_ip = 192.168.1.10
    dst_ip = 192.168.2.20
    ip_proto = TCP
    dst_port = 443
```

Becomes a driver-specific structure:

```c
struct mlx5_flow_spec
```

This is a major part of the magic.

The driver converts generic Linux match criteria into the match format understood by the mlx5 flow-steering engine.

B. Parse actions

```c
parse_tc_nic_actions(
    priv,
    &rule->action,
    flow,
    extack);
```

This converts generic TC actions into mlx5-specific actions.

For example:

```text
TC action:
    drop
```

Or:

text

```text
TC action:
    redirect
```

The driver must determine whether the NIC supports the requested action in the relevant flow domain.

C. Install the flow

```c
err = mlx5e_tc_add_nic_flow(
    priv,
    flow,
    extack);
```

At this point, the driver has translated the generic TC request into its internal representation.

Source: [mlx5e\_add\_nic\_flow implementation](<https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux.git/%2B/9b9eaee9828fe98b030cf43ac50065a54a2f5d52/drivers/net/ethernet/mellanox/mlx5/core/en_tc.c>).

## 8. Step 6: The hardware flow-table insertion

Now we reach the function I particularly want you to inspect:

```c
mlx5e_add_offloaded_nic_rule()
```

This function takes:

```c
struct mlx5_flow_spec *spec
struct mlx5_flow_attr *attr
```

These are the driver-specific match and action representations.

It prepares the flow action:

```c
struct mlx5_flow_act flow_act = {
    .action = attr->action,
    .flags = FLOW_ACT_NO_APPEND,
};
```

It also obtains or creates the appropriate flow table.

Then comes the important call:

```c
rule = mlx5_add_flow_rules(
    ft,
    spec,
    &flow_act,
    dest,
    dest_ix);
```

Hardware flow insertion APIThis is where the mlx5 flow-steering infrastructure receives the fully constructed rule.

Source: [mlx5e\_add\_offloaded\_nic\_rule](<https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux.git/%2B/9b9eaee9828fe98b030cf43ac50065a54a2f5d52/drivers/net/ethernet/mellanox/mlx5/core/en_tc.c>) and [mlx5\_add\_flow\_rules call site](<https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux.git/%2B/9b9eaee9828fe98b030cf43ac50065a54a2f5d52/drivers/net/ethernet/mellanox/mlx5/core/en_tc.c>).

### What does `mlx5_add_flow_rules()` do?

It belongs to the mlx5 flow-steering infrastructure.

Conceptually:

```text
mlx5_add_flow_rules()
          |
          v
   Flow steering core
          |
          v
   Create / configure
   flow table entry
          |
          v
   mlx5 hardware command
          |
          v
   NIC firmware / hardware
          |
          v
   Hardware flow entry installed
```

The mlx5 driver uses the device's command interface to configure its flow-steering resources.

It does not simply write an arbitrary C structure into a NIC register.

The lower-level flow-steering code handles the hardware command format, resource management and rule insertion.

The hardware then performs matching and actions without requiring the host CPU to execute the corresponding software forwarding rule for every packet.

## 9. Putting the entire mechanism together

Here is the complete path we have just explored:

+------------------------------+
OVS userspace
`ovs-vswitchd`
Constructs the offload request
+------------------------------+
    v
+------------------------------+
Linux TC / Netlink
TC flower configuration
+------------------------------+
    v
+------------------------------+
`mlx5e_setup_tc()`
`ndo_setup_tc`
+------------------------------+
    v
+------------------------------+

`mlx5e_setup_tc_block_cb()`
+------------------------------+
    v
+------------------------------+

`mlx5e_setup_tc_cls_flower()`
+------------------------------+
    v
+------------------------------+

`mlx5e_configure_flower()`
+------------------------------+
    v
+------------------------------+

`mlx5e_tc_add_flow()`
+------------------------------+
    v
+-----------------------------------------------------------+

NIC mode                |  eSwitch mode
`mlx5e_add_nic_flow()`  | `mlx5e_add_fdb_flow()` 
+-----------------------------------------------------------+
    v
+------------------------------+
mlx5 flow steering
`mlx5e_add_offloaded_nic_rule()`
`mlx5_add_flow_rules()`
+------------------------------+
    v
+------------------------------+
ConnectX-6 Dx hardware
Flow tables → Match → Actions
+------------------------------+

--- 

## 10. How I suggest we study this on your Fedora machine

Rather than reading the entire 100,000+ lines of mlx5 driver code, let's investigate the exact functions in your running kernel.

First, check whether your kernel has the relevant source or debug information available:

```bash
uname -r

rpm -q kernel-core kernel-devel

rpm -qa | grep -E 'kernel-debuginfo|kernel-debugsource'
```

You can also inspect the available driver symbols:

```bash
sudo grep -E \
'mlx5e_setup_tc$|mlx5e_setup_tc_block_cb$|mlx5e_configure_flower$|mlx5e_add_offloaded_nic_rule$|mlx5_add_flow_rules$' \
/proc/kallsyms
```

Some functions may be inlined, unexported or absent from kallsyms, so an empty result doesn't mean the function doesn't exist.

The upstream source files are available here:

- [mlx5/core/en\_main.c](<https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/mellanox/mlx5/core/en_main.c>)
- [mlx5/core/en\_tc.c](<https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/mellanox/mlx5/core/en_tc.c>)
- [mlx5/core/fs\_core.c](<https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/mellanox/mlx5/core/fs_core.c>)
- [mlx5/core/fs\_cmd.c](<https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/mellanox/mlx5/core/fs_cmd.c>)

For accuracy, we should ultimately inspect the source corresponding to your exact Fedora kernel, `6.18.16-200.fc43.x86_64`, rather than assuming upstream master is identical.

## 11. My proposed next experiment: trace the callback live

I think this is the most educational part of the exercise.

We can use ftrace or `trace-cmd` to observe the driver functions being executed when a TC flower rule is installed.

For example, first check available traceable functions:

bash

```bash
sudo grep -E \
'mlx5e_setup_tc|mlx5e_configure_flower|mlx5e_add_nic_flow|mlx5e_add_offloaded_nic_rule|mlx5_add_flow_rules' \
/sys/kernel/tracing/available_filter_functions
```

If the relevant functions are available, we can trace them while installing a simple TC flower rule.

The experiment would be:

1. Install a TC flower rule on your ConnectX-6 Dx interface.
2. Observe entry into `mlx5e_setup_tc()`.
3. Follow the callback into `mlx5e_configure_flower()`.
4. Observe the match/action translation.
5. Follow the call into `mlx5_add_flow_rules()`.
6. Remove the rule and observe the deletion path.

This would let you see the actual driver execution rather than relying only on diagrams.

One important distinction for our next step: Your NIC is currently in legacy mode. We can first study the `NIC_OFFLOAD` path using its normal netdev. Later, we can switch to switchdev and study the `ESW_OFFLOAD` / FDB path, which is arguably even more interesting for OVS because it exposes the embedded switch and representor architecture.

That's the path I would take: understand the actual C implementation first, then watch it execute on your ConnectX-6 Dx.

---


# OVS interacts with driver:


The driver's `ndo_setup_tc()` callback is the entry point through which the Linux kernel asks the network
driver to configure traffic-control functionality.

In our case:

```c
static const struct net_device_ops mlx5e_netdev_ops = {
    .ndo_setup_tc = mlx5e_setup_tc,
};
```

The sequence is:

1. OVS (`ovs-vswitchd`) decides that a flow should be offloaded.
2. OVS submits a TC flower rule through the kernel's TC/Netlink infrastructure.
3. The Linux kernel processes that request.
4. The kernel invokes the network driver's `ndo_setup_tc()` callback.
5. The Mellanox driver (`mlx5e_setup_tc()`) handles the request.

The important nuance: OVS does not directly call `mlx5e_setup_tc()`. It communicates with the kernel, and
the kernel invokes the driver's callback.

Think of it this way:

- OVS speaks to Linux TC.
- Linux TC speaks to the network driver.
- The mlx5 driver translates the request into hardware flow-steering rules.

That's the fundamental architecture to understand.

---

There is one important distinction: we don't just want to understand generic Linux **TC**. We want to
understand how the mlx5 driver connects Linux TC flower to the hardware **eSwitch**.

--- 

## 1. The architecture in switchdev mode

In **switchdev** mode, the ConnectX-6 Dx exposes an embedded switch (**eSwitch**) with representor interfaces.

Conceptually:

```text
                 OVS userspace
                 ovs-vswitchd
                      |
                      v
                OVS datapath
                      |
                      v
                 Linux TC
                TC flower
                      |
                      v
             ndo_setup_tc()
                      |
                      v
              mlx5e_setup_tc()
                      |
                      v
          mlx5e_setup_tc_block_cb()
                      |
                      v
       mlx5e_setup_tc_cls_flower()
                      |
                      v
          mlx5e_configure_flower()
                      |
                      v
             mlx5e_tc_add_flow()
                      |
                      v
             mlx5e_add_fdb_flow()
                      |
                      v
                eSwitch FDB
                      |
                      v
           mlx5 flow steering
                      |
                      v
              NIC hardware
```

The important difference from legacy NIC offload is that we are now interested in the FDB (Forwarding
Database) flow tables rather than the NIC's own ingress flow tables.

## 2. What we need to understand inside mlx5

I'd divide the investigation into five areas.

| Area | What we need to understand | Main source |
| --- | --- | --- |
| Representors | How PF, VF and uplink ports are represented in Linux | `en_rep.c` |
| TC callback | How flower requests enter the driver | `en_tc.c` |
| Match translation | How TC match fields become mlx5 match specifications | `en_tc.c` |
| Action translation | How redirect, drop, VLAN, tunnel and other actions are implemented | `en_tc.c` |
| Hardware programming | How rules are inserted into eSwitch FDB tables | `eswitch_offloads.c`, `fs_core.c`, `fs_cmd.c` |

The most important function to investigate is:

```c
mlx5e_add_fdb_flow()
```

It is the eSwitch counterpart to:

```c
mlx5e_add_nic_flow()
```

The driver parses the flower match, parses the actions using `parse_tc_fdb_actions()`, and eventually
calls `mlx5e_tc_add_fdb_flow()`.

## 3. One particularly important concept: representors

DOCA Switching - NVIDIA Docs

[docs.nvidia.com](https://docs.nvidia.com/doca/archive/3-2-2/doca-switching/index.html)

In switchdev mode, the representors are essential.

Think of them as Linux network interfaces representing physical or virtual ports inside the NIC's
embedded switch.

For example:

```text
             ConnectX-6 Dx
        +----------------------+
        |                      |
        |     Embedded Switch  |
        |                      |
        |   +--------------+   |
        |   |   Uplink     |   |
        |   +--------------+   |
        |          |           |
        |   +--------------+   |
        |   |   VF 0       |   |
        |   +--------------+   |
        |          |           |
        |   +--------------+   |
        |   |   VF 1       |   |
        |   +--------------+   |
        |                      |
        +----------------------+
              |    |    |
              v    v    v
             Linux representors
```

OVS can attach these representors to its bridge and use TC flower rules to program forwarding between them.

The Linux kernel documentation describes this switchdev architecture and the mlx5 bridge-offload support.

The Linux Kernel documentation

## 4. My recommended learning sequence

I'd study it in this order:

1. Switchdev architecture: Understand the eSwitch, vports, uplink and representors.
2. TC flower integration: Understand how `ndo_setup_tc()` and the representor callbacks work.
3. FDB flow creation: Follow `mlx5e_add_fdb_flow()`.
4. Match parsing: Follow `parse_cls_flower()`.
5. Action parsing: Follow `parse_tc_fdb_actions()`.
6. Hardware insertion: Follow `mlx5e_tc_add_fdb_flow()` down into the flow-steering infrastructure.

## 5. The question I would investigate first

Before diving into the implementation, I want to establish one important concept:

When OVS installs a TC flower rule on a representor, how does the mlx5 driver know which eSwitch port is the source of the packet and which eSwitch port should receive it?

This is fundamental to understanding hardware forwarding.

It will lead us naturally to:

- `struct mlx5_eswitch_rep`
- `struct mlx5_esw_flow_attr`
- `in_rep`
- `out_rep`
- `mlx5e_add_fdb_flow()`


--- 

However, understanding some of its concepts will help considerably.

I'd approach it in layers.

## 1. What you need to understand first

Focus on these concepts:

1. eSwitch: The embedded switch inside the ConnectX-6 Dx.
2. Representors: Linux interfaces representing eSwitch ports (PF, VF, uplink).
3. Vports: The hardware switch ports associated with those interfaces.
4. FDB (Forwarding Database): The hardware flow tables responsible for eSwitch forwarding.
5. TC flower: How Linux represents match/action rules.

## 2. My proposed investigation order

I'd suggest this sequence:

1. eSwitch architecture
   Understand PF, VF, uplink, vports and representors.
2. Switchdev implementation in mlx5
   Study how the driver enables switchdev mode and creates representors.
   Main file: `eswitch.c`, `en_rep.c`.
3. TC flower implementation
   Study `ndo_setup_tc()` and the callback registration mechanism.
   Main file: `en_main.c`, `en_tc.c`.
4. FDB flow creation
   Follow `mlx5e_add_fdb_flow()` and the match/action parsing.
5. Hardware flow steering
   Follow `mlx5_add_flow_rules()` into `fs_core.c` and the lower-level command implementation.

My recommendation: Start with the eSwitch and representor architecture, not ASAP².

## 3. What you can postpone

You don't need to understand these in detail yet:

- ASAP² architecture internals.
- Hardware pipeline implementation.
- Firmware command encoding.
- Detailed hardware steering optimizations.
- Connection tracking and advanced flow acceleration.


---

# MLX ewitch:


To understand Mellanox's TC implementation in `switchdev` mode, we first need to understand two
fundamental concepts:

1. `eSwitch (Embedded Switch)`: The hardware switch inside the CX-6 Dx that forwards packets between its ports.
2. `Representors`: Linux network interfaces that represent those hardware switch ports and allow software
   such as OVS to control them.

*The relationship is simple*:

The eSwitch is the hardware being controlled. 

**Representors** are the software interfaces used to control it.

Let's build the picture from the hardware upward.

## 1. What is the eSwitch?

ConnectX-6 Dx is more than a network interface card. It also contains switching functionality.

For example, imagine that your NIC has:

- One physical Ethernet connection to the external network.
- One PF (Physical Function).
- Two VFs (Virtual Functions).

The NIC can internally forward packets between these entities without sending every packet through the host CPU.

Conceptually:

DOCA Switching - NVIDIA Docs

[DOCA Switching Docs ](https://docs.nvidia.com/doca/archive/3-2-2/doca-switching/index.html)

Think of the eSwitch as an Ethernet switch implemented inside the NIC.

It has several logical ports:

| Port | Purpose |
| --- | --- |
| Uplink | Connection to the external Ethernet network |
| PF | Physical Function |
| VF0 | Virtual Function 0 |
| VF1 | Virtual Function 1 |

The eSwitch can forward traffic between these ports.

For example:

```text
       External Network
              |
              |
         Physical Port
              |
              v
       +--------------+
       |              |
       |   eSwitch    |
       |              |
       +--------------+
          |        |
          |        |
         VF0      VF1
```

Suppose VF0 sends a packet destined for VF1.

The eSwitch can forward that packet directly to VF1.

The packet doesn't need to travel through the host's Linux networking stack.

This is the foundation of hardware switching and offloading.

The mlx5 documentation describes this architecture and its **switchdev** implementation.


## 2. What is a representor?

Now comes the interesting part.

How can Linux, OVS, or TC control those hardware ports?

Linux needs a way to represent each hardware port as a network interface.

That's exactly what a **representor** does.

A **representor** is a Linux `net_device` representing a port inside the eSwitch.

For example:

Interface - NVIDIA Docs

[docs.nvidia.com](https://docs.nvidia.com/networking/display/mlnxofedv461000/interface)

Conceptually, Linux might expose interfaces such as:

text

```text
ens1f0np0       Physical uplink netdev
pf0vf0          VF0 representor
pf0vf1          VF1 representor
```

The exact names depend on the driver and system configuration.

The important thing is that these interfaces are not necessarily independent physical network devices.

They are software representations of ports inside the NIC's hardware switch.

The Linux kernel documentation describes three primary purposes for representors:

- Configure the represented port.
- Provide a software forwarding path for packets that aren't handled by hardware offload.
- Provide a handle through which TC and other switching rules can reference the represented port.
  The Linux Kernel documentation
  +1

## 3. How does a representor actually work?

This is the most important concept for understanding OVS.

A representor has two roles: a control-plane interface and a data-plane interface.

### A. Control-plane role

Because a representor is a normal Linux network interface, you can configure it using familiar tools:

bash

```bash
ip link show
ip link set pf0vf0 up

tc qdisc add dev pf0vf0 clsact

tc filter add dev pf0vf0 ingress \
    protocol ip flower \
    ip_proto tcp \
    action drop
```

You can also attach it to an OVS bridge:

bash

```bash
ovs-vsctl add-port br0 pf0vf0
```

This is how OVS gets access to the virtual ports inside the NIC.

### B. Data-plane role

This is even more interesting.

Suppose VF0 sends a packet.

If the packet isn't handled by a hardware forwarding rule, it can be delivered to the host through VF0's representor.

Similarly, if the host transmits a packet through VF0's representor, the driver can deliver it to VF0.

Conceptually, the representor behaves like a virtual connection to the represented port.

BF2 swithdev representor 方案介绍\_vf represtor-CSDN博客

[blog.csdn.net](https://blog.csdn.net/leoufung/article/details/121046338)

This means that software switching and hardware switching can provide equivalent forwarding behavior.

The difference is where the forwarding decision is executed:

- Software path: Linux networking stack and OVS.
- Hardware path: eSwitch flow tables inside the NIC.

This equivalence is an important design principle of representors.


## 4. How does OVS use representors?

Now let's connect everything to our original investigation.

Imagine you have:

- VF0 connected to VM0.
- VF1 connected to VM1.
- An uplink connected to the external network.
- An OVS bridge called `br0`.

The topology looks like this:

ovs offload - tycoon3 - 博客园

![ovs offload](https://i-blog.csdnimg.cn/blog_migrate/33f0761b7f0114fe2366182800404f64.png)

OVS sees the representors as bridge ports:

```text
                 OVS bridge br0
              +-------------------+
              |                   |
              |  pf0vf0           |
              |  pf0vf1           |
              |  uplink           |
              |                   |
              +-------------------+
                       |
                       v
                Linux TC flower
                       |
                       v
                mlx5 driver
                       |
                       v
                  NIC eSwitch
```

Suppose OVS wants to forward packets from VF0 to VF1.

It can request a TC flower hardware rule equivalent to:

```text
Match:
    Source port = VF0
    Destination MAC = MAC of VM1

Action:
    Forward to VF1
```

The mlx5 driver translates this into an eSwitch FDB rule.

The hardware can then forward packets directly:

```text
       VM0
        |
        v
       VF0
        |
        v
   +-----------+
   |  eSwitch  |
   |           |
   |  FDB rule |
   +-----------+
        |
        v
       VF1
        |
        v
       VM1
```

No OVS userspace processing is needed for each packet that matches the offloaded rule.

This is the important connection: representors give OVS a software interface to the hardware switch ports, while TC flower gives OVS a mechanism to program forwarding rules into that switch.

## 5. How does this relate to the mlx5 driver implementation?

Now we can understand why the driver has separate code for representors and regular NIC interfaces.

When operating in switchdev mode, the mlx5 driver creates representor netdevices for the eSwitch ports.

The relevant source files include:

| Source file | Responsibility |
| --- | --- |
| `eswitch.c` | eSwitch management and configuration |
| `en_rep.c` | Representor netdevice implementation |
| `en_rep.h` | Representor structures and definitions |
| `en_tc.c` | TC flower parsing and flow installation |
| `eswitch_offloads.c` | eSwitch offload infrastructure |

One particularly interesting structure to investigate is:

```c
struct mlx5_eswitch_rep;
```

It represents the driver's internal representation of an eSwitch port.

Another important structure is:

```c
struct mlx5_esw_flow_attr;
```

It carries eSwitch-specific flow information, including information about the ingress and egress representors.

These structures will become important when we investigate how the driver translates a TC flower rule into an FDB rule.

## 6. Legacy mode versus switchdev mode

Let's make sure we understand the difference.

| Feature | Legacy mode | Switchdev mode |
| --- | --- | --- |
| eSwitch | Present | Present |
| Hardware switching | Basic NIC-managed switching | Programmable offload architecture |
| VF representors | Not exposed in the same way | Exposed |
| TC flower offload | NIC flow domain supported | eSwitch FDB offload supported |
| OVS hardware switching between VFs | Limited architecture | Supported through representors and FDB offload |

Switchdev is what exposes the eSwitch ports through the representor architecture, allowing OVS to manage hardware switching much more directly.

## 7. What I want you to remember

Three concepts to keep separate

HardwareeSwitch

The actual switching engine inside the ConnectX-6 Dx.

Linux interfaceRepresentor

A Linux network device representing an eSwitch port.

Flow managementTC flower

The mechanism used to describe match/action rules that the driver can translate into hardware rules.

## 8. Our next step

I suggest we now inspect the actual mlx5 source code, starting with:

```text
drivers/net/ethernet/mellanox/mlx5/core/
    eswitch.c
    en_rep.c
    en_rep.h
```

I particularly want to understand:

1. Who creates the representor netdevices?
2. How does the driver associate a representor with a specific eSwitch vport?
3. How does `ndo_setup_tc()` on a representor reach the TC flower implementation?
4. How does the driver know which hardware port is the ingress port when installing an FDB rule?

Question 4 is especially important: it explains how a Linux TC rule attached to a representor becomes a hardware rule associated with the correct eSwitch port.

That's where we'll start connecting the architecture to the actual C implementation.

---


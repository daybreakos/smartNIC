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

This is the entry point through which the Linux networking stack can ask the driver to configure traffic-control functionality.

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

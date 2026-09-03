
Jumbo Frame Investigation Report — mlx5 vDPA / virtio-net

1. Objective

Investigate why jumbo-frame traffic between two VMs using NVIDIA mlx5 vDPA devices does not work above 
approximately 1504 bytes, even though:

The physical ConnectX-7 interfaces support jumbo frames.
The host PF MTU is configured to 9014.
The vDPA devices are configured with MTU 9000.
The VM virtio-net interfaces are configured with MTU 9000.
Direct physical DAC testing between hosts successfully supports 9000-byte packets.

The current investigation focuses on the datapath:

```
    VM1
      |
      | virtio-net
      |
    vhost-vdpa
      |
    vdpa0
      |
    mlx5_core / ConnectX-7
      |
    hardware / representor / switch datapath
      |
    vdpa1
      |
    vhost-vdpa
      |
    virtio-net
      |
    VM2
```

2. Environment
Host physical NICs

The ConnectX-7 PFs report jumbo-frame capability.

Example:

```
$ sudo ip -d link show enp1s0f0np0

$ sudo mtu 9014
$ sudo minmtu 68
$ sudo maxmtu 9978
$ sudo gso_max_size 65536
$ sudo gso_max_segs 65535
$ sudo tso_max_size 524280
$ sudo tso_max_segs 65535
```

The second physical port is similarly configured with MTU 9014.

The physical NICs are NVIDIA/Mellanox ConnectX-7:
```
0000:01:00.0 Ethernet controller:
Mellanox Technologies MT2910 Family [ConnectX-7]

0000:01:00.1 Ethernet controller:
Mellanox Technologies MT2910 Family [ConnectX-7]
```

3. vDPA configuration

The vDPA devices were originally created with the default MTU of 1500.

The following change was made to t2_host_setup.sh:

sudo vdpa dev add \
    name "vdpa${DEV_IDX}" \
    mgmtdev "pci/${VF_BDF}" \
    mac "${MAC}" \
    mtu "${MTU}"


with:

MTU=9000


After recreating the devices:

vdpa0: mac 52:54:00:9a:00:01 link up ... mtu 9000
vdpa1: mac 52:54:00:9a:00:02 link up ... mtu 9000


Detailed configuration:

vdpa0:
  mtu 9000
  negotiated_features:
    CSUM
    GUEST_CSUM
    HOST_TSO4
    HOST_TSO6
    STATUS
    CTRL_VQ
    CTRL_VLAN
    MQ
    CTRL_MAC_ADDR
    VERSION_1
    ACCESS_PLATFORM

vdpa1:
  mtu 9000
  negotiated_features:
    CSUM
    GUEST_CSUM
    HOST_TSO4
    HOST_TSO6
    STATUS
    CTRL_VQ
    CTRL_VLAN
    MQ
    CTRL_MAC_ADDR
    VERSION_1
    ACCESS_PLATFORM


Therefore, the vDPA device configuration itself reports MTU 9000.

4. Guest VM interface configuration

Inside VM1:

ip -d link show ens-test


reports:

ens-test:
    mtu 9000
    state UP
    parentbus virtio


The VM2 interface was also configured to MTU 9000.

The vDPA-backed interface is therefore configured consistently:

Physical PF       : 9014
vDPA               : 9000
VM virtio-net      : 9000

5. Ping testing
5.1 Initial test with vDPA MTU 1500

Before changing the vDPA MTU, the VM interface itself could be configured to 9000, but jumbo ping failed.

The following test was performed:

for size in 1400 1450 1460 1470 1480 1490 1500 1510; do
    echo "===== $size ====="
    ping -M do -s "$size" -c 2 192.168.100.12
done


Result:

1400  -> PASS
1450  -> PASS
1460  -> PASS
1470  -> PASS
1480  -> FAIL
1490  -> FAIL
1500  -> FAIL
1510  -> FAIL


The transition occurred between:

ping payload 1470 -> IP packet 1498 -> PASS
ping payload 1480 -> IP packet 1508 -> FAIL


This suggested a roughly 1500-byte datapath restriction.

6. vDPA MTU changed to 9000

The vDPA creation script was changed to explicitly configure:

mtu "${MTU}"


After recreating the vDPA devices:

vdpa0 mtu 9000
vdpa1 mtu 9000


Both VMs were then launched with their interfaces at MTU 9000.

However, the jumbo ping still failed.

7. Precise MTU boundary test

A more precise test was performed:

for size in 1472 1473 1474 1475 1476 1477 1478; do
    echo "===== $size ====="
    ping -M do -s "$size" -c 3 192.168.100.12
done


Results:

1472 -> PASS
1473 -> PASS
1474 -> PASS
1475 -> PASS
1476 -> PASS
1477 -> FAIL
1478 -> FAIL


The packet sizes reported by ping were:

1472 payload -> 1500-byte IP packet -> PASS
1473 payload -> 1501-byte IP packet -> PASS
1474 payload -> 1502-byte IP packet -> PASS
1475 payload -> 1503-byte IP packet -> PASS
1476 payload -> 1504-byte IP packet -> PASS

1477 payload -> 1505-byte IP packet -> FAIL
1478 payload -> 1506-byte IP packet -> FAIL


Therefore the experimentally observed boundary is:

1504-byte IP packet : PASS
1505-byte IP packet : FAIL


This is the most important finding so far.

It demonstrates that the effective packet-size limit in the VM-to-VM vDPA datapath is approximately 1504 bytes, despite all relevant Linux interfaces reporting MTU 9000.

8. Large jumbo-frame tests

The following tests were also performed:

ping -M do -s 8972 -c 5 192.168.100.12


The expected packet size is:

8972 ICMP payload
+ 8 ICMP header
+ 20 IPv4 header
= 9000 bytes


Result:

5 packets transmitted
0 received
100% packet loss


The following range was also tested:

for size in 1470 1472 1480 1500 2000 4000 8000 8972; do
    echo "===== $size ====="
    ping -M do -s "$size" -c 2 192.168.100.12
done


Result:

1470 -> PASS
1472 -> PASS
1480 -> FAIL
1500 -> FAIL
2000 -> FAIL
4000 -> FAIL
8000 -> FAIL
8972 -> FAIL

9. PMTU / DF testing

The tests were performed using:

ping -M do


-M do requests IPv4 DF behavior and prevents fragmentation.

A successful 9000-byte path should therefore allow:

ping -M do -s 8972 <destination>


when the interface/path MTU is 9000.

Instead, packets above approximately 1504 bytes disappear without a returned ICMP response.

10. ping -M want test

The following was also tested:

ping -M want -s 8972 -c 5 10.20.0.2


on a host-to-host test interface configured for MTU 9000.

The relevant distinction was that the direct physical DAC path successfully supported large packets, whereas the vDPA VM path did not.

11. Direct physical DAC control test

A very important control experiment was performed without vDPA.

Host A — NVIDIA GB10 / ConnectX-7
sudo ip addr add 10.20.0.1/24 dev enp1s0f0np0
sudo ip link set enp1s0f0np0 mtu 9000

Host B — ConnectX-6
sudo ip addr add 10.20.0.2/24 dev enp1s0f0np0
sudo ip link set enp1s0f0np0 mtu 9000


The hosts were connected directly using DAC.

Normal ping worked:

ping 10.20.0.2 -c 5


and, critically:

ping -s 8972 -c 5 10.20.0.2


succeeded:

8980 bytes from 10.20.0.2
...
5 packets transmitted, 5 received
0% packet loss


The same worked with:

ping -M want -s 8972 -c 5 10.20.0.2


This proves that the physical ConnectX/DAC path is capable of carrying the required jumbo frame.

Therefore, the ConnectX hardware and DAC cannot currently be considered the primary cause.

12. Host-side local interface test

A separate host test was attempted between:

enp1s0f0r0
enP2p1s0f1r0


Both interfaces were configured:

sudo ip addr add 10.20.0.1/24 dev enp1s0f0r0
sudo ip addr add 10.20.0.2/24 dev enP2p1s0f1r0

sudo ip link set enp1s0f0r0 mtu 9000
sudo ip link set enP2p1s0f1r0 mtu 9000


However:

ping -M do -s 8972 -c 5 10.20.0.2


returned:

ping: local error: message too long, mtu=1500


This was an important observation because it showed that at least one path/routing context still had an effective MTU of 1500.

The routing table at the time showed:

default via 10.10.10.18 dev enP7s7
10.10.10.0/24 dev enP7s7 src 10.10.10.27


and:

ip route get 10.20.0.2


returned:

10.20.0.2 via 10.10.10.18 dev enP7s7 src 10.10.10.27


Thus this particular test did not actually use the intended 10.20.0.x interface path. It was a routing issue and is not evidence that the physical ConnectX interfaces cannot handle jumbo frames.

The direct DAC test later confirmed that jumbo frames work on the physical path.

13. Offload testing

Inside the VM, the following was tested:

sudo ethtool -K ens-test tso off gso off gro off


The jumbo-frame failure remained unchanged.

Therefore:

TSO/GSO/GRO


does not appear to be the primary cause.

The VM interface currently reports, among other features:

tcp-segmentation-offload: on
generic-segmentation-offload: on
generic-receive-offload: on


but disabling these did not change the packet-size boundary.

14. Guest driver information

VM vDPA-backed interfaces use:

driver: mlx5_core
version: 6.11.0-1014-nvidia
firmware-version: 28.45.4028


For VM1:

bus-info: 0000:01:00.2


For VM2:

bus-info: 0002:01:01.2


Both are NVIDIA mlx5 devices.

15. vDPA PCI topology

VM1:

0000:01:00.2


is an NVIDIA mlx5 virtual function.

It has:

vdpa0
mlx5_core.eth.4
mlx5_core.vnet.4
enp1s0f0v0


The device is driven by:

/sys/bus/pci/drivers/mlx5_core


VM2 similarly uses:

0002:01:01.2


with:

enP2p1s0f1v0
vdpa1

16. Representor / devlink information

The host reports:

pci/0000:01:00.0/1:
    type eth
    netdev enp1s0f0r0
    flavour pcivf
    controller 0
    pfnum 0
    vfnum 0


and:

auxiliary/mlx5_core.eth.4/393216:
    type eth
    netdev enp1s0f0v0
    flavour virtual


The second physical path has equivalent mlx5 virtual/representor interfaces.

The command:

sudo devlink port function show pci/0000:01:00.0/1


was attempted but this kernel/devlink version reports:

Command "show" not found


The command:

sudo devlink port show pci/0000:01:00.0/1


works, but does not expose additional function configuration relevant to MTU.

17. QEMU configuration

The VM is launched with:

-netdev type=vhost-vdpa,id=vdpanet0,vhostdev=/dev/vhost-vdpa-0


and:

-device virtio-net-pci,
    netdev=vdpanet0,
    mac=52:54:00:9a:00:01,
    mrg_rxbuf=on,
    mq=on,
    vectors=10


VM2 uses:

-netdev type=vhost-vdpa,id=vdpanet0,vhostdev=/dev/vhost-vdpa-1


and the equivalent virtio-net device.

An important item for further investigation is that the QEMU command line did not explicitly contain:

host_mtu=9000


NVIDIA documentation for jumbo-frame configurations shows host_mtu being explicitly configured on the virtio-net device, together with the host MTU and guest MTU. 
N
NVIDIA Docs

This therefore remains a high-priority item to test.

18. iperf / TCP MSS testing

TCP testing should complement the ICMP/PMTU tests.

iperf3 supports:

-M, --set-mss n


which sets the TCP/SCTP maximum segment size. The documented relationship for IPv4 Ethernet is approximately:

MSS = MTU - 40


for the normal 20-byte IPv4 + 20-byte TCP headers. 
E
ESnet Software
+1

Start server on VM2
iperf3 -s

Test from VM1 using the expected 9000-byte MTU

For IPv4:

iperf3 -c 192.168.100.12 -M 8960 -t 10


because:

9000 - 40 = 8960 MSS


Also test the observed working boundary:

iperf3 -c 192.168.100.12 -M 1464 -t 10


because:

1504 - 40 = 1464 MSS


and the failing boundary:

iperf3 -c 192.168.100.12 -M 1465 -t 10


corresponding to approximately:

1505-byte IP packet


These tests can establish whether the same ~1504-byte ceiling is visible at TCP level.

19. Recommended TCP MSS sweep

Run on VM1:

for mss in 1400 1440 1460 1464 1465 1470 1500 2000 4000 8960; do
    echo "===== MSS $mss ====="
    iperf3 -c 192.168.100.12 -M "$mss" -t 5
done


The important comparison is:

MSS 1464 -> expected to correspond to 1504-byte IP packet
MSS 1465 -> expected to correspond to 1505-byte IP packet


If TCP throughput works at MSS 1464 but fails at MSS 1465, that would independently reproduce the ICMP boundary.

iperf3 -M explicitly controls TCP/SCTP MSS. 
E
ESnet Software

20. iperf TCP test without manually forcing MSS

Also run:

iperf3 -c 192.168.100.12 -t 10


and:

iperf3 -c 192.168.100.12 -R -t 10


to test both directions.

Use:

iperf3 -c 192.168.100.12 -t 10 -P 4


and:

iperf3 -c 192.168.100.12 -R -t 10 -P 4


for multiple TCP streams.

The purpose is to distinguish:

packet-size limitation


from:

general vDPA throughput/performance problem

21. Recommended iperf MSS verification with packet capture

Run on the host or guest:

sudo tcpdump -ni ens-test -s 0 -vvv tcp


while running:

iperf3 -c 192.168.100.12 -M 1464 -t 5


and:

iperf3 -c 192.168.100.12 -M 1465 -t 5


The TCP SYN packets can be inspected for the negotiated MSS.

This is useful because it tells us whether the guest is actually advertising/using the MSS that was requested.

22. Current findings

The investigation has established the following:

Confirmed
The physical ConnectX-7 interfaces support jumbo frames.
The physical PF MTU is configured to 9014.
The PF maximum MTU is reported as 9978.
The vDPA devices can be created with MTU 9000.
Both vDPA devices report MTU 9000.
The guest virtio-net interfaces report MTU 9000.
Disabling TSO/GSO/GRO does not fix the problem.
Direct DAC connectivity between physical hosts successfully carries 9000-byte IP packets.
VM-to-VM traffic through the mlx5 vDPA datapath does not carry 9000-byte packets.
The VM-to-VM vDPA path has a very repeatable packet-size boundary.
1504-byte IP packet succeeds.
1505-byte IP packet fails.
Observed boundary
Maximum currently observed working IP packet:
    1504 bytes

Minimum currently observed failing IP packet:
    1505 bytes


For normal IPv4/TCP:

1504 IP MTU
- 20 IPv4 header
- 20 TCP header
----------------
1464 TCP MSS


For a 9000-byte MTU:

9000 IP MTU
- 20 IPv4
- 20 TCP
-----------
8960 MSS

23. Current suspected root cause

The evidence strongly suggests that the problem is not the physical ConnectX hardware or DAC, and is unlikely to be TSO/GSO/GRO.

The most likely problem area is the mlx5 vDPA / virtio-net datapath configuration or implementation of jumbo-frame capability.

The key inconsistency is:

Configured:

PF                  MTU 9014
vDPA                 MTU 9000
Guest virtio-net     MTU 9000

Actual datapath:

1504-byte packet     PASS
1505-byte packet     FAIL


Therefore:

Linux interface MTU
        !=
actual vDPA datapath packet-size capability


at least in the current configuration.

A particularly important item for NVIDIA documentation investigation is host_mtu.

NVIDIA's MLNX-EN documentation explicitly describes jumbo-frame configuration involving:

host physical interface MTU
host_mtu in the virtio configuration
guest MTU


and gives an example using host_mtu=9216. 
N
NVIDIA Docs

Our current QEMU command line does not explicitly specify:

host_mtu=9000


Therefore this should be the next configuration item to verify against the NVIDIA vDPA documentation.

24. Recommended next investigation

When continuing the investigation, test the following in order.

A. QEMU host_mtu

Add:

host_mtu=9000


to both:

-device virtio-net-pci


instances.

Then restart both VMs and verify:

ip link show ens-test


followed by:

ping -M do -s 1476 -c 3 192.168.100.12
ping -M do -s 1477 -c 3 192.168.100.12
ping -M do -s 8972 -c 3 192.168.100.12

B. TCP MSS test

On VM2:

iperf3 -s


On VM1:

iperf3 -c 192.168.100.12 -M 1464 -t 10
iperf3 -c 192.168.100.12 -M 1465 -t 10
iperf3 -c 192.168.100.12 -M 8960 -t 10

C. Packet capture

Capture simultaneously on the VM and host:

sudo tcpdump -ni ens-test -s 0 -vvv icmp


and on the host:

sudo tcpdump -ni enp1s0f0v0 -s 0 -vvv icmp
sudo tcpdump -ni enp1s0f0r0 -s 0 -vvv icmp


The objective is to determine exactly where the 1505-byte packet disappears.

D. Hardware/software counters

Collect before and after the failing test:

ethtool -S ens-test
ethtool -S enp1s0f0v0
ethtool -S enp1s0f0r0


Then:

ping -M do -s 1477 -c 10 192.168.100.12


and collect the counters again.

25. Conclusion

The jumbo-frame investigation has successfully isolated the problem to the VM/vDPA datapath rather than the physical ConnectX/DAC path.

The strongest evidence is:

Direct physical DAC:
    9000-byte IP packet -> PASS

VM through mlx5 vDPA:
    1504-byte IP packet -> PASS
    1505-byte IP packet -> FAIL
    9000-byte IP packet -> FAIL


The host PF, vDPA devices, and guest interfaces all report jumbo MTUs, so the remaining issue is likely in the vDPA/virtio configuration, MTU negotiation, representor/hardware datapath, or mlx5 vDPA implementation.

The next high-value item to investigate in NVIDIA documentation is the required handling of:

host_mtu


and the complete jumbo-frame configuration for the mlx5 vDPA path.

The iperf3 MSS tests should be used as a complementary TCP-level validation. iperf3 documents -M/--set-mss specifically for controlling the TCP maximum segment size. 
E
ESnet Software

At this stage, the 1504/1505-byte transition is the key reproducible signature that should be provided to NVIDIA when requesting clarification or support.

This should give you a clean baseline for the NVIDIA documentation investigation: the most useful fact to carry forward is “MTU configured as 9000 everywhere, but vDPA VM-to-VM datapath fails at 1505-byte IP packet while direct ConnectX DAC passes 9000-byte packets.”


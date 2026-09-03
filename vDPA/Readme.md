# vDPA & TC Hardware Acceleration Benchmark Suite



sudo ./t2_perf_apply.sh
sudo ./t2_host_setup.sh
./t2_build <1|2>
./t2_launch_vm.sh <1|2> 
./t2_run_benchmark.sh
sudo ./t2_host_resetup.sh

An automated end-to-end benchmarking and profiling framework for evaluating network performance (throughput, latency, CPU utilization) across Linux kernel TC Flower offload and vDPA/vhost-user hardware acceleration datapaths.

---

## Technical Architecture & Data Flow

The benchmark suite tests communication between two QEMU Virtual Machines (**VM1** and **VM2**) bridged at the host layer via VF representors using either Linux **TC Flower Redirection** or an **In-Process DPDK vDPA Bridge**.

### Data Flow Diagram


```

+------------------------------------------------------------------------------------------------+
|                                           HOST SYSTEM                                          |
|                                                                                                |
|   +---------------------------------+                        +-----------------------------+   |
|   |             VM1                 |                        |             VM2             |   |
|   |  +---------------------------+  |                        |  +-----------------------+  |   |
|   |  |   ens-test (virtio_net)   |  |                        |  | ens-test (virtio_net)   |  |   |
|   |  |   IP: 192.168.10.1/24     |  |                        |  | IP: 192.168.10.2/24     |  |   |
|   |  +-------------+-------------+  |                        |  +-----------+-----------+  |   |
|   +----------------|----------------+                        +--------------|--------------+   |
|                    | [VirtIO Ring Buffer]                                   | [VirtIO Ring Buffer]
|                    v                                                        v                  |
|   +----------------+----------------+                        +--------------+--------------+   |
|   |   VF Representor 1 (VM1)        |                        |   VF Representor 2 (VM2)    |   |
|   |   Interface: enp1s0f0r0         |                        |   Interface: enP2p1s0f1r0   |   |
|   +----------------+----------------+                        +--------------+--------------+   |
|                    |                                                        ^                  |
|                    |     +--------------------------------------------+     |                  |
|                    |     |            DATAPATH SWITCHING              |     |                  |
|                    +---->|                                            +-----+                  |
|                          | Mode 1: Linux TC Flower Hardware Redirect  |                        |
|                          | Mode 2: DPDK / vDPA vhost-user Bridge      |                        |
|                          +--------------------------------------------+                        |
|                                                                                                |
+------------------------------------------------------------------------------------------------+

```

### Protocol & Packet Encapsulation Stack


```

[ Application Layer ]    iperf3 / qperf / ping
|
[ Transport Layer ]      TCP / UDP headers
|
[ Network Layer ]        IPv4 (MTU 1500 B / 9000 B Jumbo Frames)
|
[ Data Link Layer ]      VirtIO Ethernet Frame (ens-test)
|
[ Host Offload Path ]    VF Representor Ingress -> TC Flower Redirect -> VF Representor Egress

```

---

## Directory Structure

```text
.
├── t2_config.sh          # Centralized configuration variables (IPs, Ports, MTU, SSH keys)
├── t2_host_setup.sh      # Host system configuration (Switchdev mode, TC rules, MTU setup)
├── t2_perf_apply.sh      # Host kernel tuning & CPU performance governor scripts
├── t2_run_benchmarks.sh  # Main test runner (Executes Ping, qperf, iperf3 & generates report)
└── README.md             # Project documentation

```

---

## Prerequisites & System Requirements

### Host Environment

* **OS:** Ubuntu 22.04 LTS / 24.04 LTS or RHEL 9+ (Kernel $\ge 6.1$)
* **NIC Hardware:** NVIDIA ConnectX / BlueField or supported vDPA SmartNIC
* **Packages:** `openvswitch-switch`, `ethtool`, `sysstat` (`mpstat`), `python3`, `ssh`

### Guest Virtual Machines

* Two running QEMU/KVM Virtual Machines (**VM1** and **VM2**)
* SSH access configured on localhost forwarded ports (e.g., `2221` for VM1, `2222` for VM2)
* Installed tools on both guests: `iperf3`, `qperf`, `ethtool`, `iputils-ping`

---

## Setup & Execution Guide

### Step 1: Configuration (`t2_config.sh`)

Review and adjust system parameters in `t2_config.sh`:

```bash
# Network Settings
MTU=9000
VM1_TEST_IP="192.168.10.1"
VM2_TEST_IP="192.168.10.2"

# Guest SSH Management Settings
GUEST_USER="user"
SSH_DNAT_PORT_VM1=2221
SSH_DNAT_PORT_VM2=2222

# Host Representor Interfaces
VM1_REP_DEV="enp1s0f0r0"
VM2_REP_DEV="enP2p1s0f1r0"

```

---

### Step 2: Host Networking & Offload Setup (`t2_host_setup.sh`)

Configure the NIC to `switchdev` mode, adjust MTU settings across physical and representor ports, and install TC Flower rules:

```bash
# 1. Apply system performance profile
sudo ./t2_perf_apply.sh

# 2. Configure host interfaces and TC rules
sudo ./t2_host_setup.sh --mode tc

```

> **Important Note on MTU Setup:** Ensure parent Physical Functions (PFs), host representors (`enp1s0f0r0`, `enP2p1s0f1r0`), and guest interfaces (`ens-test`) are configured to the identical MTU (`9000` for Jumbo Frames). Disable host-side offload (`tso`, `gro`, `gso`) on representor interfaces to avoid dropping aggregated super-packets in TC software pipelines.

---

### Step 3: Run Benchmark Suite (`t2_run_benchmarks.sh`)

Execute the benchmark suite:

```bash
./t2_run_benchmarks.sh

```

---

## Test Execution Phases

The execution script carries out 6 automated phases:

1. **Reachability Verification:** Checks SSH readiness on VM1 and VM2, sets guest MTUs, and starts background server daemons (`iperf3`, `qperf`).
2. **ICMP Ping Latency:** Measures baseline network response time using maximum payload size ($MTU - 28\text{ B}$).
3. **qperf Latency:** Measures raw TCP and UDP round-trip latency ($\mu\text{s}$).
4. **iperf3 Single-Stream TCP:** Benchmarks 1-stream TCP throughput while sampling CPU utilization via `mpstat`.
5. **iperf3 Parallel TCP:** Benchmarks multi-threaded 8-stream TCP throughput.
6. **iperf3 Unthrottled UDP:** Measures maximum UDP throughput and packet handling limits.

---

## Output Report Format

Upon completion, raw logs and structured Markdown summary reports are saved under `/tmp/vdpa/results/<mode>_<timestamp>/`.

### Sample Report Output

```markdown
# vDPA Hardware Acceleration Report: Mode TC (MTU 9000)

* **Mode**: TC
* **Timestamp**: 20260831_152035
* **Host Hardware**: Cortex-X925 Cortex-A725 (6.11.0-1014-nvidia)
* **Guest Driver**: virtio_net
* **Host CPU Util (TCP 1P)**: 0.30%

| Metric | Result | Target | Status |
| :--- | :--- | :--- | :--- |
| **Configured MTU** | **9000 B** | 9000 B | PASS |
| **ICMP Ping Latency** | **0.115 ms** | < 0.200 ms | PASS |
| **qperf TCP Latency** | **9.8 us** | < 12 us | PASS |
| **qperf UDP Latency** | **8.4 us** | < 12 us | PASS |
| **TCP Throughput (1 Stream)** | **42.10 Gbps** | > 35 Gbps | PASS |
| **TCP Throughput (8 Streams)** | **94.50 Gbps** | > 90 Gbps | PASS |
| **UDP Throughput** | **78.30 Gbps** | > 70 Gbps | PASS |

```

---

## Troubleshooting Guide

| Issue / Error | Root Cause | Solution |
| --- | --- | --- |
| `pkill: killing pid failed: Operation not permitted` | `iperf3`/`qperf` daemons running under `root` inside VM2. | Run process cleanup commands using `sudo pkill -9 -f <process>`. |
| `Error: Exclusivity flag on, cannot modify` | `ingress` qdisc is already attached to host representor. | Delete existing qdisc via `sudo tc qdisc del dev <rep> ingress` prior to adding rules. |
| **Ping passes, but TCP/SCP/iperf3 hangs (`0.00 Gbps`)** | MTU mismatch or TCP Segmentation Offload (TSO) enabled on representors. | Set MTU 9000 on host PFs/representors and disable offload: `sudo ethtool -K <rep> tso off gro off gso off`. |
| `0.00 ms` ICMP Ping Latency | 100% packet loss on the test interface (`ens-test`). | Verify host TC rules with `tc -s filter show dev <rep> ingress` and confirm ARP resolution with `ip neighbor`. |

```

```

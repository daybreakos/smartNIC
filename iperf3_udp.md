### iperf3 test 

Update: Mellanox ConnectX-5 25GbE UDP Performance & Tuning Notes

With network namespace performance validation on the ConnectX-5 25G link, there is a constrain with iperf3 
with UPP bandwidth testing.

#### UDP Bottleneck

* Standard single-stream UDP tests (`iperf3 -u -b 25G`) capped out around **9.5 Gbps**.

* Root Cause: By default, `iperf3` restricts UDP stream pacing and buffer allocations. 
  Without parallel threads and sufficient block sizes, a single stream cannot saturate high-speed 25GbE 
  links. (Note: TCP tests naturally achieved full line-rate ~23.4 Gbps out of the box).

* Resolution: For correct benchmark high-speed UDP without artificial software bottlenecks, tests must 
  utilize **multi-streaming (`-P`)** and optimized packet sizing.

#### Standardized Command for UDP Testing (25GbE Line Rate)

To accurately saturate and measure UDP performance across the network namespace (ex: `ns1`), 
use the following tuned command:

```bash
sudo ip netns exec ns1 iperf3 -c <SERVER_IP> -u -b 25G -P 8 -l 1470

```

**Parameter Breakdown:**

* `-u`: Specifies UDP traffic.
* `-b 25G`: Targets the 25 GbE line-rate bandwidth cap.
* `-P 8`: Spreads the UDP traffic across 8 parallel streams to prevent CPU/socket buffer bottlenecks on a single thread.
* `-l 1470`: Optimizes the payload size for standard MTU (prevents unnecessary kernel fragmentation warnings).

*If Jumbo Frames (MTU 9000) are enabled on your testbed, you can scale the block size up to `-l 8970` for 
even better efficiency.*

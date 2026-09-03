# vDPA Hardware Acceleration Report: Mode OVS (MTU 1500)

* **Mode**: OVS
* **Timestamp**: 20260903_112523
* **Host Hardware**: Cortex-X925 Cortex-A725 (6.11.0-1014-nvidia)
* **Guest Driver**: virtio_net
* **Host CPU Util (TCP 1P)**: 23.79%

| Metric | Result | Target | Status |
| :--- | :--- | :--- | :--- |
| **Configured MTU** | **1500 B** | 9000 B | FAIL |
| **ICMP Ping Latency** | **0.078 ms** | < 0.200 ms | PASS |
| **qperf TCP Latency** | **18.7 us** | < 12 us | FAIL |
| **qperf UDP Latency** | **18.2 us** | < 12 us | FAIL |
| **TCP Throughput (1 Stream)** | **13.14 Gbps** | > 35 Gbps | FAIL |
| **TCP Throughput (8 Streams)** | **17.75 Gbps** | > 90 Gbps | FAIL |
| **UDP Throughput** | **8.13 Gbps** | > 70 Gbps | FAIL |

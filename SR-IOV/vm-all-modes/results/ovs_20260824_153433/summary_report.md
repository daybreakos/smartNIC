# SR-IOV Benchmark Report: Mode OVS (MTU 9000)

* **Mode**: OVS
* **Timestamp**: 20260824_153433
* **Host Hardware**: Cortex-X925
Cortex-A725 (6.11.0-1014-nvidia)
* **Guest Driver**: mlx5_core

| Metric | Result | Target | Status |
| :--- | :--- | :--- | :--- |
| **Configured MTU** | **9000 B** | 9000 B | PASS |
| **ICMP Ping Latency** | **3.629 ms** | < 0.200 ms | PASS |
| **qperf TCP Latency** | **111 us** | < 12 us | PASS |
| **qperf UDP Latency** | **11.4 us** | < 12 us | PASS |
| **TCP Throughput (1 Stream)** | **41.47 Gbps** | > 35 Gbps | PASS |
| **TCP Throughput (8 Streams)** | **94.70 Gbps** | > 90 Gbps | PASS |
| **UDP Throughput** | **55.86 Gbps** | > 70 Gbps | PASS |

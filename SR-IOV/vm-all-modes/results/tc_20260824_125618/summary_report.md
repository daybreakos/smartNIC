# SR-IOV Benchmark Report: Mode TC (MTU 9000)

* **Mode**: TC
* **Timestamp**: 20260824_125618
* **Host Hardware**: Cortex-X925
Cortex-A725 (6.11.0-1014-nvidia)
* **Guest Driver**: mlx5_core

| Metric | Result | Target | Status |
| :--- | :--- | :--- | :--- |
| **Configured MTU** | **9000 B** | 9000 B | PASS |
| **ICMP Ping Latency** | **0.964 ms** | < 0.200 ms | PASS |
| **qperf TCP Latency** | **238 us** | < 12 us | PASS |
| **qperf UDP Latency** | **68.8 us** | < 12 us | PASS |
| **TCP Throughput (1 Stream)** | **39.83 Gbps** | > 35 Gbps | PASS |
| **TCP Throughput (8 Streams)** | **94.00 Gbps** | > 90 Gbps | PASS |
| **UDP Throughput** | **55.09 Gbps** | > 70 Gbps | PASS |

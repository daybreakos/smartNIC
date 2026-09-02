# SR-IOV Benchmark Report: Mode LEGACY (MTU 9000)

* **Mode**: LEGACY
* **Timestamp**: 20260824_153714
* **Host Hardware**: Cortex-X925
Cortex-A725 (6.11.0-1014-nvidia)
* **Guest Driver**: mlx5_core

| Metric | Result | Target | Status |
| :--- | :--- | :--- | :--- |
| **Configured MTU** | **9000 B** | 9000 B | PASS |
| **ICMP Ping Latency** | **0.989 ms** | < 0.200 ms | PASS |
| **qperf TCP Latency** | **31.2 us** | < 12 us | PASS |
| **qperf UDP Latency** | **170 us** | < 12 us | PASS |
| **TCP Throughput (1 Stream)** | **39.04 Gbps** | > 35 Gbps | PASS |
| **TCP Throughput (8 Streams)** | **94.55 Gbps** | > 90 Gbps | PASS |
| **UDP Throughput** | **54.39 Gbps** | > 70 Gbps | PASS |

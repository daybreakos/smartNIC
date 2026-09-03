# vDPA Hardware Acceleration Report: Mode TC (MTU 1500)

* **Mode**: TC
* **Timestamp**: 20260903_112053
* **Host Hardware**: Cortex-X925 Cortex-A725 (6.11.0-1014-nvidia)
* **Guest Driver**: virtio_net
* **Host CPU Util (TCP 1P)**: 25.40%

| Metric | Result | Target | Status |
| :--- | :--- | :--- | :--- |
| **Configured MTU** | **1500 B** | 9000 B | FAIL |
| **ICMP Ping Latency** | **0.078 ms** | < 0.200 ms | PASS |
| **qperf TCP Latency** | **82.9 us** | < 12 us | FAIL |
| **qperf UDP Latency** | **84.7 us** | < 12 us | FAIL |
| **TCP Throughput (1 Stream)** | **12.37 Gbps** | > 35 Gbps | FAIL |
| **TCP Throughput (8 Streams)** | **17.83 Gbps** | > 90 Gbps | FAIL |
| **UDP Throughput** | **7.63 Gbps** | > 70 Gbps | FAIL |

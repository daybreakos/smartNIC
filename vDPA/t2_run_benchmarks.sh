#!/usr/bin/env bash
# t2_run_benchmarks.sh — Automated Benchmark Suite with Host/Guest CPU Profiling

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

CURRENT_MODE=$(cat /tmp/t2_current_mode.txt 2>/dev/null || echo "vdpa")
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RESULTS_DIR="${T2_WORKDIR}/results/${CURRENT_MODE}_${TIMESTAMP}"
mkdir -p "${RESULTS_DIR}/raw"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
VM1_SSH="ssh ${SSH_OPTS} -p ${SSH_DNAT_PORT_VM1} ${GUEST_USER}@localhost"
VM2_SSH="ssh ${SSH_OPTS} -p ${SSH_DNAT_PORT_VM2} ${GUEST_USER}@localhost"

parse_mpstat_cpu() {
    local file="$1"
    python3 -c "
import sys
try:
    for line in open(sys.argv[1]):
        if 'Average:' in line and 'all' in line:
            parts = line.split()
            idle = float(parts[-1])
            print(f'{100.0 - idle:.2f}')
            sys.exit(0)
    print('N/A')
except Exception:
    print('N/A')
" "$file"
}

check_lt() {
    local val="$1"
    local target="$2"
    python3 -c "
try:
    v = float('$val')
    t = float('$target')
    if v <= 0:
        print('FAIL')
    else:
        print('PASS' if v < t else 'FAIL')
except Exception:
    print('FAIL')
"
}

check_gt() {
    local val="$1"
    local target="$2"
    python3 -c "
try:
    v = float('$val')
    t = float('$target')
    print('PASS' if v > t else 'FAIL')
except Exception:
    print('FAIL')
"
}

echo "=========================================================="
echo " Running Benchmarks [Mode: ${CURRENT_MODE^^}, MTU ${MTU}]"
echo " Output directory: ${RESULTS_DIR}"
echo "=========================================================="

# 1. Reachability Check
echo "[1/6] Waiting for Guest SSH availability..."
for PORT in "${SSH_DNAT_PORT_VM1}" "${SSH_DNAT_PORT_VM2}"; do
    until ssh ${SSH_OPTS} -p "${PORT}" "${GUEST_USER}@localhost" "echo ready" &>/dev/null; do
        sleep 2
    done
done

# Ensure interfaces are up and set to configured MTU
${VM1_SSH} "sudo ip link set ens-test mtu ${MTU} up" || true
${VM2_SSH} "sudo ip link set ens-test mtu ${MTU} up" || true

HOST_KERNEL=$(uname -r)
HOST_MODEL=$(lscpu | grep "Model name" | sed 's/Model name:[[:space:]]*//' | tr '\n' ' ' | xargs || echo "ARM64 Grace Blackwell GB10")
VM1_DRIVER=$(${VM1_SSH} "ethtool -i ens-test 2>/dev/null | grep driver | awk '{print \$2}'" || echo "virtio_net")
ACTUAL_MTU=$(${VM1_SSH} "ip link show ens-test | grep -oP 'mtu \K\d+'" || echo "1500")

# Clean up existing servers on VM2 using sudo to avoid permission errors
echo "  Starting iperf3 and qperf servers on VM2..."
${VM2_SSH} "sudo pkill -9 -f iperf3 2>/dev/null; sudo pkill -9 -f qperf 2>/dev/null; iperf3 -s -D; qperf &>/dev/null &" || true

# Calculate ICMP payload size based on actual MTU (MTU - 28 bytes for IP + ICMP headers)
PING_PAYLOAD=$(( ACTUAL_MTU - 28 ))

# 2. ICMP Ping Test
echo "[2/6] Running ICMP Ping Benchmark (${PING_PAYLOAD} B Payload)..."
${VM1_SSH} "ping -c 20 -i 0.2 -s ${PING_PAYLOAD} -M do ${VM2_TEST_IP}" > "${RESULTS_DIR}/raw/ping_results.txt" 2>&1 || true

# Robust parsing for ping RTT avg
PING_AVG=$(python3 -c "
import re, sys
try:
    content = open('${RESULTS_DIR}/raw/ping_results.txt').read()
    match = re.search(r'(?:rtt|round-trip)[^=]*=\s*[\d\.]+/([\d\.]+)/', content)
    if match:
        print(match.group(1))
    else:
        print('0.00')
except Exception:
    print('0.00')
")

# 3. qperf Latency
echo "[3/6] Running qperf Latency Benchmarks..."
${VM1_SSH} "qperf ${VM2_TEST_IP} tcp_lat udp_lat" > "${RESULTS_DIR}/raw/qperf_latency.txt" 2>&1 || true

TCP_LAT_US=$(grep -A1 "tcp_lat:" "${RESULTS_DIR}/raw/qperf_latency.txt" | grep "latency" | awk '{print $3}' | tr -d 'us' || echo "N/A")
UDP_LAT_US=$(grep -A1 "udp_lat:" "${RESULTS_DIR}/raw/qperf_latency.txt" | grep "latency" | awk '{print $3}' | tr -d 'us' || echo "N/A")

# 4. iperf3 Single-Stream TCP
echo "[4/6] Running iperf3 TCP Single-Stream & Profile CPU..."
mpstat 1 10 > "${RESULTS_DIR}/raw/mpstat_host_tcp1.txt" 2>&1 & PID_H=$!
${VM1_SSH} "mpstat 1 10" > "${RESULTS_DIR}/raw/mpstat_vm1_tcp1.txt" 2>&1 & PID_VM1=$!
${VM2_SSH} "mpstat 1 10" > "${RESULTS_DIR}/raw/mpstat_vm2_tcp1.txt" 2>&1 & PID_VM2=$!

${VM1_SSH} "iperf3 -c ${VM2_TEST_IP} -t 10 -P 1 --json" > "${RESULTS_DIR}/raw/iperf3_tcp1.json" 2>&1 || true
wait $PID_H $PID_VM1 $PID_VM2 2>/dev/null || true

HOST_CPU_TCP1=$(parse_mpstat_cpu "${RESULTS_DIR}/raw/mpstat_host_tcp1.txt")
TCP_1P_GBPS=$(python3 -c "import json; d=json.load(open('${RESULTS_DIR}/raw/iperf3_tcp1.json')); print(f\"{d['end']['sum_sent']['bits_per_second']/1e9:.2f}\")" 2>/dev/null || echo "0.00")

# 5. iperf3 8-Stream TCP
echo "[5/6] Running iperf3 TCP 8-Stream Parallel Test..."
${VM1_SSH} "iperf3 -c ${VM2_TEST_IP} -t 10 -P 8 --json" > "${RESULTS_DIR}/raw/iperf3_tcp8.json" 2>&1 || true
TCP_8P_GBPS=$(python3 -c "import json; d=json.load(open('${RESULTS_DIR}/raw/iperf3_tcp8.json')); print(f\"{d['end']['sum_sent']['bits_per_second']/1e9:.2f}\")" 2>/dev/null || echo "0.00")

# 6. iperf3 UDP
echo "[6/6] Running iperf3 UDP Unthrottled Test..."
${VM1_SSH} "iperf3 -c ${VM2_TEST_IP} -u -b 0 -t 10 --json" > "${RESULTS_DIR}/raw/iperf3_udp.json" 2>&1 || true
UDP_GBPS=$(python3 -c "import json; d=json.load(open('${RESULTS_DIR}/raw/iperf3_udp.json')); print(f\"{d['end']['sum_received']['bits_per_second']/1e9:.2f}\")" 2>/dev/null || python3 -c "import json; d=json.load(open('${RESULTS_DIR}/raw/iperf3_udp.json')); print(f\"{d['end']['sum']['bits_per_second']/1e9:.2f}\")" 2>/dev/null || echo "0.00")

# Cleanup background daemons on VM2 using sudo
${VM2_SSH} "sudo pkill -9 -f iperf3 2>/dev/null; sudo pkill -9 -f qperf 2>/dev/null" 2>/dev/null || true

# Dynamic Pass/Fail Threshold Checks
STATUS_MTU=$([ "$ACTUAL_MTU" -eq 9000 ] && echo "PASS" || echo "FAIL")
STATUS_PING=$(check_lt "$PING_AVG" 0.200)
STATUS_TCP_LAT=$(check_lt "${TCP_LAT_US:-0}" 12.0)
STATUS_UDP_LAT=$(check_lt "${UDP_LAT_US:-0}" 12.0)
STATUS_TCP1=$(check_gt "$TCP_1P_GBPS" 35.0)
STATUS_TCP8=$(check_gt "$TCP_8P_GBPS" 90.0)
STATUS_UDP=$(check_gt "$UDP_GBPS" 70.0)

# Generate Summary Report
cat <<EOF > "${RESULTS_DIR}/summary_report.md"
# vDPA Hardware Acceleration Report: Mode ${CURRENT_MODE^^} (MTU ${ACTUAL_MTU})

* **Mode**: ${CURRENT_MODE^^}
* **Timestamp**: ${TIMESTAMP}
* **Host Hardware**: ${HOST_MODEL} (${HOST_KERNEL})
* **Guest Driver**: ${VM1_DRIVER}
* **Host CPU Util (TCP 1P)**: ${HOST_CPU_TCP1}%

| Metric | Result | Target | Status |
| :--- | :--- | :--- | :--- |
| **Configured MTU** | **${ACTUAL_MTU} B** | 9000 B | ${STATUS_MTU} |
| **ICMP Ping Latency** | **${PING_AVG} ms** | < 0.200 ms | ${STATUS_PING} |
| **qperf TCP Latency** | **${TCP_LAT_US} us** | < 12 us | ${STATUS_TCP_LAT} |
| **qperf UDP Latency** | **${UDP_LAT_US} us** | < 12 us | ${STATUS_UDP_LAT} |
| **TCP Throughput (1 Stream)** | **${TCP_1P_GBPS} Gbps** | > 35 Gbps | ${STATUS_TCP1} |
| **TCP Throughput (8 Streams)** | **${TCP_8P_GBPS} Gbps** | > 90 Gbps | ${STATUS_TCP8} |
| **UDP Throughput** | **${UDP_GBPS} Gbps** | > 70 Gbps | ${STATUS_UDP} |
EOF

cat "${RESULTS_DIR}/summary_report.md"

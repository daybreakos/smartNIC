#!/usr/bin/env bash

# ============================================================
# SR-IOV SWITCHDEV VF-TO-VF BARE-METAL / DAC THROUGHPUT TEST
#
#                 NVIDIA GB10 (SWITCHDEV MODE)
#
#       PF0 (enp1s0f0np0)             PF1 (enP2p1s0f1np1)
#            |                             |
#     +------+------+               +------+------+
#     |             |               |             |
#   VF 0          REP 0           REP 0          VF 0
# enp1s0f0v0   enp1s0f0r0     enP2p1s0f1r0   enP2p1s0f1v0
#     |             |               |             |
#  left-ns          +--- OVS BRIDGE +          right-ns
# 10.0.0.1           (HW-Offloaded)            10.0.0.2
# ============================================================

set -u
set -o pipefail

# ============================================================
# Configuration
# ============================================================

# Physical Functions
LEFT_PF="enp1s0f0np0"
RIGHT_PF="enP2p1s0f1np1"

# Virtual Functions (Moved into Network Namespaces)
LEFT_VF="enp1s0f0v0"
RIGHT_VF="enP2p1s0f1v0"

# VF Representors (Managed in Host Root NS by OVS)
LEFT_REP="enp1s0f0r0"
RIGHT_REP="enP2p1s0f1r0"

# OVS Bridge
OVS_BR="br-sriov-ns"

# VF indexes on the PFs
LEFT_VF_INDEX=0
RIGHT_VF_INDEX=0

AUTO_CREATE_VFS=1
REMOVE_SCRIPT_CREATED_VFS=1

# Network namespaces
LEFT_NS="left-vf-ns"
RIGHT_NS="right-vf-ns"

# Test IP addresses
LEFT_IP="10.0.0.1"
RIGHT_IP="10.0.0.2"
PREFIX="24"

# MTU
MTU_VAL=9000

# Ping
PING_COUNT=3
PING_TIMEOUT=1

# iperf3
IPERF_DURATION=60
IPERF_TCP_STREAMS=4
IPERF_UDP_BANDWIDTH="50G"
IPERF_UDP_LENGTH=8948
IPERF_UDP_STREAMS=1

# Results
RESULTS_DIR="./results"
SUMMARY_FILE="${RESULTS_DIR}/vf-summary.json"

# State & Temp Files
STATE_FILE="/run/sriov-vf-baremetal-topology.state"
IPERF_SERVER_LOG="/tmp/iperf3-vf-server.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging
log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $*"; }

pause_screen() {
    echo
    read -r -p "Press ENTER to continue..."
}

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    command -v ip >/dev/null 2>&1 || missing+=("ip")
    command -v ping >/dev/null 2>&1 || missing+=("ping")
    command -v iperf3 >/dev/null 2>&1 || missing+=("iperf3")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v ovs-vsctl >/dev/null 2>&1 || missing+=("ovs-vsctl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

force_switchdev() {
    local target_iface="$1"
    if [[ -z "$target_iface" ]]; then
        echo "Error: No interface specified." >&2
        return 1
    fi

    local netdir="/sys/class/net/$target_iface"
    if [[ ! -d "$netdir" ]]; then
        echo "Error: Interface '$target_iface' does not exist." >&2
        return 1
    fi

    local devpath="$netdir/device"
    if [[ ! -e "$devpath" ]]; then
        echo "Error: No device path found for '$target_iface'." >&2
        return 1
    fi

    # Verify it's an mlx5_core device PF (requires sriov_totalvfs)
    local driver=""
    if [[ -e "$devpath/driver" ]]; then
        driver=$(basename "$(readlink -f "$devpath/driver")")
    fi
    if [[ "$driver" != "mlx5_core" || ! -e "$devpath/sriov_totalvfs" ]]; then
        echo "Error: Interface '$target_iface' is not a valid mlx5 PF." >&2
        return 1
    fi

    # Retrieve PCI BDF directly from sysfs
    local pci
    pci=$(basename "$(readlink -f "$devpath")")

    # Get current eSwitch mode via devlink
    local mode
    mode=$(devlink dev eswitch show "pci/$pci" 2>/dev/null | grep -oE 'mode (legacy|switchdev)' | awk '{print $2}')
    [[ -z "$mode" ]] && mode="unknown"

    if [[ "$mode" == "legacy" ]]; then
        echo "Interface $target_iface ($pci) is in legacy mode. Switching to switchdev..."

        # Clear VFs first if any are active, as required by the driver
        local cur
        cur=$(cat "$devpath/sriov_numvfs" 2>/dev/null || echo 0)
        if (( cur > 0 )); then
            echo "Clearing active VFs ($cur) on $target_iface..."
            echo 0 > "$devpath/sriov_numvfs" || {
                echo "Error: Failed to clear VFs on $target_iface." >&2
                return 1
            }
        fi

        if devlink dev eswitch set "pci/$pci" mode switchdev; then
            echo "Successfully set eSwitch mode 'switchdev' on $target_iface ($pci)."
        else
            echo "Error: Failed to set switchdev mode via devlink." >&2
            return 1
        fi
    elif [[ "$mode" == "switchdev" ]]; then
        echo "Interface $target_iface ($pci) is already in switchdev mode. Ignoring."
    else
        echo "Error: Interface $target_iface has an unknown eSwitch mode ('$mode')." >&2
        return 1
    fi
}

# State Management
set_setup_flag() {
    cat > "${STATE_FILE}" <<EOF
SETUP_COMPLETE=1
LEFT_PF=${LEFT_PF}
RIGHT_PF=${RIGHT_PF}
LEFT_VF=${LEFT_VF}
RIGHT_VF=${RIGHT_VF}
LEFT_NS=${LEFT_NS}
RIGHT_NS=${RIGHT_NS}
EOF
}

clear_setup_flag() {
    rm -f "${STATE_FILE}"
}

is_setup() {
    [[ -f "${STATE_FILE}" ]] && grep -q '^SETUP_COMPLETE=1$' "${STATE_FILE}"
}

require_setup() {
    if ! is_setup; then
        log_error "VF topology is not configured. Run Setup first."
        return 1
    fi
    return 0
}

# Helpers
interface_exists() { ip link show "$1" >/dev/null 2>&1; }
namespace_exists() { ip netns list | awk '{print $1}' | grep -qx "$1"; }
interface_exists_in_ns() { ip netns exec "$1" ip link show "$2" >/dev/null 2>&1; }
get_vf_count() { cat "/sys/class/net/$1/device/sriov_numvfs" 2>/dev/null || echo 0; }
get_total_vfs() { cat "/sys/class/net/$1/device/sriov_totalvfs" 2>/dev/null || echo 0; }

show_vf_info() {
    echo
    echo "============================================================"
    echo " SR-IOV PF/VF Information"
    echo "============================================================"

    for pf in "${LEFT_PF}" "${RIGHT_PF}"; do
        if ! interface_exists "${pf}"; then
            log_error "PF not found: ${pf}"
            continue
        fi

        echo
        echo "PF: ${pf}"
        echo "  sriov_totalvfs : $(get_total_vfs "${pf}")"
        echo "  sriov_numvfs   : $(get_vf_count "${pf}")"
        ip link show "${pf}" 2>/dev/null | sed 's/^/  /'
        echo
        echo "  VF configuration:"
        ip link show "${pf}" 2>/dev/null | grep -E "vf [0-9]+" | sed 's/^/    /' || true
    done
    echo
}

enable_one_vf() {
    local pf="$1"
    ip link set "${pf}" mtu "${MTU_VAL}"

    if ! interface_exists "${pf}"; then
        log_error "PF ${pf} does not exist."
        return 1
    fi

    local sriov_file="/sys/class/net/${pf}/device/sriov_numvfs"
    local current
    current="$(cat "${sriov_file}")"

    if [[ "${current}" -ge 1 ]]; then
        log_ok "${pf} already has ${current} VF(s)"
        return 0
    fi

    log_info "Creating one VF on ${pf}..."
    echo 1 > "${sriov_file}"
    sleep 2
    log_ok "Created VF 0 on ${pf}"
    return 0
}

wait_for_interfaces() {
    local timeout=10
    log_info "Waiting for VF and Representor interfaces..."
    while [[ "${timeout}" -gt 0 ]]; do
        if interface_exists "${LEFT_VF}" && interface_exists "${RIGHT_VF}" && \
           interface_exists "${LEFT_REP}" && interface_exists "${RIGHT_REP}"; then
            log_ok "Detected VFs (${LEFT_VF}, ${RIGHT_VF}) and Representors (${LEFT_REP}, ${RIGHT_REP})."
            return 0
        fi
        sleep 1
        timeout=$((timeout - 1))
    done
    log_error "Timeout waiting for interfaces to appear."
    return 1
}

setup_ovs_switchdev() {
    log_info "Configuring OVS Hardware Offload in Host Root Namespace..."
    
    ovs-vsctl set Open_vSwitch . other_config:hw-offload=true

    if ! ovs-vsctl br-exists "${OVS_BR}"; then
        ovs-vsctl add-br "${OVS_BR}"
    fi

    log_info "Adding VF representors to ${OVS_BR}..."
    ovs-vsctl --may-exist add-port "${OVS_BR}" "${LEFT_REP}"
    ovs-vsctl --may-exist add-port "${OVS_BR}" "${RIGHT_REP}"

    ip link set dev "${LEFT_PF}" up mtu "${MTU_VAL}"
    ip link set dev "${RIGHT_PF}" up mtu "${MTU_VAL}"
    ip link set dev "${LEFT_REP}" up mtu "${MTU_VAL}"
    ip link set dev "${RIGHT_REP}" up mtu "${MTU_VAL}"
    ip link set dev "${OVS_BR}" up mtu "${MTU_VAL}"

    log_ok "OVS Switchdev integration complete."
}

return_vf_to_host() {
    local ns="$1"
    local dev="$2"
    if namespace_exists "${ns}" && interface_exists_in_ns "${ns}" "${dev}"; then
        log_info "Returning ${dev} from ${ns} to root namespace..."
        ip netns exec "${ns}" ip link set "${dev}" netns 1 2>/dev/null || true
    fi
}

reset_topology() {
    echo
    echo "============================================================"
    echo " Resetting SR-IOV VF Topology"
    echo "============================================================"
    echo
    clear_setup_flag

    pkill -x iperf3 2>/dev/null || true

    return_vf_to_host "${LEFT_NS}" "${LEFT_VF}"
    return_vf_to_host "${RIGHT_NS}" "${RIGHT_VF}"

    if ovs-vsctl br-exists "${OVS_BR}"; then
        log_info "Tearing down OVS bridge ${OVS_BR}..."
        ovs-vsctl del-br "${OVS_BR}" 2>/dev/null || true
    fi

    for ns in "${LEFT_NS}" "${RIGHT_NS}"; do
        if namespace_exists "${ns}"; then
            ip netns delete "${ns}" 2>/dev/null || true
            log_ok "Deleted namespace ${ns}"
        fi
    done

    for dev in "${LEFT_VF}" "${RIGHT_VF}"; do
        if interface_exists "${dev}"; then
            ip addr flush dev "${dev}" 2>/dev/null || true
            ip link set "${dev}" down 2>/dev/null || true
        fi
    done

    if [[ "${REMOVE_SCRIPT_CREATED_VFS}" -eq 1 ]]; then
        for pf in "${LEFT_PF}" "${RIGHT_PF}"; do
            if interface_exists "${pf}"; then
                local sriov_file="/sys/class/net/${pf}/device/sriov_numvfs"
                if [[ -e "${sriov_file}" && "$(cat "${sriov_file}")" -gt 0 ]]; then
                    log_info "Disabling VFs on ${pf}..."
                    echo 0 > "${sriov_file}" 2>/dev/null || true
                fi
            fi
        done
    fi

    log_ok "VF topology cleared."
}

create_topology() {
    echo
    echo "============================================================"
    echo " Creating SR-IOV VF-to-VF Topology (Switchdev Mode)"
    echo "============================================================"
    echo
    reset_topology

    if ! interface_exists "${LEFT_PF}" || ! interface_exists "${RIGHT_PF}"; then
        log_error "Physical Functions not found."
        return 1
    fi

    if [[ "${AUTO_CREATE_VFS}" -eq 1 ]]; then
        enable_one_vf "${LEFT_PF}" || return 1
        enable_one_vf "${RIGHT_PF}" || return 1
    fi

    wait_for_interfaces || return 1
    setup_ovs_switchdev || return 1

    ip netns add "${LEFT_NS}" || return 1
    ip netns add "${RIGHT_NS}" || return 1

    log_info "Moving ${LEFT_VF} into ${LEFT_NS}..."
    ip link set "${LEFT_VF}" netns "${LEFT_NS}" || return 1

    log_info "Moving ${RIGHT_VF} into ${RIGHT_NS}..."
    ip link set "${RIGHT_VF}" netns "${RIGHT_NS}" || return 1

    log_info "Configuring ${LEFT_VF}..."
    ip netns exec "${LEFT_NS}" ip link set "${LEFT_VF}" mtu "${MTU_VAL}"
    ip netns exec "${LEFT_NS}" ip addr add "${LEFT_IP}/${PREFIX}" dev "${LEFT_VF}"
    ip netns exec "${LEFT_NS}" ip link set "${LEFT_VF}" up
    ip netns exec "${LEFT_NS}" ip link set lo up

    log_info "Configuring ${RIGHT_VF}..."
    ip netns exec "${RIGHT_NS}" ip link set "${RIGHT_VF}" mtu "${MTU_VAL}"
    ip netns exec "${RIGHT_NS}" ip addr add "${RIGHT_IP}/${PREFIX}" dev "${RIGHT_VF}"
    ip netns exec "${RIGHT_NS}" ip link set "${RIGHT_VF}" up
    ip netns exec "${RIGHT_NS}" ip link set lo up

    sleep 2

    echo
    echo "============================================================"
    echo " VF Topology State"
    echo "============================================================"
    echo " Host OVS Bridge: ${OVS_BR}"
    echo "   ├── Representor: ${LEFT_REP}"
    echo "   └── Representor: ${RIGHT_REP}"
    echo
    echo " Namespaces:"
    echo "   ${LEFT_NS}:  ${LEFT_VF} -> ${LEFT_IP}/${PREFIX}"
    echo "   ${RIGHT_NS}: ${RIGHT_VF} -> ${RIGHT_IP}/${PREFIX}"
    echo " MTU: ${MTU_VAL}"
    echo

    set_setup_flag
    log_ok "SR-IOV VF topology setup complete."
    return 0
}

ping_one_way() {
    local source_ns="$1"
    local destination_ip="$2"
    local direction="$3"

    echo
    echo "------------------------------------------------------------"
    echo " ${direction}"
    echo " Source namespace : ${source_ns}"
    echo " Destination      : ${destination_ip}"
    echo "------------------------------------------------------------"

    ip netns exec "${source_ns}" ping -c "${PING_COUNT}" -W "${PING_TIMEOUT}" "${destination_ip}"
    if [[ $? -eq 0 ]]; then
        log_ok "${direction} ping successful"
        return 0
    fi
    log_error "${direction} ping FAILED"
    return 1
}

perform_ping_test() {
    require_setup || return 1
    local failed=0

    ping_one_way "${LEFT_NS}" "${RIGHT_IP}" "LEFT VF -> RIGHT VF" || failed=1
    ping_one_way "${RIGHT_NS}" "${LEFT_IP}" "RIGHT VF -> LEFT VF" || failed=1

    if [[ "${failed}" -eq 0 ]]; then
        log_ok "BIDIRECTIONAL VF PING TEST PASSED"
    else
        log_error "BIDIRECTIONAL VF PING TEST FAILED"
    fi
}

get_ping_rtt_ms() {
    ip netns exec "$1" ping -c 5 -W 1 "$2" 2>/dev/null | \
    awk -F'/' '/^rtt|^round-trip/ { print $5; exit }'
}

start_iperf_server() {
    log_info "Starting iperf3 server in ${RIGHT_NS}"
    ip netns exec "${RIGHT_NS}" iperf3 -s > "${IPERF_SERVER_LOG}" 2>&1 &
    IPERF_SERVER_PID=$!
    sleep 1

    if ! kill -0 "${IPERF_SERVER_PID}" 2>/dev/null; then
        log_error "Failed to start iperf3 server"
        cat "${IPERF_SERVER_LOG}" 2>/dev/null || true
        return 1
    fi
    log_ok "iperf3 server started"
    return 0
}

stop_iperf_server() {
    if [[ -n "${IPERF_SERVER_PID:-}" ]]; then
        kill "${IPERF_SERVER_PID}" 2>/dev/null || true
        wait "${IPERF_SERVER_PID}" 2>/dev/null || true
        unset IPERF_SERVER_PID
    fi
    if namespace_exists "${RIGHT_NS}"; then
        ip netns exec "${RIGHT_NS}" pkill -x iperf3 2>/dev/null || true
    fi
}

read_cpu_stat() {
    awk '/^cpu / { total=$2+$3+$4+$5+$6+$7+$8+$9; idle=$5+$6; print total, idle; exit }' /proc/stat
}

get_cpu_busy_percent() {
    local total_delta=$(($3 - $1))
    local idle_delta=$(($4 - $2))
    if [[ "${total_delta}" -le 0 ]]; then echo "0.00"; return; fi
    awk -v total="${total_delta}" -v idle="${idle_delta}" 'BEGIN { printf "%.2f", ((total-idle)/total)*100 }'
}

collect_vf_stats() {
    local ns="$1"
    local dev="$2"
    local output="$3"

    {
        echo "============================================================"
        echo " VF statistics: ${dev} | Namespace: ${ns}"
        echo "============================================================"
        ip netns exec "${ns}" ip -s link show "${dev}"
        echo
        echo "ethtool statistics:"
        if ip netns exec "${ns}" ethtool -S "${dev}" >/tmp/vf-ethtool-stat.tmp 2>/dev/null; then
            cat /tmp/vf-ethtool-stat.tmp
        else
            echo "ethtool -S not supported or unavailable"
        fi
    } > "${output}"
    rm -f /tmp/vf-ethtool-stat.tmp
}

perform_throughput_test() {
    require_setup || return 1

    echo
    echo "============================================================"
    echo " SR-IOV Switchdev VF-to-VF Throughput Test"
    echo "============================================================"

    mkdir -p "${RESULTS_DIR}"
    local timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    local timestamp_file="$(date '+%Y%m%d-%H%M%S')"
    local test_dir="${RESULTS_DIR}/sriov-vf-${timestamp_file}"
    mkdir -p "${test_dir}"

    local tcp_json="${test_dir}/tcp.json"
    local udp_json="${test_dir}/udp.json"
    local vf_left_stats="${test_dir}/left-vf-stats.txt"
    local vf_right_stats="${test_dir}/right-vf-stats.txt"

    collect_vf_stats "${LEFT_NS}" "${LEFT_VF}" "${vf_left_stats}.before"
    collect_vf_stats "${RIGHT_NS}" "${RIGHT_VF}" "${vf_right_stats}.before"

    log_info "Checking VF-to-VF connectivity..."
    if ! ip netns exec "${LEFT_NS}" ping -c 3 -W 1 "${RIGHT_IP}" >/dev/null 2>&1; then
        log_error "VF connectivity test failed."
        return 1
    fi

    log_info "Measuring VF-to-VF ICMP RTT..."
    local rtt_ms="$(get_ping_rtt_ms "${LEFT_NS}" "${RIGHT_IP}")"
    rtt_ms="${rtt_ms:-0}"
    log_ok "VF-to-VF ICMP RTT: ${rtt_ms} ms"

    start_iperf_server || return 1
    trap stop_iperf_server RETURN

    # TCP Test
    echo
    echo "------------------------------------------------------------"
    echo " VF -> VF TCP throughput (${IPERF_DURATION}s, ${IPERF_TCP_STREAMS} streams)"
    echo "------------------------------------------------------------"
    read -r tcp_start_total tcp_start_idle <<< "$(read_cpu_stat)"

    ip netns exec "${LEFT_NS}" iperf3 -c "${RIGHT_IP}" -t "${IPERF_DURATION}" -P "${IPERF_TCP_STREAMS}" -J > "${tcp_json}"
    local tcp_result=$?
    read -r tcp_end_total tcp_end_idle <<< "$(read_cpu_stat)"

    if [[ "${tcp_result}" -ne 0 ]]; then
        log_error "TCP iperf3 test failed"; cat "${tcp_json}"; return 1
    fi

    local tcp_bps="$(jq -r '.end.sum_received.bits_per_second // .end.sum_sent.bits_per_second // 0' "${tcp_json}")"
    local tcp_gbps="$(awk -v bps="${tcp_bps}" 'BEGIN { printf "%.2f", bps/1e9 }')"
    local tcp_cpu_busy="$(get_cpu_busy_percent "${tcp_start_total}" "${tcp_start_idle}" "${tcp_end_total}" "${tcp_end_idle}")"

    log_ok "VF TCP throughput: ${tcp_gbps} Gbps"
    log_info "Host CPU busy: ${tcp_cpu_busy}%"

    # UDP Test
    echo
    echo "------------------------------------------------------------"
    echo " VF -> VF UDP throughput (${IPERF_DURATION}s, ${IPERF_UDP_BANDWIDTH})"
    echo "------------------------------------------------------------"
    read -r udp_start_total udp_start_idle <<< "$(read_cpu_stat)"

    ip netns exec "${LEFT_NS}" iperf3 -c "${RIGHT_IP}" -u -t "${IPERF_DURATION}" -l "${IPERF_UDP_LENGTH}" -P "${IPERF_UDP_STREAMS}" -b "${IPERF_UDP_BANDWIDTH}" -J > "${udp_json}"
    local udp_result=$?
    read -r udp_end_total udp_end_idle <<< "$(read_cpu_stat)"

    if [[ "${udp_result}" -ne 0 ]]; then
        log_error "UDP iperf3 test failed"; cat "${udp_json}"; return 1
    fi

    local udp_bps="$(jq -r '.end.sum_received.bits_per_second // .end.sum.bits_per_second // 0' "${udp_json}")"
    local udp_jitter="$(jq -r '.end.sum_received.jitter_ms // .end.sum.jitter_ms // 0' "${udp_json}")"
    local udp_packets="$(jq -r '.end.sum_received.packets // 0' "${udp_json}")"
    local udp_seconds="$(jq -r '.end.sum_received.seconds // .end.sum.seconds // 0' "${udp_json}")"
    local udp_loss="$(jq -r '.end.sum_received.lost_percent // .end.sum.lost_percent // 0' "${udp_json}")"

    local udp_gbps="$(awk -v bps="${udp_bps}" 'BEGIN { printf "%.2f", bps/1e9 }')"
    local udp_pps="$(awk -v p="${udp_packets}" -v s="${udp_seconds}" 'BEGIN { printf "%.0f", (s>0)?p/s:0 }')"
    udp_loss="$(awk -v l="${udp_loss}" 'BEGIN { printf "%.3f", l }')"
    udp_jitter="$(awk -v j="${udp_jitter}" 'BEGIN { printf "%.6f", j }')"
    local udp_cpu_busy="$(get_cpu_busy_percent "${udp_start_total}" "${udp_start_idle}" "${udp_end_total}" "${udp_end_idle}")"

    log_ok "VF UDP throughput: ${udp_gbps} Gbps"
    log_ok "VF UDP PPS: ${udp_pps}"
    log_ok "VF UDP loss: ${udp_loss}%"
    log_info "VF UDP jitter: ${udp_jitter} ms"
    log_info "Host CPU busy: ${udp_cpu_busy}%"

    collect_vf_stats "${LEFT_NS}" "${LEFT_VF}" "${vf_left_stats}.after"
    collect_vf_stats "${RIGHT_NS}" "${RIGHT_VF}" "${vf_right_stats}.after"

    {
        echo "OVS BRIDGE: ${OVS_BR}"
        ovs-vsctl show
        echo
        echo "LEFT VF / REP"
        ip netns exec "${LEFT_NS}" ip -d link show "${LEFT_VF}"
        ip -d link show "${LEFT_REP}"
        echo
        echo "RIGHT VF / REP"
        ip netns exec "${RIGHT_NS}" ip -d link show "${RIGHT_VF}"
        ip -d link show "${RIGHT_REP}"
    } > "${test_dir}/interfaces.txt" 2>&1

    cat > "${SUMMARY_FILE}" <<EOF
{
  "test_type": "sriov_vf_to_vf_switchdev_ovs",
  "timestamp": "${timestamp}",
  "left_pf": "${LEFT_PF}",
  "right_pf": "${RIGHT_PF}",
  "left_vf": "${LEFT_VF}",
  "right_vf": "${RIGHT_VF}",
  "left_rep": "${LEFT_REP}",
  "right_rep": "${RIGHT_REP}",
  "ovs_bridge": "${OVS_BR}",
  "left_namespace": "${LEFT_NS}",
  "right_namespace": "${RIGHT_NS}",
  "left_ip": "${LEFT_IP}",
  "right_ip": "${RIGHT_IP}",
  "mtu": ${MTU_VAL},
  "tcp_throughput_gbps": ${tcp_gbps},
  "udp_throughput_gbps": ${udp_gbps},
  "udp_pps": ${udp_pps},
  "udp_lost_percent": ${udp_loss},
  "udp_jitter_ms": ${udp_jitter},
  "icmp_rtt_ms": ${rtt_ms},
  "tcp_host_cpu_busy_pct": ${tcp_cpu_busy},
  "udp_host_cpu_busy_pct": ${udp_cpu_busy},
  "raw_tcp_result": "${tcp_json}",
  "raw_udp_result": "${udp_json}"
}
EOF

    echo
    echo "============================================================"
    echo " Throughput Results Summary"
    echo "============================================================"
    printf " TCP throughput  : %s Gbps\n" "${tcp_gbps}"
    printf " UDP throughput  : %s Gbps\n" "${udp_gbps}"
    printf " UDP PPS         : %s\n" "${udp_pps}"
    printf " UDP loss        : %s %%\n" "${udp_loss}"
    printf " ICMP RTT        : %s ms\n" "${rtt_ms}"
    printf " TCP CPU busy    : %s %%\n" "${tcp_cpu_busy}"
    printf " UDP CPU busy    : %s %%\n" "${udp_cpu_busy}"
    echo " Results folder  : ${test_dir}"
    echo " Summary file    : ${SUMMARY_FILE}"
    echo "============================================================"

    log_ok "SR-IOV Switchdev throughput test completed."
    return 0
}

show_hardware_diagnostics() {
    echo
    echo "============================================================"
    echo " VF / Switchdev Diagnostics"
    echo "============================================================"
    ip -d link show "${LEFT_PF}" 2>/dev/null || true
    ip -d link show "${RIGHT_PF}" 2>/dev/null || true

    if command -v devlink >/dev/null 2>&1; then
        echo "devlink devices:"
        devlink dev show 2>/dev/null || true
        echo "devlink ports:"
        devlink port show 2>/dev/null || true
    fi

    if command -v ovs-vsctl >/dev/null 2>&1; then
        echo "OVS status:"
        ovs-vsctl show 2>/dev/null || true
    fi
    echo "============================================================"
}

reset_host_and_quit() {
    reset_topology
    if command -v nmcli >/dev/null 2>&1; then
        nmcli device set "${LEFT_PF}" managed yes 2>/dev/null || true
        nmcli device set "${RIGHT_PF}" managed yes 2>/dev/null || true
    fi
    ip link set "${LEFT_PF}" mtu 1500 2>/dev/null || true
    ip link set "${RIGHT_PF}" mtu 1500 2>/dev/null || true
    exit 0
}

show_menu() {
    clear
    echo "============================================================"
    echo "       SR-IOV SWITCHDEV BARE-METAL DAC TEST"
    echo "============================================================"
    echo " PF0 : ${LEFT_PF} | VF0: ${LEFT_VF} | REP0: ${LEFT_REP}"
    echo " NS  : ${LEFT_NS} | IP : ${LEFT_IP}"
    echo " PF1 : ${RIGHT_PF} | VF0: ${RIGHT_VF} | REP0: ${RIGHT_REP}"
    echo " NS  : ${RIGHT_NS} | IP : ${RIGHT_IP}"
    echo " Bridge: ${OVS_BR} (Host Root NS)"
    echo "------------------------------------------------------------"
    if is_setup; then
        echo -e "Topology state: ${GREEN}SETUP COMPLETE${NC}"
    else
        echo -e "Topology state: ${YELLOW}NOT CONFIGURED${NC}"
    fi
    echo "------------------------------------------------------------"
    echo "  1) Setup SR-IOV Switchdev topology"
    echo "  2) Reset VF topology"
    echo "  3) Show PF/VF information"
    echo "  4) Ping VF -> VF"
    echo "  5) VF-to-VF throughput"
    echo "  6) Hardware / switchdev diagnostics"
    echo "  7) Reset host and quit"
    echo "  8) Quit"
    echo "============================================================"
}

main() {
    require_root
    check_dependencies
    force_switchdev "${LEFT_PF}"
    force_switchdev "${RIGHT_PF}"

    while true; do
        show_menu
        read -r -p "Select option [1-8]: " choice
        case "${choice}" in
            1) create_topology; pause_screen ;;
            2) reset_topology; pause_screen ;;
            3) show_vf_info; pause_screen ;;
            4) perform_ping_test; pause_screen ;;
            5) perform_throughput_test; pause_screen ;;
            6) show_hardware_diagnostics; pause_screen ;;
            7) reset_host_and_quit ;;
            8) exit 0 ;;
            *) log_error "Invalid choice"; pause_screen ;;
        esac
    done
}

main "$@"

#!/usr/bin/env bash

# ============================================================
# SR-IOV VF-TO-VF BARE-METAL / DAC THROUGHPUT TEST
#
#                 NVIDIA GB10
#
#       PF0                         PF1
#  enp1s0f0np0                  enP2p1s0f1np1
#       |                            |
#       | VF 0                       | VF 0
#       v                            v
#  enp1s0f0v0                   enP2p1s0f1v0
#       |                            |
#   left-ns                       right-ns
#  10.0.0.1                      10.0.0.2
#       |                            |
#       +--------- DAC LINK ---------+
#
# The test moves the SR-IOV VFs into network namespaces.
# The PFs remain in the host/root namespace.
#
# IMPORTANT:
# A VF-to-VF flow may be switched internally by the NIC
# depending on the NIC's SR-IOV/switchdev architecture.
# Therefore, VF-to-VF throughput does not automatically prove
# that traffic traversed the external DAC.
# ============================================================

set -u
set -o pipefail

# ============================================================
# Configuration
# ============================================================

# ------------------------------------------------------------
# Physical Functions
# ------------------------------------------------------------

LEFT_PF="enp1s0f0np0"
#RIGHT_PF="enp1s0f1np1"
RIGHT_PF="enP2p1s0f1np1"

# ------------------------------------------------------------
# Virtual Functions
#
# These are the interfaces created by:
#
# echo 1 > /sys/class/net/enp1s0f0np0/device/sriov_numvfs
# echo 1 > /sys/class/net/enp1s0f1np1/device/sriov_numvfs
#
# On your system these are:
#
# enp1s0f0v0
# enp1s0f1v0
# ------------------------------------------------------------

## FIXME: VF Names are hardcoded, should be autodetected 
###LEFT_VF="enp1s0f0v0"
LEFT_VF="enp1s0f0v0"
#RIGHT_VF="enp1s0f1v0"
RIGHT_VF="enP2p1s0f1v0"

# VF indexes on the PFs
LEFT_VF_INDEX=0
RIGHT_VF_INDEX=0

# ------------------------------------------------------------
# SR-IOV behavior
# ------------------------------------------------------------

# 1 = automatically create one VF on each PF if needed
# 0 = assume the VFs already exist
AUTO_CREATE_VFS=1

# 1 = remove the VFs created by this script during reset
# 0 = leave existing VFs alone
REMOVE_SCRIPT_CREATED_VFS=1

# ------------------------------------------------------------
# Network namespaces
# ------------------------------------------------------------

LEFT_NS="left-vf-ns"
RIGHT_NS="right-vf-ns"

# ------------------------------------------------------------
# Test IP addresses
# ------------------------------------------------------------

LEFT_IP="10.0.0.1"
RIGHT_IP="10.0.0.2"
PREFIX="24"

# ------------------------------------------------------------
# MTU
# ------------------------------------------------------------

MTU_VAL=9000

# ------------------------------------------------------------
# Ping
# ------------------------------------------------------------

PING_COUNT=10
PING_TIMEOUT=1

# ------------------------------------------------------------
# iperf3
# ------------------------------------------------------------

IPERF_DURATION=10

IPERF_TCP_STREAMS=4

IPERF_UDP_BANDWIDTH="50G"
IPERF_UDP_LENGTH=8948
IPERF_UDP_STREAMS=1

# ------------------------------------------------------------
# Results
# ------------------------------------------------------------

RESULTS_DIR="./results"
SUMMARY_FILE="${RESULTS_DIR}/vf-summary.json"

# ------------------------------------------------------------
# State
# ------------------------------------------------------------

STATE_FILE="/run/sriov-vf-baremetal-topology.state"

# ------------------------------------------------------------
# Temporary files
# ------------------------------------------------------------

IPERF_SERVER_LOG="/tmp/iperf3-vf-server.log"

# ============================================================
# Colors
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# Logging
# ============================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_ok() {
    echo -e "${GREEN}[ OK ]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_debug() {
    echo -e "${CYAN}[DEBUG]${NC} $*"
}

pause_screen() {
    echo
    read -r -p "Press ENTER to continue..."
}

# ============================================================
# Root / dependencies
# ============================================================

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

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        exit 1
    fi
}

# ============================================================
# State
# ============================================================

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
    [[ -f "${STATE_FILE}" ]] &&
        grep -q '^SETUP_COMPLETE=1$' "${STATE_FILE}"
}

require_setup() {

    if ! is_setup; then
        log_error "VF topology is not configured. Run Setup first."
        return 1
    fi

    return 0
}

# ============================================================
# Interface helpers
# ============================================================

interface_exists() {
    ip link show "$1" >/dev/null 2>&1
}

namespace_exists() {
    ip netns list | awk '{print $1}' | grep -qx "$1"
}

interface_exists_in_ns() {

    local ns="$1"
    local dev="$2"

    ip netns exec "${ns}" \
        ip link show "${dev}" >/dev/null 2>&1
}

get_vf_count() {

    local pf="$1"

    cat "/sys/class/net/${pf}/device/sriov_numvfs" 2>/dev/null || echo 0
}

get_total_vfs() {

    local pf="$1"

    cat "/sys/class/net/${pf}/device/sriov_totalvfs" \
        2>/dev/null || echo 0
}

# ============================================================
# PF/VF information
# ============================================================

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

        local numvfs
        local totalvfs

        numvfs="$(get_vf_count "${pf}")"
        totalvfs="$(get_total_vfs "${pf}")"

        echo
        echo "PF: ${pf}"
        echo "  sriov_totalvfs : ${totalvfs}"
        echo "  sriov_numvfs   : ${numvfs}"

        ip link show "${pf}" 2>/dev/null | sed 's/^/  /'

        echo
        echo "  VF configuration:"
        ip link show "${pf}" 2>/dev/null |
            grep -E "vf [0-9]+" |
            sed 's/^/    /' || true
    done

    echo
}

# ============================================================
# Enable VFs
# ============================================================

enable_one_vf() {

    local pf="$1"

    # make sure to set the mtu before enable vf
    ip link set ${pf} mtu 9000

    if ! interface_exists "${pf}"; then
        log_error "PF ${pf} does not exist."
        return 1
    fi

    local sriov_file="/sys/class/net/${pf}/device/sriov_numvfs"

    if [[ ! -e "${sriov_file}" ]]; then
        log_error "${pf} does not expose sriov_numvfs."
        return 1
    fi

    local current
    current="$(cat "${sriov_file}")"

    if [[ "${current}" -ge 1 ]]; then
        log_ok "${pf} already has ${current} VF(s)"
        return 0
    fi

    local total
    total="$(get_total_vfs "${pf}")"

    if [[ "${total}" -lt 1 ]]; then
        log_error "${pf} does not support SR-IOV VFs."
        return 1
    fi

    log_info "Creating one VF on ${pf}..."

    echo 1 > "${sriov_file}"

    sleep 2

    current="$(cat "${sriov_file}")"

    if [[ "${current}" -ne 1 ]]; then
        log_error "Failed to create VF on ${pf}."
        return 1
    fi

    log_ok "Created VF 0 on ${pf}"

    return 0
}

enable_vfs() {

    if [[ "${AUTO_CREATE_VFS}" -ne 1 ]]; then
        log_info "AUTO_CREATE_VFS=0; assuming VFs already exist."
        return 0
    fi

    enable_one_vf "${LEFT_PF}" || return 1
    enable_one_vf "${RIGHT_PF}" || return 1

    return 0
}

# ============================================================
# Verify VF interfaces
# ============================================================

wait_for_vf() {

    local dev="$1"
    local timeout=10

    log_info "Waiting for VF interface ${dev}..."

    while [[ "${timeout}" -gt 0 ]]; do

        if interface_exists "${dev}"; then
            log_ok "VF ${dev} detected."
            return 0
        fi

        sleep 1
        timeout=$((timeout - 1))
    done

    log_error "VF ${dev} was not detected."
    return 1
}

verify_vfs() {

    wait_for_vf "${LEFT_VF}" || return 1
    wait_for_vf "${RIGHT_VF}" || return 1

    echo
    log_info "VF device information:"
    ip -d link show "${LEFT_VF}" 2>/dev/null || true
    ip -d link show "${RIGHT_VF}" 2>/dev/null || true

    return 0
}

# ============================================================
# Optional VF MAC configuration
# ============================================================

configure_vf_macs() {

    log_info "Configuring deterministic VF MAC addresses..."

    ip link set "${LEFT_PF}" \
        vf "${LEFT_VF_INDEX}" \
        mac 02:00:00:00:00:01 2>/dev/null || {
            log_warn "Could not set MAC for ${LEFT_PF} VF ${LEFT_VF_INDEX}"
        }

    ip link set "${RIGHT_PF}" \
        vf "${RIGHT_VF_INDEX}" \
        mac 02:00:00:00:00:02 2>/dev/null || {
            log_warn "Could not set MAC for ${RIGHT_PF} VF ${RIGHT_VF_INDEX}"
        }

    log_ok "VF MAC configuration attempted."
}

# ============================================================
# VF link state
# ============================================================

enable_vf_link_state() {

    log_info "Requesting VF link state ENABLE..."

    ip link set "${LEFT_PF}" \
        vf "${LEFT_VF_INDEX}" state enable 2>/dev/null || \
        log_warn "VF link-state enable unsupported on ${LEFT_PF}"

    ip link set "${RIGHT_PF}" \
        vf "${RIGHT_VF_INDEX}" state enable 2>/dev/null || \
        log_warn "VF link-state enable unsupported on ${RIGHT_PF}"
}

# ============================================================
# Move VF back to root namespace
# ============================================================

return_vf_to_host() {

    local ns="$1"
    local dev="$2"

    if namespace_exists "${ns}" &&
       interface_exists_in_ns "${ns}" "${dev}"; then

        log_info "Returning ${dev} from ${ns} to root namespace..."

        ip netns exec "${ns}" \
            ip link set "${dev}" netns 1 2>/dev/null || true
    fi
}

# ============================================================
# Reset topology
# ============================================================

reset_topology() {

    echo
    echo "============================================================"
    echo " Resetting SR-IOV VF Topology"
    echo "============================================================"
    echo

    clear_setup_flag

    # --------------------------------------------------------
    # Stop iperf
    # --------------------------------------------------------

    pkill -x iperf3 2>/dev/null || true

    # --------------------------------------------------------
    # Return VFs from namespaces
    # --------------------------------------------------------

    return_vf_to_host "${LEFT_NS}" "${LEFT_VF}"
    return_vf_to_host "${RIGHT_NS}" "${RIGHT_VF}"

    # --------------------------------------------------------
    # Delete namespaces
    # --------------------------------------------------------

    for ns in "${LEFT_NS}" "${RIGHT_NS}"; do

        if namespace_exists "${ns}"; then
            ip netns delete "${ns}" 2>/dev/null || true
            log_ok "Deleted namespace ${ns}"
        fi

    done

    # --------------------------------------------------------
    # Clean VF configuration
    # --------------------------------------------------------

    for dev in "${LEFT_VF}" "${RIGHT_VF}"; do

        if interface_exists "${dev}"; then
            ip addr flush dev "${dev}" 2>/dev/null || true
            ip link set "${dev}" down 2>/dev/null || true
        fi

    done

    # --------------------------------------------------------
    # Remove VFs created by this script
    # --------------------------------------------------------

    if [[ "${REMOVE_SCRIPT_CREATED_VFS}" -eq 1 ]]; then

        for pf in "${LEFT_PF}" "${RIGHT_PF}"; do

            if interface_exists "${pf}"; then

                local sriov_file="/sys/class/net/${pf}/device/sriov_numvfs"

                if [[ -e "${sriov_file}" ]]; then

                    local count
                    count="$(cat "${sriov_file}")"

                    if [[ "${count}" -gt 0 ]]; then
                        log_info "Disabling ${count} VF(s) on ${pf}..."
                        echo 0 > "${sriov_file}" 2>/dev/null || \
                            log_warn "Could not disable VFs on ${pf}"
                    fi
                fi
            fi
        done

    else
        log_info "REMOVE_SCRIPT_CREATED_VFS=0; leaving VFs enabled."
    fi

    log_ok "VF topology cleared."
}

# ============================================================
# Create topology
# ============================================================

create_topology() {

    echo
    echo "============================================================"
    echo " Creating SR-IOV VF-to-VF Topology"
    echo "============================================================"
    echo

    reset_topology

    # --------------------------------------------------------
    # Check PFs
    # --------------------------------------------------------

    if ! interface_exists "${LEFT_PF}"; then
        log_error "Left PF not found: ${LEFT_PF}"
        return 1
    fi

    if ! interface_exists "${RIGHT_PF}"; then
        log_error "Right PF not found: ${RIGHT_PF}"
        return 1
    fi

    # --------------------------------------------------------
    # Enable VFs
    # --------------------------------------------------------

    enable_vfs || return 1

    verify_vfs || return 1

    # --------------------------------------------------------
    # VF configuration
    # --------------------------------------------------------

    configure_vf_macs
    enable_vf_link_state

    # --------------------------------------------------------
    # Create namespaces
    # --------------------------------------------------------

    ip netns add "${LEFT_NS}" ||
        return 1

    ip netns add "${RIGHT_NS}" ||
        return 1

    # --------------------------------------------------------
    # Move VFs into namespaces
    # --------------------------------------------------------

    log_info "Moving ${LEFT_VF} into ${LEFT_NS}..."

    ip link set "${LEFT_VF}" netns "${LEFT_NS}" ||
        return 1

    log_info "Moving ${RIGHT_VF} into ${RIGHT_NS}..."

    ip link set "${RIGHT_VF}" netns "${RIGHT_NS}" ||
        return 1

    # --------------------------------------------------------
    # Configure left VF
    # --------------------------------------------------------

    log_info "Configuring ${LEFT_VF}..."

    ip netns exec "${LEFT_NS}" \
        ip link set "${LEFT_VF}" mtu "${MTU_VAL}"

    ip netns exec "${LEFT_NS}" \
        ip addr add "${LEFT_IP}/${PREFIX}" dev "${LEFT_VF}"

    ip netns exec "${LEFT_NS}" \
        ip link set "${LEFT_VF}" up

    ip netns exec "${LEFT_NS}" \
        ip link set lo up

    # --------------------------------------------------------
    # Configure right VF
    # --------------------------------------------------------

    log_info "Configuring ${RIGHT_VF}..."

    ip netns exec "${RIGHT_NS}" \
        ip link set "${RIGHT_VF}" mtu "${MTU_VAL}"

    ip netns exec "${RIGHT_NS}" \
        ip addr add "${RIGHT_IP}/${PREFIX}" dev "${RIGHT_VF}"

    ip netns exec "${RIGHT_NS}" \
        ip link set "${RIGHT_VF}" up

    ip netns exec "${RIGHT_NS}" \
        ip link set lo up

    sleep 2

    # --------------------------------------------------------
    # Display topology
    # --------------------------------------------------------

    echo
    echo "============================================================"
    echo " VF Topology"
    echo "============================================================"
    echo
    echo " PF/VF:"
    echo "   ${LEFT_PF}"
    echo "       └── ${LEFT_VF}"
    echo
    echo "   ${RIGHT_PF}"
    echo "       └── ${RIGHT_VF}"
    echo
    echo " Network namespaces:"
    echo "   ${LEFT_NS}:  ${LEFT_VF} -> ${LEFT_IP}/${PREFIX}"
    echo "   ${RIGHT_NS}: ${RIGHT_VF} -> ${RIGHT_IP}/${PREFIX}"
    echo
    echo " MTU: ${MTU_VAL}"
    echo

    set_setup_flag

    log_ok "SR-IOV VF topology setup complete."

    return 0
}

# ============================================================
# Ping
# ============================================================

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

    ip netns exec "${source_ns}" \
        ping -c "${PING_COUNT}" \
        -W "${PING_TIMEOUT}" \
        "${destination_ip}"

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

    ping_one_way \
        "${LEFT_NS}" \
        "${RIGHT_IP}" \
        "LEFT VF -> RIGHT VF" || failed=1

    ping_one_way \
        "${RIGHT_NS}" \
        "${LEFT_IP}" \
        "RIGHT VF -> LEFT VF" || failed=1

    if [[ "${failed}" -eq 0 ]]; then
        log_ok "BIDIRECTIONAL VF PING TEST PASSED"
    else
        log_error "BIDIRECTIONAL VF PING TEST FAILED"
    fi
}

# ============================================================
# RTT
# ============================================================

get_ping_rtt_ms() {

    local ns="$1"
    local destination="$2"

    ip netns exec "${ns}" \
        ping -c 5 -W 1 "${destination}" 2>/dev/null |
        awk -F'/' '/^rtt|^round-trip/ {
            print $5;
            exit
        }'
}

# ============================================================
# iperf server
# ============================================================

start_iperf_server() {

    log_info "Starting iperf3 server in ${RIGHT_NS}"

    ip netns exec "${RIGHT_NS}" \
        iperf3 -s > "${IPERF_SERVER_LOG}" 2>&1 &

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
        ip netns exec "${RIGHT_NS}" \
            pkill -x iperf3 2>/dev/null || true
    fi
}

# ============================================================
# CPU
# ============================================================

read_cpu_stat() {

    awk '
    /^cpu / {
        total=$2+$3+$4+$5+$6+$7+$8+$9
        idle=$5+$6
        print total, idle
        exit
    }' /proc/stat
}

get_cpu_busy_percent() {

    local start_total="$1"
    local start_idle="$2"
    local end_total="$3"
    local end_idle="$4"

    local total_delta=$((end_total - start_total))
    local idle_delta=$((end_idle - start_idle))

    if [[ "${total_delta}" -le 0 ]]; then
        echo "0.00"
        return
    fi

    awk \
        -v total="${total_delta}" \
        -v idle="${idle_delta}" \
        'BEGIN {
            printf "%.2f", ((total-idle)/total)*100
        }'
}

# ============================================================
# Interface statistics
# ============================================================

collect_vf_stats() {

    local ns="$1"
    local dev="$2"
    local output="$3"

    {
        echo "============================================================"
        echo " VF statistics: ${dev}"
        echo " Namespace: ${ns}"
        echo "============================================================"

        ip netns exec "${ns}" \
            ip -s link show "${dev}"

        echo
        echo "ethtool statistics:"

        if ip netns exec "${ns}" \
            ethtool -S "${dev}" >/tmp/vf-ethtool-stat.tmp 2>/dev/null; then

            cat /tmp/vf-ethtool-stat.tmp

        else

            echo "ethtool -S not supported or unavailable"

        fi

    } > "${output}"

    rm -f /tmp/vf-ethtool-stat.tmp
}

# ============================================================
# Throughput
# ============================================================

perform_throughput_test() {

    require_setup || return 1

    echo
    echo "============================================================"
    echo " SR-IOV VF-to-VF Throughput Test"
    echo "============================================================"
    echo

    echo "Path:"
    echo
    echo " ${LEFT_NS}"
    echo "    ${LEFT_VF} (${LEFT_IP})"
    echo "         |"
    echo "         |"
    echo "       PF/VF"
    echo "         |"
    echo "      ${LEFT_PF}"
    echo "         |"
    echo "       DAC / NIC"
    echo "         |"
    echo "      ${RIGHT_PF}"
    echo "         |"
    echo "       PF/VF"
    echo "         |"
    echo " ${RIGHT_VF} (${RIGHT_IP})"
    echo " ${RIGHT_NS}"
    echo

    mkdir -p "${RESULTS_DIR}"

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    local timestamp_file
    timestamp_file="$(date '+%Y%m%d-%H%M%S')"

    local test_dir
    test_dir="${RESULTS_DIR}/sriov-vf-${timestamp_file}"

    mkdir -p "${test_dir}"

    local tcp_json="${test_dir}/tcp.json"
    local udp_json="${test_dir}/udp.json"

    local vf_left_stats="${test_dir}/left-vf-stats.txt"
    local vf_right_stats="${test_dir}/right-vf-stats.txt"

    # --------------------------------------------------------
    # Initial stats
    # --------------------------------------------------------

    collect_vf_stats \
        "${LEFT_NS}" \
        "${LEFT_VF}" \
        "${vf_left_stats}.before"

    collect_vf_stats \
        "${RIGHT_NS}" \
        "${RIGHT_VF}" \
        "${vf_right_stats}.before"

    # --------------------------------------------------------
    # Connectivity
    # --------------------------------------------------------

    log_info "Checking VF-to-VF connectivity..."

    if ! ip netns exec "${LEFT_NS}" \
        ping -c 3 -W 1 "${RIGHT_IP}" >/dev/null 2>&1; then

        log_error "VF connectivity test failed."

        return 1
    fi

    log_ok "VF connectivity test passed"

    # --------------------------------------------------------
    # RTT
    # --------------------------------------------------------

    log_info "Measuring VF-to-VF ICMP RTT..."

    local rtt_ms

    rtt_ms="$(
        get_ping_rtt_ms \
            "${LEFT_NS}" \
            "${RIGHT_IP}"
    )"

    if [[ -z "${rtt_ms}" ]]; then

        rtt_ms="0"

        log_warn "Could not determine RTT"

    else

        log_ok "VF-to-VF ICMP RTT: ${rtt_ms} ms"

    fi

    # --------------------------------------------------------
    # Start server
    # --------------------------------------------------------

    start_iperf_server || return 1

    trap stop_iperf_server RETURN

    # ========================================================
    # TCP
    # ========================================================

    echo
    echo "------------------------------------------------------------"
    echo " VF -> VF TCP throughput"
    echo "------------------------------------------------------------"
    echo "Source VF      : ${LEFT_VF}"
    echo "Destination VF : ${RIGHT_VF}"
    echo "Duration       : ${IPERF_DURATION}s"
    echo "TCP streams    : ${IPERF_TCP_STREAMS}"
    echo

    read -r tcp_start_total tcp_start_idle <<< "$(read_cpu_stat)"

    ip netns exec "${LEFT_NS}" \
        iperf3 \
        -c "${RIGHT_IP}" \
        -t "${IPERF_DURATION}" \
        -P "${IPERF_TCP_STREAMS}" \
        -J > "${tcp_json}"

    local tcp_result=$?

    read -r tcp_end_total tcp_end_idle <<< "$(read_cpu_stat)"

    if [[ "${tcp_result}" -ne 0 ]]; then

        log_error "TCP iperf3 test failed"

        cat "${tcp_json}"

        return 1
    fi

    local tcp_bps

    tcp_bps="$(
        jq -r '
            .end.sum_received.bits_per_second //
            .end.sum_sent.bits_per_second //
            0
        ' "${tcp_json}"
    )"

    local tcp_gbps

    tcp_gbps="$(
        awk -v bps="${tcp_bps}" \
            'BEGIN {
                printf "%.2f", bps/1000000000
            }'
    )"

    local tcp_cpu_busy

    tcp_cpu_busy="$(
        get_cpu_busy_percent \
            "${tcp_start_total}" \
            "${tcp_start_idle}" \
            "${tcp_end_total}" \
            "${tcp_end_idle}"
    )"

    log_ok "VF TCP throughput: ${tcp_gbps} Gbps"
    log_info "Host CPU busy: ${tcp_cpu_busy}%"

    # ========================================================
    # UDP
    # ========================================================

    echo
    echo "------------------------------------------------------------"
    echo " VF -> VF UDP throughput"
    echo "------------------------------------------------------------"
    echo "Source VF      : ${LEFT_VF}"
    echo "Destination VF : ${RIGHT_VF}"
    echo "Duration       : ${IPERF_DURATION}s"
    echo "Bandwidth      : ${IPERF_UDP_BANDWIDTH}"
    echo "Packet length  : ${IPERF_UDP_LENGTH}"
    echo "UDP streams    : ${IPERF_UDP_STREAMS}"
    echo

    read -r udp_start_total udp_start_idle <<< "$(read_cpu_stat)"

    ip netns exec "${LEFT_NS}" \
        iperf3 \
        -c "${RIGHT_IP}" \
        -u \
        -t "${IPERF_DURATION}" \
        -l "${IPERF_UDP_LENGTH}" \
        -P "${IPERF_UDP_STREAMS}" \
        -b "${IPERF_UDP_BANDWIDTH}" \
        -J > "${udp_json}"

    local udp_result=$?

    read -r udp_end_total udp_end_idle <<< "$(read_cpu_stat)"

    if [[ "${udp_result}" -ne 0 ]]; then

        log_error "UDP iperf3 test failed"

        cat "${udp_json}"

        return 1
    fi

    local udp_bps

    udp_bps="$(
        jq -r '
            .end.sum_received.bits_per_second //
            .end.sum.bits_per_second //
            0
        ' "${udp_json}"
    )"

    local udp_jitter

    udp_jitter="$(
        jq -r '
            .end.sum_received.jitter_ms //
            .end.sum.jitter_ms //
            .end.sum_sent.jitter_ms //
            0
        ' "${udp_json}"
    )"

    local udp_packets

    udp_packets="$(
        jq -r '
            .end.sum_received.packets //
            0
        ' "${udp_json}"
    )"

    local udp_seconds

    udp_seconds="$(
        jq -r '
            .end.sum_received.seconds //
            .end.sum.seconds //
            0
        ' "${udp_json}"
    )"

    local udp_loss

    udp_loss="$(
        jq -r '
            .end.sum_received.lost_percent //
            .end.sum.lost_percent //
            0
        ' "${udp_json}"
    )"

    local udp_gbps

    udp_gbps="$(
        awk -v bps="${udp_bps}" \
            'BEGIN {
                printf "%.2f", bps/1000000000
            }'
    )"

    local udp_pps

    udp_pps="$(
        awk \
            -v packets="${udp_packets}" \
            -v seconds="${udp_seconds}" \
            'BEGIN {
                if (seconds > 0)
                    printf "%.0f", packets/seconds
                else
                    printf "0"
            }'
    )"

    udp_loss="$(
        awk -v loss="${udp_loss}" \
            'BEGIN {
                printf "%.3f", loss
            }'
    )"

    udp_jitter="$(
        awk -v jitter="${udp_jitter}" \
            'BEGIN {
                printf "%.6f", jitter
            }'
    )"

    local udp_cpu_busy

    udp_cpu_busy="$(
        get_cpu_busy_percent \
            "${udp_start_total}" \
            "${udp_start_idle}" \
            "${udp_end_total}" \
            "${udp_end_idle}"
    )"

    log_ok "VF UDP throughput: ${udp_gbps} Gbps"
    log_ok "VF UDP PPS: ${udp_pps}"
    log_ok "VF UDP loss: ${udp_loss}%"
    log_info "VF UDP jitter: ${udp_jitter} ms"
    log_info "Host CPU busy: ${udp_cpu_busy}%"

    # --------------------------------------------------------
    # Final statistics
    # --------------------------------------------------------

    collect_vf_stats \
        "${LEFT_NS}" \
        "${LEFT_VF}" \
        "${vf_left_stats}.after"

    collect_vf_stats \
        "${RIGHT_NS}" \
        "${RIGHT_VF}" \
        "${vf_right_stats}.after"

    # --------------------------------------------------------
    # Save interface information
    # --------------------------------------------------------

    {
        echo "LEFT PF"
        ip -d link show "${LEFT_PF}"

        echo
        echo "RIGHT PF"
        ip -d link show "${RIGHT_PF}"

        echo
        echo "LEFT VF"
        ip netns exec "${LEFT_NS}" \
            ip -d link show "${LEFT_VF}"

        echo
        echo "RIGHT VF"
        ip netns exec "${RIGHT_NS}" \
            ip -d link show "${RIGHT_VF}"

    } > "${test_dir}/interfaces.txt" 2>&1

    # --------------------------------------------------------
    # Save PCI relationship
    # --------------------------------------------------------

    {
        echo "============================================================"
        echo " SR-IOV PCI Information"
        echo "============================================================"

        echo
        echo "LEFT PF: ${LEFT_PF}"
        readlink -f \
            "/sys/class/net/${LEFT_PF}/device" || true

        echo
        echo "RIGHT PF: ${RIGHT_PF}"
        readlink -f \
            "/sys/class/net/${RIGHT_PF}/device" || true

        echo
        echo "LEFT VF: ${LEFT_VF}"
        ip netns exec "${LEFT_NS}" \
            readlink -f \
            "/sys/class/net/${LEFT_VF}/device" || true

        echo
        echo "RIGHT VF: ${RIGHT_VF}"
        ip netns exec "${RIGHT_NS}" \
            readlink -f \
            "/sys/class/net/${RIGHT_VF}/device" || true

    } > "${test_dir}/pci-info.txt" 2>&1

    # ========================================================
    # Summary JSON
    # ========================================================

    cat > "${SUMMARY_FILE}" <<EOF
{
  "test_type": "sriov_vf_to_vf_baremetal",
  "timestamp": "${timestamp}",

  "left_pf": "${LEFT_PF}",
  "right_pf": "${RIGHT_PF}",

  "left_vf": "${LEFT_VF}",
  "right_vf": "${RIGHT_VF}",

  "left_vf_index": ${LEFT_VF_INDEX},
  "right_vf_index": ${RIGHT_VF_INDEX},

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

  "tcp_parallel_streams": ${IPERF_TCP_STREAMS},
  "udp_packet_length": ${IPERF_UDP_LENGTH},
  "udp_streams": ${IPERF_UDP_STREAMS},
  "iperf3_duration_sec": ${IPERF_DURATION},

  "raw_tcp_result": "${tcp_json}",
  "raw_udp_result": "${udp_json}",

  "vf_left_stats_before": "${vf_left_stats}.before",
  "vf_left_stats_after": "${vf_left_stats}.after",

  "vf_right_stats_before": "${vf_right_stats}.before",
  "vf_right_stats_after": "${vf_right_stats}.after",

  "note": "VF-to-VF traffic may be internally switched by the NIC depending on hardware/driver configuration; this test alone does not prove external DAC traversal."
}
EOF

    # --------------------------------------------------------
    # Display
    # --------------------------------------------------------

    echo
    echo "============================================================"
    echo " VF-to-VF Throughput Test Results"
    echo "============================================================"
    echo

    printf " PF/VF path      : %s/%s -> %s/%s\n" \
        "${LEFT_PF}" \
        "${LEFT_VF}" \
        "${RIGHT_PF}" \
        "${RIGHT_VF}"

    printf " TCP throughput  : %s Gbps\n" "${tcp_gbps}"
    printf " UDP throughput  : %s Gbps\n" "${udp_gbps}"
    printf " UDP PPS         : %s\n" "${udp_pps}"
    printf " UDP loss        : %s %%\n" "${udp_loss}"
    printf " UDP jitter      : %s ms\n" "${udp_jitter}"
    printf " ICMP RTT        : %s ms\n" "${rtt_ms}"
    printf " TCP CPU busy    : %s %%\n" "${tcp_cpu_busy}"
    printf " UDP CPU busy    : %s %%\n" "${udp_cpu_busy}"

    echo
    echo "Results directory:"
    echo "  ${test_dir}"

    echo
    echo "Summary:"
    echo "  ${SUMMARY_FILE}"

    echo
    echo "============================================================"

    log_ok "SR-IOV VF-to-VF throughput test completed."

    return 0
}

# ============================================================
# VF hardware / switchdev diagnostics
# ============================================================

show_hardware_diagnostics() {

    echo
    echo "============================================================"
    echo " VF / Switchdev Diagnostics"
    echo "============================================================"

    echo
    echo "PF information:"
    ip -d link show "${LEFT_PF}" 2>/dev/null || true
    ip -d link show "${RIGHT_PF}" 2>/dev/null || true

    echo
    echo "VF information:"

    if interface_exists "${LEFT_VF}"; then
        ip -d link show "${LEFT_VF}"
    fi

    if interface_exists "${RIGHT_VF}"; then
        ip -d link show "${RIGHT_VF}"
    fi

    echo
    echo "devlink devices:"

    if command -v devlink >/dev/null 2>&1; then
        devlink dev show 2>/dev/null || true

        echo
        echo "devlink ports:"
        devlink port show 2>/dev/null || true
    else
        echo "devlink command not installed."
    fi

    echo
    echo "switchdev / bridge information:"

    if command -v bridge >/dev/null 2>&1; then
        bridge link show 2>/dev/null || true
    fi

    echo
    echo "============================================================"
}

# ============================================================
# Reset host and quit
# ============================================================

reset_host_and_quit() {

    reset_topology

    if command -v nmcli >/dev/null 2>&1; then

        nmcli device set "${LEFT_PF}" managed yes 2>/dev/null || true
        nmcli device set "${RIGHT_PF}" managed yes 2>/dev/null || true

    fi

    if interface_exists "${LEFT_PF}"; then
        ip link set "${LEFT_PF}" mtu 1500 2>/dev/null || true
    fi

    if interface_exists "${RIGHT_PF}"; then
        ip link set "${RIGHT_PF}" mtu 1500 2>/dev/null || true
    fi

    exit 0
}

# ============================================================
# Menu
# ============================================================

show_menu() {

    clear

    echo "============================================================"
    echo "       SR-IOV VF-TO-VF BARE-METAL DAC TEST"
    echo "============================================================"

    echo
    echo " PF0 : ${LEFT_PF}"
    echo " VF0 : ${LEFT_VF}"
    echo " NS  : ${LEFT_NS}"
    echo " IP  : ${LEFT_IP}"

    echo
    echo " PF1 : ${RIGHT_PF}"
    echo " VF0 : ${RIGHT_VF}"
    echo " NS  : ${RIGHT_NS}"
    echo " IP  : ${RIGHT_IP}"

    echo
    echo "------------------------------------------------------------"

    if is_setup; then
        echo -e "Topology state: ${GREEN}SETUP COMPLETE${NC}"
    else
        echo -e "Topology state: ${YELLOW}NOT CONFIGURED${NC}"
    fi

    echo "------------------------------------------------------------"

    echo "  1) Setup SR-IOV VF topology"
    echo "  2) Reset VF topology"
    echo "  3) Show PF/VF information"
    echo "  4) Ping VF -> VF"
    echo "  5) VF-to-VF throughput"
    echo "  6) Hardware / switchdev diagnostics"
    echo "  7) Reset host and quit"
    echo "  8) Quit"

    echo "============================================================"
}

# ============================================================
# Main
# ============================================================

main() {

    require_root
    check_dependencies

    while true; do

        show_menu

        read -r -p "Select option [1-8]: " choice

        case "${choice}" in

            1)
                create_topology
                pause_screen
                ;;

            2)
                reset_topology
                pause_screen
                ;;

            3)
                show_vf_info
                pause_screen
                ;;

            4)
                perform_ping_test
                pause_screen
                ;;

            5)
                perform_throughput_test
                pause_screen
                ;;

            6)
                show_hardware_diagnostics
                pause_screen
                ;;

            7)
                reset_host_and_quit
                ;;

            8)
                exit 0
                ;;

            *)
                log_error "Invalid choice"
                pause_screen
                ;;

        esac

    done
}

main "$@"

#!/usr/bin/env bash
# t2_host_setup.sh — Host Setup for vDPA Hardware Acceleration in Switchdev Mode
# Supports steering via TC Flower (--mode tc) or Open vSwitch (--mode ovs)
#
# Configuration is loaded from:
#
#     t2_config.sh
#
# MTU handling:
#
#     Guest / VF       -> MTU
#     PF / Uplink      -> PF_MTU
#     VF Representor   -> REP_MTU
#
# Example regular configuration:
#
#     MTU       = 1500
#     PF_MTU    = 1600
#     REP_MTU   = 1600
#
# Example jumbo configuration:
#
#     MTU       = 9000
#     PF_MTU    = 9014
#     REP_MTU   = 9014
#

set -euo pipefail


###############################################################################
# Load Common Configuration
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_FILE="${SCRIPT_DIR}/t2_config.sh"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found:"
    echo "       ${CONFIG_FILE}"
    exit 1
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"


###############################################################################
# Command Line Arguments
###############################################################################

MODE="tc"

usage() {
    echo "Usage: $0 [--mode tc|ovs]"
    echo "  --mode tc   : Configure vDPA in switchdev mode using TC Flower hardware steering (Default)"
    echo "  --mode ovs  : Configure vDPA in switchdev mode using Open vSwitch bridging"
    exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

if [[ "${MODE}" != "tc" && "${MODE}" != "ovs" ]]; then
    echo "ERROR: Invalid mode '${MODE}'. Must be 'tc' or 'ovs'."
    usage
fi


###############################################################################
# Configuration Summary
###############################################################################

echo "=========================================================="
echo " Host Setup: vDPA Hardware Acceleration [Mode: ${MODE^^}]"
echo "=========================================================="
echo
echo " MTU Profile        : ${MTU_PROFILE}"
echo " Guest / VF MTU     : ${MTU}"
echo " PF / Uplink MTU    : ${PF_MTU}"
echo " VF Representor MTU : ${REP_MTU}"
echo
echo "=========================================================="


###############################################################################
# 1. Load Kernel Modules
###############################################################################

echo "[1/6] Loading required kernel modules..."

sudo modprobe vhost_vdpa 2>/dev/null || true
sudo modprobe vdpa 2>/dev/null || true
sudo modprobe mlx5_vdpa 2>/dev/null || true


###############################################################################
# Open vSwitch
###############################################################################

if [[ "${MODE}" == "ovs" ]]; then
    if ! command -v ovs-vsctl &>/dev/null; then
        echo "ERROR: 'ovs-vsctl' not found. Please install Open vSwitch before running in --mode ovs."
        exit 1
    fi

    sudo systemctl start openvswitch 2>/dev/null || true
fi


###############################################################################
# Helper function to discover VF representors dynamically
###############################################################################

get_vf_representor() {
    local PF="$1"
    local PF_BDF="$2"
    local REP=""

    for dev in /sys/class/net/*; do
        dev_name=$(basename "$dev")

        if [[ -e "$dev/device" ]]; then
            dev_bdf=$(basename "$(readlink -f "$dev/device")" 2>/dev/null || true)

            if [[ "$dev_bdf" == "$PF_BDF" && "$dev_name" != "$PF" ]]; then
                REP="$dev_name"
                break
            fi
        fi
    done

    if [[ -z "$REP" ]]; then
        REP=$(
            ip -o link show |
            grep -E "${PF}r0|${PF}v0|pf0vf0" |
            awk -F': ' '{print $2}' |
            head -n1 || true
        )
    fi

    echo "$REP"
}


###############################################################################
# Helper function to clean prior rules/bridges on a port
###############################################################################

cleanup_port_steering() {
    local PF="$1"
    local REP="$2"
    local DEV_IDX="$3"

    # Remove TC qdiscs
    sudo tc qdisc del dev "${PF}" ingress 2>/dev/null || true

    if [[ -n "${REP}" ]]; then
        sudo tc qdisc del dev "${REP}" ingress 2>/dev/null || true
    fi

    # Delete OVS bridge if it exists
    local BR_NAME="br-vdpa${DEV_IDX}"

    if command -v ovs-vsctl &>/dev/null &&
       sudo ovs-vsctl br-exists "${BR_NAME}" 2>/dev/null; then

        echo "  Cleaning up existing OVS bridge ${BR_NAME}..."
        sudo ovs-vsctl del-br "${BR_NAME}"
    fi
}


###############################################################################
# MTU Helper
###############################################################################

configure_mtu() {
    local PF="$1"
    local REP="$2"

    echo "  Configuring MTU..."

    #
    # PF/uplink:
    #
    # The PF gets the host-side MTU, not the guest MTU.
    #
    echo "    PF ${PF} MTU: ${PF_MTU}"
    sudo ip link set "${PF}" mtu "${PF_MTU}"


    #
    # VF Representor:
    #
    # The representor exists after the VF/eSwitch Switchdev setup.
    #
    if [[ -n "${REP}" ]]; then
        echo "    REP ${REP} MTU: ${REP_MTU}"
        sudo ip link set "${REP}" mtu "${REP_MTU}"
    fi
}


###############################################################################
# vDPA Port Setup
###############################################################################

setup_vdpa_port() {
    local PF="$1"
    local MAC="$2"
    local DEV_IDX="$3"

    echo "----------------------------------------------------"
    echo "Configuring Interface: ${PF} (Index: ${DEV_IDX})"

    if ! ip link show "${PF}" &>/dev/null; then
        echo "ERROR: Physical interface ${PF} not found!"
        exit 1
    fi


    ###########################################################################
    # Obtain PF PCI BDF
    ###########################################################################

    local PF_BDF

    PF_BDF=$(
        basename "$(readlink -f "/sys/class/net/${PF}/device")"
    )

    echo "  PF PCI BDF: ${PF_BDF}"


    ###########################################################################
    # Reset VFs
    ###########################################################################

    echo "  Resetting VFs on ${PF}..."

    echo 0 |
        sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null


    ###########################################################################
    # Force Switchdev mode
    ###########################################################################

    echo "  Setting eSwitch mode to switchdev..."

    sudo devlink dev eswitch set "pci/${PF_BDF}" mode switchdev


    ###########################################################################
    # Instantiate VF 0
    ###########################################################################

    echo "  Creating Virtual Function (VF 0)..."

    echo 1 |
        sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null

    sleep 1


    ###########################################################################
    # Obtain VF PCI BDF
    ###########################################################################

    local VF_BDF

    VF_BDF=$(
        basename "$(readlink -f "/sys/class/net/${PF}/device/virtfn0")"
    )

    echo "  Allocated VF 0 PCI BDF: ${VF_BDF}"


    ###########################################################################
    # Bring up PF
    ###########################################################################
    #
    # IMPORTANT:
    #
    # PF uses PF_MTU, not the guest MTU.
    #
    ###########################################################################

    echo "  Configuring PF ${PF}: MTU ${PF_MTU}"

    sudo ip link set "${PF}" mtu "${PF_MTU}" up promisc on


    ###########################################################################
    # Locate VF Representor
    ###########################################################################

    local REP

    REP=$(get_vf_representor "${PF}" "${PF_BDF}")

    if [[ -z "${REP}" ]]; then
        echo "ERROR: Unable to locate VF representor interface for ${PF}!"
        exit 1
    fi

    echo "  Detected VF Representor: ${REP}"


    ###########################################################################
    # Configure VF Representor
    ###########################################################################
    #
    # IMPORTANT:
    #
    # The VF Representor uses REP_MTU, not MTU.
    #
    ###########################################################################

    echo "  Configuring VF Representor ${REP}: MTU ${REP_MTU}"

    sudo ip link set "${REP}" mtu "${REP_MTU}" up


    ###########################################################################
    # Clean Existing Steering Configurations
    ###########################################################################

    cleanup_port_steering "${PF}" "${REP}" "${DEV_IDX}"


    ###########################################################################
    # Apply Steering Mechanism
    ###########################################################################

    if [[ "${MODE}" == "tc" ]]; then

        echo "  [TC Flower] Applying ingress qdiscs and hardware redirection rules..."

        sudo tc qdisc add dev "${PF}" ingress
        sudo tc qdisc add dev "${REP}" ingress

        sudo tc filter add \
            dev "${PF}" \
            ingress \
            protocol all \
            prio 1 \
            flower \
            action mirred egress redirect dev "${REP}"

        sudo tc filter add \
            dev "${REP}" \
            ingress \
            protocol all \
            prio 1 \
            flower \
            action mirred egress redirect dev "${PF}"


    elif [[ "${MODE}" == "ovs" ]]; then

        local BR_NAME="br-vdpa${DEV_IDX}"

        echo "  [OVS] Creating bridge '${BR_NAME}' and adding ports '${PF}' & '${REP}'..."

        sudo ovs-vsctl add-br "${BR_NAME}"

        sudo ovs-vsctl add-port "${BR_NAME}" "${PF}"
        sudo ovs-vsctl add-port "${BR_NAME}" "${REP}"


        #######################################################################
        # OVS Bridge MTU
        #######################################################################
        #
        # The bridge is host-side infrastructure, therefore use PF_MTU.
        #
        #######################################################################

        sudo ip link set "${BR_NAME}" mtu "${PF_MTU}" up
    fi


    ###########################################################################
    # Re-create vDPA instance with MAC specification
    ###########################################################################

    if sudo vdpa dev show "vdpa${DEV_IDX}" &>/dev/null; then

        echo "  Removing existing vDPA instance 'vdpa${DEV_IDX}'..."

        sudo vdpa dev del \
            "vdpa${DEV_IDX}" \
            2>/dev/null || true
    fi


    ###########################################################################
    # Instantiate vDPA Device
    ###########################################################################

    echo "  Instantiating vDPA device 'vdpa${DEV_IDX}'..."

    sudo vdpa dev add \
        name "vdpa${DEV_IDX}" \
        mgmtdev "pci/${VF_BDF}" \
        mac "${MAC}" \
	mtu "${MTU}"


    ###########################################################################
    # Save vDPA Character Device
    ###########################################################################

    local CHAR_DEV="/dev/vhost-vdpa-${DEV_IDX}"

    echo "  Bound Character Device: ${CHAR_DEV}"

    echo "${CHAR_DEV}" > "/tmp/t2_vdpa_node_${PF}.txt"
}


###############################################################################
# 2. Provision Ports
###############################################################################

echo "[2/6] Provisioning PF0 (${PF0})..."

setup_vdpa_port \
    "${PF0}" \
    "${VM1_TEST_MAC}" \
    0


echo "[3/6] Provisioning PF1 (${PF1})..."

setup_vdpa_port \
    "${PF1}" \
    "${VM2_TEST_MAC}" \
    1


###############################################################################
# 3. Reserve Hugepages
###############################################################################

echo "[4/6] Allocating Hugepages (${TOTAL_HUGEPAGES} pages)..."

sudo sysctl -w vm.nr_hugepages="${TOTAL_HUGEPAGES}" >/dev/null

mountpoint -q /dev/hugepages ||
    sudo mount -t hugetlbfs hugetlbfs /dev/hugepages


###############################################################################
# 4. Summary & State Output
###############################################################################

echo "[5/6] Verification Summary..."

VDPA0_NODE=$(cat "/tmp/t2_vdpa_node_${PF0}.txt")
VDPA1_NODE=$(cat "/tmp/t2_vdpa_node_${PF1}.txt")


echo "  VM1 vDPA Node (${PF0}) : ${VDPA0_NODE}"
echo "  VM2 vDPA Node (${PF1}) : ${VDPA1_NODE}"

echo
echo "  MTU Configuration:"
echo "    Profile             : ${MTU_PROFILE}"
echo "    Guest / VF MTU      : ${MTU}"
echo "    PF / Uplink MTU     : ${PF_MTU}"
echo "    VF Representor MTU  : ${REP_MTU}"


###############################################################################
# Preserve Existing Mode State
###############################################################################

echo "${MODE}" > /tmp/t2_current_mode.txt


###############################################################################
# Completion
###############################################################################

echo "=========================================================="
echo " Host Setup Complete! (Mode: vDPA / ${MODE^^}, MTU: ${MTU})"
echo "=========================================================="

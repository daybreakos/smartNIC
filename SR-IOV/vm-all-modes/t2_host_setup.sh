#!/usr/bin/env bash
# t2_host_setup.sh — Unified Host Setup for SR-IOV Legacy, OVS HW-Offload, and TC Flower Modes

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

MODE="legacy"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--mode legacy|ovs|tc]"
      exit 1
      ;;
  esac
done

if [[ "$MODE" != "legacy" && "$MODE" != "ovs" && "$MODE" != "tc" ]]; then
    echo "ERROR: Invalid mode '${MODE}'. Select 'legacy', 'ovs', or 'tc'."
    exit 1
fi

echo "=========================================================="
echo " Host Setup: SR-IOV eSwitch [Selected Mode: ${MODE^^}] (MTU ${MTU})"
echo "=========================================================="

# 1. Load kernel modules (handling built-in modules on ARM64)
echo "[1/7] Initializing kernel drivers and VFIO subsystem..."
sudo modprobe vfio 2>/dev/null || true
sudo modprobe vfio-pci 2>/dev/null || true
sudo modprobe vfio_iommu_type1 2>/dev/null || true

# 2. Open vSwitch Service Management
if [[ "${MODE}" == "ovs" ]]; then
    echo "[2/7] Starting Open vSwitch with Hardware Offload enabled..."
    sudo systemctl start openvswitch-switch 2>/dev/null || sudo systemctl start ovs-vswitchd 2>/dev/null || true
    sudo ovs-vsctl set Open_vSwitch . other_config:hw-offload=true
    sudo systemctl restart openvswitch-switch 2>/dev/null || sudo systemctl restart ovs-vswitchd 2>/dev/null || true
else
    echo "[2/7] Stopping Open vSwitch daemon (Not required for ${MODE^^} mode)..."
    sudo systemctl stop openvswitch-switch 2>/dev/null || sudo systemctl stop ovs-vswitchd 2>/dev/null || true
fi

# Helper function to discover VF representor in switchdev mode
get_vf_representor() {
    local PF="$1"
    local PF_BDF="$2"
    local REP=""

    for dev in /sys/class/net/*; do
        dev_name=$(basename "$dev")
        if [[ -e "$dev/device" ]]; then
            dev_bdf=$(basename "$(readlink -f "$dev/device")" 2>/dev/null || true)
            if [[ "$dev_bdf" == "$PF_BDF" && "$dev_name" != "$PF" ]]; then
                if [[ -e "$dev/phys_port_name" ]]; then
                    port_name=$(cat "$dev/phys_port_name" 2>/dev/null || true)
                    if [[ "$port_name" =~ pf[0-9]+vf0|v0|0 ]]; then
                        REP="$dev_name"
                        break
                    fi
                fi
            fi
        fi
    done

    if [[ -z "$REP" ]]; then
        REP=$(ip -o link show | grep -E "${PF}v0|${PF}_0|pf0vf0" | awk -F': ' '{print $2}' | head -n1 || true)
    fi
    echo "$REP"
}

# 3. Provision PF and Virtual Function
setup_sriov_port() {
    local PF="$1"
    local MAC="$2"

    echo "----------------------------------------------------"
    echo "Configuring Physical Interface: ${PF} (MTU ${MTU})"

    if ! ip link show "${PF}" &>/dev/null; then
        echo "ERROR: Physical interface ${PF} not found!"
        exit 1
    fi

    # Set PF MTU & Link Up
    sudo ip link set "${PF}" mtu "${MTU}" up
    sudo ip link set "${PF}" promisc on 2>/dev/null || true

    local PF_BDF
    PF_BDF=$(basename "$(readlink -f "/sys/class/net/${PF}/device")")
    echo "  PF PCI BDF: ${PF_BDF}"

    # Reset VFs
    echo 0 | sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null

    if [[ "${MODE}" == "legacy" ]]; then
        echo "  Setting eSwitch mode to legacy..."
        sudo devlink dev eswitch set "pci/${PF_BDF}" mode legacy 2>/dev/null || true
    else
        echo "  Setting eSwitch mode to switchdev..."
        sudo devlink dev eswitch set "pci/${PF_BDF}" mode switchdev
    fi

    # Instantiate VF
    echo "  Creating Virtual Function (VF 0)..."
    echo 1 | sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null
    sleep 1.5

    # Set VF MAC and security policy
    sudo ip link set "${PF}" vf 0 mac "${MAC}" trust on spoofchk off 2>/dev/null || true

    local VF_BDF
    VF_BDF=$(basename "$(readlink -f "/sys/class/net/${PF}/device/virtfn0")")
    echo "  Allocated VF 0 PCI BDF: ${VF_BDF}"

    # Handle Representors for switchdev mode
    if [[ "${MODE}" != "legacy" ]]; then
        local REP
        REP=$(get_vf_representor "${PF}" "${PF_BDF}")
        if [[ -z "${REP}" ]]; then
            echo "ERROR: Unable to locate VF representor for ${PF}!"
            exit 1
        fi
        echo "  Detected VF Representor: ${REP}"
        sudo ip link set "${REP}" mtu "${MTU}" up
        echo "${REP}" > "/tmp/t2_rep_${PF}.txt"
    fi

    # Unbind VF from host mlx5_core driver and bind to vfio-pci
    if [[ -d "/sys/bus/pci/drivers/mlx5_core/${VF_BDF}" ]]; then
        echo "${VF_BDF}" | sudo tee /sys/bus/pci/drivers/mlx5_core/unbind >/dev/null
    fi

    echo "vfio-pci" | sudo tee "/sys/bus/pci/devices/${VF_BDF}/driver_override" >/dev/null
    echo "${VF_BDF}" | sudo tee /sys/bus/pci/drivers_probe >/dev/null

    echo "${VF_BDF}" > "/tmp/t2_vf_bdf_${PF}.txt"
}

echo "[3/7] Setting up PF0 (${PF0})..."
setup_sriov_port "${PF0}" "${VM1_TEST_MAC}"

echo "[4/7] Setting up PF1 (${PF1})..."
setup_sriov_port "${PF1}" "${VM2_TEST_MAC}"

# 4. Apply Steering Rules according to Mode
echo "[5/7] Applying datapath rules for mode: ${MODE^^}..."

if [[ "${MODE}" == "ovs" ]]; then
    REP0=$(cat "/tmp/t2_rep_${PF0}.txt")
    REP1=$(cat "/tmp/t2_rep_${PF1}.txt")

    sudo ovs-vsctl --if-exists del-br br-left
    sudo ovs-vsctl add-br br-left
    sudo ovs-vsctl add-port br-left "${PF0}"
    sudo ovs-vsctl add-port br-left "${REP0}"
    sudo ip link set br-left mtu "${MTU}" up

    sudo ovs-vsctl --if-exists del-br br-right
    sudo ovs-vsctl add-br br-right
    sudo ovs-vsctl add-port br-right "${PF1}"
    sudo ovs-vsctl add-port br-right "${REP1}"
    sudo ip link set br-right mtu "${MTU}" up

elif [[ "${MODE}" == "tc" ]]; then
    REP0=$(cat "/tmp/t2_rep_${PF0}.txt")
    REP1=$(cat "/tmp/t2_rep_${PF1}.txt")

    for DEV in "${PF0}" "${REP0}" "${PF1}" "${REP1}"; do
        sudo tc qdisc del dev "${DEV}" ingress 2>/dev/null || true
        sudo tc qdisc add dev "${DEV}" ingress
    done

    # Bidirectional hardware ingress redirection
    sudo tc filter add dev "${PF0}" ingress protocol all prio 1 flower action mirred egress redirect dev "${REP0}"
    sudo tc filter add dev "${REP0}" ingress protocol all prio 1 flower action mirred egress redirect dev "${PF0}"
    sudo tc filter add dev "${PF1}" ingress protocol all prio 1 flower action mirred egress redirect dev "${REP1}"
    sudo tc filter add dev "${REP1}" ingress protocol all prio 1 flower action mirred egress redirect dev "${PF1}"

else
    echo "  Legacy mode active: Direct hardware routing managed via ConnectX-7 ASIC."
fi

# 5. Reserve Hugepages
echo "[6/7] Allocating Hugepages (${TOTAL_HUGEPAGES} pages)..."
sudo sysctl -w vm.nr_hugepages=${TOTAL_HUGEPAGES} >/dev/null
mountpoint -q /dev/hugepages || sudo mount -t hugetlbfs hugetlbfs /dev/hugepages

# 6. Summary
echo "[7/7] Verification Summary..."
VF0_BDF=$(cat "/tmp/t2_vf_bdf_${PF0}.txt")
VF1_BDF=$(cat "/tmp/t2_vf_bdf_${PF1}.txt")

echo "  VM1 VF (${PF0}) : PCI ${VF0_BDF}"
echo "  VM2 VF (${PF1}) : PCI ${VF1_BDF}"
echo "  eSwitch Mode   : ${MODE^^}"

echo "${MODE}" > /tmp/t2_current_mode.txt
echo "=========================================================="
echo " Host Setup Complete (Mode: ${MODE^^}, MTU ${MTU})."
echo "=========================================================="

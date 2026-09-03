#!/usr/bin/env bash
# t2_host_reset.sh — Tears down vDPA instances, TC rules, OVS bridges, and resets hardware/hugepages

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

echo "=========================================================="
echo " Resetting Host Environment (vDPA / TC / OVS Cleanup)"
echo "=========================================================="

# 1. Kill any running QEMU instances for these VMs
echo "[1/6] Terminating active QEMU instances..."
sudo pkill -f "qemu-t2_vm" 2>/dev/null || true
sleep 1

# Helper function to discover VF representor dynamically
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
        REP=$(ip -o link show | grep -E "${PF}r0|${PF}v0|pf0vf0" | awk -F': ' '{print $2}' | head -n1 || true)
    fi
    echo "$REP"
}

cleanup_vdpa_port() {
    local PF="$1"
    local DEV_IDX="$2"

    echo "----------------------------------------------------"
    echo "Cleaning up interface: ${PF} (Index: ${DEV_IDX})"

    if ! ip link show "${PF}" &>/dev/null; then
        echo "  Interface ${PF} not found, skipping..."
        return 0
    fi

    local PF_BDF
    PF_BDF=$(basename "$(readlink -f "/sys/class/net/${PF}/device")")

    # 1. Remove vDPA instance
    if sudo vdpa dev show "vdpa${DEV_IDX}" &>/dev/null; then
        echo "  Deleting vDPA device 'vdpa${DEV_IDX}'..."
        sudo vdpa dev del "vdpa${DEV_IDX}" 2>/dev/null || true
    fi

    # 2. Find representor and flush TC qdiscs/filters
    local REP
    REP=$(get_vf_representor "${PF}" "${PF_BDF}")
    
    echo "  Flushing TC ingress qdiscs..."
    sudo tc qdisc del dev "${PF}" ingress 2>/dev/null || true
    if [[ -n "${REP}" ]]; then
        sudo tc qdisc del dev "${REP}" ingress 2>/dev/null || true
    fi

    # 3. Delete OVS Bridge if it exists
    local BR_NAME="br-vdpa${DEV_IDX}"
    if command -v ovs-vsctl &>/dev/null && sudo ovs-vsctl br-exists "${BR_NAME}" 2>/dev/null; then
        echo "  Deleting OVS bridge '${BR_NAME}'..."
        sudo ovs-vsctl del-br "${BR_NAME}" 2>/dev/null || true
    fi

    # 4. Clear VFs & Restore eSwitch to Legacy mode
    echo "  Resetting VFs and returning eSwitch to legacy mode..."
    echo 0 | sudo tee "/sys/class/net/${PF}/device/sriov_numvfs" >/dev/null
    sudo devlink dev eswitch set "pci/${PF_BDF}" mode legacy 2>/dev/null || true

    # 5. reset mtu back to 1500
    sudo ip link set "${PF}" mtu 1500 2>/dev/null || true

    # 6. Clean up temporary node files
    rm -f "/tmp/t2_vdpa_node_${PF}.txt"
}

# 2. Cleanup PF0 and PF1
echo "[2/6] Cleaning up PF0 (${PF0})..."
cleanup_vdpa_port "${PF0}" 0

echo "[3/6] Cleaning up PF1 (${PF1})..."
cleanup_vdpa_port "${PF1}" 1

# 3. Release Hugepages
echo "[4/6] Releasing reserved hugepages..."
sudo sysctl -w vm.nr_hugepages=0 >/dev/null

# 4. Clean State Files
echo "[5/6] Cleaning up temporary tracking files..."
rm -f /tmp/t2_current_mode.txt

echo "=========================================================="
echo " Host Environment Successfully Reset!"
echo "=========================================================="

#!/usr/bin/env bash
# t2_launch_vm.sh <1|2> — Launches QEMU VM with VF passthrough

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

VM_NUM="${1:?Usage: $0 <1|2>}"
[[ "$VM_NUM" == "1" || "$VM_NUM" == "2" ]] || { echo "VM_NUM must be 1 or 2"; exit 1; }

if [[ "$VM_NUM" == "1" ]]; then
    PF="${PF0}"
    SSH_PORT="${SSH_DNAT_PORT_VM1}"
    MGMT_MAC="${MGMT_MAC_VM1}"
    MGMT_DHCP="${MGMT_DHCPSTART_VM1}"
    VCPU_CORES="4-7"
else
    PF="${PF1}"
    SSH_PORT="${SSH_DNAT_PORT_VM2}"
    MGMT_MAC="${MGMT_MAC_VM2}"
    MGMT_DHCP="${MGMT_DHCPSTART_VM2}"
    VCPU_CORES="8-11"
fi

VM_NAME="t2_vm${VM_NUM}"
OVERLAY_QCOW2="./t2_guest-vm${VM_NUM}.qcow2"
SEED_ISO="./t2_seed-vm${VM_NUM}.iso"

VF_BDF_FILE="/tmp/t2_vf_bdf_${PF}.txt"
[[ -f "${VF_BDF_FILE}" ]] || { echo "ERROR: Run t2_host_setup.sh first!"; exit 1; }
VF_BDF=$(cat "${VF_BDF_FILE}")

NVRAM_VARS="./vars_${VM_NAME}.fd"
[[ -f "${NVRAM_VARS}" ]] || cp "${AAVMF_VARS_TEMPLATE}" "${NVRAM_VARS}"

echo "=========================================================="
echo " Launching ${VM_NAME}"
echo "   Host CPU Cores : ${VCPU_CORES}"
echo "   Passed VF BDF  : ${VF_BDF}"
echo "=========================================================="

sudo taskset -c "${VCPU_CORES}" qemu-system-aarch64 \
  -name "${VM_NAME}",process="qemu-${VM_NAME}" \
  -machine virt,gic-version=${GIC_VERSION} \
  -accel kvm \
  -cpu host \
  -smp ${VM_VCPUS} \
  -m ${VM_MEM} \
  -object memory-backend-file,id=mem,size=${VM_MEM},mem-path=/dev/hugepages,share=on \
  -numa node,memdev=mem \
  -drive if=pflash,format=raw,unit=0,file="${AAVMF_CODE}",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="${NVRAM_VARS}" \
  -drive file="${OVERLAY_QCOW2}",if=virtio,format=qcow2,cache=none,aio=native \
  -drive file="${SEED_ISO}",if=virtio,format=raw,readonly=on \
  -netdev user,id=mgmtnet,net=${MGMT_NET},host=${MGMT_GW},dhcpstart=${MGMT_DHCP},hostfwd=tcp::${SSH_PORT}-:22 \
  -device virtio-net-pci,netdev=mgmtnet,mac=${MGMT_MAC} \
  -device vfio-pci,host=${VF_BDF},id=sriov_data_vf \
  -pidfile "/tmp/qemu-${VM_NAME}.pid" \
  -display none \
  -daemonize
  ### -nographic \

echo "VM${VM_NUM} started successfully."
echo "  SSH access: ssh -p ${SSH_PORT} ${GUEST_USER}@localhost"

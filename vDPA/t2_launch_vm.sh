#!/usr/bin/env bash
# t2_launch_vm.sh <1|2> — Launches QEMU VM with vDPA Datapath Acceleration

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

VM_NUM="${1:?Usage: $0 <1|2>}"
[[ "$VM_NUM" == "1" || "$VM_NUM" == "2" ]] || { echo "VM_NUM must be 1 or 2"; exit 1; }

if [[ "$VM_NUM" == "1" ]]; then
    PF="${PF0}"
    SSH_PORT="${SSH_DNAT_PORT_VM1}"
    MGMT_MAC="${MGMT_MAC_VM1}"
    MGMT_DHCP="${MGMT_DHCPSTART_VM1}"
    DATA_MAC="${VM1_TEST_MAC}"
    VCPU_CORES="4-7"
else
    PF="${PF1}"
    SSH_PORT="${SSH_DNAT_PORT_VM2}"
    MGMT_MAC="${MGMT_MAC_VM2}"
    MGMT_DHCP="${MGMT_DHCPSTART_VM2}"
    DATA_MAC="${VM2_TEST_MAC}"
    VCPU_CORES="8-11"
fi

VM_NAME="t2_vm${VM_NUM}"
OVERLAY_QCOW2="./t2_guest-vm${VM_NUM}.qcow2"
SEED_ISO="./t2_seed-vm${VM_NUM}.iso"

VDPA_NODE_FILE="/tmp/t2_vdpa_node_${PF}.txt"
[[ -f "${VDPA_NODE_FILE}" ]] || { echo "ERROR: vDPA node file not found! Run t2_host_setup.sh first."; exit 1; }
VDPA_NODE=$(cat "${VDPA_NODE_FILE}")

NVRAM_VARS="./vars_${VM_NAME}.fd"
[[ -f "${NVRAM_VARS}" ]] || cp "${AAVMF_VARS_TEMPLATE}" "${NVRAM_VARS}"

echo "=========================================================="
echo " Launching ${VM_NAME} (vDPA Accelerated)"
echo "   Host CPU Cores : ${VCPU_CORES}"
echo "   vDPA Device    : ${VDPA_NODE}"
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
  -netdev type=vhost-vdpa,id=vdpanet0,vhostdev=${VDPA_NODE} \
  -device virtio-net-pci,netdev=vdpanet0,mac=${DATA_MAC},mrg_rxbuf=on,mq=on,vectors=10 \
  -pidfile "/tmp/qemu-${VM_NAME}.pid" \
  -display none \
  -daemonize

echo "VM${VM_NUM} started successfully with vDPA interface."
echo "  SSH access: ssh -p ${SSH_PORT} ${GUEST_USER}@localhost"

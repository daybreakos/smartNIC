#!/usr/bin/env bash
# t2_build_guest_image.sh <1|2> — Builds guest QCOW2 image and cloud-init seed ISO

set -euo pipefail
source "$(dirname "$0")/t2_config.sh"

VM_NUM="${1:?Usage: $0 <1|2>}"
[[ "$VM_NUM" == "1" || "$VM_NUM" == "2" ]] || { echo "VM_NUM must be 1 or 2"; exit 1; }

if [[ "$VM_NUM" == "1" ]]; then
    TEST_MAC="$VM1_TEST_MAC"; TEST_IP="$VM1_TEST_IP"
    MGMT_MAC="$MGMT_MAC_VM1"
    HOSTNAME="t2-vm1"
else
    TEST_MAC="$VM2_TEST_MAC"; TEST_IP="$VM2_TEST_IP"
    MGMT_MAC="$MGMT_MAC_VM2"
    HOSTNAME="t2-vm2"
fi

WORKDIR="$(pwd)/guest-image"
BASE_IMG="${WORKDIR}/guest-base.img"
OVERLAY_QCOW2="./t2_guest-vm${VM_NUM}.qcow2"
SEED_ISO="./t2_seed-vm${VM_NUM}.iso"
DISK_SIZE="20G"

# Locate or generate SSH key
SSH_KEY_FILE=""
if [[ -f "${HOME}/.ssh/id_rsa.pub" ]]; then
    SSH_KEY_FILE="${HOME}/.ssh/id_rsa.pub"
elif [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
    SSH_KEY_FILE="${HOME}/.ssh/id_ed25519.pub"
else
    echo "Generating new SSH key..."
    ssh-keygen -t ed25519 -N "" -f "${HOME}/.ssh/id_ed25519" >/dev/null
    SSH_KEY_FILE="${HOME}/.ssh/id_ed25519.pub"
fi
HOST_PUB_KEY="$(cat "${SSH_KEY_FILE}")"

mkdir -p "${WORKDIR}"

echo "=========================================================="
echo " Building Image for VM${VM_NUM} (${HOSTNAME}) [MTU ${MTU}]"
echo "=========================================================="

if [[ ! -f "$BASE_IMG" ]]; then
    echo "[1/4] Pulling Fedora base container disk: ${BASE_IMAGE}"
    podman pull "${BASE_IMAGE}"
    CID=$(podman create "${BASE_IMAGE}")
    DISK_PATH=$(podman export "${CID}" | tar -tv | awk '{print $NF}' | grep -E '^disk/disk\.(img|qcow2|raw)$' | head -n1)
    podman cp "${CID}:/${DISK_PATH#/}" "${BASE_IMG}"
    podman rm -f "${CID}" >/dev/null 2>&1 || true
fi

BASE_FORMAT=$(qemu-img info "${BASE_IMG}" | awk -F': ' '/^file format:/{print $2}')

rm -f "${OVERLAY_QCOW2}"
echo "[2/4] Creating QCOW2 overlay..."
qemu-img create -f qcow2 -F "${BASE_FORMAT}" -b "$(realpath "${BASE_IMG}")" "${OVERLAY_QCOW2}" "${DISK_SIZE}"

echo "[3/4] Generating Cloud-Init configuration..."
mkdir -p "cloud-init-vm${VM_NUM}"

cat > "cloud-init-vm${VM_NUM}/user-data" <<EOF
#cloud-config
hostname: ${HOSTNAME}
users:
  - name: bench
    shell: /bin/bash
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys:
      - ${HOST_PUB_KEY}

chpasswd:
  list: |
    bench:${GUEST_PASSWORD}
  expire: false

ssh_pwauth: true

packages:
  - iperf3
  - sysstat
  - NetworkManager
  - qperf
  - ethtool
  - pciutils
  - iproute
  - python3

write_files:
  - path: /etc/systemd/system/iperf3-server.service
    permissions: '0644'
    content: |
      [Unit]
      Description=iperf3 server
      After=network-online.target
      [Service]
      ExecStart=/usr/bin/iperf3 -s -p 5201
      Restart=always
      [Install]
      WantedBy=multi-user.target

  - path: /etc/systemd/system/qperf-server.service
    permissions: '0644'
    content: |
      [Unit]
      Description=qperf server
      After=network-online.target
      [Service]
      ExecStart=/usr/bin/qperf
      Restart=always
      [Install]
      WantedBy=multi-user.target

runcmd:
  - sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf || true
  - systemctl restart sshd || true
  - systemctl enable --now iperf3-server.service
  - systemctl enable --now qperf-server.service
  - ip link set ens-test mtu ${MTU} || true
  - ethtool -K ens-test tx on rx on tso on gro on || true
EOF

cat > "cloud-init-vm${VM_NUM}/meta-data" <<EOF
instance-id: ${HOSTNAME}-01
local-hostname: ${HOSTNAME}
EOF

cat > "cloud-init-vm${VM_NUM}/network-config" <<EOF
version: 2
ethernets:
  ens-test:
    match:
      macaddress: "${TEST_MAC}"
    set-name: ens-test
    addresses: ["${TEST_IP}/${TEST_PREFIX}"]
    mtu: ${MTU}
    dhcp4: false
  ens-mgmt:
    match:
      macaddress: "${MGMT_MAC}"
    set-name: ens-mgmt
    dhcp4: true
EOF

echo "[4/4] Creating Seed ISO..."
cloud-localds --network-config="cloud-init-vm${VM_NUM}/network-config" \
    "${SEED_ISO}" "cloud-init-vm${VM_NUM}/user-data" "cloud-init-vm${VM_NUM}/meta-data"

echo "Image build complete for VM${VM_NUM}."


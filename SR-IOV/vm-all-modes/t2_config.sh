#!/usr/bin/env bash
# t2_config.sh — Global configuration for Legacy, Switchdev OVS, and Switchdev TC modes

### ---- Physical Topology ----
PF0="enp1s0f0np0"
# PF1="enp1s0f1np1"
PF1="enP2p1s0f1np1"

### ---- Network & Frame Settings ----
VF_NUM=0      # Index of VF passed to each guest VM
MTU="9000"    # Frame size for MTU 9000 Jumbo Frames

### ---- Management Settings (QEMU SLIRP User Network) ----
SSH_DNAT_PORT_VM1=2201                # Host access: ssh -p 2201 bench@localhost
SSH_DNAT_PORT_VM2=2202                # Host access: ssh -p 2202 bench@localhost

### ---- Guest Data Subnet ----
VM1_TEST_IP="192.168.100.11"
VM2_TEST_IP="192.168.100.12"
TEST_PREFIX="24"

VM1_TEST_MAC="52:54:00:9a:00:01"
VM2_TEST_MAC="52:54:00:9a:00:02"

### ---- Guest Management Subnet ----
MGMT_NET="10.10.10.0/24"
MGMT_GW="10.10.10.2"
MGMT_DHCPSTART_VM1="10.10.10.15"
MGMT_DHCPSTART_VM2="10.10.10.16"
MGMT_MAC_VM1="52:54:00:9a:01:01"
MGMT_MAC_VM2="52:54:00:9a:01:02"

### ---- Guest Credentials ----
GUEST_USER="bench"
GUEST_PASSWORD="test1234"

### ---- VM Resources ----
VM_VCPUS=4
VM_MEM="2G"
HUGEPAGE_SIZE_KB=2048
HUGEPAGES_PER_VM=$(( $(echo "${VM_MEM}" | sed 's/G//') * 1024 * 1024 / HUGEPAGE_SIZE_KB ))
TOTAL_HUGEPAGES=$(( HUGEPAGES_PER_VM * 2 ))

### ---- ARM64 Grace Blackwell / AAVMF UEFI Firmware ----
AAVMF_CODE=/usr/share/AAVMF/AAVMF_CODE.fd
AAVMF_VARS_TEMPLATE=/usr/share/AAVMF/AAVMF_VARS.fd
GIC_VERSION=3

### ---- Base Image Setup ----
T2_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="quay.io/containerdisks/fedora:43"


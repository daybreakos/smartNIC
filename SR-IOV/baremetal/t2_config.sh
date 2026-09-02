#!/usr/bin/env bash
#
# t2_config.sh
#
# Common configuration used by:
#
#   - t2_host_setup.sh
#   - future SR-IOV setup scripts
#   - other T2 networking topologies
#
# This file contains configuration only.
# Topology-specific setup logic belongs in the corresponding setup script.
#


###############################################################################
# Physical Topology
###############################################################################

PF0="enp1s0f0np0"
PF1="enP2p1s0f1np1"

###PF1="enp1s0f1np1"


###############################################################################
# Network & Frame Settings
###############################################################################

# Index of VF used for vDPA management
VF_NUM=0


###############################################################################
# MTU Configuration
###############################################################################
#
# MTU_PROFILE controls the frame-size configuration.
#
# regular:
#
#     Guest / VF MTU       = 1500
#     PF / Uplink MTU      = 1600
#     VF Representor MTU   = 1600
#
# jumbo:
#
#     Guest / VF MTU       = 9000
#     PF / Uplink MTU      = 9014
#     VF Representor MTU   = 9014
#
# The larger PF/REP MTU provides headroom on the host-side interfaces.
#
# The actual MTU values should also be validated against the ConnectX
# firmware, driver and kernel supported MTU range.
# In Switchdev mode:
#
#                  PF / Uplink
#                     MTU
#                      |
#                    eSwitch
#                      |
#                 VF Representor
#                     MTU
#                      |
#                     VF
#                     MTU
#

MTU_PROFILE="regular"
###MTU_PROFILE="jumbo"

case "${MTU_PROFILE}" in

    regular)
        # Normal Ethernet frame configuration.
        MTU="1500"

        # Host-side PF / uplink MTU.
        PF_MTU="1600"

        # Host-side VF Representor MTU.
        REP_MTU="1600"
        ;;

    jumbo)
        # Jumbo-frame configuration.
        MTU="9000"

        # Host-side PF / uplink MTU.
        PF_MTU="9014"

        # Host-side VF Representor MTU.
        REP_MTU="9014"
        ;;

    *)
        echo "ERROR: Invalid MTU_PROFILE='${MTU_PROFILE}'"
        echo "Supported profiles: regular, jumbo"
        exit 1
        ;;
esac


###############################################################################
# Management Settings (QEMU SLIRP User Network)
###############################################################################

SSH_DNAT_PORT_VM1=2201
SSH_DNAT_PORT_VM2=2202


###############################################################################
# Guest Data Subnet
###############################################################################

VM1_TEST_IP="192.168.100.11"
VM2_TEST_IP="192.168.100.12"

TEST_PREFIX="24"


###############################################################################
# VirtIO Test MAC Addresses
#
# Must match QEMU and vDPA tool configuration.
###############################################################################

VM1_TEST_MAC="52:54:00:9a:00:01"
VM2_TEST_MAC="52:54:00:9a:00:02"


###############################################################################
# Guest Management Subnet
###############################################################################

MGMT_NET="10.10.10.0/24"
MGMT_GW="10.10.10.2"

MGMT_DHCPSTART_VM1="10.10.10.15"
MGMT_DHCPSTART_VM2="10.10.10.16"

MGMT_MAC_VM1="52:54:00:9a:01:01"
MGMT_MAC_VM2="52:54:00:9a:01:02"


###############################################################################
# Guest Credentials
###############################################################################

GUEST_USER="bench"
GUEST_PASSWORD="test1234"


###############################################################################
# VM Resources
###############################################################################

VM_VCPUS=4

# Locked memory for DMA memory backing
VM_MEM="4G"

HUGEPAGE_SIZE_KB=2048
HUGEPAGES_PER_VM=$(( $(echo "${VM_MEM}" | sed 's/G//') * 1024 * 1024 / HUGEPAGE_SIZE_KB ))
TOTAL_HUGEPAGES=$(( HUGEPAGES_PER_VM * 2 ))


###############################################################################
# ARM64 Grace Blackwell / AAVMF UEFI Firmware
###############################################################################

AAVMF_CODE=/usr/share/AAVMF/AAVMF_CODE.fd
AAVMF_VARS_TEMPLATE=/usr/share/AAVMF/AAVMF_VARS.fd
GIC_VERSION=3


###############################################################################
# Base Image Setup
###############################################################################

T2_WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_IMAGE="quay.io/containerdisks/fedora:43"


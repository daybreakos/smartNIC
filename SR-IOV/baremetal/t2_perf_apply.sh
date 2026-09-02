#!/usr/bin/env bash
# t2_perf_apply.sh — applies the recommended settings from t2_perf_status.sh.
# Live-appliable settings are changed immediately.

set -uo pipefail
source "$(dirname "$0")/t2_config.sh"

echo "===== t2 performance apply (VirtIO/vhost-net path) ====="

echo; echo "-- Live: load vhost-net --"
sudo modprobe vhost_net
[[ -e /dev/vhost-net ]] && echo "  OK: /dev/vhost-net present" || echo "  WARNING: /dev/vhost-net still missing after modprobe"

echo; echo "-- Live: NIC offloads on both PFs --"
for IFACE in "$PF0" "$PF1"; do
    [[ -e "/sys/class/net/${IFACE}" ]] || { echo "  ${IFACE} not found, skipping"; continue; }
    sudo ethtool -K "${IFACE}" tx on rx on tso on gro on 2>/dev/null || true
    echo "  ${IFACE}: tx/rx checksumming, TSO, GRO -> on"
done

echo; echo "-- Live: CPU governor -> performance --"
for GOV in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee "$GOV" >/dev/null 2>&1 || true
done
echo "  done"

echo; echo "-- Live: disable deep C-states (keep state0) --"
for STATE in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]*/disable; do
    echo 1 | sudo tee "$STATE" >/dev/null 2>&1 || true
done
echo "  done (NOTE: increases power draw/thermal load - fine for a benchmarking session, reconsider for long-term use)"

echo; echo "-- Live: KSM off --"
echo 0 | sudo tee /sys/kernel/mm/ksm/run >/dev/null 2>&1 || true
echo "  done"

echo; echo "-- Live: THP -> madvise --"
echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
echo "  done"

echo; echo "-- Live: stop irqbalance --"
sudo systemctl stop irqbalance 2>/dev/null || true
sudo systemctl disable irqbalance 2>/dev/null || true
echo "  done"

echo; echo "-- Live: hugepages --"
if [[ ! -d "/sys/kernel/mm/hugepages/hugepages-${HUGEPAGE_SIZE_KB}kB" ]]; then
    echo "  ERROR: ${HUGEPAGE_SIZE_KB}kB hugepages not supported on this platform."
    echo "  Available sizes: $(ls /sys/kernel/mm/hugepages/ 2>/dev/null | tr '\n' ' ')"
    echo "  Fix HUGEPAGE_SIZE_KB in t2_config.sh to a supported size, then rerun this script."
else
    CURRENT_HP=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
    if [[ "$CURRENT_HP" -lt "$TOTAL_HUGEPAGES" ]]; then
        sudo sysctl -w vm.nr_hugepages=${TOTAL_HUGEPAGES}
    fi
    mountpoint -q /dev/hugepages || sudo mount -t hugetlbfs hugetlbfs /dev/hugepages
    FREE_HP=$(grep HugePages_Free /proc/meminfo | awk '{print $2}')
    echo "  ${FREE_HP} free hugepages (wanted ${TOTAL_HUGEPAGES})"
    if [[ "$FREE_HP" -lt "$TOTAL_HUGEPAGES" ]]; then
        echo "  WARNING: allocation may be fragmented. For reliable contiguous allocation, ensure bootloader configuration is managed manually."
    fi
fi


echo "TCPIP Tuning: "
# Increase maximum socket receive and send buffer sizes for high-speed links
sudo sysctl -w net.core.rmem_max=67108864
sudo sysctl -w net.core.wmem_max=67108864
sudo sysctl -w net.core.rmem_default=33554432
sudo sysctl -w net.core.wmem_default=33554432
sudo sysctl -w net.core.optmem_max=67108864

# Increase Linux auto-tuning TCP buffer limits (min, default, max in bytes)
sudo sysctl -w net.ipv4.tcp_rmem="4096 87380 33554432"
sudo sysctl -w net.ipv4.tcp_wmem="4096 65536 33554432"

# Increase the processor input queue to handle heavy burst traffic without dropping packets
sudo sysctl -w net.core.netdev_max_backlog=250000

# Increase maximumorphaned sockets and connection queue backlog
sudo sysctl -w net.core.somaxconn=10240

# Enable BBR Congestion Control (if available on your kernel version >= 4.9)
sudo sysctl -w net.core.default_qdisc=fq
sudo sysctl -w net.ipv4.tcp_congestion_control=bbr

echo
echo "===== Summary ====="
echo "Live settings applied: vhost-net, NIC offloads, governor, C-states, KSM, THP, irqbalance, hugepages."
echo "No automatic bootloader modifications made - rerun t2_perf_status.sh to check live settings."


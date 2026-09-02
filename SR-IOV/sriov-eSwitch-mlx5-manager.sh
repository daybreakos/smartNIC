#!/usr/bin/env bash
#
# mlx5-eswitch-manager.sh
#
# Interactive helper for ConnectX (mlx5) NICs:
#   - Detects mlx5 PF interfaces and their PCI BDFs
#   - Shows current eSwitch mode per interface
#   - Create / delete SR-IOV VFs per interface
#   - Toggle eSwitch mode (legacy / switchdev) per interface
#   - Reset everything (VFs=0, mode=legacy) and stay, or reset+quit, or quit
#
# Tested target: NVIDIA GB10-class platforms with multiple ConnectX PFs
# (e.g. enp1s0f0np0, enp1s0f1np1, enP2p1s0f0np0, enP2p1s0f1np1)
#
# Requires: bash, iproute2, devlink (iproute2), root privileges.

set -uo pipefail

# ---------- helpers ----------------------------------------------------

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'

die() { echo "${RED}Error:${RESET} $*" >&2; exit 1; }
info() { echo "${CYAN}$*${RESET}"; }
ok() { echo "${GREEN}$*${RESET}"; }
warn() { echo "${YELLOW}$*${RESET}"; }

need_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (sudo)."
    fi
}

need_bin() {
    command -v "$1" >/dev/null 2>&1 || die "Required tool '$1' not found in PATH."
}

pause() { read -rp "Press Enter to continue..." _; }

# ---------- discovery ----------------------------------------------------

# Selectable arrays (PFs only — these back manage_vfs/toggle_mode/reset).
# Parallel, index-aligned:
#   IFACES[i]  -> netdev name        (e.g. enp1s0f0np0)
#   PCIS[i]    -> PCI BDF            (e.g. 0000:01:00.0)
#   MODES[i]   -> eswitch mode       (legacy / switchdev / unknown)
#   NUMVFS[i]  -> current sriov_numvfs
#   TOTVFS[i]  -> sriov_totalvfs (max supported)
IFACES=()
PCIS=()
MODES=()
NUMVFS=()
TOTVFS=()

# Display-only arrays (PFs + their VFs + their representors), rebuilt by
# print_table(). Not used for selection — only for the printed table.
#   DTYPE[i]   -> PF / VF / REP
#   DNAME[i]   -> netdev name (VFs with no netdev bound show "(no netdev)")
#   DPCI[i]    -> PCI BDF (VF's own BDF; "-" for REP)
#   DPARENT[i] -> parent PF interface name ("-" for PF rows)
#   DEXTRA[i]  -> vf index for VF rows, portname for REP rows, "-" for PF
#   DMODE[i]   -> inherited/own eswitch mode
DTYPE=(); DNAME=(); DPCI=(); DPARENT=(); DEXTRA=(); DMODE=()

get_eswitch_mode() {
    local pci="$1" mode
    mode=$(devlink dev eswitch show "pci/$pci" 2>/dev/null \
             | grep -oE 'mode (legacy|switchdev)' | awk '{print $2}')
    [[ -z "$mode" ]] && mode="unknown"
    echo "$mode"
}

detect_interfaces() {
    IFACES=(); PCIS=(); MODES=(); NUMVFS=(); TOTVFS=()

    local iface devpath driver pci numvfs totvfs mode

    for netdir in /sys/class/net/*; do
        iface=$(basename "$netdir")
        devpath="$netdir/device"

        [[ -e "$devpath" ]] || continue

        # Skip VF representors / VF netdevs: a PF has no 'physfn' symlink.
        [[ -e "$devpath/physfn" ]] && continue

        # Only interested in mlx5_core devices.
        driver=""
        if [[ -e "$devpath/driver" ]]; then
            driver=$(basename "$(readlink -f "$devpath/driver")")
        fi
        [[ "$driver" == "mlx5_core" ]] || continue

        # A real PF exposes sriov_totalvfs. Representors / other mlx5
        # aux devices won't have it, so this doubles as a PF filter.
        [[ -e "$devpath/sriov_totalvfs" ]] || continue

        pci=$(basename "$(readlink -f "$devpath")")
        numvfs=$(cat "$devpath/sriov_numvfs" 2>/dev/null || echo "?")
        totvfs=$(cat "$devpath/sriov_totalvfs" 2>/dev/null || echo "?")
        mode=$(get_eswitch_mode "$pci")

        IFACES+=("$iface")
        PCIS+=("$pci")
        MODES+=("$mode")
        NUMVFS+=("$numvfs")
        TOTVFS+=("$totvfs")
    done

    if [[ ${#IFACES[@]} -eq 0 ]]; then
        warn "No mlx5 PF interfaces detected."
    fi
}

# Build the display list: for each PF, list the PF row, then its VF rows
# (bound netdev name if one exists, else PCI-only), then, if the PF is in
# switchdev mode, its representor netdevs (matched by phys_switch_id +
# the vfN suffix of phys_port_name, e.g. "pf0vf1" -> VF index 1).
build_display_list() {
    DTYPE=(); DNAME=(); DPCI=(); DPARENT=(); DEXTRA=(); DMODE=()

    local i pf pf_pci pf_mode pf_switchid

    for i in "${!IFACES[@]}"; do
        pf="${IFACES[$i]}"; pf_pci="${PCIS[$i]}"; pf_mode="${MODES[$i]}"

        DTYPE+=("PF"); DNAME+=("$pf"); DPCI+=("$pf_pci")
        DPARENT+=("-"); DEXTRA+=("-"); DMODE+=("$pf_mode")

        pf_switchid=""
        [[ -e "/sys/class/net/$pf/phys_switch_id" ]] && \
            pf_switchid=$(cat "/sys/class/net/$pf/phys_switch_id" 2>/dev/null)

        # --- VFs of this PF, discovered via virtfnN symlinks ---
        local vfdir vfn vf_pci vf_iface found_rep rep_dir rep_iface rep_pname
        for vfdir in "/sys/class/net/$pf/device"/virtfn*; do
            [[ -e "$vfdir" ]] || continue
            vfn=$(basename "$vfdir" | sed 's/virtfn//')
            vf_pci=$(basename "$(readlink -f "$vfdir")")

            vf_iface=""
            if [[ -d "/sys/bus/pci/devices/$vf_pci/net" ]]; then
                vf_iface=$(ls "/sys/bus/pci/devices/$vf_pci/net" 2>/dev/null | head -n1)
            fi
            [[ -z "$vf_iface" ]] && vf_iface="(no netdev)"

            DTYPE+=("VF"); DNAME+=("$vf_iface"); DPCI+=("$vf_pci")
            DPARENT+=("$pf"); DEXTRA+=("vf$vfn"); DMODE+=("$pf_mode")

            # Try to find the matching representor for this VF (switchdev only).
            if [[ "$pf_mode" == "switchdev" && -n "$pf_switchid" ]]; then
                found_rep=""
                for rep_dir in /sys/class/net/*; do
                    rep_iface=$(basename "$rep_dir")
                    [[ -e "$rep_dir/phys_switch_id" ]] || continue
                    [[ "$(cat "$rep_dir/phys_switch_id" 2>/dev/null)" == "$pf_switchid" ]] || continue
                    [[ -e "$rep_dir/phys_port_name" ]] || continue
                    rep_pname=$(cat "$rep_dir/phys_port_name" 2>/dev/null)
                    if [[ "$rep_pname" =~ ^pf[0-9]+vf${vfn}$ ]]; then
                        found_rep="$rep_iface"
                        break
                    fi
                done
                if [[ -n "$found_rep" ]]; then
                    DTYPE+=("REP"); DNAME+=("$found_rep"); DPCI+=("-")
                    DPARENT+=("$vf_iface"); DEXTRA+=("$rep_pname"); DMODE+=("$pf_mode")
                fi
            fi
        done
    done
}

print_table() {
    detect_interfaces
    build_display_list
    echo
    printf "${BOLD}%-4s %-16s %-4s %-14s %-16s %-8s %-10s %-8s %-8s${RESET}\n" \
        "#" "INTERFACE" "TYPE" "PCI BDF" "PARENT/LINK" "VF#/PORT" "ESWITCH" "NUMVFS" "MAXVFS"
    printf '%.0s-' {1..96}; echo

    local i pf_counter=0
    for i in "${!DTYPE[@]}"; do
        local type="${DTYPE[$i]}" modecolor="$RESET"
        [[ "${DMODE[$i]}" == "switchdev" ]] && modecolor="$GREEN"
        [[ "${DMODE[$i]}" == "legacy" ]] && modecolor="$YELLOW"

        local typecolor="$RESET"
        [[ "$type" == "PF" ]]  && typecolor="$BOLD"
        [[ "$type" == "VF" ]]  && typecolor="$CYAN"
        [[ "$type" == "REP" ]] && typecolor="$YELLOW"

        if [[ "$type" == "PF" ]]; then
            pf_counter=$((pf_counter+1))
            printf "%-4s %-16s ${typecolor}%-4s${RESET} %-14s %-16s %-8s ${modecolor}%-10s${RESET} %-8s %-8s\n" \
                "$pf_counter" "${DNAME[$i]}" "$type" "${DPCI[$i]}" \
                "${DPARENT[$i]}" "${DEXTRA[$i]}" "${DMODE[$i]}" \
                "${NUMVFS[$((pf_counter-1))]}" "${TOTVFS[$((pf_counter-1))]}"
        else
            printf "%-4s %-16s ${typecolor}%-4s${RESET} %-14s %-16s %-8s ${modecolor}%-10s${RESET} %-8s %-8s\n" \
                "" "${DNAME[$i]}" "$type" "${DPCI[$i]}" \
                "${DPARENT[$i]}" "${DEXTRA[$i]}" "${DMODE[$i]}" "-" "-"
        fi
    done
    echo
    echo "  (# is only assigned to PF rows — that's what you select below)"
    echo
}

select_interface() {
    # Prints prompt, returns chosen index via echo (caller captures it).
    local i choice
    print_table >&2
    read -rp "Select interface # (or 0 to cancel): " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 0 || choice > ${#IFACES[@]} )); then
        echo "-1"
        return
    fi
    if (( choice == 0 )); then
        echo "-1"
        return
    fi
    echo "$((choice-1))"
}

# ---------- actions ----------------------------------------------------

manage_vfs() {
    local idx
    idx=$(select_interface)
    [[ "$idx" == "-1" ]] && return

    local iface="${IFACES[$idx]}" pci="${PCIS[$idx]}"
    local devpath="/sys/class/net/$iface/device"
    local cur max
    cur=$(cat "$devpath/sriov_numvfs" 2>/dev/null || echo 0)
    max=$(cat "$devpath/sriov_totalvfs" 2>/dev/null || echo 0)

    echo
    info "Interface: $iface  ($pci)"
    echo "Current VFs: $cur   Max supported: $max"
    echo
    echo "  1) Create / set VF count"
    echo "  2) Delete all VFs (set to 0)"
    echo "  0) Back"
    read -rp "Choice: " sub

    case "$sub" in
        1)
            read -rp "Number of VFs to create (0-$max): " n
            if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n > max )); then
                warn "Invalid VF count."
                pause; return
            fi
            if (( cur > 0 )); then
                warn "Existing VFs present, clearing first (echo 0)..."
                echo 0 | tee "$devpath/sriov_numvfs" >/dev/null
            fi
            echo "$n" | tee "$devpath/sriov_numvfs" >/dev/null \
                && ok "Set sriov_numvfs=$n on $iface" \
                || warn "Failed to set VF count. Check dmesg."
            ;;
        2)
            echo 0 | tee "$devpath/sriov_numvfs" >/dev/null \
                && ok "Deleted all VFs on $iface" \
                || warn "Failed to clear VFs. Check dmesg."
            ;;
        0) return ;;
        *) warn "Invalid choice." ;;
    esac
    pause
}

toggle_eswitch_mode() {
    local idx
    idx=$(select_interface)
    [[ "$idx" == "-1" ]] && return

    local iface="${IFACES[$idx]}" pci="${PCIS[$idx]}" mode="${MODES[$idx]}"
    local devpath="/sys/class/net/$iface/device"
    local cur
    cur=$(cat "$devpath/sriov_numvfs" 2>/dev/null || echo 0)

    echo
    info "Interface: $iface  ($pci)   Current eSwitch mode: $mode"

    local target
    if [[ "$mode" == "legacy" ]]; then
        target="switchdev"
    elif [[ "$mode" == "switchdev" ]]; then
        target="legacy"
    else
        echo "  1) Set legacy"
        echo "  2) Set switchdev"
        echo "  0) Back"
        read -rp "Choice: " sub
        case "$sub" in
            1) target="legacy" ;;
            2) target="switchdev" ;;
            *) return ;;
        esac
    fi

    read -rp "Switch $iface from '$mode' to '$target'? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    if (( cur > 0 )); then
        warn "VFs are currently active ($cur). They must be unbound/cleared"
        warn "before the mode can change. Clearing VFs on $iface..."
        echo 0 | tee "$devpath/sriov_numvfs" >/dev/null
    fi

    if devlink dev eswitch set "pci/$pci" mode "$target" 2>/tmp/esw_err; then
        ok "Set eswitch mode '$target' on $iface ($pci)"
    else
        warn "Failed to set mode. Driver said:"
        cat /tmp/esw_err >&2
    fi
    pause
}

reset_all() {
    local quiet="${1:-0}"
    detect_interfaces
    local i
    for i in "${!IFACES[@]}"; do
        local iface="${IFACES[$i]}" pci="${PCIS[$i]}"
        local devpath="/sys/class/net/$iface/device"
        local cur
        cur=$(cat "$devpath/sriov_numvfs" 2>/dev/null || echo 0)

        if (( cur > 0 )); then
            echo 0 | tee "$devpath/sriov_numvfs" >/dev/null 2>&1
            [[ "$quiet" == "0" ]] && ok "Cleared VFs on $iface"
        fi

        devlink dev eswitch set "pci/$pci" mode legacy >/dev/null 2>&1
        [[ "$quiet" == "0" ]] && ok "Set eswitch mode legacy on $iface"
    done
    [[ "$quiet" == "0" ]] && ok "Reset complete: all VFs removed, all interfaces set to legacy."
}

# ---------- main menu ----------------------------------------------------

main_menu() {
    while true; do
        clear 2>/dev/null || true
        echo "${BOLD}=== ConnectX (mlx5) eSwitch / SR-IOV Manager ===${RESET}"
        print_table
        echo "  1) Refresh status"
        echo "  2) Manage VFs (create/delete) on an interface"
        echo "  3) Toggle eSwitch mode (legacy/switchdev) on an interface"
        echo "  4) Reset everything (VFs=0, mode=legacy) and stay in menu"
        echo "  5) Reset everything and quit"
        echo "  6) Quit (no reset)"
        echo
        read -rp "Choice: " choice
        case "$choice" in
            1) continue ;;
            2) manage_vfs ;;
            3) toggle_eswitch_mode ;;
            4)
                read -rp "Reset ALL interfaces (clear VFs, set legacy)? [y/N]: " c
                [[ "$c" =~ ^[Yy]$ ]] && reset_all
                pause
                ;;
            5)
                read -rp "Reset ALL interfaces and quit? [y/N]: " c
                if [[ "$c" =~ ^[Yy]$ ]]; then
                    reset_all
                    ok "Done. Exiting."
                    exit 0
                fi
                ;;
            6)
                echo "Exiting without changes."
                exit 0
                ;;
            *)
                warn "Invalid choice."
                pause
                ;;
        esac
    done
}

# ---------- entry point ----------------------------------------------------

need_root
need_bin devlink
need_bin ip

main_menu

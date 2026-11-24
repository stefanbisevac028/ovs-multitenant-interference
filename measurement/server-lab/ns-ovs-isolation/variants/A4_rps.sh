#!/bin/bash
# A4 - A3 + RPS po tenantu: na redu(ovima) prijema veth-a uplink0 u netns ovs-N postavlja se RPS
# maska (A4_RPS_CPUS u ns.env). Paket iz tier0 ulazi u netns tenanta kroz red prijema uplink0, pa
# se obrada tier1 datapath-a seli na jezgra tenanta; tier0 obrada ostaje na jezgru reda kartice.
#
#   setup     primenjuje A3 ako vec nije, cuva trenutne rps_cpus u state/A4.saved, postavlja maske
#   teardown  vraca sacuvane maske, pa uklanja i A3
#   status    rps_cpus po instanci
#
#   ./A4_rps.sh setup|teardown|status [--apply]       (bez --apply: dry-run)
#
# Ako se ovs-N restartuje, agent pravi uplink0 iznova i maska se gubi (status to pokazuje).
set -uo pipefail
source "$(dirname "$0")/../lib.sh"
need_root "$@"
parse_apply "$@"
SAVED="$STATE_DIR/A4.saved"
APPLY_ARG=(); [ "$APPLY" = 1 ] && APPLY_ARG=(--apply)

rps_files() { ip netns exec "$(t1_name "$1")" sh -c 'ls /sys/class/net/uplink0/queues/rx-*/rps_cpus'; }

setup() {
    case "$(current_variant)" in
        A0|A1) die "A4 se primenjuje na hijerarhiju (A2), a primenjena je $(current_variant)" ;;
        A4) die "A4 je vec primenjen" ;;
    esac
    if ! applied A3; then "$NS_DIR/variants/A3_cpuset.sh" setup "${APPLY_ARG[@]}" || die "A3 nije postavljen"; fi
    local n f mask
    if [ "$APPLY" = 1 ]; then
        mkdir -p "$STATE_DIR"; : > "$SAVED"
        for n in $(tenants); do
            for f in $(rps_files "$n"); do
                echo "$n $f $(ip netns exec "$(t1_name "$n")" cat "$f")" >> "$SAVED"
            done
        done
    fi
    mark A4
    for n in $(tenants); do
        mask=$(cpulist_to_mask "${A4_RPS_CPUS[$((n - 1))]}")
        for f in $(rps_files "$n"); do
            run ip netns exec "$(t1_name "$n")" sh -c "echo $mask > $f"
        done
    done
    if [ "$APPLY" = 1 ]; then status; fi
    done_msg "A4 postavljen"
}

teardown() {
    local n f val
    if [ -f "$SAVED" ]; then
        while read -r n f val; do run ip netns exec "$(t1_name "$n")" sh -c "echo ${val:-0} > $f"; done < "$SAVED"
    else
        for n in $(tenants); do
            for f in $(rps_files "$n" 2>/dev/null); do run ip netns exec "$(t1_name "$n")" sh -c "echo 0 > $f"; done
        done
    fi
    if [ "$APPLY" = 1 ]; then rm -f "$SAVED"; fi
    unmark A4
    "$NS_DIR/variants/A3_cpuset.sh" teardown "${APPLY_ARG[@]}"
    done_msg "A4 uklonjen (A2)"
}

status() {
    echo "varijanta: $(current_variant)"
    local n f
    for n in $(tenants); do
        for f in $(rps_files "$n" 2>/dev/null); do
            echo "  $(t1_name "$n") ${f#/sys/class/net/}: $(ip netns exec "$(t1_name "$n")" cat "$f")"
        done
    done
}

case "${1:-}" in
    setup)    rollback_on_error; setup ;;
    teardown) teardown ;;
    status)   status ;;
    *) echo "upotreba: $0 setup|teardown|status [--apply]"; exit 2 ;;
esac

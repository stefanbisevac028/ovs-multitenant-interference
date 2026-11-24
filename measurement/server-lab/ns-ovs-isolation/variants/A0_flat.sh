#!/bin/bash
# A0 - ravni OvS: jedan OvS (sistemski, br-tier0), servisi direktno na njemu, bez tier1 instanci.
#
#   setup     zaustavlja ovs-1..N (agenti uredno skidaju svoje portove sa br-tier0; veth-ovi
#             servisa nestaju zajedno sa namespace-om), pa servise vezuje veth-om a0-<svc>
#             direktno na br-tier0, sa istom IP i stalnom MAC adresom kao u A2.
#             Pravila na br-tier0 ostaju ista (flows.txt).
#   teardown  skida a0-* portove i veth-ove i ponovo pokrece ovs-1..N; agenti sami vrate A2.
#   status    ispisuje portove na br-tier0 i stanje servisa
#
#   ./A0_flat.sh setup|teardown|status [--apply]      (bez --apply: dry-run)
#
# Zaustavljeni ovs-N se ne podizu sami posle restarta masine (unless-stopped).
# Ako se server restartuje u A0: ./A0_flat.sh teardown --apply vraca A2.
set -uo pipefail
source "$(dirname "$0")/../lib.sh"
need_root "$@"
parse_apply "$@"

hv() { echo "a0-$1"; }

setup() {
    [ "$(current_variant)" = A2 ] || die "primenjena je varijanta $(current_variant); prvo ./restore_A2.sh --apply"
    check_a2_running
    mark A0
    stop_tier1
    local s
    for s in "${SERVICES[@]}"; do attach_svc "$s" "$T0_BRIDGE" "$(hv "$(svc_field "$s" 1)")"; done
    if [ "$APPLY" = 1 ]; then status; fi
    done_msg "A0 postavljen"
}

teardown() {
    local s
    for s in "${SERVICES[@]}"; do detach_svc "$(hv "$(svc_field "$s" 1)")" "$T0_BRIDGE"; done
    start_tier1_wait
    unmark A0
    done_msg "A0 uklonjen (A2)"
}

status() {
    echo "varijanta: $(current_variant)"
    ovs-vsctl list-ports "$T0_BRIDGE" | sed 's/^/  br-tier0: /'
    local s name
    for s in "${SERVICES[@]}"; do
        name=$(svc_field "$s" 1)
        if svc_has_ip "$name" "$(svc_field "$s" 3)"; then echo "  $name: eth0 ok"; else echo "  $name: nema eth0/IP"; fi
    done
}

case "${1:-}" in
    setup)    rollback_on_error; setup ;;
    teardown) teardown ;;
    status)   status ;;
    *) echo "upotreba: $0 setup|teardown|status [--apply]"; exit 2 ;;
esac

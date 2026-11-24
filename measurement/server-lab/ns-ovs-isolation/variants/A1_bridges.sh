#!/bin/bash
# A1 - ravni OvS sa bridge-om po tenantu: jedan ovs-vswitchd i jedan kernel datapath (sistemski
# OvS hosta), ali svaki tenant ima svoj bridge br-a1-N povezan sa br-tier0.
#
#   A1_LINK=patch (ns.env, podrazumevano): patch portovi; razresavaju se pri prevodjenju pravila,
#                 pa datapath vidi jedan megaflow po toku (logicka podela, bez dodatnog prolaza).
#   A1_LINK=veth: veth par izmedju bridge-ova (dodatni prolaz kroz isti datapath).
#
#   setup     zaustavlja ovs-1..N, pravi br-a1-N (secure, pravila iz flows.txt), vezu ka
#             br-tier0 i veth a1-<svc> do servisa (ista IP i stalna MAC kao u A2)
#   teardown  brise br-a1-N, veze i veth-ove, ponovo pokrece ovs-1..N (agenti vrate A2)
#   status
#
#   ./A1_bridges.sh setup|teardown|status [--apply]   (bez --apply: dry-run)
set -uo pipefail
source "$(dirname "$0")/../lib.sh"
need_root "$@"
parse_apply "$@"

br()    { echo "br-a1-$1"; }
lt0()   { if [ "$A1_LINK" = veth ]; then echo "a1v-t0-$1"; else echo "a1p-t0-$1"; fi; }   # strana na br-tier0
lt1()   { if [ "$A1_LINK" = veth ]; then echo "a1v-$1"; else echo "a1p-$1"; fi; }         # strana na br-a1-N
hv()    { echo "a1-$1"; }

setup() {
    [ "$(current_variant)" = A2 ] || die "primenjena je varijanta $(current_variant); prvo ./restore_A2.sh --apply"
    case "$A1_LINK" in patch|veth) ;; *) die "A1_LINK mora biti patch ili veth" ;; esac
    check_a2_running
    mark A1
    stop_tier1
    local n s b
    for n in $(tenants); do
        b=$(br "$n")
        run ovs-vsctl --may-exist add-br "$b" -- set-fail-mode "$b" secure
        run ip link set "$b" mtu "$MTU" up
        if [ "$A1_LINK" = veth ]; then
            run ip link add "$(lt0 "$n")" type veth peer name "$(lt1 "$n")"
            run ip link set "$(lt0 "$n")" mtu "$MTU" up
            run ip link set "$(lt1 "$n")" mtu "$MTU" up
            run ovs-vsctl --may-exist add-port "$T0_BRIDGE" "$(lt0 "$n")"
            run ovs-vsctl --may-exist add-port "$b" "$(lt1 "$n")"
        else
            run ovs-vsctl --may-exist add-port "$T0_BRIDGE" "$(lt0 "$n")" -- \
                set interface "$(lt0 "$n")" type=patch options:peer="$(lt1 "$n")" -- \
                --may-exist add-port "$b" "$(lt1 "$n")" -- \
                set interface "$(lt1 "$n")" type=patch options:peer="$(lt0 "$n")"
        fi
        for s in $(svc_of_tenant "$n"); do attach_svc "$s" "$b" "$(hv "$(svc_field "$s" 1)")"; done
        run ovs-ofctl replace-flows "$b" "$FLOWS_DIR/flows.txt"
    done
    if [ "$APPLY" = 1 ]; then status; fi
    done_msg "A1 postavljen ($A1_LINK)"
}

teardown() {
    local n s l
    for n in $(tenants); do
        for s in $(svc_of_tenant "$n"); do detach_svc "$(hv "$(svc_field "$s" 1)")" "$(br "$n")"; done
        for l in "a1p-t0-$n" "a1v-t0-$n"; do run ovs-vsctl --if-exists del-port "$T0_BRIDGE" "$l"; done
        run ovs-vsctl --if-exists del-br "$(br "$n")"
        if ip link show "a1v-t0-$n" >/dev/null 2>&1; then run ip link del "a1v-t0-$n"; fi
    done
    start_tier1_wait
    unmark A1
    done_msg "A1 uklonjen (A2)"
}

status() {
    echo "varijanta: $(current_variant)"
    ovs-vsctl show | grep -E "Bridge|Port|type: patch" | sed 's/^/  /'
}

case "${1:-}" in
    setup)    rollback_on_error; setup ;;
    teardown) teardown ;;
    status)   status ;;
    *) echo "upotreba: $0 setup|teardown|status [--apply]"; exit 2 ;;
esac

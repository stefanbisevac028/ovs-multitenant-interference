#!/bin/bash
# A3 - A2 + cpuset: tier1 kontejneri ovs-N (ovsdb-server, ovs-vswitchd, agent) ograniceni su na
# disjunktne skupove jezgara (A3_CPUS u ns.env). Izoluje sporu putanju, ne i softirq obradu.
#
#   setup     cuva trenutni cpuset kontejnera u state/A3.saved, pa docker update --cpuset-cpus
#   teardown  vraca sacuvane vrednosti (prazno = sva jezgra 0..nproc-1)
#   status    cpuset kontejnera i dozvoljena jezgra procesa ovs-vswitchd po instanci
#
#   ./A3_cpuset.sh setup|teardown|status [--apply]    (bez --apply: dry-run)
#
# Napomena: docker ne moze da vrati cpuset na "prazno"; posle teardown-a pise "0-15",
# sto je funkcionalno isto kao pre.
set -uo pipefail
source "$(dirname "$0")/../lib.sh"
need_root "$@"
parse_apply "$@"
SAVED="$STATE_DIR/A3.saved"

targets() { # "kontejner cpuset" po liniji
    local n s
    for n in $(tenants); do
        echo "$(t1_name "$n") ${A3_CPUS[$((n - 1))]}"
        if [ "$A3_PIN_SERVICES" = 1 ]; then
            for s in $(svc_of_tenant "$n"); do echo "$(svc_field "$s" 1) ${A3_CPUS[$((n - 1))]}"; done
        fi
    done
}

setup() {
    case "$(current_variant)" in
        A0|A1) die "A3 se primenjuje na hijerarhiju (A2), a primenjena je $(current_variant)" ;;
        A3|A4) die "A3 je vec primenjen" ;;
    esac
    check_a2_running
    local c cpus
    if [ "$APPLY" = 1 ]; then
        mkdir -p "$STATE_DIR"; : > "$SAVED"
        while read -r c cpus; do
            echo "$c $(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$c")" >> "$SAVED"
        done < <(targets)
    fi
    mark A3
    while read -r c cpus; do run docker update --cpuset-cpus "$cpus" "$c"; done < <(targets)
    if [ "$APPLY" = 1 ]; then status; fi
    done_msg "A3 postavljen"
}

teardown() {
    local all="0-$(($(nproc) - 1))" c val cpus
    if [ -f "$SAVED" ]; then
        while read -r c val; do run docker update --cpuset-cpus "${val:-$all}" "$c"; done < "$SAVED"
    else
        warn "nema $SAVED, vracam sva jezgra ($all) svim ciljevima"
        while read -r c cpus; do run docker update --cpuset-cpus "$all" "$c"; done < <(targets)
    fi
    if [ "$APPLY" = 1 ]; then rm -f "$SAVED"; fi
    unmark A3
    done_msg "A3 uklonjen"
}

status() {
    echo "varijanta: $(current_variant)"
    local n pid
    for n in $(tenants); do
        pid=$(ns_pid_of "$(t1_name "$n")" ovs-vswitchd) || pid=""
        printf '  %-6s cpuset=%-8s vswitchd=%s\n' "$(t1_name "$n")" \
            "$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$(t1_name "$n")")" \
            "${pid:+$(taskset -pc "$pid" | sed 's/.*: //')}"
    done
}

case "${1:-}" in
    setup)    rollback_on_error; setup ;;
    teardown) teardown ;;
    status)   status ;;
    *) echo "upotreba: $0 setup|teardown|status [--apply]"; exit 2 ;;
esac

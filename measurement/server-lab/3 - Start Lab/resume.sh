#!/bin/bash
# Ponovo pokrece kontejnere zaustavljene sa stop.sh (redom: tier0, tier1, servisi).
# Agenti sami ponovo povezu veth-ove i primene pravila.
#
#   ./resume.sh
set -uo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

start_c() {
    docker inspect "$1" >/dev/null 2>&1 || { warn "[$1] ne postoji (pokreni setup.sh / start.sh)"; return; }
    running "$1" || { docker start "$1" >/dev/null && ok "[$1] pokrenut"; }
}

start_c "$T0_CONTAINER"
for n in $(seq 1 "$T1_COUNT"); do start_c "$(t1_name "$n")"; done
for s in "${SERVICES[@]}"; do start_c "$(svc_field "$s" 1)"; done
info "Agenti povezuju veth-ove (do ~$((AGENT_INTERVAL * 2)) s). Provera: ./status.sh"

#!/bin/bash
# Ponovo pokrece TRex kontejnere zaustavljene sa stop.sh. Svaki kontejner sam
# ponovo napravi svoj veth ka br-trex.
#
#   ./resume.sh
set -uo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

N=$(trex_count)
for i in $(seq 1 "$N"); do
    name=$(trex_name "$i")
    docker inspect "$name" >/dev/null 2>&1 || { warn "[$name] ne postoji (pokreni start.sh)"; continue; }
    if [ "$(docker inspect -f '{{.State.Running}}' "$name")" != "true" ]; then
        docker start "$name" >/dev/null && ok "[$name] pokrenut"
    fi
done
info "TRex-u treba nekoliko sekundi da podigne API. Provera: ./status.sh"

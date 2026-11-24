#!/bin/bash
# Bezbedno zaustavljanje: TRex dobija SIGINT (kao Ctrl+C) i vreme da zaustavi saobracaj.
# Kontejneri ostaju (ne brisu se) i NE podizu se sami posle restarta masine
# (unless-stopped). Ponovno pokretanje: ./resume.sh
#
#   ./stop.sh
set -uo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

N=$(trex_count)
for i in $(seq 1 "$N"); do
    name=$(trex_name "$i")
    if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ]; then
        info "[$name] zaustavljam..."
        docker stop -t 30 "$name" >/dev/null
        ok "[$name] zaustavljen"
    fi
done
ok "TRex kontejneri zaustavljeni. Ponovno pokretanje: ./resume.sh"

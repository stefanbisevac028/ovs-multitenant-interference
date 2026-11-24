#!/bin/bash
# Pregled stanja lab-a: kontejneri, OvS, API portovi, hugepages.
#
#   ./status.sh
set -uo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

info "Kontejneri:"
docker ps -a --filter label=lab=trex --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

info "OvS:"
ovs-vsctl show 2>/dev/null || warn "OvS ne radi"
ovs-ofctl dump-ports "$OVS_BRIDGE" 2>/dev/null | grep -E "port|rx pkts|tx pkts" | sed 's/^/   /'

info "TRex API:"
for i in $(seq 1 "$(trex_count)"); do
    name=$(trex_name "$i")
    if docker exec "$name" ss -ltn 2>/dev/null | grep -q ':4501 '; then
        ok "$name: radi na portu $(trex_sync_port "$i")"
    else
        warn "$name: ne radi"
    fi
done

info "Hugepages: $(grep -E 'HugePages_(Total|Free)' /proc/meminfo | tr -s ' ' | tr '\n' ' ')"

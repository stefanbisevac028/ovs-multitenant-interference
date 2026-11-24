#!/bin/bash
# Pregled stanja: kontejneri, tier0, tier1 OvS-ovi, servisi.
#
#   ./status.sh
set -uo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

info "Kontejneri:"
docker ps -a --filter label=lab=server-lab \
    --format 'table {{.Names}}\t{{.Label "role"}}\t{{.Status}}' 2>/dev/null | sort -k2,2 -k1,1

info "tier0 ${T0_BRIDGE}:"
if ovs-vsctl br-exists "$T0_BRIDGE"; then
    ovs-vsctl list-ports "$T0_BRIDGE" | sed 's/^/   port: /'
    ovs-ofctl dump-flows "$T0_BRIDGE" | grep -v NXST | sed 's/^ */   /'
else
    warn "ne postoji"
fi

for n in $(seq 1 "$T1_COUNT"); do
    name=$(t1_name "$n")
    info "tier1 $name/$(t1_br "$n"):"
    if running "$name"; then
        docker exec "$name" ovs-vsctl list-ports "$(t1_br "$n")" | sed 's/^/   port: /'
    else
        warn "kontejner ne radi"
    fi
done

info "Servisi:"
for s in "${SERVICES[@]}"; do
    name=$(svc_field "$s" 1)
    if running "$name"; then
        a=$(docker exec "$name" ip -4 -br addr show dev eth0 2>/dev/null | awk '{print $3}')
        echo "   $name: ${a:-nema eth0 (agent jos nije povezao)}"
    else
        echo "   $name: ne radi"
    fi
done

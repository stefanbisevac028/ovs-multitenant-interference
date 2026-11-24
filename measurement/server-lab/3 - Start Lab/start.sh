#!/bin/bash
# 3 - Start Lab
# Podize servise (Docker kontejneri iz SERVICES u lab.env) sa --restart unless-stopped.
# Servisi nemaju Docker mrezu; agent u njihovom tier1 OvS kontejneru sam pravi veth
# (s-<ime> na br0-N <-> eth0 u servisu) i dodeljuje IP. Postojeci servisi se prave iznova.
#
#   ./start.sh
set -euo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

for n in $(seq 1 "$T1_COUNT"); do
    running "$(t1_name "$n")" || die "tier1 $(t1_name "$n") ne radi, pokreni 2 - Setup Lab/setup.sh"
done
docker image inspect "$SERVICE_IMAGE" >/dev/null 2>&1 || docker pull -q "$SERVICE_IMAGE"

for s in "${SERVICES[@]}"; do
    name=$(svc_field "$s" 1); n=$(svc_field "$s" 2)
    info "[$name] pokrecem ($(svc_field "$s" 3) na $(t1_name "$n"))..."
    docker rm -f "$name" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    docker run -d --name "$name" --hostname "$name" \
        --network none --cap-add NET_ADMIN --restart unless-stopped \
        --label lab=server-lab --label role=service --label tier1="$(t1_name "$n")" \
        "$SERVICE_IMAGE" $SERVICE_CMD >/dev/null
done

info "Cekam da agenti povezu servise..."
for s in "${SERVICES[@]}"; do
    name=$(svc_field "$s" 1); ip_addr=$(svc_field "$s" 3); up=0
    for _ in $(seq $((AGENT_INTERVAL * 4 + 5))); do
        docker exec "$name" ip -4 addr show dev eth0 2>/dev/null | grep -q "$ip_addr/" && { up=1; break; }
        sleep 1
    done
    if [ "$up" = 1 ]; then ok "[$name] povezan ($ip_addr)"; else warn "[$name] nije povezan, pogledaj: docker logs $(t1_name "$(svc_field "$s" 2)")"; fi
done

echo
echo "================ Server lab ================"
printf "%-8s %-15s %-8s %s\n" "Servis" "IP" "tier1" "Pristup"
for s in "${SERVICES[@]}"; do
    name=$(svc_field "$s" 1)
    printf "%-8s %-15s %-8s %s\n" "$name" "$(svc_field "$s" 3)" "$(t1_name "$(svc_field "$s" 2)")" "docker exec -it $name bash"
done
cat <<EOF

Servis komanda:   ${SERVICE_CMD}   (image ${SERVICE_IMAGE})
tier1 OvS:        docker exec $(t1_name 1) ovs-vsctl show
Pravila:          ../2\ -\ Setup\ Lab/flows.sh show
Logovi agenta:    docker logs -f $(t1_name 1)
Status:           ./status.sh
Zaustavljanje:    ./stop.sh      Brisanje: ./delete.sh
EOF

#!/bin/bash
# 3 - Start Lab
# Podize TRex kontejnere (--restart unless-stopped) i ispisuje kako se pristupa API-ju
# i konzoli. Svaki kontejner sam pravi svoj data interfejs eth1 (veth ka br-trex), pa se
# posle restarta kontejnera ili masine sve poveze samo. Postojeci kontejneri se prave iznova.
#
#   ./start.sh
set -euo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

docker image inspect "$TREX_IMAGE" >/dev/null 2>&1 || die "Nema image-a $TREX_IMAGE, pokreni 1 - Installation/install.sh"
ovs-vsctl br-exists "$OVS_BRIDGE" || die "Nema bridge-a $OVS_BRIDGE, pokreni 2 - Setup Lab/setup.sh"

N=$(trex_count)
for i in $(seq 1 "$N"); do
    name=$(trex_name "$i")
    ip_addr=${TREX_IPS[$((i-1))]}
    core=${TREX_CORES[$((i-1))]:-1}
    rxcore=${TREX_RX_CORES[$((i-1))]:-2}
    dest=${TREX_DEST_IPS[$((i-1))]}
    sync=$(trex_sync_port "$i")
    async=$(trex_async_port "$i")
    hveth=$(host_veth "$i")

    info "[$name] pokrecem (IP $ip_addr -> $dest, core $core, API $sync/$async)..."
    docker rm -f "$name" >/dev/null 2>&1 || true
    ovs-vsctl --if-exists del-port "$OVS_BRIDGE" "$hveth"
    ip link del "$hveth" 2>/dev/null || true

    docker run -d -t --name "$name" --hostname "$name" \
        --restart unless-stopped --privileged --stop-signal SIGINT \
        -v /dev/hugepages:/dev/hugepages \
        -v /var/run/openvswitch:/host/run/openvswitch \
        -v /proc/1/ns/net:/var/run/netns/host:ro \
        -p "${sync}:4501" -p "${async}:4500" \
        -e TREX_NAME="$name" -e TREX_IP="$ip_addr" -e TREX_DEST_IP="$dest" \
        -e TREX_CORE="$core" -e TREX_RX_CORE="$rxcore" -e TREX_MEM_MB="$TREX_MEM_MB" \
        -e OVS_BRIDGE="$OVS_BRIDGE" -e HOST_VETH="$hveth" -e PHY_IF="$PHY_IF" -e MTU="$MTU" \
        --label lab=trex \
        "$TREX_IMAGE" >/dev/null
done

info "Cekam da TRex serveri podignu API..."
for i in $(seq 1 "$N"); do
    name=$(trex_name "$i")
    up=0
    for _ in $(seq 90); do
        if docker exec "$name" ss -ltn 2>/dev/null | grep -q ':4501 '; then up=1; break; fi
        docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true || break
        sleep 1
    done
    if [ "$up" = 1 ]; then ok "[$name] API radi"; else warn "[$name] API se nije podigao, pogledaj: docker logs $name"; fi
done

HOST_IP=$(ip -4 -o addr show scope global | awk '$2 != "docker0" {split($4,a,"/"); print a[1]; exit}')
echo
echo "================ TRex lab ================"
printf "%-7s %-14s %-14s %-22s %s\n" "Ime" "Data IP" "Odrediste" "API (sync/async)" "Konzola"
for i in $(seq 1 "$N"); do
    name=$(trex_name "$i")
    printf "%-7s %-14s %-14s %-22s %s\n" "$name" "${TREX_IPS[$((i-1))]}" "${TREX_DEST_IPS[$((i-1))]}" "${HOST_IP}:$(trex_sync_port "$i")/$(trex_async_port "$i")" \
        "docker exec -it $name ./trex-console"
done
cat <<EOF

Odrediste = servis na serveru, direktna veza preko ${PHY_IF} / ${OVS_BRIDGE} (bez gateway-a)

Ulaz u kontejner:     docker exec -it trex1 bash
TRex konzola:         docker exec -it trex1 ./trex-console
Konzola sa druge masine (TRex client paket):
                      ./trex-console -s ${HOST_IP} -p $(trex_sync_port 1) --async_port $(trex_async_port 1)
Python API:           from trex.stl.api import STLClient
                      c = STLClient(server="${HOST_IP}", sync_port=$(trex_sync_port 1), async_port=$(trex_async_port 1))
Logovi:               docker logs -f trex1
Status:               ./status.sh
Zaustavljanje:        ./stop.sh      Ponovo: ./resume.sh      Brisanje: ./delete.sh
EOF

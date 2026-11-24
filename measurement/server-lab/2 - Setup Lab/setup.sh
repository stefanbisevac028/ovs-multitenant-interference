#!/bin/bash
# 2 - Setup Lab
# Podize OvS hijerarhiju kao Docker kontejnere (--restart unless-stopped, pa se
# posle restarta masine podizu sami, bez systemd servisa):
#   ovs-tier0 : agent koji na sistemskom OvS-u hosta odrzava br-tier0, SmartNIC port i pravila
#   ovs-1..N  : tier1 OvS-ovi; svaki kontejner je svoj mrezni namespace u kome rade
#               ovsdb-server i ovs-vswitchd; agent pravi br0-N, uplink ka br-tier0 i
#               veth-ove ka servisima (start.sh)
# Ako kontejneri vec postoje, prave se iznova (npr. posle izmene lab.env).
#
#   ./setup.sh
set -euo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

command -v ovs-vsctl >/dev/null || die "OvS nije instaliran, pokreni 1 - Installation/install.sh"
docker image inspect "$OVS_IMAGE" >/dev/null 2>&1 || die "Nema image-a $OVS_IMAGE, pokreni 1 - Installation/install.sh"
systemctl is-active --quiet openvswitch-switch || systemctl start openvswitch-switch
[ -f "$FLOWS_DIR/flows.txt" ] || die "Nema $FLOWS_DIR/flows.txt"

if [ -n "$PHY_IF" ]; then
    ip link show "$PHY_IF" >/dev/null 2>&1 || die "Nema interfejsa $PHY_IF"
    master=$(ip -o link show "$PHY_IF" | grep -oP 'master \K\S+' || true)
    if [ -n "$master" ] && [ "$master" != "ovs-system" ]; then
        die "$PHY_IF je u Linux bridge-u '$master'. Prvo ga ukloni: ip link set $PHY_IF nomaster"
    fi
fi
mkdir -p /run/netns

COMMON_MOUNTS=(
    -v /var/run/openvswitch:/host/run/openvswitch
    -v /run/netns:/host/run/netns
    -v /var/run/docker.sock:/var/run/docker.sock
    --mount "type=bind,src=$FLOWS_DIR,dst=/lab,readonly"
)

info "tier0: kontejner ${T0_CONTAINER} (${T0_BRIDGE} + ${PHY_IF:-bez kartice})..."
docker rm -f "$T0_CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$T0_CONTAINER" --hostname "$T0_CONTAINER" \
    --restart unless-stopped --privileged --pid host --network host \
    "${COMMON_MOUNTS[@]}" \
    -e MODE=tier0 -e T0_BRIDGE="$T0_BRIDGE" -e PHY_IF="$PHY_IF" -e MTU="$MTU" \
    -e INTERVAL="$AGENT_INTERVAL" \
    --label lab=server-lab --label role=tier0 \
    "$OVS_IMAGE" >/dev/null

for _ in $(seq 30); do ovs-vsctl br-exists "$T0_BRIDGE" 2>/dev/null && break; sleep 1; done
ovs-vsctl br-exists "$T0_BRIDGE" || die "tier0 nije napravio $T0_BRIDGE: docker logs $T0_CONTAINER"
ok "tier0 radi"

for n in $(seq 1 "$T1_COUNT"); do
    name=$(t1_name "$n")
    info "tier1: kontejner $name ($(t1_br "$n"), servisi: $(t1_services "$n"))..."
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --hostname "$name" \
        --restart unless-stopped --privileged --pid host --network none \
        "${COMMON_MOUNTS[@]}" \
        -e MODE=tier1 -e NAME="$name" -e BRIDGE="$(t1_br "$n")" \
        -e T0_BRIDGE="$T0_BRIDGE" -e T0_VETH="$(t0_veth "$n")" -e MTU="$MTU" \
        -e SERVICES="$(t1_services "$n")" -e INTERVAL="$AGENT_INTERVAL" \
        --label lab=server-lab --label role=tier1 \
        "$OVS_IMAGE" >/dev/null
done

info "Cekam da se tier1 povezu na tier0..."
for n in $(seq 1 "$T1_COUNT"); do
    name=$(t1_name "$n"); up=0
    for _ in $(seq 30); do
        if ovs-vsctl port-to-br "$(t0_veth "$n")" >/dev/null 2>&1 && \
           docker exec "$name" ovs-vsctl port-to-br uplink0 >/dev/null 2>&1; then up=1; break; fi
        running "$name" || break
        sleep 1
    done
    if [ "$up" = 1 ]; then ok "$name povezan ($(t0_veth "$n") <-> uplink0)"; else warn "$name nije spreman: docker logs $name"; fi
done

ok "Setup zavrsen."
echo "--- tier0 ${T0_BRIDGE}"; ovs-vsctl list-ports "$T0_BRIDGE" | sed 's/^/   /'
echo "Sledeci korak: ../3\ -\ Start\ Lab/start.sh"

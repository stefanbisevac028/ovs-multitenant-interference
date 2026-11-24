#!/bin/bash
# Agent u OvS kontejnerima server lab-a. Dva rezima (MODE):
#
#   tier0  - kontejner ovs-tier0 (--network host): odrzava br-tier0 na sistemskom OvS-u
#            hosta: bridge, fail_mode, SmartNIC port i OpenFlow pravila.
#   tier1  - kontejner ovs-N (--network none, svoj namespace): pokrece ovsdb-server i
#            ovs-vswitchd kao procese, pravi br0-N, uplink veth ka br-tier0 i veth-ove ka
#            svojim servisima, i primenjuje pravila.
#
# Agent u petlji (svakih INTERVAL sekundi) proverava i popravlja stanje, pa se sve samo
# ponovo poveze posle restarta bilo kog kontejnera ili cele masine.
#
# Montirano iz hosta (videti setup.sh):
#   /host/run/openvswitch  - sistemski OvS (db.sock, br-tier0.mgmt)
#   /host/run/netns        - da namespace kontejnera bude vidljiv kao "ip netns" na hostu
#   /var/run/docker.sock   - za PID servisnih kontejnera
#   /lab                   - "2 - Setup Lab" (flows.txt)
set -u

MODE="${MODE:?MODE=tier0|tier1}"
INTERVAL="${INTERVAL:-5}"
MTU="${MTU:-1500}"
T0_BRIDGE="${T0_BRIDGE:-br-tier0}"
FLOWS="/lab/flows.txt"
HOST_DB="unix:/host/run/openvswitch/db.sock"
HOST_MGMT="unix:/host/run/openvswitch/${T0_BRIDGE}.mgmt"

log()   { echo "$(date '+%F %T') [${NAME:-$MODE}] $*"; }
hvsctl(){ ovs-vsctl --timeout=5 --db="$HOST_DB" "$@"; }

wait_host_ovs() {
    until [ -S /host/run/openvswitch/db.sock ] && hvsctl show >/dev/null 2>&1; do
        log "cekam sistemski OvS na hostu..."; sleep 2
    done
}

# OpenFlow pravila: replace-flows menja samo ono sto se razlikuje (brojaci ostaju)
apply_flows() { # $1 = ovs-ofctl cilj (bridge ili unix:...mgmt)
    [ -f "$FLOWS" ] || return 0
    local sum; sum=$(md5sum < "$FLOWS")
    if [ "$sum" != "${FLOWS_SUM:-}" ] || [ "$(ovs-ofctl dump-flows "$1" 2>/dev/null | grep -c priority)" = 0 ]; then
        if ovs-ofctl replace-flows "$1" "$FLOWS"; then
            [ "$sum" != "${FLOWS_SUM:-}" ] && log "pravila primenjena iz flows.txt"
            FLOWS_SUM=$sum
        fi
    fi
}

sleep_loop() { sleep "$INTERVAL" & wait $!; }

# ------------------------------------------------------------------ tier0
run_tier0() {
    NAME="tier0"
    trap 'log "zaustavljam"; exit 0' TERM INT
    while true; do
        wait_host_ovs
        hvsctl --may-exist add-br "$T0_BRIDGE" -- set-fail-mode "$T0_BRIDGE" secure
        ip link set "$T0_BRIDGE" mtu "$MTU" up 2>/dev/null
        if [ -n "${PHY_IF:-}" ] && ip link show "$PHY_IF" >/dev/null 2>&1; then
            master=$(ip -o link show "$PHY_IF" | grep -oP 'master \K\S+' || true)
            if [ -n "$master" ] && [ "$master" != "ovs-system" ]; then
                log "UPOZORENJE: $PHY_IF je u Linux bridge-u '$master', ne dodajem ga"
            elif ! hvsctl port-to-br "$PHY_IF" >/dev/null 2>&1; then
                ip addr flush dev "$PHY_IF"
                ip link set "$PHY_IF" mtu "$MTU" up
                hvsctl --may-exist add-port "$T0_BRIDGE" "$PHY_IF" && log "$PHY_IF dodat na $T0_BRIDGE"
            fi
        fi
        apply_flows "$HOST_MGMT"
        sleep_loop
    done
}

# ------------------------------------------------------------------ tier1
start_ovs() {
    mkdir -p /var/run/openvswitch /var/log/openvswitch /etc/openvswitch
    rm -f /etc/openvswitch/conf.db
    ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
    ovsdb-server /etc/openvswitch/conf.db \
        --remote=punix:/var/run/openvswitch/db.sock \
        --pidfile=/var/run/openvswitch/ovsdb-server.pid --detach \
        --log-file=/var/log/openvswitch/ovsdb-server.log -vconsole:off
    ovs-vsctl --no-wait init
    ovs-vsctl --no-wait set Open_vSwitch . external_ids:lab=server-lab external_ids:hostname="$NAME"
    ovs-vswitchd unix:/var/run/openvswitch/db.sock \
        --pidfile=/var/run/openvswitch/ovs-vswitchd.pid --detach \
        --log-file=/var/log/openvswitch/ovs-vswitchd.log -vconsole:off
    ovs-vsctl --may-exist add-br "$BRIDGE" -- set-fail-mode "$BRIDGE" secure
    ip link set "$BRIDGE" mtu "$MTU" up
    log "ovsdb-server i ovs-vswitchd rade, bridge $BRIDGE"
}

alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

ensure_uplink() {
    if ! ip link show uplink0 >/dev/null 2>&1; then
        nsenter -t 1 -n ip link del "$T0_VETH" 2>/dev/null
        # druga strana veth-a ide direktno u namespace hosta (PID 1 hosta, --pid=host)
        ip link add uplink0 type veth peer name "$T0_VETH" netns 1 || return
        log "uplink: uplink0 <-> $T0_VETH (host)"
    fi
    nsenter -t 1 -n ip link set "$T0_VETH" mtu "$MTU" up
    hvsctl --may-exist add-port "$T0_BRIDGE" "$T0_VETH"
    ip link set uplink0 mtu "$MTU" up
    ovs-vsctl --may-exist add-port "$BRIDGE" uplink0
}

ip_to_mac() { local IFS=.; set -- $1; printf '02:00:%02x:%02x:%02x:%02x' "$1" "$2" "$3" "$4"; }

docker_pid() { # PID kontejnera preko Docker API-ja (0 ako ne radi)
    curl -s --max-time 3 --unix-socket /var/run/docker.sock "http://localhost/containers/$1/json" \
        | jq -r 'if .State.Running then .State.Pid else 0 end' 2>/dev/null || echo 0
}

ensure_services() {
    local spec name addr sv pid
    for spec in ${SERVICES:-}; do
        name=${spec%%:*}; addr=${spec#*:}; sv="s-$name"
        ip link show "$sv" >/dev/null 2>&1 && continue
        pid=$(docker_pid "$name"); [ "${pid:-0}" -gt 0 ] 2>/dev/null || continue
        ovs-vsctl --if-exists del-port "$BRIDGE" "$sv"
        nsenter -t "$pid" -n ip link del eth0 2>/dev/null
        ip link add "$sv" type veth peer name "${sv}-c" netns "$pid" || continue
        nsenter -t "$pid" -n ip link set "${sv}-c" name eth0
        # stalna MAC adresa izvedena iz IP-a (02:00:a:b:c:d): posle restarta kontejnera
        # ARP kes kod drugih servisa i TRex-a ostaje ispravan
        nsenter -t "$pid" -n ip link set eth0 address "$(ip_to_mac "${addr%/*}")"
        nsenter -t "$pid" -n ip addr add "$addr" dev eth0
        nsenter -t "$pid" -n ip link set eth0 mtu "$MTU" up
        ip link set "$sv" mtu "$MTU" up
        ovs-vsctl --may-exist add-port "$BRIDGE" "$sv" -- set interface "$sv" external_ids:container="$name"
        log "servis $name povezan ($addr, $(ip_to_mac "${addr%/*}"), $sv)"
    done
}

ensure_netns_link() { # "ip netns" na hostu vidi namespace ovog kontejnera kao $NAME
    [ -d /host/run/netns ] || return 0
    [ "$(readlink "/host/run/netns/$NAME" 2>/dev/null)" = "/proc/$$/ns/net" ] || \
        ln -sfn "/proc/$$/ns/net" "/host/run/netns/$NAME"
}

cleanup_tier1() {
    log "zaustavljam"
    hvsctl --if-exists del-port "$T0_BRIDGE" "$T0_VETH" 2>/dev/null
    [ "$(readlink "/host/run/netns/$NAME" 2>/dev/null)" = "/proc/$$/ns/net" ] && rm -f "/host/run/netns/$NAME"
    ovs-vsctl --if-exists del-br "$BRIDGE" 2>/dev/null
    for p in ovs-vswitchd ovsdb-server; do
        alive /var/run/openvswitch/$p.pid && kill "$(cat /var/run/openvswitch/$p.pid)"
    done
    exit 0
}

run_tier1() {
    : "${NAME:?}" "${BRIDGE:?}" "${T0_VETH:?}"
    trap cleanup_tier1 TERM INT
    ip link set lo up
    wait_host_ovs          # sistemski OvS = ucitan kernel modul + br-tier0 za uplink
    start_ovs
    while true; do
        for p in ovsdb-server ovs-vswitchd; do
            alive /var/run/openvswitch/$p.pid || { log "$p ne radi, izlazim (Docker restartuje kontejner)"; exit 1; }
        done
        ensure_netns_link
        hvsctl br-exists "$T0_BRIDGE" 2>/dev/null && ensure_uplink
        ensure_services
        apply_flows "$BRIDGE"
        sleep_loop
    done
}

case "$MODE" in
    tier0) run_tier0 ;;
    tier1) run_tier1 ;;
    *) echo "nepoznat MODE: $MODE"; exit 2 ;;
esac

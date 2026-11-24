#!/bin/bash
# A2 - provera da je lab u polaznom stanju (hijerarhija, bez izmena iz A0/A1/A3/A4).
# Samo cita stanje. Izlazni kod 0 = sve u redu, 1 = ima odstupanja.
#
#   ./A2_check.sh
set -uo pipefail
source "$(dirname "$0")/../lib.sh"
need_root "$@"

bad=0
fail() { warn "$*"; bad=1; }
all="0-$(($(nproc) - 1))"

[ -s "$STATE_DIR/applied" ] && fail "state/applied nije prazan: $(tr '\n' ' ' < "$STATE_DIR/applied")"
running "$T0_CONTAINER" || fail "$T0_CONTAINER ne radi"

# br-tier0: samo kartica i t0-ovs-N
want=$(printf '%s\n' "$PHY_IF" $(for n in $(tenants); do t0_veth "$n"; done) | sort)
have=$(ovs-vsctl list-ports "$T0_BRIDGE" | sort)
[ "$want" = "$have" ] || fail "portovi na $T0_BRIDGE: $(echo $have) (ocekivano: $(echo $want))"
[ "$(ovs-vsctl list-br)" = "$T0_BRIDGE" ] || fail "na hostu postoje i drugi bridge-ovi: $(ovs-vsctl list-br | tr '\n' ' ')"

for n in $(tenants); do
    c=$(t1_name "$n")
    if ! running "$c"; then fail "$c ne radi"; continue; fi
    ports=$(docker exec "$c" ovs-vsctl list-ports "$(t1_br "$n")" 2>/dev/null | tr '\n' ' ')
    [[ " $ports" == *" uplink0 "* ]] || fail "$c: nema uplink0 na $(t1_br "$n")"
    cs=$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$c")
    [ -z "$cs" ] || [ "$cs" = "$all" ] || fail "$c: cpuset=$cs"
    for f in $(ip netns exec "$c" sh -c 'ls /sys/class/net/uplink0/queues/rx-*/rps_cpus' 2>/dev/null); do
        m=$(ip netns exec "$c" cat "$f"); [ "$((16#${m//,/}))" = 0 ] || fail "$c: RPS $f=$m"
    done
    nf=$(docker exec "$c" ovs-ofctl dump-flows "$(t1_br "$n")" "cookie=$((LAT_COOKIE_BASE + n))/-1" 2>/dev/null | grep -c priority)
    [ "$nf" = 0 ] || fail "$c: postoji pravilo reflektora"
    for s in $(svc_of_tenant "$n"); do
        name=$(svc_field "$s" 1)
        [[ " $ports" == *" $(svc_veth "$name") "* ]] || fail "$c: nema $(svc_veth "$name")"
        svc_has_ip "$name" "$(svc_field "$s" 3)" || fail "$name: nema IP na eth0"
    done
done

if [ "$bad" = 0 ]; then ok "lab je u A2 (polazno stanje)"; else warn "lab NIJE u cistom A2"; fi
exit "$bad"

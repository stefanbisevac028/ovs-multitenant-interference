#!/bin/bash
# Brisanje infrastrukture (paketi i Docker image-i ostaju):
#   - brise servise, tier1 OvS kontejnere i tier0 agenta
#   - brise br-tier0 sa sistemskog OvS-a, SmartNIC se vraca kao obican interfejs
#
#   ./delete.sh [-y]
set -uo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

YES=0
for a in "$@"; do
    case "$a" in
        -y|--yes) YES=1 ;;
        *) die "Nepoznat argument: $a" ;;
    esac
done

if [ "$YES" != 1 ]; then
    echo "Brisem servise, OvS kontejnere ($T0_CONTAINER, $(t1_name 1)..$(t1_name "$T1_COUNT")) i bridge ${T0_BRIDGE}."
    read -r -p "Nastaviti? [y/N] " r
    [[ "$r" =~ ^[yY]$ ]] || { echo "Odustao."; exit 0; }
fi

rm_c() { docker inspect "$1" >/dev/null 2>&1 && { docker stop -t 20 "$1" >/dev/null; docker rm "$1" >/dev/null; ok "[$1] obrisan"; }; }

for s in "${SERVICES[@]}"; do rm_c "$(svc_field "$s" 1)"; done
for n in $(seq 1 "$T1_COUNT"); do rm_c "$(t1_name "$n")"; done
rm_c "$T0_CONTAINER"
# eventualni zaostali kontejneri lab-a (npr. servisi uklonjeni iz lab.env)
docker ps -aq --filter label=lab=server-lab | xargs -r docker rm -f >/dev/null

for n in $(seq 1 "$T1_COUNT"); do
    ip link del "$(t0_veth "$n")" 2>/dev/null || true
    [ -L "/run/netns/$(t1_name "$n")" ] && rm -f "/run/netns/$(t1_name "$n")"
done
if ovs-vsctl br-exists "$T0_BRIDGE"; then
    ovs-vsctl del-br "$T0_BRIDGE" && ok "Bridge ${T0_BRIDGE} obrisan"
fi
[ -n "$PHY_IF" ] && ip link set "$PHY_IF" up 2>/dev/null

ok "Infrastruktura obrisana. Ponovno podizanje: 2 - Setup Lab/setup.sh pa start.sh"

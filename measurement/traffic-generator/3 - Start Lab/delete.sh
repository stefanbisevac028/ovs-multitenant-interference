#!/bin/bash
# Brisanje infrastrukture (paketi ostaju instalirani):
#   - zaustavlja i brise TRex kontejnere
#   - brise OvS bridge, Mellanox se vraca kao obican interfejs
#   - oslobadja hugepages
#   - sa --image brise i TRex Docker image (posle toga ponovo 1 - Installation)
#
#   ./delete.sh [-y] [--image]
set -uo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

YES=0; RM_IMAGE=0
for a in "$@"; do
    case "$a" in
        -y|--yes) YES=1 ;;
        --image)  RM_IMAGE=1 ;;
        *) die "Nepoznat argument: $a" ;;
    esac
done

if [ "$YES" != 1 ]; then
    echo "Brisem TRex kontejnere, OvS bridge ${OVS_BRIDGE} i hugepages$( [ $RM_IMAGE = 1 ] && echo ", i image ${TREX_IMAGE}")."
    read -r -p "Nastaviti? [y/N] " r
    [[ "$r" =~ ^[yY]$ ]] || { echo "Odustao."; exit 0; }
fi

bash "$(dirname "$0")/stop.sh"
for i in $(seq 1 "$(trex_count)"); do
    docker rm "$(trex_name "$i")" >/dev/null 2>&1 && ok "[$(trex_name "$i")] obrisan"
    ovs-vsctl --if-exists del-port "$OVS_BRIDGE" "$(host_veth "$i")"
done

# eventualni zaostali kontejneri iz lab-a
docker ps -aq --filter label=lab=trex | xargs -r docker rm -f >/dev/null

if ovs-vsctl br-exists "$OVS_BRIDGE"; then
    info "Brisem OvS bridge ${OVS_BRIDGE}..."
    ovs-vsctl del-br "$OVS_BRIDGE"
fi
ip link set "$PHY_IF" up 2>/dev/null || true

info "Oslobadjam hugepages..."
echo 0 > /proc/sys/vm/nr_hugepages

if [ "$RM_IMAGE" = 1 ]; then
    info "Brisem image ${TREX_IMAGE}..."
    docker rmi "$TREX_IMAGE" >/dev/null || warn "Image nije obrisan"
fi

ok "Infrastruktura obrisana. Ponovno podizanje: 2 - Setup Lab/setup.sh pa start.sh"

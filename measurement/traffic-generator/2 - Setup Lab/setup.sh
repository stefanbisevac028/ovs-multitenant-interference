#!/bin/bash
# 2 - Setup Lab
# Podize OvS bridge i dodaje mu Mellanox karticu (i hugepages, ako je HUGEPAGES_2M > 0).
# Portovi kontejnera se dodaju na bridge u koraku 3 (start.sh).
# Idempotentno. Pokrece se samo jednom: bridge ostaje sacuvan u OvS bazi i posle restarta
# masine, a TRex kontejneri sami podizu karticu i dodaju svoje portove.
#
#   ./setup.sh
set -euo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

command -v ovs-vsctl >/dev/null || die "OvS nije instaliran, pokreni 1 - Installation/install.sh"
ip link show "$PHY_IF" >/dev/null 2>&1 || die "Nema interfejsa $PHY_IF"
systemctl is-active --quiet openvswitch-switch || systemctl start openvswitch-switch

if [ "${HUGEPAGES_2M:-0}" -gt 0 ]; then
    info "Hugepages: ${HUGEPAGES_2M} x 2MB..."
    echo "$HUGEPAGES_2M" > /proc/sys/vm/nr_hugepages
    got=$(cat /proc/sys/vm/nr_hugepages)
    [ "$got" -ge "$HUGEPAGES_2M" ] || warn "Dobijeno samo $got hugepages (trazeno $HUGEPAGES_2M)"
    ok "Hugepages: $got"
fi
mountpoint -q /dev/hugepages || mount -t hugetlbfs nodev /dev/hugepages

info "OvS bridge ${OVS_BRIDGE}..."
ovs-vsctl --may-exist add-br "$OVS_BRIDGE"
# standalone = obican L2 learning switch ako nema kontrolera
ovs-vsctl set-fail-mode "$OVS_BRIDGE" standalone

info "Dodajem ${PHY_IF} (Mellanox) na ${OVS_BRIDGE}..."
# IP adresa na fizickoj kartici nema smisla kad je u bridge-u
ip addr flush dev "$PHY_IF"
ip link set "$PHY_IF" mtu "$MTU" up
ovs-vsctl --may-exist add-port "$OVS_BRIDGE" "$PHY_IF"
ip link set "$OVS_BRIDGE" mtu "$MTU" up

ok "Setup zavrsen:"
ovs-vsctl show
ethtool "$PHY_IF" 2>/dev/null | grep -E "Speed|Link detected" | sed 's/^/   /'
echo "Sledeci korak: ../3\ -\ Start\ Lab/start.sh"

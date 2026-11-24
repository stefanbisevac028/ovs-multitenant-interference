#!/bin/bash
# 1 - Installation
# Instalira OvS, Docker i alate, pravi OvS image za tier0/tier1 kontejnere
# i skida image za servise.
# Idempotentno: moze da se pokrene vise puta.
#
#   ./install.sh
set -euo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"
HERE="$(cd "$(dirname "$0")" && pwd)"
REAL_USER="${SUDO_USER:-$USER}"

info "Instaliram sistemske pakete (OvS, alati)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q \
    openvswitch-switch openvswitch-common \
    iproute2 ethtool pciutils tcpdump jq curl ca-certificates iperf3

info "Docker..."
if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y -q docker.io
else
    ok "Docker vec postoji: $(docker --version)"
fi

# Docker ucitava br_netfilter i stavlja iptables FORWARD na DROP. To ne utice na OvS,
# ali blokira saobracaj kroz Linux bridge-ove (npr. br-phy/br-mgmt/br-of iz stare
# infrastrukture). Iskljucujemo da Linux bridge saobracaj prolazi kroz iptables.
cat > /etc/sysctl.d/90-lab-bridge-nf.conf <<'EOF'
# server-lab: Linux bridge saobracaj ne ide kroz iptables (Docker FORWARD DROP)
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-arptables = 0
EOF

systemctl enable --now docker
systemctl enable --now openvswitch-switch
modprobe br_netfilter 2>/dev/null || true
sysctl -q -p /etc/sysctl.d/90-lab-bridge-nf.conf || true

if ! id -nG "$REAL_USER" | grep -qw docker; then
    usermod -aG docker "$REAL_USER"
    warn "Korisnik $REAL_USER dodat u grupu docker (vazi od sledeceg logovanja)."
fi

info "Pravim OvS image ${OVS_IMAGE} (ovsdb-server, ovs-vswitchd, agent)..."
docker build -q -t "$OVS_IMAGE" "$HERE/ovs-image" >/dev/null

info "Skidam image za servise: ${SERVICE_IMAGE}..."
docker pull -q "$SERVICE_IMAGE"

ok "Instalacija zavrsena."
echo "   OvS:    $(ovs-vsctl --version | head -1)"
echo "   Docker: $(docker --version)"
echo "Sledeci korak: ../2\ -\ Setup\ Lab/setup.sh"

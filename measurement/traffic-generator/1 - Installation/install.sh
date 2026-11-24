#!/bin/bash
# 1 - Installation
# Instalira sve sto je potrebno za lab i pravi TRex Docker image.
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
    iproute2 ethtool pciutils tcpdump jq curl wget ca-certificates \
    python3 python3-pip

info "Docker..."
if ! command -v docker >/dev/null 2>&1; then
    apt-get install -y -q docker.io
else
    ok "Docker vec postoji: $(docker --version)"
fi
systemctl enable --now docker
systemctl enable --now openvswitch-switch

if ! id -nG "$REAL_USER" | grep -qw docker; then
    usermod -aG docker "$REAL_USER"
    warn "Korisnik $REAL_USER dodat u grupu docker (vazi od sledeceg logovanja)."
fi

info "Pravim TRex image ${TREX_IMAGE} (TRex ${TREX_VERSION})..."
if docker image inspect "$TREX_IMAGE" >/dev/null 2>&1; then
    ok "Image ${TREX_IMAGE} vec postoji (za ponovno pravljenje: docker rmi ${TREX_IMAGE})."
else
    TGZ="$HERE/trex-image/${TREX_VERSION}.tar.gz"
    if [ ! -s "$TGZ" ]; then
        info "Skidam TRex ${TREX_VERSION}..."
        # trex-tgn.cisco.com ne salje intermediate sertifikat (HydrantID Server CA O1),
        # pa ga dodajemo iz AIA adrese. Lanac se i dalje proverava do IdenTrust root-a.
        CA_BUNDLE=$(mktemp)
        cp /etc/ssl/certs/ca-certificates.crt "$CA_BUNDLE"
        curl -fsS --retry 3 http://validation.identrust.com/certs/hydrantidcaO1.p7c \
            | openssl pkcs7 -inform DER -print_certs >> "$CA_BUNDLE"
        curl -fL --retry 3 --cacert "$CA_BUNDLE" -o "$TGZ.part" \
            "https://trex-tgn.cisco.com/trex/release/${TREX_VERSION}.tar.gz"
        rm -f "$CA_BUNDLE"
        mv "$TGZ.part" "$TGZ"
    fi
    docker build --build-arg TREX_VERSION="$TREX_VERSION" -t "$TREX_IMAGE" "$HERE/trex-image"
fi

ok "Instalacija zavrsena."
echo "   OvS:    $(ovs-vsctl --version | head -1)"
echo "   Docker: $(docker --version)"
echo "   Image:  $(docker image inspect -f '{{.RepoTags}} {{.Size}}B' "$TREX_IMAGE")"
echo "Sledeci korak: ../2\ -\ Setup\ Lab/setup.sh"

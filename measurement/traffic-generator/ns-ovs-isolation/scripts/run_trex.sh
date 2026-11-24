#!/bin/bash
# Pokrece ns-ovs-isolation TRex skripte u kontejneru trexN. Skripta ide preko stdin-a
# (docker exec -i ... python3 -), pa se nista ne kopira u kontejner. src/dst se uzimaju iz
# ../../lab.env (TREX_IPS, TREX_DEST_IPS). Rezultat (jedan JSON red) ide na stdout.
#
#   ./run_trex.sh lat <N> [argumenti trex_latency.py]    merenje latencije
#   ./run_trex.sh flow  <N> --pps P [argumenti trex_flow.py] jedan fiksni UDP tok
#   ./run_trex.sh e2  <N> --intensity X --duration D [--out f.json]   korisnicki profil e2_profile.py
#   ./run_trex.sh e3  <N> --intensity X --duration D [--out f.json]   korisnicki profil e3_profile.py
#   ./run_trex.sh mac <N>                                MAC adresa eth1 u trexN (za lat_reflect.sh)
#
# E2/E3 profile pise korisnik; ugovor (argumenti i JSON polja) je u INTERFACE.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/../../lab.env"

cmd=${1:?lat|flow|e2|e3|mac}; n=${2:?broj TRex kontejnera (1..3)}; shift 2
c="${CONTAINER_PREFIX}${n}"
src=${TREX_IPS[$((n - 1))]}; dst=${TREX_DEST_IPS[$((n - 1))]}

in_trex() { # $1 = skripta na hostu, ostalo = argumenti; izvrsava se u trexN preko stdin-a
    local script=$1; shift
    sudo docker exec -i "$c" python3 - "$@" < "$script"
}

profile() { # E2/E3: korisnicki profil, isti raspored rezultata kao flow (jedan JSON red)
    local script="$HERE/$1" out="" args=()
    [ -f "$script" ] || { echo "nema $script (pise ga korisnik, videti INTERFACE.md)" >&2; exit 1; }
    shift
    while [ $# -gt 0 ]; do
        if [ "$1" = "--out" ]; then out=$2; shift 2; else args+=("$1"); shift; fi
    done
    if [ -n "$out" ]; then
        in_trex "$script" --src "$src" --dst "$dst" "${args[@]}" --out /dev/stdout > "$out"
    else
        in_trex "$script" --src "$src" --dst "$dst" "${args[@]}" --out /dev/stdout
    fi
}

case "$cmd" in
    lat) in_trex "$HERE/trex_latency.py" --src "$src" --dst "$dst" "$@" ;;
    flow) in_trex "$HERE/trex_flow.py" --src "$src" --dst "$dst" "$@" ;;
    e2)  profile e2_profile.py "$@" ;;
    e3)  profile e3_profile.py "$@" ;;
    mac) sudo docker exec "$c" cat /sys/class/net/eth1/address ;;
    *) echo "nepoznata komanda: $cmd" >&2; exit 2 ;;
esac

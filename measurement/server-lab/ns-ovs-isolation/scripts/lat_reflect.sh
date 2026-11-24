#!/bin/bash
# Reflektor za latency tok (trex_latency.py na traffic-generator-u). OpenFlow pravilo na bridge-u
# ispred servisa tenanta N vraca UDP pakete latency toka (dst = IP servisa, port LAT_PORT) nazad
# ka TRex-u: menja MAC i IP adrese i salje paket na ulazni port. Payload i IP ID ostaju isti, pa
# TRex paket prepoznaje kao svoj. Meri se RTT kroz OvS putanju (u A2-A4 tier0 + tier1), bez
# mreznog steka servisa.
#
# OVO MENJA STANJE LABA (jedno pravilo na bridge-u), zato je podrazumevano dry-run.
# Pravilo ima cookie LAT_COOKIE_BASE+N i prioritet 200 (iznad flows.txt); del ga brise po cookie-ju.
# Agent ga ne dira dok se flows.txt ne promeni; posle restarta ovs-N pravila nema.
#
#   ./lat_reflect.sh add <N> <trex_mac> [trex_ip] [--apply]
#   ./lat_reflect.sh del <N> [--apply]
#   ./lat_reflect.sh show <N>
set -uo pipefail
source "$(dirname "$0")/../lib.sh"
need_root "$@"
parse_apply "$@"
mapfile -t ARGS < <(args_no_apply "$@")
cmd=${ARGS[0]:-}; n=${ARGS[1]:-}
[ -n "$cmd" ] && [ -n "$n" ] || { echo "upotreba: $0 add|del|show <N> [trex_mac] [trex_ip] [--apply]"; exit 2; }

ck=$(printf '0x%x' $((LAT_COOKIE_BASE + n)))
spec=$(svc_of_tenant "$n"); [ -n "$spec" ] || die "tenant $n nema servis"
svc_ip=$(svc_field "$spec" 3); svc_mac=$(ip_to_mac "$svc_ip")

# bridge ispred servisa i ulazni port zavise od varijante
case "$(current_variant)" in
    A0) OF=(ovs-ofctl); BR=$T0_BRIDGE; INP=$PHY_IF ;;
    A1) OF=(ovs-ofctl); BR="br-a1-$n"
        if [ "$A1_LINK" = veth ]; then INP="a1v-$n"; else INP="a1p-$n"; fi ;;
    *)  OF=(docker exec "$(t1_name "$n")" ovs-ofctl); BR=$(t1_br "$n"); INP=uplink0 ;;
esac

case "$cmd" in
    add)
        tmac=${ARGS[2]:?MAC adresa eth1 u trexN (traffic-generator: scripts/run_trex.sh mac N)}
        tip=${ARGS[3]:-${TREX_IPS[$((n - 1))]}}
        run "${OF[@]}" add-flow "$BR" \
            "cookie=$ck,priority=200,in_port=$INP,udp,nw_dst=$svc_ip,tp_dst=$LAT_PORT,actions=set_field:$tmac->eth_dst,set_field:$svc_mac->eth_src,set_field:$svc_ip->ip_src,set_field:$tip->ip_dst,in_port"
        ;;
    del)  run "${OF[@]}" del-flows "$BR" "cookie=$ck/-1" ;;
    show) "${OF[@]}" dump-flows "$BR" "cookie=$ck/-1" ;;
    *) die "nepoznata komanda: $cmd" ;;
esac

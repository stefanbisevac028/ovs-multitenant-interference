#!/bin/bash
# Interferencija - preopterecenje brze putanje, varijanta A2 (pokrece se sa servera ili radne stanice).
# Opterecujuci tenant 1 (trex1 -> svc1) salje jedan fiksni UDP tok (64 B) intenziteta P pps.
# Posmatrani tenanti 2 i 3 salju pozadinski tok (BG_PPS, 64 B) i latency tok (LAT_PPS) kroz
# reflektor, koji postoji samo za vreme merenja. P = 0 je osnovna linija (bez opterecujuceg).
#
# Konfiguracija RSS redova se bira izvornim portovima (mapa: results/raw/rss_map.csv):
#   same: tok opterecujuceg i tokovi posmatranih u ISTOM redu kartice
#   diff: tok opterecujuceg u redu u kome nije nijedan tok posmatranih
#
#   ./run_interference.sh <konfiguracija> [intenziteti] [ponavljanja] [trajanje_s]
#   ./run_interference.sh same "0 25000 50000 100000 150000 200000 300000 450000" "$(seq -s ' ' 1 10)" 20
#
# Izvorni portovi po konfiguraciji su u interference_ports.env (L_SPORT, T2_BG, T2_LAT, T3_BG, T3_LAT).
set -u
# Radi i sa radne stanice i sa servera: na serveru ($SRV_HOSTNAME) koraci za server idu lokalno, a ka
# generatoru preko SSH-a kljucem $SSH_KEY (ako postoji). Keepalive prekida zaglavljenu vezu.
HERE="$(cd "$(dirname "$0")" && pwd)"
KA="-o ServerAliveInterval=10 -o ServerAliveCountMax=3 -o BatchMode=yes"
# Adrese laboratorije se zadaju promenljivim okruzenja (vrednosti ispod su primeri):
SRV_HOST=${SRV_HOST:-user@server}; GEN_HOST=${GEN_HOST:-user@generator}
SRV_HOSTNAME=${SRV_HOSTNAME:-server}; SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}
if [ "$(hostname)" = "$SRV_HOSTNAME" ]; then
  cd "$HOME"; RS="bash -c"
  TG="$KA $( [ -f "$SSH_KEY" ] && echo "-i $SSH_KEY" ) $GEN_HOST"
else
  RS="ssh $KA $SRV_HOST"; TG="$KA $GEN_HOST"
fi
SD=server-lab/ns-ovs-isolation
TD=traffic-generator/ns-ovs-isolation
CFG=${1:?same|diff}
RATES=${2:-"0 25000 50000 100000 150000 200000 300000 450000"}
REPS=${3:-"$(seq -s ' ' 1 10)"}
DUR=${4:-20}
BG_PPS=20000; LAT_PPS=1000; FRAME=64          # okvir posmatranih (pozadinski tok)
L_FRAME=${L_FRAME:-64}; L_PROTO=${L_PROTO:-udp}   # okvir i protokol opterecujuceg toka (revizija 2)
PRE=2; POST=3; PAUSE=3
source "$HERE/interference_ports.env"
eval "L_SPORT=\$${CFG}_L_SPORT T2_BG=\$${CFG}_T2_BG T2_LAT=\$${CFG}_T2_LAT T3_BG=\$${CFG}_T3_BG T3_LAT=\$${CFG}_T3_LAT"
BG_MBPS=$(python3 -c "print(round($BG_PPS * $FRAME * 8 / 1e6, 4))")
OBS="2 3"
VARIANT=${VARIANT:-A2}   # samo oznaka u imenu i u interference_runs.csv; varijantu postavlja run_all.sh

cleanup() { for n in $OBS; do $RS "cd $SD && sudo scripts/lat_reflect.sh del $n --apply" >/dev/null; done; }
trap 'cleanup; exit 1' INT TERM

[ "$VARIANT" = A2 ] && { $RS "cd $SD && sudo variants/A2_check.sh" || { echo "lab nije u A2, prekidam"; exit 1; }; }
$RS "cd $SD && [ -f results/raw/interference_runs.csv ] || echo 'name,variant,cfg,load_pps,rep,start_utc,status' > results/raw/interference_runs.csv"
mac_of() { ssh $TG "cd $TD/scripts && ./run_trex.sh mac $1"; }   # bash 3.2 (macOS): bez asocijativnih nizova
MAC2=$(mac_of 2); MAC3=$(mac_of 3)

for rep in $REPS; do
  # slucajan redosled intenziteta u svakom ponavljanju
  for P in $(printf '%s\n' $RATES | python3 -c "import sys,random;l=sys.stdin.read().split();random.shuffle(l);print(' '.join(l))"); do
    name="intf_${VARIANT}_${CFG}_p${P}_r${rep}"
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$(date +%H:%M:%S)] $name"
    for n in $OBS; do
      $RS "cd $SD && sudo scripts/lat_reflect.sh add $n $(eval echo \$MAC$n) --apply" >/dev/null || { echo "reflektor nije dodat"; cleanup; exit 1; }
    done
    $RS "cd $SD && rm -rf results/raw/$name && (sudo nohup scripts/run_measure.sh $name $((PRE + DUR + POST)) 0.5 1 > logs/$name.log 2>&1 &)"
    sleep $PRE
    LOAD=""
    [ "$P" != 0 ] && LOAD="./run_trex.sh flow 1 --pps $P --frame $L_FRAME --proto $L_PROTO --duration $DUR --sport $L_SPORT --label $name > ../results/raw/${name}_t1.json 2> ../logs/${name}_t1.err &"
    ssh $TG "cd $TD/scripts || exit 1; $LOAD
      ./run_trex.sh lat 2 --duration $DUR --lat-pps $LAT_PPS --lat-sport $T2_LAT --bg-mbps $BG_MBPS --bg-frame $FRAME --bg-sport $T2_BG --label $name > ../results/raw/${name}_t2.json 2> ../logs/${name}_t2.err &
      ./run_trex.sh lat 3 --duration $DUR --lat-pps $LAT_PPS --lat-sport $T3_LAT --bg-mbps $BG_MBPS --bg-frame $FRAME --bg-sport $T3_BG --label $name > ../results/raw/${name}_t3.json 2> ../logs/${name}_t3.err &
      wait"
    cleanup
    sleep $((POST + 1))
    st=ok
    for t in 2 3; do ssh $TG "test -s $TD/results/raw/${name}_t$t.json" || st="${st}_missing_t$t"; done
    [ "$P" != 0 ] && { ssh $TG "test -s $TD/results/raw/${name}_t1.json" || st="${st}_missing_t1"; }
    $RS "test -s $SD/results/raw/$name/cpu.jsonl" || st="${st}_missing_server"
    $RS "echo '$name,$VARIANT,$CFG,$P,$rep,$start,$st' >> $SD/results/raw/interference_runs.csv"
    for t in 2 3; do
      ssh $TG "python3 -c \"import json;d=json.load(open('$TD/results/raw/${name}_t$t.json'));l=d['lat_us'];print('   t$t loss', d['lat_loss_pct'], '% p50', l.get('p50'), 'p99', l.get('p99'))\"" 2>/dev/null
    done
    echo "   status: $st"
    sleep $PAUSE
  done
done
[ "$VARIANT" = A2 ] && $RS "cd $SD && sudo variants/A2_check.sh"
echo "GOTOVO $(date)"

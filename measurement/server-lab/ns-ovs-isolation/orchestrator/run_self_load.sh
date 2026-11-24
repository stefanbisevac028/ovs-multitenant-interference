#!/bin/bash
# Samoopterecenje - kontrola (recenzija K7): opterecujuci tenant 1 SAM, bez posmatranih tenanata.
# trex1 salje pozadinski tok P pps (64 B, isti izvorni port kao u merenju interferencije) i latency tok kroz reflektor
# na tenantu 1 (samo za vreme merenja). Razlika izmedju merenja interferencije i samoopterecenja je interferencija, a ne zasicenje kutije.
#
#   VARIANT=A2n CFG=same ./run_self_load.sh [intenziteti] [ponavljanja] [trajanje_s]
set -u
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
RATES=${1:-"50000 100000 150000 200000 300000 450000"}
REPS=${2:-"$(seq -s ' ' 1 10)"}
DUR=${3:-15}
VARIANT=${VARIANT:-A2}; CFG=${CFG:-same}
LAT_PPS=1000; FRAME=64; N=1
PRE=2; POST=3; PAUSE=3
source "$HERE/interference_ports.env"
eval "L_SPORT=\$${CFG}_L_SPORT"

cleanup() { $RS "cd $SD && sudo scripts/lat_reflect.sh del $N --apply" >/dev/null; }
trap 'cleanup; exit 1' INT TERM
$RS "cd $SD && [ -f results/raw/self_load_runs.csv ] || echo 'name,variant,cfg,load_pps,rep,start_utc,status' > results/raw/self_load_runs.csv"
MAC=$(ssh -n $TG "cd $TD/scripts && ./run_trex.sh mac $N")

for rep in $REPS; do
  for P in $(printf '%s\n' $RATES | python3 -c "import sys,random;l=sys.stdin.read().split();random.shuffle(l);print(' '.join(l))"); do
    name="self_${VARIANT}_${CFG}_p${P}_r${rep}"
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$(date +%H:%M:%S)] $name"
    MBPS=$(python3 -c "print(round($P * $FRAME * 8 / 1e6, 4))")
    $RS "cd $SD && sudo scripts/lat_reflect.sh add $N $MAC --apply" >/dev/null || { echo "reflektor nije dodat"; exit 1; }
    $RS "cd $SD && rm -rf results/raw/$name && (sudo nohup scripts/run_measure.sh $name $((PRE + DUR + POST)) 0.5 1 > logs/$name.log 2>&1 &)"
    sleep $PRE
    ssh -n $TG "cd $TD/scripts && ./run_trex.sh lat $N --duration $DUR --lat-pps $LAT_PPS --bg-mbps $MBPS --bg-frame $FRAME --bg-sport $L_SPORT --label $name > ../results/raw/$name.json 2> ../logs/$name.err"
    cleanup
    sleep $((POST + 1))
    st=ok
    ssh -n $TG "test -s $TD/results/raw/$name.json" || st=missing_client
    $RS "test -s $SD/results/raw/$name/cpu.jsonl" || st="${st}_missing_server"
    $RS "echo '$name,$VARIANT,$CFG,$P,$rep,$start,$st' >> $SD/results/raw/self_load_runs.csv"
    echo "   status: $st"
    sleep $PAUSE
  done
done
echo "GOTOVO $(date)"

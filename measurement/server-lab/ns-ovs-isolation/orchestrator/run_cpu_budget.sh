#!/bin/bash
# CPU budzet - cena hijerarhije blize zasicenju (pokrece se sa servera ili radne stanice). Samo tenant 1, jedan
# fiksni UDP tok (trex_flow.py, bez latency toka, pa generator dostize vise pps nego uz latency tok), bez
# reflektora. Na serveru run_measure.sh daje CPU po sloju i po paketu.
#
#   VARIANT=A2 ./run_cpu_budget.sh [intenziteti] [ponavljanja] [trajanje_s] [okvir]
#   VARIANT=A2 ./run_cpu_budget.sh "100000 150000 200000 250000" "$(seq -s ' ' 1 10)" 15 64
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
RATES=${1:-"100000 150000 200000 250000"}
REPS=${2:-"$(seq -s ' ' 1 10)"}
DUR=${3:-15}
F=${4:-64}
VARIANT=${VARIANT:-A2}
PRE=2; POST=3; PAUSE=3

$RS "cd $SD && [ -f results/raw/cpu_budget_runs.csv ] || echo 'name,variant,frame,pps,rep,start_utc,status' > results/raw/cpu_budget_runs.csv"
for rep in $REPS; do
  for P in $(printf '%s\n' $RATES | python3 -c "import sys,random;l=sys.stdin.read().split();random.shuffle(l);print(' '.join(l))"); do
    name="budget_${VARIANT}_f${F}_p${P}_r${rep}"
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "[$(date +%H:%M:%S)] $name"
    $RS "cd $SD && rm -rf results/raw/$name && (sudo nohup scripts/run_measure.sh $name $((PRE + DUR + POST)) 0.5 1 > logs/$name.log 2>&1 &)"
    sleep $PRE
    ssh $TG "cd $TD/scripts && ./run_trex.sh flow 1 --pps $P --frame $F --duration $DUR --label $name > ../results/raw/$name.json 2> ../logs/$name.err"
    sleep $((POST + 1))
    st=ok
    ssh $TG "test -s $TD/results/raw/$name.json" || st=missing_client
    $RS "test -s $SD/results/raw/$name/cpu.jsonl" || st="${st}_missing_server"
    $RS "echo '$name,$VARIANT,$F,$P,$rep,$start,$st' >> $SD/results/raw/cpu_budget_runs.csv"
    echo "   status: $st"
    sleep $PAUSE
  done
done
echo "GOTOVO $(date)"

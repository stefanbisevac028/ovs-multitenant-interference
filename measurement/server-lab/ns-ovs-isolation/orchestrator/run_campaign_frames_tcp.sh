#!/bin/bash
# Revizija 2 (22. 11. 2026, odgovor na recenzije): dopunska kampanja, pokrece se NA SERVERU (nohup setsid),
# sama upravlja generatorom preko SSH kljuca ($SSH_KEY, vidi run_interference.sh). Ne zavisi od radne stanice.
#
#  (b) velicina okvira opterecujuceg toka 512 i 1400 B: uzak RPS, isti red, A0/A2/A4   (oznaka A2n_f512 ...)
#  (c) TCP segmenti opterecujuceg toka (64 B, RST zastavica): uzak RPS, isti red, A0/A2/A4 (oznaka A2n_tcp)
#  (a) celija koja nedostaje: sirok RPS, razliciti redovi, A0-A4                         (oznaka A2w, cfg diff)
# Posmatrani tenanti kao u merenju interferencije (pozadinski 20 kpps 64 B + latency 1000 pps UDP).
# Svaka varijanta: setup -> merenja -> restore_A2 -> A2_check; na kraju RPS kartice iz state/nic_pre_kampanja.txt.
#
#   ./run_campaign_frames_tcp.sh [ponavljanja] [trajanje_s]      (smoke: SMOKE=1 ./run_campaign_frames_tcp.sh "1" 10)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(hostname)" = "${SRV_HOSTNAME:-server}" ] || { echo "pokrece se samo na serveru"; exit 1; }
cd "$HOME"; RS="bash -c"
SD=server-lab/ns-ovs-isolation
REPS=${1:-"$(seq -s ' ' 1 10)"}
DUR=${2:-15}
INTF_RATES="0 50000 100000 150000 200000 300000 450000"
SUB_RATES="0 150000 300000 450000"
VSUB="A2 A4 A0"
VALL="A2 A3 A4 A1 A0"
PFX=""   # smoke merenja dobijaju prefiks SMK u oznaci, da se ne mesaju sa kampanjom
if [ "${SMOKE:-0}" = 1 ]; then INTF_RATES="300000"; SUB_RATES="300000"; VSUB="A2"; VALL="A2"; PFX="SMK"; fi

restore() { $RS "cd $SD && sudo variants/restore_A2.sh --all --apply"; }
check()   { $RS "cd $SD && sudo variants/A2_check.sh"; }
nic()     { $RS "cd $SD && sudo scripts/nic_rps.sh $1 --apply"; }
finish()  { restore; nic restore; check; }
trap 'echo "prekid"; finish; exit 1' INT TERM
setupv()  { case $1 in A0) S=A0_flat.sh ;; A1) S=A1_bridges.sh ;; A3) S=A3_cpuset.sh ;; A4) S=A4_rps.sh ;; A2) S="" ;; esac
            if [ -n "$S" ]; then $RS "cd $SD && sudo variants/$S setup --apply" || { echo "setup $1 nije uspeo"; finish; exit 1; }; sleep 5; fi; }
backv()   { if [ "$1" != A2 ]; then restore || { echo "teardown $1 nije uspeo"; finish; exit 1; }; fi
            check || { echo "lab nije u A2, prekidam"; finish; exit 1; }; }

check || { echo "lab nije u A2 na pocetku"; exit 1; }
[ -f "$HOME/$SD/state/nic_pre_kampanja.txt" ] || nic save || exit 1

# (b) + (c): uzak RPS
nic narrow || { finish; exit 1; }
for V in $VSUB; do
  echo "================ ${V}n okviri/TCP $(date) ================"
  setupv $V
  for F in 512 1400; do
    VARIANT=${PFX}${V}n_f$F L_FRAME=$F "$HERE/run_interference.sh" same "$SUB_RATES" "$REPS" $DUR
  done
  VARIANT=${PFX}${V}n_tcp L_PROTO=tcp "$HERE/run_interference.sh" same "$SUB_RATES" "$REPS" $DUR
  backv $V
done

# (a): sirok RPS, razliciti redovi
nic wide || { finish; exit 1; }
for V in $VALL; do
  echo "================ ${V}w razliciti redovi $(date) ================"
  setupv $V
  VARIANT=${PFX}${V}w "$HERE/run_interference.sh" diff "$INTF_RATES" "$REPS" $DUR
  backv $V
done

nic restore
check
echo "SVE GOTOVO $(date)"

#!/bin/bash
# Revizija po recenziji (18. 11. 2026): nova kampanja, pokrece se NA SERVERU (nohup setsid), sama
# upravlja generatorom preko SSH kljuca ($SSH_KEY, vidi run_interference.sh). Ne zavisi od radne stanice.
#
# Faktori: RPS na kartici (n = uzak 0000, w = sirok ffff) x varijanta A0-A4 (A4 = RPS na uplink0).
#   n: interferencija (isti red, razliciti redovi); samoopterecenje (A0, A2, A4); CPU budzet (A0, A1, A2)
#   w: interferencija (isti red; red kartice ne odredjuje procesor kad je RPS sirok)
# Oznaka varijante u imenu merenja: <varijanta><n|w>, npr. A2n. K2: cpuset/RPS tenanata iz ns.env
# (t1 {4,12}, t2 {5,13}, t3 {6,14}). Prstenovi i coalescing se ne menjaju.
# Pre pocetka: stanje kartice u state/nic_pre_kampanja.txt; na kraju: RPS vracen iz njega, lab u A2.
# Svaka varijanta: setup -> merenja -> restore_A2 -> A2_check; greska -> vracanje i prekid.
#
#   ./run_campaign.sh [ponavljanja] [trajanje_s]      (smoke: SMOKE=1 ./run_campaign.sh "1" 10)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(hostname)" = "${SRV_HOSTNAME:-server}" ] || { echo "pokrece se samo na serveru"; exit 1; }
cd "$HOME"; RS="bash -c"
SD=server-lab/ns-ovs-isolation
REPS=${1:-"$(seq -s ' ' 1 10)"}
DUR=${2:-15}
INTF_RATES="0 50000 100000 150000 200000 300000 450000"
SELF_RATES="50000 100000 150000 200000 300000 450000"
BUDGET_RATES="100000 150000 200000 250000"
VARIANTS="A2 A3 A4 A1 A0"
RPSSET="n w"
if [ "${SMOKE:-0}" = 1 ]; then INTF_RATES="0 200000"; SELF_RATES="200000"; BUDGET_RATES="150000"; VARIANTS="A2 A4"; RPSSET="n"; fi

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
for R in $RPSSET; do
  case $R in n) nic narrow ;; w) nic wide ;; esac || { finish; exit 1; }
  for V in $VARIANTS; do
    L="$V$R"
    echo "================ $L $(date) ================"
    setupv $V
    VARIANT=$L "$HERE/run_interference.sh" same "$INTF_RATES" "$REPS" $DUR
    if [ $R = n ]; then
      VARIANT=$L "$HERE/run_interference.sh" diff "$INTF_RATES" "$REPS" $DUR
      case $V in A0|A2|A4) VARIANT=$L CFG=same "$HERE/run_self_load.sh" "$SELF_RATES" "$REPS" $DUR ;; esac
      case $V in A0|A1|A2) VARIANT=$L "$HERE/run_cpu_budget.sh" "$BUDGET_RATES" "$REPS" $DUR 64 ;; esac
    fi
    backv $V
  done
done
nic restore
check
echo "SVE GOTOVO $(date)"

#!/bin/bash
# RPS na redovima fizicke kartice kao faktor eksperimenta (recenzija K3).
#   uzak  = 0000 (softirq ostaje na jezgru reda, IRQ rxtx-N -> CPU N)
#   sirok = ffff (procesor bira RPS hes toka; zateceno stanje pri prvim merenjima)
# Prstenovi, kanali i coalescing se NE menjaju. Bez --apply samo ispisuje komande (dry-run).
#
#   ./nic_rps.sh save [--apply]        upisi trenutno stanje kartice u state/nic_pre_kampanja.txt
#   ./nic_rps.sh narrow|wide [--apply] postavi RPS na svim redovima
#   ./nic_rps.sh restore [--apply]     vrati RPS iz state/nic_pre_kampanja.txt
#   ./nic_rps.sh show
set -uo pipefail
source "$(dirname "$0")/../lib.sh"
need_root "$@"
parse_apply "$@"
SAVED="$STATE_DIR/nic_pre_kampanja.txt"
Q=(/sys/class/net/$PHY_IF/queues/rx-*/rps_cpus)

show() { for f in "${Q[@]}"; do echo "$f $(cat "$f")"; done; }
set_all() { local f; for f in "${Q[@]}"; do run_sh "echo $1 > $f"; done; [ "$APPLY" = 1 ] && show; return 0; }

case "${1:-}" in
    save)
        if [ "$APPLY" = 1 ]; then
            mkdir -p "$STATE_DIR"
            [ -f "$SAVED" ] && die "$SAVED vec postoji (ne prepisujem)"
            { show; echo "### ethtool -g"; ethtool -g "$PHY_IF"; echo "### ethtool -c"; ethtool -c "$PHY_IF"; echo "### ethtool -i"; ethtool -i "$PHY_IF"; } > "$SAVED"
            ok "sacuvano: $SAVED"
        else echo "[dry-run] sacuvao bih stanje u $SAVED"; fi ;;
    narrow) set_all 0 ;;
    wide)   set_all ffff ;;
    restore)
        [ -f "$SAVED" ] || die "nema $SAVED"
        while read -r f v; do [ -f "$f" ] && run_sh "echo $v > $f"; done < <(grep "^/sys/" "$SAVED")
        [ "$APPLY" = 1 ] && show ;;
    show) show ;;
    *) echo "upotreba: $0 save|narrow|wide|restore|show [--apply]"; exit 2 ;;
esac

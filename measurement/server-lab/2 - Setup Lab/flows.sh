#!/bin/bash
# OpenFlow pravila su u flows.txt (isti folder). Agenti u OvS kontejnerima ih primenjuju
# sami, za nekoliko sekundi posle izmene fajla. Ova skripta sluzi za pregled i za
# trenutnu primenu.
#
#   ./flows.sh show       # prikazi trenutna pravila na svim bridge-ovima
#   ./flows.sh apply      # primeni flows.txt odmah (bez cekanja agenata)
set -euo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"
FLOWS="$FLOWS_DIR/flows.txt"

case "${1:-show}" in
    show)
        echo "--- tier0 ${T0_BRIDGE}"
        ovs-ofctl dump-flows "$T0_BRIDGE" --no-stats 2>/dev/null || warn "nema $T0_BRIDGE"
        for n in $(seq 1 "$T1_COUNT"); do
            echo "--- tier1 $(t1_name "$n")/$(t1_br "$n")"
            docker exec "$(t1_name "$n")" ovs-ofctl dump-flows "$(t1_br "$n")" --no-stats 2>/dev/null || warn "$(t1_name "$n") ne radi"
        done
        ;;
    apply)
        ovs-ofctl replace-flows "$T0_BRIDGE" "$FLOWS" && ok "tier0 ${T0_BRIDGE}"
        for n in $(seq 1 "$T1_COUNT"); do
            docker exec "$(t1_name "$n")" ovs-ofctl replace-flows "$(t1_br "$n")" /lab/flows.txt \
                && ok "tier1 $(t1_name "$n")" || warn "$(t1_name "$n") ne radi"
        done
        ;;
    *) die "Upotreba: $0 [show|apply]" ;;
esac

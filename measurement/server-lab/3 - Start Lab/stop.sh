#!/bin/bash
# Zaustavlja lab bez brisanja: servisi, pa tier1 i tier0 kontejneri dobijaju SIGTERM i
# uredno se gase (agenti skidaju svoje portove sa br-tier0). Zaustavljeni kontejneri
# se NE podizu sami posle restarta masine (unless-stopped). Ponovno pokretanje: ./resume.sh
#
#   ./stop.sh            # sve (servisi + OvS kontejneri)
#   ./stop.sh services   # samo servisi, OvS-ovi rade dalje
set -uo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

stop_c() { running "$1" && { docker stop -t 20 "$1" >/dev/null && ok "[$1] zaustavljen"; }; }

for s in "${SERVICES[@]}"; do stop_c "$(svc_field "$s" 1)"; done
[ "${1:-}" = "services" ] && exit 0
for n in $(seq 1 "$T1_COUNT"); do stop_c "$(t1_name "$n")"; done
stop_c "$T0_CONTAINER"
ok "Lab zaustavljen (kontejneri postoje). Ponovno pokretanje: ./resume.sh"

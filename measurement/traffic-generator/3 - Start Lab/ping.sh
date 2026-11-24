#!/bin/bash
# Ping iz svakog TRex kontejnera ka njegovom servisu (TREX_DEST_IPS u lab.env).
# Koristi trex-console u batch rezimu: service -> arp (osvezi MAC servisa) -> ping -> service --off.
#
#   ./ping.sh            # sva tri: trex1->svc1, trex2->svc2, trex3->svc3, po 3 paketa
#   ./ping.sh 2          # samo trex2
#   ./ping.sh all 10     # sva tri, po 10 paketa
set -uo pipefail
source "$(dirname "$0")/../common.sh"
need_root "$@"

WHICH="${1:-all}"
COUNT="${2:-3}"
N=$(trex_count)
[ "$WHICH" = all ] && list=$(seq 1 "$N") || list="$WHICH"

rc=0
for i in $list; do
    name=$(trex_name "$i")
    dest=${TREX_DEST_IPS[$((i-1))]}
    echo "=== $name (${TREX_IPS[$((i-1))]}) -> $dest, $COUNT paketa"
    out=$(docker exec "$name" bash -c "printf 'service\narp -p 0\nping -p 0 -d $dest -n $COUNT\nservice --off\n' > /tmp/ping.batch; timeout 60 ./trex-console -f --batch /tmp/ping.batch" 2>&1 | sed "s/\x1b\[[0-9;]*[a-zA-Z]//g")
    replies=$(echo "$out" | grep -c "Reply from")
    echo "$out" | grep -E "Reply from|timed out|rror" | sed 's/^/   /'
    if [ "$replies" -gt 0 ]; then ok "$name: $replies/$COUNT odgovora"; else warn "$name: nema odgovora"; rc=1; fi
done
exit $rc

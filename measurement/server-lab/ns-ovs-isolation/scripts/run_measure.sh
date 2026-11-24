#!/bin/bash
# Jedno merenje na serveru (samo cita stanje sistema):
#   - CPU po OvS instanci: ../tools/ovs_instance_cpu.py (eBPF)
#   - periodicni snimci OvS stanja po instanci: ovs_snapshot.py
#   - konfiguracija u trenutku merenja: ovs_snapshot.py --meta
# Rezultati: results/raw/<ime>/{meta.json, cpu.jsonl, ovs.jsonl, *.log}
#
#   ./run_measure.sh <ime> <trajanje_s> [cpu_interval_s=0.5] [snap_interval_s=1]
#
# Ctrl+C (ili SIGTERM) zaustavlja oba procesa uredno.
set -uo pipefail
source "$(dirname "$0")/../lib.sh"
need_root "$@"

name=${1:?ime merenja}; dur=${2:?trajanje u s}; ci=${3:-0.5}; si=${4:-1}
out="$RESULTS_DIR/$name"
[ -e "$out" ] && die "$out vec postoji"
mkdir -p "$out"
CPU_TOOL="${CPU_TOOL:-$NS_DIR/tools/ovs_instance_cpu.py}"
[ -f "$CPU_TOOL" ] || die "nema $CPU_TOOL"

python3 "$NS_DIR/scripts/ovs_snapshot.py" --meta > "$out/meta.json"
python3 "$CPU_TOOL" -i "$ci" -d "$dur" -q -o "$out/cpu.jsonl" > "$out/cpu.log" 2>&1 &
cpu_pid=$!
python3 "$NS_DIR/scripts/ovs_snapshot.py" -i "$si" -d "$dur" -o "$out/ovs.jsonl" > "$out/snap.log" 2>&1 &
snap_pid=$!
trap 'kill -INT $cpu_pid $snap_pid 2>/dev/null' INT TERM
wait $cpu_pid; wait $snap_pid
chown -R "${SUDO_USER:-$(id -un)}:" "$out"
ok "rezultati: $out ($(wc -l < "$out/cpu.jsonl") CPU uzoraka, $(wc -l < "$out/ovs.jsonl") OvS snimaka)"

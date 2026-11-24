#!/bin/bash
# Vraca lab u A2 (polazno stanje): teardown svih primenjenih varijanti, pa provera (A2_check.sh).
#
#   ./restore_A2.sh [--apply]          teardown samo onoga sto je u state/applied
#   ./restore_A2.sh --all [--apply]    teardown svih varijanti (ako je state/ izgubljen);
#                                      teardown skripte su idempotentne
set -uo pipefail
source "$(dirname "$0")/../lib.sh"
need_root "$@"
parse_apply "$@"
APPLY_ARG=(); [ "$APPLY" = 1 ] && APPLY_ARG=(--apply)
ALL=0; for a in "$@"; do [ "$a" = "--all" ] && ALL=1; done
V="$NS_DIR/variants"

if [ "$ALL" = 1 ] || applied A4; then "$V/A4_rps.sh" teardown "${APPLY_ARG[@]}"; fi
if [ "$ALL" = 1 ] || applied A3; then "$V/A3_cpuset.sh" teardown "${APPLY_ARG[@]}"; fi
if [ "$ALL" = 1 ] || applied A1; then "$V/A1_bridges.sh" teardown "${APPLY_ARG[@]}"; fi
if [ "$ALL" = 1 ] || applied A0; then "$V/A0_flat.sh" teardown "${APPLY_ARG[@]}"; fi

if [ "$APPLY" = 1 ]; then "$V/A2_check.sh"; else info "dry-run: posle --apply sledi provera ./A2_check.sh"; fi

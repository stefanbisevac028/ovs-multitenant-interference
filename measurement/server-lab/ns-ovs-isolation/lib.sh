# Zajednicke funkcije za ns-ovs-isolation skripte na serveru. Ucitava se iz skripti:
#   source "$(dirname "$0")/../lib.sh"
# lab.env i common.sh server lab-a se samo citaju. Sve sto menja stanje sistema ide kroz
# run()/run_sh(): bez --apply skripta samo ispisuje sta bi uradila (dry-run).
NS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common.sh
source "$NS_DIR/../common.sh"
# shellcheck source=ns.env
source "$NS_DIR/ns.env"
STATE_DIR="$NS_DIR/state"
APPLY=0

parse_apply() { local a; for a in "$@"; do [ "$a" = "--apply" ] && APPLY=1; done; return 0; }
args_no_apply() { local a; for a in "$@"; do [ "$a" != "--apply" ] && printf '%s\n' "$a"; done; }

run()    { if [ "$APPLY" = 1 ]; then echo "+ $*"; "$@"; else echo "[dry-run] $*"; fi; }
run_sh() { if [ "$APPLY" = 1 ]; then echo "+ $1"; bash -c "$1"; else echo "[dry-run] $1"; fi; }
done_msg() { if [ "$APPLY" = 1 ]; then ok "$*"; else info "dry-run gotov (nista nije promenjeno): $*"; fi; }

# --- stanje primenjenih varijanti (state/applied, po jedna linija: A0 / A1 / A3 / A4) ---
applied() { [ -f "$STATE_DIR/applied" ] && grep -qx "$1" "$STATE_DIR/applied"; }
mark()    { [ "$APPLY" = 1 ] || return 0; mkdir -p "$STATE_DIR"; applied "$1" || echo "$1" >> "$STATE_DIR/applied"; }
unmark()  { [ "$APPLY" = 1 ] || return 0; [ -f "$STATE_DIR/applied" ] && sed -i "/^$1\$/d" "$STATE_DIR/applied"; return 0; }
current_variant() {
    if applied A0; then echo A0; elif applied A1; then echo A1
    elif applied A4; then echo A4; elif applied A3; then echo A3; else echo A2; fi
}

# greska tokom setup-a sa --apply -> teardown (vracanje u A2)
rollback_on_error() {
    [ "$APPLY" = 1 ] || return 0
    set -E
    trap 'warn "greska u setup-u, vracam stanje (teardown)"; trap - ERR; teardown; exit 1' ERR
}

# --- tenanti i servisi ---
tenants()       { seq 1 "$T1_COUNT"; }
svc_of_tenant() { local s; for s in "${SERVICES[@]}"; do [ "$(svc_field "$s" 2)" = "$1" ] && echo "$s"; done; return 0; }
svc_pid()       { docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null; }
ip_to_mac()     { local IFS=.; set -- $1; printf '02:00:%02x:%02x:%02x:%02x' "$1" "$2" "$3" "$4"; }
svc_has_ip()    { docker exec "$1" ip -4 addr show dev eth0 2>/dev/null | grep -q "$2/"; }

cpulist_to_mask() { # "4-5,8" -> "130"
    local IFS=, part a b m=0 i
    for part in $1; do
        a=${part%-*}; b=${part#*-}
        for ((i = a; i <= b; i++)); do m=$((m | (1 << i))); done
    done
    printf '%x' "$m"
}

ns_pid_of() { # PID procesa $2 (npr. ovs-vswitchd) u netns $1 (/run/netns/$1)
    local ino p
    ino=$(stat -Lc %i "/run/netns/$1" 2>/dev/null) || return 1
    for p in $(pgrep -x "$2"); do
        [ "$(stat -Lc %i "/proc/$p/ns/net" 2>/dev/null)" = "$ino" ] && { echo "$p"; return 0; }
    done
    return 1
}

check_a2_running() {
    local n s
    running "$T0_CONTAINER" || die "$T0_CONTAINER ne radi"
    for n in $(tenants); do running "$(t1_name "$n")" || die "$(t1_name "$n") ne radi"; done
    for s in "${SERVICES[@]}"; do running "$(svc_field "$s" 1)" || die "$(svc_field "$s" 1) ne radi"; done
}

# --- zajednicko za A0 i A1 (tenanti bez tier1 instanci) ---
stop_tier1() {
    local n
    for n in $(tenants); do running "$(t1_name "$n")" && run docker stop -t 20 "$(t1_name "$n")"; done
    return 0
}

start_tier1_wait() {
    local n s name ip_addr i
    for n in $(tenants); do running "$(t1_name "$n")" || run docker start "$(t1_name "$n")"; done
    [ "$APPLY" = 1 ] || return 0
    for s in "${SERVICES[@]}"; do
        name=$(svc_field "$s" 1); ip_addr=$(svc_field "$s" 3)
        for i in $(seq $((AGENT_INTERVAL * 4 + 10))); do svc_has_ip "$name" "$ip_addr" && break; sleep 1; done
        if svc_has_ip "$name" "$ip_addr"; then ok "[$name] ponovo povezan preko tier1"; else warn "[$name] nije povezan"; fi
    done
}

# servis vezan veth-om direktno na bridge sistemskog OvS-a (ista IP i stalna MAC kao u A2)
attach_svc() { # $1 = "svc1:1:ip", $2 = bridge, $3 = ime veth-a na hostu
    local spec=$1 br=$2 hv=$3 name ip_addr mac pid
    name=$(svc_field "$spec" 1); ip_addr=$(svc_field "$spec" 3); mac=$(ip_to_mac "$ip_addr")
    pid=$(svc_pid "$name"); [ "${pid:-0}" -gt 0 ] 2>/dev/null || die "[$name] ne radi"
    run_sh "nsenter -t $pid -n ip link del eth0 2>/dev/null || true"
    run ip link add "$hv" type veth peer name eth0 netns "$pid"
    run nsenter -t "$pid" -n ip link set eth0 address "$mac"
    run nsenter -t "$pid" -n ip addr add "$ip_addr/$SERVICE_PREFIXLEN" dev eth0
    run nsenter -t "$pid" -n ip link set eth0 mtu "$MTU" up
    run ip link set "$hv" mtu "$MTU" up
    run ovs-vsctl --may-exist add-port "$br" "$hv" -- set interface "$hv" external_ids:ns-ovs-isolation="$name"
}

detach_svc() { # $1 = ime veth-a na hostu, $2 = bridge
    run ovs-vsctl --if-exists del-port "$2" "$1"
    if ip link show "$1" >/dev/null 2>&1; then run ip link del "$1"; fi
    return 0
}

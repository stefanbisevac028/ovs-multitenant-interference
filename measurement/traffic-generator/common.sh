# Pomocne funkcije, ucitava se iz skripti: source "$(dirname "$0")/../common.sh"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab.env
source "$LAB_DIR/lab.env"

info()  { echo -e "\e[1;34m[*]\e[0m $*"; }
ok()    { echo -e "\e[1;32m[+]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[!]\e[0m $*"; }
die()   { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        exec sudo -E bash "$0" "$@"
    fi
}

trex_name()      { echo "${CONTAINER_PREFIX}$1"; }            # 1 -> trex1
trex_sync_port() { echo $(( TREX_RPC_BASE + ($1 - 1) * 10 )); }
trex_async_port(){ echo $(( $(trex_sync_port "$1") - 1 )); }
host_veth()      { echo "veth-${CONTAINER_PREFIX}$1"; }       # host strana, ide u OvS
trex_count()     { echo "${#TREX_IPS[@]}"; }

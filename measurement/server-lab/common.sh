# Pomocne funkcije, ucitava se iz skripti: source "$(dirname "$0")/../common.sh"
LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab.env
source "$LAB_DIR/lab.env"
FLOWS_DIR="$LAB_DIR/2 - Setup Lab"      # flows.txt, montira se u OvS kontejnere kao /lab

info()  { echo -e "\e[1;34m[*]\e[0m $*"; }
ok()    { echo -e "\e[1;32m[+]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[!]\e[0m $*"; }
die()   { echo -e "\e[1;31m[x]\e[0m $*" >&2; exit 1; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        exec sudo -E bash "$0" "$@"
    fi
}

# --- tier1 ---
t1_name()    { echo "${T1_PREFIX}$1"; }                 # 1 -> ovs-1 (kontejner i namespace)
t1_br()      { echo "${T1_BRIDGE_PREFIX}$1"; }          # 1 -> br0-1
t0_veth()    { echo "t0-$(t1_name "$1")"; }             # 1 -> t0-ovs-1 (host, na br-tier0)

# servisi koji pripadaju tier1 instanci N, u formatu agenta: "ime:ip/prefiks ..."
t1_services() {
    local n=$1 s out=""
    for s in "${SERVICES[@]}"; do
        [ "$(svc_field "$s" 2)" = "$n" ] && out+="$(svc_field "$s" 1):$(svc_field "$s" 3)/${SERVICE_PREFIXLEN} "
    done
    echo "${out% }"
}

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

# --- servisi ---
svc_field()  { echo "$1" | cut -d: -f"$2"; }            # "svc1:1:10.10.10.101" 1 -> svc1
svc_veth()   { echo "s-$1"; }                           # svc1 -> s-svc1 (u tier1 kontejneru)

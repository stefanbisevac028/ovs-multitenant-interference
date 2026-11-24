#!/bin/bash
# Pokrece TRex server (stateless, interaktivni rezim) nad data interfejsom eth1.
# Kontejner sam pravi eth1: veth par cija druga strana (HOST_VETH) ide u namespace hosta
# i dodaje se na OvS bridge hosta. Zato se posle restarta kontejnera ili masine sve
# poveze samo (kontejner ima --restart unless-stopped).
#
# Montirano iz hosta (videti start.sh):
#   /host/run/openvswitch   - sistemski OvS (db.sock)
#   /var/run/netns/host     - mrezni namespace hosta (/proc/1/ns/net), za "ip -n host"
set -e

: "${TREX_NAME:?}" "${TREX_IP:?}" "${TREX_DEST_IP:?}"
DATA_IF="${DATA_IF:-eth1}"
TREX_CORE="${TREX_CORE:-1}"
TREX_RX_CORE="${TREX_RX_CORE:-2}"   # mora biti razlicit od TREX_CORE i od 0
TREX_MEM_MB="${TREX_MEM_MB:-1024}"
MTU="${MTU:-1500}"
HOST_DB="unix:/host/run/openvswitch/db.sock"

if [ -n "${HOST_VETH:-}" ]; then
    : "${OVS_BRIDGE:?}"
    hvsctl() { ovs-vsctl --timeout=5 --db="$HOST_DB" "$@"; }
    echo "[$TREX_NAME] cekam OvS bridge $OVS_BRIDGE na hostu..."
    command -v ovs-vsctl >/dev/null || { echo "[$TREX_NAME] nema ovs-vsctl u image-u"; exit 1; }
    until [ -S /host/run/openvswitch/db.sock ] && hvsctl br-exists "$OVS_BRIDGE" 2>/dev/null; do sleep 2; done
    # fizicka kartica mora biti podignuta (posle restarta masine nije)
    [ -n "${PHY_IF:-}" ] && ip -n host link set "$PHY_IF" mtu "$MTU" up
    if ! ip link show "$DATA_IF" >/dev/null 2>&1; then
        ip -n host link del "$HOST_VETH" 2>/dev/null || true
        ip link add "$DATA_IF" type veth peer name "$HOST_VETH" netns host
    fi
    ip -n host link set "$HOST_VETH" mtu "$MTU" up
    hvsctl --may-exist add-port "$OVS_BRIDGE" "$HOST_VETH" -- set interface "$HOST_VETH" external_ids:container="$TREX_NAME"
    ip link set "$DATA_IF" mtu "$MTU" up
    echo "[$TREX_NAME] $DATA_IF <-> $HOST_VETH na $OVS_BRIDGE"
else
    echo "[$TREX_NAME] cekam data interfejs $DATA_IF..."
    for _ in $(seq 120); do
        ip link show "$DATA_IF" >/dev/null 2>&1 && break
        sleep 1
    done
    ip link show "$DATA_IF" >/dev/null 2>&1 || { echo "[$TREX_NAME] nema $DATA_IF"; exit 1; }
    ip link set "$DATA_IF" up
fi

# TRex trazi paran broj portova: port 0 = eth1 (af_packet), port 1 = dummy.
cat > /etc/trex_cfg.yaml <<EOF
- version: 2
  port_limit: 2
  prefix: ${TREX_NAME}
  limit_memory: ${TREX_MEM_MB}
  interfaces: ['--vdev=net_af_packet0,iface=${DATA_IF}', 'dummy']
  port_info:
    - ip: ${TREX_IP}
      default_gw: ${TREX_DEST_IP}   # server (direktna veza, nije gateway)
    - ip: 169.254.0.1
      default_gw: 169.254.0.2
  platform:
    master_thread_id: 0
    latency_thread_id: ${TREX_RX_CORE}
    dual_if:
      - socket: 0
        threads: [${TREX_CORE}]
EOF

echo "[$TREX_NAME] konfiguracija:"; cat /etc/trex_cfg.yaml
cd /opt/trex
exec ./t-rex-64 -i --cfg /etc/trex_cfg.yaml -c 1 ${TREX_EXTRA_ARGS:-}

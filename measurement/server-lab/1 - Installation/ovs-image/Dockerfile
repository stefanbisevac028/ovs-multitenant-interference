FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        openvswitch-switch iproute2 iputils-ping tcpdump curl jq ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

COPY agent.sh /agent.sh
RUN chmod +x /agent.sh
ENTRYPOINT ["/agent.sh"]

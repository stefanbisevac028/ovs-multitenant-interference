FROM ubuntu:22.04

ARG TREX_VERSION=v3.06
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-distutils iproute2 iputils-ping pciutils kmod procps \
        netbase tcpdump less libarchive13 libibverbs1 ibverbs-providers \
        openvswitch-switch \
    && rm -rf /var/lib/apt/lists/*

# Arhivu skida install.sh na host (trex-image/<verzija>.tar.gz), ADD je raspakuje.
ADD ${TREX_VERSION}.tar.gz /opt/
RUN mv /opt/${TREX_VERSION} /opt/trex

WORKDIR /opt/trex
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 4501 = sync RPC (API), 4500 = async (events/stats)
EXPOSE 4500 4501
ENTRYPOINT ["/entrypoint.sh"]

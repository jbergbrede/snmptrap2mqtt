FROM debian:bookworm-slim AS mib-fetch

ARG MIB_URL=""

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /mibs
RUN if [ -n "$MIB_URL" ]; then curl -fsSL -o "$(basename "$MIB_URL")" "$MIB_URL"; fi

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# snmp-mibs-downloader lives in contrib (it fetches IETF/IANA-licensed MIB
# text at build time) and provides the base MIBs (SNMPv2-SMI, SNMPv2-TC,
# SNMP-FRAMEWORK-MIB, INET-ADDRESS-MIB, ...) that vendor MIBs like
# TRUENAS-MIB import. Without it, `snmptrapd -m ALL` can't resolve those
# imports and floods the log with "Cannot find module" / "Unlinked OID"
# noise instead of actually resolving vendor OID names.
RUN sed -i 's/^Components: main$/Components: main contrib/' /etc/apt/sources.list.d/debian.sources \
    && apt-get update && apt-get install -y --no-install-recommends \
    snmp \
    snmptrapd \
    snmp-mibs-downloader \
    mosquitto-clients \
    jq \
    && download-mibs \
    && rm -rf /var/lib/apt/lists/*

COPY mibs/ /usr/share/snmp/mibs/
COPY --from=mib-fetch /mibs/ /usr/share/snmp/mibs/
COPY start.sh /usr/local/bin/start.sh
COPY handle-trap.sh /usr/local/bin/handle-trap.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/handle-trap.sh

CMD ["/usr/local/bin/start.sh"]

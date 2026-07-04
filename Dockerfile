FROM debian:bookworm-slim AS mib-fetch

ARG MIB_URL=""

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /mibs
RUN if [ -n "$MIB_URL" ]; then curl -fsSL -o "$(basename "$MIB_URL")" "$MIB_URL"; fi

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    snmp \
    snmptrapd \
    mosquitto-clients \
    jq \
    && rm -rf /var/lib/apt/lists/*

COPY mibs/ /usr/share/snmp/mibs/
COPY --from=mib-fetch /mibs/ /usr/share/snmp/mibs/
COPY start.sh /usr/local/bin/start.sh
COPY handle-trap.sh /usr/local/bin/handle-trap.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/handle-trap.sh

CMD ["/usr/local/bin/start.sh"]

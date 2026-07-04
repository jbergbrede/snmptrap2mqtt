FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    snmp \
    snmptrapd \
    mosquitto-clients \
    jq \
    && rm -rf /var/lib/apt/lists/*

COPY mibs/ /usr/share/snmp/mibs/
COPY start.sh /usr/local/bin/start.sh
COPY handle-trap.sh /usr/local/bin/handle-trap.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/handle-trap.sh

CMD ["/usr/local/bin/start.sh"]

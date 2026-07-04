FROM debian:bookworm-slim AS mib-fetch

ARG MIB_URL=""

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /mibs
RUN if [ -n "$MIB_URL" ]; then curl -fsSL -o "$(basename "$MIB_URL")" "$MIB_URL"; fi

# Base IETF/IANA MIBs that vendor MIBs (e.g. TRUENAS-MIB) and even
# net-snmp's own bundled MIBs import. Debian's snmp package doesn't ship
# them (unlike Ubuntu's snmp-mibs-downloader, which isn't available on
# Debian) so without these, snmptrapd -m ALL can't resolve the imports and
# floods the log with "Cannot find module" / "Unlinked OID" noise instead
# of actually resolving OID names.
RUN for mib in SNMPv2-SMI SNMPv2-TC SNMPv2-CONF SNMP-FRAMEWORK-MIB HCNUM-TC INET-ADDRESS-MIB SNMP-VIEW-BASED-ACM-MIB; do \
      curl -fsSL -o "$mib" "https://pysnmp.github.io/mibs/asn1/$mib"; \
    done

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

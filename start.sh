#!/usr/bin/env bash
set -euo pipefail

required_vars=(MQTT_HOST MQTT_PORT MQTT_TOPIC)
for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "[ERROR] Required environment variable ${var} is not set" >&2
        exit 1
    fi
done

# snmptrapd spawns the trap handler with a clean environment, so persist
# the config here for handle-trap.sh to source. Restrict permissions since
# MQTT_PASSWORD may be present.
umask 077
cat > /tmp/trap-env <<EOF
MQTT_HOST=${MQTT_HOST}
MQTT_PORT=${MQTT_PORT}
MQTT_USER=${MQTT_USER:-}
MQTT_PASSWORD=${MQTT_PASSWORD:-}
MQTT_TOPIC=${MQTT_TOPIC}
EOF
chmod 600 /tmp/trap-env

cat > /etc/snmp/snmptrapd.conf <<EOF
authCommunity log,execute,net ${SNMP_COMMUNITY:-public}
traphandle default /usr/local/bin/handle-trap.sh
disableAuthorization yes
EOF

echo "[INFO] Starting snmptrapd on UDP 162 (topic: ${MQTT_TOPIC})..."
# `-m ALL` directory-scans every MIB file, including ones (UCD-SNMP-MIB,
# NET-SNMP-AGENT-MIB) that snmptrapd already registers internally by
# default, which makes it log a harmless "Cannot adopt OID" warning per
# object. Filter those out so real trap activity isn't buried in noise.
#
# Bind explicitly to 127.0.0.1 rather than the bare "udp:162" form: the
# latter can make snmptrapd open both an IPv4 and IPv6 socket, and on
# dual-stack hosts a single incoming packet can be delivered to both,
# firing the trap handler twice per trap. Traps only ever arrive via
# loopback (see README), so binding to 127.0.0.1 instead of 0.0.0.0 also
# avoids exposing the unauthenticated listener on other interfaces.
exec snmptrapd -f -Lo -m ALL -c /etc/snmp/snmptrapd.conf udp:127.0.0.1:162 > >(grep --line-buffered -v '^Cannot adopt OID')

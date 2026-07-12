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
MQTT_TIMEOUT=${MQTT_TIMEOUT:-10}
ALERT_STATE_TOPIC_PREFIX=${ALERT_STATE_TOPIC_PREFIX:-truenas/alerts}
HA_DISCOVERY_PREFIX=${HA_DISCOVERY_PREFIX:-homeassistant}
EOF
chmod 600 /tmp/trap-env

cat > /etc/snmp/snmptrapd.conf <<EOF
authCommunity log,execute,net ${SNMP_COMMUNITY:-public}
traphandle default /usr/local/bin/handle-trap.sh
EOF

echo "[INFO] Starting snmptrapd on UDP 162 (topic: ${MQTT_TOPIC})..."
# `-m ALL` directory-scans every MIB file, including ones (UCD-SNMP-MIB,
# NET-SNMP-AGENT-MIB) that snmptrapd already registers internally by
# default, which makes it log a harmless "Cannot adopt OID" warning per
# object. Filter those out so real trap activity isn't buried in noise.
#
# Bind explicitly to 127.0.0.1 rather than the bare "udp:162" form, since
# the latter can make snmptrapd open both an IPv4 and IPv6 socket. Traps
# only ever arrive via loopback (see README), so this also avoids exposing
# the unauthenticated listener on other interfaces.
#
# No `-c` flag: /etc/snmp/snmptrapd.conf (written above) is already
# net-snmp's default config path, and `-c` *adds* to the default search
# list rather than replacing it. Passing `-c /etc/snmp/snmptrapd.conf`
# here made net-snmp load that same file twice, registering `traphandle
# default` twice and running handle-trap.sh twice per trap (confirmed by
# reproducing it locally: removing the redundant -c drops it back to one
# invocation per trap).
exec snmptrapd -f -Lo -m ALL udp:127.0.0.1:162 > >(grep --line-buffered -v '^Cannot adopt OID')

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
exec snmptrapd -f -Lo -m ALL -c /etc/snmp/snmptrapd.conf udp:162

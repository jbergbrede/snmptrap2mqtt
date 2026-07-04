#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /tmp/trap-env

# snmptrapd passes trap data via stdin:
# Line 1: sender hostname/ip
# Line 2: trap OID
# Remaining lines: variable bindings (OID = value)
read -r TRAP_HOST
read -r TRAP_OID
TRAP_VARS=$(cat)

PAYLOAD=$(jq -n \
  --arg host "$TRAP_HOST" \
  --arg oid "$TRAP_OID" \
  --arg vars "$TRAP_VARS" \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{
    source_host: $host,
    trap_oid: $oid,
    variables: $vars,
    timestamp: $ts
  }')

mqtt_args=(-h "$MQTT_HOST" -p "$MQTT_PORT" -r -t "$MQTT_TOPIC" -m "$PAYLOAD")
if [ -n "${MQTT_USER:-}" ]; then
    mqtt_args+=(-u "$MQTT_USER" -P "$MQTT_PASSWORD")
fi

mosquitto_pub "${mqtt_args[@]}"
echo "[INFO] Trap from ${TRAP_HOST} (${TRAP_OID}) published to ${MQTT_TOPIC}"

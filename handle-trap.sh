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

# Pull out the TrueNAS alert fields so subscribers can notify on just the
# human-relevant bits instead of the full variable-binding dump.
ALERT_ID=$(grep -oP 'TRUENAS-MIB::alertId \K.*' <<<"$TRAP_VARS" || true)
ALERT_LEVEL=$(grep -oP 'TRUENAS-MIB::alertLevel \K.*' <<<"$TRAP_VARS" || true)
ALERT_MESSAGE=$(grep -oP 'TRUENAS-MIB::alertMessage \K.*' <<<"$TRAP_VARS" || true)

PAYLOAD=$(jq -n \
  --arg host "$TRAP_HOST" \
  --arg oid "$TRAP_OID" \
  --arg vars "$TRAP_VARS" \
  --arg alert_id "$ALERT_ID" \
  --arg alert_level "$ALERT_LEVEL" \
  --arg alert_message "$ALERT_MESSAGE" \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{
    source_host: $host,
    trap_oid: $oid,
    variables: $vars,
    alert_id: $alert_id,
    alert_level: $alert_level,
    alert_message: $alert_message,
    timestamp: $ts
  }')

mqtt_args=(-h "$MQTT_HOST" -p "$MQTT_PORT" -r -t "$MQTT_TOPIC" -m "$PAYLOAD")
if [ -n "${MQTT_USER:-}" ]; then
    mqtt_args+=(-u "$MQTT_USER" -P "$MQTT_PASSWORD")
fi

mosquitto_pub "${mqtt_args[@]}"
echo "[INFO] Trap from ${TRAP_HOST} (${TRAP_OID}) published to ${MQTT_TOPIC}"

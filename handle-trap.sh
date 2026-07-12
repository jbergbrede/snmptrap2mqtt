#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
source /tmp/trap-env

# snmptrapd passes trap data via stdin:
# Line 1: sender hostname/ip
# Line 2: transport info (e.g. "UDP: [1.2.3.4]:47132->[5.6.7.8]:162"),
#         NOT the trap OID despite what net-snmp's docs suggest
# Remaining lines: variable bindings (OID = value), including the
#         sysUpTime.0 and snmpTrapOID.0 bindings every trap carries
read -r TRAP_HOST
read -r TRAP_TRANSPORT
TRAP_VARS=$(cat)

# The actual trap type lives in the snmpTrapOID.0 varbind, not line 2.
# Depending on which MIBs are loaded it may resolve as either name below.
TRAP_OID=$(grep -oP '(SNMPv2-MIB::snmpTrapOID\.0|SNMPv2-SMI::snmpModules\.1\.1\.4\.1\.0) \K.*' <<<"$TRAP_VARS" || true)

# Pull out the TrueNAS alert fields so subscribers can notify on just the
# human-relevant bits instead of the full variable-binding dump.
ALERT_ID=$(grep -oP 'TRUENAS-MIB::alertId \K.*' <<<"$TRAP_VARS" || true)
ALERT_LEVEL=$(grep -oP 'TRUENAS-MIB::alertLevel \K.*' <<<"$TRAP_VARS" || true)
ALERT_MESSAGE=$(grep -oP 'TRUENAS-MIB::alertMessage \K.*' <<<"$TRAP_VARS" || true)

PAYLOAD=$(jq -n \
  --arg host "$TRAP_HOST" \
  --arg oid "$TRAP_OID" \
  --arg transport "$TRAP_TRANSPORT" \
  --arg vars "$TRAP_VARS" \
  --arg alert_id "$ALERT_ID" \
  --arg alert_level "$ALERT_LEVEL" \
  --arg alert_message "$ALERT_MESSAGE" \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  '{
    source_host: $host,
    trap_oid: $oid,
    trap_transport: $transport,
    variables: $vars,
    alert_id: $alert_id,
    alert_level: $alert_level,
    alert_message: $alert_message,
    timestamp: $ts
  }')

mqtt_args=(-h "$MQTT_HOST" -p "$MQTT_PORT" -t "$MQTT_TOPIC" -m "$PAYLOAD")
if [ -n "${MQTT_USER:-}" ]; then
    mqtt_args+=(-u "$MQTT_USER" -P "$MQTT_PASSWORD")
fi

# Capture output/exit code explicitly instead of letting a failed
# mosquitto_pub trip `set -e` straight to exit: that would skip both the
# success log below AND any indication of what went wrong, making a dead
# broker (e.g. an ACL blocking the connection) indistinguishable from a
# trap that never arrived at all.
#
# mosquitto_pub has no built-in connect timeout, so a blackholed
# destination (e.g. a Tailscale ACL silently dropping packets, as opposed
# to actively refusing the connection) hangs with zero output until the
# OS-level TCP timeout kicks in, which can take minutes. Wrap it in
# `timeout` so that failure mode surfaces as an [ERROR] line within
# MQTT_TIMEOUT seconds instead.
if MQTT_OUTPUT=$(timeout "${MQTT_TIMEOUT:-10}" mosquitto_pub "${mqtt_args[@]}" 2>&1); then
    echo "[INFO] Trap from ${TRAP_HOST} (${TRAP_OID}) published to ${MQTT_TOPIC}"
else
    MQTT_STATUS=$?
    if [ "$MQTT_STATUS" -eq 124 ]; then
        MQTT_OUTPUT="timed out after ${MQTT_TIMEOUT:-10}s connecting to broker"
    fi
    echo "[ERROR] Failed to publish trap from ${TRAP_HOST} (${TRAP_OID}) to ${MQTT_HOST}:${MQTT_PORT}/${MQTT_TOPIC} (mosquitto_pub exit ${MQTT_STATUS}): ${MQTT_OUTPUT}" >&2
    exit "$MQTT_STATUS"
fi

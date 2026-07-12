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
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

PAYLOAD=$(jq -n \
  --arg host "$TRAP_HOST" \
  --arg oid "$TRAP_OID" \
  --arg transport "$TRAP_TRANSPORT" \
  --arg vars "$TRAP_VARS" \
  --arg alert_id "$ALERT_ID" \
  --arg alert_level "$ALERT_LEVEL" \
  --arg alert_message "$ALERT_MESSAGE" \
  --arg ts "$TIMESTAMP" \
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

# --- Per-alert MQTT discovery bridge ----------------------------------------
#
# TrueNAS fires two distinct notification types for its alert lifecycle
# (per TRUENAS-MIB): `alert` on create (carries alertId/alertLevel/
# alertMessage) and `alertCancellation` on clear (carries only alertId).
# Each resolves to its MIB name when TRUENAS-MIB is loaded, or falls back to
# the raw enterprise OID otherwise:
#   create: TRUENAS-MIB::alert             / ...50536.2.1.1
#   cancel: TRUENAS-MIB::alertCancellation / ...50536.2.1.2
# Represent each active alert as its own retained state + HA MQTT-discovery
# topic, so it appears as a discrete entity that disappears on cancel
# instead of a transient log line.
publish_retained() {
    local topic=$1 payload=$2
    local args=(-h "$MQTT_HOST" -p "$MQTT_PORT" -t "$topic" -q 1 -r)
    if [ -n "${MQTT_USER:-}" ]; then
        args+=(-u "$MQTT_USER" -P "$MQTT_PASSWORD")
    fi
    if [ -n "$payload" ]; then
        args+=(-m "$payload")
    else
        # Empty retained payload clears the retained message on the broker;
        # for the discovery topic this also deletes the HA entity. Doing
        # this is a broker-side operation independent of whether HA is
        # online at the moment the cancel trap arrives.
        args+=(-n)
    fi
    # Same fail-fast-and-loudly treatment as the flat-topic publish above:
    # bounded by MQTT_TIMEOUT and logged explicitly on failure instead of
    # silently tripping `set -e`. Status must be captured inside the `else`
    # branch itself — an `if` with no `else` exits 0 when its condition
    # fails, so `$?` read after `fi` would always read back as success.
    local output status
    if output=$(timeout "${MQTT_TIMEOUT:-10}" mosquitto_pub "${args[@]}" 2>&1); then
        return 0
    else
        status=$?
    fi
    if [ "$status" -eq 124 ]; then
        output="timed out after ${MQTT_TIMEOUT:-10}s connecting to broker"
    fi
    echo "[ERROR] Failed to publish to ${topic} (mosquitto_pub exit ${status}): ${output}" >&2
    return "$status"
}

# Collapse TrueNAS's 7-level alertLevel onto the CRIT/WARN/INFO taxonomy the
# HA-side severity aggregation keys off of:
#   CRIT: critical, alert, emergency (5-7) - loud/DND-bypass notification
#   WARN: warning, error (3-4)             - normal-priority notification
#   INFO: info, notice (1-2)               - normal-priority notification
# Matches on substring so it handles both net-snmp's typical enum rendering
# ("critical(5)") and a bare numeric fallback if the label doesn't resolve.
severity_class() {
    local level
    level=$(tr '[:upper:]' '[:lower:]' <<<"$1")
    case "$level" in
        *critical*|*emergency*|*alert*|5|6|7) echo "CRIT" ;;
        *warning*|*error*|3|4) echo "WARN" ;;
        *info*|*notice*|1|2) echo "INFO" ;;
        *) echo "WARN" ;;
    esac
}

if [ -n "$ALERT_ID" ]; then
    # TrueNAS's alertId is a DisplayString varbind, which net-snmp may quote
    # (`"a1b2c3d4-uuid"`); strip surrounding quotes/whitespace before using
    # it in topic names and entity IDs, where a stray quote would corrupt
    # both the MQTT topic and the discovery payload.
    ALERT_ID_CLEAN=$(sed -e 's/^[[:space:]"]*//' -e 's/[[:space:]"]*$//' <<<"$ALERT_ID")
    # unique_id/topics keep the full UUID (needed for collision-safety and
    # for correlating an entity back to `midclt call alert.list`); the
    # display name only needs enough of it to tell entities apart at a
    # glance, so shorten it there.
    ALERT_ID_SHORT="${ALERT_ID_CLEAN: -8}"
    state_topic="${ALERT_STATE_TOPIC_PREFIX}/${ALERT_ID_CLEAN}"
    discovery_topic="${HA_DISCOVERY_PREFIX}/binary_sensor/truenas_${ALERT_ID_CLEAN}/config"

    if [[ "$TRAP_OID" =~ (::alert$|\.50536\.2\.1\.1$) ]]; then
        SEVERITY=$(severity_class "$ALERT_LEVEL")
        STATE_PAYLOAD=$(jq -n \
            --arg severity "$SEVERITY" \
            --arg message "${NAS_NAME}: ${ALERT_MESSAGE}" \
            --arg since "$TIMESTAMP" \
            '{state: "active", severity: $severity, message: $message, since: $since}')
        DISCOVERY_PAYLOAD=$(jq -n \
            --arg uid "truenas_${ALERT_ID_CLEAN}" \
            --arg name "TrueNAS Alert ${ALERT_ID_SHORT}" \
            --arg state_topic "$state_topic" \
            '{
              unique_id: $uid,
              name: $name,
              state_topic: $state_topic,
              value_template: "{{ value_json.state }}",
              payload_on: "active",
              payload_off: "cleared",
              json_attributes_topic: $state_topic,
              device_class: "problem",
              device: { identifiers: ["truenas"], name: "TrueNAS" }
            }')
        publish_retained "$state_topic" "$STATE_PAYLOAD"
        publish_retained "$discovery_topic" "$DISCOVERY_PAYLOAD"
        echo "[INFO] Alert ${ALERT_ID_CLEAN} (${SEVERITY}) created, entity published to ${discovery_topic}"
    elif [[ "$TRAP_OID" =~ (::alertCancellation$|\.50536\.2\.1\.2$) ]]; then
        # Delete the discovery entry first so HA drops the entity before its
        # backing state topic disappears, then clear the retained state.
        publish_retained "$discovery_topic" ""
        publish_retained "$state_topic" ""
        echo "[INFO] Alert ${ALERT_ID_CLEAN} cancelled, entity ${discovery_topic} removed"
    fi
fi

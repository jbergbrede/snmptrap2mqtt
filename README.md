# snmptrap2mqtt

Bridges SNMP traps (e.g. from TrueNAS's alert service) to an MQTT broker, so
alerts can be picked up by Home Assistant or any other MQTT subscriber.

```
TrueNAS (snmptrapd) → localhost trap → container → MQTT (VPS via Tailscale) → HA
```

The container listens on UDP 162, receives traps sent to `127.0.0.1`, and
publishes each one as a JSON message to an MQTT topic. Encryption is handled
by Tailscale, so no TLS is needed at the MQTT layer. Deploy the same image on
multiple NAS instances, using a different `MQTT_TOPIC` per instance.

## Files

```
snmptrap2mqtt/
├── Dockerfile
├── start.sh          # renders snmptrapd config, starts the daemon
├── handle-trap.sh     # invoked by snmptrapd per trap, publishes to MQTT
├── mibs/               # optional extra MIBs for human-readable OID names
└── .github/workflows/  # CI: build & publish the image to GHCR
```

## Configuration

| Variable | Example | Required | Description |
|---|---|---|---|
| `MQTT_HOST` | `100.x.x.x` | yes | VPS Tailscale IP or hostname |
| `MQTT_PORT` | `1883` | yes | MQTT port |
| `MQTT_USER` | `your-user` | no | Mosquitto username |
| `MQTT_PASSWORD` | `your-password` | no | Mosquitto password |
| `MQTT_TOPIC` | `truenas/nas1/snmp_trap` | yes | Use a different topic per NAS instance |
| `SNMP_COMMUNITY` | `public` | no | SNMP community string (default: `public`) |
| `MQTT_TIMEOUT` | `10` | no | Max seconds for a single publish attempt before failing (default: `10`) |
| `ALERT_STATE_TOPIC_PREFIX` | `truenas/alerts` | no | Retained per-alert state topic prefix (default: `truenas/alerts`) |
| `HA_DISCOVERY_PREFIX` | `homeassistant` | no | Home Assistant MQTT discovery prefix (default: `homeassistant`) |
| `NAS_NAME` | `nas1` | no | Prefixed onto each alert's message, e.g. `"nas1: pool tank DEGRADED"` (default: `TrueNAS`) |

Copy `.env.example` to `.env` and fill in your own values for local testing.
**Never commit `.env`** — it's already in `.gitignore`.

## Running

The container must be able to receive UDP traffic addressed to
`127.0.0.1:162`, so it needs to run in the host's network namespace.

```bash
docker run -d \
  --name snmptrap2mqtt \
  --network host \
  --env-file .env \
  ghcr.io/<owner>/<repo>:latest
```

### TrueNAS (Apps → Custom App)

- Set network mode to **Host**.
- Provide the environment variables above.

### TrueNAS Alert Service (System → Alert Services → Add → SNMP Trap)

| Field | Value |
|---|---|
| Host | `127.0.0.1` |
| Port | `162` |
| Community | `public` (or your `SNMP_COMMUNITY`) |

Click **Send Test Alert** to verify the pipeline end to end.

## Home Assistant

Use a topic wildcard so one automation handles every NAS instance;
`trigger.topic` identifies which one fired. The payload includes parsed
`alert_level` and `alert_message` fields (pulled from the TrueNAS MIB
`alertLevel`/`alertMessage` bindings) alongside the raw `variables` dump, so
notifications can show just the relevant text instead of the full trap.
Both are cleaned up before publishing: `alert_level` is the plain word
(`critical`, not net-snmp's `critical(5)` enum rendering), and
`alert_message` has TrueNAS's `<br>`/`&nbsp;` HTML (meant for its own web
UI) flattened to a plain sentence:

```yaml
automation:
  - alias: "TrueNAS SNMP Trap"
    trigger:
      platform: mqtt
      topic: "truenas/+/snmp_trap"
    condition:
      # Only notify on warning/critical alerts; drop info-level noise.
      - "{{ trigger.payload_json.alert_level in ['warning', 'critical'] }}"
    action:
      service: notify.mobile_app_your_phone
      data:
        title: "NAS Alert: {{ trigger.topic.split('/')[1] }} ({{ trigger.payload_json.alert_level }})"
        message: "{{ trigger.payload_json.alert_message }}"
        data:
          push:
            sound:
              name: default
              critical: "{{ 1 if trigger.payload_json.alert_level == 'critical' else 0 }}"
              volume: 1
```

If a trap isn't a TrueNAS alert (e.g. `linkDown`), `alert_level` and
`alert_message` will be empty strings — fall back to `variables` in that
case, or add a second automation keyed on `trigger.payload_json.trap_oid`.

### Per-alert entities (MQTT discovery)

Alongside the flat `MQTT_TOPIC` feed above, `handle-trap.sh` also tracks
each TrueNAS alert as its own disappearing HA entity, keyed by the alert's
UUID (`alertId`), so active alerts can be aggregated by severity and drive
`alert:`-based acknowledge/repeat notifications instead of one-shot
messages. This only fires for TrueNAS's own `alert` / `alertCancellation`
notifications (identified by `trap_oid`), not other trap types.

On alert create, two retained messages are published. The state topic's
`message` is prefixed with `NAS_NAME` (default `TrueNAS`) so notifications
built on multiple instances' aggregated messages still identify which NAS
fired:

```
truenas/alerts/{alertId}                          # ALERT_STATE_TOPIC_PREFIX
{"state": "active", "severity": "CRIT", "message": "TrueNAS: pool tank DEGRADED", "since": "2026-07-09T10:03:00Z"}

homeassistant/binary_sensor/truenas_{alertId}/config   # HA_DISCOVERY_PREFIX
{"unique_id": "truenas_{alertId}", "name": "TrueNAS Alert {alertId}", "state_topic": "truenas/alerts/{alertId}", ...}
```

On alert cancel, both topics are republished with an empty retained
payload — this clears the state topic and, for the discovery topic,
deletes the HA entity. Because both are retained broker-side operations,
the delete lands whether or not HA is online at the moment the cancel
trap arrives; HA picks it up on next connect.

TrueNAS's `alertLevel` (7 levels: `info`, `notice`, `warning`, `error`,
`critical`, `alert`, `emergency`) is collapsed to the three-way severity
used for notification routing:

| TrueNAS `alertLevel` | `severity` |
|---|---|
| `info`, `notice` | `INFO` |
| `warning`, `error` | `WARN` |
| `critical`, `alert`, `emergency` | `CRIT` |

Configure HA-side template sensors, `alert:` entries, and a critical-only
loud-notification automation on top of these entities/topics to get
severity-proportional push notifications (loud/DND-bypass for `CRIT`,
normal-priority otherwise).

## MIB / human-readable OID names

`start.sh` runs `snmptrapd` with `-m ALL`, so any MIBs present under
`/usr/share/snmp/mibs/` are loaded. Drop additional MIB files (e.g. the
TrueNAS `FREENAS-MIB.txt`, downloadable from **System → SNMP**) into the
local `mibs/` directory before building the image — they are copied into
the container automatically. MIB files are gitignored by default since they
may be vendor-specific; only commit ones you intend to ship with the image.

A pre-built `truenas` variant (tags `latest-truenas`, `vX.Y.Z-truenas`) ships
with the TrueNAS MIB baked in, downloaded at build time from
`https://www.truenas.com/docs/files/truenas-mib-27.txt`:

```bash
docker run -d \
  --name snmptrap2mqtt \
  --network host \
  --env-file .env \
  ghcr.io/<owner>/<repo>:latest-truenas
```

To build it yourself: `docker build --build-arg MIB_URL=https://www.truenas.com/docs/files/truenas-mib-27.txt .`

## Testing

Send a test trap from another machine:

```bash
snmptrap -v2c -c public <truenas-ip> '' linkDown.0
```

On success, `handle-trap.sh` logs a line to the container's stdout for every
trap it forwards:

```
[INFO] Trap from 192.0.2.10 (linkDown) published to truenas/nas1/snmp_trap
```

Check for it with `docker logs <container>` (or `docker logs -f <container>`
while sending the test trap). If you don't see it at all, the trap likely
never reached `snmptrapd` — check that UDP/162 is reachable and that the
sender's community string matches `SNMP_COMMUNITY`.

If the trap *did* arrive but the broker connection is broken (wrong
`MQTT_HOST`/port, bad credentials, or a network/ACL issue blocking the
route — e.g. Tailscale), `handle-trap.sh` logs an explicit line instead of
failing silently:

```
[ERROR] Failed to publish trap from 192.0.2.10 (linkDown) to 100.x.x.x:1883/truenas/nas1/snmp_trap (mosquitto_pub exit 1): Error: Connection refused
```

`MQTT_TIMEOUT` (default 10s) bounds how long that connection attempt can
hang before it's reported as a failure — useful when the network silently
drops packets instead of refusing the connection, since a plain TCP
timeout can otherwise take minutes. To confirm the MQTT side
independently, subscribe to the topic before sending the test trap:

```bash
mosquitto_sub -h <mqtt-host> -p <mqtt-port> -t '<mqtt-topic>' -v
```

To verify the per-alert entity pipeline specifically, subscribe to both the
state and discovery topics (retained, so you'll also see any alert already
active) while triggering a real create/cancel from TrueNAS's alert service:

```bash
mosquitto_sub -h <mqtt-host> -p <mqtt-port> -v \
  -t 'truenas/alerts/#' -t 'homeassistant/binary_sensor/truenas_+/config'
```

Startup also logs a handful of `Cannot adopt OID` lines from `snmptrapd -m
ALL`; these are harmless (duplicate registration of MIB modules it already
loads by default) and are filtered out of the container's log output.

To inspect the raw stdin format `snmptrapd` hands to the trap handler,
temporarily replace the body of `handle-trap.sh` with `cat >> /tmp/last-trap.txt`,
send a test trap, then:

```bash
docker exec <container> cat /tmp/last-trap.txt
```

## CI/CD

`.github/workflows/docker-publish.yml` builds and publishes a multi-arch
(amd64/arm64) image to `ghcr.io/<owner>/<repo>` **only when a `vX.Y.Z` tag is
pushed** — i.e. only on release (see below), tagged both `vX.Y.Z` and
`latest`. Pull requests only build (no push) to validate the Dockerfile; a
plain push to `main` does not publish an image on its own. No secrets are
required beyond the automatically-provided `GITHUB_TOKEN`.

Open pull requests also build and push, tagged `dev-<number>` (and
`dev-<number>-truenas` for the TrueNAS variant), so you can pull and test
a PR's changes without building locally:

```bash
docker pull ghcr.io/<owner>/<repo>:dev-<number>
```

These `dev-*` tags are never promoted to `latest` and aren't cleaned up
automatically — prune stale ones from the package's GHCR page once a PR
merges or is closed.

### Semantic versioning

`.github/workflows/release.yml` runs [semantic-release](https://semantic-release.gitbook.io/)
on every push to `main`. It inspects commit messages since the last release
and, if any warrant a version bump, creates a `vX.Y.Z` git tag and GitHub
release automatically — which in turn triggers `docker-publish.yml` to build
and push that version's image tag to GHCR.

Commit messages must follow [Conventional Commits](https://www.conventionalcommits.org/)
for versioning to work:

| Prefix | Bump |
|---|---|
| `fix:` | patch |
| `feat:` | minor |
| `feat!:` / `BREAKING CHANGE:` footer | major |
| `chore:`, `docs:`, `refactor:`, etc. | none |

Releases and their notes are visible under the repo's **Releases** page.

## Security notes

- This repository contains no real hostnames, credentials, or topics —
  configure all of that via environment variables at deploy time.
- `.env` and downloaded MIB files are gitignored to prevent accidental
  leakage of site-specific configuration.
- MQTT runs in plaintext (port 1883) by design here, relying on the
  Tailscale tunnel for encryption. Make sure your Mosquitto broker only
  accepts connections from your Tailscale interface/subnet.

#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Docker/LXC wrapper
# - Ensures <base>/options.json exists (default if missing)
# - Reads external MQTT settings from options.json
# - Exports MQTT_* env vars
# - Runs core bridge (/usr/bin/bridge.sh)
# ============================================================

BASE="${WMBUS_BASE:-/config}"
export WMBUS_BASE="${BASE}"

OPTIONS_JSON="${BASE}/options.json"
mkdir -p "${BASE}"

if [[ ! -f "${OPTIONS_JSON}" ]]; then
  cat > "${OPTIONS_JSON}" <<'EOFJSON'
{
  "raw_topic": "wmbusmeters/raw/#",
  "state_prefix": "wmbusmeters",
  "state_retain": true,

  "discovery": true,
  "discovery_prefix": "homeassistant",
  "discovery_retain": true,

  "filter_hex_only": false,
  "debug_every_n": 0,
  "loglevel": "normal",

  "external_mqtt_host": "mosquitto",
  "external_mqtt_port": 1883,
  "external_mqtt_username": "",
  "external_mqtt_password": "",

  "meters": []
}
EOFJSON
  echo "[wmbus-bridge] Created default ${OPTIONS_JSON} (edit it + restart container)."
fi

MQTT_HOST="$(jq -r '.external_mqtt_host // .mqtt.host // "mosquitto"' "${OPTIONS_JSON}")"
MQTT_PORT="$(jq -r '.external_mqtt_port // .mqtt.port // 1883' "${OPTIONS_JSON}")"
MQTT_USER="$(jq -r '.external_mqtt_username // .mqtt.username // ""' "${OPTIONS_JSON}")"
MQTT_PASS="$(jq -r '.external_mqtt_password // .mqtt.password // ""' "${OPTIONS_JSON}")"

export MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASS

echo "[wmbus-bridge] Starting core bridge..."
exec /usr/bin/bridge.sh

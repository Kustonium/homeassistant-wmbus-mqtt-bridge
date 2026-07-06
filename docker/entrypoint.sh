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
  "raw_topic": "wmbus/+/telegram",
  "loglevel": "normal",
  "filter_hex_only": true,
  "debug_every_n": 0,

  "search_mode": false,
  "search_expected_value_m3": 0,
  "search_tolerance_m3": 0.05,
  "search_delta_mode": false,
  "search_min_delta_m3": 0.001,
  "search_topic": "wmbus/search/candidates",

  "discovery_enabled": true,
  "discovery_prefix": "homeassistant",
  "discovery_retain": true,

  "state_prefix": "wmbusmeters",
  "state_retain": false,

  "mqtt_mode": "external",
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

# One bounded startup probe (mirrors run.sh's diagnose_configured_broker in
# the HA add-on). bridge.sh's own wait_for_mqtt retry loop swallows the
# mosquitto error output, so without this the log only ever says "MQTT not
# ready" and the WebUI tile says offline — with no way to tell a wrong
# address from rejected credentials. Non-fatal either way: bridge.sh keeps
# retrying exactly as before.
probe_args=( -h "${MQTT_HOST}" -p "${MQTT_PORT}" -t 'homeassistant/status' -E )
[[ -n "${MQTT_USER}" && "${MQTT_USER}" != "null" ]] && probe_args+=( -u "${MQTT_USER}" )
[[ -n "${MQTT_PASS}" && "${MQTT_PASS}" != "null" ]] && probe_args+=( -P "${MQTT_PASS}" )
if probe_out="$(timeout 6 mosquitto_sub "${probe_args[@]}" 2>&1)"; then
  echo "[wmbus-bridge] MQTT broker ${MQTT_HOST}:${MQTT_PORT} verified (connect + subscribe OK)."
elif grep -qiE 'not authori[sz]ed|bad user ?name or password' <<<"${probe_out}"; then
  echo "[wmbus-bridge][WARN] MQTT broker ${MQTT_HOST}:${MQTT_PORT} is up but REJECTED the credentials — check external_mqtt_username/external_mqtt_password in ${OPTIONS_JSON}."
else
  echo "[wmbus-bridge][WARN] MQTT broker ${MQTT_HOST}:${MQTT_PORT} did not respond to a probe — check the address/port and container network; the bridge will keep retrying."
fi

WEBUI_PORT="${WEBUI_PORT:-8099}"
export WEBUI_PORT

echo "[wmbus-bridge] Starting WebGUI on port ${WEBUI_PORT}..."
/usr/bin/python3 /usr/bin/webui.py &

echo "[wmbus-bridge] Starting core bridge..."
/usr/bin/bridge.sh &
BRIDGE_PID=$!

# PID 1 must stay THIS shell (no exec): the WebUI restart button in Docker
# mode signals PID 1 with SIGTERM, and that only stops the container when
# PID 1 installs a handler that exits — bridge.sh's own TERM trap
# (stop_listen_instance) cleans up but does not exit, and SIGKILL to PID 1
# from inside the namespace is ignored by the kernel. The container comes
# back only under a restart policy (docker/examples compose:
# restart: unless-stopped); without one, "restart" degrades to "stop".
term_handler() {
  echo "[wmbus-bridge] SIGTERM received — stopping container (the restart policy brings it back if configured)."
  kill -TERM "${BRIDGE_PID}" 2>/dev/null || true
  exit 143
}
trap term_handler TERM INT

wait "${BRIDGE_PID}"
exit $?

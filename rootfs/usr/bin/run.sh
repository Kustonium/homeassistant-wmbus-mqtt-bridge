#!/usr/bin/with-contenv bashio
set -euo pipefail

bashio::log.info "RUN.SH: bashio OK"

export CONFIG_PATH=/data/options.json

# --- MQTT z HA service "mqtt:need" ---
MQTT_HOST="$(bashio::services mqtt "host")"
MQTT_PORT="$(bashio::services mqtt "port")"
MQTT_USER="$(bashio::services mqtt "username")"
MQTT_PASS="$(bashio::services mqtt "password")"

bashio::log.info "MQTT broker: ${MQTT_HOST}:${MQTT_PORT}"

# --- opcje addona ---
RAW_TOPIC="$(bashio::config 'raw_topic')"
METERS_JSON="$(bashio::config 'meters')"

bashio::log.info "Subscribing to: ${RAW_TOPIC}"

# --- generuj config dla wmbusmeters (stdin:hex) ---
CONF_DIR="/data"
CONF_FILE="${CONF_DIR}/wmbusmeters.conf"
mkdir -p "${CONF_DIR}"

{
  echo "device=stdin:hex"
  echo "loglevel=normal"
  echo "mqtt_host=${MQTT_HOST}"
  echo "mqtt_port=${MQTT_PORT}"
  echo "mqtt_topic=wmbusmeters"
  echo ""
  echo "# generated from addon options"
  echo "${METERS_JSON}" | jq -r '
    .[] |
    "meter=\(.type)\n" +
    "id=\(.meter_id|ascii_downcase|ltrimstr("0x"))\n" +
    "name=\(.id)\n" +
    "mode=\(.mode)\n"
  ' 2>/dev/null || true
} > "${CONF_FILE}"

bashio::log.info "Generated ${CONF_FILE}:"
sed -n '1,200p' "${CONF_FILE}" | while IFS= read -r line; do bashio::log.info "${line}"; done

# --- SUB -> STDIN wmbusmeters ---
# UWAGA: wmbusmeters --useconfig oczekuje KATALOGU, nie pliku.
mosquitto_sub \
  -h "${MQTT_HOST}" -p "${MQTT_PORT}" \
  ${MQTT_USER:+-u "${MQTT_USER}"} \
  ${MQTT_PASS:+-P "${MQTT_PASS}"} \
  -t "${RAW_TOPIC}" -v \
| awk '{print $NF}' \
| tee /tmp/wmbus_raw.log \
| wmbusmeters --useconfig="${CONF_DIR}" --verbose

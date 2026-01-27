#!/usr/bin/with-contenv bashio
set -euo pipefail

TOPIC="wmbus_bridge/sensor/wm-bus_raw_data"

MQTT_HOST="$(bashio::services mqtt host)"
MQTT_PORT="$(bashio::services mqtt port)"
MQTT_USER="$(bashio::services mqtt username || true)"
MQTT_PASS="$(bashio::services mqtt password || true)"

bashio::log.info "MQTT broker: ${MQTT_HOST}:${MQTT_PORT}"
bashio::log.info "Subscribing to: ${TOPIC}  and  ${TOPIC}/#"

ARGS="-h ${MQTT_HOST} -p ${MQTT_PORT} -v -t ${TOPIC} -t ${TOPIC}/#"

if [ -n "${MQTT_USER:-}" ] && [ -n "${MQTT_PASS:-}" ]; then
  ARGS="${ARGS} -u ${MQTT_USER} -P ${MQTT_PASS}"
fi

exec mosquitto_sub ${ARGS} | while IFS= read -r line; do
  echo "RAW: $line"
done

#!/usr/bin/with-contenv bashio
set -euo pipefail

TOPIC="wmbus_bridge/sensor/wm-bus_raw_data/state"

MQTT_HOST="$(bashio::services mqtt host)"
MQTT_PORT="$(bashio::services mqtt port)"
MQTT_USER="$(bashio::services mqtt username)"
MQTT_PASSWORD="$(bashio::services mqtt password)"

bashio::log.info "TEST MQTT SUB: ${MQTT_HOST}:${MQTT_PORT} topic=${TOPIC}"

mosquitto_sub \
  -h "${MQTT_HOST}" -p "${MQTT_PORT}" \
  -u "${MQTT_USER}" -P "${MQTT_PASSWORD}" \
  -t "${TOPIC}"
  
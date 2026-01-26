#!/usr/bin/with-contenv bashio
set -euo pipefail

TOPIC="$(bashio::config 'mqtt_topic')"

MQTT_HOST="$(bashio::services mqtt 'host')"
MQTT_PORT="$(bashio::services mqtt 'port')"
MQTT_USER="$(bashio::services mqtt 'username')"
MQTT_PASS="$(bashio::services mqtt 'password')"

bashio::log.info "wMBus MQTT Bridge START"
bashio::log.info "Listening on MQTT topic: ${TOPIC}"
bashio::log.info "MQTT: ${MQTT_HOST}:${MQTT_PORT}"

exec mosquitto_sub \
  -h "${MQTT_HOST}" -p "${MQTT_PORT}" \
  -u "${MQTT_USER}" -P "${MQTT_PASS}" \
  -t "${TOPIC}" | while read -r line; do
    bashio::log.info "RX RAW: ${line}"
  done

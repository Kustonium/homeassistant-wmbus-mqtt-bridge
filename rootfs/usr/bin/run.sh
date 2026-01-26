#!/usr/bin/with-contenv bashio
set -e

TOPIC=$(bashio::config 'mqtt_topic')

bashio::log.info "wMBus MQTT Bridge START"
bashio::log.info "Listening on MQTT topic: $TOPIC"

mosquitto_sub \
  -h core-mosquitto \
  -t "$TOPIC" | while read -r line; do
    bashio::log.info "RX RAW: $line"
done

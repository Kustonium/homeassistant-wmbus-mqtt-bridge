#!/usr/bin/with-contenv bashio

bashio::log.info "wMBus MQTT Bridge started!"

MQTT_TOPIC=$(bashio::config "mqtt_topic" "wmbus/raw")
bashio::log.info "Topic: ${MQTT_TOPIC}"

while true; do
    sleep 3600
done

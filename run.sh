#!/usr/bin/env bash
set -e

echo "===================================="
echo " TEST RAW MQTT - NC"
echo "===================================="

MQTT_HOST="${MQTT_HOST:-core-mosquitto}"
MQTT_PORT="${MQTT_PORT:-1883}"

echo "Łączę przez nc z $MQTT_HOST:$MQTT_PORT..."
echo "Wysyłam SUBSCRIBE..."

# MQTT CONNECT + SUBSCRIBE (raw protocol)
printf '\x10\x0e\x00\x04MQTT\x04\x02\x00\x3c\x00\x00' | nc "$MQTT_HOST" "$MQTT_PORT" &
sleep 1
printf '\x82\x13\x00\x01\x00\x0ewmbus_bridge/debug\x00' | nc "$MQTT_HOST" "$MQTT_PORT"

echo "Nasłuchuję..."
nc "$MQTT_HOST" "$MQTT_PORT" | hexdump -C

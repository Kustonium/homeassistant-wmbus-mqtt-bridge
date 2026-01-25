#!/usr/bin/env bash
set -e

echo "===================================="
echo " TEST - CZY WIDZĘ RAW Z MQTT?"
echo "===================================="

# Home Assistant automatycznie dostarcza te zmienne gdy masz "services: - mqtt:need"
MQTT_HOST="${MQTT_HOST:-core-mosquitto}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"

echo "MQTT Host: $MQTT_HOST:$MQTT_PORT"
echo "User: $MQTT_USER"
echo "Nasłuchuję topic: wmbus_bridge/debug"
echo "Czekam na dane..."

# Jeśli są credentials
if [ -n "$MQTT_USER" ]; then
    mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "wmbus_bridge/debug" -v | while read -r line; do
        echo "========================================="
        echo "OTRZYMANO DANE:"
        echo "$line"
        echo "========================================="
    done
else
    # Bez auth
    mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -t "wmbus_bridge/debug" -v | while read -r line; do
        echo "========================================="
        echo "OTRZYMANO DANE:"
        echo "$line"
        echo "========================================="
    done
fi

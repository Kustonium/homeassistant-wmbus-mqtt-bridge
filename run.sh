#!/usr/bin/env bash
set -e

echo "===================================="
echo " TEST - CZY WIDZĘ RAW Z MQTT?"
echo "===================================="

# Pobierz dane MQTT z Supervisor
TOKEN="${SUPERVISOR_TOKEN}"
MQTT_DATA=$(curl -s -H "Authorization: Bearer ${TOKEN}" http://supervisor/services/mqtt)

MQTT_HOST=$(echo "$MQTT_DATA" | jq -r '.data.host')
MQTT_PORT=$(echo "$MQTT_DATA" | jq -r '.data.port')
MQTT_USER=$(echo "$MQTT_DATA" | jq -r '.data.username')
MQTT_PASS=$(echo "$MQTT_DATA" | jq -r '.data.password')

echo "MQTT Host: $MQTT_HOST:$MQTT_PORT"
echo "Nasłuchuję topic: wmbus_bridge/debug"
echo "Czekam na dane..."

# Użyj mosquitto_sub z credentials
mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "wmbus_bridge/debug" -v | while read -r line; do
    echo "========================================="
    echo "OTRZYMANO DANE:"
    echo "$line"
    echo "========================================="
done

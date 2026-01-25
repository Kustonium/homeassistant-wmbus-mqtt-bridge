#!/usr/bin/env bash

echo "===================================="
echo " TEST - CZY WIDZĘ RAW Z MQTT?"
echo "===================================="

sleep 5

TOKEN=$(printenv SUPERVISOR_TOKEN)

echo "Nasłuchuję topic: wmbus_bridge/debug"
echo "Czekam na dane..."

# Subskrybuj przez HA MQTT API
while true; do
    PAYLOAD=$(curl -s -X GET \
        -H "Authorization: Bearer $TOKEN" \
        "http://supervisor/core/api/states/sensor.wmbus_bridge_debug" 2>/dev/null)
    
    if [ ! -z "$PAYLOAD" ]; then
        echo "========================================="
        echo "OTRZYMANO DANE:"
        echo "$PAYLOAD"
        echo "========================================="
    fi
    
    sleep 2
done

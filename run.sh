#!/usr/bin/env bash

echo "===================================="
echo " TEST - CZY WIDZĘ RAW Z MQTT?"
echo "===================================="

sleep 5

echo "Nasłuchuję wmbus/#"

mosquitto_sub -h core-mosquitto -v -t "wmbus/#" | while read -r topic message
do
    echo "========================================="
    echo "TOPIC: $topic"
    echo "RAW:   $message"
    echo "========================================="
done

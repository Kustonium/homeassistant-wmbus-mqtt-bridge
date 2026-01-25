#!/bin/sh
TOPIC="$(jq -r .mqtt_topic /data/options.json)"

echo "[INFO] Subscribing to MQTT topic: $TOPIC"

mosquitto_sub -h core-mosquitto -t "$TOPIC" | while read line; do
  echo "$line" | wmbusmeters --useconfig=/etc --overridedevice=stdin:hex:t1
done

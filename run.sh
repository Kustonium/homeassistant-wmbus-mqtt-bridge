#!/bin/sh
echo "[wMBus MQTT Bridge] starting RAW MQTT listener"

python3 - << 'EOF'
import os
import paho.mqtt.client as mqtt

MQTT_HOST = os.environ.get("MQTT_HOST")
MQTT_PORT = int(os.environ.get("MQTT_PORT", 1883))
MQTT_USER = os.environ.get("MQTT_USERNAME")
MQTT_PASS = os.environ.get("MQTT_PASSWORD")
TOPIC = os.environ.get("MQTT_TOPIC", "wmbus/raw")

def on_connect(client, userdata, flags, rc):
    print(f"[MQTT] Connected with code {rc}")
    client.subscribe(TOPIC)

def on_message(client, userdata, msg):
    payload = msg.payload.decode(errors="ignore")
    print(f"[RAW] topic={msg.topic} payload={payload}")

client = mqtt.Client()
if MQTT_USER:
    client.username_pw_set(MQTT_USER, MQTT_PASS)

client.on_connect = on_connect
client.on_message = on_message

client.connect(MQTT_HOST, MQTT_PORT, 60)
client.loop_forever()
EOF

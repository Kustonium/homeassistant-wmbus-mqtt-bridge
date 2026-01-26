#!/usr/bin/with-contenv sh

python3 - << 'EOF'
import paho.mqtt.client as mqtt
import os

host = os.getenv("MQTT_HOST", "core-mosquitto")
port = int(os.getenv("MQTT_PORT", "1883"))
topic = os.getenv("MQTT_TOPIC", "wmbus/raw")

def on_message(client, userdata, msg):
    print("RAW:", msg.payload.decode(errors="ignore"))

client = mqtt.Client()
client.connect(host, port, 60)
client.subscribe(topic)
client.loop_forever()
EOF

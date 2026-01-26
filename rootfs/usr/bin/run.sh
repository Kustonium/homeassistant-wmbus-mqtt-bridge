#!/usr/bin/with-contenv bashio
set -euo pipefail

TOPIC="wmbus_bridge/sensor/wm-bus_raw_data/state"

MQTT_HOST="$(bashio::services mqtt host)"
MQTT_PORT="$(bashio::services mqtt port)"
MQTT_USER="$(bashio::services mqtt username)"
MQTT_PASSWORD="$(bashio::services mqtt password)"

bashio::log.info "RAW TEST via python"
bashio::log.info "Broker: ${MQTT_HOST}:${MQTT_PORT}"
bashio::log.info "Topic : ${TOPIC}"

exec python3 - <<'EOF'
import paho.mqtt.client as mqtt

MQTT_HOST = "${MQTT_HOST}"
MQTT_PORT = int("${MQTT_PORT}")
TOPIC = "${TOPIC}"
USER = "${MQTT_USER}"
PASSWORD = "${MQTT_PASSWORD}"

def on_connect(client, userdata, flags, rc):
    print(f"[RAW] connected rc={rc}", flush=True)
    client.subscribe(TOPIC)

def on_message(client, userdata, msg):
    print("====== RAW MQTT ======", flush=True)
    print("topic:", msg.topic, flush=True)
    print("payload:", msg.payload, flush=True)
    try:
        print("utf8:", msg.payload.decode(), flush=True)
    except Exception:
        print("utf8: <binary>", flush=True)
    print("======================", flush=True)

client = mqtt.Client()
client.username_pw_set(USER, PASSWORD)
client.on_connect = on_connect
client.on_message = on_message

client.connect(MQTT_HOST, MQTT_PORT, 60)
client.loop_forever()
EOF

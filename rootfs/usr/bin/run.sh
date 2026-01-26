name: "wMBus MQTT Bridge"
description: "DEBUG addon – listens for RAW wMBus frames over MQTT"
version: "0.1.0"
slug: "wmbus_mqtt_bridge"
arch:
  - amd64
  - armv7
  - armhf
  - aarch64

init: false
services:
  - mqtt:need

options:
  mqtt_topic: "wmbus/raw"

schema:
  mqtt_topic: str
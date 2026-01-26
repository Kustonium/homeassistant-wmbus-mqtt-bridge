# wMBus MQTT Bridge ( NOT WORKED !!!!! )

Home Assistant add-on that feeds RAW wM-Bus T1 HEX frames from **ESP32** (via MQTT)
directly into **wmbusmeters** using `stdin:hex:t1`.

## How it works
ESP32 → MQTT (RAW HEX) → this add-on → stdin → wmbusmeters → MQTT discovery → HA entities

No USB dongle. No RTL-SDR.

## Requirements
- ESP32 sending RAW T1 frames as HEX over MQTT
- Official wmbusmeters configuration (meters defined via GUI)

## MQTT
Default topic: `wmbus/raw`

Payload example:
```
33839FD937072E6AE811D831E38760C3FBF80CBF89D8BE0CFD613891664CEE0B
```

## License
MIT

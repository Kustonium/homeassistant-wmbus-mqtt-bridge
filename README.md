## AI disclosure

Most of the code and documentation in this repository were produced using AI.  
The maintainer mainly served as a “human interface” (requirements, testing, and integration in Home Assistant).




# wMBus MQTT Bridge

Home Assistant add-on that takes **RAW wM-Bus telegrams as HEX** from an **ESP32** (via MQTT),
feeds them into **wmbusmeters** using `device=stdin:hex`,
then publishes:

- decoded JSON telegrams back to MQTT (per meter id)
- **MQTT Discovery** so entities appear automatically in Home Assistant

## How it works
ESP32 → MQTT (HEX payload) → this add-on → wmbusmeters (stdin:hex) → JSON → MQTT + Discovery → HA entities

No USB dongle. No RTL-SDR.

## Requirements
- ESP32 that publishes **full wM-Bus telegrams as HEX** to MQTT (payload only)
- Mosquitto / MQTT broker available in Home Assistant (official MQTT add-on is fine)

## MQTT input
Default topic:
- `wmbus_bridge/telegram`

Payload example (HEX only, no spaces required):
4C44B4092182520317067A120000000C1387490100046D24285C310F8F00000000000000000000000000000000002F0000B40000530100B60100100200B50200400300BE03006F040031050000

csharp
Skopiuj kod

## Listen mode (diagnostics)
If you leave `meters: []` empty, the add-on starts in LISTEN MODE and prints lines like:
Received telegram from: 03528221
driver: hydrodigit

python
Skopiuj kod

**Use the shown 8-digit value (DLL-ID) as `meter_id`.**
Keep leading zeros.

## Configuration: meters
Example:
```yaml
meters:
  - id: "Zimna Woda"
    meter_id: "03528221"
    type: "hydrodigit"
    key: "NOKEY"
  - id: "Ciepła woda"
    meter_id: "03534159"
    type: "hydrodigit"
    key: "NOKEY"
Notes
mode is NOT used (and must not be written into wmbusmeters meter files).

key is optional in add-on config. If missing, NOKEY is used.
In the schema you will see key: str? where ? means "optional".

MQTT output
States (JSON)
For each meter id, the add-on publishes decoded JSON to:

wmbusmeters/<ID>/state

Example:

wmbusmeters/03528221/state

MQTT Discovery
Discovery configs are published under:

homeassistant/sensor/wmbus_<ID>/total_m3/config

So entities appear automatically in:
Settings → Devices & services → MQTT

License
MIT
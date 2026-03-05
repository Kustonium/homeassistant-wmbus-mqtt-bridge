# Home Assistant Add-on: wMBus MQTT Bridge

## 馃嚨馃嚤 Opis (PL)

Ten dodatek Home Assistant jest rozszerzeniem oraz forkiem oficjalnego projektu **wmbusmeters-ha-addon**, kt贸ry bazuje na narz臋dziu **wmbusmeters**.

Celem projektu jest dekodowanie telegram贸w Wireless M-Bus (C1 / T1 / S1) w Home Assistant **bez u偶ycia lokalnego dongla radiowego** (USB/RTL-SDR). Zamiast tego wykorzystuje **zewn臋trzne odbiorniki** (np. ESP32/gateway/bridge) i **MQTT jako kana艂 wej艣ciowy**.

### Problem, kt贸ry rozwi膮zuje ten add-on

Oryginalny **wmbusmeters-ha-addon**:
- zak艂ada, 偶e odbi贸r radiowy odbywa si臋 lokalnie (USB / serial / RTL-SDR),
- nie przewiduje podania telegram贸w z zewn臋trznego 藕r贸d艂a,
- nie obs艂uguje wej艣cia **STDIN** jako 藕r贸d艂a danych.

W praktyce oznacza to, 偶e odbiorniki ESP32, gatewaye, mosty radiowe (bridge) i w艂asne odbiorniki wM-Bus nie mog膮 by膰 u偶yte bezpo艣rednio jako 藕r贸d艂o danych dla wmbusmeters w oficjalnym add-onie.

### Rozwi膮zanie zastosowane w tym projekcie

Ten fork wprowadza alternatywn膮 艣cie偶k臋 wej艣ciow膮 opart膮 o MQTT. Add-on dzia艂a jako most (bridge) pomi臋dzy zewn臋trznym 藕r贸d艂em telegram贸w wM-Bus a silnikiem dekoduj膮cym **wmbusmeters**.

### Architektura przep艂ywu danych

```
ESP32 / Gateway / Bridge
鈫?MQTT (surowy telegram wM-Bus w formacie HEX)
鈫?wmbusmeters (stdin:hex)
鈫?MQTT (JSON)
鈫?Home Assistant (MQTT Discovery)
```

### Kluczowe cechy

- **MQTT jako wej艣cie danych** 鈥?surowe telegramy wM-Bus (HEX) odbierane z wybranego tematu MQTT.
- **Wej艣cie STDIN dla wmbusmeters** 鈥?telegramy przekazywane przez `stdin:hex`, czego oryginalny add-on nie obs艂uguje.
- **Pe艂ne dekodowanie przez wmbusmeters** 鈥?projekt nie zast臋puje wmbusmeters, lecz wykorzystuje go w ca艂o艣ci.
- **MQTT + Home Assistant Discovery** 鈥?dane publikowane w MQTT i automatycznie rejestrowane w HA.
- **Tryb LISTEN (nas艂uch)** 鈥?gdy lista `meters` jest pusta, add-on wypisuje w logach wszystkie s艂yszane liczniki wraz z sugerowanym driverem.

### Wymagania (WA呕NE)

Add-on domy艣lnie korzysta z wewn臋trznego brokera MQTT Home Assistant (Mosquitto add-on), ale mo偶e pracowa膰 z brokerem zewn臋trznym.

**Tryby brokera (`mqtt_mode`):**
- `auto` (domy艣lnie) 鈥?u偶ywa brokera HA je艣li dost臋pny, w przeciwnym razie zewn臋trzny
- `ha` 鈥?wymusza broker HA (Mosquitto add-on)
- `external` 鈥?zawsze u偶ywa ustawie艅 zewn臋trznych (`external_mqtt_host`, itd.)

---

### Konfiguracja w Home Assistant (GUI)

Konfiguracja odbywa si臋 przez interfejs graficzny dodatku 鈥?nie trzeba edytowa膰 plik贸w r臋cznie.

#### Krok 1 鈥?Tryb LISTEN (wykrycie licznik贸w)

Zostaw sekcj臋 **meters** pust膮 i uruchom addon. W logach pojawi膮 si臋 wykryte liczniki:

```
Received telegram from: 41553221
          manufacturer: (TCH) Techem
                  type: Cold water
                driver: mkradio3
=== NEW METER CANDIDATE DETECTED ===
Received telegram from: 41553221
Suggested driver: mkradio3
```

Zanotuj **8-cyfrowy numer** (`meter_id`) i sugerowany **driver**.

#### Krok 2 鈥?Dodanie licznika w GUI

W konfiguracji dodatku wype艂nij sekcj臋 **meters**:

| Pole | Opis | Przyk艂ad |
|------|------|---------|
| `id` | Twoja w艂asna nazwa sensora w HA | `woda_zimna_lazienka` |
| `meter_id` | 8-cyfrowy numer z trybu LISTEN | `41553221` |
| `type` | Driver z trybu LISTEN | `mkradio3` |
| `key` | Klucz szyfrowania (je艣li licznik szyfruje) | `00112233...` lub puste |

Je艣li licznik nie szyfruje telegram贸w, pole `key` pozostaw puste.

---

### Docker standalone (bez Home Assistant)

W trybie Docker konfiguracja odbywa si臋 przez plik `options.json`.

#### Szybki start (Docker Compose 鈥?DietPi/Ubuntu)

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
mkdir -p /home/wmbus-test
cp -a homeassistant-wmbus-mqtt-bridge/docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
docker compose up -d --build
docker compose logs -f wmbus
```

Je艣li widzisz `No meters configured -> LISTEN MODE` 鈥?kontener dzia艂a i czeka na telegramy.

#### Konfiguracja (Docker)

G艂贸wny plik: `./config/options.json` (wewn膮trz kontenera: `/config/options.json`).

Pliki pod `./config/etc/` s膮 **generowane automatycznie** przy ka偶dym starcie 鈥?nie edytuj ich r臋cznie, zostan膮 nadpisane.

**Pola wpisu licznika:**

| Pole | Opis |
|------|------|
| `id` | Twoja w艂asna etykieta (cz臋艣膰 tematu MQTT i nazwa sensora w HA) |
| `meter_id` | 8-cyfrowy numer seryjny licznika (z trybu LISTEN) |
| `type` | Driver wmbusmeters (z trybu LISTEN), lub `auto` |
| `type_other` | Niestandardowy driver 鈥?wype艂nij tylko gdy `type` = `other` |
| `key` | Klucz szyfrowania w formacie HEX, lub `NOKEY` |

Przyk艂ad `options.json`:

```json
{
  "raw_topic": "wmbus_bridge/telegram",
  "loglevel": "normal",
  "filter_hex_only": true,
  "discovery_enabled": true,
  "state_prefix": "wmbusmeters",
  "mqtt_mode": "external",
  "external_mqtt_host": "192.168.1.10",
  "external_mqtt_port": 1883,
  "external_mqtt_username": "user",
  "external_mqtt_password": "pass",
  "meters": [
    {
      "id": "woda_zimna_lazienka",
      "meter_id": "41553221",
      "type": "mkradio3",
      "key": "NOKEY"
    },
    {
      "id": "cieplo_mieszkanie",
      "meter_id": "03534275",
      "type": "hydrodigit",
      "key": "00112233445566778899AABBCCDDEEFF"
    }
  ]
}
```

Po zmianach zrestartuj kontener:

```bash
docker compose restart wmbus
```

#### Uwagi

- Katalog `./config` musi by膰 **zapisywalny** (nie montuj jako `:ro`) 鈥?bridge tworzy tam `options.json` i konfiguracj臋 wmbusmeters.
- Domy艣lny `raw_topic` to `wmbus_bridge/telegram` 鈥?upewnij si臋, 偶e Tw贸j odbiornik publikuje na ten sam temat.

#### R臋czny test MQTT

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbus_bridge/telegram' -m '<HEX_TELEGRAM>'
mosquitto_sub -h localhost -p 1883 -t 'wmbusmeters/#' -v
```

---

### Przeznaczenie

Ten add-on jest szczeg贸lnie przydatny gdy:
- odbi贸r radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),
- chcesz u偶ywa膰 wmbusmeters bez dongla USB,
- masz w艂asny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

鈿狅笍 **Nie instaluj oficjalnego add-onu wmbusmeters r贸wnolegle.** Ten add-on zawiera w艂asn膮 instancj臋 wmbusmeters i zast臋puje go w tym scenariuszu.

### Projekty bazowe (upstream)

- **wmbusmeters** 鈥?https://github.com/wmbusmeters/wmbusmeters (GPL-3.0)
- **wmbusmeters-ha-addon** 鈥?https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)

### Licencja

Repozytorium zawiera i modyfikuje kod z projektu **wmbusmeters-ha-addon** obj臋tego licencj膮 GPL-3.0. Ca艂y projekt dystrybuowany jest na licencji:

**GNU General Public License v3.0 (GPL-3.0)**

---

## 馃嚞馃嚙 Description (EN)

This Home Assistant add-on is a fork and extension of the official **wmbusmeters-ha-addon**, based on **wmbusmeters**.

The purpose of this add-on is to decode Wireless M-Bus (C1 / T1 / S1) telegrams in Home Assistant **without a local radio dongle** (USB/RTL-SDR). Instead, it uses **external receivers** (ESP32/gateway/bridge) and **MQTT as the input transport**.

### The problem it solves

The original **wmbusmeters-ha-addon** assumes local radio reception and does not accept external telegram sources or STDIN input. ESP32-based receivers, gateways and custom wM-Bus bridges cannot be used directly as data sources with the official add-on.

### Solution

This fork introduces an MQTT-based input path:

```
ESP32 / Gateway / Bridge
鈫?MQTT (raw wM-Bus HEX telegram)
鈫?wmbusmeters (stdin:hex)
鈫?MQTT (JSON)
鈫?Home Assistant (MQTT Discovery)
```

### Key features

- MQTT input for raw wM-Bus telegrams
- STDIN support for wmbusmeters (`stdin:hex`)
- Full decoding handled by upstream wmbusmeters
- MQTT output with Home Assistant Discovery
- LISTEN mode: when `meters` list is empty, logs all detected meter IDs and suggested drivers

### Broker modes (`mqtt_mode`)

- `auto` (default) 鈥?use HA broker if available, otherwise external
- `ha` 鈥?force HA broker (Mosquitto add-on)
- `external` 鈥?always use external settings (`external_mqtt_host`, etc.)

---

### Configuration in Home Assistant (GUI)

Configuration is done through the add-on GUI 鈥?no manual file editing required.

#### Step 1 鈥?LISTEN mode (meter discovery)

Leave the **meters** list empty and start the add-on. The log will show all received telegrams:

```
Received telegram from: 41553221
          manufacturer: (TCH) Techem
                  type: Cold water
                driver: mkradio3
=== NEW METER CANDIDATE DETECTED ===
Received telegram from: 41553221
Suggested driver: mkradio3
```

Note the **8-digit number** (`meter_id`) and the suggested **driver**.

#### Step 2 鈥?Add a meter in the GUI

Fill in the **meters** section in the add-on configuration:

| Field | Description | Example |
|-------|-------------|---------|
| `id` | Your own sensor name in HA | `cold_water_bathroom` |
| `meter_id` | 8-digit number from LISTEN mode | `41553221` |
| `type` | Driver from LISTEN mode | `mkradio3` |
| `key` | Encryption key (if meter encrypts) | `00112233...` or leave empty |

If the meter does not encrypt telegrams, leave `key` empty.

---

### Docker standalone (without Home Assistant)

In Docker mode, configuration is done via `options.json`.

#### Quick start (Docker Compose 鈥?DietPi/Ubuntu)

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
mkdir -p /home/wmbus-test
cp -a homeassistant-wmbus-mqtt-bridge/docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
docker compose up -d --build
docker compose logs -f wmbus
```

If you see `No meters configured -> LISTEN MODE` 鈥?the container is running and waiting for telegrams.

#### Configuration (Docker)

Main file: `./config/options.json` (inside container: `/config/options.json`).

Files under `./config/etc/` are **auto-generated on startup** 鈥?do not edit them manually.

**Meter fields:**

| Field | Description |
|-------|-------------|
| `id` | Your label (used in MQTT topic and HA sensor name) |
| `meter_id` | 8-digit serial number (from LISTEN mode) |
| `type` | wmbusmeters driver (from LISTEN mode), or `auto` |
| `type_other` | Custom driver name 鈥?only when `type` is `other` |
| `key` | Encryption key in HEX, or `NOKEY` |

Example `options.json`:

```json
{
  "raw_topic": "wmbus_bridge/telegram",
  "loglevel": "normal",
  "filter_hex_only": true,
  "discovery_enabled": true,
  "state_prefix": "wmbusmeters",
  "mqtt_mode": "external",
  "external_mqtt_host": "192.168.1.10",
  "external_mqtt_port": 1883,
  "external_mqtt_username": "user",
  "external_mqtt_password": "pass",
  "meters": [
    {
      "id": "cold_water_bathroom",
      "meter_id": "41553221",
      "type": "mkradio3",
      "key": "NOKEY"
    },
    {
      "id": "heat_apartment",
      "meter_id": "03534275",
      "type": "hydrodigit",
      "key": "00112233445566778899AABBCCDDEEFF"
    }
  ]
}
```

Restart after changes:

```bash
docker compose restart wmbus
```

#### Notes

- `./config` must be **writable** (do not mount as `:ro`) 鈥?the bridge creates `options.json` and wmbusmeters config there.
- Default `raw_topic` is `wmbus_bridge/telegram` 鈥?make sure your receiver publishes to the same topic.

#### Manual MQTT test

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbus_bridge/telegram' -m '<HEX_TELEGRAM>'
mosquitto_sub -h localhost -p 1883 -t 'wmbusmeters/#' -v
```

---

鈿狅笍 **Do not install the official wmbusmeters add-on in parallel.** This add-on bundles its own wmbusmeters instance and replaces it for this use case.

### Upstream projects

- wmbusmeters 鈥?https://github.com/wmbusmeters/wmbusmeters (GPL-3.0)
- wmbusmeters-ha-addon 鈥?https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)

### License

This repository contains and modifies code derived from **wmbusmeters-ha-addon** (GPL-3.0). The entire project is distributed under:

**GNU General Public License v3.0 (GPL-3.0)**

# Home Assistant Add-on: wMBus MQTT Bridge

## ???? Opis (PL)

Ten dodatek Home Assistant jest rozszerzeniem oraz forkiem oficjalnego projektu **wmbusmeters-ha-addon**, kt車ry bazuje na narz?dziu **wmbusmeters**.

Celem projektu jest dekodowanie telegram車w Wireless M-Bus (C1 / T1 / S1) w Home Assistant **bez u?ycia lokalnego dongla radiowego** (USB/RTL-SDR). Zamiast tego wykorzystuje **zewn?trzne odbiorniki** (np. ESP32/gateway/bridge) i **MQTT jako kana? wej?ciowy**.

### Problem, kt車ry rozwi?zuje ten add-on

Oryginalny **wmbusmeters-ha-addon**:
- zak?ada, ?e odbi車r radiowy odbywa si? lokalnie (USB / serial / RTL-SDR),
- nie przewiduje podania telegram車w z zewn?trznego ?r車d?a,
- nie obs?uguje wej?cia **STDIN** jako ?r車d?a danych.

W praktyce oznacza to, ?e odbiorniki ESP32, gatewaye, mosty radiowe (bridge) i w?asne odbiorniki wM-Bus nie mog? by? u?yte bezpo?rednio jako ?r車d?o danych dla wmbusmeters w oficjalnym add-onie.

### Rozwi?zanie zastosowane w tym projekcie

Ten fork wprowadza alternatywn? ?cie?k? wej?ciow? opart? o MQTT. Add-on dzia?a jako most (bridge) pomi?dzy zewn?trznym ?r車d?em telegram車w wM-Bus a silnikiem dekoduj?cym **wmbusmeters**.

### Architektura przep?ywu danych

```
ESP32 / Gateway / Bridge
↙ MQTT (surowy telegram wM-Bus w formacie HEX)
↙ wmbusmeters (stdin:hex)
↙ MQTT (JSON)
↙ Home Assistant (MQTT Discovery)
```

### Kluczowe cechy

- **MQTT jako wej?cie danych** 〞 surowe telegramy wM-Bus (HEX) odbierane z wybranego tematu MQTT.
- **Wej?cie STDIN dla wmbusmeters** 〞 telegramy przekazywane przez `stdin:hex`, czego oryginalny add-on nie obs?uguje.
- **Pe?ne dekodowanie przez wmbusmeters** 〞 projekt nie zast?puje wmbusmeters, lecz wykorzystuje go w ca?o?ci.
- **MQTT + Home Assistant Discovery** 〞 dane publikowane w MQTT i automatycznie rejestrowane w HA.
- **Tryb LISTEN (nas?uch)** 〞 gdy lista `meters` jest pusta, add-on wypisuje w logach wszystkie s?yszane liczniki wraz z sugerowanym driverem.

### Wymagania (WA?NE)

Add-on domy?lnie korzysta z wewn?trznego brokera MQTT Home Assistant (Mosquitto add-on), ale mo?e pracowa? z brokerem zewn?trznym.

**Tryby brokera (`mqtt_mode`):**
- `auto` (domy?lnie) 〞 u?ywa brokera HA je?li dost?pny, w przeciwnym razie zewn?trzny
- `ha` 〞 wymusza broker HA (Mosquitto add-on)
- `external` 〞 zawsze u?ywa ustawie里 zewn?trznych (`external_mqtt_host`, itd.)

---

### Konfiguracja w Home Assistant (GUI)

Konfiguracja odbywa si? przez interfejs graficzny dodatku 〞 nie trzeba edytowa? plik車w r?cznie.

#### Krok 1 〞 Tryb LISTEN (wykrycie licznik車w)

Zostaw sekcj? **meters** pust? i uruchom addon. W logach pojawi? si? wykryte liczniki:

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

#### Krok 2 〞 Dodanie licznika w GUI

W konfiguracji dodatku wype?nij sekcj? **meters**:

| Pole | Opis | Przyk?ad |
|------|------|---------|
| `id` | Twoja w?asna nazwa sensora w HA | `woda_zimna_lazienka` |
| `meter_id` | 8-cyfrowy numer z trybu LISTEN | `41553221` |
| `type` | Driver z trybu LISTEN | `mkradio3` |
| `key` | Klucz szyfrowania (je?li licznik szyfruje) | `00112233...` lub puste |

Je?li licznik nie szyfruje telegram車w, pole `key` pozostaw puste.

---

### Docker standalone (bez Home Assistant)

W trybie Docker konfiguracja odbywa si? przez plik `options.json`.

#### Szybki start (Docker Compose 〞 DietPi/Ubuntu)

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
mkdir -p /home/wmbus-test
cp -a homeassistant-wmbus-mqtt-bridge/docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
docker compose up -d --build
docker compose logs -f wmbus
```

Je?li widzisz `No meters configured -> LISTEN MODE` 〞 kontener dzia?a i czeka na telegramy.

#### Konfiguracja (Docker)

G?車wny plik: `./config/options.json` (wewn?trz kontenera: `/config/options.json`).

Pliki pod `./config/etc/` s? **generowane automatycznie** przy ka?dym starcie 〞 nie edytuj ich r?cznie, zostan? nadpisane.

**Pola wpisu licznika:**

| Pole | Opis |
|------|------|
| `id` | Twoja w?asna etykieta (cz??? tematu MQTT i nazwa sensora w HA) |
| `meter_id` | 8-cyfrowy numer seryjny licznika (z trybu LISTEN) |
| `type` | Driver wmbusmeters (z trybu LISTEN), lub `auto` |
| `type_other` | Niestandardowy driver 〞 wype?nij tylko gdy `type` = `other` |
| `key` | Klucz szyfrowania w formacie HEX, lub `NOKEY` |

Przyk?ad `options.json`:

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

- Katalog `./config` musi by? **zapisywalny** (nie montuj jako `:ro`) 〞 bridge tworzy tam `options.json` i konfiguracj? wmbusmeters.
- Domy?lny `raw_topic` to `wmbus_bridge/telegram` 〞 upewnij si?, ?e Tw車j odbiornik publikuje na ten sam temat.

#### R?czny test MQTT

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbus_bridge/telegram' -m '<HEX_TELEGRAM>'
mosquitto_sub -h localhost -p 1883 -t 'wmbusmeters/#' -v
```

---

### Przeznaczenie

Ten add-on jest szczeg車lnie przydatny gdy:
- odbi車r radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),
- chcesz u?ywa? wmbusmeters bez dongla USB,
- masz w?asny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

?? **Nie instaluj oficjalnego add-onu wmbusmeters r車wnolegle.** Ten add-on zawiera w?asn? instancj? wmbusmeters i zast?puje go w tym scenariuszu.

### Projekty bazowe (upstream)

- **wmbusmeters** 〞 https://github.com/wmbusmeters/wmbusmeters (GPL-3.0)
- **wmbusmeters-ha-addon** 〞 https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)

### Licencja

Repozytorium zawiera i modyfikuje kod z projektu **wmbusmeters-ha-addon** obj?tego licencj? GPL-3.0. Ca?y projekt dystrybuowany jest na licencji:

**GNU General Public License v3.0 (GPL-3.0)**

---

## ???? Description (EN)

This Home Assistant add-on is a fork and extension of the official **wmbusmeters-ha-addon**, based on **wmbusmeters**.

The purpose of this add-on is to decode Wireless M-Bus (C1 / T1 / S1) telegrams in Home Assistant **without a local radio dongle** (USB/RTL-SDR). Instead, it uses **external receivers** (ESP32/gateway/bridge) and **MQTT as the input transport**.

### The problem it solves

The original **wmbusmeters-ha-addon** assumes local radio reception and does not accept external telegram sources or STDIN input. ESP32-based receivers, gateways and custom wM-Bus bridges cannot be used directly as data sources with the official add-on.

### Solution

This fork introduces an MQTT-based input path:

```
ESP32 / Gateway / Bridge
↙ MQTT (raw wM-Bus HEX telegram)
↙ wmbusmeters (stdin:hex)
↙ MQTT (JSON)
↙ Home Assistant (MQTT Discovery)
```

### Key features

- MQTT input for raw wM-Bus telegrams
- STDIN support for wmbusmeters (`stdin:hex`)
- Full decoding handled by upstream wmbusmeters
- MQTT output with Home Assistant Discovery
- LISTEN mode: when `meters` list is empty, logs all detected meter IDs and suggested drivers

### Broker modes (`mqtt_mode`)

- `auto` (default) 〞 use HA broker if available, otherwise external
- `ha` 〞 force HA broker (Mosquitto add-on)
- `external` 〞 always use external settings (`external_mqtt_host`, etc.)

---

### Configuration in Home Assistant (GUI)

Configuration is done through the add-on GUI 〞 no manual file editing required.

#### Step 1 〞 LISTEN mode (meter discovery)

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

#### Step 2 〞 Add a meter in the GUI

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

#### Quick start (Docker Compose 〞 DietPi/Ubuntu)

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
mkdir -p /home/wmbus-test
cp -a homeassistant-wmbus-mqtt-bridge/docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
docker compose up -d --build
docker compose logs -f wmbus
```

If you see `No meters configured -> LISTEN MODE` 〞 the container is running and waiting for telegrams.

#### Configuration (Docker)

Main file: `./config/options.json` (inside container: `/config/options.json`).

Files under `./config/etc/` are **auto-generated on startup** 〞 do not edit them manually.

**Meter fields:**

| Field | Description |
|-------|-------------|
| `id` | Your label (used in MQTT topic and HA sensor name) |
| `meter_id` | 8-digit serial number (from LISTEN mode) |
| `type` | wmbusmeters driver (from LISTEN mode), or `auto` |
| `type_other` | Custom driver name 〞 only when `type` is `other` |
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

- `./config` must be **writable** (do not mount as `:ro`) 〞 the bridge creates `options.json` and wmbusmeters config there.
- Default `raw_topic` is `wmbus_bridge/telegram` 〞 make sure your receiver publishes to the same topic.

#### Manual MQTT test

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbus_bridge/telegram' -m '<HEX_TELEGRAM>'
mosquitto_sub -h localhost -p 1883 -t 'wmbusmeters/#' -v
```

---

?? **Do not install the official wmbusmeters add-on in parallel.** This add-on bundles its own wmbusmeters instance and replaces it for this use case.

### Upstream projects

- wmbusmeters 〞 https://github.com/wmbusmeters/wmbusmeters (GPL-3.0)
- wmbusmeters-ha-addon 〞 https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)

### License

This repository contains and modifies code derived from **wmbusmeters-ha-addon** (GPL-3.0). The entire project is distributed under:

**GNU General Public License v3.0 (GPL-3.0)**

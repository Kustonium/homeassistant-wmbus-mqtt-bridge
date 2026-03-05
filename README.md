# Home Assistant Add-on: wMBus MQTT Bridge

## ?ƒV?? Opis (PL)

Ten dodatek Home Assistant jest rozszerzeniem oraz forkiem oficjalnego projektu **wmbusmeters-ha-addon**, kt?ry bazuje na narz?dziu **wmbusmeters**.

Celem projektu jest dekodowanie telegram?w Wireless M-Bus (C1 / T1 / S1) w Home Assistant **bez u∞∏ycia lokalnego dongla radiowego** (USB/RTL-SDR). Zamiast tego wykorzystuje **zewn?trzne odbiorniki** (np. ESP32/gateway/bridge) i **MQTT jako kanaﬂß wejÚ≈ciowy**.

### Problem, kt?ry rozwiÍÍzuje ten add-on

Oryginalny **wmbusmeters-ha-addon**:
- zakﬂßada, ∞∏e odbi?r radiowy odbywa si? lokalnie (USB / serial / RTL-SDR),
- nie przewiduje podania telegram?w z zewn?trznego √¬r?dﬂßa,
- nie obsﬂßuguje wejÚ≈cia **STDIN** jako √¬r?dﬂßa danych.

W praktyce oznacza to, ∞∏e odbiorniki ESP32, gatewaye, mosty radiowe (bridge) i wﬂßasne odbiorniki wM-Bus nie mogÍÍ byÍÓ u∞∏yte bezpoÚ≈rednio jako √¬r?dﬂßo danych dla wmbusmeters w oficjalnym add-onie.

### RozwiÍÍzanie zastosowane w tym projekcie

Ten fork wprowadza alternatywnÍÍ Ú≈cie∞∏k? wejÚ≈ciowÍÍ opartÍÍ o MQTT. Add-on dziaﬂßa jako most (bridge) pomi?dzy zewn?trznym √¬r?dﬂßem telegram?w wM-Bus a silnikiem dekodujÍÍcym **wmbusmeters**.

### Architektura przepﬂßywu danych

```
ESP32 / Gateway / Bridge
??MQTT (surowy telegram wM-Bus w formacie HEX)
??wmbusmeters (stdin:hex)
??MQTT (JSON)
??Home Assistant (MQTT Discovery)
```

### Kluczowe cechy

- **MQTT jako wejÚ≈cie danych** ‹d?surowe telegramy wM-Bus (HEX) odbierane z wybranego tematu MQTT.
- **WejÚ≈cie STDIN dla wmbusmeters** ‹d?telegramy przekazywane przez `stdin:hex`, czego oryginalny add-on nie obsﬂßuguje.
- **Peﬂßne dekodowanie przez wmbusmeters** ‹d?projekt nie zast?puje wmbusmeters, lecz wykorzystuje go w caﬂßoÚ≈ci.
- **MQTT + Home Assistant Discovery** ‹d?dane publikowane w MQTT i automatycznie rejestrowane w HA.
- **Tryb LISTEN (nasﬂßuch)** ‹d?gdy lista `meters` jest pusta, add-on wypisuje w logach wszystkie sﬂßyszane liczniki wraz z sugerowanym driverem.

### Wymagania (WA?NE)

Add-on domyÚ≈lnie korzysta z wewn?trznego brokera MQTT Home Assistant (Mosquitto add-on), ale mo∞∏e pracowaÍÓ z brokerem zewn?trznym.

**Tryby brokera (`mqtt_mode`):**
- `auto` (domyÚ≈lnie) ‹d?u∞∏ywa brokera HA jeÚ≈li dost?pny, w przeciwnym razie zewn?trzny
- `ha` ‹d?wymusza broker HA (Mosquitto add-on)
- `external` ‹d?zawsze u∞∏ywa ustawieﬂ® zewn?trznych (`external_mqtt_host`, itd.)

---

### Konfiguracja w Home Assistant (GUI)

Konfiguracja odbywa si? przez interfejs graficzny dodatku ‹d?nie trzeba edytowaÍÓ plik?w r?cznie.

#### Krok 1 ‹d?Tryb LISTEN (wykrycie licznik?w)

Zostaw sekcj? **meters** pustÍÍ i uruchom addon. W logach pojawiÍÍ si? wykryte liczniki:

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

#### Krok 2 ‹d?Dodanie licznika w GUI

W konfiguracji dodatku wypeﬂßnij sekcj? **meters**:

| Pole | Opis | Przykﬂßad |
|------|------|---------|
| `id` | Twoja wﬂßasna nazwa sensora w HA | `woda_zimna_lazienka` |
| `meter_id` | 8-cyfrowy numer z trybu LISTEN | `41553221` |
| `type` | Driver z trybu LISTEN | `mkradio3` |
| `key` | Klucz szyfrowania (jeÚ≈li licznik szyfruje) | `00112233...` lub puste |

JeÚ≈li licznik nie szyfruje telegram?w, pole `key` pozostaw puste.

---

### Docker standalone (bez Home Assistant)

W trybie Docker konfiguracja odbywa si? przez plik `options.json`.

#### Szybki start (Docker Compose ‹d?DietPi/Ubuntu)

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
mkdir -p /home/wmbus-test
cp -a homeassistant-wmbus-mqtt-bridge/docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
docker compose up -d --build
docker compose logs -f wmbus
```

JeÚ≈li widzisz `No meters configured -> LISTEN MODE` ‹d?kontener dziaﬂßa i czeka na telegramy.

#### Konfiguracja (Docker)

Gﬂß?wny plik: `./config/options.json` (wewnÍÍtrz kontenera: `/config/options.json`).

Pliki pod `./config/etc/` sÍÍ **generowane automatycznie** przy ka∞∏dym starcie ‹d?nie edytuj ich r?cznie, zostanÍÍ nadpisane.

**Pola wpisu licznika:**

| Pole | Opis |
|------|------|
| `id` | Twoja wﬂßasna etykieta (cz?Ú≈ÍÓ tematu MQTT i nazwa sensora w HA) |
| `meter_id` | 8-cyfrowy numer seryjny licznika (z trybu LISTEN) |
| `type` | Driver wmbusmeters (z trybu LISTEN), lub `auto` |
| `type_other` | Niestandardowy driver ‹d?wypeﬂßnij tylko gdy `type` = `other` |
| `key` | Klucz szyfrowania w formacie HEX, lub `NOKEY` |

Przykﬂßad `options.json`:

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

- Katalog `./config` musi byÍÓ **zapisywalny** (nie montuj jako `:ro`) ‹d?bridge tworzy tam `options.json` i konfiguracj? wmbusmeters.
- DomyÚ≈lny `raw_topic` to `wmbus_bridge/telegram` ‹d?upewnij si?, ∞∏e Tw?j odbiornik publikuje na ten sam temat.

#### R?czny test MQTT

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbus_bridge/telegram' -m '<HEX_TELEGRAM>'
mosquitto_sub -h localhost -p 1883 -t 'wmbusmeters/#' -v
```

---

### Przeznaczenie

Ten add-on jest szczeg?lnie przydatny gdy:
- odbi?r radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),
- chcesz u∞∏ywaÍÓ wmbusmeters bez dongla USB,
- masz wﬂßasny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

πfÀg? **Nie instaluj oficjalnego add-onu wmbusmeters r?wnolegﬂße.** Ten add-on zawiera wﬂßasnÍÍ instancj? wmbusmeters i zast?puje go w tym scenariuszu.

### Projekty bazowe (upstream)

- **wmbusmeters** ‹d?https://github.com/wmbusmeters/wmbusmeters (GPL-3.0)
- **wmbusmeters-ha-addon** ‹d?https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)

### Licencja

Repozytorium zawiera i modyfikuje kod z projektu **wmbusmeters-ha-addon** obj?tego licencjÍÍ GPL-3.0. Caﬂßy projekt dystrybuowany jest na licencji:

**GNU General Public License v3.0 (GPL-3.0)**

---

## ???Ôø Description (EN)

This Home Assistant add-on is a fork and extension of the official **wmbusmeters-ha-addon**, based on **wmbusmeters**.

The purpose of this add-on is to decode Wireless M-Bus (C1 / T1 / S1) telegrams in Home Assistant **without a local radio dongle** (USB/RTL-SDR). Instead, it uses **external receivers** (ESP32/gateway/bridge) and **MQTT as the input transport**.

### The problem it solves

The original **wmbusmeters-ha-addon** assumes local radio reception and does not accept external telegram sources or STDIN input. ESP32-based receivers, gateways and custom wM-Bus bridges cannot be used directly as data sources with the official add-on.

### Solution

This fork introduces an MQTT-based input path:

```
ESP32 / Gateway / Bridge
??MQTT (raw wM-Bus HEX telegram)
??wmbusmeters (stdin:hex)
??MQTT (JSON)
??Home Assistant (MQTT Discovery)
```

### Key features

- MQTT input for raw wM-Bus telegrams
- STDIN support for wmbusmeters (`stdin:hex`)
- Full decoding handled by upstream wmbusmeters
- MQTT output with Home Assistant Discovery
- LISTEN mode: when `meters` list is empty, logs all detected meter IDs and suggested drivers

### Broker modes (`mqtt_mode`)

- `auto` (default) ‹d?use HA broker if available, otherwise external
- `ha` ‹d?force HA broker (Mosquitto add-on)
- `external` ‹d?always use external settings (`external_mqtt_host`, etc.)

---

### Configuration in Home Assistant (GUI)

Configuration is done through the add-on GUI ‹d?no manual file editing required.

#### Step 1 ‹d?LISTEN mode (meter discovery)

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

#### Step 2 ‹d?Add a meter in the GUI

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

#### Quick start (Docker Compose ‹d?DietPi/Ubuntu)

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
mkdir -p /home/wmbus-test
cp -a homeassistant-wmbus-mqtt-bridge/docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
docker compose up -d --build
docker compose logs -f wmbus
```

If you see `No meters configured -> LISTEN MODE` ‹d?the container is running and waiting for telegrams.

#### Configuration (Docker)

Main file: `./config/options.json` (inside container: `/config/options.json`).

Files under `./config/etc/` are **auto-generated on startup** ‹d?do not edit them manually.

**Meter fields:**

| Field | Description |
|-------|-------------|
| `id` | Your label (used in MQTT topic and HA sensor name) |
| `meter_id` | 8-digit serial number (from LISTEN mode) |
| `type` | wmbusmeters driver (from LISTEN mode), or `auto` |
| `type_other` | Custom driver name ‹d?only when `type` is `other` |
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

- `./config` must be **writable** (do not mount as `:ro`) ‹d?the bridge creates `options.json` and wmbusmeters config there.
- Default `raw_topic` is `wmbus_bridge/telegram` ‹d?make sure your receiver publishes to the same topic.

#### Manual MQTT test

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbus_bridge/telegram' -m '<HEX_TELEGRAM>'
mosquitto_sub -h localhost -p 1883 -t 'wmbusmeters/#' -v
```

---

πfÀg? **Do not install the official wmbusmeters add-on in parallel.** This add-on bundles its own wmbusmeters instance and replaces it for this use case.

### Upstream projects

- wmbusmeters ‹d?https://github.com/wmbusmeters/wmbusmeters (GPL-3.0)
- wmbusmeters-ha-addon ‹d?https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)

### License

This repository contains and modifies code derived from **wmbusmeters-ha-addon** (GPL-3.0). The entire project is distributed under:

**GNU General Public License v3.0 (GPL-3.0)**

# Home Assistant Add-on: wMBus MQTT Bridge

## 🇵🇱 Opis (PL)

Ten dodatek Home Assistant jest rozszerzeniem oraz forkiem oficjalnego projektu **wmbusmeters-ha-addon**, który bazuje na narzędziu **wmbusmeters**.

Celem projektu jest dekodowanie telegramów Wireless M-Bus (C1 / T1 / S1) w Home Assistant **bez użycia lokalnego dongla radiowego** (USB/RTL-SDR). Zamiast tego wykorzystuje **zewnętrzne odbiorniki** (np. ESP32/gateway/bridge) i **MQTT jako kanał wejściowy**.

### Problem, który rozwiązuje ten add-on

Oryginalny **wmbusmeters-ha-addon**:
- zakłada, że odbiór radiowy odbywa się lokalnie (USB / serial / RTL-SDR),
- nie przewiduje podania telegramów z zewnętrznego źródła,
- nie obsługuje wejścia **STDIN** jako źródła danych.

W praktyce oznacza to, że odbiorniki ESP32, gatewaye, mosty radiowe (bridge) i własne odbiorniki wM-Bus nie mogą być użyte bezpośrednio jako źródło danych dla wmbusmeters w oficjalnym add-onie.

### Rozwiązanie zastosowane w tym projekcie

Ten fork wprowadza alternatywną ścieżkę wejściową opartą o MQTT. Add-on działa jako most (bridge) pomiędzy zewnętrznym źródłem telegramów wM-Bus a silnikiem dekodującym **wmbusmeters**.

### Architektura przepływu danych

```
ESP32 / Gateway / Bridge
→ MQTT (surowy telegram wM-Bus w formacie HEX)
→ wmbusmeters (stdin:hex)
→ MQTT (JSON)
→ Home Assistant (MQTT Discovery)
```

### Kluczowe cechy

- **MQTT jako wejście danych** — surowe telegramy wM-Bus (HEX) odbierane z wybranego tematu MQTT.
- **Wejście STDIN dla wmbusmeters** — telegramy przekazywane przez `stdin:hex`, czego oryginalny add-on nie obsługuje.
- **Pełne dekodowanie przez wmbusmeters** — projekt nie zastępuje wmbusmeters, lecz wykorzystuje go w całości.
- **MQTT + Home Assistant Discovery** — dane publikowane w MQTT i automatycznie rejestrowane w HA.
- **Tryb LISTEN (nasłuch)** — gdy lista `meters` jest pusta, add-on wypisuje w logach wszystkie słyszane liczniki wraz z sugerowanym driverem.

### Wymagania (WAŻNE)

Add-on domyślnie korzysta z wewnętrznego brokera MQTT Home Assistant (Mosquitto add-on), ale może pracować z brokerem zewnętrznym.

**Tryby brokera (`mqtt_mode`):**
- `auto` (domyślnie) — używa brokera HA jeśli dostępny, w przeciwnym razie zewnętrzny
- `ha` — wymusza broker HA (Mosquitto add-on)
- `external` — zawsze używa ustawień zewnętrznych (`external_mqtt_host`, itd.)

---

### Konfiguracja w Home Assistant (GUI)

Konfiguracja odbywa się przez interfejs graficzny dodatku — nie trzeba edytować plików ręcznie.

#### Krok 1 — Tryb LISTEN (wykrycie liczników)

Zostaw sekcję **meters** pustą i uruchom addon. W logach pojawią się wykryte liczniki:

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

#### Krok 2 — Dodanie licznika w GUI

W konfiguracji dodatku wypełnij sekcję **meters**:

| Pole | Opis | Przykład |
|------|------|---------|
| `id` | Twoja własna nazwa sensora w HA | `woda_zimna_lazienka` |
| `meter_id` | 8-cyfrowy numer z trybu LISTEN | `41553221` |
| `type` | Driver z trybu LISTEN | `mkradio3` |
| `key` | Klucz szyfrowania (jeśli licznik szyfruje) | `00112233...` lub puste |

Jeśli licznik nie szyfruje telegramów, pole `key` pozostaw puste.

---

### Docker standalone (bez Home Assistant)

W trybie Docker konfiguracja odbywa się przez plik `options.json`.

#### Szybki start (Docker Compose — DietPi/Ubuntu)

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
mkdir -p /home/wmbus-test
cp -a homeassistant-wmbus-mqtt-bridge/docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
docker compose up -d --build
docker compose logs -f wmbus
```

Jeśli widzisz `No meters configured -> LISTEN MODE` — kontener działa i czeka na telegramy.

#### Konfiguracja (Docker)

Główny plik: `./config/options.json` (wewnątrz kontenera: `/config/options.json`).

Pliki pod `./config/etc/` są **generowane automatycznie** przy każdym starcie — nie edytuj ich ręcznie, zostaną nadpisane.

**Pola wpisu licznika:**

| Pole | Opis |
|------|------|
| `id` | Twoja własna etykieta (część tematu MQTT i nazwa sensora w HA) |
| `meter_id` | 8-cyfrowy numer seryjny licznika (z trybu LISTEN) |
| `type` | Driver wmbusmeters (z trybu LISTEN), lub `auto` |
| `type_other` | Niestandardowy driver — wypełnij tylko gdy `type` = `other` |
| `key` | Klucz szyfrowania w formacie HEX, lub `NOKEY` |

Przykład `options.json`:

```json
{
  "raw_topic": "wmbus_bridge/+/telegram",
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

- Katalog `./config` musi być **zapisywalny** (nie montuj jako `:ro`) — bridge tworzy tam `options.json` i konfigurację wmbusmeters.
- Domyślny `raw_topic` to `wmbus_bridge/+/telegram` — upewnij się, że Twój odbiornik publikuje na ten sam temat.

#### Ręczny test MQTT

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbus_bridge/any/telegram' -m '<HEX_TELEGRAM>'
mosquitto_sub -h localhost -p 1883 -t 'wmbusmeters/#' -v
```

---

### Przeznaczenie

Ten add-on jest szczególnie przydatny gdy:
- odbiór radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),
- chcesz używać wmbusmeters bez dongla USB,
- masz własny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

⚠️ **Nie instaluj oficjalnego add-onu wmbusmeters równoległe.** Ten add-on zawiera własną instancję wmbusmeters i zastępuje go w tym scenariuszu.

### Projekty bazowe (upstream)

- **wmbusmeters** — https://github.com/wmbusmeters/wmbusmeters (GPL-3.0)
- **wmbusmeters-ha-addon** — https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)

### Licencja

Repozytorium zawiera i modyfikuje kod z projektu **wmbusmeters-ha-addon** objętego licencją GPL-3.0. Cały projekt dystrybuowany jest na licencji:

**GNU General Public License v3.0 (GPL-3.0)**

---

## 🇬🇧 Description (EN)

This Home Assistant add-on is a fork and extension of the official **wmbusmeters-ha-addon**, based on **wmbusmeters**.

The purpose of this add-on is to decode Wireless M-Bus (C1 / T1 / S1) telegrams in Home Assistant **without a local radio dongle** (USB/RTL-SDR). Instead, it uses **external receivers** (ESP32/gateway/bridge) and **MQTT as the input transport**.

### The problem it solves

The original **wmbusmeters-ha-addon** assumes local radio reception and does not accept external telegram sources or STDIN input. ESP32-based receivers, gateways and custom wM-Bus bridges cannot be used directly as data sources with the official add-on.

### Solution

This fork introduces an MQTT-based input path:

```
ESP32 / Gateway / Bridge
→ MQTT (raw wM-Bus HEX telegram)
→ wmbusmeters (stdin:hex)
→ MQTT (JSON)
→ Home Assistant (MQTT Discovery)
```

### Key features

- MQTT input for raw wM-Bus telegrams
- STDIN support for wmbusmeters (`stdin:hex`)
- Full decoding handled by upstream wmbusmeters
- MQTT output with Home Assistant Discovery
- LISTEN mode: when `meters` list is empty, logs all detected meter IDs and suggested drivers

### Broker modes (`mqtt_mode`)

- `auto` (default) — use HA broker if available, otherwise external
- `ha` — force HA broker (Mosquitto add-on)
- `external` — always use external settings (`external_mqtt_host`, etc.)

---

### Configuration in Home Assistant (GUI)

Configuration is done through the add-on GUI — no manual file editing required.

#### Step 1 — LISTEN mode (meter discovery)

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

#### Step 2 — Add a meter in the GUI

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

#### Quick start (Docker Compose — DietPi/Ubuntu)

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
mkdir -p /home/wmbus-test
cp -a homeassistant-wmbus-mqtt-bridge/docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
docker compose up -d --build
docker compose logs -f wmbus
```

If you see `No meters configured -> LISTEN MODE` — the container is running and waiting for telegrams.

#### Configuration (Docker)

Main file: `./config/options.json` (inside container: `/config/options.json`).

Files under `./config/etc/` are **auto-generated on startup** — do not edit them manually.

**Meter fields:**

| Field | Description |
|-------|-------------|
| `id` | Your label (used in MQTT topic and HA sensor name) |
| `meter_id` | 8-digit serial number (from LISTEN mode) |
| `type` | wmbusmeters driver (from LISTEN mode), or `auto` |
| `type_other` | Custom driver name — only when `type` is `other` |
| `key` | Encryption key in HEX, or `NOKEY` |

Example `options.json`:

```json
{
  "raw_topic": "wmbus_bridge/+/telegram",
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

- `./config` must be **writable** (do not mount as `:ro`) — the bridge creates `options.json` and wmbusmeters config there.
- Default `raw_topic` is `wmbus_bridge/+/telegram` — make sure your receiver publishes to the same topic.

#### Manual MQTT test

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbus_bridge/any/telegram' -m '<HEX_TELEGRAM>'
mosquitto_sub -h localhost -p 1883 -t 'wmbusmeters/#' -v
```

---

⚠️ **Do not install the official wmbusmeters add-on in parallel.** This add-on bundles its own wmbusmeters instance and replaces it for this use case.

### Upstream projects

- wmbusmeters — https://github.com/wmbusmeters/wmbusmeters (GPL-3.0)
- wmbusmeters-ha-addon — https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)

### License

This repository contains and modifies code derived from **wmbusmeters-ha-addon** (GPL-3.0). The entire project is distributed under:

**GNU General Public License v3.0 (GPL-3.0)**

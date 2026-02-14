# Home Assistant Add-on: wMBus MQTT Bridge

## 🇵🇱 Opis (PL)

Ten dodatek Home Assistant jest rozszerzeniem oraz forkiem oficjalnego projektu **wmbusmeters-ha-addon**, który bazuje na narzędziu **wmbusmeters**.

Celem projektu jest dekodowanie telegramów Wireless M-Bus (C1 / T1 / S1) w Home Assistant **bez użycia lokalnego dongla radiowego** (USB/RTL-SDR). Zamiast tego wykorzystuje **zewnętrzne odbiorniki** (np. ESP32/gateway/bridge) i **MQTT jako kanał wejściowy**.

### Problem, który rozwiązuje ten add-on

Oryginalny **wmbusmeters-ha-addon**:
- zakłada, że odbiór radiowy odbywa się lokalnie (USB / serial / RTL-SDR),
- nie przewiduje podania telegramów z zewnętrznego źródła,
- nie obsługuje wejścia **STDIN** jako źródła danych.

W praktyce oznacza to, że:
- odbiorniki ESP32,
- gatewaye,
- mosty radiowe (bridge),
- własne odbiorniki wM-Bus

nie mogą być użyte bezpośrednio jako źródło danych dla wmbusmeters w oficjalnym add-onie.

### Rozwiązanie zastosowane w tym projekcie

Ten fork wprowadza alternatywną ścieżkę wejściową opartą o MQTT.

Add-on działa jako most (bridge) pomiędzy:
- źródłem telegramów wM-Bus (zewnętrzny odbiornik),
- a silnikiem dekodującym **wmbusmeters**.

### Architektura przepływu danych

ESP32 / Gateway / Bridge  
→ MQTT (surowy telegram wM-Bus w formacie HEX)  
→ wmbusmeters (stdin:hex)  
→ MQTT (JSON)  
→ Home Assistant (MQTT Discovery)

### Kluczowe cechy

- **MQTT jako wejście danych**  
  Surowe telegramy wM-Bus (HEX) są odbierane z wybranego tematu MQTT.

- **Wejście STDIN dla wmbusmeters**  
  Telegramy są przekazywane do wmbusmeters przez `stdin:hex`, czego oryginalny add-on nie obsługuje.

- **Pełne dekodowanie przez wmbusmeters**  
  Projekt nie zastępuje wmbusmeters — wykorzystuje go w całości (dekodowanie, logika, formaty).

- **MQTT + Home Assistant Discovery**  
  Dane są publikowane w MQTT oraz automatycznie rejestrowane w Home Assistant.

- **Tryb LISTEN (nasłuch)**  
  Gdy lista `meters` jest pusta:
  - add-on działa w trybie pasywnym,
  - w logach wypisywane są wykryte `meter_id` oraz sugerowany driver,
  - ułatwia to identyfikację i konfigurację nowych liczników.

### Wymagania (WAŻNE)

Add-on domyślnie korzysta z wewnętrznego brokera MQTT z Home Assistant (Mosquitto add-on), ale może też pracować z brokerem zewnętrznym (np. osobny LXC/Docker).

**Tryby brokera (mqtt_mode):**
- `auto` (domyślnie): używa brokera HA jeśli dostępny, w przeciwnym razie używa ustawień zewnętrznych
- `ha`: wymusza broker HA (Mosquitto add-on)
- `external`: zawsze używa ustawień zewnętrznych (`external_mqtt_host`, itd.)


### Docker standalone (bez Home Assistant)

Jeśli chcesz uruchomić bridge jako zwykły kontener (np. DietPi/Ubuntu), to obraz w trybie `docker`:
- **sam utworzy** plik `/config/options.json` (jeśli go nie ma),
- wygeneruje `/config/etc/wmbusmeters.conf` oraz katalog `/config/etc/wmbusmeters.d`,
- będzie subskrybował `raw_topic` z MQTT i publikował stany do `state_prefix`.

Minimalny start:
1. Uruchom kontener z podmontowanym katalogiem `./config` jako `/config`.
2. Po pierwszym starcie edytuj `./config/options.json` (np. `raw_topic`, dane brokera, lista `meters`) i zrestartuj kontener.

Przykładowy `docker-compose.yml` znajdziesz w `docker/examples/`.

#### Szybki start (Docker Compose – DietPi/Ubuntu)

1) Pobierz repozytorium i wejdź do katalogu:

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
cd homeassistant-wmbus-mqtt-bridge
```

2) Skopiuj przykład do osobnego katalogu roboczego (żeby nie mieszać w repo):

```bash
mkdir -p /home/wmbus-test
cp -a docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
```

3) Uruchom:

```bash
docker compose up -d --build
```

4) Zobacz logi bridge (pierwszy start utworzy pliki w `./config/`):

```bash
docker compose logs -f wmbus
```

Jeśli zobaczysz komunikat typu:
- `Created default /config/options.json`
- `No meters configured -> LISTEN-like mode`

…to znaczy, że kontener działa i czeka na telegramy.

#### Konfiguracja

- **Najważniejszy plik**: `./config/options.json` (w kontenerze: `/config/options.json`).
- Pliki `./config/etc/wmbusmeters.conf` i `./config/etc/wmbusmeters.d/*.conf` są **generowane** na starcie (nie edytuj ich ręcznie – nadpiszą się).

Przykład wpisu licznika (uzupełnij `type` i `key`):

```json
{
  "meters": [
    {
      "id": "12345678",
      "name": "Energia",
      "type": "amiplus",
      "key": "00112233445566778899AABBCCDDEEFF"
    }
  ]
}
```

Po zmianach zrestartuj tylko bridge:

```bash
docker compose restart wmbus
```

#### Skąd mają przychodzić telegramy

Ten kontener **nie odbiera radia**. On tylko:
- subskrybuje `raw_topic` (domyślnie `wmbusmeters/raw/#`),
- bierze payload (HEX),
- wrzuca to na `stdin` do `wmbusmeters`,
- publikuje JSON do `state_prefix` (domyślnie `wmbusmeters/<id>/state`),
- opcjonalnie publikuje MQTT Discovery do `homeassistant/...` (w Dockerze ustaw `publish_discovery: true`).

Minimalny test MQTT (musisz mieć prawdziwy telegram z odbiornika):

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbusmeters/raw/test' -m '<HEX_TELEGRAM>'
mosquitto_sub -h localhost -p 1883 -t 'wmbusmeters/#' -v
```

#### Ważne

- Katalog `./config` **musi być zapisywalny** (nie montuj jako `:ro`), bo bridge tworzy tam `options.json` i konfigurację wmbusmeters.
- Jeśli `meters` jest puste, uruchamia się tryb LISTEN (pomocny do wykrycia ID/drivera), ale bez kluczy nie będzie pełnego dekodowania.

### Przeznaczenie

Ten add-on jest szczególnie przydatny, gdy:
- odbiór radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),
- chcesz używać wmbusmeters bez dongla USB,
- masz własny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

⚠️ **Ważna informacja**  
Nie instaluj oficjalnego add-onu **wmbusmeters** równolegle. Ten add-on zawiera własną instancję wmbusmeters i zastępuje go w tym scenariuszu.

### Projekty bazowe (upstream)

- **wmbusmeters**  
  https://github.com/wmbusmeters/wmbusmeters  
  Licencja: GPL-3.0

- **wmbusmeters-ha-addon**  
  https://github.com/wmbusmeters/wmbusmeters-ha-addon  
  Licencja: GPL-3.0

### Licencja

Repozytorium zawiera i modyfikuje kod pochodzący z projektu **wmbusmeters-ha-addon**, który jest objęty licencją GPL-3.0.  
W związku z tym cały projekt jest dystrybuowany na licencji:

**GNU General Public License v3.0 (GPL-3.0)**

---

## 🇬🇧 Description (EN)

This Home Assistant add-on is a fork and extension of the official **wmbusmeters-ha-addon**, which itself is based on **wmbusmeters**.

The purpose of this add-on is to decode Wireless M-Bus (C1 / T1 / S1) telegrams in Home Assistant **without a local radio dongle** (USB/RTL-SDR). Instead, it uses **external receivers** (ESP32/gateway/bridge) and **MQTT as the input transport**.

### The problem it solves

The original **wmbusmeters-ha-addon**:
- assumes local radio reception (USB / serial / RTL-SDR),
- does not support external telegram sources,
- does not accept **STDIN** as an input source.

As a result, ESP32-based receivers, gateways or custom wM-Bus bridges cannot be used directly as data sources.

### Solution implemented in this fork

This project introduces an MQTT-based input path for wmbusmeters.

The add-on acts as a bridge between:
- an external wM-Bus telegram source,
- and the wmbusmeters decoding engine.

### Data flow architecture

ESP32 / Gateway / Bridge  
→ MQTT (raw wM-Bus HEX telegram)  
→ wmbusmeters (stdin:hex)  
→ MQTT (JSON)  
→ Home Assistant (MQTT Discovery)

### Key features

- MQTT input for raw wM-Bus telegrams  
- STDIN support for wmbusmeters (`stdin:hex`)  
- Full decoding handled by upstream wmbusmeters  
- MQTT output with Home Assistant Discovery  
- LISTEN mode for detecting meter IDs and drivers before configuration

### Requirements (IMPORTANT)

By default, this add-on uses Home Assistant's internal MQTT service (Mosquitto add-on), but it can also connect to an external broker (e.g., separate LXC/Docker).

**Broker modes (mqtt_mode):**
- `auto` (default): use HA broker if available, otherwise use external settings
- `ha`: force HA broker (Mosquitto add-on)
- `external`: always use external settings (`external_mqtt_host`, etc.)


### Docker standalone (without Home Assistant)

If you want to run the bridge as a plain Docker container:
- the `docker` image entrypoint **creates** `/config/options.json` on first start,
- generates `/config/etc/wmbusmeters.conf` and `/config/etc/wmbusmeters.d`,
- subscribes to `raw_topic` and publishes state to `state_prefix` (and optional HA discovery).

Minimal start:
1. Run the container with a host directory mounted to `/config`.
2. After first start, edit `/config/options.json` (broker, `raw_topic`, `meters`) and restart.

See `docker/examples/` for a compose example.

#### Quick start (Docker Compose – DietPi/Ubuntu)

1) Clone the repo:

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
cd homeassistant-wmbus-mqtt-bridge
```

2) Copy the example into a separate working directory:

```bash
mkdir -p /home/wmbus-test
cp -a docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
```

3) Start:

```bash
docker compose up -d --build
```

4) Follow logs (first start creates files in `./config/`):

```bash
docker compose logs -f wmbus
```

#### Configuration

- Main file: `./config/options.json` (inside container: `/config/options.json`).
- `./config/etc/wmbusmeters.conf` and `./config/etc/wmbusmeters.d/*.conf` are **generated on startup** (don’t edit manually).

Example meter entry:

```json
{
  "meters": [
    {
      "id": "12345678",
      "name": "Energy",
      "type": "amiplus",
      "key": "00112233445566778899AABBCCDDEEFF"
    }
  ]
}
```

Restart after changes:

```bash
docker compose restart wmbus
```

#### Where raw telegrams come from

This container **does not do radio reception**. It only:
- subscribes to `raw_topic` (default `wmbusmeters/raw/#`),
- takes payload (HEX),
- feeds it to `wmbusmeters` via stdin,
- publishes decoded JSON to `state_prefix`,
- optionally publishes HA MQTT Discovery (set `publish_discovery: true` in Docker).

Minimal MQTT test (you need a real telegram):

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbusmeters/raw/test' -m '<HEX_TELEGRAM>'
mosquitto_sub -h localhost -p 1883 -t 'wmbusmeters/#' -v
```

#### Notes

- `./config` must be **writable** (don’t mount as `:ro`), because the bridge creates `options.json` and wmbusmeters config there.
- If `meters` is empty, LISTEN mode is enabled (useful to discover meter IDs/drivers), but you won’t get full decoding without keys.

⚠️ **Important note**  
Do not install the official **wmbusmeters** add-on in parallel. This add-on bundles its own wmbusmeters instance and replaces it for this use case.

### Upstream projects

- wmbusmeters — https://github.com/wmbusmeters/wmbusmeters (GPL-3.0)  
- wmbusmeters-ha-addon — https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)

### License

Because this repository contains and modifies code derived from **wmbusmeters-ha-addon**, the entire project is distributed under:

**GNU General Public License v3.0 (GPL-3.0)**

> 🌐 [EN](README.en.md) | [PL](README.pl.md) | [DE](README.de.md) | [**CS**](README.cs.md) | [SK](README.sk.md)

> 🤖 **Strojový překlad** — Tato dokumentace byla strojově přeložena z polštiny. Může obsahovat chyby.

# wMBus MQTT Bridge — kompletní dokumentace (CS)

> Verze dokumentu: **1.5.4-dev**  ·  Jazyk: **čeština**  ·  Stav: dev-channel Home Assistant add-onu
>
> Krátký dvojjazyčný přehled najdete v hlavním [README.md](../README.md). Tento dokument je úplná česká dokumentace projektu — od „co to je" po detaily architektury a runtime.

---

## Obsah

1. [TL;DR — co to dělá](#1-tldr--co-to-dělá)
2. [Architektura toku dat](#2-architektura-toku-dat)
3. [Rychlý start — Home Assistant](#3-rychlý-start--home-assistant)
4. [Rychlý start — Docker standalone](#4-rychlý-start--docker-standalone)
5. [WebUI — 7 pohledů](#5-webui--7-pohledů)
6. [Typický workflow: od prázdna k fungujícímu měřiči](#6-typický-workflow-od-prázdna-k-fungujícímu-měřiči)
7. [Režim SEARCH — když LISTEN slyší příliš mnoho cizích měřičů](#7-režim-search--když-listen-slyší-příliš-mnoho-cizích-měřičů)
8. [Kompletní reference konfigurace](#8-kompletní-reference-konfigurace)
9. [MQTT témata — co publikujeme, co konzumujeme](#9-mqtt-témata--co-publikujeme-co-konzumujeme)
10. [Runtime soubory v `/data/`](#10-runtime-soubory-v-data)
11. [Home Assistant vs Docker — rozdíly UX](#11-home-assistant-vs-docker--rozdíly-ux)
12. [Lokalizace UI](#12-lokalizace-ui)
13. [Řešení problémů](#13-řešení-problémů)
14. [Architektura kódu — pro vývojáře](#14-architektura-kódu--pro-vývojáře)
15. [Verzování a Docker image](#15-verzování-a-docker-image)
16. [Licence a upstream projekty](#16-licence-a-upstream-projekty)

---

## 1. TL;DR — co to dělá

> **V jedné větě:** Add-on dekóduje Wireless M-Bus telegramy (vodoměry, měřiče tepla, elektroměry) **bez lokálního USB donglu** — surové HEX telegramy mu dodává libovolný externí přijímač (ESP32, bridge, gateway) přes MQTT.

Standardně `wmbusmeters` vyžaduje radiový dongl připojený k hostiteli. Tento projekt to řeší jinak:

- **Ty** máš radiový přijímač daleko od Home Assistant (např. ESP32 na půdě s anténou).
- **Přijímač** publikuje surové HEX rámce do MQTT.
- **Tento add-on** se připojí k brokeru, krmí `wmbusmeters` přes `stdin:hex`, dekóduje JSON a publikuje výsledek zpět do MQTT + Home Assistant Discovery.

Výsledek: **Tvoje měřiče se objeví jako senzory v HA, bez jakéhokoli radiového hardwaru na straně HA.**

> 🤝 **Spolupráce s ESPHome firmwarem** — Tento add-on se typicky používá společně s [`esphome-wmbus-bridge-rawonly`](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly), ESPHome komponentou běžící na ESP32 s rádiovým čipem **CC1101, SX1276 nebo SX1262**. ESP přijímá rádiové rámce a publikuje surové HEX do MQTT; tento add-on je dekóduje. Oba projekty jsou **nezávislé** — add-on přijímá HEX z libovolného zdroje publikujícího do nakonfigurovaného `raw_topic`.

---

## 2. Architektura toku dat

### Datová pipeline

```mermaid
%%{init: {'theme':'default'}}%%
flowchart LR
  subgraph EXT["🛰️ Externí přijímač (mimo HA)"]
    A1["ESP32 / Gateway / Bridge<br/>s modulem CC1101, SX1276 nebo SX1262"]
  end

  subgraph BROKER["📡 MQTT broker"]
    B1["topic: wmbus/+/telegram<br/>(surové HEX)"]
    B2["topic: wmbusmeters/&lt;id&gt;/...<br/>(dekódované JSON)"]
    B3["topic: homeassistant/sensor/...<br/>(MQTT Discovery)"]
  end

  subgraph ADDON["🧩 wMBus MQTT Bridge (tento add-on)"]
    C1["bridge.sh<br/>mosquitto_sub → stdin → wmbusmeters"]
    C2["wmbusmeters<br/>(stdin:hex dekodér)"]
    C3["webui.py<br/>port 8099"]
    C1 -- "HEX in" --> C2
    C2 -- "JSON out" --> C1
    C3 -. "čte status.json + tsv" .-> C1
  end

  subgraph HA["🏠 Home Assistant"]
    D1["Sensors:<br/>sensor.cold_water_bathroom<br/>sensor.heat_apartment"]
  end

  A1 -- "publish HEX" --> B1
  B1 -- "subscribe" --> C1
  C1 -- "publish JSON" --> B2
  C1 -- "publish discovery" --> B3
  B2 -.-> D1
  B3 -.-> D1
```

### Mapa komponent uvnitř kontejneru

```mermaid
%%{init: {'theme':'default'}}%%
flowchart TB
  subgraph CONTAINER["🐳 Add-on kontejner"]
    direction TB
    S6["s6-overlay (init)"] --> SVC1["service: wmbus_mqtt_bridge<br/>(bridge.sh)"]
    S6 --> SVC2["service: wmbus_webui<br/>(webui.py)"]
    SVC1 -- "telegram HEX in" --> WM["wmbusmeters --useconf"]
    WM -- "JSON out" --> SVC1
    SVC1 -- "TSV/JSON runtime state" --> DATA["/data/*.tsv<br/>/data/status.json"]
    SVC2 -- "čte" --> DATA
    SVC2 -. "Supervisor API<br/>(když HA)" .-> SUP["http://supervisor"]
  end
```

**Tři paralelně běžící procesy** spravované `s6-overlay`:

| Proces | Co dělá | Soubor |
|---|---|---|
| `bridge.sh` | Odebírá MQTT, krmí wmbusmeters HEXem, parsuje JSON, publikuje výsledky | [rootfs/usr/bin/bridge.sh](../rootfs/usr/bin/bridge.sh) |
| `wmbusmeters` | Dekodér telegramů (upstream binárka — Fredrik Öhrström) | `/usr/bin/wmbusmeters` |
| `webui.py` | HTTP server na portu 8099, správní panel | [rootfs/usr/bin/webui.py](../rootfs/usr/bin/webui.py) |

Tyto tři komponenty komunikují pouze přes **soubory v `/data/`** — žádné sockety uvnitř kontejneru. Díky tomu lze webui restartovat nezávisle na bridge a stav přežívá restarty.

> 🔗 **Na straně přijímače (ESP32 s rádiem)** — používáme sesterský projekt Kustonia: **[esphome-wmbus-bridge-rawonly-dev](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly-dev)** — ESPHome firmware pro SX1262 / SX1276 / CC1101 publikující surové HEX na `wmbus/<device>/telegram`. Topic přesně odpovídá našemu výchozímu `raw_topic: wmbus/+/telegram` — na naší straně není třeba nic konfigurovat. Přijímač má vlastní úplnou dokumentaci (EN/PL) — začni s [`START_HERE.md`](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly-dev/blob/main/docs/START_HERE.md).

---

## 3. Rychlý start — Home Assistant

### Krok 1 — přidej repozitář

V HA: **Settings → Add-ons → Add-on Store → ⋮ (menu) → Repositories**, přidej:

```
https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge
```

### Krok 2 — nainstaluj add-on

Ve storu najdi **wMBus MQTT Bridge Dev** (sekce „dev"), klikni **Install**.

> ⚠️ Neinstaluj oficiální `wmbusmeters` add-on paralelně — tento projekt má vlastní instanci wmbusmeters a duplikuje ji.

### Krok 3 — spusť s prázdným seznamem `meters` (režim LISTEN)

Klikni **Start**. Defaultně `meters: []` — add-on jde do režimu LISTEN a pouze poslouchá, nic ještě nekonfiguruje.

### Krok 4 — otevři WebUI

Na záložce **Info** add-onu klikni **OPEN WEB UI**. Přivítá tě dashboard:

```
┌────────────────────────────────────────────────────────────────┐
│ wMBus MQTT Bridge                              [EN PL DE CS SK]│
│ Panel | Měřiče | Detekce | Hledání | Logy | Nastavení | ⋮     │
├────────────────────────────────────────────────────────────────┤
│ Panel                                                          │
│ Stav pipeline za běhu...                                       │
│                                                                │
│ [System status]  [Statistics]  [Discovery]                     │
│                                                                │
│ Nakonfigurované měřiče                                         │
│   (prázdné)                                                    │
│                                                                │
│ Detekovaní kandidáti                                           │
│   12 kandidátů / OTEVŘÍT DETEKCI                               │
└────────────────────────────────────────────────────────────────┘
```

### Krok 5 — jdi na „Detekce" a přidej měřič

Na záložce **DETEKCE** uvidíš seznam kandidátů. Pro každého bez požadavku na AES klíč — tlačítko **PŘIDAT MĚŘIČ** přímo v řádku. Klik, restart, hotovo.

➡️ Plný popis tohoto workflowu v [§6 Typický workflow](#6-typický-workflow-od-prázdna-k-fungujícímu-měřiči).

---

## 4. Rychlý start — Docker standalone

Pro všechny mimo Home Assistant (DietPi, Ubuntu, Raspberry Pi OS, NAS atd.).

### Požadavky

- Docker + docker compose
- Funkční MQTT broker (Mosquitto, EMQX, …) dostupný z hostitele
- Radiový přijímač publikující HEX rámce do brokeru — např. [esphome-wmbus-bridge-rawonly-dev](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly-dev) (publikuje na `wmbus/<device>/telegram`, kompatibilní out-of-the-box)

### Instalace

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
mkdir -p /home/wmbus-test
cp -a homeassistant-wmbus-mqtt-bridge/docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
docker compose up -d --build
docker compose logs -f wmbus
```

První logy by měly ukazovat:

```
[wmbus-bridge] mqtt: connected to 192.168.1.10:1883
[wmbus-bridge] No meters configured -> LISTEN MODE
```

### Konfigurace

Edituj `./config/options.json`. Úplná reference polí v [§8](#8-kompletní-reference-konfigurace). Minimální příklad:

```json
{
  "raw_topic": "wmbus_bridge/+/telegram",
  "loglevel": "normal",
  "discovery_enabled": true,
  "state_prefix": "wmbusmeters",
  "mqtt_mode": "external",
  "external_mqtt_host": "192.168.1.10",
  "external_mqtt_port": 1883,
  "external_mqtt_username": "user",
  "external_mqtt_password": "pass",
  "meters": []
}
```

Po editaci:

```bash
docker compose restart wmbus
```

### WebUI v Dockeru

Vystav port 8099 v `docker-compose.yml`:

```yaml
services:
  wmbus:
    ports:
      - "8099:8099"
```

Pak otevři `http://<host-ip>:8099/`.

> 💡 V režimu Docker UI detekuje chybějící `SUPERVISOR_TOKEN` a nahradí tlačítka RESTART pokynem `docker restart <container>` — viz [§11](#11-home-assistant-vs-docker--rozdíly-ux).

---

## 5. WebUI — 7 pohledů

WebUI je dostupné v **5 jazycích** (EN/PL/DE/CS/SK) — přepínač v pravém horním rohu. Jazyk je detekován z (v pořadí): `?lang=`, cookie `wmbus_lang`, hlavička `Accept-Language`.

Všechny stránky se automaticky obnovují každých 15 sekund (kromě `/candidate`).

### Mapa záložek

```mermaid
flowchart LR
  N1["PANEL<br/>/"] --> N2["MĚŘIČE<br/>/meters"]
  N2 --> N3["DETEKCE<br/>/discover"]
  N3 --> N4["HLEDÁNÍ<br/>/search"]
  N4 --> N5["LOGY<br/>/logs"]
  N5 --> N6["NASTAVENÍ<br/>/settings"]
  N6 --> N7["O PROJEKTU<br/>/about"]
  N3 -.->|ANALYZOVAT| N8["/candidate?id=...<br/>(detail kandidáta)"]
```

### 5.1. Panel (`/`)

Tři karty nahoře: **System status** (MQTT, RAW telegrams, wmbusmeters, decoded JSON, configured meters, HA Discovery), **Statistics** (čísla + mini-bary), **Discovery status** (prefixy + počet měřičů/kandidátů).

Níže: kompaktní mřížka nakonfigurovaných měřičů + shrnutí kandidátů s tlačítkem „OTEVŘÍT DETEKCI".

Pokud máš **pending changes** (přidal jsi něco před restartem) — žlutý panel se objeví zde, na `/meters` a na `/discover`. Viz [§6](#krok-3--podívej-se-co-čeká-na-restart).

### 5.2. Měřiče (`/meters`)

Plná mřížka **dekódovaných** měřičů. Každá karta:

```
┌──────────────────────────────┐
│ 💧 cold_water_bathroom       │
│ 41553221 / mkradio3          │
│                              │
│ total_m3                     │
│ 123.456                      │
│ ─────────────────────────    │
│ Media:    water              │
│ Reception: ~30 min           │
│ Seen 15m:  2  Seen 60m: 5    │
│ ─────────────────────────    │
│ [Online]            [DELETE] │
└──────────────────────────────┘
```

Hlavní hodnota je **aktuální** okamžitá hodnota nebo stav měřiče (od verze 1.5.2-dev — viz [§13](#13-řešení-problémů)).

### 5.3. Detekce (`/discover`)

Tabulka kandidátů z LISTEN módu. Pro každého vidíš: ID, ovladač, médium (💧/⚡/🔥/📡), šifrování (AES required / no AES / —), příjem (15m/60m), poslední telegram, akce.

**Akce** závisí na šifrovacím pillu:

| Pill | Tlačítka |
|---|---|
| 🟢 **no AES** nebo šedé **—** | `[PŘIDAT MĚŘIČ] [ANALYZOVAT] [IGNOROVAT]` — inline ADD, jedno kliknutí = zápis do `options.json` |
| 🔴 **AES required** | `[ANALYZOVAT] [IGNOROVAT]` — musíš jít na `/candidate` a vložit 32-znakový HEX klíč |

Filtry médií nahoře: **Vše / Voda / Elektřina / Teplo / Ostatní**. Druhý odkaz `[Ignorovaní]` zobrazuje dříve ignorované kandidáty (s možností OBNOVIT).

### 5.4. Hledání (`/search`)

Servisní režim — používán když LISTEN vrátí desítky cizích měřičů (např. bytový dům) a nevíš, který je tvůj. Viz dedikovaná sekce [§7](#7-režim-search--když-listen-slyší-příliš-mnoho-cizích-měřičů).

UI má 3 (kontextové) banery:

- 🟢 **MATCH FOUND** — když je shoda nalezena
- 🟢 **SEARCH MODE ACTIVE** — běží, čeká na další telegramy
- 🟡 **SEARCH MODE — konfigurace** — před aktivací

Plus formulář konfigurace (m³ odečet + tolerance) a živý status z bridge.sh (KV: phase, cached, ignored, loaded, decoded, checked, matches, last candidate, last checked, last reason).

### 5.5. Logy (`/logs`)

Krátký proud runtime událostí z [`status_events.tsv`](#10-runtime-soubory-v-data) — RAW received, candidate detected, errors. Úplné logy jsou stále v záložce HA add-onu **Log**.

### 5.6. Nastavení (`/settings`)

Zobrazuje aktivní runtime konfiguraci (ze `status.json`):
- `raw_topic`, `state_prefix`, `discovery_prefix`
- `search_mode`, `search_expected_value_m3`, `search_tolerance_m3`
- `loglevel`, MQTT host, počet ignorovaných kandidátů

Plus blok **RESTART ADDON** (nebo v režimu Docker: pokyn `docker restart`) a seznam runtime souborů + tlačítko **MANAGE IGNORED CANDIDATES** (přesměrování na `/discover?ignored=1`).

### 5.7. O projektu (`/about`)

Krátký popis architektury a ASCII diagram.

---

## 6. Typický workflow: od prázdna k fungujícímu měřiči

```mermaid
flowchart TD
  A["1️⃣ Start add-onu<br/>meters=[]"] --> B["bridge.sh přechází<br/>do režimu LISTEN"]
  B --> C["Přijímač publikuje<br/>HEX → wmbusmeters<br/>→ kandidát viditelný"]
  C --> D{"Vidíš kandidáta<br/>na /discover?"}
  D -- "ano, no AES" --> E["2️⃣ Klik PŘIDAT MĚŘIČ<br/>(inline)"]
  D -- "ano, AES required" --> F["2a. Klik ANALYZOVAT<br/>→ vlož HEX klíč<br/>→ PŘIDAT MĚŘIČ"]
  D -- "ne" --> G["Zkontroluj přijímač,<br/>broker, raw_topic,<br/>filter_hex_only"]
  E --> H["3️⃣ Kandidát zmizí ze seznamu,<br/>pending panel zobrazuje<br/>'čeká na restart'"]
  F --> H
  H --> I["4️⃣ Klik RESTART ADDON<br/>(panel nebo /settings)"]
  I --> J["5️⃣ Po prvním telegramu<br/>měřič přejde Online<br/>na /meters"]
```

### Krok 1 — první spuštění

`meters: []` v konfiguraci. Add-on startuje, připojí se k brokeru, čeká. V lozích:

```
[wmbus-bridge] mqtt: connected
[wmbus-bridge] No meters configured -> LISTEN MODE
[wmbus-bridge][INFO] === NEW METER CANDIDATE DETECTED ===
[wmbus-bridge][INFO] Received telegram from: 41553221
[wmbus-bridge][INFO] Suggested driver: mkradio3
```

WebUI → **Detekce** ukazuje 41553221 s ovladačem `mkradio3`.

### Krok 2 — přidej kandidáta

Pro měřič bez šifrování: v řádku **DETEKCE** klikni `PŘIDAT MĚŘIČ`. Pod kapotou:

1. POST `/add-meter` → `add_meter_to_options(meter_id, driver, "")` ve `webui.py`
2. Kontrola `SUPERVISOR_TOKEN`:
   - **Je** → POST na `http://supervisor/addons/self/options` s celým polem `meters[]` → Supervisor persistentně zapíše
   - **Není** → `write_json_atomic(/data/options.json, ...)` — přímý zápis souboru
3. Redirect zpět na `/discover?added=...`

Výsledek: měřič je v `options.json`, ale **wmbusmeters ho ještě nezná** (naučí se až po restartu).

### Krok 3 — podívej se „co čeká na restart"

WebUI hned ukáže, že máš neaktivní změny:

**Žlutý panel nahoře na /discover, /meters a dashboardu:**

```
┌─────────────────────────────────────────────────────────────┐
│ ⚠ Čekající změny — čekají na restart (2)                    │
│ Tyto měřiče jsou v options.json, ale add-on je ještě        │
│ nepřevzal. Restartujte add-on pro načtení.                  │
│ ┌─────────────────────────────────────────────┐             │
│ │ Meter ID   │ Driver       │ AES             │             │
│ │ 41553221   │ mkradio3     │ bez AES klíče   │             │
│ │ aabbccdd   │ amiplus      │ klíč nastaven   │             │
│ └─────────────────────────────────────────────┘             │
│                                                             │
│ [ RESTARTOVAT ADD-ON NYNÍ ]                                 │
└─────────────────────────────────────────────────────────────┘
```

Plus šedé/přerušované „pending" karty v mřížce nakonfigurovaných měřičů s nápisem „Čeká / čeká na restart".

Mechanismus funguje porovnáním `options.json` ↔ `status_meters.tsv`. Záznam zmizí z pending automaticky, jakmile wmbusmeters dekóduje první telegram pro toto ID.

### Krok 4 — restart

V režimu HA: klik **RESTARTOVAT ADD-ON NYNÍ** → POST `/restart-bridge` → volání `http://supervisor/addons/self/restart`.

V režimu Docker: místo tlačítka — pokyn `docker restart <container>`. Viz [§11](#11-home-assistant-vs-docker--rozdíly-ux).

### Krok 5 — hotovo

Po restartu dostane wmbusmeters novou konfiguraci, čeká na další telegram. Když přijde:

1. JSON přistane v MQTT (`wmbusmeters/<id>/...`)
2. `bridge.sh` zapíše záznam do `status_meters.tsv`
3. WebUI při dalším refreshi (15s) zobrazí měřič jako **Online** místo „Pending"
4. HA Discovery automaticky vytvoří entity `sensor.<id>_total_m3` atd.

---

## 7. Režim SEARCH — když LISTEN slyší příliš mnoho cizích měřičů

V bytovém domě tvůj přijímač zachytí 30-50 telegramů od sousedů. LISTEN ukáže 30 kandidátů. Který je tvůj?

**SEARCH to řeší porovnáním m³ odečtu z displeje fyzického měřiče** s dekódy všech kandidátů.

### Fáze

```mermaid
sequenceDiagram
  participant U as Uživatel
  participant W as WebUI /search
  participant B as bridge.sh
  participant WM as wmbusmeters

  U->>W: zadá expected=23.93, tolerance=0.05
  U->>W: klik ULOŽIT — AKTIVOVAT SEARCH A RESTARTOVAT
  W->>B: zápis options.json, restart addonu
  B->>B: fáze 1 — čte search_candidates.tsv,<br/>vytváří search_<id> měřič pro každého
  B->>WM: všechny telegramy dekódovány jako<br/>všechny možné ovladače
  WM-->>B: JSON pro každého kandidáta
  B->>B: porovnává total_m3 s expected ±tolerance
  B-->>W: SEARCH MATCH! zapisuje do search_matches.tsv
  W-->>U: zelený banner + tlačítko PŘIDAT MĚŘIČ
```

### Konfigurace přes UI

Jdi na `/search`:

1. **Odečet měřiče** — zadej aktuální hodnotu z displeje, např. `23.93` nebo `23,93` (oba akceptovány)
2. **Tolerance m³** — výchozí `0.05` (50 litrů). V bytovém domě **nepoužívej `0.5`** — mnoho měřičů může mít podobné hodnoty
3. Klik **ULOŽIT — AKTIVOVAT SEARCH A RESTARTOVAT**

Add-on se restartuje a přejde do SEARCH MODE. Čekej na další telegramy (typické intervaly: 30 s — 15 min v závislosti na měřiči).

### Výsledek

Když je shoda nalezena:

```
[wmbus-bridge][WARN] SEARCH MATCH: id=03534159 driver=hydrodigit
  media=water field=total_m3 value=23.932 m3
  expected=23.93 diff=0.002000 m3
[wmbus-bridge][WARN] SEARCH SUGGESTED CONFIG:
  {"id":"meter_03534159","meter_id":"03534159","type":"hydrodigit",
   "type_other":"","key":""}
```

WebUI na `/search` ukazuje:

```
✅ SEARCH MODE — NALEZENA SHODA
Hlavní výsledek: nalezena shoda (1)

┌──────────────────────────────────────────────────────┐
│ 03534159  hydrodigit · water                         │
│ value: 23.932 m³ · expected: 23.93 m³ · diff: 0.002  │
│ {"id":"meter_03534159","meter_id":"03534159",...}    │
│                                                      │
│ [ PŘIDAT MĚŘIČ ]  [ KOPÍROVAT KONFIG ]               │
└──────────────────────────────────────────────────────┘
```

Klik PŘIDAT MĚŘIČ → uloženo do `options.json`, restart, hotovo.

### Po dokončení

- **Vypni `search_mode`** — vrací se k normální práci s `meters[]`
- Dočasné `search_*` měřiče nevytvářejí entity v HA
- Soubory `/data/search_candidates.tsv` a `/data/search_matches.tsv` lze smazat, aby další hledání začínalo s čistým stavem

---

## 8. Kompletní reference konfigurace

Z [`config.yaml`](../config.yaml):

### MQTT — vstup / výstup

| Pole | Typ | Výchozí | Popis |
|---|---|---|---|
| `raw_topic` | str | `wmbus/+/telegram` | Topic se surovým HEX z přijímače. `+` je MQTT wildcard — odpovídá jednomu segmentu |
| `filter_hex_only` | bool | `true` | Ignoruj MQTT zprávy, které nevypadají jako HEX (chrání před odpadem) |
| `mqtt_mode` | enum | `auto` | `auto` (HA broker je-li dostupný, jinak external), `ha` (vynuť HA), `external` (vždy externí) |
| `external_mqtt_host` | str? | `""` | Host externího brokeru (když `mqtt_mode=external`) |
| `external_mqtt_port` | int | `1883` | Port externího brokeru |
| `external_mqtt_username` | str? | `""` | Uživatel brokeru |
| `external_mqtt_password` | str? | `""` | Heslo brokeru |

### Discovery a výstup

| Pole | Typ | Výchozí | Popis |
|---|---|---|---|
| `discovery_enabled` | bool | `true` | Publikuje konfiguraci HA Discovery |
| `discovery_prefix` | str | `homeassistant` | Standardní HA Discovery prefix |
| `discovery_retain` | bool | `true` | Discovery zprávy jako retained |
| `state_prefix` | str | `wmbusmeters` | Topic prefix pro hodnoty měřičů |
| `state_retain` | bool | `false` | Retained pro state (obvykle nechcete, HA stejně stahuje) |

### Režim SEARCH

| Pole | Typ | Výchozí | Popis |
|---|---|---|---|
| `search_mode` | bool | `false` | Aktivuje SEARCH (viz [§7](#7-režim-search--když-listen-slyší-příliš-mnoho-cizích-měřičů)) |
| `search_expected_value_m3` | float | `0` | Očekávaný m³ odečet z fyzického měřiče |
| `search_tolerance_m3` | float | `0.05` | Tolerance shody — v bytovém domě nepoužívej >`0.05` |
| `search_delta_mode` | bool | `false` | (Experimentální) Porovnává deltu místo absolutní hodnoty |
| `search_min_delta_m3` | float | `0.001` | Práh delty v `search_delta_mode` |
| `search_topic` | str | `wmbus/search/candidates` | Volitelné MQTT téma pro výsledky search |

### Debug

| Pole | Typ | Výchozí | Popis |
|---|---|---|---|
| `loglevel` | enum | `normal` | `normal` / `verbose` / `debug` — verbose loguje každý přijatý RAW |
| `debug_every_n` | int | `0` | Loguj diagnostiku každý N-tý telegram (0 = vyp) |

### Měřiče — `meters[]`

Každý záznam je objekt:

| Pole | Typ | Povinné | Popis |
|---|---|---|---|
| `id` | str | ano | Tvůj štítek, použitý v MQTT topiku a názvu HA senzoru |
| `meter_id` | str | ano | 8-znakový HEX, sériové číslo měřiče (z LISTEN) |
| `type` | enum | ano | wmbusmeters ovladač — úplný seznam 100+ v [`config.yaml:75`](../config.yaml#L75) nebo `auto`/`other` |
| `type_other` | str? | jen když `type=other` | Vlastní jméno ovladače |
| `key` | str? | jen pro šifrované měřiče | 32-znakový HEX, AES klíč |

Nejčastější ovladače pro vodu a teplo: `multical21`, `iperl`, `flowiq2200`, `mkradio3`, `mkradio4`, `kamwater`, `hydrodigit`, `hydrus`. Elektřina: `amiplus`. Teplo: `kamheat`, `hydrocalm3`, `qcaloric`.

---

## 9. MQTT témata — co publikujeme, co konzumujeme

### Odebíráme (vstup)

```
<raw_topic>  →  např. wmbus/<receiver_id>/telegram
```

Payload: surové HEX z wM-Bus telegramu, ASCII. Každý znak `[0-9A-Fa-f]`, délka typicky 40-200 znaků. Bridge filtruje payloady neodpovídající HEX (když `filter_hex_only=true`).

Příklad publikace od přijímače:

```bash
mosquitto_pub -h broker -t 'wmbus/esp32-attic/telegram' \
  -m '244D8C0682185601A06D7AE3000000020FFCB39D000000000B6E000000'
```

### Publikujeme (výstup)

#### State (dekódované hodnoty)

```
<state_prefix>/<id>/state
```

Např. pro měřič `id=cold_water_bathroom`:

```
wmbusmeters/cold_water_bathroom/state
  →  {"id":"cold_water_bathroom","name":"...","media":"water","total_m3":123.456,"flow_m3h":0.0,"timestamp":"2026-05-17T10:00:00+02:00"}
```

Celý dekódovaný telegram je publikován jako JSON payload na jednom state topicu na měřič; HA vybírá jednotlivá pole z něj přes `value_template` v Discovery.

#### Home Assistant Discovery

```
<discovery_prefix>/sensor/<id>_<field>/config
```

Např.:

```
homeassistant/sensor/wmbus_cold_water_bathroom/total_m3/config
  →  {"name":"cold_water_bathroom total_m3",
      "state_topic":"wmbusmeters/cold_water_bathroom/state",
      "value_template":"{{ value_json.get('total_m3') | default(none) }}",
      "json_attributes_topic":"wmbusmeters/cold_water_bathroom/state",
      "expire_after":3600,
      "unit_of_measurement":"m³",
      "device_class":"water",
      "state_class":"total_increasing",
      "unique_id":"wmbus_cold_water_bathroom_total_m3",
      ...}
```

#### SEARCH (volitelně)

```
<search_topic>  →  např. wmbus/search/candidates
```

Kandidáti nalezení v LISTEN fázi režimu SEARCH jsou publikováni zde.

---

## 10. Runtime soubory v `/data/`

Všechny soubory sdílené mezi `bridge.sh` ↔ `webui.py` žijí v `/data/`:

| Soubor | Formát | Zapisuje | Čte | Obsah |
|---|---|---|---|---|
| `options.json` | JSON | Supervisor / `webui.py` (fallback) | `bridge.sh`, `webui.py` | Hlavní konfigurace add-onu |
| `status.json` | JSON | `bridge.sh` | `webui.py` | Snapshot stavu pipeline (MQTT connected, counts, config echo) |
| `status_meters.tsv` | TSV | `bridge.sh` | `webui.py` | Dekódované měřiče — jeden řádek na meter_id |
| `status_candidates.tsv` | TSV | `bridge.sh` | `webui.py` | LISTEN kandidáti |
| `status_candidate_analysis.tsv` | TSV | `bridge.sh` | `webui.py` | Analýza šifrování kandidátů |
| `status_events.tsv` | TSV | `bridge.sh`, `webui.py` | `webui.py` | Posledních 80 událostí (RAW received, errors, UI actions) |
| `status_seen.tsv` | TSV | `bridge.sh` | `bridge.sh` | Historie intervalů příjmu (pro seen_15m/seen_60m statistiky) |
| `status_ignored_candidates.tsv` | text | `webui.py` | `bridge.sh`, `webui.py` | Seznam ID ignorovaných uživatelem |
| `status_raw_count.txt` | int | `bridge.sh` | `bridge.sh` | Počítadlo všech RAW telegramů této session |
| `status_last_raw_seen.txt` | ISO time | `bridge.sh` | `bridge.sh`, `webui.py` | Časové razítko posledního RAW |
| `status_recent_raw.tsv` | TSV | `bridge.sh` | (pro debug) | Kruhový buffer posledních N RAW HEX hodnot |
| `search_candidates.tsv` | TSV | `bridge.sh` | `bridge.sh` | Vodoměrné kandidáty pro SEARCH |
| `search_matches.tsv` | TSV | `bridge.sh` | `webui.py` | Shody nalezené v SEARCH |
| `search_status.json` | JSON | `bridge.sh` | `webui.py` | Živý SEARCH status (fáze, čísla) |

> ⚠️ Soubory v `/data/etc/` jsou **generovány při startu** — needituj ručně.

Tyto soubory přežívají restart kontejneru (mountovaný `/data` volume), ale `options.json` v HA je přepisován ze stavu Supervisora — ruční editace souboru nepřežijí restart v režimu HA.

---

## 11. Home Assistant vs Docker — rozdíly UX

Jedna kódová báze, dva módy běhu. UI sama detekuje mód podle přítomnosti `SUPERVISOR_TOKEN` v prostředí (HA injektuje, když `hassio_api: true`).

### Co funguje identicky

✅ Celé WebUI (Panel, Měřiče, Detekce, Hledání, Logy, Nastavení, O projektu)
✅ Lokalizace 5 jazyků
✅ Inline ADD v tabulce kandidátů (rozdíl pouze v zápisu: API vs soubor)
✅ Pending panel
✅ Bridge.sh — dekódování, MQTT, Discovery
✅ Výběr okamžitých hodnot (current_power_kw místo total_kwh)

### Co se liší

| Akce | Home Assistant | Docker standalone |
|---|---|---|
| Přidání měřiče | POST `http://supervisor/addons/self/options` (perzistentní) | `write_json_atomic(/data/options.json)` (soubor) |
| Banner po přidání | „Klikněte RESTART ADDON níže…" | „Restartujte kontejner ručně pro aplikování." |
| Pending panel — restart tlačítko | `[RESTARTOVAT ADD-ON NYNÍ]` (POST `/restart-bridge`) | Pokyn: `docker restart <container>` |
| `/settings` — restart sekce | Tlačítko + supervisor_api_notice | Žlutá karta s pokynem |
| `/candidate` — RESTART ADDON | POST tlačítko | Pokyn |
| Stažení nového image | HA Supervisor automaticky při „Update Available" | `docker pull ...` ručně |
| Perzistence změn | Supervisor (Supervisor DB) | `/data` volume |

### Proč tak

V Dockeru není Supervisor API. Volání `http://supervisor/addons/self/restart` by vrátilo chybu. Místo zobrazení rozbitého tlačítka uživateli, UI sama detekuje chybějící token a nahradí ho textovou instrukcí.

```mermaid
flowchart TD
  A["UI klik"] --> B{"is_supervisor_mode()<br/>SUPERVISOR_TOKEN env?"}
  B -- "ANO" --> C["POST /supervisor/addons/self/...<br/>Supervisor zapisuje + restartuje"]
  B -- "NE" --> D["write_json_atomic(options.json)<br/>+ pokyn uživateli:<br/>docker restart"]
```

---

## 12. Lokalizace UI

WebUI podporuje 5 jazyků:

| Kód | Jazyk | Pokrytí |
|---|---|---|
| `en` | English | 100% |
| `pl` | Polski | 100% |
| `de` | Deutsch | 100% |
| `cs` | Čeština | 100% |
| `sk` | Slovenčina | 100% |

### Jak je zvolen jazyk

Hierarchie (první shoda vyhrává):

1. **URL** — `?lang=pl` na konci adresy
2. **Cookie** — `wmbus_lang=pl` (nastavováno při kliknutí na přepínač)
3. **Hlavička** — `Accept-Language` od prohlížeče (např. `pl-PL, en;q=0.9`)
4. **Výchozí** — `en`

### Jak přepnout

Pravý horní roh každé stránky:

```
[EN]  PL   DE   CS   SK
```

Aktivní jazyk zvýrazněn. Klik = nastaví cookie a znovu načte stránku.

### Pro vývojáře

Všechny překlady jsou v jednom souboru — [rootfs/usr/bin/i18n.py](../rootfs/usr/bin/i18n.py). 153 klíčů × 5 jazyků. Přidání nového klíče:

1. Přidej do `I18N["en"]`, `I18N["pl"]`, … všech 5 slovníků
2. Použij ve `webui.py` jako `tr(lang, "tvuj_klic")`

Překlady jsou aplikovány přes přímá volání `tr()` — starý mechanismus `localize_html` (string replacement) je jen fallback.

---

## 13. Řešení problémů

### „Nevidím žádné telegramy" (RAW count = 0)

Zkontroluj postupně:

1. **Publikuje přijímač na správné téma?**
   - Tvoje konfigurace má `raw_topic: "wmbus/+/telegram"` — přijímač musí publikovat na `wmbus/<cokoli>/telegram`
   - Manuální test:
     ```bash
     mosquitto_sub -h <broker> -t 'wmbus/#' -v
     ```
2. **Je bridge odebráno?** Logy by měly obsahovat:
   ```
   [wmbus-bridge] mqtt: connected
   [wmbus-bridge] mqtt: subscribed to wmbus/+/telegram
   ```
3. **Neodmítá `filter_hex_only`?** Aktivuj `loglevel: verbose` a podívej se, jestli logy říkají `dropped (not HEX)`. Tvůj přijímač možná posílá base64 nebo JSON — v těchto případech vypni filter nebo změň formát.
4. **Je broker dosažitelný?** `mqtt_mode=auto` zkouší HA, pak external. Zkontroluj logy pro connection error.

### „Kandidát přidán, ale měřič se neobjevuje v Měřičích"

- Klik na **PŘIDAT MĚŘIČ** zapisuje do `options.json`, ale **nerestartuje wmbusmeters**. Musíš restartovat add-on.
- WebUI to ukazuje skrz **pending panel** (žlutý, nahoře na /discover, /meters, dashboardu).
- Po restartu dostane wmbusmeters nový seznam, ale potřebuje **další telegram** pro dekódování — může to trvat od několika desítek sekund až do mnoha minut v závislosti na intervalu měřiče.

### „Hodnota ukazuje číslo, které jen roste, ne okamžité"

Od verze **1.5.2-dev** UI preferuje okamžitá pole (`current_power_kw`, `volume_flow_m3h`, `_kw$`/`_w$`/`_m3h$`/`_l_h$`) před totals (`total_energy_consumption_kwh`).

Pro vodoměr bez `volume_flow_m3h` (např. mkradio3) — `total_m3` je jediné smysluplné pole a to se zobrazuje. Je to **stav měřiče** (jako na displeji vodoměru), ne kumulativní spotřeba — i když číslo roste, je aktuální pro dnešek.

Úplná logika výběru [v bridge.sh — `status_meter_seen`](../rootfs/usr/bin/bridge.sh).

### „HA neukazuje aktualizaci add-onu"

HA Supervisor detekuje novou verzi pouze když se `version:` v `config.yaml` změní. Tag image na GHCR je odvozen z `version:`. Viz [§15](#15-verzování-a-docker-image).

Vynucená kontrola: **Settings → System → ⋮ → Reload** nebo `ha supervisor restart` z CLI HA hostitele.

### „Mám šifrovaný měřič, ale nevím, odkud vzít AES klíč"

AES klíč dodává:
- **Dodavatel měřičů** (správce budovy, dodavatel vody/tepla)
- **Nálepka na měřiči** (zřídka)
- **Dokumentace měřiče** (pokud máš)

Bez klíče nedekóduješ šifrované telegramy. Některé měřiče používají tzv. „zero-key" (`00000000000000000000000000000000`) jako fasádové šifrování — někdy funguje.

### „Inline ADD nic neudělal" (v Dockeru)

Zkontroluj:
- Je adresář `./config/` **zapisovatelný** pro uživatele kontejneru (ne `:ro`)
- Je v logu `Meter added to options.json (file only — no SUPERVISOR_TOKEN)` — to znamená, že soubor byl uložen. Restartuj kontejner ručně.
- Zkontroluj obsah `options.json` po kliknutí — měl by obsahovat nový záznam v `meters[]`.

---

## 14. Architektura kódu — pro vývojáře

### Struktura repozitáře

```
.
├── config.yaml                  # Manifest HA add-onu: opce, schema, image
├── Dockerfile                   # Multi-stage: builder + docker + addon
├── repository.yaml              # Manifest HA repa
├── CHANGELOG.md
├── README.md
├── docs/                        # Úplná vícejazyčná dokumentace
│   ├── README.en.md
│   ├── README.pl.md
│   ├── README.de.md
│   ├── README.cs.md
│   └── README.sk.md
├── docker/                      # Soubory pouze pro Docker standalone
│   ├── entrypoint.sh
│   └── examples/                # docker-compose + příkladová config/
├── rootfs/                      # Kopírováno do / v HA image
│   ├── etc/services.d/          # s6-overlay service definice
│   │   ├── wmbus_mqtt_bridge/
│   │   └── wmbus_webui/
│   └── usr/bin/
│       ├── bridge.sh            # 1400+ řádků — hlavní smyčka, MQTT, decode
│       ├── i18n.py              # Překlady pro 5 jazyků
│       ├── run.sh               # Startup wrapper pro HA režim
│       └── webui.py             # 1700+ řádků — HTTP server, stránky, API
├── translations/                # Překlady HA add-on opcí (en.yaml, pl.yaml)
└── .github/workflows/           # CI: build-addon, shellcheck, yaml-lint
```

### Hlavní komponenty

#### `bridge.sh` (1400+ řádků)

Bash, jeden proces. Hlavní smyčka:

1. **Setup** — čtení `options.json`, generování `wmbusmeters.conf` v `/data/etc/`
2. **MQTT subscribe** — `mosquitto_sub` na `raw_topic`, každý řádek → `process_raw_telegram`
3. **HEX → wmbusmeters** — předáno přes `stdin:hex`
4. **JSON parse** — další řádek z `mosquitto_sub` na wmbusmeters topiku
5. **Status update** — zápis do `status_meters.tsv`, `status_events.tsv`, `status.json`
6. **HA Discovery publish** — MQTT Discovery zprávy vypočítané pro každé nové pole
7. **SEARCH** — pokud aktivováno, dekóduje kandidáty z `search_candidates.tsv` paralelně

Klíčové funkce:
- `status_meter_seen()` ([řádek 316](../rootfs/usr/bin/bridge.sh#L316)) — zapisuje záznam do `status_meters.tsv`, vybírá value_key (okamžitý > kumulativní)
- `status_candidate_seen()` ([řádek 341](../rootfs/usr/bin/bridge.sh#L341)) — registruje LISTEN kandidáta
- `process_raw_telegram()` — hlavní HEX → decode pipeline

#### `webui.py` (1700+ řádků)

Python 3.12, `http.server.ThreadingHTTPServer`. Bez frameworku — surové HTTP + HTML stringy. Hlavní sekce:

- **`state()`** ([řádek 583](../rootfs/usr/bin/webui.py#L583)) — čte všechny runtime soubory, vrací dict
- **`add_meter_to_options()`** ([řádek 385](../rootfs/usr/bin/webui.py#L385)) — Supervisor API + file fallback
- **`is_supervisor_mode()`** — detekuje HA vs Docker režim
- **`pending_meters()`** — diff `options.json` ↔ `status_meters.tsv`
- **`render_*()`** — funkce renderující jednotlivé HTML fragmenty (system_status, stats, meter_card, candidates_table, …)
- **`page_*()`** — renderery celých stránek (`page_dashboard`, `page_meters`, `page_discover`, `page_search`, `page_candidate`, `page_logs`, `page_settings`, `page_about`)
- **`Handler` (BaseHTTPRequestHandler)** — GET/POST routing, language detection, cookie handling

Lokalizace (`i18n.py`):
- `tr(lang, key)` — hlavní překladová funkce
- `localize_html(html, lang)` — legacy string-replacement (fallback)
- `detect_lang(headers, params)` — URL → cookie → Accept-Language → default

#### `wmbusmeters` (upstream)

Binárka kompilovaná z [upstream](https://github.com/wmbusmeters/wmbusmeters) v Dockerfile builder stage. Volaná s `stdin:hex` — čte HEX z stdin, dekóduje, publikuje JSON do MQTT.

> ⚙️ Patch v Dockerfile odstraňuje `-flto` z Makefile, protože aktuální Alpine toolchain má problémy s LTO.

### Lokální build

```bash
# HA image build (multi-arch):
docker buildx build \
  --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.20 \
  --target addon \
  -t wmbus-mqtt-bridge:local \
  .

# Docker standalone image build:
docker buildx build \
  --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.20 \
  --target docker \
  -t wmbus-bridge-docker:local \
  .
```

### Lokální testy webui.py

```bash
cd rootfs/usr/bin
WMBUS_BASE=/tmp/wmbus-test python webui.py
# Otevři http://localhost:8099/
```

S fake daty (smoke test):

```python
import os, tempfile, json, pathlib
base = tempfile.mkdtemp()
os.environ['WMBUS_BASE'] = base
p = pathlib.Path(base)
p.joinpath('options.json').write_text(json.dumps({
    'meters': [{'id':'test','meter_id':'12345678','type':'multical21','key':''}]
}))
p.joinpath('status_meters.tsv').write_text('')
import webui
print(webui.render_page('/discover', {}, 'pl'))
```

---

## 15. Verzování a Docker image

### Schéma verzování

`MAJOR.MINOR.PATCH-dev` — semver s `-dev` suffixem (vývojářský kanál).

| Část | Bumpuje při |
|---|---|
| MAJOR | Breaking change v konfiguraci / MQTT / discovery |
| MINOR | Nové funkce (např. lokalizace, pending panel, inline ADD) |
| PATCH | Bug fixes, drobné UX |
| `-dev` | Dokud jsme ve vývojářském kanále |

### GHCR image tagy

Každý build pushuje 2 tagy:

```
ghcr.io/kustonium/amd64-addon-wmbus_mqtt_bridge-dev:1.5.4-dev   ← verze
ghcr.io/kustonium/amd64-addon-wmbus_mqtt_bridge-dev:dev          ← rolling latest
```

Plus to samé pro `aarch64-addon-...`. HA Supervisor používá tag verze (z `image` + `version` v `config.yaml`).

### CI/CD workflow

```mermaid
flowchart LR
  A["push do main"] --> B[".github/workflows/build.yaml"]
  B --> C["build amd64 image"]
  B --> D["build aarch64 image"]
  C --> E["push :1.5.4-dev + :dev<br/>do GHCR"]
  D --> E
  E --> F["HA Supervisor při<br/>'Check for updates'<br/>vidí novou verzi"]
  E --> G["Docker uživatel:<br/>docker pull ručně"]
```

Bump verze v `config.yaml` je **vyžadován**, aby HA detekoval aktualizaci — bez změny `version:` se HA nepodívá na GHCR, ani když byl image znovu sestaven.

---

## 16. Licence a upstream projekty

### Licence

**GNU General Public License v3.0 (GPL-3.0)**

Toto repo obsahuje a modifikuje kód z projektu `wmbusmeters-ha-addon` (GPL-3.0). Celý projekt — včetně forku, nových komponent (webui.py, i18n.py, bridge.sh rewrite, pending panel, inline ADD) — je distribuován pod GPL-3.0.

### Upstream

- **wmbusmeters** — https://github.com/wmbusmeters/wmbusmeters (Fredrik Öhrström, GPL-3.0)
  - wM-Bus telegram dekodér, kompilovaný ze zdrojáku v Dockerfile
- **wmbusmeters-ha-addon** — https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)
  - Původní HA add-on, ze kterého fork startoval

### Atribuce

Projekt je fork vyvíjený **Kustoniem**. Hlavní rozdíl proti upstream: MQTT vstup místo lokálního donglu, WebUI v polštině/angličtině/němčině/češtině/slovenštině, plný LISTEN → ADD → SEARCH workflow přes UI.

---

**Konec dokumentace.** Otázky, bugy, návrhy → [GitHub Issues](https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge/issues).

📚 Dokument připravený Paige (BMad Method Technical Writer) pro Foszta · 2026-05-17

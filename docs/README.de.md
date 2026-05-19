> 🌐 [EN](README.en.md) | [PL](README.pl.md) | [**DE**](README.de.md) | [CS](README.cs.md) | [SK](README.sk.md)

> 🤖 **Maschinelle Übersetzung** — Diese Dokumentation wurde maschinell aus dem Polnischen übersetzt. Sie kann Fehler enthalten.

# wMBus MQTT Bridge — vollständige Dokumentation (DE)

> Dokumentversion: **1.5.4-dev**  ·  Sprache: **Deutsch**  ·  Status: Dev-Channel des Home Assistant Add-ons
>
> Eine kurze zweisprachige Übersicht findest du im Haupt-[README.md](../README.md). Dieses Dokument ist die vollständige deutsche Dokumentation — von „Was ist das?" bis zu Architektur- und Laufzeitdetails.

---

## Inhaltsverzeichnis

1. [TL;DR — was es tut](#1-tldr--was-es-tut)
2. [Datenfluss-Architektur](#2-datenfluss-architektur)
3. [Schnellstart — Home Assistant](#3-schnellstart--home-assistant)
4. [Schnellstart — Docker standalone](#4-schnellstart--docker-standalone)
5. [WebUI — 7 Ansichten](#5-webui--7-ansichten)
6. [Typischer Workflow: von leer zum funktionierenden Zähler](#6-typischer-workflow-von-leer-zum-funktionierenden-zähler)
7. [SEARCH-Modus — wenn LISTEN zu viele fremde Zähler hört](#7-search-modus--wenn-listen-zu-viele-fremde-zähler-hört)
8. [Vollständige Konfigurationsreferenz](#8-vollständige-konfigurationsreferenz)
9. [MQTT-Topics — was wir veröffentlichen, was wir konsumieren](#9-mqtt-topics--was-wir-veröffentlichen-was-wir-konsumieren)
10. [Laufzeit-Dateien in `/data/`](#10-laufzeit-dateien-in-data)
11. [Home Assistant vs. Docker — UX-Unterschiede](#11-home-assistant-vs-docker--ux-unterschiede)
12. [UI-Lokalisierung](#12-ui-lokalisierung)
13. [Problemlösung](#13-problemlösung)
14. [Code-Architektur — für Entwickler](#14-code-architektur--für-entwickler)
15. [Versionierung und Docker-Images](#15-versionierung-und-docker-images)
16. [Lizenz und Upstream-Projekte](#16-lizenz-und-upstream-projekte)

---

## 1. TL;DR — was es tut

> **In einem Satz:** Das Add-on dekodiert Wireless-M-Bus-Telegramme (Wasserzähler, Wärmezähler, Stromzähler) **ohne lokalen USB-Dongle** — die rohen HEX-Telegramme liefert ihm ein beliebiger externer Empfänger (ESP32, Bridge, Gateway) über MQTT.

Standardmäßig benötigt `wmbusmeters` einen am Host angeschlossenen Funk-Dongle. Dieses Projekt löst es anders:

- **Du** hast einen Funkempfänger weit weg von Home Assistant (z. B. einen ESP32 auf dem Dachboden mit Antenne).
- **Der Empfänger** veröffentlicht rohe HEX-Frames an MQTT.
- **Dieses Add-on** abonniert diesen Broker, füttert `wmbusmeters` über `stdin:hex`, dekodiert JSON und veröffentlicht das Ergebnis zurück an MQTT + Home Assistant Discovery.

Ergebnis: **Deine Zähler erscheinen als Sensoren in HA, ohne Funkhardware auf der HA-Seite.**

> 🤝 **Zusammenspiel mit der ESPHome-Firmware** — Dieses Add-on wird typischerweise zusammen mit [`esphome-wmbus-bridge-rawonly`](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly) verwendet, einer ESPHome-External-Component, die auf einem ESP32 mit einem **CC1101-, SX1276- oder SX1262**-Funkchip läuft. Der ESP empfängt die Funkframes und veröffentlicht rohes HEX über MQTT; dieses Add-on dekodiert sie. Beide Projekte sind **unabhängig** — das Add-on akzeptiert HEX aus jeder Quelle, die auf das konfigurierte `raw_topic` veröffentlicht.

---

## 2. Datenfluss-Architektur

### Daten-Pipeline

```mermaid
%%{init: {'theme':'default'}}%%
flowchart LR
  subgraph EXT["🛰️ Externer Empfänger (außerhalb HA)"]
    A1["ESP32 / Gateway / Bridge<br/>mit CC1101-, SX1276- oder SX1262-Modul"]
  end

  subgraph BROKER["📡 MQTT-Broker"]
    B1["topic: wmbus/+/telegram<br/>(rohes HEX)"]
    B2["topic: wmbusmeters/&lt;id&gt;/...<br/>(dekodiertes JSON)"]
    B3["topic: homeassistant/sensor/...<br/>(MQTT Discovery)"]
  end

  subgraph ADDON["🧩 wMBus MQTT Bridge (dieses Add-on)"]
    C1["bridge.sh<br/>mosquitto_sub → stdin → wmbusmeters"]
    C2["wmbusmeters<br/>(stdin:hex-Decoder)"]
    C3["webui.py<br/>Port 8099"]
    C1 -- "HEX in" --> C2
    C2 -- "JSON out" --> C1
    C3 -. "liest status.json + tsv" .-> C1
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

### Komponentenkarte innerhalb des Containers

```mermaid
%%{init: {'theme':'default'}}%%
flowchart TB
  subgraph CONTAINER["🐳 Add-on-Container"]
    direction TB
    S6["s6-overlay (init)"] --> SVC1["service: wmbus_mqtt_bridge<br/>(bridge.sh)"]
    S6 --> SVC2["service: wmbus_webui<br/>(webui.py)"]
    SVC1 -- "telegram HEX in" --> WM["wmbusmeters --useconf"]
    WM -- "JSON out" --> SVC1
    SVC1 -- "TSV/JSON Laufzeit-State" --> DATA["/data/*.tsv<br/>/data/status.json"]
    SVC2 -- "liest" --> DATA
    SVC2 -. "Supervisor API<br/>(wenn HA)" .-> SUP["http://supervisor"]
  end
```

**Drei parallel laufende Prozesse**, verwaltet von `s6-overlay`:

| Prozess | Was er macht | Datei |
|---|---|---|
| `bridge.sh` | Abonniert MQTT, füttert wmbusmeters mit HEX, parst JSON, veröffentlicht Ergebnisse | [rootfs/usr/bin/bridge.sh](../rootfs/usr/bin/bridge.sh) |
| `wmbusmeters` | Telegramm-Decoder (Upstream-Binary — Fredrik Öhrström) | `/usr/bin/wmbusmeters` |
| `webui.py` | HTTP-Server auf Port 8099, Verwaltungspanel | [rootfs/usr/bin/webui.py](../rootfs/usr/bin/webui.py) |

Die drei Komponenten kommunizieren nur über **Dateien in `/data/`** — keine Sockets innerhalb des Containers. Dadurch kann die WebUI unabhängig von der Bridge neu gestartet werden, und der Zustand bleibt über Neustarts erhalten.

> 🔗 **Auf der Empfängerseite (ESP32 mit Radio)** — wir verwenden Kustoniums Schwesterprojekt: **[esphome-wmbus-bridge-rawonly-dev](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly-dev)** — ESPHome-Firmware für SX1262 / SX1276 / CC1101, die rohes HEX an `wmbus/<device>/telegram` veröffentlicht. Das Topic passt exakt zu unserem Standard `raw_topic: wmbus/+/telegram` — auf unserer Seite ist keine Konfiguration nötig. Der Empfänger hat eine eigene vollständige Dokumentation (EN/PL) — beginne mit [`START_HERE.md`](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly-dev/blob/main/docs/START_HERE.md).

---

## 3. Schnellstart — Home Assistant

### Schritt 1 — Repository hinzufügen

In HA: **Settings → Add-ons → Add-on Store → ⋮ (Menü) → Repositories**, hinzufügen:

```
https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge
```

### Schritt 2 — Add-on installieren

Im Store **wMBus MQTT Bridge Dev** (Bereich „dev") suchen, **Install** klicken.

> ⚠️ Installiere nicht parallel das offizielle `wmbusmeters`-Add-on — dieses Projekt enthält seine eigene wmbusmeters-Instanz und dupliziert sie.

### Schritt 3 — mit leerer `meters`-Liste starten (LISTEN-Modus)

Klicke **Start**. Standardmäßig `meters: []` — das Add-on geht in den LISTEN-Modus und hört nur zu, konfiguriert noch nichts.

### Schritt 4 — WebUI öffnen

Im **Info**-Tab des Add-ons klicke **OPEN WEB UI**. Das Dashboard begrüßt dich:

```
┌────────────────────────────────────────────────────────────────┐
│ wMBus MQTT Bridge                              [EN PL DE CS SK]│
│ Dashboard | Zähler | Erkennung | Suche | Logs | Einstell. | ⋮  │
├────────────────────────────────────────────────────────────────┤
│ Dashboard                                                      │
│ Pipeline-Laufzeitstatus...                                     │
│                                                                │
│ [System status]  [Statistics]  [Discovery]                     │
│                                                                │
│ Konfigurierte Zähler                                           │
│   (leer)                                                       │
│                                                                │
│ Erkannte Kandidaten                                            │
│   12 Kandidaten / ERKENNUNG ÖFFNEN                             │
└────────────────────────────────────────────────────────────────┘
```

### Schritt 5 — zu „Erkennung" gehen und Zähler hinzufügen

Im **ERKENNUNG**-Tab siehst du die Liste der Kandidaten. Für jeden ohne AES-Schlüssel-Anforderung — eine **ZÄHLER HINZUFÜGEN**-Schaltfläche direkt inline in der Zeile. Klick, Neustart, fertig.

➡️ Vollständige Beschreibung dieses Workflows in [§6 Typischer Workflow](#6-typischer-workflow-von-leer-zum-funktionierenden-zähler).

---

## 4. Schnellstart — Docker standalone

Für alle außerhalb von Home Assistant (DietPi, Ubuntu, Raspberry Pi OS, NAS usw.).

### Voraussetzungen

- Docker + docker compose
- Ein funktionierender MQTT-Broker (Mosquitto, EMQX, …), vom Host erreichbar
- Ein Funkempfänger, der HEX-Frames an den Broker veröffentlicht — z. B. [esphome-wmbus-bridge-rawonly-dev](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly-dev) (veröffentlicht an `wmbus/<device>/telegram`, out-of-the-box kompatibel)

### Installation

```bash
git clone https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge.git
mkdir -p /home/wmbus-test
cp -a homeassistant-wmbus-mqtt-bridge/docker/examples/* /home/wmbus-test/
cd /home/wmbus-test
docker compose up -d --build
docker compose logs -f wmbus
```

Die ersten Logs sollten zeigen:

```
[wmbus-bridge] mqtt: connected to 192.168.1.10:1883
[wmbus-bridge] No meters configured -> LISTEN MODE
```

### Konfiguration

Bearbeite `./config/options.json`. Vollständige Feldreferenz in [§8](#8-vollständige-konfigurationsreferenz). Minimalbeispiel:

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

Nach dem Bearbeiten:

```bash
docker compose restart wmbus
```

### WebUI unter Docker

Port 8099 in `docker-compose.yml` freigeben:

```yaml
services:
  wmbus:
    ports:
      - "8099:8099"
```

Dann `http://<host-ip>:8099/` öffnen.

> 💡 Im Docker-Modus erkennt die UI das fehlende `SUPERVISOR_TOKEN` und ersetzt RESTART-Schaltflächen durch einen `docker restart <container>`-Hinweis — siehe [§11](#11-home-assistant-vs-docker--ux-unterschiede).

---

## 5. WebUI — 7 Ansichten

Die WebUI ist in **5 Sprachen** verfügbar (EN/PL/DE/CS/SK) — Sprachumschalter oben rechts. Die Sprache wird in dieser Reihenfolge erkannt: `?lang=`, Cookie `wmbus_lang`, Header `Accept-Language`.

Alle Seiten aktualisieren sich automatisch alle 15 Sekunden (außer `/candidate`).

### Tab-Karte

```mermaid
flowchart LR
  N1["DASHBOARD<br/>/"] --> N2["ZÄHLER<br/>/meters"]
  N2 --> N3["ERKENNUNG<br/>/discover"]
  N3 --> N4["SUCHE<br/>/search"]
  N4 --> N5["LOGS<br/>/logs"]
  N5 --> N6["EINSTELLUNGEN<br/>/settings"]
  N6 --> N7["INFO<br/>/about"]
  N3 -.->|ANALYSIEREN| N8["/candidate?id=...<br/>(Kandidatendetails)"]
```

### 5.1. Dashboard (`/`)

Drei Karten oben: **System status** (MQTT, RAW telegrams, wmbusmeters, decoded JSON, configured meters, HA Discovery), **Statistics** (Zahlen + Mini-Balken), **Discovery status** (Präfixe + Anzahl Zähler/Kandidaten).

Darunter: kompaktes Raster konfigurierter Zähler + Kandidaten-Zusammenfassung mit der „ERKENNUNG ÖFFNEN"-Schaltfläche.

Wenn du **ausstehende Änderungen** hast (du hast etwas vor dem Neustart hinzugefügt) — ein gelbes Panel erscheint hier, auf `/meters` und auf `/discover`. Siehe [§6](#schritt-3--sehen-was-auf-neustart-wartet).

### 5.2. Zähler (`/meters`)

Vollständiges Raster **dekodierter** Zähler. Jede Karte:

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

Der Hauptwert ist der **aktuelle** Momentanwert oder der Zählerstand (seit Version 1.5.2-dev — siehe [§13](#13-problemlösung)).

### 5.3. Erkennung (`/discover`)

Tabelle der LISTEN-Modus-Kandidaten. Für jeden siehst du: ID, Treiber, Medium (💧/⚡/🔥/📡), Verschlüsselung (AES required / no AES / —), Empfang (15m/60m), letztes Telegramm, Aktionen.

**Aktionen** hängen vom Verschlüsselungs-Pill ab:

| Pill | Schaltflächen |
|---|---|
| 🟢 **no AES** oder grau **—** | `[ZÄHLER HINZUFÜGEN] [ANALYSIEREN] [IGNORIEREN]` — inline ADD, ein Klick = schreibt in `options.json` |
| 🔴 **AES required** | `[ANALYSIEREN] [IGNORIEREN]` — du musst `/candidate` aufrufen und einen 32-Zeichen-HEX-Schlüssel einfügen |

Medienfilter oben: **Alle / Wasser / Strom / Wärme / Andere**. Der zweite Link `[Ignoriert]` zeigt zuvor ignorierte Kandidaten (mit WIEDERHERSTELLEN-Option).

### 5.4. Suche (`/search`)

Servicemodus — wird verwendet, wenn LISTEN dutzende Nachbarn-Zähler zurückgibt (z. B. Mietshaus) und du nicht weißt, welcher deiner ist. Siehe den eigenen Abschnitt [§7](#7-search-modus--wenn-listen-zu-viele-fremde-zähler-hört).

Die UI hat 3 (kontextuelle) Banner:

- 🟢 **MATCH FOUND** — wenn ein Treffer gefunden wurde
- 🟢 **SEARCH MODE ACTIVE** — läuft, wartet auf weitere Telegramme
- 🟡 **SEARCH MODE — Konfiguration** — vor dem Aktivieren

Plus ein Konfigurationsformular (m³-Stand + Toleranz) und Live-Status von bridge.sh (KV: phase, cached, ignored, loaded, decoded, checked, matches, last candidate, last checked, last reason).

### 5.5. Logs (`/logs`)

Kurzer Laufzeit-Ereignisstrom aus [`status_events.tsv`](#10-laufzeit-dateien-in-data) — RAW received, candidate detected, errors. Vollständige Logs sind weiterhin im HA-Add-on-**Log**-Tab.

### 5.6. Einstellungen (`/settings`)

Zeigt die aktive Laufzeitkonfiguration (aus `status.json`):
- `raw_topic`, `state_prefix`, `discovery_prefix`
- `search_mode`, `search_expected_value_m3`, `search_tolerance_m3`
- `loglevel`, MQTT-Host, Anzahl ignorierter Kandidaten

Plus ein **RESTART ADDON**-Block (oder im Docker-Modus: ein `docker restart`-Hinweis) und eine Liste von Laufzeit-Dateien + eine **MANAGE IGNORED CANDIDATES**-Schaltfläche (leitet auf `/discover?ignored=1` weiter).

### 5.7. Info (`/about`)

Kurze Architekturbeschreibung und ASCII-Diagramm.

---

## 6. Typischer Workflow: von leer zum funktionierenden Zähler

```mermaid
flowchart TD
  A["1️⃣ Add-on starten<br/>meters=[]"] --> B["bridge.sh wechselt<br/>in LISTEN-Modus"]
  B --> C["Empfänger veröffentlicht<br/>HEX → wmbusmeters<br/>→ Kandidat sichtbar"]
  C --> D{"Siehst du den Kandidaten<br/>auf /discover?"}
  D -- "ja, no AES" --> E["2️⃣ Klick ZÄHLER HINZUFÜGEN<br/>(inline)"]
  D -- "ja, AES required" --> F["2a. Klick ANALYSIEREN<br/>→ HEX-Schlüssel eingeben<br/>→ ZÄHLER HINZUFÜGEN"]
  D -- "nein" --> G["Prüfe Empfänger,<br/>Broker, raw_topic,<br/>filter_hex_only"]
  E --> H["3️⃣ Kandidat verschwindet,<br/>Pending-Panel zeigt<br/>'wartet auf Neustart'"]
  F --> H
  H --> I["4️⃣ Klick RESTART ADDON<br/>(Panel oder /settings)"]
  I --> J["5️⃣ Nach dem ersten Telegramm<br/>geht der Zähler Online<br/>auf /meters"]
```

### Schritt 1 — erster Start

`meters: []` in der Konfiguration. Das Add-on startet, verbindet sich mit dem Broker, wartet. In den Logs:

```
[wmbus-bridge] mqtt: connected
[wmbus-bridge] No meters configured -> LISTEN MODE
[wmbus-bridge][INFO] === NEW METER CANDIDATE DETECTED ===
[wmbus-bridge][INFO] Received telegram from: 41553221
[wmbus-bridge][INFO] Suggested driver: mkradio3
```

WebUI → **Erkennung** zeigt 41553221 mit dem Treiber `mkradio3`.

### Schritt 2 — Kandidaten hinzufügen

Für einen Zähler ohne Verschlüsselung: in der **ERKENNUNG**-Zeile `ZÄHLER HINZUFÜGEN` klicken. Im Hintergrund:

1. POST `/add-meter` → `add_meter_to_options(meter_id, driver, "")` in `webui.py`
2. Prüfung von `SUPERVISOR_TOKEN`:
   - **Vorhanden** → POST an `http://supervisor/addons/self/options` mit dem gesamten `meters[]`-Array → Supervisor persistiert es
   - **Fehlt** → `write_json_atomic(/data/options.json, ...)` — direkter Dateischreibvorgang
3. Redirect zurück auf `/discover?added=...`

Ergebnis: Der Zähler ist in `options.json`, aber **wmbusmeters kennt ihn noch nicht** (lernt ihn erst nach einem Neustart).

### Schritt 3 — sehen, was auf Neustart wartet

Die WebUI zeigt sofort, dass du inaktive Änderungen hast:

**Gelbes Panel oben auf /discover, /meters und Dashboard:**

```
┌─────────────────────────────────────────────────────────────┐
│ ⚠ Ausstehende Änderungen — warten auf Neustart (2)          │
│ Diese Zähler sind in options.json, aber das Add-on hat sie  │
│ noch nicht übernommen. Add-on neu starten zum Laden.        │
│ ┌─────────────────────────────────────────────┐             │
│ │ Meter ID   │ Driver       │ AES             │             │
│ │ 41553221   │ mkradio3     │ kein AES-Schl.  │             │
│ │ aabbccdd   │ amiplus      │ AES-Schl. ges.  │             │
│ └─────────────────────────────────────────────┘             │
│                                                             │
│ [ ADD-ON JETZT NEUSTARTEN ]                                 │
└─────────────────────────────────────────────────────────────┘
```

Plus graue/gestrichelte „Pending"-Karten im Raster konfigurierter Zähler mit der Aufschrift „Wartet / Neustart erforderlich".

Der Mechanismus funktioniert durch Vergleich von `options.json` ↔ `status_meters.tsv`. Ein Eintrag verschwindet aus Pending automatisch, sobald wmbusmeters das erste Telegramm für diese ID dekodiert.

### Schritt 4 — Neustart

Im HA-Modus: Klick **ADD-ON JETZT NEUSTARTEN** → POST `/restart-bridge` → Aufruf von `http://supervisor/addons/self/restart`.

Im Docker-Modus: Statt der Schaltfläche — die Anweisung `docker restart <container>`. Siehe [§11](#11-home-assistant-vs-docker--ux-unterschiede).

### Schritt 5 — fertig

Nach dem Neustart erhält wmbusmeters die neue Konfiguration, wartet auf das nächste Telegramm. Wenn es eintrifft:

1. JSON landet in MQTT (`wmbusmeters/<id>/...`)
2. `bridge.sh` schreibt einen Eintrag in `status_meters.tsv`
3. WebUI beim nächsten Refresh (15s) zeigt den Zähler als **Online** statt „Pending"
4. HA Discovery erstellt automatisch Entitäten `sensor.<id>_total_m3` usw.

---

## 7. SEARCH-Modus — wenn LISTEN zu viele fremde Zähler hört

In einem Mehrfamilienhaus fängt dein Empfänger 30-50 Telegramme von Nachbarn. LISTEN zeigt 30 Kandidaten. Welcher ist deiner?

**SEARCH löst es, indem der m³-Stand vom Display des physischen Zählers** mit den Dekodierungen aller Kandidaten verglichen wird.

### Phasen

```mermaid
sequenceDiagram
  participant U as Benutzer
  participant W as WebUI /search
  participant B as bridge.sh
  participant WM as wmbusmeters

  U->>W: gibt ein expected=23.93, tolerance=0.05
  U->>W: Klick SPEICHERN — SEARCH AKTIVIEREN UND NEUSTART
  W->>B: schreibt options.json, startet Addon neu
  B->>B: Phase 1 — liest search_candidates.tsv,<br/>erstellt search_<id>-Zähler für jeden
  B->>WM: alle Telegramme dekodiert als<br/>alle möglichen Treiber
  WM-->>B: JSON für jeden Kandidaten
  B->>B: vergleicht total_m3 mit expected ±tolerance
  B-->>W: SEARCH MATCH! schreibt in search_matches.tsv
  W-->>U: grüner Banner + ZÄHLER-HINZUFÜGEN-Schaltfläche
```

### Konfiguration über die UI

Gehe auf `/search`:

1. **Zählerstand** — gib den aktuellen Wert vom Display ein, z. B. `23.93` oder `23,93` (beide akzeptiert)
2. **Toleranz m³** — Standard `0.05` (50 Liter). In einem Mehrfamilienhaus **verwende nicht `0.5`** — viele Zähler können ähnliche Werte haben
3. Klick **SPEICHERN — SEARCH AKTIVIEREN UND NEUSTART**

Das Add-on startet neu und geht in den SEARCH-Modus. Warte auf weitere Telegramme (typische Intervalle: 30 s — 15 min, je nach Zähler).

### Ergebnis

Wenn ein Treffer gefunden wird:

```
[wmbus-bridge][WARN] SEARCH MATCH: id=03534159 driver=hydrodigit
  media=water field=total_m3 value=23.932 m3
  expected=23.93 diff=0.002000 m3
[wmbus-bridge][WARN] SEARCH SUGGESTED CONFIG:
  {"id":"meter_03534159","meter_id":"03534159","type":"hydrodigit",
   "type_other":"","key":""}
```

WebUI auf `/search` zeigt:

```
✅ SEARCH MODE — TREFFER GEFUNDEN
Hauptergebnis: Treffer gefunden (1)

┌──────────────────────────────────────────────────────┐
│ 03534159  hydrodigit · water                         │
│ value: 23.932 m³ · expected: 23.93 m³ · diff: 0.002  │
│ {"id":"meter_03534159","meter_id":"03534159",...}    │
│                                                      │
│ [ ZÄHLER HINZUFÜGEN ]  [ KONFIG KOPIEREN ]           │
└──────────────────────────────────────────────────────┘
```

Klick ZÄHLER HINZUFÜGEN → in `options.json` gespeichert, Neustart, fertig.

### Nach dem Abschluss

- **Schalte `search_mode` aus** — kehrt zum Normalbetrieb mit `meters[]` zurück
- Temporäre `search_*`-Zähler erstellen keine HA-Entitäten
- Dateien `/data/search_candidates.tsv` und `/data/search_matches.tsv` können gelöscht werden, damit die nächste Suche mit einem sauberen Zustand startet

---

## 8. Vollständige Konfigurationsreferenz

Aus [`config.yaml`](../config.yaml):

### MQTT — Eingang / Ausgang

| Feld | Typ | Standard | Beschreibung |
|---|---|---|---|
| `raw_topic` | str | `wmbus/+/telegram` | Topic mit rohem HEX vom Empfänger. `+` ist MQTT-Wildcard — passt auf ein Segment |
| `filter_hex_only` | bool | `true` | MQTT-Nachrichten ignorieren, die nicht wie HEX aussehen (schützt vor Müll) |
| `mqtt_mode` | enum | `auto` | `auto` (HA-Broker wenn verfügbar, sonst extern), `ha` (HA erzwingen), `external` (immer extern) |
| `external_mqtt_host` | str? | `""` | Externer Broker-Host (wenn `mqtt_mode=external`) |
| `external_mqtt_port` | int | `1883` | Externer Broker-Port |
| `external_mqtt_username` | str? | `""` | Broker-Benutzername |
| `external_mqtt_password` | str? | `""` | Broker-Passwort |

### Discovery und Ausgang

| Feld | Typ | Standard | Beschreibung |
|---|---|---|---|
| `discovery_enabled` | bool | `true` | Veröffentlicht HA-Discovery-Konfiguration |
| `discovery_prefix` | str | `homeassistant` | Standard-HA-Discovery-Präfix |
| `discovery_retain` | bool | `true` | Discovery-Nachrichten als retained |
| `state_prefix` | str | `wmbusmeters` | Topic-Präfix für Zählerwerte |
| `state_retain` | bool | `false` | Retained für State (normalerweise nicht gewünscht, HA pullt sowieso) |

### SEARCH-Modus

| Feld | Typ | Standard | Beschreibung |
|---|---|---|---|
| `search_mode` | bool | `false` | Aktiviert SEARCH (siehe [§7](#7-search-modus--wenn-listen-zu-viele-fremde-zähler-hört)) |
| `search_expected_value_m3` | float | `0` | Erwarteter m³-Stand vom physischen Zähler |
| `search_tolerance_m3` | float | `0.05` | Treffertoleranz — im Mehrfamilienhaus nicht >`0.05` verwenden |
| `search_delta_mode` | bool | `false` | (Experimentell) Vergleicht Delta statt absoluten Wert |
| `search_min_delta_m3` | float | `0.001` | Delta-Schwellenwert für `search_delta_mode` |
| `search_topic` | str | `wmbus/search/candidates` | Optionales MQTT-Topic für Suchergebnisse |

### Debug

| Feld | Typ | Standard | Beschreibung |
|---|---|---|---|
| `loglevel` | enum | `normal` | `normal` / `verbose` / `debug` — verbose loggt jedes empfangene RAW |
| `debug_every_n` | int | `0` | Diagnostik jedes N-te Telegramm loggen (0 = aus) |

### Zähler — `meters[]`

Jeder Eintrag ist ein Objekt:

| Feld | Typ | Erforderlich | Beschreibung |
|---|---|---|---|
| `id` | str | ja | Dein Label, verwendet im MQTT-Topic und HA-Sensornamen |
| `meter_id` | str | ja | 8-Zeichen-HEX, Zähler-Seriennummer (aus LISTEN) |
| `type` | enum | ja | wmbusmeters-Treiber — vollständige Liste von 100+ in [`config.yaml:75`](../config.yaml#L75) oder `auto`/`other` |
| `type_other` | str? | nur wenn `type=other` | Benutzerdefinierter Treibername |
| `key` | str? | nur für verschlüsselte Zähler | 32-Zeichen-HEX, AES-Schlüssel |

Häufigste Treiber für Wasser und Wärme: `multical21`, `iperl`, `flowiq2200`, `mkradio3`, `mkradio4`, `kamwater`, `hydrodigit`, `hydrus`. Strom: `amiplus`. Wärme: `kamheat`, `hydrocalm3`, `qcaloric`.

---

## 9. MQTT-Topics — was wir veröffentlichen, was wir konsumieren

### Wir abonnieren (Eingang)

```
<raw_topic>  →  z. B. wmbus/<receiver_id>/telegram
```

Payload: rohes HEX aus dem wM-Bus-Telegramm, ASCII. Jedes Zeichen `[0-9A-Fa-f]`, Länge typischerweise 40-200 Zeichen. Die Bridge filtert Payloads aus, die nicht zu HEX passen (wenn `filter_hex_only=true`).

Beispiel-Publish vom Empfänger:

```bash
mosquitto_pub -h broker -t 'wmbus/esp32-attic/telegram' \
  -m '244D8C0682185601A06D7AE3000000020FFCB39D000000000B6E000000'
```

### Wir veröffentlichen (Ausgang)

#### State (dekodierte Werte)

```
<state_prefix>/<id>/state
```

Z. B. für einen Zähler `id=cold_water_bathroom`:

```
wmbusmeters/cold_water_bathroom/state
  →  {"id":"cold_water_bathroom","name":"...","media":"water","total_m3":123.456,"flow_m3h":0.0,"timestamp":"2026-05-17T10:00:00+02:00"}
```

Das gesamte dekodierte Telegramm wird als JSON-Payload auf einem einzigen state-Topic pro Zähler veröffentlicht; HA wählt einzelne Felder daraus über `value_template` in Discovery aus.

#### Home Assistant Discovery

```
<discovery_prefix>/sensor/<id>_<field>/config
```

Z. B.:

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

#### SEARCH (optional)

```
<search_topic>  →  z. B. wmbus/search/candidates
```

Kandidaten, die in der LISTEN-Phase des SEARCH-Modus gefunden wurden, werden hier veröffentlicht.

---

## 10. Laufzeit-Dateien in `/data/`

Alle Dateien, die zwischen `bridge.sh` ↔ `webui.py` geteilt werden, leben in `/data/`:

| Datei | Format | Schreibt | Liest | Inhalt |
|---|---|---|---|---|
| `options.json` | JSON | Supervisor / `webui.py` (Fallback) | `bridge.sh`, `webui.py` | Hauptkonfiguration des Add-ons |
| `status.json` | JSON | `bridge.sh` | `webui.py` | Pipeline-State-Snapshot (MQTT connected, counts, config echo) |
| `status_meters.tsv` | TSV | `bridge.sh` | `webui.py` | Dekodierte Zähler — eine Zeile pro meter_id |
| `status_candidates.tsv` | TSV | `bridge.sh` | `webui.py` | LISTEN-Kandidaten |
| `status_candidate_analysis.tsv` | TSV | `bridge.sh` | `webui.py` | Verschlüsselungsanalyse der Kandidaten |
| `status_events.tsv` | TSV | `bridge.sh`, `webui.py` | `webui.py` | Letzte 80 Ereignisse (RAW received, errors, UI actions) |
| `status_seen.tsv` | TSV | `bridge.sh` | `bridge.sh` | Empfangsintervall-Historie (für seen_15m/seen_60m-Statistiken) |
| `status_ignored_candidates.tsv` | text | `webui.py` | `bridge.sh`, `webui.py` | Liste der vom Benutzer ignorierten IDs |
| `status_raw_count.txt` | int | `bridge.sh` | `bridge.sh` | Zähler aller RAW-Telegramme dieser Sitzung |
| `status_last_raw_seen.txt` | ISO time | `bridge.sh` | `bridge.sh`, `webui.py` | Zeitstempel des letzten RAW |
| `status_recent_raw.tsv` | TSV | `bridge.sh` | (für Debug) | Ringpuffer der letzten N RAW-HEX-Werte |
| `search_candidates.tsv` | TSV | `bridge.sh` | `bridge.sh` | Wasserzähler-Kandidaten für SEARCH |
| `search_matches.tsv` | TSV | `bridge.sh` | `webui.py` | In SEARCH gefundene Treffer |
| `search_status.json` | JSON | `bridge.sh` | `webui.py` | Live-SEARCH-Status (Phase, Zahlen) |

> ⚠️ Dateien in `/data/etc/` werden **beim Start generiert** — nicht manuell bearbeiten.

Diese Dateien überleben den Container-Neustart (gemountetes `/data`-Volume), aber `options.json` in HA wird vom Supervisor-Zustand überschrieben — manuelle Bearbeitungen der Datei überleben einen Neustart im HA-Modus nicht.

---

## 11. Home Assistant vs. Docker — UX-Unterschiede

Eine Codebasis, zwei Run-Modi. Die UI erkennt den Modus selbst anhand der `SUPERVISOR_TOKEN`-Umgebungsvariable (HA injiziert sie, wenn `hassio_api: true`).

### Was identisch funktioniert

✅ Die gesamte WebUI (Dashboard, Zähler, Erkennung, Suche, Logs, Einstellungen, Info)
✅ 5-Sprachen-Lokalisierung
✅ Inline ADD in der Kandidaten-Tabelle (Unterschied nur im Schreiben: API vs. Datei)
✅ Pending-Panel
✅ Bridge.sh — Dekodierung, MQTT, Discovery
✅ Auswahl von Momentanwerten (current_power_kw statt total_kwh)

### Was sich unterscheidet

| Aktion | Home Assistant | Docker standalone |
|---|---|---|
| Zähler hinzufügen | POST `http://supervisor/addons/self/options` (persistent) | `write_json_atomic(/data/options.json)` (Datei) |
| Banner nach dem Hinzufügen | „Klicke RESTART ADDON unten…" | „Container manuell neu starten zum Übernehmen." |
| Pending-Panel — Restart-Schaltfläche | `[ADD-ON JETZT NEUSTARTEN]` (POST `/restart-bridge`) | Hinweis: `docker restart <container>` |
| `/settings` — Restart-Bereich | Schaltfläche + supervisor_api_notice | Gelbe Karte mit Hinweis |
| `/candidate` — RESTART ADDON | POST-Schaltfläche | Hinweis |
| Neues Image pullen | HA Supervisor automatisch bei „Update Available" | `docker pull ...` manuell |
| Persistenz der Änderungen | Supervisor (Supervisor-DB) | `/data`-Volume |

### Warum

Es gibt keine Supervisor-API in Docker. Ein Aufruf an `http://supervisor/addons/self/restart` würde einen Fehler zurückgeben. Statt dem Benutzer eine kaputte Schaltfläche zu zeigen, erkennt die UI das fehlende Token und ersetzt es durch eine textuelle Anweisung.

```mermaid
flowchart TD
  A["UI-Klick"] --> B{"is_supervisor_mode()<br/>SUPERVISOR_TOKEN env?"}
  B -- "JA" --> C["POST /supervisor/addons/self/...<br/>Supervisor schreibt + startet neu"]
  B -- "NEIN" --> D["write_json_atomic(options.json)<br/>+ Hinweis an Benutzer:<br/>docker restart"]
```

---

## 12. UI-Lokalisierung

Die WebUI unterstützt 5 Sprachen:

| Code | Sprache | Abdeckung |
|---|---|---|
| `en` | English | 100% |
| `pl` | Polski | 100% |
| `de` | Deutsch | 100% |
| `cs` | Čeština | 100% |
| `sk` | Slovenčina | 100% |

### Wie die Sprache gewählt wird

Hierarchie (erster Match gewinnt):

1. **URL** — `?lang=pl` am Ende der Adresse
2. **Cookie** — `wmbus_lang=pl` (gesetzt beim Klick auf den Umschalter)
3. **Header** — `Accept-Language` vom Browser (z. B. `pl-PL, en;q=0.9`)
4. **Standard** — `en`

### Wie umschalten

Oben rechts auf jeder Seite:

```
[EN]  PL   DE   CS   SK
```

Aktive Sprache hervorgehoben. Klick = setzt das Cookie und lädt die Seite neu.

### Für Entwickler

Alle Übersetzungen leben in einer einzigen Datei — [rootfs/usr/bin/i18n.py](../rootfs/usr/bin/i18n.py). 153 Schlüssel × 5 Sprachen. Hinzufügen eines neuen Schlüssels:

1. In `I18N["en"]`, `I18N["pl"]`, … alle 5 Wörterbücher hinzufügen
2. In `webui.py` als `tr(lang, "dein_schluessel")` verwenden

Übersetzungen werden durch direkte `tr()`-Aufrufe angewendet — der alte `localize_html`-Mechanismus (String-Ersetzung) ist nur ein Fallback.

---

## 13. Problemlösung

### „Ich sehe keine Telegramme" (RAW count = 0)

Prüfe der Reihe nach:

1. **Veröffentlicht der Empfänger im richtigen Topic?**
   - Deine Konfiguration hat `raw_topic: "wmbus/+/telegram"` — der Empfänger muss in `wmbus/<irgendetwas>/telegram` veröffentlichen
   - Manueller Test:
     ```bash
     mosquitto_sub -h <broker> -t 'wmbus/#' -v
     ```
2. **Ist die Bridge abonniert?** Die Logs sollten enthalten:
   ```
   [wmbus-bridge] mqtt: connected
   [wmbus-bridge] mqtt: subscribed to wmbus/+/telegram
   ```
3. **Verwirft `filter_hex_only` sie?** Aktiviere `loglevel: verbose` und prüfe, ob die Logs `dropped (not HEX)` sagen. Dein Empfänger sendet möglicherweise base64 oder JSON — in diesen Fällen den Filter deaktivieren oder das Format ändern.
4. **Ist der Broker erreichbar?** `mqtt_mode=auto` versucht zuerst HA, dann external. Prüfe die Logs auf Connection-Errors.

### „Kandidat hinzugefügt, aber der Zähler erscheint nicht in Zähler"

- Klick auf **ZÄHLER HINZUFÜGEN** schreibt in `options.json`, aber **startet wmbusmeters nicht neu**. Du musst das Add-on neu starten.
- Die WebUI zeigt das durch das **Pending-Panel** (gelb, oben auf /discover, /meters, Dashboard).
- Nach dem Neustart erhält wmbusmeters die neue Liste, braucht aber **ein weiteres Telegramm** zum Dekodieren — das kann von einigen Dutzend Sekunden bis zu vielen Minuten dauern, je nach Zähler-Intervall.

### „Der Wert zeigt eine Zahl, die nur wächst, nicht eine Momentanzahl"

Seit Version **1.5.2-dev** bevorzugt die UI Momentanwerte (`current_power_kw`, `volume_flow_m3h`, `_kw$`/`_w$`/`_m3h$`/`_l_h$`) gegenüber Totals (`total_energy_consumption_kwh`).

Für einen Wasserzähler ohne `volume_flow_m3h` (z. B. mkradio3) — `total_m3` ist das einzige sinnvolle Feld und das wird angezeigt. Es ist der **Zählerstand** (wie auf dem Display des Wasserzählers), nicht der kumulative Verbrauch — obwohl die Zahl wächst, ist sie aktuell für heute.

Die vollständige Auswahllogik [in bridge.sh — `status_meter_seen`](../rootfs/usr/bin/bridge.sh).

### „HA zeigt kein Add-on-Update"

HA Supervisor erkennt eine neue Version nur, wenn sich `version:` in `config.yaml` ändert. Das Image-Tag auf GHCR wird aus `version:` abgeleitet. Siehe [§15](#15-versionierung-und-docker-images).

Prüfung erzwingen: **Settings → System → ⋮ → Reload** oder `ha supervisor restart` von der HA-Host-CLI.

### „Ich habe einen verschlüsselten Zähler, aber ich weiß nicht, woher ich den AES-Schlüssel bekomme"

Der AES-Schlüssel wird bereitgestellt von:
- **Dem Zählerlieferanten** (Hausverwaltung, Wasser-/Wärmelieferant)
- **Einem Aufkleber auf dem Zähler** (selten)
- **Zählerdokumentation** (falls vorhanden)

Ohne Schlüssel kannst du verschlüsselte Telegramme nicht dekodieren. Manche Zähler verwenden einen sogenannten „zero-key" (`00000000000000000000000000000000`) als Fassaden-Verschlüsselung — funktioniert manchmal.

### „Inline ADD hat nichts gemacht" (unter Docker)

Prüfe:
- Ist das Verzeichnis `./config/` für den Container-Benutzer **schreibbar** (nicht `:ro`)
- Steht in den Logs `Meter added to options.json (file only — no SUPERVISOR_TOKEN)` — das bedeutet, die Datei wurde gespeichert. Container manuell neu starten.
- Prüfe den Inhalt von `options.json` nach dem Klick — sollte einen neuen Eintrag in `meters[]` enthalten.

---

## 14. Code-Architektur — für Entwickler

### Repository-Struktur

```
.
├── config.yaml                  # HA-Add-on-Manifest: Optionen, Schema, Image
├── Dockerfile                   # Multi-stage: builder + docker + addon
├── repository.yaml              # HA-Repo-Manifest
├── CHANGELOG.md
├── README.md
├── docs/                        # Vollständige mehrsprachige Dokumentation
│   ├── README.en.md
│   ├── README.pl.md
│   ├── README.de.md
│   ├── README.cs.md
│   └── README.sk.md
├── docker/                      # Dateien nur für Docker standalone
│   ├── entrypoint.sh
│   └── examples/                # docker-compose + Beispiel-config/
├── rootfs/                      # Kopiert nach / im HA-Image
│   ├── etc/services.d/          # s6-overlay-Service-Definitionen
│   │   ├── wmbus_mqtt_bridge/
│   │   └── wmbus_webui/
│   └── usr/bin/
│       ├── bridge.sh            # 1400+ Zeilen — Hauptschleife, MQTT, Decode
│       ├── i18n.py              # Übersetzungen für 5 Sprachen
│       ├── run.sh               # Startup-Wrapper für HA-Modus
│       └── webui.py             # 1700+ Zeilen — HTTP-Server, Seiten, API
├── translations/                # HA-Add-on-Options-Übersetzungen (en.yaml, pl.yaml)
└── .github/workflows/           # CI: build-addon, shellcheck, yaml-lint
```

### Hauptkomponenten

#### `bridge.sh` (1400+ Zeilen)

Bash, ein Prozess. Hauptschleife:

1. **Setup** — `options.json` lesen, `wmbusmeters.conf` in `/data/etc/` generieren
2. **MQTT subscribe** — `mosquitto_sub` auf `raw_topic`, jede Zeile → `process_raw_telegram`
3. **HEX → wmbusmeters** — über `stdin:hex` weitergeleitet
4. **JSON parse** — nächste Zeile von `mosquitto_sub` auf dem wmbusmeters-Topic
5. **Status-Update** — Schreiben in `status_meters.tsv`, `status_events.tsv`, `status.json`
6. **HA Discovery publish** — MQTT-Discovery-Nachrichten für jedes neue Feld berechnet
7. **SEARCH** — wenn aktiviert, dekodiert Kandidaten aus `search_candidates.tsv` parallel

Schlüsselfunktionen:
- `status_meter_seen()` ([Zeile 316](../rootfs/usr/bin/bridge.sh#L316)) — schreibt einen Eintrag in `status_meters.tsv`, wählt value_key (Momentanwert > kumulativ)
- `status_candidate_seen()` ([Zeile 341](../rootfs/usr/bin/bridge.sh#L341)) — registriert einen LISTEN-Kandidaten
- `process_raw_telegram()` — Haupt-HEX-→-Decode-Pipeline

#### `webui.py` (1700+ Zeilen)

Python 3.12, `http.server.ThreadingHTTPServer`. Kein Framework — rohes HTTP + HTML-Strings. Hauptabschnitte:

- **`state()`** ([Zeile 583](../rootfs/usr/bin/webui.py#L583)) — liest alle Laufzeit-Dateien, gibt ein dict zurück
- **`add_meter_to_options()`** ([Zeile 385](../rootfs/usr/bin/webui.py#L385)) — Supervisor API + File-Fallback
- **`is_supervisor_mode()`** — erkennt HA- vs. Docker-Modus
- **`pending_meters()`** — diff `options.json` ↔ `status_meters.tsv`
- **`render_*()`** — Funktionen, die einzelne HTML-Fragmente rendern (system_status, stats, meter_card, candidates_table, …)
- **`page_*()`** — Renderer für ganze Seiten (`page_dashboard`, `page_meters`, `page_discover`, `page_search`, `page_candidate`, `page_logs`, `page_settings`, `page_about`)
- **`Handler` (BaseHTTPRequestHandler)** — GET/POST-Routing, Spracherkennung, Cookie-Handling

Lokalisierung (`i18n.py`):
- `tr(lang, key)` — Hauptübersetzungsfunktion
- `localize_html(html, lang)` — Legacy-String-Ersetzung (Fallback)
- `detect_lang(headers, params)` — URL → Cookie → Accept-Language → default

#### `wmbusmeters` (upstream)

Binary, kompiliert aus [upstream](https://github.com/wmbusmeters/wmbusmeters) in der Dockerfile-Builder-Stage. Aufgerufen mit `stdin:hex` — liest HEX von stdin, dekodiert, veröffentlicht JSON an MQTT.

> ⚙️ Ein Patch im Dockerfile entfernt `-flto` aus dem Makefile, weil die aktuelle Alpine-Toolchain Probleme mit LTO hat.

### Lokaler Build

```bash
# HA-Image-Build (multi-arch):
docker buildx build \
  --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.20 \
  --target addon \
  -t wmbus-mqtt-bridge:local \
  .

# Docker-standalone-Image-Build:
docker buildx build \
  --build-arg BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.20 \
  --target docker \
  -t wmbus-bridge-docker:local \
  .
```

### Lokale webui.py-Tests

```bash
cd rootfs/usr/bin
WMBUS_BASE=/tmp/wmbus-test python webui.py
# Öffne http://localhost:8099/
```

Mit Fake-Daten (smoke test):

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

## 15. Versionierung und Docker-Images

### Versionsschema

`MAJOR.MINOR.PATCH-dev` — semver mit `-dev`-Suffix (Entwicklerkanal).

| Teil | Bumpt bei |
|---|---|
| MAJOR | Breaking Change in Konfiguration / MQTT / Discovery |
| MINOR | Neue Funktionen (z. B. Lokalisierung, Pending-Panel, Inline ADD) |
| PATCH | Bug-Fixes, kleinere UX |
| `-dev` | Solange wir im Entwicklerkanal sind |

### GHCR-Image-Tags

Jeder Build pusht 2 Tags:

```
ghcr.io/kustonium/amd64-addon-wmbus_mqtt_bridge-dev:1.5.4-dev   ← Version
ghcr.io/kustonium/amd64-addon-wmbus_mqtt_bridge-dev:dev          ← Rolling Latest
```

Plus dasselbe für `aarch64-addon-...`. HA Supervisor verwendet das Versions-Tag (aus `image` + `version` in `config.yaml`).

### CI/CD-Workflow

```mermaid
flowchart LR
  A["push nach main"] --> B[".github/workflows/build.yaml"]
  B --> C["build amd64 image"]
  B --> D["build aarch64 image"]
  C --> E["push :1.5.4-dev + :dev<br/>nach GHCR"]
  D --> E
  E --> F["HA Supervisor bei<br/>'Check for updates'<br/>sieht neue Version"]
  E --> G["Docker-Benutzer:<br/>docker pull manuell"]
```

Ein Versions-Bump in `config.yaml` ist **erforderlich**, damit HA ein Update erkennt — ohne Änderung von `version:` schaut HA nicht auf GHCR, selbst wenn das Image neu gebaut wurde.

---

## 16. Lizenz und Upstream-Projekte

### Lizenz

**GNU General Public License v3.0 (GPL-3.0)**

Dieses Repository enthält und modifiziert Code aus dem `wmbusmeters-ha-addon`-Projekt (GPL-3.0). Das gesamte Projekt — einschließlich des Forks, neuer Komponenten (webui.py, i18n.py, bridge.sh-Rewrite, Pending-Panel, Inline ADD) — wird unter GPL-3.0 distribuiert.

### Upstream

- **wmbusmeters** — https://github.com/wmbusmeters/wmbusmeters (Fredrik Öhrström, GPL-3.0)
  - Der wM-Bus-Telegramm-Decoder, kompiliert aus dem Quellcode im Dockerfile
- **wmbusmeters-ha-addon** — https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)
  - Das ursprüngliche HA-Add-on, mit dem der Fork gestartet ist

### Attribution

Das Projekt ist ein von **Kustonium** entwickelter Fork. Der Hauptunterschied zum Upstream: MQTT-Eingang statt eines lokalen Dongles, WebUI auf Polnisch/Englisch/Deutsch/Tschechisch/Slowakisch, vollständiger LISTEN → ADD → SEARCH-Workflow über die UI.

---

**Ende der Dokumentation.** Fragen, Bugs, Vorschläge → [GitHub Issues](https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge/issues).

📚 Dokument vorbereitet von Paige (BMad Method Technical Writer) für Foszt · 2026-05-17

# Getting Started — wMBus MQTT Bridge Dev

Current as of: `2026-05-29`.

- [English](#english)
- [Polski](#polski)
- [Deutsch](#deutsch)
- [Česky](#česky)
- [Slovenčina](#slovenčina)

---

## English

### 1. Prerequisites

- An MQTT broker reachable from the add-on or Docker container.
- A receiver that publishes Wireless M-Bus RAW HEX payloads to MQTT
  (an ESP32 with CC1101 / SX1276 / SX1262 is the typical setup).
- For AES-encrypted meters: the 32-character HEX key per meter.

The bridge reads MQTT payloads only — the topic just routes them. With
`filter_hex_only: true` (the default), whitespace is removed, an
optional `0x` prefix is stripped, non-HEX payloads are dropped, and
odd-length HEX is dropped.

### 2. Start under Home Assistant

1. Configure the add-on options. Defaults work for most installs.
2. MQTT:
   - `mqtt_mode: auto` (default) — use the HA broker when present, fall
     back to `external_mqtt_*`.
   - `mqtt_mode: ha` — require the HA broker.
   - `mqtt_mode: external` — use `external_mqtt_host`,
     `external_mqtt_port`, `external_mqtt_username`,
     `external_mqtt_password`.
3. Leave `raw_topic: wmbus/+/telegram` unless your publisher uses a
   different topic. The `+` segment is also used as the ESP device name
   for the WebGUI pipeline.
4. Start the add-on. Two services run: the bridge and the WebGUI.
   The WebGUI listens on port `8099` internally and is reached through
   Ingress.

### 3. Start under Docker

```bash
docker compose -f docker/examples/docker-compose.yml up -d --build
```

On first run, `docker/entrypoint.sh` writes a default `/config/options.json`.
Edit it for your environment. The generated file currently uses
`external_mqtt_host: mosquitto` and `raw_topic: wmbus_bridge/+/telegram`;
set `raw_topic: wmbus/+/telegram` manually when your receiver publishes
to `wmbus/<device>/telegram`, then restart:

```bash
docker compose -f docker/examples/docker-compose.yml restart wmbus
```

`/config` must be writable. The WebGUI is reachable at
`http://<host>:8099/`.

### 4. First telegrams (LISTEN → Discover → add)

Start with `meters: []`. The bridge is in LISTEN mode and writes seen
IDs to `status_candidates.tsv`.

Open `#/discover`:

1. Wait for candidate IDs to appear.
2. Each row shows driver guess, media, encryption hint, last telegram,
   reception counters and (if available) a preview value.
3. Candidates **without** an AES key are decoded **automatically** — the
   parallel LISTEN instance is seeded with a `meter-preview-<id>` file
   under `listen/etc/wmbusmeters.d/` on every (re)start (soft-reloaded via
   `.reload_listen`), so the preview value appears on its own after the
   next decoded telegram. There is no manual preview toggle in the current
   table. Candidates that **require AES** show no value until you add a key.
4. Use the value filter (numeric input with `± tolerance`) when several
   candidates share the same driver.
5. Click **Add meter**. The WebGUI calls `/api/add-meter` followed by
   `/api/reload-pipeline`. The DECODE pipeline restarts without
   restarting the container; first decoded JSON arrives within a few
   seconds of the next telegram from the meter.

### 5. Meter configuration

Minimal entry:

```json
{
  "id": "cold_water",
  "meter_id": "12345678",
  "type": "auto",
  "type_other": "",
  "key": ""
}
```

Field rules:

- `id` — stable identifier used in generated `wmbusmeters` configs and HA
  entity IDs. Changing it later renames entities.
- `meter_id` — 8-character hex ID printed on the device.
- `type` — `auto` lets `wmbusmeters` guess from telegram type; otherwise
  pick a specific driver. Use `other` + `type_other` for drivers not in
  the schema.
- `key` — empty for unencrypted meters, exactly 32 hex characters for
  AES.

After the first decoded telegram, the meter appears in `#/meters` and
JSON is published to `<state_prefix>/<meter_id>/state`
(default `wmbusmeters/<meter_id>/state`).

### 6. Discovery and Home Assistant entities

With `discovery_enabled: true` (default), `bridge.sh` publishes
HA MQTT Discovery configs under `discovery_prefix` (default
`homeassistant`). It creates one sensor per numeric JSON field
emitted by `wmbusmeters`. Units, `device_class` and `state_class` are
derived from the field name suffix and the meter media.

Entities show up in **Home Assistant → Settings → Devices &
Services → MQTT → Devices** as `wmbus_<id>`.

### 7. SEARCH (advanced)

SEARCH compares decoded readings to an expected m³ value. It is
controlled by:

- `search_mode`
- `search_expected_value_m3`
- `search_tolerance_m3`
- `search_delta_mode`
- `search_min_delta_m3`
- `search_topic`

`bridge.sh` collects water candidates in `search_candidates.tsv`,
generates temporary meter files in SEARCH mode, compares decoded values,
and writes `search_status.json` and `search_matches.tsv`. The current
`#/search` UI shows the result tables only; add the identified meter from
`#/discover`, then set `search_mode: false` to return to normal operation.

The hidden `#/search` route in the WebGUI is the entry point for
advanced users.

### 8. Troubleshooting

**No RAW telegrams counted**
- Verify MQTT credentials, host and port.
- Verify the receiver publishes to `raw_topic`.
- Verify the payload is HEX (not JSON wrapping); `filter_hex_only`
  drops anything else.
- Check `#/logs` and the `Statystyki` view for current/previous minute
  rate.

**ESP devices not shown**
- The `raw_topic` must contain a `+` wildcard for ESP device detection.
- The matched segment becomes the ESP name in `#/esp-logs`.
- Diagnostic event topics `wmbus/+/diag` and `wmbus/+/diag/#` are optional
  log feeds. The exact `wmbus/+/diag/summary` topic is an optional heartbeat;
  with no diag enabled, ESPs are still detected from the RAW topic
  (primary source).
- Boot/diagnostic retained messages are log-only. ESP activity is detected
  from `wmbus/+/telegram`; a device seen on that topic stays counted for the
  current bridge session. `wmbus/+/diag/summary` is an optional fresh
  heartbeat.

**Configured meter does not decode**
- Verify `meter_id` (must be 8 hex characters).
- Try `type: auto`; if that fails, pick a specific `wmbusmeters` driver.
- Verify the AES key if the meter is encrypted.
- Wait for the next transmission — intervals are controlled by the
  meter, not the add-on.

**Bridge pipeline restart**
- `Restart add-on` button uses the Supervisor API. In Docker it does not
  restart the container without `SUPERVISOR_TOKEN`; use `docker restart`.
- Adding a meter from the WebGUI calls `/api/reload-pipeline`
  automatically; removing a meter does not call that endpoint in the
  current frontend, so the old decode config may persist until reload or
  restart.

---

## Polski

### 1. Wymagania

- Broker MQTT dostępny z dodatku lub kontenera Docker.
- Odbiornik publikujący telegramy Wireless M-Bus RAW HEX do MQTT
  (typowo ESP32 z CC1101 / SX1276 / SX1262).
- Dla liczników szyfrowanych AES: 32-znakowy klucz HEX per licznik.

Bridge czyta tylko payload MQTT. Przy `filter_hex_only: true`
(domyślnie) usuwa whitespace, usuwa opcjonalny prefiks `0x`, ignoruje
payload nie-HEX i HEX o nieparzystej długości.

### 2. Start w Home Assistant

1. Skonfiguruj opcje dodatku — w większości instalacji wystarczają
   wartości domyślne.
2. MQTT:
   - `mqtt_mode: auto` (domyślnie) — broker HA gdy dostępny, w innym
     razie `external_mqtt_*`.
   - `mqtt_mode: ha` — wymuś brokera HA.
   - `mqtt_mode: external` — broker zewnętrzny.
3. Zostaw `raw_topic: wmbus/+/telegram`, chyba że publisher używa
   innego topicu. Segment `+` służy też jako nazwa urządzenia ESP
   w pipeline.
4. Uruchom dodatek. Działają dwie usługi: bridge i WebGUI. WebGUI
   nasłuchuje na porcie `8099` wewnętrznie, dostęp przez Ingress.

### 3. Start w Dockerze

```bash
docker compose -f docker/examples/docker-compose.yml up -d --build
```

Przy pierwszym starcie `docker/entrypoint.sh` zapisuje domyślny
`/config/options.json`. Edytuj go pod swoje środowisko. Wygenerowany
plik używa obecnie `external_mqtt_host: mosquitto` i
`raw_topic: wmbus_bridge/+/telegram`; ustaw ręcznie
`raw_topic: wmbus/+/telegram`, jeśli odbiornik publikuje na
`wmbus/<device>/telegram`, następnie restart:

```bash
docker compose -f docker/examples/docker-compose.yml restart wmbus
```

`/config` musi być zapisywalny. WebGUI dostępne pod
`http://<host>:8099/`.

### 4. Pierwsze telegramy (LISTEN → Discover → dodaj)

Zacznij od `meters: []`. Bridge jest w trybie LISTEN i zapisuje
widziane ID do `status_candidates.tsv`.

Otwórz `#/discover`:

1. Czekaj aż pojawią się ID kandydatów.
2. Każdy wiersz pokazuje sugerowany driver, medium, podpowiedź
   szyfrowania, ostatni telegram, liczniki odbioru i (jeśli dostępne)
   preview wartości.
3. Kandydaci **bez** klucza AES są dekodowani **automatycznie** —
   równoległa instancja LISTEN dostaje plik `meter-preview-<id>` w
   `listen/etc/wmbusmeters.d/` przy każdym (re)starcie (miękkie
   przeładowanie przez `.reload_listen`), więc wartość pojawia się sama po
   następnym zdekodowanym telegramie. W aktualnej tabeli nie ma ręcznego
   przełącznika podglądu. Kandydaci **wymagający AES** nie pokazują
   wartości, dopóki nie podasz klucza.
4. Użyj filtra po wartości (input z `± tolerancja`) jeśli kilka
   kandydatów dzieli driver.
5. Kliknij **Dodaj licznik**. WebGUI wywołuje `/api/add-meter` a
   potem `/api/reload-pipeline`. Pipeline DECODE restartuje się bez
   restartu kontenera; pierwszy zdekodowany JSON przychodzi po
   kilku sekundach od następnego telegramu.

### 5. Konfiguracja licznika

Minimalny wpis:

```json
{
  "id": "cold_water",
  "meter_id": "12345678",
  "type": "auto",
  "type_other": "",
  "key": ""
}
```

Zasady pól:

- `id` — stabilny identyfikator używany w generowanych configach
  `wmbusmeters` i ID encji HA. Późniejsza zmiana zmieni nazwy encji.
- `meter_id` — 8-znakowy hex ID nadrukowany na urządzeniu.
- `type` — `auto` pozwala `wmbusmeters` zgadnąć z telegramu;
  alternatywnie wybierz konkretny driver. `other` + `type_other` dla
  driverów spoza schematu.
- `key` — puste dla nieszyfrowanych, dokładnie 32 znaki hex dla AES.

Po pierwszym zdekodowanym telegramie licznik pojawia się w `#/meters`
i JSON publikowany jest na `<state_prefix>/<meter_id>/state`
(domyślnie `wmbusmeters/<meter_id>/state`).

### 6. Discovery i encje Home Assistant

Przy `discovery_enabled: true` (domyślnie) `bridge.sh` publikuje
configy HA MQTT Discovery pod `discovery_prefix` (domyślnie
`homeassistant`). Tworzy po jednym sensorze na każde numeryczne pole
JSON z `wmbusmeters`. Jednostki, `device_class` i `state_class`
wyprowadzane są z sufiksu nazwy pola i medium licznika.

Encje pojawią się w **Home Assistant → Ustawienia → Urządzenia i
usługi → MQTT → Urządzenia** jako `wmbus_<id>`.

### 7. SEARCH (zaawansowane)

SEARCH porównuje dekodowane odczyty z oczekiwaną wartością m³.
Sterowany opcjami `search_*`. `bridge.sh` zbiera kandydatów wodnych
do `search_candidates.tsv`, generuje tymczasowe pliki meter w trybie
SEARCH, porównuje wartości i zapisuje `search_status.json` oraz
`search_matches.tsv`. Aktualny widok `#/search` pokazuje tylko tabele
wyników; zidentyfikowany licznik dodaj z `#/discover`, a potem ustaw
`search_mode: false`, żeby wrócić do normalnej pracy. Ukryta trasa
`#/search` jest punktem wejścia dla zaawansowanych.

### 8. Diagnostyka

**Brak liczonych telegramów RAW**
- Sprawdź credentials, host i port MQTT.
- Sprawdź czy odbiornik publikuje na `raw_topic`.
- Sprawdź czy payload to HEX (nie JSON); `filter_hex_only` odrzuca
  resztę.
- Sprawdź `#/logs` i widok `Statystyki`.

**Nie widać urządzeń ESP**
- `raw_topic` musi mieć wildcard `+` do wykrycia ESP.
- Dopasowany segment to nazwa ESP w `#/esp-logs`.
- Topiki zdarzeń diagnostycznych `wmbus/+/diag` i `wmbus/+/diag/#` są
  opcjonalnymi logami. Dokładny topic `wmbus/+/diag/summary` jest
  opcjonalnym heartbeat; bez diagnostyki ESP są dalej wykrywane z RAW topicu.
- Retained `diag/boot` i inne zdarzenia diagnostyczne są tylko logami.
  Aktywność ESP jest wykrywana z `wmbus/+/telegram`; urządzenie widziane na
  tym topiku liczy się w bieżącej sesji bridge. `wmbus/+/diag/summary` jest
  opcjonalnym świeżym heartbeat.

**Skonfigurowany licznik nie dekoduje**
- Sprawdź `meter_id` (musi być 8 znaków hex).
- Spróbuj `type: auto`; jeśli nie działa, wybierz konkretny driver.
- Sprawdź klucz AES jeśli licznik jest szyfrowany.
- Poczekaj na następny telegram — interwały kontroluje licznik.

**Restart pipeline**
- Przycisk `Restart add-on` używa Supervisor API. W Dockerze bez
  `SUPERVISOR_TOKEN` nie restartuje kontenera; użyj `docker restart`.
- Dodanie licznika wywołuje `/api/reload-pipeline` automatycznie.
  Usunięcie licznika w aktualnym frontendzie tego endpointu nie wywołuje,
  więc stara konfiguracja dekodowania może działać do reloadu lub restartu.

---

## Deutsch

### 1. Voraussetzungen

- Erreichbarer MQTT-Broker.
- Empfänger, der Wireless-M-Bus-RAW-HEX-Telegramme über MQTT
  veröffentlicht (typischerweise ESP32 mit CC1101 / SX1276 / SX1262).
- Bei AES-verschlüsselten Zählern: 32-stelliger HEX-Schlüssel.

Bridge liest nur den MQTT-Payload. Mit `filter_hex_only: true`
(Standard) werden Leerzeichen entfernt, ein optionales `0x` entfernt,
Nicht-HEX und HEX mit ungerader Länge verworfen.

### 2. Start unter Home Assistant

1. Add-on-Optionen konfigurieren — Standardwerte reichen meist aus.
2. MQTT: `mqtt_mode` auf `auto`, `ha` oder `external` setzen.
3. `raw_topic: wmbus/+/telegram` beibehalten, sofern der Publisher
   kein anderes Topic nutzt. Das `+`-Segment dient zugleich als
   ESP-Gerätename in der Pipeline.
4. Add-on starten. Zwei Dienste laufen: Bridge und WebGUI. WebGUI
   intern auf Port `8099`, Zugriff über Ingress.

### 3. Start unter Docker

```bash
docker compose -f docker/examples/docker-compose.yml up -d --build
```

Beim ersten Start schreibt `docker/entrypoint.sh` ein
`/config/options.json`. Datei anpassen, dann
`docker compose ... restart wmbus`. `/config` muss beschreibbar sein.

### 4. Erste Telegramme (LISTEN → Discover → hinzufügen)

Mit `meters: []` läuft die Bridge im LISTEN-Modus und schreibt
gesehene IDs in `status_candidates.tsv`. In `#/discover`:

1. Auf Kandidaten-IDs warten.
2. Pro Zeile: Driver-Vermutung, Medium, Verschlüsselungs-Hinweis,
   letztes Telegramm, Empfangszähler, ggf. Vorschauwert.
3. Kandidaten **ohne AES** werden automatisch dekodiert. `bridge.sh`
   schreibt eine temporäre `meter-preview-<id>`-Datei und lädt die
   LISTEN-Instanz über `.reload_listen` neu. Der Wert erscheint mit dem
   nächsten dekodierten Telegramm; in der aktuellen Tabelle gibt es keinen
   manuellen Preview-Schalter.
4. Wert-Filter (numerische Eingabe mit `± Toleranz`) bei mehreren
   gleichartigen Kandidaten.
5. **Add meter** klicken. Die WebGUI ruft `/api/add-meter` und
   anschließend `/api/reload-pipeline` auf. Die DECODE-Pipeline
   startet neu ohne Container-Neustart.

### 5. Zählerkonfiguration

Minimaler Eintrag wie in der englischen Sektion. `id` ist stabil
und wird in `wmbusmeters`-Configs und HA-Entity-IDs verwendet;
spätere Änderung benennt Entitäten um. `meter_id` ist die
8-stellige Hex-ID. `key` ist leer oder genau 32 Hex-Zeichen.

### 6. Discovery und HA-Entitäten

Mit `discovery_enabled: true` veröffentlicht `bridge.sh`
HA-MQTT-Discovery unter `discovery_prefix` (Standard
`homeassistant`) — ein Sensor pro numerischem JSON-Feld. Einheit,
`device_class` und `state_class` werden vom Feldsuffix und
Zählermedium abgeleitet. Entitäten erscheinen in
**Einstellungen → Geräte & Dienste → MQTT** als `wmbus_<id>`.

### 7. SEARCH (erweitert)

Vergleicht dekodierte Messwerte mit einem erwarteten m³-Wert.
Steuerung über `search_*`. Nach erfolgreicher Identifikation
`search_mode: false` setzen.

### 8. Diagnose

- **Keine RAW-Telegramme**: MQTT-Verbindung, `raw_topic` und
  HEX-Payload prüfen; `#/logs` und Statistik-Ansicht ansehen.
- **Keine ESPs sichtbar**: `raw_topic` mit `+`-Wildcard verwenden.
  `diag/boot` und andere retained Diagnoseereignisse sind nur Logs.
  Aktivität wird aus `wmbus/+/telegram` erkannt; `wmbus/+/diag/summary`
  ist ein optionaler frischer Heartbeat.
- **Zähler dekodiert nicht**: `meter_id`, Driver-Wahl und
  AES-Schlüssel prüfen; auf nächste Übertragung warten.
- **Pipeline-Neustart**: `Restart add-on` nutzt die Supervisor-API; in
  Docker startet er ohne `SUPERVISOR_TOKEN` den Container nicht neu.
  Hinzufügen über die WebGUI ruft `/api/reload-pipeline` automatisch auf;
  Entfernen ruft diesen Endpoint im aktuellen Frontend nicht auf.

---

## Česky

### 1. Požadavky

- Dostupný MQTT broker.
- Přijímač publikující Wireless-M-Bus RAW HEX telegramy přes MQTT.
- Pro AES-šifrované měřiče: 32-znakový HEX klíč.

Bridge čte pouze payload MQTT. S `filter_hex_only: true` zahazuje
whitespace, prefix `0x`, non-HEX a HEX s lichou délkou.

### 2. Start v Home Assistantu

1. Nakonfigurujte volby — výchozí hodnoty obvykle stačí.
2. `mqtt_mode`: `auto`, `ha` nebo `external`.
3. Ponechte `raw_topic: wmbus/+/telegram`, pokud publisher
   nepoužívá jiné téma. Segment `+` slouží i jako jméno ESP.
4. Spusťte add-on. Bridge a WebGUI běží jako dvě služby. WebGUI
   na portu `8099` přes Ingress.

### 3. Start v Dockeru

Stejně jako v anglické sekci. `/config` musí být zapisovatelný.

### 4. První telegramy (LISTEN → Discover → přidat)

Začněte s `meters: []` v režimu LISTEN. V `#/discover`:

1. Vyčkejte na ID kandidátů.
2. Každý řádek: odhad driveru, médium, hint o šifrování, poslední
   telegram, počítadla příjmu, příp. preview hodnota.
3. Kandidáti **bez AES** se dekódují automaticky. `bridge.sh` zapíše
   `meter-preview-<id>` a obnoví LISTEN přes `.reload_listen`. Hodnota se
   objeví s dalším dekódovaným telegramem; aktuální tabulka nemá ruční
   přepínač náhledu.
4. Filtr podle hodnoty s `± tolerance`.
5. **Add meter** zavolá `/api/add-meter` a `/api/reload-pipeline`.
   DECODE pipeline se restartuje bez restartu kontejneru.

### 5. Konfigurace měřiče

Minimální záznam jako v anglické sekci. `id` je stabilní a používá
se v `wmbusmeters` souborech i ID entit HA. `meter_id` je 8 hex.
`key` je prázdný nebo přesně 32 hex.

### 6. Discovery a entity HA

S `discovery_enabled: true` `bridge.sh` publikuje HA MQTT Discovery
pod `discovery_prefix`. Jednotky a třídy se odvozují z přípony pole
a média měřiče. Entity v **Nastavení → Zařízení a služby → MQTT**
jako `wmbus_<id>`.

### 7. SEARCH (pokročilé)

Porovnává dekódované hodnoty s očekávaným m³. Po nalezení nastavte
`search_mode: false`.

### 8. Diagnostika

- **Žádné RAW**: zkontrolovat MQTT, `raw_topic`, formát payloadu.
- **ESP nejsou vidět**: `raw_topic` musí mít wildcard `+`. `diag/boot`
  a jiné retained diagnostické události jsou jen logy. Aktivita se detekuje
  z `wmbus/+/telegram`; `wmbus/+/diag/summary` je volitelný čerstvý
  heartbeat.
- **Měřič nedekoduje**: zkontrolovat `meter_id`, driver, AES klíč.
- **Restart pipeline**: `Restart add-on` používá Supervisor API; v Dockeru
  bez `SUPERVISOR_TOKEN` kontejner nerestartuje. Přidání v WebGUI volá
  `/api/reload-pipeline` automaticky; odebrání ho v aktuálním frontendu
  nevolá.

---

## Slovenčina

### 1. Požiadavky

- Dostupný MQTT broker.
- Prijímač publikujúci Wireless-M-Bus RAW HEX telegramy cez MQTT.
- Pre AES-šifrované merače: 32-znakový HEX kľúč.

Bridge číta iba payload MQTT. S `filter_hex_only: true` zahadzuje
whitespace, prefix `0x`, non-HEX a HEX s nepárnou dĺžkou.

### 2. Štart v Home Assistante

1. Nakonfigurujte voľby — predvolené hodnoty zvyčajne stačia.
2. `mqtt_mode`: `auto`, `ha` alebo `external`.
3. Ponechajte `raw_topic: wmbus/+/telegram`, pokiaľ publisher
   nepoužíva inú tému. Segment `+` slúži aj ako meno ESP.
4. Spustite add-on. Bridge a WebGUI bežia ako dve služby. WebGUI
   na porte `8099` cez Ingress.

### 3. Štart v Dockeri

Rovnako ako v anglickej sekcii. `/config` musí byť zapisovateľný.

### 4. Prvé telegramy (LISTEN → Discover → pridať)

Začnite s `meters: []` v režime LISTEN. V `#/discover`:

1. Počkajte na ID kandidátov.
2. Každý riadok: odhad driveru, médium, hint o šifrovaní, posledný
   telegram, počítadlá príjmu, príp. preview hodnota.
3. Kandidáti **bez AES** sa dekódujú automaticky. `bridge.sh` zapíše
   `meter-preview-<id>` a obnoví LISTEN cez `.reload_listen`. Hodnota sa
   objaví s ďalším dekódovaným telegramom; aktuálna tabuľka nemá ručný
   prepínač náhľadu.
4. Filter podľa hodnoty s `± tolerancia`.
5. **Add meter** zavolá `/api/add-meter` a `/api/reload-pipeline`.
   DECODE pipeline sa reštartuje bez reštartu kontajnera.

### 5. Konfigurácia merača

Minimálny záznam ako v anglickej sekcii. `id` je stabilný a používa
sa v `wmbusmeters` súboroch i ID entít HA. `meter_id` je 8 hex.
`key` je prázdny alebo presne 32 hex.

### 6. Discovery a entity HA

S `discovery_enabled: true` `bridge.sh` publikuje HA MQTT Discovery
pod `discovery_prefix`. Jednotky a triedy sa odvodzujú z prípony
poľa a média merača. Entity v **Nastavenia → Zariadenia a služby →
MQTT** ako `wmbus_<id>`.

### 7. SEARCH (pokročilé)

Porovnáva dekódované hodnoty s očakávaným m³. Po nájdení nastavte
`search_mode: false`.

### 8. Diagnostika

- **Žiadne RAW**: skontrolovať MQTT, `raw_topic`, formát payloadu.
- **ESP nie sú vidieť**: `raw_topic` musí mať wildcard `+`. `diag/boot`
  a iné retained diagnostické udalosti sú iba logy. Aktivita sa deteguje
  z `wmbus/+/telegram`; `wmbus/+/diag/summary` je voliteľný čerstvý
  heartbeat.
- **Merač nedekóduje**: skontrolovať `meter_id`, driver, AES kľúč.
- **Reštart pipeline**: `Restart add-on` používa Supervisor API; v Dockeri
  bez `SUPERVISOR_TOKEN` kontajner nereštartuje. Pridanie v WebGUI volá
  `/api/reload-pipeline` automaticky; odobratie ho v aktuálnom frontende
  nevolá.

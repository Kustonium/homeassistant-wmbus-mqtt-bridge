# Home Assistant Add-on: wMBus MQTT Bridge

**Dokumentacja do wersji / Documentation for version:** 1.5.38.

**Szybka nawigacja / Quick navigation:**
[🇵🇱 PL (poniżej)](#-opis-pl) · [🇬🇧 EN (below)](#-description-en)

**Pełna dokumentacja / Full documentation:**
[🇵🇱 PL](docs/README.pl.md) · [🇬🇧 EN](docs/README.en.md) · [🇩🇪 DE](docs/README.de.md) · [🇨🇿 CS](docs/README.cs.md) · [🇸🇰 SK](docs/README.sk.md)

**Architektura / internals (maintainers):** [ARCHITECTURE.md](docs/ARCHITECTURE.md)

> ⚠️ Tłumaczenia maszynowe — mogą zawierać błędy w dowolnym języku, w tym PL i EN. / Machine-generated translations — may contain errors in any language, including PL and EN.

---

## 🇵🇱 Opis (PL)

Ten dodatek Home Assistant jest rozszerzeniem oraz forkiem oficjalnego projektu **wmbusmeters-ha-addon**, który bazuje na narzędziu **wmbusmeters**.

Celem projektu jest dekodowanie telegramów Wireless M-Bus (C1 / T1 / S1) w Home Assistant **bez użycia lokalnego dongla radiowego** (USB/RTL-SDR). Zamiast tego wykorzystuje **zewnętrzne odbiorniki** (np. ESP32/gateway/bridge) i **MQTT jako kanał wejściowy**.

Add-on konsumuje surowe ramki wMBus w formacie HEX z MQTT i jest typowo używany razem z firmware [`esphome-wmbus-bridge-rawonly`](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly) działającym na ESP32 z układem radiowym **CC1101, SX1276 lub SX1262**. Oba projekty tworzą pipeline (ESP odbiera radio → MQTT raw hex → ten add-on dekoduje → HA), ale są **niezależne**: add-on przyjmuje hex z dowolnego źródła publikującego na skonfigurowany `raw_topic`.

> 🌉 **Całościowo: ESP (odbiornik radiowy) + ten add-on (dekoder) tworzą rozproszony _gateway wM-Bus → Home Assistant_.** Radio stoi tam, gdzie jest zasięg, a dekodowanie (deszyfracja, drivery, ~120 typów liczników) działa na HA. W odróżnieniu od **monolitycznych bramek wM-Bus** (radio + dekoder w jednym pudełku) ta architektura nie wymaga lokalnego dongla USB i skaluje się przez dostawianie tanich węzłów ESP. Każdą połowę można też używać samodzielnie: ESP karmi dowolny backend MQTT, a add-on dekoduje hex z dowolnego źródła (rtl-wmbus, inny gateway, narzędzie replay) — współpracują, ale żadna nie zależy od drugiej.

> 🧱 **Granica odpowiedzialności:** projekt dostarcza dwóch klientów MQTT (ESP i add-on); jego zakres kończy się na temacie MQTT. Sam broker — uwierzytelnianie, ACL, TLS, ekspozycja i mostek broker-broker dla instalacji rozproszonych (A → internet → B) — należy do operatora. Trzymaj broker w LAN; do dostępu zdalnego użyj tunelu/VPN lub mostka brokera z TLS. ⚠️ Początkujący: **nie** przekierowuj portu brokera (1883) ani HA do internetu na routerze — do dostępu z zewnątrz użyj gotowca: **Nabu Casa**, **Tailscale** lub **Cloudflare Tunnel**. Niepewny? Zostaw wszystko w LAN.

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
- **Encje diagnostyczne statusu** — gdy licznik raportuje pole `status`, powstaje sensor z tekstem statusu oraz `binary_sensor` (`device_class: problem`) włączający się przy każdym stanie innym niż `OK` (np. `elf2` daje pełne flagi błędów, `elf` tylko status TPL).
- **Tryb LISTEN (nasłuch)** — gdy lista `meters` jest pusta, add-on wypisuje w logach wszystkie słyszane liczniki wraz z sugerowanym driverem.
- **Tryb SEARCH** — gdy nasłuch słyszy wiele cudzych liczników, dopasowuje właściwy po odczycie m³ z fizycznego licznika.
- **Interaktywny panel WebUI** — zarządzanie przez przeglądarkę (panel boczny w HA / port `8099` w Dockerze): lista wykrytych kandydatów, dodawanie licznika przez modal, podgląd na żywo wartości słuchanych liczników bez dodawania ich na stałe, tryb SEARCH, logi ESP. Interfejs w 5 językach: 🇬🇧 EN · 🇵🇱 PL · 🇩🇪 DE · 🇨🇿 CS · 🇸🇰 SK.

### Wymagania (WAŻNE)

Add-on domyślnie korzysta z wewnętrznego brokera MQTT Home Assistant (Mosquitto add-on), ale może pracować z brokerem zewnętrznym.

**Tryby brokera (`mqtt_mode`):**
- `auto` (domyślnie) — kolejność wykrywania: **1)** `external_mqtt_host`, jeśli wpisany (wygrywa nawet, gdy broker HA też działa); **2)** broker HA z usługi Supervisora (Mosquitto add-on); **3)** sonda znanych brokerów-add-onów (`core-mosquitto`, EMQX `a0d7b954-emqx`) — z danymi `external_mqtt_username/password`, jeśli podane, inaczej anonimowo. Gdy sonda wykryje broker odrzucający logowanie, log mówi wprost, których pól brakuje.
- `ha` — wymusza broker HA (Mosquitto add-on)
- `external` — zawsze używa ustawień zewnętrznych (`external_mqtt_host`, itd.)

### ⚙️ Uwaga o AI, dokumentacji i tłumaczeniach

Projekt jest **rozwijany z użyciem AI**. Rolą człowieka (**Kustonium**) jest testowanie, walidacja i decyzje architektoniczne (human-in-the-loop) — nie pisanie kodu znak po znaku.

Wszystkie pliki tekstowe widoczne dla użytkownika — README, dokumentacja w `docs/`, tłumaczenia interfejsu WebUI w [`rootfs/usr/bin/i18n.py`](rootfs/usr/bin/i18n.py), CHANGELOG, komunikaty — są generowane maszynowo. Mogą zawierać błędy lub nienaturalne sformułowania w **dowolnym języku, włącznie z polskim i angielskim**, nie tylko w niemieckim, czeskim czy słowackim.

---

### Interfejs WebUI (panel zarządzania)

Add-on udostępnia interaktywny panel WWW (w Home Assistant jako panel boczny lub przycisk **OPEN WEB UI**, w Dockerze pod portem `8099`). To podstawowy sposób obsługi — wykrywanie i dodawanie liczników nie wymaga ręcznej edycji plików.

Widoki:

- **Panel** — stan pipeline'u (MQTT, telegramy RAW, dekoder, HA Discovery), statystyki odbioru (w tym tempo telegramy/min na żywo) oraz wykryte płytki ESP.
- **Liczniki** — skonfigurowane liczniki z bieżącą wartością i statystykami odbioru (15m / 60m).
- **Odbierane / Szukaj** — kandydaci z trybu LISTEN (ID, driver, medium, szyfrowanie, odbiór). Każdy bez wymaganego klucza AES ma przycisk **Dodaj licznik** i jest **dekodowany automatycznie** przez równoległą instancję LISTEN — bieżąca wartość pojawia się w kolumnie **Wartość** po następnym zdekodowanym telegramie, bez dodawania licznika i bez klikania podglądu. Kandydaci wymagający AES nie pokazują wartości, dopóki nie podasz klucza. Stąd uruchamia się również tryb SEARCH.
- **Logi** — skrócony strumień zdarzeń runtime (pełne logi w zakładce **Log** dodatku HA).
- **Logi ESP** — diagnostyka z odbiorników ESP (zdarzenia, RSSI, boot, sugestie) oraz wykrycie wielu płytek na podstawie napływających telegramów `wmbus/+/telegram`.
- **Ustawienia** — aktywna konfiguracja runtime i snapshot `options.json`; globalny restart dodatku jest w górnym pasku WebUI. Wszystkie opcje add-onu można tu **edytować** (te same co w zakładce Konfiguracja HA), z opisem „po co są" przy każdej; opcje rdzenne wchodzą w życie po restarcie.
- **O projekcie** — krótki opis architektury.

**Porównanie driverów:** w modalu **Dodaj licznik** lub **Driver…** wybierz driver z listy, wpisz klucz AES jeśli licznik jest szyfrowany i kliknij **Porównaj**. Lewa kolumna pokazuje driver zapisany albo auto-detekcję `wmbusmeters`, prawa kolumna pokazuje driver wybrany w polu **Sterownik**. Zielone wiersze to pola dostępne tylko dla wybranego drivera, żółte to różne wartości; więcej pól nie gwarantuje poprawnego drivera — porównaj wartości z wyświetlaczem licznika.

Interfejs jest dostępny w 5 językach (🇬🇧 EN · 🇵🇱 PL · 🇩🇪 DE · 🇨🇿 CS · 🇸🇰 SK) — przełącznik w prawym górnym rogu. Pełny opis widoków: [dokumentacja PL](docs/README.pl.md) · [EN §5](docs/README.en.md#5-the-webui--what-you-see).

---

### Konfiguracja w Home Assistant (GUI)

Konfiguracja odbywa się przez interfejs graficzny dodatku — nie trzeba edytować plików ręcznie. Najprościej: znajdź licznik w widoku **Odbierane / Szukaj** i kliknij **Dodaj licznik**. Poniższe kroki opisują też ścieżkę z odczytem z logów.

#### Krok 1 — Wykrycie liczników

**Zalecane (WebUI):** zostaw sekcję **meters** pustą, uruchom addon i otwórz panel WebUI → widok **Odbierane / Szukaj**. Wykryte liczniki pojawią się na liście z wartością podglądu (dla liczników bez AES) i przyciskiem **Dodaj licznik**.

**Alternatywnie (logi):** te same liczniki widać w logach addonu:

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

#### Opcjonalnie — tryb SEARCH (dopasowanie po stanie licznika)

Tryb `search_mode` pomaga znaleźć właściwy licznik w budynku, gdy w trybie LISTEN pojawia się dużo obcych urządzeń.

Działa dwuetapowo:

1. Przy pustej liście `meters` add-on zbiera kandydatów z logów LISTEN i zapisuje ich w:
   `/data/search_candidates.tsv`
2. Po restarcie add-on tworzy tymczasowe liczniki `search_<meter_id>`, dekoduje ich JSON-y i porównuje wartości `total_m3` z podanym odczytem.
3. Gdy znajdzie pasujący licznik, wypisuje tylko czytelny wynik `SEARCH MATCH` oraz gotową konfigurację `SEARCH SUGGESTED CONFIG`.

Przykład wyniku:

```text
[wmbus-bridge][WARN] SEARCH MATCH: id=03534159 driver=hydrodigit media=water field=total_m3 value=23.932 m3 expected=23.93 diff=0.002000 m3
[wmbus-bridge][WARN] SEARCH SUGGESTED CONFIG: {"id":"meter_03534159","meter_id":"03534159","type":"hydrodigit","type_other":"","key":""}
```

Zalecana konfiguracja:

| Pole | Zalecenie |
|------|-----------|
| `search_mode` | `true` tylko na czas szukania licznika |
| `search_expected_value_m3` | aktualny odczyt z fizycznego licznika, np. `23.93` albo `23,93` |
| `search_tolerance_m3` | zwykle `0.05` (50 litrów); nie używaj szerokiej tolerancji typu `0.5` w bloku |
| `search_topic` | opcjonalny temat MQTT dla wyników, domyślnie `wmbus/search/candidates` |

Ważne zasady:

- SEARCH służy tylko do identyfikacji licznika — po znalezieniu ID wyłącz `search_mode`.
- Tymczasowe liczniki `search_*` nie powinny tworzyć encji Home Assistant.
- Po znalezieniu licznika skopiuj `SEARCH SUGGESTED CONFIG` do sekcji `meters`.
- Po zakończeniu szukania usuń `/data/search_candidates.tsv`, jeśli chcesz zacząć kolejne wyszukiwanie od czystej listy.
- Dla wodomierzy w bloku ustawiaj wąską tolerancję, np. `0.05`, bo wiele cudzych liczników może mieć podobny stan.

---

### Aktualne / okresowe zużycie z `total_m3`

Część wodomierzy (driver **apator162, hydrodigit, dme_07, itron, lse_07_17, qwater, qwaterv2, unismart**) wystawia **tylko `total_m3`** — narastający stan licznika, bez pola chwilowego przepływu (telegram po prostu go nie zawiera). To **nie jest błąd** — „aktualne zużycie" uzyskujesz z `total_m3` natywnie w Home Assistant:

- **Utility Meter** (Ustawienia → Urządzenia i usługi → Pomocnicy → *Licznik zużycia*): wskaż encję `sensor.<id>_total_m3` i ustaw cykl (dobowy/miesięczny) → HA liczy zużycie w okresie. Stan **przeżywa restarty i aktualizacje** addonu.
- **Derivative** (pomocnik *Pochodna*): chwilowy przepływ (np. m³/h) z przyrostu `total_m3` — rozdzielczość ograniczona interwałem telegramów licznika.

`total_m3` jest publikowane z `device_class: water` i `state_class: total_increasing`, więc wchodzi też do statystyk wody / panelu Energii HA.

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
| `key` | Klucz szyfrowania w formacie HEX; zostaw puste, jeśli licznik nie szyfruje |

> ℹ️ Pełna lista opcji (m.in. `discovery_prefix`, `discovery_retain`, `state_retain`, `debug_every_n`, `search_delta_mode`, `search_min_delta_m3`) znajduje się w `config.yaml` oraz w pełnej dokumentacji: [docs/README.pl.md](docs/README.pl.md).

Przykład `options.json`:

```json
{
  "raw_topic": "wmbus/+/telegram",
  "loglevel": "normal",
  "filter_hex_only": true,
  "discovery_enabled": true,
  "state_prefix": "wmbusmeters",
  "search_mode": false,
  "search_expected_value_m3": "0",
  "search_tolerance_m3": "0.05",
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
      "key": ""
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
- Domyślny `raw_topic` to `wmbus/+/telegram` w obu trybach (HA `config.yaml` i pierwszy `/config/options.json` generowany przez `docker/entrypoint.sh`) — zgodny z firmware publikującym na `wmbus/<urządzenie>/telegram`. Plik `options.json` wygenerowany przez starszą wersję mógł dostać `wmbus_bridge/+/telegram` — wtedy popraw ręcznie i zrestartuj kontener.
- Przycisk **Restart** w WebUI działa też w Dockerze: kontener dostaje SIGTERM i kończy pracę, a z powrotem podnosi go **polityka restartu** (przykładowy compose ma `restart: unless-stopped`). Jeśli uruchamiasz kontener bez polityki restartu, przycisk zadziała jak „stop" — wtedy wystartuj go ręcznie (`docker start <kontener>`).

#### Ręczny test MQTT

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbus/any/telegram' -m '<HEX_TELEGRAM>'
mosquitto_sub -h localhost -p 1883 -t 'wmbusmeters/#' -v
```

---

### Przeznaczenie

Ten add-on jest szczególnie przydatny gdy:
- odbiór radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),
- chcesz używać wmbusmeters bez dongla USB,
- masz własny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

⚠️ **Nie instaluj oficjalnego add-onu wmbusmeters równolegle.** Ten add-on zawiera własną instancję wmbusmeters i zastępuje go w tym scenariuszu.

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

This add-on consumes raw wMBus hex frames from MQTT and is typically paired with the companion firmware [`esphome-wmbus-bridge-rawonly`](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly) running on an ESP32 with a **CC1101, SX1276 or SX1262** radio. The two projects work as a pipeline (ESP receives radio → MQTT raw hex → this add-on parses → HA), but each is **independent**: this add-on accepts hex from any source publishing to the configured `raw_topic`.

> 🌉 **As a whole: the ESP (RF receiver) + this add-on (decoder) form a distributed _wM-Bus → Home Assistant gateway_.** The radio sits where the signal is, while decoding (decryption, drivers, ~120 meter types) runs on HA. Unlike **monolithic wM-Bus gateways** (radio + decoder in one box), this architecture needs no local USB dongle and scales by adding cheap ESP nodes. Each half also works standalone: the ESP feeds any MQTT backend, and the add-on decodes hex from any source (rtl-wmbus, another gateway, the replay tool) — they cooperate, but neither depends on the other.

> 🧱 **Responsibility boundary:** the project ships two MQTT clients (ESP + add-on); its scope ends at the MQTT topic. The broker itself — authentication, ACLs, TLS, exposure and broker-to-broker bridging for distributed setups (A → internet → B) — is the operator's. Keep the broker on your LAN; for remote access use a tunnel/VPN or TLS broker bridging. ⚠️ Beginners: do **not** forward the broker port (1883) or HA to the internet on your router — for outside access use a ready-made option: **Nabu Casa**, **Tailscale** or **Cloudflare Tunnel**. Unsure? Keep everything on the LAN.

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
- Status diagnostic entities: when a meter reports a `status` field, a text sensor plus a `binary_sensor` (`device_class: problem`) that turns on for any non-`OK` state (e.g. `elf2` exposes the full error flags, `elf` only the TPL status)
- LISTEN mode: when `meters` list is empty, logs all detected meter IDs and suggested drivers
- SEARCH mode: matches the right meter by its m³ reading when LISTEN hears many neighbours' meters
- Interactive WebUI: browser management panel (HA side panel / port `8099` in Docker) — detected candidates, modal-based meter add, live preview of listened meters' values without adding them permanently, SEARCH mode, ESP logs. Available in 5 languages: 🇬🇧 EN · 🇵🇱 PL · 🇩🇪 DE · 🇨🇿 CS · 🇸🇰 SK.

### Broker modes (`mqtt_mode`)

- `auto` (default) — detection order: **1)** `external_mqtt_host` when set (wins even if the HA broker is also up); **2)** the HA broker from the Supervisor service (Mosquitto add-on); **3)** a probe of well-known broker add-ons (`core-mosquitto`, EMQX `a0d7b954-emqx`) — using `external_mqtt_username/password` when provided, anonymously otherwise. When the probe finds a broker that rejects the login, the log states exactly which fields are missing.
- `ha` — force HA broker (Mosquitto add-on)
- `external` — always use external settings (`external_mqtt_host`, etc.)

### ⚙️ Notice on AI, documentation and translations

This project is **AI-developed**. The human role (**Kustonium**) is testing, validation and architectural decisions (human-in-the-loop) — not writing code character by character.

All user-facing text files — READMEs, the documentation under `docs/`, the WebUI translations in [`rootfs/usr/bin/i18n.py`](rootfs/usr/bin/i18n.py), the CHANGELOG, log messages — are machine-generated. They may contain errors or unnatural phrasing in **any language, including Polish and English**, not only in German, Czech or Slovak.

---

### WebUI (management panel)

The add-on ships an interactive web panel (a side panel or the **OPEN WEB UI** button in Home Assistant, port `8099` in Docker). It is the primary way to use the add-on — discovering and adding meters needs no manual file editing.

Views:

- **Dashboard** — pipeline status (MQTT, RAW telegrams, decoder, HA Discovery), reception statistics (including a live telegrams-per-minute rate) and detected ESP boards.
- **Meters** — configured meters with their current value and reception stats (15m / 60m).
- **Received / Search** — LISTEN-mode candidates (ID, driver, media, encryption, reception). Each one without a required AES key has an **Add meter** button and is **decoded automatically** by the parallel LISTEN instance — its current value appears in the **Value** column after the next decoded telegram, with no meter added and no preview click. AES-required candidates show no value until you provide a key. SEARCH mode is also started here.
- **Logs** — a short runtime event stream (full logs are in the add-on **Log** tab).
- **ESP Logs** — diagnostics from ESP receivers (events, RSSI, boot, suggestions) and multi-board detection based on incoming `wmbus/+/telegram` telegrams.
- **Settings** — active runtime configuration and `options.json` snapshot; the global add-on restart button is in the WebUI top bar. All add-on options can be **edited** here (the same options as the HA Configuration tab), each with an explanation of what it does; core options take effect after a restart.
- **About** — a short architecture description.

**Driver comparison:** in the **Add meter** or **Driver…** modal, choose a driver, enter the AES key if the meter is encrypted, then click **Compare**. The left column shows the saved driver or `wmbusmeters` auto-detection; the right column shows the driver selected in the **Driver** field. Green rows are fields available only with the selected driver, amber rows are different values; more fields do not prove the driver is correct — compare the values with the meter display.

The interface is available in 5 languages (🇬🇧 EN · 🇵🇱 PL · 🇩🇪 DE · 🇨🇿 CS · 🇸🇰 SK) — switcher in the top-right corner. Full description of the views: [docs EN §5](docs/README.en.md#5-the-webui--what-you-see).

---

### Configuration in Home Assistant (GUI)

Configuration is done through the add-on GUI — no manual file editing required. The easiest path: find the meter in the **Received / Search** view and click **Add meter**. The steps below also describe the log-based path.

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

#### Optional — SEARCH mode (matching by meter reading)

`search_mode` helps identify the correct meter in buildings where LISTEN mode sees many nearby devices.

It works in two stages:

1. With an empty `meters` list, the add-on collects LISTEN candidates and stores them in:
   `/data/search_candidates.tsv`
2. After restart, the add-on creates temporary `search_<meter_id>` meters, decodes their JSON output and compares `total_m3` with the expected physical reading.
3. When a match is found, it prints a readable `SEARCH MATCH` line and a ready-to-copy `SEARCH SUGGESTED CONFIG`.

Example output:

```text
[wmbus-bridge][WARN] SEARCH MATCH: id=03534159 driver=hydrodigit media=water field=total_m3 value=23.932 m3 expected=23.93 diff=0.002000 m3
[wmbus-bridge][WARN] SEARCH SUGGESTED CONFIG: {"id":"meter_03534159","meter_id":"03534159","type":"hydrodigit","type_other":"","key":""}
```

Recommended settings:

| Field | Recommendation |
|-------|----------------|
| `search_mode` | `true` only while identifying a meter |
| `search_expected_value_m3` | current physical meter reading, for example `23.93` or `23,93` |
| `search_tolerance_m3` | usually `0.05` (50 liters); avoid wide values such as `0.5` in apartment blocks |
| `search_topic` | optional MQTT topic for search results, default: `wmbus/search/candidates` |

Important rules:

- SEARCH is only for meter identification — disable `search_mode` after finding the ID.
- Temporary `search_*` meters should not create Home Assistant entities.
- Copy `SEARCH SUGGESTED CONFIG` into the `meters` section after finding the match.
- Remove `/data/search_candidates.tsv` after searching if you want the next search to start from a clean candidate list.
- Use a narrow tolerance for water meters in apartment blocks, for example `0.05`, because many nearby meters may have similar readings.

---

### Current / period consumption from `total_m3`

Some water meters (drivers **apator162, hydrodigit, dme_07, itron, lse_07_17, qwater, qwaterv2, unismart**) expose **only `total_m3`** — the cumulative meter reading, with no instantaneous flow field (the telegram simply doesn't carry one). This is **not a bug** — derive "current consumption" from `total_m3` natively in Home Assistant:

- **Utility Meter** (Settings → Devices & services → Helpers → *Utility meter*): point it at `sensor.<id>_total_m3` and pick a cycle (daily/monthly) → HA computes period consumption. Its state **survives add-on restarts and updates**.
- **Derivative** helper: instantaneous flow (e.g. m³/h) from the `total_m3` increase — resolution limited by the meter's telegram interval.

`total_m3` is published with `device_class: water` and `state_class: total_increasing`, so it also feeds HA water / Energy statistics.

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
| `key` | Encryption key in HEX; leave empty if the meter is not encrypted |

> ℹ️ The full option list (e.g. `discovery_prefix`, `discovery_retain`, `state_retain`, `debug_every_n`, `search_delta_mode`, `search_min_delta_m3`) is in `config.yaml` and the full documentation: [docs/README.en.md](docs/README.en.md).

Example `options.json`:

```json
{
  "raw_topic": "wmbus/+/telegram",
  "loglevel": "normal",
  "filter_hex_only": true,
  "discovery_enabled": true,
  "state_prefix": "wmbusmeters",
  "search_mode": false,
  "search_expected_value_m3": "0",
  "search_tolerance_m3": "0.05",
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
      "key": ""
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
- The default `raw_topic` is `wmbus/+/telegram` in both modes (HA `config.yaml` and the first `/config/options.json` generated by `docker/entrypoint.sh`) — matching firmware that publishes to `wmbus/<device>/telegram`. An `options.json` generated by an older version may carry `wmbus_bridge/+/telegram` — fix it manually and restart the container.
- The WebUI **Restart** button works in Docker too: the container receives SIGTERM and exits, and the **restart policy** brings it back (the example compose has `restart: unless-stopped`). If you run the container without a restart policy, the button acts as a "stop" — start it again manually (`docker start <container>`).

#### Manual MQTT test

```bash
mosquitto_pub -h localhost -p 1883 -t 'wmbus/any/telegram' -m '<HEX_TELEGRAM>'
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

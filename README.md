# Home Assistant Add-on: wMBus MQTT Bridge

[![Release][release-shield]][releases]
[![License][license-shield]][license]
![Supports aarch64 Architecture][aarch64-shield]
![Supports amd64 Architecture][amd64-shield]

[![Build][build-shield]][build]
[![Commit activity][commits-shield]][commits]

<!-- Badges read live data from the stable repository, which is the channel end
     users install. Nothing here is a hand-written claim about the project's
     state: in particular there is no shields.io "maintenance/yes/<year>" badge,
     because that one silently turns into a red "maintained: no!" the moment the
     hard-coded year rolls over. -->

[release-shield]: https://img.shields.io/github/v/release/Kustonium/homeassistant-wmbus-mqtt-bridge
[releases]: https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge/releases
[license-shield]: https://img.shields.io/github/license/Kustonium/homeassistant-wmbus-mqtt-bridge
[license]: https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge/blob/main/LICENSE
[aarch64-shield]: https://img.shields.io/badge/aarch64-yes-green.svg
[amd64-shield]: https://img.shields.io/badge/amd64-yes-green.svg
[build-shield]: https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge/actions/workflows/build.yaml/badge.svg
[build]: https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge/actions/workflows/build.yaml
[commits-shield]: https://img.shields.io/github/commit-activity/y/Kustonium/homeassistant-wmbus-mqtt-bridge
[commits]: https://github.com/Kustonium/homeassistant-wmbus-mqtt-bridge/commits/main


[![Add repository to my Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2FKustonium%2Fhomeassistant-wmbus-mqtt-bridge)
<a href="https://buymeacoffee.com/Kustonium"><img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="41"></a>


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

Od wersji **1.5.49** dodatek umie dodatkowo **odpytywać przewodową magistralę M-Bus** przez konwerter M-Bus master na porcie szeregowym (USB / RS-232 / RS-485) — jako trzecia instancja `wmbusmeters` obok DECODE i LISTEN. Ta ścieżka jest **opcjonalna, domyślnie wyłączona i nieprzetestowana na prawdziwej magistrali** (autor nie ma takiego sprzętu — protokół sprawdzono na symulatorze). Wyłączona nie uruchamia się i nie dotyka toru radiowego, który pozostaje głównym i to jego dotyczy wszystko poniżej. Szczegóły: [pełna dokumentacja](docs/README.pl.md).

Add-on konsumuje surowe ramki wMBus w formacie HEX z MQTT i jest typowo używany razem z firmware [`esphome-wmbus-bridge-rawonly`](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly) działającym na ESP32 z układem radiowym **CC1101, SX1276 lub SX1262**. Oba projekty tworzą pipeline (ESP odbiera radio → MQTT raw hex → ten add-on dekoduje → HA), ale są **niezależne**: add-on przyjmuje hex z dowolnego źródła publikującego na skonfigurowany `raw_topic`.

> 🌉 **Całościowo: ESP (odbiornik radiowy) + ten add-on (dekoder) tworzą rozproszony _gateway wM-Bus → Home Assistant_.** Radio stoi tam, gdzie jest zasięg, a dekodowanie (deszyfracja i zestaw driverów z przypiętego buildu `wmbusmeters`) działa na HA. W odróżnieniu od **monolitycznych bramek wM-Bus** (radio + dekoder w jednym pudełku) ta architektura nie wymaga lokalnego dongla USB i skaluje się przez dostawianie tanich węzłów ESP. Każdą połowę można też używać samodzielnie: ESP karmi dowolny backend MQTT, a add-on dekoduje hex z dowolnego źródła (rtl-wmbus, inny gateway, narzędzie replay) — współpracują, ale żadna nie zależy od drugiej.

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
Tor radiowy (główny):
ESP32 / Gateway / Bridge
→ MQTT (surowy telegram wM-Bus w formacie HEX)
→ wmbusmeters (stdin:hex)
→ MQTT (JSON)
→ Home Assistant (MQTT Discovery)

Tor przewodowy (opcjonalny, domyślnie wyłączony):
Licznik na magistrali M-Bus
→ konwerter M-Bus master na porcie szeregowym
→ wmbusmeters (odpytywanie, osobna instancja)
→ MQTT (JSON)
→ Home Assistant (MQTT Discovery)
```

Oba tory schodzą się w tym samym miejscu: warstwa encji nie pyta, skąd przyszedł zdekodowany telegram, więc jednostki, `device_class`, podział na pomiarowe/diagnostyczne oraz pola liczone i stałe działają tak samo.

### Kluczowe cechy

- **MQTT jako wejście danych** — surowe telegramy wM-Bus (HEX) odbierane z wybranego tematu MQTT.
- **Wejście STDIN dla wmbusmeters** — telegramy przekazywane przez `stdin:hex`, czego oryginalny add-on nie obsługuje.
- **Pełne dekodowanie przez wmbusmeters** — projekt nie zastępuje wmbusmeters, lecz wykorzystuje go w całości.
- **MQTT + Home Assistant Discovery** — dane publikowane w MQTT i automatycznie rejestrowane w HA.
- **Wybór publikowanych pól** — w modalu licznika (**Dodaj licznik** / **Driver…**) jest tabela wszystkich pól, jakie driver potrafi zwrócić, każde z opisem z `wmbusmeters` i checkboxem; obok pole na wzorce (`consumption_at_history_*`). Odznaczone pole nie dostaje encji — a jeśli encja już istniała, zostaje usunięta razem z historią.
- **Opis pola przy encji** — każda encja niesie atrybut `Description` z opisem napisanym przez autora drivera, obok pól zdekodowanego telegramu.
- **Encje diagnostyczne statusu** — gdy licznik raportuje pole `status`, powstaje sensor z tekstem przekazanym przez wybrany driver `wmbusmeters` oraz `binary_sensor` (`device_class: problem`) włączający się przy każdym stanie innym niż `OK`. Publikowane są **wszystkie** pola drivera: te z jednostką zużycia lub rozpoznaną `device_class` jako zwykłe sensory, cała reszta (liczby bez klasy, teksty, pola `null`) jako encje diagnostyczne wyłączone domyślnie — włączasz w HA tylko te, których potrzebujesz.
- **M-Bus przewodowy (opcjonalny, domyślnie wyłączony)** — dodatek potrafi sam odpytywać magistralę przez konwerter na porcie szeregowym: wybór portu bez skanowania (sondowanie mogłoby zagadać do koordynatora Zigbee), skan adresów pierwotnych z klasyfikacją odpowiedzi, konsola tylko do odczytu i panel stanu, który nazywa przyczynę ciszy zamiast zostawiać „nic nie przychodzi". **Niesprawdzone na prawdziwej magistrali** — protokół testowano na symulatorze.
- **Liczenie realnych odbiorów i eksport dowodów (opcja, domyślnie wyłączona)** — gdy firmware publikuje metadane odbioru na `wmbus/<płytka>/rx`, dodatek liczy rzeczywiste odbiory per licznik i per płytka zamiast procentów, które każda płytka wyliczała sama o sobie. Opcja `esp_rx_api_enabled` udostępnia dodatkowo `GET /api/esp-rx` i przycisk pobrania historii RX — bez surowych telegramów, kluczy AES i poświadczeń.
- **Blok walk-by Qundis (opcja, domyślnie wyłączona)** — liczniki Qundis pakują cały odczyt w jeden rekord producenta (`0DFF5F`), a od generacji 2026 szyfrują go wewnątrz tego rekordu — na warstwie wM-Bus ramka wygląda na nieszyfrowaną, więc nic nie sygnalizuje potrzeby klucza. Opcja `qds_walkby_enabled` odrzuca rekordy, których nie da się zweryfikować (bez niej dekoder raz na 256 telegramów publikuje szyfrogram jako odczyt, np. 15430,611 m³ na liczniku pokazującym 1,387), a przy skonfigurowanym kluczu AES licznika — tym samym, którego używają jego zwykłe ramki — odszyfrowuje blok i podaje dekoderowi czytelną treść.
- **Tryb LISTEN (nasłuch)** — gdy lista `meters` jest pusta, add-on wypisuje w logach wszystkie słyszane liczniki wraz z sugerowanym driverem.
- **Filtrowanie po wartości** — gdy nasłuch słyszy wiele cudzych liczników, WebUI filtruje już wyświetlone wartości według odczytu z fizycznego licznika i tolerancji.
- **Interaktywny panel WebUI** — zarządzanie przez przeglądarkę (panel boczny w HA / port `8099` w Dockerze): lista wykrytych kandydatów, dodawanie licznika przez modal, podgląd wartości bez trwałego dodawania, filtrowanie wartości, porównanie driverów i logi ESP. Interfejs w 5 językach: 🇬🇧 EN · 🇵🇱 PL · 🇩🇪 DE · 🇨🇿 CS · 🇸🇰 SK.

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

- **Panel** — stan potoków radiowego i — po pierwszej prawidłowej odpowiedzi — przewodowego M-Bus, statystyki odbioru oraz wykryte płytki ESP.
- **Liczniki** — skonfigurowane liczniki radiowe i przewodowe z bieżącą wartością oraz jawnym źródłem odczytu (`ESP` albo `M-Bus · <alias>`).
- **Odbierane / Szukaj** — kandydaci z trybu LISTEN (ID, driver, medium, szyfrowanie, odbiór). Kandydaci bez wymaganego klucza AES są dekodowani przez jednorazowe procesy podglądu, a bieżąca wartość pojawia się w kolumnie **Wartość** bez trwałego dodawania licznika. Kandydaci wymagający AES są pomijani do czasu podania klucza. Pasek **Filtruj po wartości** zawęża już wyświetlone dane bez uruchamiania dodatkowych driverów.
- **Logi** — skrócony strumień zdarzeń runtime (pełne logi w zakładce **Log** dodatku HA).
- **Logi ESP** — diagnostyka z odbiorników ESP (zdarzenia, RSSI, boot, sugestie) oraz wykrycie wielu płytek na podstawie napływających telegramów `wmbus/+/telegram`.
- **Ustawienia** — aktywna konfiguracja runtime i snapshot `options.json`; globalny restart dodatku jest w górnym pasku WebUI. Opcje skalarne ze schematu add-onu można tu **edytować**, a lista liczników jest zarządzana w widoku **Odbierane / Szukaj**; opcje rdzenne wchodzą w życie po restarcie.
- **M-Bus** — konfiguracja, stan, skan adresów i konsola opcjonalnej magistrali przewodowej.
- **O projekcie** — rzeczywiste potoki radiowy/przewodowy oraz nota o wsparciu AI; pełna nota jest również w [NOTICE.md](NOTICE.md).

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
| `id` | Twoja etykieta licznika używana w nazwach Discovery i generowanej konfiguracji | `woda_zimna_lazienka` |
| `meter_id` | 8-cyfrowy numer z trybu LISTEN | `41553221` |
| `type` | Driver z trybu LISTEN | `mkradio3` |
| `key` | Klucz szyfrowania (jeśli licznik szyfruje) | `00112233...` lub puste |

Jeśli licznik nie szyfruje telegramów, pole `key` pozostaw puste.

#### Filtrowanie wartości i starszy tryb SEARCH

Podstawowy sposób identyfikacji licznika to pasek **Filtruj po wartości** w widoku
**Odbierane / Szukaj**. Podaj stan z fizycznego wyświetlacza i tolerancję;
WebUI ukryje wiersze, których już wyświetlone wartości są poza zakresem. Filtr
nie uruchamia dodatkowego dekodowania, nie próbuje wszystkich driverów i nie
zmienia konfiguracji.

Starszy backend `search_mode` pozostaje dostępny w konfiguracji zaawansowanej,
ale jego widok jest ukryty w nawigacji. Działa dwuetapowo:

1. Przy pustej liście `meters` LISTEN zapisuje w `/data/search_candidates.tsv`
   wyłącznie jawnie nieszyfrowane wodomierze i jeden sugerowany driver.
2. Po kolejnym restarcie add-on tworzy tymczasowe liczniki `search_<meter_id>` i
   porównuje pola liczbowe zawierające w nazwie `m3` lub `total_volume` z podanym odczytem.
3. Przy zgodności wypisuje `SEARCH MATCH` oraz `SEARCH SUGGESTED CONFIG`.

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
- Tymczasowe liczniki `search_*` są wyłączone z Home Assistant Discovery.
- Po znalezieniu licznika skopiuj `SEARCH SUGGESTED CONFIG` do sekcji `meters`.
- Po zakończeniu szukania usuń `/data/search_candidates.tsv`, jeśli chcesz zacząć kolejne wyszukiwanie od czystej listy.
- Dla wodomierzy w bloku ustawiaj wąską tolerancję, np. `0.05`, bo wiele cudzych liczników może mieć podobny stan.

---

### Aktualne / okresowe zużycie z `total_m3`

Jeśli JSON dekodera zawiera **tylko `total_m3`** i nie zawiera pola chwilowego przepływu, bridge takiego pola nie tworzy. Aktualne lub okresowe zużycie uzyskasz z `total_m3` natywnie w Home Assistant:

- **Utility Meter** (Ustawienia → Urządzenia i usługi → Pomocnicy → *Licznik zużycia*): wskaż encję utworzoną dla pola `total_m3` i ustaw cykl (dobowy/miesięczny) → HA liczy zużycie w okresie. Stan **przeżywa restarty i aktualizacje** addonu.
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
docker compose pull
docker compose up -d
docker compose logs -f wmbus
```

Obraz `wmbus` jest wieloarchitekturowy (amd64 + aarch64) — `pull` sam ściąga
wariant pasujący do hosta, bez lokalnej kompilacji.

Jeśli widzisz `No meters configured -> LISTEN MODE` — kontener działa i czeka na telegramy.

#### Konfiguracja (Docker)

Główny plik: `./config/options.json` (wewnątrz kontenera: `/config/options.json`).

Pliki pod `./config/etc/` są **generowane automatycznie** przy każdym starcie — nie edytuj ich ręcznie, zostaną nadpisane.

**Pola wpisu licznika:**

| Pole | Opis |
|------|------|
| `id` | Twoja własna etykieta używana w nazwach Discovery i generowanej konfiguracji |
| `meter_id` | 8-cyfrowy numer seryjny licznika (z trybu LISTEN) |
| `type` | Driver wmbusmeters (z trybu LISTEN), lub `auto` |
| `type_other` | Niestandardowy driver — wypełnij tylko gdy `type` = `other` |
| `key` | Klucz szyfrowania w formacie HEX; zostaw puste, jeśli licznik nie szyfruje |
| `exclude_fields` | Wzorce pól, które mają NIE dostać encji w HA, oddzielone przecinkami lub spacjami (np. `consumption_at_history_*, history_*_date`). Puste = publikuj wszystko |

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
  "search_expected_value_m3": 0,
  "search_tolerance_m3": 0.05,
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

Since **1.5.49** the add-on can additionally **poll a wired M-Bus** through an M-Bus master converter on a serial port (USB / RS-232 / RS-485), as a third `wmbusmeters` instance next to DECODE and LISTEN. That path is **optional, off by default and not verified against a real bus** (the author has no such hardware — the protocol was tested against a simulator). Disabled, it does not start and does not touch the radio path, which remains the primary one and is what everything below describes. Details: [full documentation](docs/README.en.md).

This add-on consumes raw wMBus hex frames from MQTT and is typically paired with the companion firmware [`esphome-wmbus-bridge-rawonly`](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly) running on an ESP32 with a **CC1101, SX1276 or SX1262** radio. The two projects work as a pipeline (ESP receives radio → MQTT raw hex → this add-on parses → HA), but each is **independent**: this add-on accepts hex from any source publishing to the configured `raw_topic`.

> 🌉 **As a whole: the ESP (RF receiver) + this add-on (decoder) form a distributed _wM-Bus → Home Assistant gateway_.** The radio sits where the signal is, while decoding (decryption and the driver set from the pinned `wmbusmeters` build) runs on HA. Unlike **monolithic wM-Bus gateways** (radio + decoder in one box), this architecture needs no local USB dongle and scales by adding cheap ESP nodes. Each half also works standalone: the ESP feeds any MQTT backend, and the add-on decodes hex from any source (rtl-wmbus, another gateway, the replay tool) — they cooperate, but neither depends on the other.

> 🧱 **Responsibility boundary:** the project ships two MQTT clients (ESP + add-on); its scope ends at the MQTT topic. The broker itself — authentication, ACLs, TLS, exposure and broker-to-broker bridging for distributed setups (A → internet → B) — is the operator's. Keep the broker on your LAN; for remote access use a tunnel/VPN or TLS broker bridging. ⚠️ Beginners: do **not** forward the broker port (1883) or HA to the internet on your router — for outside access use a ready-made option: **Nabu Casa**, **Tailscale** or **Cloudflare Tunnel**. Unsure? Keep everything on the LAN.

### The problem it solves

The original **wmbusmeters-ha-addon** assumes local radio reception and does not accept external telegram sources or STDIN input. ESP32-based receivers, gateways and custom wM-Bus bridges cannot be used directly as data sources with the official add-on.

### Solution

This fork introduces an MQTT-based input path:

```
Radio path (primary):
ESP32 / Gateway / Bridge
→ MQTT (raw wM-Bus HEX telegram)
→ wmbusmeters (stdin:hex)
→ MQTT (JSON)
→ Home Assistant (MQTT Discovery)

Wired path (optional, off by default):
Meter on an M-Bus bus
→ M-Bus master converter on a serial port
→ wmbusmeters (polling, separate instance)
→ MQTT (JSON)
→ Home Assistant (MQTT Discovery)
```

Both paths meet at the same place: the entity layer never asks where a decoded telegram came from, so units, `device_class`, the measurement/diagnostic split and calculated/constant fields all behave identically.

### Key features

- MQTT input for raw wM-Bus telegrams
- STDIN support for wmbusmeters (`stdin:hex`)
- Full decoding handled by upstream wmbusmeters
- MQTT output with Home Assistant Discovery
- Field selection: the meter modal (**Add meter** / **Driver…**) lists every field the driver can report, each with the description from `wmbusmeters` and a checkbox, next to a box for patterns (`consumption_at_history_*`). An unchecked field gets no entity — and if one already existed, it is removed together with its history.
- Field descriptions on the entity: each entity carries a `Description` attribute written by the driver author, alongside the decoded telegram fields.
- Status diagnostic entities: when a meter reports a `status` field, a text sensor with the value supplied by the selected `wmbusmeters` driver plus a `binary_sensor` (`device_class: problem`) that turns on for any non-`OK` state. **Every** driver field is published: those with a consumption unit or a recognised `device_class` as plain sensors, everything else (unclassified numbers, text, `null` fields) as diagnostic entities disabled by default, so you enable only the ones you need
- Wired M-Bus (optional, off by default): the add-on can poll a bus itself through a converter on a serial port — port selection without scanning (probing could talk into a Zigbee coordinator), a primary-address scan that classifies each reply, a read-only console and a status panel that names the cause of silence instead of leaving you with "nothing arrives". **Not verified against a real bus** — the protocol was tested against a simulator.
- Real reception counting and evidence export (optional, off by default): when the firmware publishes receive metadata on `wmbus/<board>/rx`, the add-on counts actual receptions per meter and per board instead of percentages each board computed about itself. `esp_rx_api_enabled` additionally exposes `GET /api/esp-rx` and a download button for the RX history — with no RAW telegrams, AES keys or credentials.
- Qundis walk-by block (optional, off by default): Qundis meters pack the whole reading into one manufacturer record (`0DFF5F`) and, since the 2026 generation, encrypt it inside that record — at the wM-Bus layer the frame looks unencrypted, so nothing signals that a key is needed. `qds_walkby_enabled` rejects records that cannot be validated (without it the decoder publishes ciphertext as a reading once in 256 telegrams, e.g. 15430.611 m³ on a meter reading 1.387) and, when the meter's ordinary AES key is configured — the same one its regular frames use — decrypts the block and hands the decoder readable content.
- LISTEN mode: when `meters` list is empty, logs all detected meter IDs and suggested drivers
- Value filtering: when LISTEN hears many neighbours' meters, the WebUI filters already displayed values by the physical meter reading and tolerance
- Interactive WebUI: browser management panel (HA side panel / port `8099` in Docker) — detected candidates, modal-based meter add, value preview without permanent configuration, value filtering, driver comparison and ESP logs. Available in 5 languages: 🇬🇧 EN · 🇵🇱 PL · 🇩🇪 DE · 🇨🇿 CS · 🇸🇰 SK.

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

- **Dashboard** — the radio pipeline and, after its first valid reply, the wired M-Bus pipeline, reception statistics and detected ESP boards.
- **Meters** — configured radio and wired meters with their current value and an explicit source (`ESP` or `M-Bus · <alias>`).
- **Received / Search** — LISTEN-mode candidates (ID, driver, media, encryption, reception). Candidates without a required AES key are decoded by one-shot preview processes, and their current value appears in the **Value** column without permanent configuration. Candidates requiring AES are skipped until a key is provided. The **Filter by value** bar narrows already displayed data without running extra drivers.
- **Logs** — a short runtime event stream (full logs are in the add-on **Log** tab).
- **ESP Logs** — diagnostics from ESP receivers (events, RSSI, boot, suggestions) and multi-board detection based on incoming `wmbus/+/telegram` telegrams.
- **Settings** — active runtime configuration and `options.json` snapshot; the global add-on restart button is in the WebUI top bar. Scalar options from the add-on schema can be **edited** here, while meters are managed in **Received / Search**; core options take effect after a restart.
- **M-Bus** — configuration, status, address scan and console for the optional wired bus.
- **About** — the actual radio/wired pipelines and the AI-assistance notice; the full notice is also in [NOTICE.md](NOTICE.md).

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
| `id` | Your meter label used in Discovery names and generated configuration | `cold_water_bathroom` |
| `meter_id` | 8-digit number from LISTEN mode | `41553221` |
| `type` | Driver from LISTEN mode | `mkradio3` |
| `key` | Encryption key (if meter encrypts) | `00112233...` or leave empty |

If the meter does not encrypt telegrams, leave `key` empty.

#### Value filtering and the legacy SEARCH mode

The primary identification workflow is the **Filter by value** bar in
**Received / Search**. Enter the reading from the physical display and a
tolerance; the WebUI hides rows whose already displayed values are outside that
range. The filter performs no extra decoding, tries no additional drivers and
does not change configuration.

The legacy `search_mode` backend remains available in advanced configuration,
but its view is hidden from navigation. It works in two stages:

1. With an empty `meters` list, LISTEN stores only explicitly unencrypted water
   candidates and one suggested driver in `/data/search_candidates.tsv`.
2. On the following restart, the add-on creates temporary `search_<meter_id>`
   meters and compares numeric fields whose names contain `m3` or `total_volume`
   with the expected reading.
3. On a match it prints `SEARCH MATCH` and `SEARCH SUGGESTED CONFIG`.

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
- Temporary `search_*` meters are excluded from Home Assistant Discovery.
- Copy `SEARCH SUGGESTED CONFIG` into the `meters` section after finding the match.
- Remove `/data/search_candidates.tsv` after searching if you want the next search to start from a clean candidate list.
- Use a narrow tolerance for water meters in apartment blocks, for example `0.05`, because many nearby meters may have similar readings.

---

### Current / period consumption from `total_m3`

If the decoder JSON exposes **only `total_m3`** and no instantaneous-flow field,
the bridge does not synthesize one. Derive current or period consumption from
`total_m3` natively in Home Assistant:

- **Utility Meter** (Settings → Devices & services → Helpers → *Utility meter*): point it at the entity created for the `total_m3` field and pick a cycle (daily/monthly) → HA computes period consumption. Its state **survives add-on restarts and updates**.
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
docker compose pull
docker compose up -d
docker compose logs -f wmbus
```

The `wmbus` image is multi-arch (amd64 + aarch64) — `pull` fetches the variant
matching your host automatically, no local build toolchain needed.

If you see `No meters configured -> LISTEN MODE` — the container is running and waiting for telegrams.

#### Configuration (Docker)

Main file: `./config/options.json` (inside container: `/config/options.json`).

Files under `./config/etc/` are **auto-generated on startup** — do not edit them manually.

**Meter fields:**

| Field | Description |
|-------|-------------|
| `id` | Your label used in Discovery names and generated configuration |
| `meter_id` | 8-digit serial number (from LISTEN mode) |
| `type` | wmbusmeters driver (from LISTEN mode), or `auto` |
| `type_other` | Custom driver name — only when `type` is `other` |
| `key` | Encryption key in HEX; leave empty if the meter is not encrypted |
| `exclude_fields` | Patterns for fields that should get NO entity in HA, separated by commas or spaces (e.g. `consumption_at_history_*, history_*_date`). Empty publishes everything |

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
  "search_expected_value_m3": 0,
  "search_tolerance_m3": 0.05,
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

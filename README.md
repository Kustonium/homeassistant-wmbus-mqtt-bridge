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

⚠️ Ten add-on korzysta **wyłącznie** z wewnętrznego brokera MQTT dostarczanego przez Home Assistant (**Mosquitto add-on**).

- Wymagany jest **Mosquitto Broker** zainstalowany i uruchomiony jako add-on w Home Assistant.
- Zewnętrzne brokery MQTT (LXC / VM / Docker) nie są wspierane.
- Add-on wymaga **Home Assistant OS / Supervised** (Supervisor API).

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

⚠️ This add-on uses **only** the internal MQTT broker provided by Home Assistant (Mosquitto add-on).

- Mosquitto Broker add-on must be installed and running.
- External MQTT brokers are not supported.
- Requires Home Assistant OS / Supervised (Supervisor API).

⚠️ **Important note**  
Do not install the official **wmbusmeters** add-on in parallel. This add-on bundles its own wmbusmeters instance and replaces it for this use case.

### Upstream projects

- wmbusmeters — https://github.com/wmbusmeters/wmbusmeters (GPL-3.0)  
- wmbusmeters-ha-addon — https://github.com/wmbusmeters/wmbusmeters-ha-addon (GPL-3.0)

### License

Because this repository contains and modifies code derived from **wmbusmeters-ha-addon**, the entire project is distributed under:

**GNU General Public License v3.0 (GPL-3.0)**

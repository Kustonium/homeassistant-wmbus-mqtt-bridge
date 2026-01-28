Home Assistant Add-on: wMBus MQTT Bridge
🇵🇱 Opis (PL)

Ten dodatek Home Assistant jest rozszerzeniem oraz forkiem oficjalnego projektu
wmbusmeters-ha-addon, który sam w sobie bazuje na narzędziu wmbusmeters.

Celem projektu jest umożliwienie dekodowania telegramów Wireless M-Bus (C1 / T1 / S1) w Home Assistant bez użycia fizycznego dongla radiowego, poprzez wykorzystanie zewnętrznych odbiorników i MQTT jako kanału wejściowego.

Problem, który rozwiązuje ten add-on

Oryginalny add-on wmbusmeters-ha-addon:

zakłada, że odbiór radiowy odbywa się lokalnie (USB / serial / RTL-SDR),

nie przewiduje możliwości podania telegramów z zewnętrznego źródła,

nie obsługuje wejścia STDIN jako źródła danych.

W praktyce oznacza to, że:

ESP32, gatewaye, bridge’e radiowe czy własne odbiorniki wM-Bus
nie mogą być użyte bezpośrednio jako źródło danych dla wmbusmeters.

Rozwiązanie zastosowane w tym projekcie

Ten fork wprowadza alternatywną ścieżkę wejściową opartą o MQTT.

Add-on działa jako most (bridge) pomiędzy:

źródłem telegramów wM-Bus,

a silnikiem dekodującym wmbusmeters.

Architektura przepływu danych
ESP32 / Gateway / Bridge
→ MQTT (surowy telegram wM-Bus w formacie HEX)
→ wmbusmeters (stdin:hex)
→ MQTT (JSON)
→ Home Assistant (MQTT Discovery)

Kluczowe cechy

📡 MQTT jako wejście danych
Surowe telegramy wM-Bus (HEX) są odbierane z wybranego tematu MQTT.

🔌 Wejście STDIN dla wmbusmeters
Telegramy są przekazywane do wmbusmeters przez stdin:hex, czego oryginalny add-on nie obsługuje.

🧠 Pełne dekodowanie przez wmbusmeters
Projekt nie zastępuje wmbusmeters – wykorzystuje go w całości (dekodowanie, logika, formaty).

🏠 MQTT + Home Assistant Discovery
Dane są publikowane w MQTT oraz automatycznie rejestrowane w Home Assistant.

👂 Tryb LISTEN (nasłuch)
Gdy lista meters jest pusta:

add-on działa w trybie pasywnym,

w logach wypisywane są wykryte meter_id oraz sugerowany driver,

ułatwia to identyfikację i konfigurację nowych liczników.

Przeznaczenie

Ten add-on jest szczególnie przydatny, gdy:

odbiór radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),

chcesz używać wmbusmeters bez dongla USB,

posiadasz własny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

Projekty bazowe (upstream)

Ten projekt bazuje na następujących repozytoriach:

wmbusmeters
https://github.com/wmbusmeters/wmbusmeters

Licencja: GPL-3.0

wmbusmeters-ha-addon
https://github.com/wmbusmeters/wmbusmeters-ha-addon

Licencja: GPL-3.0

Licencja

Repozytorium zawiera i modyfikuje kod pochodzący z projektu
wmbusmeters-ha-addon, który jest objęty licencją GPL-3.0.

W związku z tym cały projekt jest dystrybuowany na licencji:

GNU General Public License v3.0 (GPL-3.0)

🇬🇧 Description (EN)

This Home Assistant add-on is a fork and extension of the official
wmbusmeters-ha-addon, which itself is based on the wmbusmeters project.

The purpose of this add-on is to enable Wireless M-Bus (C1 / T1 / S1) telegram decoding in Home Assistant without a local radio dongle, by using external receivers and MQTT as the input transport.

The problem it solves

The original wmbusmeters-ha-addon:

assumes local radio reception (USB / serial / RTL-SDR),

does not support external telegram sources,

does not accept input via STDIN.

As a result, ESP32-based receivers, gateways or custom wM-Bus bridges
cannot be used directly as data sources.

Solution implemented in this fork

This project introduces an MQTT-based input path for wmbusmeters.

The add-on acts as a bridge between:

an external wM-Bus telegram source,

and the wmbusmeters decoding engine.

Data flow architecture
ESP32 / Gateway / Bridge
→ MQTT (RAW wM-Bus HEX telegram)
→ wmbusmeters (stdin:hex)
→ MQTT (JSON)
→ Home Assistant (MQTT Discovery)

Key features

📡 MQTT input for raw wM-Bus telegrams

🔌 STDIN support for wmbusmeters

🧠 Full decoding handled by upstream wmbusmeters

🏠 MQTT output with Home Assistant Discovery

👂 LISTEN mode for detecting meter IDs and drivers before configuration

Intended use cases

This add-on is useful when:

radio reception is handled externally,

no USB radio dongle is available or desired,

wmbusmeters is used purely as a decoder and HA integration layer.

Upstream projects

wmbusmeters
https://github.com/wmbusmeters/wmbusmeters

License: GPL-3.0

wmbusmeters-ha-addon
https://github.com/wmbusmeters/wmbusmeters-ha-addon

License: GPL-3.0

License

Because this repository contains and modifies code derived from
wmbusmeters-ha-addon, the entire project is distributed under:

GNU General Public License v3.0 (GPL-3.0)
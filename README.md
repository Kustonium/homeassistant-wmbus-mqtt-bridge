Home Assistant Add-on: wMBus MQTT Bridge
???? Opis (PL)

Ten dodatek Home Assistant jest rozszerzeniem oraz forkiem oficjalnego projektu
wmbusmeters-ha-addon, który sam w sobie bazuje na narzædziu wmbusmeters.

Celem projektu jest umoýliwienie dekodowania telegramów Wireless M-Bus (C1 / T1 / S1)
w Home Assistant bez uýycia fizycznego dongla radiowego, poprzez wykorzystanie
zewnætrznych odbiorników oraz MQTT jako kanaùu wejúciowego.

Problem, który rozwiàzuje ten add-on

Oryginalny add-on wmbusmeters-ha-addon:

zakùada, ýe odbiór radiowy odbywa siæ lokalnie (USB / serial / RTL-SDR),

nie przewiduje moýliwoúci podania telegramów z zewnætrznego êródùa,

nie obsùuguje wejúcia STDIN jako êródùa danych.

W praktyce oznacza to, ýe:

ESP32,

gatewaye,

bridge’e radiowe,

wùasne odbiorniki wM-Bus

nie mogà byã uýyte bezpoúrednio jako êródùo danych dla wmbusmeters.

Rozwiàzanie zastosowane w tym projekcie

Ten fork wprowadza alternatywnà úcieýkæ wejúciowà opartà o MQTT.

Add-on dziaùa jako most (bridge) pomiædzy:

êródùem telegramów wM-Bus,

a silnikiem dekodujàcym wmbusmeters.

Architektura przepùywu danych
ESP32 / Gateway / Bridge
? MQTT (surowy telegram wM-Bus w formacie HEX)
? wmbusmeters (stdin:hex)
? MQTT (JSON)
? Home Assistant (MQTT Discovery)

Kluczowe cechy

?? MQTT jako wejúcie danych
Surowe telegramy wM-Bus (HEX) sà odbierane z wybranego tematu MQTT.

?? Wejúcie STDIN dla wmbusmeters
Telegramy sà przekazywane do wmbusmeters przez stdin:hex,
czego oryginalny add-on nie obsùuguje.

?? Peùne dekodowanie przez wmbusmeters
Projekt nie zastæpuje wmbusmeters — wykorzystuje go w caùoúci
(dekodowanie, logika, formaty).

?? MQTT + Home Assistant Discovery
Dane sà publikowane w MQTT oraz automatycznie rejestrowane w Home Assistant.

?? Tryb LISTEN (nasùuch)
Gdy lista meters jest pusta:

add-on dziaùa w trybie pasywnym,

w logach wypisywane sà wykryte meter_id oraz sugerowany driver,

uùatwia to identyfikacjæ i konfiguracjæ nowych liczników.

Wymagania (WAÝNE)

?? Ten add-on korzysta WYÙÀCZNIE z wewnætrznego brokera MQTT dostarczanego przez Home Assistant (Mosquitto add-on).

Wymagany jest Mosquitto Broker zainstalowany jako add-on w Home Assistant.

Zewnætrzne brokery MQTT (LXC / VM / Docker) nie sà obsùugiwane.

Add-on wymaga Home Assistant OS / Supervised (Supervisor API).

Przeznaczenie

Ten add-on jest szczególnie przydatny, gdy:

odbiór radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),

chcesz uýywaã wmbusmeters bez dongla USB,

posiadasz wùasny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

?? Waýna informacja

Nie instaluj oficjalnego add-onu wmbusmeters równolegle.
Ten add-on zawiera wùasnà instancjæ wmbusmeters i zastæpuje go w tym scenariuszu.

Projekty bazowe (upstream)

wmbusmeters
https://github.com/wmbusmeters/wmbusmeters

Licencja: GPL-3.0

wmbusmeters-ha-addon
https://github.com/wmbusmeters/wmbusmeters-ha-addon

Licencja: GPL-3.0

Licencja

Repozytorium zawiera i modyfikuje kod pochodzàcy z projektu
wmbusmeters-ha-addon, który jest objæty licencjà GPL-3.0.

W zwiàzku z tym caùy projekt jest dystrybuowany na licencji:

GNU General Public License v3.0 (GPL-3.0)

???? Description (EN)

This Home Assistant add-on is a fork and extension of the official
wmbusmeters-ha-addon, which itself is based on the wmbusmeters project.

The purpose of this add-on is to enable Wireless M-Bus (C1 / T1 / S1) telegram decoding
in Home Assistant without a local radio dongle, by using external receivers
and MQTT as the input transport.

The problem it solves

The original wmbusmeters-ha-addon:

assumes local radio reception (USB / serial / RTL-SDR),

does not support external telegram sources,

does not accept STDIN as an input source.

As a result, ESP32-based receivers, gateways or custom wM-Bus bridges
cannot be used directly as data sources.

Solution implemented in this fork

This project introduces an MQTT-based input path for wmbusmeters.

The add-on acts as a bridge between:

an external wM-Bus telegram source,

and the wmbusmeters decoding engine.

Data flow architecture
ESP32 / Gateway / Bridge
? MQTT (RAW wM-Bus HEX telegram)
? wmbusmeters (stdin:hex)
? MQTT (JSON)
? Home Assistant (MQTT Discovery)

Key features

?? MQTT input for raw wM-Bus telegrams

?? STDIN support for wmbusmeters

?? Full decoding handled by upstream wmbusmeters

?? MQTT output with Home Assistant Discovery

?? LISTEN mode for detecting meter IDs and drivers before configuration

Requirements (IMPORTANT)

?? This add-on uses ONLY the internal MQTT broker provided by Home Assistant (Mosquitto add-on).

The Mosquitto Broker add-on must be installed and running.

External MQTT brokers are not supported.

Requires Home Assistant OS / Supervised (Supervisor API).

Intended use cases

This add-on is useful when:

radio reception is handled externally,

no USB radio dongle is available or desired,

wmbusmeters is used purely as a decoder and HA integration layer.

?? Important note

Do not install the official wmbusmeters add-on in parallel.
This add-on bundles its own wmbusmeters instance and replaces it for this use case.

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
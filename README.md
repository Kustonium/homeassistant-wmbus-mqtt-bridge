Home Assistant Add-on: wMBus MQTT Bridge
???? Opis (PL)

Ten dodatek Home Assistant jest rozszerzeniem oraz forkiem oficjalnego projektu
wmbusmeters-ha-addon, kt車ry sam w sobie bazuje na narz?dziu wmbusmeters.

Celem projektu jest umo?liwienie dekodowania telegram車w Wireless M-Bus (C1 / T1 / S1)
w Home Assistant bez u?ycia fizycznego dongla radiowego, poprzez wykorzystanie
zewn?trznych odbiornik車w oraz MQTT jako kana?u wej?ciowego.

Problem, kt車ry rozwi?zuje ten add-on

Oryginalny add-on wmbusmeters-ha-addon:

zak?ada, ?e odbi車r radiowy odbywa si? lokalnie (USB / serial / RTL-SDR),

nie przewiduje mo?liwo?ci podania telegram車w z zewn?trznego ?r車d?a,

nie obs?uguje wej?cia STDIN jako ?r車d?a danych.

W praktyce oznacza to, ?e:

ESP32,

gatewaye,

bridge＊e radiowe,

w?asne odbiorniki wM-Bus

nie mog? by? u?yte bezpo?rednio jako ?r車d?o danych dla wmbusmeters.

Rozwi?zanie zastosowane w tym projekcie

Ten fork wprowadza alternatywn? ?cie?k? wej?ciow? opart? o MQTT.

Add-on dzia?a jako most (bridge) pomi?dzy:

?r車d?em telegram車w wM-Bus,

a silnikiem dekoduj?cym wmbusmeters.

Architektura przep?ywu danych
ESP32 / Gateway / Bridge
↙ MQTT (surowy telegram wM-Bus w formacie HEX)
↙ wmbusmeters (stdin:hex)
↙ MQTT (JSON)
↙ Home Assistant (MQTT Discovery)

Kluczowe cechy

?? MQTT jako wej?cie danych
Surowe telegramy wM-Bus (HEX) s? odbierane z wybranego tematu MQTT.

?? Wej?cie STDIN dla wmbusmeters
Telegramy s? przekazywane do wmbusmeters przez stdin:hex,
czego oryginalny add-on nie obs?uguje.

?? Pe?ne dekodowanie przez wmbusmeters
Projekt nie zast?puje wmbusmeters 〞 wykorzystuje go w ca?o?ci
(dekodowanie, logika, formaty).

?? MQTT + Home Assistant Discovery
Dane s? publikowane w MQTT oraz automatycznie rejestrowane w Home Assistant.

?? Tryb LISTEN (nas?uch)
Gdy lista meters jest pusta:

add-on dzia?a w trybie pasywnym,

w logach wypisywane s? wykryte meter_id oraz sugerowany driver,

u?atwia to identyfikacj? i konfiguracj? nowych licznik車w.

Wymagania (WA?NE)

?? Ten add-on korzysta WY??CZNIE z wewn?trznego brokera MQTT dostarczanego przez Home Assistant (Mosquitto add-on).

Wymagany jest Mosquitto Broker zainstalowany jako add-on w Home Assistant.

Zewn?trzne brokery MQTT (LXC / VM / Docker) nie s? obs?ugiwane.

Add-on wymaga Home Assistant OS / Supervised (Supervisor API).

Przeznaczenie

Ten add-on jest szczeg車lnie przydatny, gdy:

odbi車r radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),

chcesz u?ywa? wmbusmeters bez dongla USB,

posiadasz w?asny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

?? Wa?na informacja

Nie instaluj oficjalnego add-onu wmbusmeters r車wnolegle.
Ten add-on zawiera w?asn? instancj? wmbusmeters i zast?puje go w tym scenariuszu.

Projekty bazowe (upstream)

wmbusmeters
https://github.com/wmbusmeters/wmbusmeters

Licencja: GPL-3.0

wmbusmeters-ha-addon
https://github.com/wmbusmeters/wmbusmeters-ha-addon

Licencja: GPL-3.0

Licencja

Repozytorium zawiera i modyfikuje kod pochodz?cy z projektu
wmbusmeters-ha-addon, kt車ry jest obj?ty licencj? GPL-3.0.

W zwi?zku z tym ca?y projekt jest dystrybuowany na licencji:

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
↙ MQTT (RAW wM-Bus HEX telegram)
↙ wmbusmeters (stdin:hex)
↙ MQTT (JSON)
↙ Home Assistant (MQTT Discovery)

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
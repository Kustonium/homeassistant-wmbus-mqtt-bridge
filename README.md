Home Assistant Add-on: wMBus MQTT Bridge
馃嚨馃嚤 Opis (PL)

Ten dodatek Home Assistant jest rozszerzeniem oraz forkiem oficjalnego projektu
wmbusmeters-ha-addon, kt贸ry sam w sobie bazuje na narz臋dziu wmbusmeters.

Celem projektu jest umo偶liwienie dekodowania telegram贸w Wireless M-Bus (C1 / T1 / S1) w Home Assistant bez u偶ycia fizycznego dongla radiowego, poprzez wykorzystanie zewn臋trznych odbiornik贸w i MQTT jako kana艂u wej艣ciowego.

Problem, kt贸ry rozwi膮zuje ten add-on

Oryginalny add-on wmbusmeters-ha-addon:

zak艂ada, 偶e odbi贸r radiowy odbywa si臋 lokalnie (USB / serial / RTL-SDR),

nie przewiduje mo偶liwo艣ci podania telegram贸w z zewn臋trznego 藕r贸d艂a,

nie obs艂uguje wej艣cia STDIN jako 藕r贸d艂a danych.

W praktyce oznacza to, 偶e:

ESP32, gatewaye, bridge鈥檈 radiowe czy w艂asne odbiorniki wM-Bus
nie mog膮 by膰 u偶yte bezpo艣rednio jako 藕r贸d艂o danych dla wmbusmeters.

Rozwi膮zanie zastosowane w tym projekcie

Ten fork wprowadza alternatywn膮 艣cie偶k臋 wej艣ciow膮 opart膮 o MQTT.

Add-on dzia艂a jako most (bridge) pomi臋dzy:

藕r贸d艂em telegram贸w wM-Bus,

a silnikiem dekoduj膮cym wmbusmeters.

Architektura przep艂ywu danych
ESP32 / Gateway / Bridge
鈫?MQTT (surowy telegram wM-Bus w formacie HEX)
鈫?wmbusmeters (stdin:hex)
鈫?MQTT (JSON)
鈫?Home Assistant (MQTT Discovery)

Kluczowe cechy

馃摗 MQTT jako wej艣cie danych
Surowe telegramy wM-Bus (HEX) s膮 odbierane z wybranego tematu MQTT.

馃攲 Wej艣cie STDIN dla wmbusmeters
Telegramy s膮 przekazywane do wmbusmeters przez stdin:hex, czego oryginalny add-on nie obs艂uguje.

馃 Pe艂ne dekodowanie przez wmbusmeters
Projekt nie zast臋puje wmbusmeters 鈥?wykorzystuje go w ca艂o艣ci (dekodowanie, logika, formaty).

馃彔 MQTT + Home Assistant Discovery
Dane s膮 publikowane w MQTT oraz automatycznie rejestrowane w Home Assistant.

馃憘 Tryb LISTEN (nas艂uch)
Gdy lista meters jest pusta:

add-on dzia艂a w trybie pasywnym,

w logach wypisywane s膮 wykryte meter_id oraz sugerowany driver,

u艂atwia to identyfikacj臋 i konfiguracj臋 nowych licznik贸w.

Przeznaczenie

Ten add-on jest szczeg贸lnie przydatny, gdy:

odbi贸r radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),

chcesz u偶ywa膰 wmbusmeters bez dongla USB,

posiadasz w艂asny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

????

Nie instaluj oficjalnego add-onu wmbusmeters równolegle.
Ten add-on zawiera w?asn? instancj? wmbusmeters i zast?puje go w tym scenariuszu.

????

Do not install the official wmbusmeters add-on in parallel.
This add-on bundles its own wmbusmeters instance and replaces it for this use case.
Projekty bazowe (upstream)

Ten projekt bazuje na nast臋puj膮cych repozytoriach:

wmbusmeters
https://github.com/wmbusmeters/wmbusmeters

Licencja: GPL-3.0

wmbusmeters-ha-addon
https://github.com/wmbusmeters/wmbusmeters-ha-addon

Licencja: GPL-3.0

Licencja

Repozytorium zawiera i modyfikuje kod pochodz膮cy z projektu
wmbusmeters-ha-addon, kt贸ry jest obj臋ty licencj膮 GPL-3.0.

W zwi膮zku z tym ca艂y projekt jest dystrybuowany na licencji:

GNU General Public License v3.0 (GPL-3.0)

馃嚞馃嚙 Description (EN)

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
鈫?MQTT (RAW wM-Bus HEX telegram)
鈫?wmbusmeters (stdin:hex)
鈫?MQTT (JSON)
鈫?Home Assistant (MQTT Discovery)

Key features

馃摗 MQTT input for raw wM-Bus telegrams

馃攲 STDIN support for wmbusmeters

馃 Full decoding handled by upstream wmbusmeters

馃彔 MQTT output with Home Assistant Discovery

馃憘 LISTEN mode for detecting meter IDs and drivers before configuration

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
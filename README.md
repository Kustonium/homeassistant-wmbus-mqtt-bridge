Home Assistant Add-on: wMBus MQTT Bridge
ğŸ‡µğŸ‡± Opis (PL)

Ten dodatek Home Assistant jest rozszerzeniem oraz forkiem oficjalnego projektu
<<<<<<< HEAD
wmbusmeters-ha-addon, który sam w sobie bazuje na narzædziu wmbusmeters.

Celem projektu jest umoıliwienie dekodowania telegramów Wireless M-Bus (C1 / T1 / S1)
w Home Assistant bez uıycia fizycznego dongla radiowego, poprzez wykorzystanie
zewnætrznych odbiorników oraz MQTT jako kanaùu wejúciowego.

Problem, który rozwiàzuje ten add-on

Oryginalny add-on wmbusmeters-ha-addon:

zakùada, ıe odbiór radiowy odbywa siæ lokalnie (USB / serial / RTL-SDR),

nie przewiduje moıliwoúci podania telegramów z zewnætrznego êródùa,

nie obsùuguje wejúcia STDIN jako êródùa danych.

W praktyce oznacza to, ıe:
=======
wmbusmeters-ha-addon, ktÃ³ry sam w sobie bazuje na narzÄ™dziu wmbusmeters.

Celem projektu jest umoÅ¼liwienie dekodowania telegramÃ³w Wireless M-Bus (C1 / T1 / S1)
w Home Assistant bez uÅ¼ycia fizycznego dongla radiowego, poprzez wykorzystanie
zewnÄ™trznych odbiornikÃ³w oraz MQTT jako kanaÅ‚u wejÅ›ciowego.

Problem, ktÃ³ry rozwiÄ…zuje ten add-on

Oryginalny add-on wmbusmeters-ha-addon:

zakÅ‚ada, Å¼e odbiÃ³r radiowy odbywa siÄ™ lokalnie (USB / serial / RTL-SDR),

nie przewiduje moÅ¼liwoÅ›ci podania telegramÃ³w z zewnÄ™trznego ÅºrÃ³dÅ‚a,

nie obsÅ‚uguje wejÅ›cia STDIN jako ÅºrÃ³dÅ‚a danych.

W praktyce oznacza to, Å¼e:
>>>>>>> 5217cdd411ec4eb4adc96306792fb39477c6572e

ESP32,

gatewaye,

<<<<<<< HEAD
bridge’e radiowe,

wùasne odbiorniki wM-Bus

nie mogà byã uıyte bezpoúrednio jako êródùo danych dla wmbusmeters.

Rozwiàzanie zastosowane w tym projekcie

Ten fork wprowadza alternatywnà úcieıkæ wejúciowà opartà o MQTT.

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

Wymagania (WAİNE)

?? Ten add-on korzysta WYÙÀCZNIE z wewnætrznego brokera MQTT dostarczanego przez Home Assistant (Mosquitto add-on).

Wymagany jest Mosquitto Broker zainstalowany jako add-on w Home Assistant.

Zewnætrzne brokery MQTT (LXC / VM / Docker) nie sà obsùugiwane.
=======
bridgeâ€™e radiowe,

wÅ‚asne odbiorniki wM-Bus

nie mogÄ… byÄ‡ uÅ¼yte bezpoÅ›rednio jako ÅºrÃ³dÅ‚o danych dla wmbusmeters.

RozwiÄ…zanie zastosowane w tym projekcie

Ten fork wprowadza alternatywnÄ… Å›cieÅ¼kÄ™ wejÅ›ciowÄ… opartÄ… o MQTT.

Add-on dziaÅ‚a jako most (bridge) pomiÄ™dzy:

ÅºrÃ³dÅ‚em telegramÃ³w wM-Bus,

a silnikiem dekodujÄ…cym wmbusmeters.

Architektura przepÅ‚ywu danych
ESP32 / Gateway / Bridge
â†’ MQTT (surowy telegram wM-Bus w formacie HEX)
â†’ wmbusmeters (stdin:hex)
â†’ MQTT (JSON)
â†’ Home Assistant (MQTT Discovery)

Kluczowe cechy

ğŸ“¡ MQTT jako wejÅ›cie danych
Surowe telegramy wM-Bus (HEX) sÄ… odbierane z wybranego tematu MQTT.

ğŸ”Œ WejÅ›cie STDIN dla wmbusmeters
Telegramy sÄ… przekazywane do wmbusmeters przez stdin:hex,
czego oryginalny add-on nie obsÅ‚uguje.

ğŸ§  PeÅ‚ne dekodowanie przez wmbusmeters
Projekt nie zastÄ™puje wmbusmeters â€” wykorzystuje go w caÅ‚oÅ›ci
(dekodowanie, logika, formaty).

ğŸ  MQTT + Home Assistant Discovery
Dane sÄ… publikowane w MQTT oraz automatycznie rejestrowane w Home Assistant.

ğŸ‘‚ Tryb LISTEN (nasÅ‚uch)
Gdy lista meters jest pusta:

add-on dziaÅ‚a w trybie pasywnym,

w logach wypisywane sÄ… wykryte meter_id oraz sugerowany driver,

uÅ‚atwia to identyfikacjÄ™ i konfiguracjÄ™ nowych licznikÃ³w.

Wymagania (WAÅ»NE)

âš ï¸ Ten add-on korzysta WYÅÄ„CZNIE z wewnÄ™trznego brokera MQTT dostarczanego przez Home Assistant (Mosquitto add-on).

Wymagany jest Mosquitto Broker zainstalowany jako add-on w Home Assistant.

ZewnÄ™trzne brokery MQTT (LXC / VM / Docker) nie sÄ… obsÅ‚ugiwane.
>>>>>>> 5217cdd411ec4eb4adc96306792fb39477c6572e

Add-on wymaga Home Assistant OS / Supervised (Supervisor API).

Przeznaczenie

<<<<<<< HEAD
Ten add-on jest szczególnie przydatny, gdy:

odbiór radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),

chcesz uıywaã wmbusmeters bez dongla USB,

posiadasz wùasny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

?? Waına informacja

Nie instaluj oficjalnego add-onu wmbusmeters równolegle.
Ten add-on zawiera wùasnà instancjæ wmbusmeters i zastæpuje go w tym scenariuszu.
=======
Ten add-on jest szczegÃ³lnie przydatny, gdy:

odbiÃ³r radiowy realizowany jest poza Home Assistant (ESP32, SBC, bridge),

chcesz uÅ¼ywaÄ‡ wmbusmeters bez dongla USB,

posiadasz wÅ‚asny pipeline radiowy i potrzebujesz tylko dekodera + integracji z HA.

âš ï¸ WaÅ¼na informacja

Nie instaluj oficjalnego add-onu wmbusmeters rÃ³wnolegle.
Ten add-on zawiera wÅ‚asnÄ… instancjÄ™ wmbusmeters i zastÄ™puje go w tym scenariuszu.
>>>>>>> 5217cdd411ec4eb4adc96306792fb39477c6572e

Projekty bazowe (upstream)

wmbusmeters
https://github.com/wmbusmeters/wmbusmeters

Licencja: GPL-3.0

wmbusmeters-ha-addon
https://github.com/wmbusmeters/wmbusmeters-ha-addon

Licencja: GPL-3.0

Licencja

<<<<<<< HEAD
Repozytorium zawiera i modyfikuje kod pochodzàcy z projektu
wmbusmeters-ha-addon, który jest objæty licencjà GPL-3.0.

W zwiàzku z tym caùy projekt jest dystrybuowany na licencji:
=======
Repozytorium zawiera i modyfikuje kod pochodzÄ…cy z projektu
wmbusmeters-ha-addon, ktÃ³ry jest objÄ™ty licencjÄ… GPL-3.0.

W zwiÄ…zku z tym caÅ‚y projekt jest dystrybuowany na licencji:
>>>>>>> 5217cdd411ec4eb4adc96306792fb39477c6572e

GNU General Public License v3.0 (GPL-3.0)

ğŸ‡¬ğŸ‡§ Description (EN)

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
<<<<<<< HEAD
? MQTT (RAW wM-Bus HEX telegram)
? wmbusmeters (stdin:hex)
? MQTT (JSON)
? Home Assistant (MQTT Discovery)
=======
â†’ MQTT (RAW wM-Bus HEX telegram)
â†’ wmbusmeters (stdin:hex)
â†’ MQTT (JSON)
â†’ Home Assistant (MQTT Discovery)
>>>>>>> 5217cdd411ec4eb4adc96306792fb39477c6572e

Key features

ğŸ“¡ MQTT input for raw wM-Bus telegrams

ğŸ”Œ STDIN support for wmbusmeters

ğŸ§  Full decoding handled by upstream wmbusmeters

ğŸ  MQTT output with Home Assistant Discovery

ğŸ‘‚ LISTEN mode for detecting meter IDs and drivers before configuration

Requirements (IMPORTANT)

âš ï¸ This add-on uses ONLY the internal MQTT broker provided by Home Assistant (Mosquitto add-on).

The Mosquitto Broker add-on must be installed and running.

External MQTT brokers are not supported.

Requires Home Assistant OS / Supervised (Supervisor API).

Intended use cases

This add-on is useful when:

radio reception is handled externally,

no USB radio dongle is available or desired,

wmbusmeters is used purely as a decoder and HA integration layer.

âš ï¸ Important note

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

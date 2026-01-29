# wMBus MQTT Bridge (ESP32 → MQTT → wmbusmeters → Home Assistant)

Home Assistant add-on that feeds **RAW wM-Bus telegrams as HEX** from an ESP32 (via MQTT) directly into **wmbusmeters** using `stdin:hex`, and then publishes parsed JSON + **MQTT Discovery** so encje pojawiają się same (bez ręcznego dopisywania).

**Bez USB dongla. Bez RTL-SDR.**

## Jak to działa

ESP32 (radio) → MQTT (HEX telegram) → ten add-on → `wmbusmeters` → MQTT (JSON + Discovery) → Home Assistant encje

## Wymagania

- Home Assistant z działającym MQTT brokerem (np. core-mosquitto)
- Włączona integracja **MQTT** w HA (to ona odbiera Discovery)
- ESP32 wysyła **surowy telegram jako HEX** w payload (bez JSONa, bez dodatkowego tekstu)
- Jeśli licznik jest szyfrowany → musisz podać `key` dla tego licznika (AES)

## MQTT (wejście)

Domyślny topic wejściowy: `wmbus_bridge/telegram`

Payload przykład (HEX):
```
4c44b4092182520317067a120000000c1387490100046d24285c310f8f00000000000000000000000000000000002f0000b40000530100b60100100200b50200400300be03006f040031050000
```

Add-on sanitizuje payload (usuwa spacje, usuwa `0x`, przepuszcza tylko znaki hex), o ile `filter_hex_only: true`.

## Konfiguracja add-on

### 1) Tryb normalny (masz swoje liczniki)
W `options` ustawiasz listę `meters`:
- `id` – nazwa w HA
- `meter_id` – **DLL-ID** z logu `Received telegram from: XXXXXXXX` (zwykle 8 cyfr, może mieć wiodące zera)
- `type` – driver (np. `hydrodigit`)
- `key` – `NOKEY` jeśli nieszyfrowane, albo klucz AES jeśli szyfrowane

### 2) Tryb diagnostyczny (LISTEN MODE)
Jeśli **zostawisz `meters: []`**, wmbusmeters wypisze:
- `Received telegram from: XXXXXXXX`
- `driver: ...`

A add-on dodatkowo wypluje snippet do wklejenia w opcjach.

## MQTT (wyjście)

Add-on publikuje:
- **state**: `wmbusmeters/<id>/state` (JSON z wmbusmeters)
- **discovery config**: `homeassistant/sensor/wmbus_<id>/total_m3/config` (retained)

W HA pojawi się sensor `total_m3`, a cała reszta pól będzie w atrybutach encji (json_attributes).

## ESPHome – przykład publikacji RAW HEX

Jeśli używasz `wmbus_radio` i chcesz wysłać HEX (bez dekodowania w ESP), to w `on_frame`:

```yaml
on_frame:
  then:
    - mqtt.publish:
        topic: "wmbus_bridge/telegram"
        payload: !lambda |-
          auto s = frame->as_hex();
          if (s.size() < 30) return std::string("");  // odfiltruj krótkie śmieci
          return s;
```

To jest dokładnie podejście, które odciąża ESP: zero ładowania driverów / dekodowania w mikrokontrolerze.

## Uwaga o powstaniu kodu

Kod add-on i konfiguracje zostały przygotowane w oparciu o narzędzia AI.
Autor repozytorium pełnił rolę integratora/testera i dostarczał kontekst oraz logi do iteracji.

## License
MIT

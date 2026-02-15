## 1.3.0

### PL (Polski)
#### Dodano
- Refaktor architektury: wspólna logika w `bridge.sh` + cienkie wrappery dla HA add-on (`run.sh`) i Docker/LXC (`docker/entrypoint.sh`).
- Generic MQTT Discovery: automatyczne tworzenie encji Home Assistant dla każdego pola liczbowego z JSON telegramu (niezależnie od drivera).
- Listen-mode snippet: gdy `meters: []`, log podaje gotowy wpis do konfiguracji z `type: auto` (sugerowany driver jako komentarz).

#### Zmieniono
- Wybór drivera w UI: `type` jako lista (`auto` + popularne drivery + `other` z `type_other`).
- Discovery generowane per-pole: `homeassistant/sensor/wmbus_<id>/<field>/config`.
- Czyszczenie starego błędnego retained discovery `.../total_m3/config` (publish empty payload z retain).

#### Naprawiono
- Budowanie payload w `jq`: poprawione na składnię `if ... then ... else ... end` (kompatybilne z jq 1.6).
- Walidacja konfiguracji: `meters` ma być listą (`[]`), nie `null`.

#### Breaking / Uwagi
- Jeśli miałeś ręcznie dodane encje po starych topicach discovery, po aktualizacji usuń je lub zrestartuj HA (Discovery jest teraz per-pole).
- Dla liczników bez `total_m3` stary retained config zostaje usunięty.

---

### EN (English)
#### Added
- Architecture refactor: shared core logic in `bridge.sh` + thin wrappers for HA add-on (`run.sh`) and Docker/LXC (`docker/entrypoint.sh`).
- Generic MQTT Discovery: automatically creates Home Assistant entities for every numeric field in telegram JSON (driver-agnostic).
- Listen-mode snippet: when `meters: []`, logs a ready-to-paste config entry using `type: auto` (suggested driver shown as a comment).

#### Changed
- UI driver selection: `type` is now an enum (`auto` + common drivers + `other` with `type_other`).
- Discovery is generated per-field: `homeassistant/sensor/wmbus_<id>/<field>/config`.
- Cleanup of legacy wrong retained discovery `.../total_m3/config` (publish empty retained payload).

#### Fixed
- `jq` payload generation: replaced unsupported ternary with `if ... then ... else ... end` (jq 1.6 compatible).
- Config validation: `meters` must be a list (`[]`), not `null`.

#### Breaking / Notes
- If you created manual entities based on legacy discovery topics, remove them or restart HA after update (Discovery is now per-field).
- For meters without `total_m3`, the old retained config will be removed automatically.

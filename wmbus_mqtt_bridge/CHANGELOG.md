## 1.5.2

Defensive MQTT Discovery — closes a class of issues equivalent to
upstream wmbusmeters issue
[#1922](https://github.com/wmbusmeters/wmbusmeters/issues/1922).
Telegrams from a single meter often carry only a subset of all fields
the meter can report. Until now, every missing field in a freshly
received telegram raised a Jinja warning in Home Assistant
(`'dict object' has no attribute '<field>'`), easily producing
thousands of warnings per day, and a stopped meter would still appear
"alive" with stale values forever.

### Fixed
- `value_template` in Discovery payloads is now defensive:
  `{{ value_json.get('<field>') | default(none) }}`. Missing field
  returns `None`, HA treats it as "no state update" and the entity
  keeps its last known value without raising a Jinja warning.
- `expire_after` is now emitted per sensor and equals
  `2 * avg_interval_s` of the meter (rounded down to the nearest
  minute), with a 3600 s floor for fresh installs without history.
  HA marks the entire meter unavailable when it actually stops
  talking; the value self-tunes as telegram-interval statistics
  stabilize (the Discovery cache key includes the rounded
  `expire_after`, so updated configs are re-published automatically).
- `state_class: measurement` is now emitted only for fields whose
  `device_class` is one of the statistically meaningful kinds
  (`temperature`, `humidity`, `power`, `voltage`, `current`,
  `frequency`, `battery`, `water`, `gas`, `energy`). Error codes,
  status flags, version numbers and similar numeric metadata no
  longer pollute Home Assistant long-term statistics.
- `device_class` for `m³` readings is now derived primarily from the
  meter's reported `media` (water / warm_water / hot_water /
  cold_water → `water`; gas → `gas`; heat / cooling → no
  `device_class`, since HA has no heat-volume class and `water`
  would be wrong). The previous keyword heuristic stays only as a
  fallback for unknown media.

### Changed
- Docs (`docs/README.{pl,en,de,cs,sk}.md`) now describe the actual
  MQTT topology — one JSON state topic per meter
  (`<state_prefix>/<id>/state`) and Discovery payloads using
  `value_template` / `json_attributes_topic` / `expire_after` — and
  no longer claim that the bridge publishes a separate topic per
  field, which never matched the implementation.

### Notes
- No changes to the WebUI, MQTT topology, broker connection or
  add-on options. This release only tunes how Home Assistant
  Discovery describes the existing data stream.

---

## 1.5.1

First stable release that ships the full WebUI as developed and tested on
the dev addon. The previous 1.5.0 stable image was frozen at the time of
the multi-addon repo split and missed every dev-side WebUI improvement
made since. This release brings stable's runtime in lockstep with dev.

### Added
- Sync of `rootfs/` and `Dockerfile` from `wmbus_mqtt_bridge_dev/`,
  bringing in the accumulated WebUI work: media icons and signal bars,
  warm-water media type, bare-meter-ID handling, candidate counts,
  smart refresh, meter-name input, localized media labels, suggested
  meter names, restart i18n message, hidden pending meters, alarm-field
  exclusion, options.json read/write paths, waiting panel, timestamp
  formatting, sanitization and other fixes. See dev addon commit log
  for individual entries.
- `scripts/promote-rootfs.sh` — manual sync from dev to stable.
- `.github/workflows/sync-rootfs.yaml` — automatic sync on every push
  to `dev` whose changes land in `wmbus_mqtt_bridge_dev/rootfs`,
  `Dockerfile` or `translations`. Prevents future drift between the
  two addons.

### Changed
- Merged the AI-development note and the per-language translation
  disclaimer into a single, vendor-neutral notice (PL + EN) clarifying
  that this project is AI-developed with human-in-the-loop testing and
  maintenance by Kustonium, and that **all** user-facing text — PL/EN
  included — is machine-generated and may contain errors.
- Removed the "native speakers welcome / submit corrections" appeal
  from the README and from every `docs/README.<lang>.md`.
- Added an early-section paragraph in every README explaining that the
  add-on is normally paired with the companion firmware
  [`esphome-wmbus-bridge-rawonly`](https://github.com/Kustonium/esphome-wmbus-bridge-rawonly)
  running on an ESP32 with **CC1101, SX1276 or SX1262**, while staying
  independent of any specific source of raw wMBus hex on MQTT.

### Fixed
- Mermaid radio list in every `docs/README.<lang>.md` now lists the
  actually supported chips (CC1101, SX1276, SX1262) instead of the
  outdated "CC1101 or RFM69".
- Trimmed the per-language `docs/README.<de,cs,sk>.md` headers to keep
  the machine-translation disclaimer but drop the corrections call.

---

## 1.5.0

Marked as **experimental** — first release of the embedded WebUI. Tested on the
companion dev add-on; please report regressions via GitHub Issues.

### Added
- **WebUI with Home Assistant Ingress** — new panel "wMBus Bridge" served on
  port 8099 via `hassio_api: true` + `ingress: true`, no extra port exposure.
  Backed by a Python service (`rootfs/usr/bin/webui.py`) supervised by s6
  (`rootfs/etc/services.d/wmbus_webui/run`).
- **Multi-language UI** — translation layer in `rootfs/usr/bin/i18n.py`
  covering Polish, English, German, Czech and Slovak. All UI strings are
  machine-generated and may contain errors in any language.
- **Multi-language documentation** under `docs/` — full PL/EN/DE/CS/SK
  versions of the README, linked from the main README. All docs are
  machine-generated.
- Combined AI / machine-generated-text notice in the README (PL/EN).

### Changed
- Add-on stage set to `experimental`.
- Default `search_tolerance_m3` lowered from `1` to `0.05` for a more accurate
  match window during meter discovery.
- Bridge runtime script (`rootfs/usr/bin/bridge.sh`) heavily extended to back
  the WebUI flows (status, candidates, controls).
- Dockerfile: base image bumped to `alpine:3.23`; `python3` added to the
  add-on stage for the WebUI; `webui.py` made executable on build.

### Notes
- Version `1.5.0` bumped manually; previous published release was `1.4.7`.

---

## 1.4.6

## Updated to version [2.0.0-444]

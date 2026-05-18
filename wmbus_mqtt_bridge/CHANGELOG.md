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

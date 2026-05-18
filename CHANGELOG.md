## 1.5.1

Documentation-only release. No runtime / code / configuration changes.

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

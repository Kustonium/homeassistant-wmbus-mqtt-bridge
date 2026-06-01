## 1.5.19-dev

### Fixed
- FU-008: Diehl/SAP (mfct 0x304C) RAW fallback no longer hardcodes
  `izarv2 / Water meter (0x07)` for every SAP telegram. The A/TYPE byte
  (raw[18:20]) is now read: type `0x07` keeps the unchanged izarv2 water
  path, any other type registers as `auto` + a mapped label via the new
  `map_device_type()` (known OMS types + `Unknown meter type (0xXX)`
  fallback, no full 0x00–0xFF table). Added a hard LISTEN-over-RAW
  priority: if the candidate already has a concrete (non-`auto`) driver
  from a real LISTEN classification, the RAW fallback returns without
  overwriting it — fixing the alternating overwrite race (e.g. non-water
  Diehl flapping auto → sharky → auto). bridge.sh only; IZAR water path
  and lowercase-ID handling unchanged.

## 1.5.18-dev

PRD §14 follow-up batch (FU-001, FU-002, FU-005). Verification-only
items FU-003 and FU-004 needed no code change (current behaviour already
correct; reference PRD updated).

### Fixed
- FU-001: unified the `search_tolerance_m3` default to `0.05` across all
  runtime and Docker fallbacks. `bridge.sh` used a stale `1` fallback in
  two spots (`json_get '.search_tolerance_m3' '1'` and
  `float_or_default "${SEARCH_TOLERANCE_M3}" "1"`) and
  `docker/entrypoint.sh` seeded the default `options.json` with `1`.
  Without an explicit value, Docker users (and anyone clearing the option)
  got a 20× wider match tolerance than the documented `0.05`, risking
  false matches in multi-dwelling buildings. `config.yaml` was already
  correct.

- FU-005: the "Restart add-on" button no longer silently fakes success in
  Docker standalone mode. Without a Supervisor API, `/api/restart-bridge`
  can only return a 400, yet the frontend swallowed the error, entered the
  "restarting" overlay and — because the WebUI process never actually went
  down — reported "Add-on restarted successfully". The handler now detects
  `meta.runtime === "docker"` and shows a clear instruction to run
  `docker restart <container>` on the host instead. New i18n key
  `restart_docker_manual` (EN/PL/DE/CS/SK). HA behaviour unchanged.

### Docs
- FU-002: corrected the published MQTT state/Discovery topic examples in
  all READMEs (EN/PL/DE/SK/CS). The topic uses the hardware serial
  (`.id`, e.g. `wmbusmeters/41553221/state`), not the user label — docs
  previously showed `wmbusmeters/cold_water_bathroom/state`. Discovery
  topic and `unique_id` now use `wmbus_<meter_id>`; the user label is kept
  only in the sensor `name`. Placeholders fixed: `<id>` → `<meter_id>`,
  `sensor/<id>_<field>` → `sensor/wmbus_<meter_id>/<field>`.

## 1.5.3-dev

Development snapshot ahead of the next stable cut. Bundles the
stable-track fixes already promoted to 1.5.1 / 1.5.2 plus a batch of
WebUI polish and an exhaustive unit-suffix table.

### Added
- `unit_from_key()` (WebUI) and full rewrite of `guess_unit()`
  (`bridge.sh`) with the exhaustive wmbusmeters field-suffix
  vocabulary. Longest suffixes are checked first so `_kwh`
  isn't shadowed by `_kw`, `_kvarh` by `_kvar`, `_m3h` by `_m3`,
  etc. New coverage includes `kVARh`/`kVAh`/`kVAR`/`kVA`, `J/h`,
  `GJ`/`MJ`, `dBm`, `hca`, `pct`/`ppm`, `bar`, `Pa`, `mol`, `min`,
  `rad`, `deg`, `kg`, `cd`, `K`, `°F` and the base units. Non-numeric
  meta suffixes (`utc`, `datetime`, `counter`, `factor`, `txt`, `nr`,
  `month`) explicitly emit no unit. In the WebUI the unit is shown
  with a small category emoji on the meter card.
- Dynamic meter-status label on the WebUI meter card (was always
  the static "Online"): `seen_15m > 0` → online (green), else
  `seen_60m > 0` → silent (amber), else offline (red).
  Uses `online_label` / `silent_label` / `offline_label` i18n keys.
- Restart button is back inside the pending-meters panel — earlier
  removal was reverted by user preference.

### Changed
- Carries every change from the 1.5.2 stable release: defensive
  `value_template` (`value_json.get(...) | default(none)`),
  `expire_after = 2 * avg_interval_s` (60 s rounded, 3600 s floor),
  `state_class: measurement` restricted to statistically meaningful
  `device_class` values, `device_class` for `m³` derived from
  the meter's reported `media`. See `wmbus_mqtt_bridge/CHANGELOG.md`
  for the full description.
- Carries every change from the 1.5.1 stable release: combined
  AI-development notice, ESPHome-pairing paragraph, mermaid radio
  list now lists CC1101/SX1276/SX1262, machine-translation
  disclaimers trimmed.

### CI
- Build workflow no longer rebuilds the image for text-only commits
  (`README.md`, `CHANGELOG.md` inside the addon folder, repo-root
  docs). Path filter narrowed to `rootfs/**`, `Dockerfile`,
  `config.yaml`, `translations/**` and the workflow file itself.
- New `sync-rootfs` workflow keeps `wmbus_mqtt_bridge/rootfs`,
  `Dockerfile` and `translations` in lockstep with the dev addon
  by auto-committing back to `dev` after every push that changes
  the dev runtime. Manual escape hatch is
  `scripts/promote-rootfs.sh`.

### Notes
- Versions `1.5.1-dev` and `1.5.2-dev` were not separately published —
  the dev branch moved straight from `1.5.0-dev` to `1.5.3-dev` while
  promoting incremental fixes to the stable channel.

---

## 1.5.0-dev

Development snapshot tracking the upcoming `1.5.0` stable release.
First version of the embedded WebUI — please report regressions via
GitHub Issues.

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

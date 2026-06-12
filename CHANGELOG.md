## 1.5.36

### Added
- AES lock badge under meter id; validated key field in change-driver modal (9d09334)
- surface AES key problems for encrypted meters (roadmap task 4) (7c91d32)

### Fixed
- doctor checklist hides the hint on passing checks (f01ddaa)
- gate diffs the whole push range, not only the last commit (3258561)
- Discovery Doctor prefix check uses canary verification and honest unknown state (f448e7b)
- prefix check in Discovery Doctor also accepts the live HA birth signal (3ab1b78)

## 1.5.35

### Added
- decrypt issue-report analysis with the configured AES key (1a37d14)
- published-fields expander on the meters view (ecbded7)
- issue-report export, driver picker and post-add driver change (2d22724)
- per-field availability template in MQTT Discovery configs (afb096d)

### Fixed
- hold live table re-render while the pointer is over a table (9205126)
- pass prune python program via -c (stdin heredoc broke in production) (6adb814)
- add change-driver action to the configured-on-air table (264bca5)
- browsable driver select, input validation and modal click-close bug (1e206cf)
- lowercase meter id in izar fixture test (id match is case-sensitive) (9a5c3b5)
- pin wmbusmeters build to last known-good commit 8c35c4a1 (171e0d1)

## 1.5.34

### Added
- prune long-silent candidates from status_candidates.tsv (24h) (c8dc73c)
- sink no-reception candidates to the bottom + media-group dividers (909ea78)
- stable candidate sort — group by media, then telegram count, then id (71640fc)

### Fixed
- align candidate silent-detection with the age-adjusted UI counters (2ba28b0)

## 1.5.33

### Fixed
- Meters whose wmbusmeters driver was added after the add-on's options schema
  was frozen (notably Diehl/Izar `izarv2`) were rejected when saved (Supervisor
  HTTP 400 "value must be one of …"), so they fell back to a file-only write and
  silently disappeared on the next restart/upgrade. The `meters[].type` field is
  now a free string, so any current wmbusmeters driver is accepted.

### Added
- Opt-in Home Assistant entity verification (`verify_ha_entities`, off by
  default): the add-on can ask the HA Core API whether its discovery entities
  were actually created. Enabling it grants read-only HA Core API access
  (`homeassistant_api`). This brings the stable schema/permissions in line with
  the development build (promote now syncs config.yaml, so they no longer drift).

## 1.5.32

### Added
- adaptive per-meter status from its cadence; silence never red (b2477b0)

### Fixed
- keep reception counts continuous across candidate->meter promotion (2d4d8a8)

## 1.5.31

### Added
- Per-ESP reception quality for each configured meter: the dashboard now shows,
  per receiver, the reception % and the telegram count for a meter, sourced from
  the ESP's opt-in diagnostics (`meter_snapshot` and the more frequent
  `meter_window`). It populates within minutes and scales to any number of ESPs.
- Reception badges (the ESP flag and per-ESP reception %) shown in the reception
  column across all meter tables, stacked one per line, with a legend on the
  column header explaining what each marker means.
- Bulk removal of configured meters via per-row checkboxes and a toolbar action.

### Changed
- ESP devices silent for over 12 h are dropped from the "Connected ESP" list
  (e.g. after a topic_name rename), while a recently stopped ESP stays visible
  and still raises the "pulse stopped" verdict.

### Fixed
- Removed the RSSI signal-strength band: field testing showed RSSI is not
  trustworthy across boards, so reception % — not RSSI — is the quality signal.
- Corrected the "configured meters on air" panel subtitle: the 15m/60m counters
  come from the decode instance (primary wmbusmeters), not the parallel listen
  instance.
- Made the pipeline expand affordance readable (triple chevron).


## 1.5.30

### Added
- Always-on ESP radio-path status in the dashboard, independent of the ESP's
  `diagnostic_mode`. The ESP firmware now publishes, every 60 s, a health pulse
  (`wmbus/<device>/health`) and the set of meters it is configured for
  (`wmbus/<device>/meters`). The WebUI turns these into:
  - a per-ESP "radio alive / receiver hearing" verdict taken from the pulse — so
    it reflects that the receiver actually hears telegrams, not merely that the
    firmware's main loop runs — with an aggregate that names a stopped ESP instead
    of hiding it behind a healthy total, surfaced on both the workspace and the
    pipeline tile;
  - a "ESP" badge on meters and candidates the ESP is explicitly flagged for
    (`target_meter_id` / `highlight_meters`), so an ESP-vs-add-on configuration
    mismatch is visible at a glance.
  This works even with ESP diagnostics off, and stays honest-witness throughout:
  missing or stale data degrades to a neutral state and is never shown as a green
  "all good".

### Fixed
- "Pulse stopped" is distinguished from "firmware without the pulse": an ESP that
  was seen and then goes silent reports that it stopped (powered off / lost
  connection) instead of a misleading "update the ESP firmware".
- Severity ordering of the radio verdict is correct: a stopped pulse degrades the
  pipeline tile green → amber only while the ESP is otherwise online; a fully
  offline ESP source stays red rather than being softened to amber.
- The per-ESP radio health no longer overwrites the device STATUS column (which
  made every row read as "offline" while telegrams were arriving).
- A focused pipeline tile no longer freezes: the live-update DOM patch now
  preserves only focused form inputs, not buttons, so a tile keeps refreshing
  after it is clicked to open its workspace.
- The ESP health/meters subscribers no longer abort under `set -euo pipefail`
  when their status file does not exist yet, which previously stopped the file
  from ever being created on first run (so the meter-flag badge never appeared).


## 1.5.29

### Added
- MQTT→HA healthcheck: the add-on now detects when it publishes to a broker
  that Home Assistant does not consume (a common "my meters never appear in HA"
  cause). HA presence is reported honestly — confirmed on the native HA broker
  (`core-mosquitto` / `mqtt_mode=ha`) or via a seen `online` birth message — and
  the MQTT tile shows broker identity read from `$SYS` (Mosquitto / EMQX, native
  / external) with a diagnostics panel (software, version, connected clients,
  HA-on-broker, TLS support).
- Opt-in HA entity verification (`verify_ha_entities`): the add-on publishes a
  hidden diagnostic canary entity and asks the HA Core API whether it was
  actually created, giving a definitive verified / not-created verdict with an
  actionable reason in the HA panel, instead of inference. Uses `homeassistant_api`
  only when the option is enabled.
- Stale-data detection: a liveness heartbeat distinguishes "bridge alive but
  idle" from "bridge down". When the bridge stops updating, the dashboard shows
  a STALE badge, a banner, and greys the pipeline tiles rather than displaying a
  stale green snapshot.
- The ESP tile lists all active ESP devices, and the wmbusmeters panel shows the
  running wmbusmeters version.
- A dedicated zero-meter LISTEN instance keeps candidate manufacturer/identity
  visible even with meters configured.

### Changed
- `mqtt_mode=auto` now honours an explicitly configured `external_mqtt_host`
  over HA's own Mosquitto — if you configured an external broker, it is used.
- ESP online/offline is driven by live telegram flow as the primary signal;
  optional `diag/*` topics only refine it.

### Fixed
- Honest-witness corrections to the healthcheck: birth-message absence no longer
  raises a false "no HA on broker" alarm; a non-native broker without
  confirmation shows neutral "HA unconfirmed" instead of a green "published" lie;
  the canary is queried via the HA Template API (robust against entity_id
  slugification) rather than a guessed entity_id.
- The bridge waits for the HA MQTT service to return instead of FATAL-looping on
  a broker restart; the heartbeat and ESP / `$SYS` subscribers survive soft
  reloads; pipeline tiles grey out while stale and MQTT-wait log spam is thinned.
- Candidate/preview pipeline hardening: LISTEN reloads are coalesced with a
  trailing debounce to stop discovery churn; candidates are registered from the
  RAW path when meters are configured (closing a discovery dead zone); AES
  classification is preserved on the RAW path (no bogus preview for encrypted
  meters); full manufacturer names are filled from the FLAG code; a `BASH_REMATCH`
  unbound-variable crash and a decoded-JSON reload churn are fixed.
- The WebGUI no longer double-logs "Meter X saved" / "Search X" events.


## 1.5.28

### Added
- detect missing Home Assistant on the MQTT broker (MQTT→HA healthcheck) (eae89c7)


## 1.5.27

### Fixed
- The dashboard ESP pipeline tile could show a contradictory "Offline · N/min"
  state — reporting the receiver offline while telegrams were actively flowing
  through the bridge. The ESP online/silent/offline state was derived solely
  from `sourceDeviceObj.health`, which `webui.py` computes from
  `last_telegram_epoch` in `status_esp_telegram_devices.tsv`; that file is
  written by a separate `mosquitto_sub` in `bridge-lib/13-esp.sh`, so when that
  secondary subscriber lags or reconnects its epoch ages past the offline
  threshold even though the primary pipeline keeps receiving telegrams. Fixed in
  `rootfs/usr/share/wmbus-webui/assets/app.js` (`pipelineHeader`): a live
  telegram rate (`hasLiveRate`, i.e. `rate_current_min > 0`, which `webui.py`
  already zeroes once older than 90 s) now takes precedence for `espOnline` and
  `espSeen`, while the per-device `health` from the tracker TSV only refines the
  state when no live rate is available. Telegrams are the primary sign of life;
  the optional `diag/*` topics remain auxiliary. The per-ESP device list in the
  workspace panel still shows each device's tracker-based health.

### Changed
- The `media_water` label was simplified from "cold water" to "water" in the
  Polish, German, Czech and Slovak translations (`rootfs/usr/bin/i18n.py`), so
  the media name matches meters that report generic water rather than
  specifically cold water.


## 1.5.26

### Fixed
- Parallel LISTEN restarted roughly once per newly discovered candidate, so
  discovering many ids made the supervisor kill and respawn the pipeline ~15
  times in a row (visible as repeated "`.reload_listen` detected, killing
  pid=…" / "pipeline stopped, restarting") and it rarely stayed up long enough
  to decode a preview. Cause: `_request_listen_reload`
  (`bridge-lib/06-candidates.sh`) used a leading-edge cooldown of 10 s, so a new
  candidate arriving more than 10 s after the previous reload triggered an
  immediate reload; discovery of ~29 ids spans several replay cycles, so the
  per-candidate reloads never coalesced. Replaced with a trailing ("settle")
  debounce with a cap: each call stamps `.reload_listen_req`; a single
  background worker (guarded by the atomic `mkdir` of `.reload_listen_pending`)
  fires `.reload_listen` exactly once when either no new request has arrived for
  `RELOAD_SETTLE_SECONDS` (default 6 s, so a short discovery reloads promptly) or
  the worker has run for `RELOAD_MAXWAIT_SECONDS` (default 30 s, so a long burst
  is force-flushed and early candidates still decode). A sustained discovery
  burst now costs roughly one reload per 30 s plus one final settle reload
  instead of one reload per candidate. The supervisor restart loads every
  `meter-preview-<id>` file present on disk, so coalescing drops no candidate;
  the WebGUI manual preview toggle still touches `.reload_listen` directly
  (`webui.py`), bypassing this debounce, and stays immediately responsive.
  `bridge-lib/06-candidates.sh` only.
- AES-encrypted candidate (e.g. NES electricity `00089907`) wrongly showed
  "decoding…" forever and "not analysed" encryption instead of "requires AES",
  after the candidate-discovery fix started registering all manufacturers from
  the RAW path. Cause: the RAW path labelled the type from the DLL device-type
  byte (`map_device_type`), which carries no encryption info, so the
  "encrypted" marker was lost — `candidate_type_requires_aes` stopped matching,
  a preview file was created for a meter that can never decode without a key,
  and the encryption analysis went blank. Fixed in `bridge-lib/05-raw.sh`: a new
  `raw_is_encrypted()` reads the TPL CFG security mode for the common short
  header (CI=0x7A) and appends `encrypted` to the registered type, and the RAW
  registration guard now refuses to downgrade an existing `encrypted`
  classification to the bare device-type label. AES meters again skip preview
  creation and show "requires AES"; plain meters are unaffected and still
  decode. `bridge-lib/05-raw.sh` only.
- Manufacturer column showed only the bare 3-letter FLAG code (e.g. `BMT`)
  instead of the full vendor name (`BMT · BMETERS`) for a meter/candidate first
  seen while another meter was already configured. The full text comes only from
  the LISTEN `manufacturer:` block, which is not emitted once the parallel LISTEN
  has preview files loaded (it leaves "print all" mode), so such ids only ever
  had the RAW M-field code. A small confirmed FLAG-code -> vendor lookup
  (`mfct_name_from_code` in `05-raw.sh`: BMT, NES, SAP, QDS, TCH) now lets the RAW
  path fill the full `(CODE) Vendor` form, which the WebGUI compactor renders as
  `CODE · Vendor`. Unknown codes fall back to the bare code (no regression); the
  existing fill-only-when-empty-or-bare guard upgrades a previously stored bare
  code and never downgrades a full LISTEN name. `bridge-lib/05-raw.sh` only.
- New candidates were not discovered while one or more official meters were
  configured: with no meter the addon listed and decoded the whole replay
  corpus, but with a meter configured only candidates that already had a
  `meter-preview-<id>` file or arrived via the Diehl/SAP RAW special case
  appeared — every other id (e.g. Qundis qwaterv2) was never shown. Root cause:
  `status_raw_candidate_seen()` (`05-raw.sh`) registered a candidate from the RAW
  M-field only for Diehl/SAP (`mfct 0x304C`), assuming the LISTEN path supplies
  the rest. That holds in pure LISTEN mode, but with meters configured the
  primary pipeline runs in DECODE mode (inline candidate parser gated off) and
  the parallel LISTEN — loaded with preview files — leaves "print all telegrams"
  mode, so it never emits the analysis block for unmatched telegrams and new
  candidates are never seen. The RAW path now also registers non-Diehl
  manufacturers when `OFFICIAL_METERS_COUNT > 0`, so the candidate list still
  populates (and previews still decode) with meters configured. Pure LISTEN mode
  (no meters) is unchanged — non-Diehl ids are still left to the LISTEN parser to
  avoid the "auto / inne" clobber. The hardcoded `izarv2` fallback for device
  type `0x07` is now scoped to Diehl/SAP only, so a non-Diehl water meter (also
  type `0x07`, e.g. QDS/BMETERS) registered via the RAW path is no longer
  mislabelled as `izarv2`; LISTEN/decoded-JSON supplies its real driver. The
  existing concrete-driver guard keeps a real classification authoritative and
  prevents reception double-counting. `bridge-lib/05-raw.sh` only.
- Parallel LISTEN parser crashed with `BASH_REMATCH[1]: unbound variable` (under
  `set -u`) from the second telegram block onward, killing and restarting the
  candidate/preview pipeline. In `parse_listen_candidates()` the captured ID was
  read as `${BASH_REMATCH[1]}` *after* `_process_listen_text_block()` had already
  run its own `[[ =~ ]]` internally (via `candidate_update_manufacturer_text` /
  `emit_snippet_if_new`), which clears `BASH_REMATCH`. The match is now captured
  into a local immediately, before the flush call. `bridge-lib/11-listen.sh` only.
- Candidate preview values stayed stuck on "decoding..." while one or more
  official meters were configured, and recovered only after the meters were
  removed. Root cause: `status_candidate_seen_from_json()` (parallel LISTEN,
  added in `db2dfcc`) runs on every decoded preview telegram, but only when
  `OFFICIAL_METERS_COUNT > 0`. It relabels the candidate driver from the decoded
  JSON (e.g. `auto` -> `izarv2`), which rewrote the `meter-preview-<id>` file and
  triggered `_request_listen_reload`, killing and restarting the parallel LISTEN
  pipeline on every telegram. With a multi-meter replay the pipeline never
  stabilised, so previews never finished decoding. A user debug log confirmed
  both the reload churn (`LISTEN supervisor: .reload_listen detected, killing
  pid=...`) and that previews do decode once the driver settles (`unchanged, no
  reload triggered`). `status_candidate_seen()` now takes a 6th `reload`
  argument (default `true`, preserving the text/RAW callers) and the decoded-JSON
  path passes `reload=false`: the driver is still refreshed in the preview file
  for the next natural restart, but no immediate LISTEN reload is triggered, so
  the pipeline is no longer churned. `bridge-lib/06-candidates.sh` and
  `bridge-lib/11-listen.sh` only; preview values, TSV schema, preview states,
  text/RAW reload behaviour and `wmbusmeters` are unchanged.

### Reverted
- Reverted the dedicated zero-meter manufacturer-detection LISTEN instance
  (`bridge-lib/14-detect.sh`). A user reported that after the change, candidate
  preview values stopped decoding while an official meter was configured
  (they reappeared once the meter was removed), a regression that did not exist
  before. A file-level comparison against the pre-modularization monolithic
  `bridge.sh` confirmed the preview decode path (`run_once`,
  `parse_listen_candidates`, `_store_candidate_value`) is byte-identical, so the
  only behavioural difference was the newly added third concurrent
  `wmbusmeters` + `mosquitto_sub` instance. Reverting restores the known-good
  preview behaviour. The bare-vs-full manufacturer healing on the non-concurrent
  paths (`05-raw.sh`, `06-candidates.sh`, `11-listen.sh`) is retained; a
  non-interfering approach for the configured-meter manufacturer case will be
  revisited separately.


## 1.5.25

### Fixed
- Configured-meters-on-air panel showed a bare 3-letter manufacturer code
  (e.g. `NES`) instead of the compact display name
  (`NES · NORA ELK MALZ SAN ve TIC`) after upgrading from a pre-1.5.22
  installation, and the code never healed even after hundreds of telegram
  receptions. Two causes were addressed in `bridge-lib`:
  - `candidate_fill_manufacturer_code()` (RAW hex path, `05-raw.sh`) only
    filled column 9 of `status_candidates.tsv` when it was empty. A legacy
    bare 3-letter code left by an old installation is non-empty, so the
    write was skipped on every restart. It now also matches `/^[A-Z]{3}$/`
    so a legacy code is treated like an empty cell. Full-text names do not
    match the pattern and are never downgraded.
  - `_process_listen_text_block()` (parallel LISTEN, `11-listen.sh`) only
    wrote the manufacturer after an early `[[ -n id && -n driver ]]` guard.
    `wmbusmeters` omits the `driver:` line for telegrams it cannot decrypt
    or recognise, so the full manufacturer text captured by the LISTEN text
    path never reached the TSV. A new `candidate_update_manufacturer_text()`
    in `06-candidates.sh` now writes the full text form before the driver
    guard, overwriting only an empty or bare 3-letter column. It never
    creates rows and never touches reception stats or events.

## 1.5.24-dev

### Changed
- Maintenance refactor: split helper functions from the large
  `rootfs/usr/bin/bridge.sh` runtime script into sourced modules under
  `rootfs/usr/bin/bridge-lib/`. The refactor keeps `bridge.sh` as the
  Home Assistant/Docker entrypoint and leaves startup initialization,
  wrapper integration and `run_once` orchestration in `bridge.sh`.
- The extracted modules now group existing bridge logic by responsibility:
  logging/utilities, options parsing, atomic TSV helpers, status files, raw
  telegram helpers, candidate lifecycle, meter file generation and value
  selection, Home Assistant Discovery helpers/publishing, SEARCH, Parallel
  LISTEN, MQTT pipeline helpers and ESP subscribers.
- This development cycle is intended to be behaviour-preserving. WebUI status
  file formats, MQTT topics, Home Assistant Discovery identifiers, reload
  markers and generated `wmbusmeters` configuration are not intentionally
  changed by the modularization.

### Fixed
- Hardened bridge module loading so `bridge.sh` resolves `bridge-lib` from
  `${BASH_SOURCE[0]}` instead of `$0`, preserving execution through wrappers,
  direct script calls and PATH-based smoke tests.
- Updated the IZAR fixture test lookup so it validates the extracted meter
  helper in `bridge-lib/07-meters.sh` after the refactor.

## 1.5.22-dev

### Fixed
- Candidate `manufacturer` (column 9 of `status_candidates.tsv`) no longer
  stays empty when official meters are configured. Once a candidate has a
  `meter-preview-<id>` file, the parallel LISTEN instance decodes its
  telegrams to JSON — which carries no manufacturer name — and
  `status_candidate_seen_from_json()` updated the row without it, so
  persisted candidates (and the configured-meters panel that borrows the
  candidate's manufacturer) showed a blank `Producent`. Every raw telegram
  carries the wMBus M-field, so `status_raw_candidate_seen()` now decodes
  the 3-letter EN 13757 manufacturer code via the new
  `mfct_code_from_raw_hex()` and fills it into an existing candidate row
  through `candidate_fill_manufacturer_code()` only when the column is
  empty. The full text name from the LISTEN text path stays authoritative
  (a later text update still overwrites the bare code via
  `_upsert_candidate_row`), no candidate rows are created, and reception
  stats / events are untouched (no double counting). `bridge.sh` only.

## 1.5.21-dev

### Fixed
- Correct `total_m3` selection for IZAR meters: the bridge now prefers
  the current `total_m3` field over `last_month_total_m3` when both are
  present in the decoded JSON. Previously, the historical monthly value
  was selected over the live reading in some field-ordering situations.

- Preserve preview context after a candidate is added to the
  configuration: the cached preview value and state
  (`status_candidate_preview_state.tsv`) are now kept visible in the
  pending-meters panel until the first official DECODE telegram arrives,
  instead of being cleared immediately on pipeline reload.

- Self-heal orphaned `meter-preview-*` files: when a candidate is
  officially configured, the bridge now removes its
  `meter-preview-<id>` file and the `.preview_attempts/<id>` counter
  on every restart-loop iteration. A guard in
  `ensure_candidate_autodecode()` also prevents the file from being
  re-created for officially configured meters on subsequent telegrams.
  `status_candidate_values.tsv` and `status_candidate_preview_state.tsv`
  are deliberately preserved.

### Added
- Manual "Usuń podgląd" / Cancel preview button in the new SPA WebGUI:
  available in the candidates table, the pending-meters section, and the
  configured-meters-on-air panel whenever `preview_active` is true.
  Calls the existing `/api/cancel-preview` endpoint.

- Regression tests for IZAR current total selection, covering real
  user-reported HEX telegrams where `total_m3` and
  `last_month_total_m3` co-exist in the decoded output.

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

# Architecture & Internals

Developer / maintainer reference for the **wMBus MQTT Bridge** Home Assistant
add-on. This documents *how it works* — the runtime topology, the bridge
scripts, the on-disk state files, the soft-reload mechanism, the dashboard data
model, the ESP diagnostics contract, and the dev→stable release flow.

This is **not** user onboarding (install / add a meter / troubleshoot) — that
lives in `README.md` / `docs/README.*.md`. Everything here is derived from the
actual code under `rootfs/`, `config.yaml`, `docker/` and `.github/`.

---

## 1. What the add-on is

A thin, robust bridge that turns **RAW wM-Bus telegrams** (hex, published over
MQTT by one or more ESP receivers running the companion ESPHome firmware) into
**decoded meter readings** and **Home Assistant MQTT Discovery** entities, plus
a read-only diagnostic dashboard (Ingress).

The add-on does **not** talk to radio hardware itself. The ESP nodes do the RF
work and publish hex frames to `wmbus/<device>/telegram`; the add-on feeds those
frames into [`wmbusmeters`](https://github.com/wmbusmeters/wmbusmeters) over
`stdin:hex` and republishes the decoded JSON + HA discovery.

```
   wM-Bus meters ))) ┌─────────┐  MQTT   ┌──────────────────────────────┐   MQTT   ┌────┐
                     │  ESP(s) │ ──────► │  add-on                      │ ───────► │ HA │
                     │ SX127x/ │ wmbus/  │  wmbusmeters (stdin:hex)     │ state +  │    │
                     │ SX126x/ │ +/tele  │  + HA discovery + dashboard  │ discovery└────┘
                     │ CC1101  │ gram     └──────────────────────────────┘
                     └─────────┘
```

---

## 2. Process model (s6)

The HA base image uses **s6** as init. Two long-running services are declared:

| Service (`rootfs/etc/services.d/…/run`) | Starts |
|---|---|
| `wmbus_mqtt_bridge` | `run.sh` → core `bridge.sh` |
| `wmbus_webui`       | `webui.py` (read-only dashboard on port `8099`, Ingress) |

- **`run.sh`** — entrypoint: resolves MQTT mode (`auto`/`ha`/`external`), waits
  for the broker (bounded retry, not a FATAL loop), then `exec`s `bridge.sh`.
  `auto` resolution order: **1)** `external_mqtt_host` when set (wins even when
  HA's Mosquitto is up — a typed address is intent); **2)** an **instant**
  Supervisor `mqtt` service check (registered only by the official Mosquitto
  add-on); **3)** `scan_broker_addons` — a quick `probe_mqtt` scan of
  well-known broker add-on hostnames (`core-mosquitto`, `a0d7b954-emqx`);
  **4)** only when both found nothing: the full bounded `wait_for_ha_mqtt`
  (~60 s — still needed to ride out a restarting Mosquitto), then one
  re-scan. Scan-before-wait matters: the Supervisor services API cannot see
  brokers that do not register the `mqtt` service (e.g. community EMQX), so
  the old wait-first order burned a dead minute on every start of an
  EMQX-only host (measured 65 s boot-to-bridge; now seconds). Each probe is
  one bounded `mosquitto_sub -E` CONNECT+SUBSCRIBE, using
  `external_mqtt_username/password` when set, anonymously otherwise. A CONNACK "not authorised" means the broker EXISTS: the FATAL
  then names the detected host and the missing credential fields instead of a
  generic "no MQTT service". Explicitly configured brokers (`external` and
  auto-with-host) get the same probe as a non-fatal startup diagnostic
  (address vs credentials) — behaviour is unchanged, `bridge.sh` still
  retries. Every FATAL exit first writes `/data/status_run_error.txt`
  (`code<TAB>detail`; codes: `auth_required`, `no_broker`, `no_ha_service`,
  `external_host_missing`), cleared on successful resolution — `webui.py`
  exposes it as `run_error` (only while the bridge heartbeat is dead) and
  `app.js` renders it as a red actionable banner instead of the generic
  stale-data one, so a user who never opens the add-on log still learns
  exactly which config field is missing. The RUNTIME counterpart is
  `/data/status_broker_error.txt` (`auth_rejected`/`unreachable` +
  `host:port`), written by `wait_for_mqtt` while the bridge keeps running and
  cleared on the first successful publish or received telegram — rendered as
  its own banner regardless of the heartbeat. On `auth_rejected` every
  reconnect loop also backs off (`_sub_reconnect_sleep`, exponential to a
  120 s cap; `wait_for_mqtt` retries 5× slower): a wrong password once drove
  ~200 connections/min against EMQX from the ~10 instant-retry subscriber
  loops (observed live, throttled in the broker's own log).
- **`docker/entrypoint.sh`** — used **only** in standalone Docker (non-HA); it
  starts the WebGUI and the bridge directly. In HA, s6 does this, so the
  entrypoint is not on the path. (This file must track dev — it previously
  drifted on stable; see §11.) The entrypoint stays PID 1 (**no exec**) with a
  TERM/INT trap that exits: the WebUI restart button in Docker mode SIGTERMs
  PID 1 (delayed `os.kill` in `restart_addon_via_supervisor`), the container
  exits and the Docker restart policy brings it back (compose example:
  `restart: unless-stopped`; without a policy the button degrades to a stop).
  Signalling bridge.sh directly would not work: its own TERM trap
  (`stop_listen_instance`) cleans up but does not exit, and SIGKILL to PID 1
  from inside the namespace is ignored by the kernel. On boot the entrypoint
  also runs the same one-shot broker probe as run.sh's
  `diagnose_configured_broker` (verified / rejected credentials / no
  response) — bridge.sh's `wait_for_mqtt` swallows mosquitto's error output,
  so this is the only place the log states WHY a broker shows offline.
- **`webui.py`** is intentionally **read-only over the pipeline state**: it reads
  the `status_*` files written by `bridge.sh` and serves a model to `app.js`. It
  only *writes* `options.json` via the Supervisor API for the add/remove/search
  actions (see §10).

---

## 3. The bridge: `bridge.sh` + `bridge-lib/*.sh`

`bridge.sh` runs under `set -euo pipefail` and sources a numbered library set
(load order matters — later libs use earlier helpers):

| Lib | Responsibility |
|---|---|
| `00-logging.sh` | `log` / `warn`, event log (`status_add_event`) |
| `01-utils.sh`   | `epoch_now`, `iso_now`, JSON helpers, misc |
| `02-config.sh`  | read add-on options from `OPTIONS_JSON` (`json_get*`) |
| `03-tsv.sh`     | `_tsv_upsert` — **atomic** TSV row upsert via `flock` + `mktemp` + `mv` |
| `04-status.sh`  | event log, `status_record_seen` / `status_seen_stats`, raw counters, `write_status_json` |
| `05-raw.sh`     | RAW frame handling, `normalize_meter_id`, Diehl/SAP IZAR special case |
| `06-candidates.sh` | candidate (discovered-but-unconfigured) tracking + preview |
| `07-meters.sh`  | build `wmbusmeters.d/*` from configured meters, per-meter stats |
| `08/09-discovery*.sh` | HA MQTT Discovery payloads + publish/expire |
| `10-search.sh`  | SEARCH mode (find a meter by expected m³ value) |
| `11-listen.sh`  | the **parallel LISTEN** wmbusmeters instance (start/stop, `LISTEN_PID`) |
| `12-pipeline.sh`| pipeline orchestration helpers |
| `13-esp.sh`     | ESP background subscribers (telegram tracker + diag topics) |

`bridge.sh` defines all `STATUS_*` paths (under `BASE`, default `/data`), starts
the heartbeat (`HEARTBEAT_PID`) and ESP subscribers, then enters the
`restart_on_exit` loop around `run_once()`.

### 3.1 Two wmbusmeters instances (DECODE + parallel LISTEN)

This is the single most important runtime fact:

- **DECODE instance** — `wmbusmeters` configured with the user's meters
  (`wmbusmeters.d/meter-*`). Decodes configured meters → publishes state +
  discovery. Records reception under `kind=meter`.
- **Parallel LISTEN instance** (`11-listen.sh`) — a *second*, zero-meter
  `wmbusmeters` permanently in pure listen mode. It keeps **candidate discovery**
  and **per-candidate preview** alive even when meters are configured (otherwise
  discovery would stall once the DECODE instance has meters). Records reception
  under `kind=candidate`. Runs as `LISTEN_PID`, **survives soft reloads**.

Both instances receive the same telegrams; a single physical transmission is
therefore logged twice (~1 s apart) — see §6.3 for how stats de-duplicate it.

---

## 4. Soft reload (the robustness core — do not regress)

Adding/removing a meter (or toggling search) must apply **without restarting the
add-on**. The mechanism:

1. The WebUI writes `options.json` and touches `${BASE}/.reload_pipeline`.
2. `run_once()` (and a watcher inside it) sees `.reload_pipeline`, tears down the
   **decode** pipeline, and returns cleanly (rc=0).
3. The `restart_on_exit` loop in `bridge.sh` (`RESTART_ON_EXIT`, default true)
   re-reads `options.json`, rebuilds `wmbusmeters.d/*`, and respawns `run_once`
   after ~2 s (`"Pipeline exited cleanly (rc=0), reloading in 2s..."`).

### 4.1 PID exclusions (critical)

When `run_once` tears down, its watcher kills child PIDs **except** the
long-lived workers that must survive a reload:

```
exclude: BASHPID (self), LISTEN_PID, HEARTBEAT_PID, ESP_SUBSCRIBER_PIDS
```

(see `bridge.sh` ~lines 483–498). **Any new long-lived background worker MUST
append its PID to `ESP_SUBSCRIBER_PIDS`** (or be similarly excluded), or a soft
reload will silently kill it.

### 4.2 LISTEN reload debounce

The parallel LISTEN instance is reloaded separately and **debounced** via
`.reload_listen` / `.reload_listen_req` and an atomic pending marker
(`.reload_listen_pending`, created with `mkdir`). Orphaned pending markers are
cleaned at startup (`bridge.sh:165/382`). This coalesces rapid discovery-driven
reloads into one trailing reload (stops "discovery churn").

---

## 5. On-disk state (`/data/status_*`)

`bridge.sh` is the single writer of the pipeline state; `webui.py` is a reader.
All TSV writes go through `_tsv_upsert` (`flock` + `mktemp` + atomic `mv`);
counter/JSON files use atomic `mv` too. Files **truncated at startup** (`: >`)
hold "this run only" data; the rest persist in `/data`.

| File | Shape | Holds |
|---|---|---|
| `status.json` | JSON | top-level pipeline status (mqtt connected, counts, discovery, last events) |
| `status_meters.tsv` | TSV | configured meters: id, name, driver, media, value, last_seen, seen_count, avg_interval_s, seen_15m, seen_60m, value_parts |
| `status_candidates.tsv` | TSV | discovered-but-unconfigured meters (same stats shape) |
| `status_seen.tsv` | TSV | `id <TAB> kind <TAB> epoch` per received telegram (tail-capped 5000); source for 15m/60m/interval |
| `status_events.tsv` | TSV | rolling event log (tail 40) |
| `status_raw_count.txt` / `status_last_raw_seen.txt` | text | RAW telegram counter + last-seen (file-backed; subshell-safe) |
| `status_recent_raw.tsv` | TSV | recent RAW hex (tail 200), for candidate RAW lookup |
| `status_candidate_analysis.tsv` / `_raw.tsv` / `_values.tsv` / `_preview_state.tsv` | TSV | candidate encryption analysis, RAW, decoded preview values, preview state machine |
| `status_meter_last_json.tsv` | TSV | `id <TAB> ts <TAB> json` — last full decoded JSON per configured meter (written by `status_meter_seen`); feeds the WebUI "published fields" expander (rendered only in the action-enabled meter tables — METERS/RECEIVING — where the toggle button lives; never in the read-only PANEL dashboard) |
| `.discovery_doctor_request` / `status_discovery_doctor.json` | flag / JSON | Discovery Doctor: webui touches the flag, the heartbeat ticker runs `discovery_doctor_probe` (broker probe via `mosquitto_sub`) and writes the result |
| `.factory_reset_request` | flag | Factory reset (Settings → "Reset add-on"): webui empties `options.json` (`meters=[]`) and writes the removed ids here (one per line). The heartbeat ticker consumes the flag, runs `clear_meter_discovery` per id (empty retained config → entities vanish from HA), wipes runtime state (`status_*`/`search_*`/`seen_ids.txt` + preview meter files) and soft-reloads the pipeline (`.reload_pipeline`), returning the add-on to its post-install state. `options.json`, the wmbusmeters binary and the `etc/listen/preview` config dirs are left intact |
| `status_meter_key_problem.tsv` | TSV | `id <TAB> reason <TAB> ts` — AES key problem (`key_missing` / `key_invalid`) detected by `status_detect_key_problem` from wmbusmeters warnings (which then permanently ignores the meter until reload); cleared by the next decoded JSON |
| `status_ha_presence.txt` / `status_broker_info.txt` / `status_ha_verification.txt` | text | MQTT→HA healthcheck signals (see [memory: mqtt-ha-healthcheck]) |
| `status_heartbeat.txt` | text | liveness ticker (WebUI STALE threshold) — must survive soft reload |
| `status_esp_telegram_devices.tsv` | TSV | per-ESP device tracker: name, last_telegram_epoch, topic, count (**truncated at startup**) |
| `status_esp_health.json` / `status_esp_meters.json` | JSON map | per-ESP `/health` pulse and `/meters` flags (keyed by device) |
| `status_esp_meter_snapshot.json` / `status_esp_meter_window.json` | JSON map | per-ESP per-meter reception windows (diag, opt-in) |
| `status_wmbusmeters_version.txt`, `status_official_meters_count.txt`, `status_rate_history.tsv`, `status_bridge_start.txt`, `status_discovery_published.flag` | misc | version, configured-count, rate sparkline, start time, discovery-published flag |

The WebUI driver comparison endpoint is deliberately read-only. For a configured
meter it resolves the latest RAW frame from `status_recent_raw.tsv`; for an
unconfigured candidate it can use `status_candidate_raw.tsv`. It then runs short
`wmbusmeters --format=json` forced-driver decodes (`stdin:hex`) with the saved or
typed AES key and shows the decoded fields side by side. The result is advisory:
`wmbusmeters` auto detection and "more fields" are hints, not proof that the
driver is correct.

The Settings view also exposes an **editable options form**. Its fields are not
hand-coded: `config_options_spec()` parses the `schema:`/`options:` blocks from
the baked `config.yaml`, so the form can never drift from HA's own config schema
(add an option to `config.yaml` and it appears automatically). `POST
/api/save-config` validates each value against its schema type and persists via
the Supervisor API (`save_config_options`), exactly like the meter edits. Secret
fields (`external_mqtt_password`) are write-only: the value is never sent to the
browser and a blank input keeps the current one. As with the HA config tab, core
options take effect only after an add-on restart.

`options.json` (the add-on config) is **owned by Supervisor**, not the bridge.
Supervisor rewrites it from its DB on every start; the bridge only reads it (see
§10 for why a file-only write does not survive a restart).

---

## 6. Reception counting (`status_seen.tsv`)

### 6.1 Recording
`status_record_seen(id, kind)` appends `id<TAB>kind<TAB>epoch`, de-duping
same-kind writes within 2 s, then tail-caps the file to 5000 lines.

### 6.2 Stats
`status_seen_stats(id)` computes `count / avg_interval_s / seen_15m / seen_60m`
from the rows for that id. Windows: `seen_15m` = telegrams in the last 900 s,
`seen_60m` = last 3600 s.

### 6.3 Cross-kind continuity (do not regress)
Stats are counted **across both kinds** (`meter` + `candidate`) for an id, with a
**~2 s cross-kind de-dup** (the DECODE and LISTEN instances each log the same
physical transmission a second apart). This keeps a meter's counters **continuous
when it is promoted candidate→meter** (the `kind` switches) without double
counting. The stream is processed in append (time) order; a `>= 0` guard
tolerates rare cross-process interleave.

---

## 7. ESP integration

### 7.1 Liveness (always-on)
The **telegram device tracker** (`13-esp.sh`) subscribes to `RAW_TOPIC`
(`wmbus/+/telegram`) and records each distinct ESP device + last-seen + count to
`status_esp_telegram_devices.tsv`. This is the **source of truth for "which ESPs
are alive right now"** — telegrams arrive live (not retained), so dead ESPs age
out. Works even with ESP diagnostics fully off.

### 7.2 Always-on pulse + flags (firmware, independent of `diagnostic_mode`)
Every 60 s the firmware publishes, regardless of diag level:
- `wmbus/<dev>/health` → `{uptime_s, rx_total, sec_since_last_rx, rssi, chip, listen_mode}` (sentinel `sec_since_last_rx=-1` = nothing heard yet; `rssi=1` = no valid sample)
- `wmbus/<dev>/meters` → `{target, highlight[]}` (meters the ESP is flagged for)

### 7.3 Opt-in diagnostics (`diagnostic_mode: low|normal|debug|dev`)
- `wmbus/<dev>/diag/summary` (every 60 s) and `…/summary_15min` / `…/summary_60min`
- `…/diag/meter_snapshot` — batch of per-highlight-meter reception (every 15 min)
- `…/diag/meter/<id>/<mode>/window/<trigger>` — per-meter reception window; triggers `count` (every N telegrams), `time`, `summary_15min`, `summary_60min`

The add-on subscribes to all of these via per-device background subscribers in
`13-esp.sh`, writing keyed-per-device JSON maps.

> **`set -euo pipefail` gotcha (recurring):** a read-modify-write subscriber that
> does `var="$(cat "$FILE" 2>/dev/null)"` aborts the subshell when the file does
> not exist yet (the failed `cat` propagates non-zero under `set -e`), so the file
> is never created. **Every such `cat` must end with `|| true`.**

---

## 8. Dashboard data model (`webui.py` + `app.js`) — honest-witness

`webui.py` builds a JSON model from the `status_*` files; `app.js` is a small SPA
that patches the DOM with **morphdom**. The governing principle is
**honest-witness** (see [memory: honest-witness-principle]): *the dashboard
reports facts and never paints green over absent data.*

Concretely:
- Missing/stale signals degrade to **neutral**, never a green "all good".
- A liveness **heartbeat** distinguishes "bridge idle" from "bridge down" → STALE
  badge + grey tiles when the snapshot is stale.
- **Reception is the truth signal; RSSI was removed** — field testing showed RSSI
  is not comparable across boards (FEM/antenna dependent). Per-meter quality =
  **reception %** from the opt-in diag windows.
- **Per-meter status is rhythm-adaptive**: derived from the meter's own observed
  `avg_interval_s` (fallback 300 s, floor 8 s) — online ≤3×, overdue ≤12×, beyond
  that **neutral "quiet", never a red alarm** (a meter is passive; prolonged
  silence is ambiguous — night/away/battery). This also removes night/weekend
  false alarms without hardcoding quiet hours.
- **Per-ESP reception** (`📡 ESP` flag + `📶 <esp> N% · count`) shown in the
  reception column; the discriminating sensitivity signal is **coverage** (which
  meters a board hears at all), not the raw count (cumulative-since-boot, not
  comparable) nor the % (saturates ~100 % for any heard meter).
- morphdom `onBeforeElUpdated` skips **only focused INPUT/TEXTAREA/SELECT** (not
  buttons) — skipping any focused element froze clicked pipeline tiles.

`i18n.py` holds 5 languages (en/pl/de/cs/sk); `app.js` calls `t(key, fallback)`.

---

## 9. HA Discovery & MQTT→HA healthcheck

- Decoded meters are published as HA MQTT Discovery entities (prefix configurable,
  retained). `discovery_published` is file-flagged (`status_discovery_published.flag`)
  so the frequent raw-counter subshell can't clobber it.
- Discovery is emitted before the matching state payload. With the default
  `state_retain=false`, this keeps the retained config on the broker before the
  non-retained state payload for the same telegram is sent.
- **Per-field availability** (`09-discovery.sh`, `emit_discovery_from_json`): every
  entity's config carries an availability template on its own state topic —
  `{{ 'online' if value_json.get('<key>') is not none else 'offline' }}`. A field
  missing from the latest (partial) telegram turns only that entity `unavailable`
  instead of leaving a stale/false value (local analog of upstream issue #1922).
  `value_template` uses the warning-free `value_json.get(...) | default(none)`.
  No `availability_mode` is needed — this is the only availability source.
- **`expire_after` self-tunes**: 2× the meter's observed average telegram interval
  (from `status_seen_stats`), floor 3600 s, rounded to whole minutes; the rounded
  value is part of the discovery cache key, so a changed interval republishes the
  config. The in-memory cache is empty on restart, so existing installs pick up
  config changes automatically.
- **Status diagnostic entities** (`09-discovery.sh`, `emit_discovery_from_json`): the
  string `status` field never matches the numeric field filter, so it is surfaced
  explicitly when present — a `sensor` (`entity_category: diagnostic`) with the raw
  text and a `binary_sensor` (`device_class: problem`, `entity_category: diagnostic`)
  whose template is `{{ 'ON' if value_json.get('status') not in [none, 'OK', ''] else
  'OFF' }}`. Passthrough only: the text is verbatim from wmbusmeters (e.g. `elf2`
  decodes the full ErrorFlags bitfield, `elf` only the TPL status); the sole literal
  is the `OK` baseline. Both reuse the per-field availability template and the shared
  `expire_after`, are rate-limited via `DISCOVERY_SENT_FIELD`, and are cleared
  (including the `binary_sensor/` topic) by `clear_meter_discovery` on meter removal.
- **MQTT→HA healthcheck**: the add-on detects publishing to a broker HA does not
  consume. HA presence is reported honestly — confirmed on the native broker
  (`core-mosquitto` / `mqtt_mode=ha`) or via a seen `online` birth message; the
  MQTT tile shows broker identity from `$SYS`.
- **`verify_ha_entities`** (opt-in): publishes a hidden canary sensor and asks the
  HA Core API (Template lookup by unique icon, robust to entity_id slugification)
  whether HA actually created it. Needs `homeassistant_api: true` (granted only
  when enabled).
- **Discovery Doctor** (SETTINGS view): on-demand checklist for the "telegrams
  reach the broker but no entities in HA" class of reports. The WebUI touches
  `.discovery_doctor_request`; the bridge heartbeat ticker (which has the MQTT
  credentials) runs `discovery_doctor_probe` (`09-discovery.sh`): a bounded
  `mosquitto_sub` on `<prefix>/status` (retained HA birth proves HA listens on
  this prefix on this broker) and on `<prefix>/sensor/wmbus_<id>/+/config` per
  configured meter (retained configs arrive immediately on subscribe; count +
  one sample payload). webui's POST `/api/discovery-doctor` waits ≤25 s for
  the JSON result and merges static checks (mqtt connected, discovery
  settings). "Force re-discovery" = the existing pipeline soft reload — the
  in-memory `DISCOVERY_SENT_FIELD` cache resets, so configs republish with the
  next telegrams.

---

## 10. Options persistence (why a meter can "vanish")

The WebUI add/remove/search actions persist by **POST `http://supervisor/addons/self/options`**
(Supervisor then writes `options.json` and it survives restarts). A direct write
to `/data/options.json` does **not** persist — Supervisor overwrites it from its
DB on the next start.

`urllib.urlopen` **raises `HTTPError` on a 4xx**, so a Supervisor schema rejection
must be caught explicitly and its **body read and surfaced** (otherwise the cause
is invisible and the add silently falls back to a file-only write that vanishes on
restart). The schema field `meters[].type` is a **free string** (`str`), never a
driver enum: an enum goes stale every time wmbusmeters adds a driver (e.g.
`izarv2`), and Supervisor then 400s valid meters. wmbusmeters validates the driver
at decode time.

---

## 11. dev → stable promote

Two repos: **dev** (`…-dev`, this repo) and **stable** (`homeassistant-wmbus-mqtt-bridge`).
`.github/workflows/promote.yaml` (manual `workflow_dispatch`, in the **stable**
repo) makes stable a copy of dev **minus the dev identity**:

- **Synced from dev verbatim:** `rootfs/`, `Dockerfile`, `docker/`, `translations/`,
  `wmbusmeters-mqtt-stdin`, `README.md`, `THIRD_PARTY_NOTICES.md`, `docs/` (minus
  `docs/CLAUDE_HANDOFF.md`), and `config.yaml` (adopted wholesale, then identity
  restored).
- **Never synced (stable-specific / infra):** `.github/` (the workflow lives
  there — copying dev would delete it), `repository.yaml` (name/url), the
  `config.yaml` identity fields (name/slug/image/panel_title/description), `LICENSE`.
- **CHANGELOG** is auto-consolidated: the cycle's per-build `## X.Y.Z-dev.NN`
  sections are merged into one `## X.Y.Z`, de-duped, marker stripped.

> **Lesson:** promote originally synced only `rootfs/Dockerfile/translations`, so
> `config.yaml` and `docker/` **drifted** — that is how the `izarv2` enum and the
> standalone-Docker entrypoint went stale on stable while dev was already fixed.
> A dev fix that lives outside the synced set never reaches users. Since then the
> `standalone-boot` CI job (§12) boots `docker/entrypoint.sh` on every dev build,
> so a broken standalone entrypoint blocks the version bump instead of drifting
> silently.

---

## 12. wmbusmeters build pin & decode smoke gate

- **Pin:** the Dockerfile builds wmbusmeters from a fixed commit
  (`ARG WMBUSMETERS_COMMIT`), not master HEAD. Rationale: upstream's codebase
  restructuring (wmbusmeters/wmbusmeters#1940) broke master compilation
  (2026-06-11) and any upstream breakage propagated straight into our CI.
  The clone stays **full** (not `--depth 1`): the Makefile derives the binary's
  version string via `git describe --tags`.
- **Bumping the pin is a deliberate act**: change `WMBUSMETERS_COMMIT`, push, and
  let the `decode-smoke` CI job validate the new decoder against the golden
  fixtures before any version is published.
- **Monthly bump automation** (`.github/workflows/wmbusmeters-pin-bump.yml`): on
  the 1st of each month the workflow compares the pin against upstream's latest
  **release tag** (`X.Y.Z` — deliberately not master HEAD) and opens a bump PR
  when it moved. Merging stays a human decision; validation happens on the push
  to main after merge, via the same `decode-smoke` + `standalone-boot` gates as
  a manual bump. No PR is opened when the pin is current or the bump branch for
  that tag already exists.
- **`decode-smoke` (`.github/workflows/build.yaml`)**: after the arch images are
  built, the job runs `tests/test_decode_smoke.sh` **inside the freshly built
  amd64 image**. The `bump` job depends on it — a failed smoke-test means
  `config.yaml` keeps the previous version and HA users never see the broken
  image (which still lands in GHCR, unversioned).
- **Fixtures** (`tests/fixtures/golden.tsv`): `<dir>/<id> TAB <driver> TAB <key>`;
  key is `NOKEY`, a literal 32-hex key (**only for already-public keys**, e.g.
  upstream driver test keys) or an env-var name (private keys via repo secrets —
  never in git). `<dir>/<id>.hex` is the raw telegram, `<dir>/<id>.golden.json`
  the expected decode (jq -S normalized, `timestamp`/`name` dropped). All
  committed fixtures are public (upstream driver tests + the public replay
  corpus). Meter ids are lowercased before the wmbusmeters call — id matching is
  case-sensitive.
- **`standalone-boot` (`.github/workflows/build.yaml`)**: boots the amd64 image
  the way the documented Docker-standalone deployment does — default entrypoint
  `/usr/bin/docker-entrypoint.sh` next to an anonymous Mosquitto reachable as
  host `mosquitto` (the target of the entrypoint's generated default
  `options.json`). Asserts from the container logs that the entrypoint generated
  `/config/options.json`, that `bridge.sh` connected to the broker
  (`MQTT broker ready`), and that the container is still running. Like
  `decode-smoke`, the `bump` job depends on it, so a broken standalone boot
  never becomes a published version. Exists because nobody tests this mode by
  hand (§11 lesson).
- **Regenerating goldens** (after an accepted decode change): build wmbusmeters
  at the pinned commit, re-run the fixtures, commit the new `.golden.json`; or
  temporarily set `GOLDEN_REQUIRE=0` in the workflow — missing goldens are then
  printed by the job instead of failing it.

---

## 13. Conventions

- **Commits:** Conventional Commits (`fix:`/`feat:`/`docs:`/`chore:`/`refactor:`/`test:`),
  no AI attribution footer. Public repo — write for external reviewers.
- **CHANGELOG:** per-build `## X.Y.Z-dev.NN` sections during a dev cycle
  (prepend-only, immutable); promote consolidates them into `## X.Y.Z`.
- **Version source of truth:** `config.yaml` `version:` — never trust a remembered
  version; the CI `bump` job derives `X.Y.Z-dev.<run_number>`.
- **Validation before push (bash):** `bash -n` + `shellcheck` on the touched
  scripts, `git diff --check`. Python: `ast.parse`/`py_compile`.

---

*This file is a living internals reference. When the runtime behaviour changes
(new state file, new ESP topic, reload semantics, promote scope), update the
relevant section here rather than burying internals in the user README.*

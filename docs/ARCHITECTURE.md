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
- **`docker/entrypoint.sh`** — used **only** in standalone Docker (non-HA); it
  starts the WebGUI and the bridge directly. In HA, s6 does this, so the
  entrypoint is not on the path. (This file must track dev — it previously
  drifted on stable; see §11.)
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
| `status_ha_presence.txt` / `status_broker_info.txt` / `status_ha_verification.txt` | text | MQTT→HA healthcheck signals (see [memory: mqtt-ha-healthcheck]) |
| `status_heartbeat.txt` | text | liveness ticker (WebUI STALE threshold) — must survive soft reload |
| `status_esp_telegram_devices.tsv` | TSV | per-ESP device tracker: name, last_telegram_epoch, topic, count (**truncated at startup**) |
| `status_esp_health.json` / `status_esp_meters.json` | JSON map | per-ESP `/health` pulse and `/meters` flags (keyed by device) |
| `status_esp_meter_snapshot.json` / `status_esp_meter_window.json` | JSON map | per-ESP per-meter reception windows (diag, opt-in) |
| `status_wmbusmeters_version.txt`, `status_official_meters_count.txt`, `status_rate_history.tsv`, `status_bridge_start.txt`, `status_discovery_published.flag` | misc | version, configured-count, rate sparkline, start time, discovery-published flag |

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
- **MQTT→HA healthcheck**: the add-on detects publishing to a broker HA does not
  consume. HA presence is reported honestly — confirmed on the native broker
  (`core-mosquitto` / `mqtt_mode=ha`) or via a seen `online` birth message; the
  MQTT tile shows broker identity from `$SYS`.
- **`verify_ha_entities`** (opt-in): publishes a hidden canary sensor and asks the
  HA Core API (Template lookup by unique icon, robust to entity_id slugification)
  whether HA actually created it. Needs `homeassistant_api: true` (granted only
  when enabled).

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
> A dev fix that lives outside the synced set never reaches users.

---

## 12. Conventions

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

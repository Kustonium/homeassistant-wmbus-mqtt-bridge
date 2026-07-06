#!/usr/bin/env bash
set -euo pipefail

# ── Source modules ────────────────────────────────────────────
BRIDGE_SCRIPT_PATH="${BASH_SOURCE[0]}"
BRIDGE_SCRIPT_DIR="${BRIDGE_SCRIPT_PATH%/*}"
[[ "${BRIDGE_SCRIPT_DIR}" == "${BRIDGE_SCRIPT_PATH}" ]] && BRIDGE_SCRIPT_DIR="."
BRIDGE_SCRIPT_DIR="$(cd "${BRIDGE_SCRIPT_DIR}" && pwd)"
BRIDGE_LIB_DIR="${BRIDGE_SCRIPT_DIR}/bridge-lib"
# shellcheck source=bridge-lib/00-logging.sh
source "${BRIDGE_LIB_DIR}/00-logging.sh"
# shellcheck source=bridge-lib/01-utils.sh
source "${BRIDGE_LIB_DIR}/01-utils.sh"
# shellcheck source=bridge-lib/02-config.sh
source "${BRIDGE_LIB_DIR}/02-config.sh"
# shellcheck source=bridge-lib/03-tsv.sh
source "${BRIDGE_LIB_DIR}/03-tsv.sh"
# shellcheck source=bridge-lib/04-status.sh
source "${BRIDGE_LIB_DIR}/04-status.sh"
# shellcheck source=bridge-lib/05-raw.sh
source "${BRIDGE_LIB_DIR}/05-raw.sh"
# shellcheck source=bridge-lib/06-candidates.sh
source "${BRIDGE_LIB_DIR}/06-candidates.sh"
# shellcheck source=bridge-lib/07-meters.sh
source "${BRIDGE_LIB_DIR}/07-meters.sh"
# shellcheck source=bridge-lib/08-discovery-helpers.sh
source "${BRIDGE_LIB_DIR}/08-discovery-helpers.sh"
# shellcheck source=bridge-lib/09-discovery.sh
source "${BRIDGE_LIB_DIR}/09-discovery.sh"
# shellcheck source=bridge-lib/10-search.sh
source "${BRIDGE_LIB_DIR}/10-search.sh"
# shellcheck source=bridge-lib/11-listen.sh
source "${BRIDGE_LIB_DIR}/11-listen.sh"
# shellcheck source=bridge-lib/12-pipeline.sh
source "${BRIDGE_LIB_DIR}/12-pipeline.sh"
# shellcheck source=bridge-lib/13-esp.sh
source "${BRIDGE_LIB_DIR}/13-esp.sh"

# ============================================================
# wMBus MQTT Bridge (core)
# - MQTT RAW HEX (payload-only) -> wmbusmeters stdin:hex
# - wmbusmeters JSON telegram -> MQTT state: <state_prefix>/<id>/state
# - Home Assistant MQTT Discovery (generic): sensor per numeric JSON field
# ============================================================

need_bin jq
need_bin mosquitto_sub
need_bin mosquitto_pub
need_bin wmbusmeters
need_bin awk
need_bin sed
need_bin tr

BASE="${WMBUS_BASE:-/data}"
OPTIONS_JSON="${BASE}/options.json"
ETC_DIR="${BASE}/etc"
METER_DIR="${ETC_DIR}/wmbusmeters.d"
CONF_FILE="${ETC_DIR}/wmbusmeters.conf"

mkdir -p "${ETC_DIR}" "${METER_DIR}"

# ------------------------------------------------------------
# Runtime status files for optional read-only Ingress dashboard
# ------------------------------------------------------------
# shellcheck disable=SC2034
STATUS_JSON="${BASE}/status.json"
STATUS_METERS_FILE="${BASE}/status_meters.tsv"
STATUS_CANDIDATES_FILE="${BASE}/status_candidates.tsv"
STATUS_EVENTS_FILE="${BASE}/status_events.tsv"
STATUS_SEEN_FILE="${BASE}/status_seen.tsv"
STATUS_RAW_COUNT_FILE="${BASE}/status_raw_count.txt"
STATUS_LAST_RAW_FILE="${BASE}/status_last_raw_seen.txt"
STATUS_RECENT_RAW_FILE="${BASE}/status_recent_raw.tsv"
STATUS_CANDIDATE_ANALYSIS_FILE="${BASE}/status_candidate_analysis.tsv"
STATUS_CANDIDATE_RAW_FILE="${BASE}/status_candidate_raw.tsv"
# Last full decoded JSON per configured meter — written by status_meter_seen,
# read by webui.py to show the "published fields" expander on the meters view.
# Format: id<TAB>iso_timestamp<TAB>json_line
STATUS_METER_LAST_JSON_FILE="${BASE}/status_meter_last_json.tsv"
# Discovery Doctor: webui.py touches the request flag; the heartbeat ticker
# runs discovery_doctor_probe (09-discovery.sh) and writes the JSON result.
DISCOVERY_DOCTOR_REQUEST_FILE="${BASE}/.discovery_doctor_request"
# shellcheck disable=SC2034  # consumed by discovery_doctor_probe (sourced lib)
STATUS_DISCOVERY_DOCTOR_FILE="${BASE}/status_discovery_doctor.json"
# Factory reset: webui.py empties options.json (meters=[]) and writes this flag
# with the removed meter ids (one per line); the heartbeat ticker clears their
# retained discovery, wipes runtime state and soft-reloads the pipeline so the
# add-on returns to its post-install state. See the ticker block below.
FACTORY_RESET_REQUEST_FILE="${BASE}/.factory_reset_request"
# Per-meter AES key problem (key_missing | key_invalid) detected from
# wmbusmeters warnings by status_detect_key_problem; cleared by the next
# successfully decoded JSON (status_meter_seen). Read by webui.py.
# Format: id<TAB>reason<TAB>iso_timestamp
STATUS_METER_KEY_PROBLEM_FILE="${BASE}/status_meter_key_problem.tsv"
# Per-candidate decoded value preview — written by parse_listen_candidates when
# the parallel LISTEN instance has a meter-preview-<id> file in its config dir.
# Format: id<TAB>value<TAB>value_key<TAB>iso_timestamp
STATUS_CANDIDATE_VALUES_FILE="${BASE}/status_candidate_values.tsv"
# Per-candidate preview lifecycle state: pending | decoded_value | decoded_without_numeric_value
# Format: id<TAB>state<TAB>iso_timestamp<TAB>note
STATUS_CANDIDATE_PREVIEW_STATE_FILE="${BASE}/status_candidate_preview_state.tsv"
# Preview one-shot decoder paths. Defined here (derived purely from BASE) so the
# liveness/maintenance ticker forked below can reference PREVIEW_METER_DIR; the
# directory mkdir and conf-file creation still happen later in startup.
PREVIEW_BASE="${BASE}/preview"
PREVIEW_ETC="${PREVIEW_BASE}/etc"
PREVIEW_METER_DIR="${PREVIEW_ETC}/wmbusmeters.d"
PREVIEW_CONF_FILE="${PREVIEW_ETC}/wmbusmeters.conf"
# MQTT->HA healthcheck: presence of Home Assistant's MQTT integration on the
# broker the bridge uses, inferred from HA's retained birth message
# (<discovery_prefix>/status). Written by the HA-presence subscriber in
# start_esp_subscribers. Format: state<TAB>epoch  (state = online | offline).
STATUS_HA_PRESENCE_FILE="${BASE}/status_ha_presence.txt"
# Liveness heartbeat — stamped every few seconds by the background ticker started
# after the ESP subscribers, regardless of telegram flow. Lets the WebUI tell
# "bridge alive but idle" apart from "bridge down / run.sh waiting for broker"
# (status.json alone goes stale during quiet periods too). Format: epoch.
STATUS_HEARTBEAT_FILE="${BASE}/status_heartbeat.txt"
# Broker identity from $SYS, written by the broker-info subscriber: brand+version
# (Mosquitto via $SYS/broker/version, EMQX via $SYS/brokers/+/sysdescr+version).
# Lets the WebUI label the MQTT tile "Mosquitto 2.x (native)" / "EMQX 5.x (other)".
# Format: brand<TAB>version. Session-scoped (the broker can change between runs).
STATUS_BROKER_INFO_FILE="${BASE}/status_broker_info.txt"
# Broker-connection failure marker, written by wait_for_mqtt when the broker
# refuses the connection WHILE THE BRIDGE IS RUNNING. Format: code<TAB>host:port
# (codes: auth_rejected, unreachable). Cleared on the first successful publish
# or received telegram. Rendered by the WebUI as an actionable banner — the
# offline MQTT tile alone proved too quiet when a wrong password silently
# blocked everything (observed live). Distinct from status_run_error.txt,
# which covers run.sh failing BEFORE the bridge ever starts.
STATUS_BROKER_ERROR_FILE="${BASE}/status_broker_error.txt"
# HA entity verification (opt-in, see verify_ha_entities option): worker writes
# one of verified | not_created | unavailable | pending here, after asking the
# HA Core API whether the canary entity (sensor.wmbus_bridge_health) exists.
# Format: state<TAB>epoch  (epoch = last check).
STATUS_HA_VERIFICATION_FILE="${BASE}/status_ha_verification.txt"
# wmbusmeters version triplet — written once at start. webui.py surfaces it on
# the wmbusmeters workspace panel. Format: runtime<TAB>build_version<TAB>build_commit.
STATUS_WMBUSMETERS_VERSION_FILE="${BASE}/status_wmbusmeters_version.txt"
# File-backed count of officially configured meters. Several pipelines run in
# subshells and can outlive a soft reload, so their inherited shell variable may
# be stale. This file is the shared runtime source of truth.
STATUS_OFFICIAL_METERS_COUNT_FILE="${BASE}/status_official_meters_count.txt"
# Per-ESP-device telegram tracking — written by the background MQTT subscriber
# that listens to the RAW topic itself. The "+" wildcard segment carries the
# device name (e.g. wmbus/xiaoseed/telegram → "xiaoseed"). Lets the WebGUI
# detect ESPs WITHOUT requiring diagnostic publishing on the ESP side.
# The file is cleared at bridge start, so rows describe devices seen in the
# current bridge session via the configured RAW_TOPIC.
# Format: device_name<TAB>last_seen_epoch<TAB>last_topic<TAB>telegram_count
STATUS_ESP_TELEGRAM_DEVICES_FILE="${BASE}/status_esp_telegram_devices.tsv"
SEARCH_MATCHES_FILE="${BASE}/search_matches.tsv"
SEARCH_STATUS_FILE="${BASE}/search_status.json"
# discovery_published flag — file-backed (see write_status_json). The raw-counter
# and decode loops run in SEPARATE subshells, each with its own isolated copy of
# STATUS_* vars. A shell-var-only flag gets clobbered back to false by the
# frequent raw-counter writes. The file is the shared source of truth. Cleared
# once per add-on start so the HA tile shows "pending" until discovery is
# (re)published this session.
STATUS_DISCOVERY_FLAG="${BASE}/status_discovery_published.flag"
rm -f "${STATUS_DISCOVERY_FLAG}" 2>/dev/null || true

# shellcheck disable=SC2034
STATUS_MQTT_CONNECTED="false"
STATUS_WMBUSMETERS_RUNNING="false"
# shellcheck disable=SC2034
STATUS_RAW_COUNT=0
STATUS_DECODED_COUNT=0
# shellcheck disable=SC2034
STATUS_DISCOVERY_PUBLISHED="false"
# shellcheck disable=SC2034
STATUS_DISCOVERY_PUBLISHED_AT=""
# shellcheck disable=SC2034
STATUS_LAST_RAW_SEEN=""
STATUS_LAST_DECODED_SEEN=""
STATUS_LAST_ERROR=""
# shellcheck disable=SC2034
STATUS_LAST_EVENT="starting"

# Per-minute rate tracking: updated on every incoming RAW telegram.
# WebGUI reads status_rate_1m.json to show live current/prev minute counts.
# shellcheck disable=SC2034
STATUS_RATE_1M_FILE="${BASE}/status_rate_1m.json"
# Per-minute history (rolling 15 entries) — feeds the sparkline in the WebGUI
# Statystyki view. Each row: epoch_minute<TAB>telegram_count. Appended every
# time a minute boundary is crossed; trimmed back to 15 rows.
STATUS_RATE_HISTORY_FILE="${BASE}/status_rate_history.tsv"
STATUS_BRIDGE_START_FILE="${BASE}/status_bridge_start.txt"
# shellcheck disable=SC2034
RAW_RATE_CUR_MIN_EPOCH=0
# shellcheck disable=SC2034
RAW_RATE_CUR_MIN_COUNT=0
# shellcheck disable=SC2034
RAW_RATE_PREV_MIN_COUNT=0

touch "${STATUS_METERS_FILE}" "${STATUS_CANDIDATES_FILE}" "${STATUS_EVENTS_FILE}" "${STATUS_SEEN_FILE}" "${STATUS_LAST_RAW_FILE}" "${STATUS_RECENT_RAW_FILE}" "${STATUS_CANDIDATE_ANALYSIS_FILE}" "${STATUS_CANDIDATE_RAW_FILE}" "${STATUS_METER_LAST_JSON_FILE}" "${STATUS_METER_KEY_PROBLEM_FILE}" "${STATUS_RATE_HISTORY_FILE}" "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" "${SEARCH_MATCHES_FILE}" "${SEARCH_STATUS_FILE}" "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}" "${STATUS_BROKER_ERROR_FILE}"
printf '0\n' > "${STATUS_OFFICIAL_METERS_COUNT_FILE}" 2>/dev/null || true
# Remove any orphaned pending-reload marker left by a hard stop during deferred sleep.
rm -rf "${BASE}/.reload_listen_pending" 2>/dev/null || true
# Session-scoped attempt counter dir — counts text-only telegrams per preview candidate
# without JSON. Cleared on every bridge start so stale counts never carry over.
rm -rf "${BASE}/.preview_attempts" 2>/dev/null || true
mkdir -p "${BASE}/.preview_attempts" 2>/dev/null || true
: > "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" 2>/dev/null || true
# HA presence is session-scoped to the current broker. Clear stale state so a
# previous run's "online" cannot mask a now-foreign broker until the retained
# birth message (if any) re-arrives on subscribe.
: > "${STATUS_HA_PRESENCE_FILE}" 2>/dev/null || true
# Broker identity is session-scoped — clear so a previous run's broker brand
# cannot linger after the user repoints the add-on at a different broker.
: > "${STATUS_BROKER_INFO_FILE}" 2>/dev/null || true
# HA verification verdict is session-scoped (it depends on the running bridge's
# Discovery publication and on the HA instance reachable now).
: > "${STATUS_HA_VERIFICATION_FILE}" 2>/dev/null || true
# Preview values are session-scoped — clear stale entries from previous runs
# so the WebGUI doesn't show outdated readings (or the legacy first-numeric-field
# pick that briefly stored bogus backflow_m3 / fraud counter values) until the
# next telegram arrives. New correct values appear ~2 min later on first decode.
: > "${STATUS_CANDIDATE_VALUES_FILE}" 2>/dev/null || touch "${STATUS_CANDIDATE_VALUES_FILE}"
[[ -f "${STATUS_RAW_COUNT_FILE}" ]] || echo "0" > "${STATUS_RAW_COUNT_FILE}"

# Record bridge start time for the WebGUI rate denominator fix.
printf '%s\n' "$(epoch_now)" > "${STATUS_BRIDGE_START_FILE}" 2>/dev/null || true


# ------------------------------------------------------------
# Config (ENV overrides JSON)
# ------------------------------------------------------------
RAW_TOPIC="${RAW_TOPIC:-$(json_get '.raw_topic' 'wmbus/+/telegram')}"
LOGLEVEL="${LOGLEVEL:-$(json_get '.loglevel' 'normal')}"
FILTER_HEX_ONLY="${FILTER_HEX_ONLY:-$(json_get_bool '.filter_hex_only' 'true')}"
DEBUG_EVERY_N="${DEBUG_EVERY_N:-$(json_get_int '.debug_every_n' '0')}"

SEARCH_MODE="${SEARCH_MODE:-$(json_get_bool '.search_mode' 'false')}"
SEARCH_EXPECTED_VALUE_M3="${SEARCH_EXPECTED_VALUE_M3:-$(json_get '.search_expected_value_m3' '0')}"
SEARCH_TOLERANCE_M3="${SEARCH_TOLERANCE_M3:-$(json_get '.search_tolerance_m3' '0.05')}"
SEARCH_DELTA_MODE="${SEARCH_DELTA_MODE:-$(json_get_bool '.search_delta_mode' 'false')}"
SEARCH_MIN_DELTA_M3="${SEARCH_MIN_DELTA_M3:-$(json_get '.search_min_delta_m3' '0.001')}"
SEARCH_TOPIC="${SEARCH_TOPIC:-$(json_get '.search_topic' 'wmbus/search/candidates')}"

# Robustness toggles
IGNORE_RETAINED="${IGNORE_RETAINED:-$(json_get_bool '.ignore_retained' 'true')}"
REQUIRE_TIMESTAMP="${REQUIRE_TIMESTAMP:-$(json_get_bool '.require_timestamp' 'false')}"
RESTART_ON_EXIT="${RESTART_ON_EXIT:-$(json_get_bool '.restart_on_exit' 'true')}"

# Opt-in HA entity verification: when true, the bridge publishes a hidden canary
# entity (sensor.wmbus_bridge_health) and a background worker asks the HA Core
# API whether that entity exists. Off by default (read-only HA access is opt-in).
VERIFY_HA_ENTITIES="${VERIFY_HA_ENTITIES:-$(json_get_bool '.verify_ha_entities' 'false')}"
export VERIFY_HA_ENTITIES

STATE_PREFIX="${STATE_PREFIX:-$(json_get '.state_prefix' 'wmbusmeters')}"
STATE_RETAIN="${STATE_RETAIN:-$(json_get_bool '.state_retain' 'false')}"

# Backward compat keys:
# - discovery_enabled (new)
# - enable_mqtt_discovery (old)
# - discovery (docker)
if [[ -z "${DISCOVERY_ENABLED:-}" ]]; then
  if [[ -f "${OPTIONS_JSON}" ]] && jq -e '.discovery_enabled' "${OPTIONS_JSON}" >/dev/null 2>&1; then
    DISCOVERY_ENABLED="$(json_get_bool '.discovery_enabled' 'true')"
  elif [[ -f "${OPTIONS_JSON}" ]] && jq -e '.enable_mqtt_discovery' "${OPTIONS_JSON}" >/dev/null 2>&1; then
    DISCOVERY_ENABLED="$(json_get_bool '.enable_mqtt_discovery' 'true')"
  else
    DISCOVERY_ENABLED="$(json_get_bool '.discovery' 'true')"
  fi
fi

DISCOVERY_PREFIX="${DISCOVERY_PREFIX:-$(json_get '.discovery_prefix' 'homeassistant')}"
DISCOVERY_RETAIN="${DISCOVERY_RETAIN:-$(json_get_bool '.discovery_retain' 'true')}"

# MQTT must be provided by wrapper (HA run.sh or docker entrypoint)
: "${MQTT_HOST:?MQTT_HOST is required}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"

WMBUSMETERS_BIN="$(command -v wmbusmeters || true)"
WMBUSMETERS_RUNTIME_VERSION="$(wmbusmeters --version 2>&1 | head -n 1 || true)"
WMBUSMETERS_BUILD_VERSION=""
WMBUSMETERS_BUILD_COMMIT=""

if [[ -f /usr/share/wmbusmeters-build-version.txt ]]; then
  WMBUSMETERS_BUILD_VERSION="$(cat /usr/share/wmbusmeters-build-version.txt 2>/dev/null || true)"
fi

if [[ -f /usr/share/wmbusmeters-build-commit.txt ]]; then
  WMBUSMETERS_BUILD_COMMIT="$(cat /usr/share/wmbusmeters-build-commit.txt 2>/dev/null || true)"
fi

log "core: bridge.sh (base=${BASE})"
log "wmbusmeters binary: ${WMBUSMETERS_BIN:-unknown}"
log "wmbusmeters runtime version: ${WMBUSMETERS_RUNTIME_VERSION:-unknown}"
[[ -n "${WMBUSMETERS_BUILD_VERSION}" ]] && log "wmbusmeters build version: ${WMBUSMETERS_BUILD_VERSION}"
[[ -n "${WMBUSMETERS_BUILD_COMMIT}" ]] && log "wmbusmeters build commit: ${WMBUSMETERS_BUILD_COMMIT}"
# Persist the version triplet for the WebUI (write-once, never refreshed —
# the binary cannot change without a restart). NB: write_atomic via .tmp + mv.
printf '%s\t%s\t%s\n' \
  "${WMBUSMETERS_RUNTIME_VERSION:-}" \
  "${WMBUSMETERS_BUILD_VERSION:-}" \
  "${WMBUSMETERS_BUILD_COMMIT:-}" \
  > "${STATUS_WMBUSMETERS_VERSION_FILE}.tmp" 2>/dev/null \
  && mv "${STATUS_WMBUSMETERS_VERSION_FILE}.tmp" "${STATUS_WMBUSMETERS_VERSION_FILE}" 2>/dev/null \
  || true
log "MQTT: ${MQTT_HOST}:${MQTT_PORT} topic=${RAW_TOPIC}"
log "state: prefix=${STATE_PREFIX} retain=${STATE_RETAIN}"
log "discovery: enabled=${DISCOVERY_ENABLED} prefix=${DISCOVERY_PREFIX} retain=${DISCOVERY_RETAIN}"
log "wmbusmeters: loglevel=${LOGLEVEL} filter_hex_only=${FILTER_HEX_ONLY} debug_every_n=${DEBUG_EVERY_N}"
log "search: mode=${SEARCH_MODE} expected_value_m3=${SEARCH_EXPECTED_VALUE_M3} tolerance_m3=${SEARCH_TOLERANCE_M3} delta_mode=${SEARCH_DELTA_MODE} min_delta_m3=${SEARCH_MIN_DELTA_M3} topic=${SEARCH_TOPIC}"
log "robust: ignore_retained=${IGNORE_RETAINED} require_timestamp=${REQUIRE_TIMESTAMP} restart_on_exit=${RESTART_ON_EXIT}"
log "verify_ha_entities: ${VERIFY_HA_ENTITIES}"
status_add_event "ok" "bridge starting"
write_status_json

# ------------------------------------------------------------
# MQTT args
# ------------------------------------------------------------
PUB_ARGS=( -h "${MQTT_HOST}" -p "${MQTT_PORT}" )
SUB_ARGS=( -h "${MQTT_HOST}" -p "${MQTT_PORT}" )

if [[ -n "${MQTT_USER}" && "${MQTT_USER}" != "null" ]]; then
  PUB_ARGS+=( -u "${MQTT_USER}" )
  SUB_ARGS+=( -u "${MQTT_USER}" )
fi
if [[ -n "${MQTT_PASS}" && "${MQTT_PASS}" != "null" ]]; then
  PUB_ARGS+=( -P "${MQTT_PASS}" )
  SUB_ARGS+=( -P "${MQTT_PASS}" )
fi

# mosquitto_sub robustness flags
SUB_EXTRA=()
if [[ "${IGNORE_RETAINED}" == "true" ]]; then
  SUB_EXTRA+=( -R )
fi

# line-buffer output if stdbuf exists
STDBUF_BIN=""
if command -v stdbuf >/dev/null 2>&1; then
  STDBUF_BIN="stdbuf -oL -eL"
fi

start_esp_subscribers

# Liveness heartbeat ticker: stamp the current epoch every few seconds,
# independent of telegram flow, so the WebUI can distinguish "bridge alive but
# idle" from "bridge down / run.sh waiting for the broker". Dies with bridge.sh.
(
  _last_candidate_prune=0
  while true; do
    printf '%s\n' "$(epoch_now)" > "${STATUS_HEARTBEAT_FILE}.tmp" 2>/dev/null \
      && mv "${STATUS_HEARTBEAT_FILE}.tmp" "${STATUS_HEARTBEAT_FILE}" 2>/dev/null \
      || true
    # Throttled bridge-side cleanup of long-silent candidates. The pipeline
    # restart loop only prunes on reload; a stable long-running pipeline never
    # reloads, so this ticker (already excluded from soft-reload kills) drives
    # the time-based self-deletion. Heartbeat is stamped first every tick, so a
    # prune run can never delay liveness past the 30 s WebUI threshold.
    _hb_now="$(epoch_now)"
    if (( _hb_now - _last_candidate_prune >= ${CANDIDATE_PRUNE_INTERVAL_SECONDS:-600} )); then
      prune_stale_candidates || true
      _last_candidate_prune="${_hb_now}"
    fi
    # Discovery Doctor: WebUI requested a broker probe. Consume the flag
    # first so a slow probe cannot be re-triggered by the same request.
    if [[ -f "${DISCOVERY_DOCTOR_REQUEST_FILE}" ]]; then
      rm -f "${DISCOVERY_DOCTOR_REQUEST_FILE}" 2>/dev/null || true
      discovery_doctor_probe || true
    fi
    # Factory reset: webui.py already emptied options.json (meters=[]) and wrote
    # the removed ids here. Consume the flag first so a slow teardown cannot be
    # re-triggered, clear each meter's retained discovery (entities vanish from
    # HA), wipe runtime state (status_*/search_*/seen + preview meter files), and
    # soft-reload the decode pipeline — refresh_meter_files then regenerates an
    # empty meter set, leaving the add-on in its post-install state. The binary,
    # options.json and the etc/listen/preview config dirs are left intact. NB:
    # use ${BASE}-literal paths — RELOAD_FLAG/LISTEN_METER_DIR are defined after
    # this ticker subshell forks, so they are not in scope here.
    if [[ -f "${FACTORY_RESET_REQUEST_FILE}" ]]; then
      _fr_ids=()
      mapfile -t _fr_ids < "${FACTORY_RESET_REQUEST_FILE}" 2>/dev/null || _fr_ids=()
      rm -f "${FACTORY_RESET_REQUEST_FILE}" 2>/dev/null || true
      log "Factory reset: clearing discovery for ${#_fr_ids[@]} meter(s), wiping runtime state"
      for _fr_id in "${_fr_ids[@]}"; do
        [[ -n "${_fr_id}" ]] || continue
        clear_meter_discovery "${_fr_id}" || true
      done
      rm -f "${BASE}/status_"* "${BASE}/search_"* "${BASE}/seen_ids.txt" 2>/dev/null || true
      rm -f "${BASE}/preview/etc/wmbusmeters.d/meter-preview-"* \
            "${BASE}/listen/etc/wmbusmeters.d/meter-preview-"* 2>/dev/null || true
      # Recreate the empty status files exactly like startup does — the wipe
      # removed them under RUNNING writers, and not every writer tolerates a
      # missing file (observed: _upsert_candidate_row's awk failed on the
      # absent status_candidates.tsv and silently dropped every candidate
      # until the next restart). All these vars are defined before this
      # ticker subshell forks, so they are in scope here.
      touch "${STATUS_METERS_FILE}" "${STATUS_CANDIDATES_FILE}" "${STATUS_EVENTS_FILE}" "${STATUS_SEEN_FILE}" "${STATUS_LAST_RAW_FILE}" "${STATUS_RECENT_RAW_FILE}" "${STATUS_CANDIDATE_ANALYSIS_FILE}" "${STATUS_CANDIDATE_RAW_FILE}" "${STATUS_METER_LAST_JSON_FILE}" "${STATUS_METER_KEY_PROBLEM_FILE}" "${STATUS_RATE_HISTORY_FILE}" "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" "${SEARCH_MATCHES_FILE}" "${SEARCH_STATUS_FILE}" "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}" "${STATUS_BROKER_ERROR_FILE}" 2>/dev/null || true
      # The wipe also removed the heartbeat we stamped at the top of this loop;
      # re-stamp now so the WebUI never sees a liveness gap before the next tick.
      printf '%s\n' "$(epoch_now)" > "${STATUS_HEARTBEAT_FILE}" 2>/dev/null || true
      touch "${BASE}/.reload_pipeline" 2>/dev/null || true
      status_add_event "ok" "Factory reset applied — add-on returned to post-install state" || true
    fi
    sleep "${HEARTBEAT_INTERVAL_SECONDS:-10}"
  done
) &
HEARTBEAT_PID=$!

# ------------------------------------------------------------
# wmbusmeters.conf
# ------------------------------------------------------------
cat > "${CONF_FILE}" <<EOFCONF
loglevel=${LOGLEVEL}
device=stdin:hex
logfile=/dev/stdout
format=json
EOFCONF

# ------------------------------------------------------------
# Listen-only wmbusmeters config: SECONDARY instance for candidate
# visibility in DECODE mode. Separate config dir under ${BASE}/listen
# with NO meter files — this instance always runs in pure listen mode
# and emits "Received telegram from: XXXXXXXX" / type: / driver: lines
# for every wMBus telegram seen, regardless of how many meters the user
# has configured in the primary instance. Spawned when DECODE is active or
# when meter-preview-* files exist (preview values need this separate config
# dir even if the primary instance is otherwise in pure LISTEN mode).
#
# Shares the SAME wmbusmeters binary as the primary — only the config
# dir differs. User-uploaded binary upgrades are picked up by both
# instances on addon restart with no additional work.
# ------------------------------------------------------------
LISTEN_BASE="${BASE}/listen"
LISTEN_ETC="${LISTEN_BASE}/etc"
LISTEN_METER_DIR="${LISTEN_ETC}/wmbusmeters.d"
LISTEN_CONF_FILE="${LISTEN_ETC}/wmbusmeters.conf"
mkdir -p "${LISTEN_METER_DIR}"
# Defensive — the listen instance must NEVER have meter files (would force decode)
rm -f "${LISTEN_METER_DIR}/meter-"* 2>/dev/null || true
cat > "${LISTEN_CONF_FILE}" <<EOFLISTEN
loglevel=${LOGLEVEL}
device=stdin:hex
logfile=/dev/stdout
format=json
EOFLISTEN

# ------------------------------------------------------------
# Preview one-shot decoder config
# ------------------------------------------------------------
# Preview must NOT contaminate the always-on LISTEN instance. Candidate preview
# files live in a separate directory and are decoded from individual RAW frames
# by short-lived one-shot wmbusmeters processes. This preserves exactly two
# long-running pipelines: PRIMARY DECODE and SECONDARY PURE LISTEN.
# PREVIEW_BASE/ETC/METER_DIR/CONF_FILE are defined earlier (near the STATUS_*
# paths) so the maintenance ticker can see PREVIEW_METER_DIR; create them now.
mkdir -p "${PREVIEW_METER_DIR}"
cat > "${PREVIEW_CONF_FILE}" <<EOFPREVIEW
loglevel=${LOGLEVEL}
device=stdin:hex
logfile=/dev/stdout
format=json
EOFPREVIEW
# Defensive cleanup for upgrades from the broken hybrid LISTEN+preview design.
rm -f "${LISTEN_METER_DIR}/meter-preview-"* 2>/dev/null || true
rm -f "${BASE}/.reload_listen" "${BASE}/.reload_listen_req" 2>/dev/null || true
rm -rf "${BASE}/.reload_listen_pending" 2>/dev/null || true
rm -rf "${BASE}/.preview_decode_locks" "${BASE}/.preview_decode_slots" 2>/dev/null || true
mkdir -p "${BASE}/.preview_decode_locks" "${BASE}/.preview_decode_last" "${BASE}/.preview_decode_slots" 2>/dev/null || true

# ------------------------------------------------------------
# Search mode helpers
# ------------------------------------------------------------
SEARCH_EXPECTED_VALUE_M3="$(float_or_default "${SEARCH_EXPECTED_VALUE_M3}" "0")"
SEARCH_TOLERANCE_M3="$(float_or_default "${SEARCH_TOLERANCE_M3}" "0.05")"
SEARCH_MIN_DELTA_M3="$(float_or_default "${SEARCH_MIN_DELTA_M3}" "0.001")"

# shellcheck disable=SC2034
SEARCH_CANDIDATES_FILE="${BASE}/search_candidates.tsv"
SEARCH_USING_TEMP_METERS="false"
# Used by sourced bridge-lib/07-meters.sh
# shellcheck disable=SC2034
OFFICIAL_METERS_COUNT=0
# Used by sourced bridge-lib/07-meters.sh
# shellcheck disable=SC2034
SEARCH_IGNORED_COUNT=0
# shellcheck disable=SC2034
SEARCH_TEMP_METERS_LOADED=0
# shellcheck disable=SC2034
SEARCH_CHECKED_VALUES=0
# shellcheck disable=SC2034
SEARCH_DECODED_JSON_COUNT=0
# shellcheck disable=SC2034
SEARCH_MATCH_COUNT=0
# shellcheck disable=SC2034
SEARCH_LAST_CACHE_CHANGE=""
# shellcheck disable=SC2034
SEARCH_LAST_CANDIDATE_ID=""
# shellcheck disable=SC2034
SEARCH_LAST_CANDIDATE_DRIVER=""
# shellcheck disable=SC2034
SEARCH_LAST_CANDIDATE_TYPE=""
# shellcheck disable=SC2034
SEARCH_LAST_CHECKED_ID=""
# shellcheck disable=SC2034
SEARCH_LAST_CHECKED_DRIVER=""
# shellcheck disable=SC2034
SEARCH_LAST_CHECKED_FIELD=""
# shellcheck disable=SC2034
SEARCH_LAST_CHECKED_VALUE=""
# shellcheck disable=SC2034
SEARCH_LAST_CHECKED_DIFF=""
# shellcheck disable=SC2034
SEARCH_LAST_REASON="starting"
# shellcheck disable=SC2034
SEARCH_LAST_IGNORED_REASON=""


write_search_status "auto" "bridge_starting"


# ------------------------------------------------------------
# Meter registration — refresh_meter_files()
# Called once at startup AND before every run_once() iteration, so that
# meters added/removed by the user via options.json are picked up by a
# soft pipeline restart (touch ${RELOAD_FLAG}) without needing a full
# container restart. wmbusmeters reads its meter-NNNN files only at
# startup, so the pipeline must be restarted to pick up changes.
# ------------------------------------------------------------
# Soft-reload flag: touch this file to make the running pipeline exit
# cleanly. The restart_on_exit loop refreshes meter files and respawns.
# Used by webui.py /api/reload-pipeline to pick up new meters without
# a full container restart.
RELOAD_FLAG="${BASE}/.reload_pipeline"
rm -f "${RELOAD_FLAG}" 2>/dev/null || true

# Initial meter registration before the restart loop kicks in. Without
# this, OFFICIAL_METERS_COUNT would stay at 0 and parse_listen_candidates
# would mis-guard candidate double-counting on the first pipeline start.
refresh_meter_files

# ------------------------------------------------------------
# Discovery
# ------------------------------------------------------------

# Listen-mode snippet (best-effort)
# ------------------------------------------------------------
SNIPPET_STATE="${BASE}/seen_ids.txt"
touch "${SNIPPET_STATE}"


# ------------------------------------------------------------
# Pipeline
# ------------------------------------------------------------
log "Starting wmbusmeters..."

run_once() {
  last_id=""
  last_driver=""
  last_type=""
  last_manufacturer=""

  # ─── Soft-reload flag watcher ────────────────────────────────────────
  # Polls for ${RELOAD_FLAG} every 2 s. When present, removes it and kills
  # the main shell's direct children (mosquitto_sub, awk, tee, wmbusmeters,
  # while-read subshell) to bring down the foreground pipeline. The
  # restart_on_exit loop above refreshes meter files and respawns run_once.
  # Watcher excludes itself (BASHPID), LISTEN_PID, HEARTBEAT_PID and the ESP
  # subscriber PIDs (ESP_SUBSCRIBER_PIDS) from the kill list so the parallel
  # listen instance, the liveness heartbeat and the ESP/diag/HA-presence
  # subscribers keep running across pipeline restarts (otherwise a soft reload
  # would silently stop them — e.g. a stale heartbeat falsely flags the dashboard).
  (
    watcher_self="${BASHPID}"
    while sleep 2; do
      if [[ -f "${RELOAD_FLAG}" ]]; then
        rm -f "${RELOAD_FLAG}" 2>/dev/null || true
        log "Soft reload: ${RELOAD_FLAG} detected, restarting decode pipeline..."
        for child in $(pgrep -P "$$" 2>/dev/null); do
          [[ "${child}" == "${watcher_self}" ]] && continue
          [[ -n "${LISTEN_PID}" && "${child}" == "${LISTEN_PID}" ]] && continue
          [[ -n "${HEARTBEAT_PID:-}" && "${child}" == "${HEARTBEAT_PID}" ]] && continue
          [[ -n "${ESP_SUBSCRIBER_PIDS:-}" && " ${ESP_SUBSCRIBER_PIDS} " == *" ${child} "* ]] && continue
          kill -TERM "${child}" 2>/dev/null
        done
        exit 0
      fi
    done
  ) &
  local WATCHER_PID=$!

  if [[ "${FILTER_HEX_ONLY}" == "true" ]]; then
  ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" "${SUB_EXTRA[@]}" -t "${RAW_TOPIC}" -F '%p' \
    | awk -v dbg_n="${DEBUG_EVERY_N}" '
        function ishex(s) { return (s ~ /^[0-9A-Fa-f]+$/) }
        BEGIN { n=0 }
        {
          gsub(/[[:space:]]/, "", $0);
          sub(/^0x/i, "", $0);
          if (!ishex($0)) next;
          if ((length($0) % 2) != 0) next;

          n++;
          if (dbg_n > 0 && (n % dbg_n) == 0) {
            printf("[MQTT HEX] #%d %s...\n", n, substr($0,1,16)) > "/dev/stderr";
          }
          print $0;
          fflush();
        }
      ' \
    | tee >(while IFS= read -r raw_line; do status_raw_seen "${raw_line}"; done >/dev/null) \
    | ${STDBUF_BIN} /usr/bin/wmbusmeters --useconfig="${BASE}" 2>&1 \
    | while IFS= read -r line; do
        if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
          STATUS_WMBUSMETERS_RUNNING="true"
          STATUS_DECODED_COUNT=$((STATUS_DECODED_COUNT + 1))
          # shellcheck disable=SC2034
          STATUS_LAST_DECODED_SEEN="$(iso_now)"
          status_add_event "ok" "Decoded telegram received"
          write_status_json
          status_mark_search_decoded_no_aes "${line}"
          process_search_json "${line}"
          if is_search_temp_json "${line}"; then
            clear_search_discovery_from_json "${line}"
            continue
          fi
          status_meter_seen "${line}"
          echo "${line}"
          id="$(normalize_meter_id "$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)")"
          ts="$(echo "${line}" | jq -r '.timestamp // .device_date_time // empty' 2>/dev/null || true)"
          if [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]]; then
            if [[ "${REQUIRE_TIMESTAMP}" == "true" && -z "${ts}" ]]; then
              warn "Skip publish: missing timestamp for id=${id}"
            else
              emit_discovery_from_json "${line}"
              mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
              status_mark_discovery_published
              write_status_json
            fi
          fi
          continue
        fi

        echo "${line}"
        status_detect_key_problem "${line}" || true

        if [[ "$(official_meters_count_current)" -eq 0 && "${SEARCH_USING_TEMP_METERS}" != "true" ]]; then
          if [[ "${line}" =~ ^Received\ telegram\ from:\ ([0-9A-Fa-f]{8}) ]]; then
            last_id="$(normalize_meter_id "${BASH_REMATCH[1]}")"
            last_type=""
            last_driver=""
            last_manufacturer=""
          fi
          if [[ "${line}" =~ ^[[:space:]]*type:[[:space:]]*(.*)$ ]]; then
            last_type="${BASH_REMATCH[1]}"
          fi
          if [[ "${line}" =~ ^[[:space:]]*manufacturer:[[:space:]]*(.*)$ ]]; then
            last_manufacturer="${BASH_REMATCH[1]}"
          fi
          if [[ "${line}" =~ ^[[:space:]]*driver:\ ([a-zA-Z0-9_]+) ]]; then
            last_driver="${BASH_REMATCH[1]}"
          fi
          if [[ -n "${last_id}" && -n "${last_driver}" ]]; then
            if [[ "${SEARCH_MODE}" == "true" && "${SEARCH_EXPECTED_VALUE_M3}" != "0" ]]; then
              search_cache_candidate "${last_id}" "${last_driver}" "${last_type}"
            else
              emit_snippet_if_new "${last_id}" "${last_driver}" "${last_type}" "${last_manufacturer}"
            fi
            last_id=""
            last_driver=""
            last_type=""
            last_manufacturer=""
          fi
        fi

done
else
  ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" "${SUB_EXTRA[@]}" -t "${RAW_TOPIC}" -F '%p' \
    | tee >(while IFS= read -r raw_line; do status_raw_seen "${raw_line}"; done >/dev/null) \
    | ${STDBUF_BIN} /usr/bin/wmbusmeters --useconfig="${BASE}" 2>&1 \
    | while IFS= read -r line; do
        if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
          STATUS_WMBUSMETERS_RUNNING="true"
          STATUS_DECODED_COUNT=$((STATUS_DECODED_COUNT + 1))
          # shellcheck disable=SC2034
          STATUS_LAST_DECODED_SEEN="$(iso_now)"
          status_add_event "ok" "Decoded telegram received"
          write_status_json
          status_mark_search_decoded_no_aes "${line}"
          process_search_json "${line}"
          if is_search_temp_json "${line}"; then
            clear_search_discovery_from_json "${line}"
            continue
          fi
          status_meter_seen "${line}"
          echo "${line}"
          id="$(normalize_meter_id "$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)")"
          ts="$(echo "${line}" | jq -r '.timestamp // .device_date_time // empty' 2>/dev/null || true)"
          if [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]]; then
            if [[ "${REQUIRE_TIMESTAMP}" == "true" && -z "${ts}" ]]; then
              warn "Skip publish: missing timestamp for id=${id}"
            else
              emit_discovery_from_json "${line}"
              mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
              status_mark_discovery_published
              write_status_json
            fi
          fi
        else
          echo "${line}"
          status_detect_key_problem "${line}" || true
        fi
done
fi

  # ─── Cleanup flag watcher ──────────────────────────────────────────────
  # Main pipeline exited (natural EOF / soft-reload kill / SIGTERM). Stop
  # the polling watcher. LISTEN instance is NOT killed here — it persists
  # across run_once restarts (managed by the restart_on_exit loop instead).
  if [[ -n "${WATCHER_PID}" ]]; then
    kill -TERM "${WATCHER_PID}" 2>/dev/null || true
    wait "${WATCHER_PID}" 2>/dev/null || true
  fi
}

# Ensure LISTEN dies when the addon shuts down (docker stop / s6 SIGTERM).
trap stop_listen_instance EXIT TERM INT

# ------------------------------------------------------------
# wait_for_mqtt
# Czeka na dostępność brokera MQTT przed startem pipeline.
# Potrzebne po aktualizacji addona - broker może być chwilę
# niedostępny zanim mosquitto w HA zdąży się podnieść.
# Próbuje co MQTT_WAIT_DELAY sekund, maksymalnie MQTT_WAIT_RETRIES razy.
# Jeśli broker nie odpowie w tym czasie - kontynuuje mimo to
# (pipeline i tak zrestartuje się przez pętlę restart_on_exit).
# ------------------------------------------------------------
MQTT_WAIT_RETRIES="${MQTT_WAIT_RETRIES:-30}"
MQTT_WAIT_DELAY="${MQTT_WAIT_DELAY:-2}"

# ------------------------------------------------------------
# Restart loop (optional)
# Uruchamia pipeline w pętli jeśli RESTART_ON_EXIT=true (domyślnie).
# Przed każdym uruchomieniem sprawdza dostępność brokera MQTT.
# ------------------------------------------------------------
while true; do
  set +e
  wait_for_mqtt

  # ─── Soft reload: refresh meter files & LISTEN instance ───
  # Re-read options.json so meters added/removed via WebUI without a
  # container restart are picked up. wmbusmeters reads its meter-NNNN
  # configs only at startup, so the pipeline restart on the next line
  # is required for new meters to start decoding.
  refresh_meter_files

  # Existing candidates from previous LISTEN ticks should retain preview
  # configs after a soft reload. These files live under ${BASE}/preview, never
  # inside the always-on LISTEN configuration directory.
  sync_candidate_autodecode_files

  # Remove preview configs for IDs promoted to official meters. PRIMARY DECODE
  # handles those meters from now on.
  prune_official_meter_previews

  # Parallel LISTEN always starts unconditionally and remains a pure, empty-dir
  # discovery stream. Preview decoding is one-shot and never reloads LISTEN.
  start_listen_instance

  # Republish the canary entity used by the opt-in HA verification (no-op when
  # the option is off). Cheap and idempotent — retained Discovery payload.
  publish_canary_entity

  run_once
  rc=$?
  set -e
  if [[ "${RESTART_ON_EXIT}" != "true" ]]; then
    exit ${rc}
  fi
  # shellcheck disable=SC2034
  STATUS_WMBUSMETERS_RUNNING="false"
  if [[ "${rc}" -eq 0 ]]; then
    # rc=0 is a clean, intentional exit — typically a soft pipeline reload
    # requested via the WebUI (.reload_pipeline) to pick up added/removed
    # meters. Not an error: the loop just respawns the pipeline.
    log "Pipeline exited cleanly (rc=0), reloading in 2s..."
    status_add_event "ok" "Pipeline reloaded"
  else
    warn "Pipeline exited (rc=${rc}), restarting in 2s..."
    # shellcheck disable=SC2034
    STATUS_LAST_ERROR="pipeline exited rc=${rc}"
    status_add_event "error" "Pipeline exited rc=${rc}"
  fi
  write_status_json
  sleep 2
  # continue
done

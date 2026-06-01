#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# wMBus MQTT Bridge (core)
# - MQTT RAW HEX (payload-only) -> wmbusmeters stdin:hex
# - wmbusmeters JSON telegram -> MQTT state: <state_prefix>/<id>/state
# - Home Assistant MQTT Discovery (generic): sensor per numeric JSON field
# ============================================================

log()         { echo "[wmbus-bridge] $*"; }
warn()        { echo "[wmbus-bridge][WARN] $*" >&2; }
err()         { echo "[wmbus-bridge][ERR] $*" >&2; }
log_verbose() { [[ "${LOGLEVEL}" == "verbose" || "${LOGLEVEL}" == "debug" ]] && echo "[wmbus-bridge] $*" || true; }
log_debug()   { [[ "${LOGLEVEL}" == "debug" ]] && echo "[wmbus-bridge] $*" || true; }

need_bin() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing binary: $1"; exit 1; }
}

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
# Per-candidate decoded value preview — written by parse_listen_candidates when
# the parallel LISTEN instance has a meter-preview-<id> file in its config dir.
# Format: id<TAB>value<TAB>value_key<TAB>iso_timestamp
STATUS_CANDIDATE_VALUES_FILE="${BASE}/status_candidate_values.tsv"
# Per-candidate preview lifecycle state: pending | decoded_value | decoded_without_numeric_value
# Format: id<TAB>state<TAB>iso_timestamp<TAB>note
STATUS_CANDIDATE_PREVIEW_STATE_FILE="${BASE}/status_candidate_preview_state.tsv"
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

STATUS_MQTT_CONNECTED="false"
STATUS_WMBUSMETERS_RUNNING="false"
STATUS_RAW_COUNT=0
STATUS_DECODED_COUNT=0
STATUS_DISCOVERY_PUBLISHED="false"
STATUS_DISCOVERY_PUBLISHED_AT=""
STATUS_LAST_RAW_SEEN=""
STATUS_LAST_DECODED_SEEN=""
STATUS_LAST_ERROR=""
STATUS_LAST_EVENT="starting"

# Per-minute rate tracking: updated on every incoming RAW telegram.
# WebGUI reads status_rate_1m.json to show live current/prev minute counts.
STATUS_RATE_1M_FILE="${BASE}/status_rate_1m.json"
# Per-minute history (rolling 15 entries) — feeds the sparkline in the WebGUI
# Statystyki view. Each row: epoch_minute<TAB>telegram_count. Appended every
# time a minute boundary is crossed; trimmed back to 15 rows.
STATUS_RATE_HISTORY_FILE="${BASE}/status_rate_history.tsv"
STATUS_BRIDGE_START_FILE="${BASE}/status_bridge_start.txt"
RAW_RATE_CUR_MIN_EPOCH=0
RAW_RATE_CUR_MIN_COUNT=0
RAW_RATE_PREV_MIN_COUNT=0

touch "${STATUS_METERS_FILE}" "${STATUS_CANDIDATES_FILE}" "${STATUS_EVENTS_FILE}" "${STATUS_SEEN_FILE}" "${STATUS_LAST_RAW_FILE}" "${STATUS_RECENT_RAW_FILE}" "${STATUS_CANDIDATE_ANALYSIS_FILE}" "${STATUS_CANDIDATE_RAW_FILE}" "${STATUS_RATE_HISTORY_FILE}" "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" "${SEARCH_MATCHES_FILE}" "${SEARCH_STATUS_FILE}" "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}"
# Remove any orphaned pending-reload marker left by a hard stop during deferred sleep.
rm -rf "${BASE}/.reload_listen_pending" 2>/dev/null || true
# Session-scoped attempt counter dir — counts text-only telegrams per preview candidate
# without JSON. Cleared on every bridge start so stale counts never carry over.
rm -rf "${BASE}/.preview_attempts" 2>/dev/null || true
mkdir -p "${BASE}/.preview_attempts" 2>/dev/null || true
: > "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" 2>/dev/null || true
# Preview values are session-scoped — clear stale entries from previous runs
# so the WebGUI doesn't show outdated readings (or the legacy first-numeric-field
# pick that briefly stored bogus backflow_m3 / fraud counter values) until the
# next telegram arrives. New correct values appear ~2 min later on first decode.
: > "${STATUS_CANDIDATE_VALUES_FILE}" 2>/dev/null || touch "${STATUS_CANDIDATE_VALUES_FILE}"
[[ -f "${STATUS_RAW_COUNT_FILE}" ]] || echo "0" > "${STATUS_RAW_COUNT_FILE}"

iso_now() {
  date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

epoch_now() {
  date +%s 2>/dev/null || echo 0
}

# Record bridge start time for the WebGUI rate denominator fix.
printf '%s\n' "$(epoch_now)" > "${STATUS_BRIDGE_START_FILE}" 2>/dev/null || true

status_add_event() {
  local level="$1"
  local message="$2"
  local now
  now="$(iso_now)"
  STATUS_LAST_EVENT="${message}"
  printf '%s	%s	%s
' "${now}" "${level}" "${message}" >> "${STATUS_EVENTS_FILE}" 2>/dev/null || true
  tail -n 40 "${STATUS_EVENTS_FILE}" > "${STATUS_EVENTS_FILE}.tmp" 2>/dev/null && mv "${STATUS_EVENTS_FILE}.tmp" "${STATUS_EVENTS_FILE}" 2>/dev/null || true
}

status_record_seen() {
  local id
  local kind="${2:-meter}"
  local ts last_ts
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  ts="$(epoch_now)"
  last_ts="$(awk -F '\t' -v id="${id}" -v kind="${kind}" '
    $1 == id && $2 == kind && $3 ~ /^[0-9]+$/ { last = $3 + 0 }
    END { if (last) print last; }
  ' "${STATUS_SEEN_FILE}" 2>/dev/null || true)"
  if [[ "${last_ts}" =~ ^[0-9]+$ ]] && (( ts - last_ts < 2 )); then
    return 0
  fi
  printf '%s\t%s\t%s\n' "${id}" "${kind}" "${ts}" >> "${STATUS_SEEN_FILE}" 2>/dev/null || true
  tail -n 5000 "${STATUS_SEEN_FILE}" > "${STATUS_SEEN_FILE}.tmp" 2>/dev/null && mv "${STATUS_SEEN_FILE}.tmp" "${STATUS_SEEN_FILE}" 2>/dev/null || true
}

status_seen_stats() {
  local id
  local kind="${2:-meter}"
  local now
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || { printf '0\t0\t0\t0\n'; return 0; }
  now="$(epoch_now)"

  awk -F '\t' -v id="${id}" -v kind="${kind}" -v now="${now}" '
    $1 == id && $2 == kind && $3 ~ /^[0-9]+$/ {
      ts = $3 + 0
      count++
      if (ts >= now - 900) seen15++
      if (ts >= now - 3600) seen60++
      if (prev > 0 && ts >= prev) {
        sum += ts - prev
        intervals++
      }
      prev = ts
    }
    END {
      if (intervals > 0) {
        avg = int((sum / intervals) + 0.5)
      } else {
        avg = 0
      }
      printf "%d\t%d\t%d\t%d\n", count + 0, avg + 0, seen15 + 0, seen60 + 0
    }
  ' "${STATUS_SEEN_FILE}" 2>/dev/null || printf '0\t0\t0\t0\n'
}

status_read_raw_count() {
  local v
  v="$(cat "${STATUS_RAW_COUNT_FILE}" 2>/dev/null || echo "0")"
  [[ "${v}" =~ ^[0-9]+$ ]] || v=0
  echo "${v}"
}

status_read_last_raw_seen() {
  cat "${STATUS_LAST_RAW_FILE}" 2>/dev/null || true
}

status_store_raw_seen() {
  local now="$1"
  local count tmp
  count="$(status_read_raw_count)"
  count=$((count + 1))
  tmp="${STATUS_RAW_COUNT_FILE}.tmp"
  printf '%s\n' "${count}" > "${tmp}" 2>/dev/null && mv "${tmp}" "${STATUS_RAW_COUNT_FILE}" 2>/dev/null || true
  printf '%s\n' "${now}" > "${STATUS_LAST_RAW_FILE}" 2>/dev/null || true
  STATUS_RAW_COUNT="${count}"
  STATUS_LAST_RAW_SEEN="${now}"
}

status_store_recent_raw() {
  local raw="${1:-}"
  local now
  [[ -n "${raw}" ]] || return 0
  [[ "${raw}" =~ ^[0-9A-Fa-f]+$ ]] || return 0
  now="$(iso_now)"
  printf '%s\t%s\t%s\n' "${now}" "${#raw}" "${raw}" >> "${STATUS_RECENT_RAW_FILE}" 2>/dev/null || true
  tail -n 200 "${STATUS_RECENT_RAW_FILE}" > "${STATUS_RECENT_RAW_FILE}.tmp" 2>/dev/null && mv "${STATUS_RECENT_RAW_FILE}.tmp" "${STATUS_RECENT_RAW_FILE}" 2>/dev/null || true
}

id_to_le_hex() {
  local id
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || { echo ""; return 0; }
  echo "${id:6:2}${id:4:2}${id:2:2}${id:0:2}" | tr '[:upper:]' '[:lower:]'
}

status_find_recent_raw_for_id() {
  local id="$1"
  local le raw
  le="$(id_to_le_hex "${id}")"
  [[ -n "${le}" ]] || return 1
  tac "${STATUS_RECENT_RAW_FILE}" 2>/dev/null | while IFS=$'\t' read -r ts len raw; do
    raw="$(echo "${raw:-}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${raw}" == *"${le}"* ]]; then
      printf '%s\t%s\t%s\n' "${ts}" "${len}" "${raw}"
      return 0
    fi
  done
}

# Atomic, serialized replace-or-insert for a single-keyed TSV file.
# Holds an exclusive flock on FILE.lock for the entire read-modify-write.
# Uses mktemp so concurrent writers never collide on a shared .tmp path.
_tsv_upsert() {
  local file="$1" id="$2" row="$3"
  (
    flock -x 9
    local _tmp
    _tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    awk -F '\t' -v id="${id}" '$1 != id {print}' "${file}" 2>/dev/null > "${_tmp}" || true
    printf '%s\n' "${row}" >> "${_tmp}"
    mv "${_tmp}" "${file}" 2>/dev/null || { rm -f "${_tmp}"; true; }
  ) 9>"${file}.lock"
}

_upsert_candidate_row() {
  local _id="$1" _driver="$2" _type="$3" _last_seen="$4" _seen_count="$5"
  local _avg_interval_s="$6" _seen_15m="$7" _seen_60m="$8" _manufacturer="${9:-}"
  local _file="${STATUS_CANDIDATES_FILE}"
  (
    flock -x 9
    local _tmp
    _tmp="$(mktemp "${_file}.tmp.XXXXXX")" || return 1
    if ! awk -F $'\t' -v OFS=$'\t' \
      -v id="${_id}" \
      -v driver="${_driver}" \
      -v type_line="${_type}" \
      -v last_seen="${_last_seen}" \
      -v seen_count="${_seen_count}" \
      -v avg_interval_s="${_avg_interval_s}" \
      -v seen_15m="${_seen_15m}" \
      -v seen_60m="${_seen_60m}" \
      -v manufacturer="${_manufacturer}" '
        BEGIN { final_manufacturer = manufacturer }
        $1 == id {
          if (final_manufacturer == "" && NF >= 9 && $9 != "") {
            final_manufacturer = $9
          }
          next
        }
        { print }
        END {
          print id, driver, type_line, last_seen, seen_count, avg_interval_s, seen_15m, seen_60m, final_manufacturer
        }
      ' "${_file}" > "${_tmp}"; then
      rm -f "${_tmp}"
      return 1
    fi
    if ! mv "${_tmp}" "${_file}"; then
      rm -f "${_tmp}"
      return 1
    fi
  ) 9>"${STATUS_CANDIDATES_FILE}.lock"
}

# Write or update a per-candidate preview lifecycle state row.
# States: pending | decoded_value | decoded_without_numeric_value | no_decode_result
_set_preview_state() {
  local id="$1" state="$2" note="${3:-}"
  _tsv_upsert "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s' "${id}" "${state}" "$(iso_now)" "${note}")"
  # Discard the attempt counter once a terminal decode outcome is known.
  case "${state}" in
    decoded_value|decoded_without_numeric_value|no_decode_result)
      rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
      ;;
  esac
}

# Debounced .reload_listen trigger — at most one LISTEN restart per 10 seconds.
# When called within the cooldown window a single deferred fire is scheduled via
# a background sleep so all meter-preview-<id> files written during the burst are
# picked up on the next restart (supervisor loop polls every 2 s).
#
# Pending marker: mkdir is atomic on POSIX — exactly one concurrent caller wins
# the race and schedules the background worker; the others are silently no-ops.
# The worker sleeps only the remaining cooldown time (not a full 10 s), so a
# candidate detected near the end of a window reloads as soon as the gate opens.
_request_listen_reload() {
  local gate="${BASE}/.reload_listen_gate"
  local pending="${BASE}/.reload_listen_pending"
  local now last remaining
  now="$(date +%s 2>/dev/null || echo 0)"
  last="$(cat "${gate}" 2>/dev/null || echo 0)"
  if (( now - last >= 10 )); then
    log_debug "[DIAG] reload_listen: immediate (elapsed=$(( now - last ))s >= 10s)"
    printf '%s\n' "${now}" > "${gate}"
    touch "${BASE}/.reload_listen" 2>/dev/null || true
    log_debug "[DIAG] reload_listen: touched .reload_listen"
  elif mkdir "${pending}" 2>/dev/null; then
    remaining=$(( 10 - (now - last) ))
    (( remaining < 1 )) && remaining=1
    log_debug "[DIAG] reload_listen: deferred in ${remaining}s (elapsed=$(( now - last ))s < 10s)"
    ( sleep "${remaining}"; rmdir "${pending}" 2>/dev/null; printf '%s\n' "$(date +%s)" > "${gate}"; touch "${BASE}/.reload_listen" 2>/dev/null; log_debug "[DIAG] reload_listen: deferred fired, touched .reload_listen" ) 2>/dev/null &
  else
    log_debug "[DIAG] reload_listen: suppressed (pending already set, elapsed=$(( now - last ))s)"
  fi
}

status_upsert_candidate_analysis() {
  local id
  local encryption="$2"
  local note="$3"
  local ci="${4:-}"
  local security="${5:-}"
  local raw_len="${6:-0}"
  local last_seen="${7:-}"

  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${last_seen}" ]] || last_seen="$(iso_now)"

  _tsv_upsert "${STATUS_CANDIDATE_ANALYSIS_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "${id}" "${encryption:-unknown}" "${note:-}" "${ci:-}" "${security:-}" "${raw_len:-0}" "${last_seen}")"
}

candidate_autodecode_file() {
  local id="$1"
  printf '%s/meter-preview-%s' "${LISTEN_METER_DIR}" "${id}"
}

candidate_type_requires_aes() {
  local type_lc
  type_lc="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "${type_lc}" == *not\ encrypted* || "${type_lc}" == *unencrypted* || "${type_lc}" == *no\ aes* || "${type_lc}" == *no_aes* ]] && return 1
  [[ "${type_lc}" == *encrypted* || "${type_lc}" == *aes* ]]
}

ensure_candidate_autodecode() {
  local id
  local driver="${2:-auto}"
  local type_line="${3:-}"
  local reload="${4:-true}"
  local file tmp

  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  file="$(candidate_autodecode_file "${id}")"

  # Skip preview for officially configured meters — they decode via the primary pipeline.
  # Checked via METER_DIR on disk so the guard works in LISTEN subshell forks where
  # in-memory variables from the parent process are stale after a soft pipeline reload.
  if grep -ql "^id=${id,,}$" "${METER_DIR}"/meter-* 2>/dev/null; then
    if [[ -f "${file}" ]]; then
      rm -f "${file}" 2>/dev/null || true
      rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
      log "autodecode ${id}: skipped (official meter), pruned orphaned preview"
      [[ "${reload}" == "true" ]] && _request_listen_reload
    fi
    return 0
  fi

  log_debug "[DIAG] autodecode ${id}: file=${file} driver=${driver:-auto} type=${type_line:-?} reload=${reload}"

  if candidate_type_requires_aes "${type_line}"; then
    log_verbose "[DIAG] autodecode ${id}: AES required, skipping preview"
    if [[ -f "${file}" ]]; then
      rm -f "${file}" 2>/dev/null || true
      rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
      if [[ "${reload}" == "true" ]]; then
        # Preview files live in LISTEN_METER_DIR — only the LISTEN instance
        # needs reloading. Do NOT touch RELOAD_FLAG/.reload_pipeline here: that
        # restarts the main DECODE pipeline on every new candidate (churn loop).
        _request_listen_reload
      fi
    fi
    return 0
  fi

  mkdir -p "${LISTEN_METER_DIR}" 2>/dev/null || true
  tmp="${file}.tmp"
  {
    echo "name=preview_${id}"
    echo "id=${id,,}"
    if [[ -n "${driver}" && "${driver}" != "auto" && "${driver}" != "unknown" ]]; then
      echo "driver=${driver}"
    fi
  } > "${tmp}" 2>/dev/null || return 0

  if [[ ! -f "${file}" ]] || ! cmp -s "${tmp}" "${file}" 2>/dev/null; then
    mv "${tmp}" "${file}" 2>/dev/null || true
    log_verbose "[DIAG] autodecode ${id}: wrote ${file} (driver=${driver:-auto})"
    _set_preview_state "${id}" "pending"
    rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
    if [[ "${reload}" == "true" ]]; then
      # Only the LISTEN instance reads these preview files — reload just it.
      # Touching RELOAD_FLAG/.reload_pipeline would needlessly restart the main
      # DECODE pipeline on every newly heard candidate (the churn seen in logs).
      # _request_listen_reload debounces bursts (many new candidates at once)
      # to at most one restart per 10 s, with a deferred fire for late arrivals.
      _request_listen_reload
    fi
  else
    rm -f "${tmp}" 2>/dev/null || true
    log_debug "[DIAG] autodecode ${id}: ${file} unchanged, no reload triggered"
  fi
}

sync_candidate_autodecode_files() {
  local id driver type_line rest
  [[ -f "${STATUS_CANDIDATES_FILE}" ]] || return 0
  while IFS=$'\t' read -r id driver type_line rest; do
    id="$(normalize_meter_id "${id}")"
    [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || continue
    ensure_candidate_autodecode "${id}" "${driver:-auto}" "${type_line:-}" "false"
  done < "${STATUS_CANDIDATES_FILE}"
}

# Remove meter-preview-<id> files for IDs that are now official configured meters.
# Called after sync_candidate_autodecode_files() to override any preview file it may
# have written for a candidate that was concurrently promoted to official status.
# Also removes the corresponding .preview_attempts/<id> counter.
# Does NOT touch status_candidate_values.tsv or status_candidate_preview_state.tsv.
prune_official_meter_previews() {
  local mid pf _pruned=0
  [[ -d "${METER_DIR}" ]] || return 0
  for mf in "${METER_DIR}"/meter-*; do
    [[ -f "${mf}" ]] || continue
    mid="$(grep -m1 '^id=' "${mf}" | cut -d= -f2 | tr '[:lower:]' '[:upper:]')"
    [[ "${mid}" =~ ^[0-9A-Fa-f]{8}$ ]] || continue
    pf="${LISTEN_METER_DIR}/meter-preview-${mid}"
    if [[ -f "${pf}" ]]; then
      rm -f "${pf}" 2>/dev/null || true
      rm -f "${BASE}/.preview_attempts/${mid}" 2>/dev/null || true
      log "pruned orphaned meter-preview-${mid} (now official configured meter)"
      _pruned=1
    fi
  done
  [[ "${_pruned}" -eq 1 ]] && _request_listen_reload
}

status_record_candidate_raw() {
  local id
  local raw="$2"
  local ts="${3:-}"
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${raw}" ]] || return 0
  [[ -n "${ts}" ]] || ts="$(iso_now)"

  _tsv_upsert "${STATUS_CANDIDATE_RAW_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s' "${id}" "${ts}" "${#raw}" "${raw}")"
}

status_analyze_candidate_from_text() {
  local id
  local driver="${2:-auto}"
  local type_line="${3:-}"
  local type_lc raw_row raw_ts raw_len raw ci encryption note security

  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  type_lc="$(echo "${type_line}" | tr '[:upper:]' '[:lower:]')"

  raw_row="$(status_find_recent_raw_for_id "${id}" || true)"
  raw_ts=""
  raw_len="0"
  raw=""
  if [[ -n "${raw_row}" ]]; then
    IFS=$'\t' read -r raw_ts raw_len raw <<< "${raw_row}"
    status_record_candidate_raw "${id}" "${raw}" "${raw_ts}"
    # Best-effort CI position for normal wM-Bus DLL frames:
    # L(1), C(1), M(2), A/id+ver+type(6), CI(1) => byte offset 10 => hex offset 20.
    # This is metadata only. AES decision below does NOT rely on this guess.
    if [[ "${#raw}" -ge 22 ]]; then
      ci="${raw:20:2}"
    else
      ci=""
    fi
  else
    ci=""
  fi

  security=""

  # Do not guess encryption from driver. Only use explicit backend evidence:
  # 1) wmbusmeters/listen text explicitly says encrypted/AES,
  # 2) process_search_json marks a temporary no-key search meter as decoded.
  if candidate_type_requires_aes "${type_line}"; then
    encryption="aes_required"
    note="wmbusmeters/listen output explicitly reports encrypted/AES telegram"
  elif [[ -n "${raw}" ]]; then
    encryption="unknown"
    note="RAW was mapped to this candidate, but no backend security parser has classified AES yet"
  else
    encryption="unknown"
    note="No RAW/security analysis mapped to this candidate yet"
  fi

  status_upsert_candidate_analysis "${id}" "${encryption}" "${note}" "${ci}" "${security}" "${raw_len}" "$(iso_now)"
}

status_mark_search_decoded_no_aes() {
  local json_line="$1"
  local id meter media field
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  # Search temporary meters are created without key=. If wmbusmeters decodes
  # numeric JSON from such a meter, then no AES key was required for that telegram.
  if is_search_temp_json "${json_line}"; then
    meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
    media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
    field="$(jq -r 'to_entries[] | select((.value|type)=="number") | .key' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
    status_upsert_candidate_analysis "${id}" "no_aes" "Temporary SEARCH meter decoded without key; no AES key was required for this telegram" "" "" "0" "$(iso_now)"
  fi
}

search_record_match() {
  local json_line="$1"
  local field="$2"
  local value="$3"
  local diff="$4"
  local id meter media now tmp

  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
  media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
  now="$(iso_now)"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${now}" "${id}" "${meter:-auto}" "${media:-}" "${field}" "${value}" "${SEARCH_EXPECTED_VALUE_M3}" "${diff}" "${SEARCH_TOLERANCE_M3}" >> "${SEARCH_MATCHES_FILE}" 2>/dev/null || true
  tail -n 100 "${SEARCH_MATCHES_FILE}" > "${SEARCH_MATCHES_FILE}.tmp" 2>/dev/null && mv "${SEARCH_MATCHES_FILE}.tmp" "${SEARCH_MATCHES_FILE}" 2>/dev/null || true
}

write_status_json() {
  local tmp="${STATUS_JSON}.tmp"
  # RAW is counted in a process-substitution/subshell created by tee.
  # Keep it in files too, otherwise later writes from the main shell
  # would overwrite raw_count back to 0.
  STATUS_RAW_COUNT="$(status_read_raw_count)"
  STATUS_LAST_RAW_SEEN="$(status_read_last_raw_seen)"
  # discovery_published is file-backed too (see STATUS_DISCOVERY_FLAG) so the
  # frequent raw-counter subshell can't clobber a 'true' set by the decode loop.
  local _disc_pub="${STATUS_DISCOVERY_PUBLISHED}" _disc_at="${STATUS_DISCOVERY_PUBLISHED_AT}"
  if [[ -s "${STATUS_DISCOVERY_FLAG}" ]]; then
    _disc_pub="true"
    _disc_at="$(head -n1 "${STATUS_DISCOVERY_FLAG}" 2>/dev/null || true)"
  fi
  jq -n     --arg updated_at "$(iso_now)"     --arg raw_topic "${RAW_TOPIC:-}"     --arg state_prefix "${STATE_PREFIX:-}"     --arg discovery_prefix "${DISCOVERY_PREFIX:-}"     --arg search_mode "${SEARCH_MODE:-false}"     --arg loglevel "${LOGLEVEL:-}"     --arg mqtt_host "${MQTT_HOST:-}"     --arg mqtt_port "${MQTT_PORT:-}"     --arg mqtt_connected "${STATUS_MQTT_CONNECTED}"     --arg wmbusmeters_running "${STATUS_WMBUSMETERS_RUNNING}"     --arg raw_count "${STATUS_RAW_COUNT}"     --arg decoded_count "${STATUS_DECODED_COUNT}"     --arg discovery_published "${_disc_pub}"     --arg discovery_published_at "${_disc_at}"     --arg last_raw_seen "${STATUS_LAST_RAW_SEEN}"     --arg last_decoded_seen "${STATUS_LAST_DECODED_SEEN}"     --arg last_error "${STATUS_LAST_ERROR}"     --arg last_event "${STATUS_LAST_EVENT}"     '{updated_at:$updated_at,
      config:{raw_topic:$raw_topic,state_prefix:$state_prefix,discovery_prefix:$discovery_prefix,search_mode:($search_mode=="true"),loglevel:$loglevel},
      mqtt:{host:$mqtt_host,port:$mqtt_port,connected:($mqtt_connected=="true")},
      pipeline:{raw_count:($raw_count|tonumber? // 0),decoded_count:($decoded_count|tonumber? // 0),wmbusmeters_running:($wmbusmeters_running=="true"),discovery_published:($discovery_published=="true"),discovery_published_at:$discovery_published_at,last_raw_seen:$last_raw_seen,last_decoded_seen:$last_decoded_seen,last_error:$last_error,last_event:$last_event}}'     > "${tmp}" 2>/dev/null && mv "${tmp}" "${STATUS_JSON}" 2>/dev/null || true
}

_select_primary_meter_value() {
  local json_line="$1"
  jq -r '
    [ "total_m3",
      "total_kwh",
      "total_wh",
      "total_energy_consumption_kwh",
      "total_volume_m3" ] as $canonical
    | (
        [ $canonical[] as $k
          | select((.[$k] | type) == "number")
          | [$k, .[$k]]
        ][0]
        // [ to_entries[]
          | select((.value|type)=="number")
          | select(.key|test("(^total|_m3$|kwh|wh$|energy|volume)";"i"))
          | select(.key|test("(last_month|last_year|previous_month|previous_year|previous|prev|at_history|history|historic|billing|due_date|target|backflow|fraud|leak|tamper|alarm|production|tariff)";"i")|not)
          | [.key, .value]
        ][0]
      )
    | if . == null then empty else @tsv end
  ' <<<"${json_line}" 2>/dev/null | head -n 1 || true
}

status_mark_discovery_published() {
  STATUS_DISCOVERY_PUBLISHED="true"
  STATUS_DISCOVERY_PUBLISHED_AT="$(iso_now)"
  # Persist to a file so the flag survives subshell isolation — every other
  # subshell's write_status_json reads it (see STATUS_DISCOVERY_FLAG). Without
  # this, the raw-counter subshell (stale STATUS_DISCOVERY_PUBLISHED=false)
  # overwrites status.json back to "pending" on every raw telegram.
  printf '%s\n' "${STATUS_DISCOVERY_PUBLISHED_AT}" > "${STATUS_DISCOVERY_FLAG}.tmp" 2>/dev/null \
    && mv "${STATUS_DISCOVERY_FLAG}.tmp" "${STATUS_DISCOVERY_FLAG}" 2>/dev/null || true
}

status_raw_seen() {
  local raw="${1:-}"
  # If a RAW telegram arrived from mosquitto_sub, MQTT and the input pipeline
  # are alive even if no configured meter JSON has been decoded yet.
  STATUS_MQTT_CONNECTED="true"
  STATUS_WMBUSMETERS_RUNNING="true"
  status_store_raw_seen "$(iso_now)"
  status_store_recent_raw "${raw}"
  status_raw_candidate_seen "${raw}"
  if (( STATUS_RAW_COUNT == 1 || STATUS_RAW_COUNT % 25 == 0 )); then
    status_add_event "ok" "RAW telegram received (${#raw} hex chars)"
  fi

  # Per-minute rate tracking for the WebGUI live dashboard.
  # Telegrams arriving within the same 60-second bucket increment current_min.
  # When the minute turns, current_min is rotated into prev_min and reset to 1.
  local _now_epoch _cur_min
  _now_epoch="$(epoch_now)"
  _cur_min=$(( _now_epoch / 60 ))
  if [[ "${RAW_RATE_CUR_MIN_EPOCH}" -ne "${_cur_min}" ]]; then
    # Minute boundary crossed: archive the finished minute's count into the
    # 15-entry rolling history (skip when there was no previous minute yet —
    # RAW_RATE_CUR_MIN_EPOCH==0 means this is the very first telegram). The
    # _prev_min epoch lets the WebGUI place each bar correctly on the axis.
    if [[ "${RAW_RATE_CUR_MIN_EPOCH}" -ne 0 ]]; then
      local _hist_tmp="${STATUS_RATE_HISTORY_FILE}.tmp"
      {
        tail -n 14 "${STATUS_RATE_HISTORY_FILE}" 2>/dev/null || true
        printf '%d\t%d\n' "${RAW_RATE_CUR_MIN_EPOCH}" "${RAW_RATE_CUR_MIN_COUNT}"
      } > "${_hist_tmp}" 2>/dev/null \
        && mv "${_hist_tmp}" "${STATUS_RATE_HISTORY_FILE}" 2>/dev/null || true
    fi
    RAW_RATE_PREV_MIN_COUNT="${RAW_RATE_CUR_MIN_COUNT}"
    RAW_RATE_CUR_MIN_COUNT=1
    RAW_RATE_CUR_MIN_EPOCH="${_cur_min}"
  else
    RAW_RATE_CUR_MIN_COUNT=$(( RAW_RATE_CUR_MIN_COUNT + 1 ))
  fi
  printf '{"current_min":%d,"prev_min":%d,"epoch":%d}\n' \
    "${RAW_RATE_CUR_MIN_COUNT}" "${RAW_RATE_PREV_MIN_COUNT}" "${_now_epoch}" \
    > "${STATUS_RATE_1M_FILE}.tmp" 2>/dev/null \
    && mv "${STATUS_RATE_1M_FILE}.tmp" "${STATUS_RATE_1M_FILE}" 2>/dev/null || true

  write_status_json
}

status_meter_seen() {
  local json_line="$1"
  local id name meter media value_key value value_parts last_seen
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  name="$(jq -r '.name // empty' <<<"${json_line}" 2>/dev/null || true)"
  meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
  media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
  value_parts="$(jq -rc '
    [to_entries[]
      | select((.value|type)=="number")
      | select(.key|test("^total_energy_consumption_tariff_[0-9]+_kwh$";"i"))
      | . as $entry
      | ($entry.key | capture("^total_energy_consumption_tariff_(?<tariff>[0-9]+)_kwh$";"i")) as $m
      | {label: ("T" + $m.tariff), key: $entry.key, value: $entry.value, order: ($m.tariff|tonumber)}
    ]
    | sort_by(.order)
    | map(del(.order))
    | if length > 0 then . else empty end
  ' <<<"${json_line}" 2>/dev/null || true)"
  # Prefer the cumulative METER READING (what's shown on the meter's own
  # display) as the primary value — total_m3, total_energy_consumption_kwh,
  # etc. Consistent across media: water shows total_m3, electricity shows
  # total_energy_consumption_kwh (not the live kW draw). Exclude production,
  # raw tariff registers and fault/alarm counters on the first pass; if an
  # electricity meter only publishes consumption tariffs, sum them below.
  IFS=$'\t' read -r value_key value < <(_select_primary_meter_value "${json_line}") || true
  if [[ -z "${value_key}" ]]; then
    # Some electricity meters publish only per-tariff import registers. When
    # the aggregate total is missing, sum consumption tariffs and expose that
    # as the meter reading. Production tariffs remain excluded.
    IFS=$'\t' read -r value_key value < <(
      jq -r '
        [to_entries[]
          | select((.value|type)=="number")
          | select(.key|test("^total_energy_consumption_tariff_[0-9]+_kwh$";"i"))
          | .value] as $vals
        | if ($vals|length) > 0 then "total_energy_consumption_kwh\t\($vals|add)" else empty end
      ' <<<"${json_line}" 2>/dev/null | head -n 1
    ) || true
  fi
  if [[ -z "${value_key}" ]]; then
    # This telegram carries NO cumulative total. Some electricity meters send
    # mostly instantaneous-only telegrams (current_power, voltage) and a total
    # only occasionally. Do NOT downgrade a meter that already showed a
    # total — reuse the last cumulative reading from the TSV so the value stays
    # the meter reading and does not flicker back to the live kW draw on every
    # power-only telegram. For electricity, never show live power as the meter
    # reading; leave the value empty until a cumulative total arrives. Other
    # media keep the historical instantaneous fallback.
    local prev_key prev_val prev_parts
    IFS=$'\t' read -r prev_key prev_val prev_parts < <(awk -F '\t' -v id="${id}" '$1==id {print $5 "\t" $6 "\t" $13; exit}' "${STATUS_METERS_FILE}" 2>/dev/null || true)
    if [[ -n "${prev_key}" ]] \
       && printf '%s' "${prev_key}" | grep -qiE '(^total|_m3$|kwh|wh$|energy|volume)' \
       && ! printf '%s' "${prev_key}" | grep -qiE '(last_month|last_year|previous_month|previous_year|previous|prev|at_history|history|historic|billing|due_date|target|backflow|fraud|leak|tamper|alarm|production|tariff)'; then
      value_key="${prev_key}"
      value="${prev_val}"
      value_parts="${prev_parts}"
    else
      local media_lc meter_lc
      media_lc="$(printf '%s' "${media}" | tr '[:upper:]' '[:lower:]')"
      meter_lc="$(printf '%s' "${meter}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${media_lc}" == *electric* || "${media_lc}" == *energy* || "${meter_lc}" == *electric* ]] \
         || jq -e 'any(to_entries[]; (.key | test("(energy|power|voltage|current).*(_kwh|_wh|_kw|_w|_v|_a)$"; "i")))' <<<"${json_line}" >/dev/null 2>&1; then
        value_key=""
        value=""
      else
        value_key="$(jq -r 'to_entries[] | select((.value|type)=="number") | select(.key|test("(_kw$|_w$|_m3h$|_l_h$)";"i")) | .key' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
        if [[ -n "${value_key}" ]]; then
          value="$(jq -r --arg k "${value_key}" '.[$k] // empty' <<<"${json_line}" 2>/dev/null || true)"
        else
          value_key="value"
          value="$(jq -r 'to_entries[] | select((.value|type)=="number") | .value' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
        fi
      fi
    fi
  fi
  status_record_seen "${id}" "meter"
  last_seen="$(iso_now)"
  IFS=$'\t' read -r seen_count avg_interval_s seen_15m seen_60m < <(status_seen_stats "${id}" "meter")
  _tsv_upsert "${STATUS_METERS_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "${id}" "${name}" "${meter}" "${media}" "${value_key}" "${value}" "${last_seen}" "published" "${seen_count}" "${avg_interval_s}" "${seen_15m}" "${seen_60m}" "${value_parts}")"
}

status_candidate_seen() {
  local id
  local driver="${2:-auto}"
  local type_line="${3:-}"
  local update_status="${4:-true}"
  local manufacturer="${5:-}"
  local now
  STATUS_WMBUSMETERS_RUNNING="true"
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  local existed="false"
  if grep -q "^${id}	" "${STATUS_CANDIDATES_FILE}" 2>/dev/null; then
    existed="true"
  fi
  status_record_seen "${id}" "candidate"
  now="$(iso_now)"
  IFS=$'\t' read -r seen_count avg_interval_s seen_15m seen_60m < <(status_seen_stats "${id}" "candidate")
  _upsert_candidate_row "${id}" "${driver}" "${type_line}" "${now}" "${seen_count}" "${avg_interval_s}" "${seen_15m}" "${seen_60m}" "${manufacturer}"
  status_analyze_candidate_from_text "${id}" "${driver}" "${type_line}"
  ensure_candidate_autodecode "${id}" "${driver:-auto}" "${type_line:-}"
  if [[ "${existed}" != "true" ]]; then
    status_add_event "candidate" "Candidate detected ${id} (${driver})"
  fi
  [[ "${update_status}" == "true" ]] && write_status_json
}

json_get() {
  local expr="$1"
  local def="${2:-}"
  if [[ -f "${OPTIONS_JSON}" ]]; then
    local v
    v="$(jq -r "${expr} // empty" "${OPTIONS_JSON}" 2>/dev/null || true)"
    if [[ -n "${v}" && "${v}" != "null" ]]; then
      echo "${v}"
      return 0
    fi
  fi
  echo "${def}"
}

json_get_bool() {
  local expr="$1"
  local def="${2:-true}"
  local v
  v="$(json_get "${expr}" "")"
  if [[ "${v}" == "true" || "${v}" == "false" ]]; then
    echo "${v}"
  else
    echo "${def}"
  fi
}

json_get_int() {
  local expr="$1"
  local def="${2:-0}"
  local v
  v="$(json_get "${expr}" "")"
  if [[ "${v}" =~ ^-?[0-9]+$ ]]; then
    echo "${v}"
  else
    echo "${def}"
  fi
}

# ------------------------------------------------------------
# Config (ENV overrides JSON)
# ------------------------------------------------------------
RAW_TOPIC="${RAW_TOPIC:-$(json_get '.raw_topic' 'wmbus_bridge/+/telegram')}"
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
log "MQTT: ${MQTT_HOST}:${MQTT_PORT} topic=${RAW_TOPIC}"
log "state: prefix=${STATE_PREFIX} retain=${STATE_RETAIN}"
log "discovery: enabled=${DISCOVERY_ENABLED} prefix=${DISCOVERY_PREFIX} retain=${DISCOVERY_RETAIN}"
log "wmbusmeters: loglevel=${LOGLEVEL} filter_hex_only=${FILTER_HEX_ONLY} debug_every_n=${DEBUG_EVERY_N}"
log "search: mode=${SEARCH_MODE} expected_value_m3=${SEARCH_EXPECTED_VALUE_M3} tolerance_m3=${SEARCH_TOLERANCE_M3} delta_mode=${SEARCH_DELTA_MODE} min_delta_m3=${SEARCH_MIN_DELTA_M3} topic=${SEARCH_TOPIC}"
log "robust: ignore_retained=${IGNORE_RETAINED} require_timestamp=${REQUIRE_TIMESTAMP} restart_on_exit=${RESTART_ON_EXIT}"
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

# Background subscriber for ESP diagnostic summaries (wmbus/+/diag/summary).
# ESP publishes every 60 s: {"event":"summary","interval_s":60,"total":N,...}
# bridge.sh injects _bridge_rx_epoch so webui.py can check freshness.
# When fresh (<90 s) webui.py uses ESP's exact "total" count as the live rate
# instead of its own per-minute counting — more accurate source of truth.
STATUS_ESP_DIAG_FILE="${BASE}/status_esp_diag.json"
(
  while true; do
    # -F '%t\t%p' = "topic<TAB>payload" so we can record which ESP device sent
    # the summary. The topic segment between wmbus/ and /diag/summary is the
    # ESP device name (e.g. "esphome-wmbus-tx-lilygo"). webui.py uses _topic
    # to display the source in the Pipeline ESP node and to detect when more
    # than one ESP is publishing.
    while IFS=$'\t' read -r _diag_topic _diag_line; do
          [[ -n "${_diag_line}" ]] || continue
          _ts="$(date +%s 2>/dev/null || echo 0)"
          printf '%s\n' "${_diag_line}" \
            | jq --argjson t "${_ts}" --arg topic "${_diag_topic:-}" '. + {_bridge_rx_epoch: $t, _topic: $topic}' 2>/dev/null \
            > "${STATUS_ESP_DIAG_FILE}.tmp" \
            && mv "${STATUS_ESP_DIAG_FILE}.tmp" "${STATUS_ESP_DIAG_FILE}" 2>/dev/null \
            || true
        done < <(
          ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "wmbus/+/diag/summary" -F '%t\t%p' -W 90 2>/dev/null
        )
    sleep 5
  done
) &

# Background subscriber for per-ESP-device telegram tracking.
# Listens to the RAW telegram topic (with wildcard) and records each
# distinct device name + last-seen epoch + telegram count to a TSV.
# This is the SOURCE OF TRUTH for "which ESPs are alive right now" —
# telegrams arrive live, not retained, so dead ESPs naturally age out.
# Works even when the ESP has NO diagnostic publishing enabled.
#
# The device name is whatever segment of the received topic matches the
# `+` wildcard in RAW_TOPIC (e.g. RAW_TOPIC="wmbus/+/telegram", topic
# "wmbus/xiaoseed/telegram" → device "xiaoseed"). If RAW_TOPIC has no
# wildcard at all, this loop still runs but produces no device data
# (and the WebGUI falls back to diag-based detection as before).
(
  # Pre-compute which segment of RAW_TOPIC holds the device name.
  IFS='/' read -ra _RT_PARTS <<< "${RAW_TOPIC}"
  _RT_DEV_POS=-1
  for _i in "${!_RT_PARTS[@]}"; do
    if [[ "${_RT_PARTS[$_i]}" == "+" ]]; then
      _RT_DEV_POS="${_i}"
      break
    fi
  done

  if [[ "${_RT_DEV_POS}" -ge 0 ]]; then
    log "ESP-device tracker: device name at topic segment ${_RT_DEV_POS} of '${RAW_TOPIC}'"
    while true; do
      # Read via process substitution, not a pipe: with set -euo pipefail a
      # mosquitto_sub timeout/disconnect would otherwise kill this tracker.
      while IFS= read -r _tg_topic; do
        [[ -n "${_tg_topic}" ]] || continue
        IFS='/' read -ra _T_PARTS <<< "${_tg_topic}"
        _dev="${_T_PARTS[${_RT_DEV_POS}]:-}"
        [[ -n "${_dev}" ]] || continue
        _now=$(date +%s 2>/dev/null || echo 0)
        _tmp="${STATUS_ESP_TELEGRAM_DEVICES_FILE}.tmp"
        # Upsert the row for this device — increment count if exists,
        # otherwise append a fresh row with count=1.
        awk -F'\t' -v dev="${_dev}" -v now="${_now}" -v tg="${_tg_topic}" '
          BEGIN { upd=0 }
          $1 == dev {
            cnt = (NF >= 4 ? $4+1 : 1)
            print dev "\t" now "\t" tg "\t" cnt
            upd=1
            next
          }
          { print }
          END { if (!upd) print dev "\t" now "\t" tg "\t1" }
        ' "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" 2>/dev/null > "${_tmp}" \
          && mv "${_tmp}" "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" 2>/dev/null \
          || true
      done < <(
        ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" "${SUB_EXTRA[@]}" -t "${RAW_TOPIC}" -F '%t' -W 180 2>/dev/null
      )
      sleep 5
    done
  else
    log "ESP-device tracker: RAW_TOPIC '${RAW_TOPIC}' has no '+' wildcard — per-device tracking disabled."
  fi
) &

# Background subscriber for all ESP diagnostic events.
# Subscribes to bare diag topic (dropped/truncated/rx_path) and all subtopics.
# Writes TSV: epoch<TAB>evtype<TAB>topic<TAB>payload  (rolling 200 lines).
# Extracts suggestion and boot events to their own JSON files for webui detail panels.
STATUS_ESP_EVENTS_FILE="${BASE}/status_esp_events.tsv"
STATUS_ESP_SUGGESTION_FILE="${BASE}/status_esp_suggestion.json"
STATUS_ESP_BOOT_FILE="${BASE}/status_esp_boot.json"
touch "${STATUS_ESP_EVENTS_FILE}" 2>/dev/null || true
(
  _n=0
  while true; do
    while IFS=$'\t' read -r _etopic _epayload; do
      [[ -n "${_etopic}" ]] || continue
      [[ -n "${_epayload}" ]] || continue
      _ets="$(date +%s 2>/dev/null || echo 0)"
      _evtype="$(printf '%s\n' "${_epayload}" | jq -r '.event // "unknown"' 2>/dev/null || echo "unknown")"
      [[ -n "${_evtype}" && "${_evtype}" != "null" ]] || _evtype="unknown"
      # summary_15min and summary_60min publish JSON with "event":"summary" (same as 60s).
      # Override evtype from the MQTT topic suffix so they appear distinctly in the log.
      case "${_etopic}" in
        */summary_15min) _evtype="summary_15min" ;;
        */summary_60min) _evtype="summary_60min" ;;
      esac
      printf '%s\t%s\t%s\t%s\n' "${_ets}" "${_evtype}" "${_etopic}" "${_epayload}" \
        >> "${STATUS_ESP_EVENTS_FILE}" 2>/dev/null || true
      _n=$(( _n + 1 ))
      if (( _n % 50 == 0 )); then
        tail -n 200 "${STATUS_ESP_EVENTS_FILE}" > "${STATUS_ESP_EVENTS_FILE}.tmp" 2>/dev/null \
          && mv "${STATUS_ESP_EVENTS_FILE}.tmp" "${STATUS_ESP_EVENTS_FILE}" 2>/dev/null || true
      fi
      if [[ "${_evtype}" == "suggestion" ]]; then
        printf '%s\n' "${_epayload}" \
          | jq --argjson t "${_ets}" '. + {_bridge_rx_epoch: $t}' 2>/dev/null \
          > "${STATUS_ESP_SUGGESTION_FILE}.tmp" \
          && mv "${STATUS_ESP_SUGGESTION_FILE}.tmp" "${STATUS_ESP_SUGGESTION_FILE}" 2>/dev/null \
          || true
      fi
      if [[ "${_evtype}" == "boot" ]]; then
        printf '%s\n' "${_epayload}" \
          | jq --argjson t "${_ets}" '. + {_bridge_rx_epoch: $t}' 2>/dev/null \
          > "${STATUS_ESP_BOOT_FILE}.tmp" \
          && mv "${STATUS_ESP_BOOT_FILE}.tmp" "${STATUS_ESP_BOOT_FILE}" 2>/dev/null \
          || true
        # Clear stale suggestion on ESP reboot — suggestions from previous session
        # are no longer actionable after the ESP restarts.
        rm -f "${STATUS_ESP_SUGGESTION_FILE}" 2>/dev/null || true
      fi
    done < <(
      ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" \
        -t "wmbus/+/diag" -t "wmbus/+/diag/#" \
        -F '%t\t%p' -W 180 2>/dev/null
    )
    sleep 5
  done
) &

mqtt_pub() {
  local topic="$1"
  local payload="$2"
  local retain="${3:-false}"

  local retain_flag=()
  [[ "${retain}" == "true" ]] && retain_flag=( -r )

  /usr/bin/mosquitto_pub "${PUB_ARGS[@]}" -t "${topic}" "${retain_flag[@]}" -m "${payload}" || true
}

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
# Helpers
# ------------------------------------------------------------
meter_id_from_raw_hex() {
  local raw="$1"
  local byte_count lfield id_le

  [[ "${raw}" =~ ^[0-9A-F]+$ ]] || { echo ""; return 0; }
  [[ "${#raw}" -ge 22 ]] || { echo ""; return 0; }
  (( ${#raw} % 2 == 0 )) || { echo ""; return 0; }

  byte_count=$(( ${#raw} / 2 ))
  lfield=$((16#${raw:0:2}))
  [[ "${lfield}" -eq $((byte_count - 1)) ]] || { echo ""; return 0; }

  # wMBus A-field stores the 4-byte meter ID little-endian after L/C/M-field.
  id_le="${raw:8:8}"
  echo "${id_le:6:2}${id_le:4:2}${id_le:2:2}${id_le:0:2}"
}

# Decode the 3-letter EN 13757 manufacturer code from a raw wMBus telegram.
# Frame layout (hex chars): L=0:2 C=2:4 M=4:8 A=8:20. The 2-byte M-field is
# little-endian; the 16-bit value packs three 5-bit letters (1..26 -> A..Z):
#   value = (L1<<10) | (L2<<5) | L3 , letter = code + 64.
# Returns the 3-letter code (e.g. "SAP", "DME") or "" when the field does not
# decode to three A..Z letters. Used only as a manufacturer fallback when the
# full wmbusmeters text name is not available (JSON-only candidate path).
mfct_code_from_raw_hex() {
  local raw="$1" m val l1 l2 l3
  raw="${raw//[[:space:]]/}"
  [[ "${#raw}" -ge 8 ]] || { echo ""; return 0; }
  m="${raw:4:4}"
  [[ "${m}" =~ ^[0-9A-Fa-f]{4}$ ]] || { echo ""; return 0; }
  # Byte-swap (little-endian) to get the 16-bit manufacturer value.
  val=$(( 16#${m:2:2}${m:0:2} ))
  l1=$(( (val >> 10) & 0x1f ))
  l2=$(( (val >> 5) & 0x1f ))
  l3=$(( val & 0x1f ))
  (( l1 >= 1 && l1 <= 26 && l2 >= 1 && l2 <= 26 && l3 >= 1 && l3 <= 26 )) \
    || { echo ""; return 0; }
  awk -v a="$((l1 + 64))" -v b="$((l2 + 64))" -v c="$((l3 + 64))" \
    'BEGIN { printf "%c%c%c", a, b, c }'
}

# Fallback fill of the manufacturer column (9) for an EXISTING candidate row
# whose manufacturer is still empty. Deliberately conservative:
#   - never creates a row (would spawn a phantom candidate for an official meter),
#   - only writes when column 9 is empty, so the richer full-text name captured
#     by the LISTEN text path (e.g. "DME ...") is never downgraded to the bare
#     code, and a later text update still overwrites the code via
#     _upsert_candidate_row,
#   - touches no reception stats and emits no events (no double counting).
candidate_fill_manufacturer_code() {
  local _id="$1" _code="$2"
  [[ "${_id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${_code}" ]] || return 0
  local _file="${STATUS_CANDIDATES_FILE}"
  [[ -f "${_file}" ]] || return 0
  # Cheap lock-free pre-check: only take the lock when a fillable row exists.
  awk -F '\t' -v id="${_id}" \
    '$1 == id && (NF < 9 || $9 == "") { found = 1 } END { exit found ? 0 : 1 }' \
    "${_file}" 2>/dev/null || return 0
  (
    flock -x 9
    local _tmp
    _tmp="$(mktemp "${_file}.tmp.XXXXXX")" || return 1
    if ! awk -F $'\t' -v OFS=$'\t' -v id="${_id}" -v code="${_code}" '
        $1 == id {
          while (NF < 9) { $(NF + 1) = "" }
          if ($9 == "") { $9 = code }
        }
        { print }
      ' "${_file}" > "${_tmp}"; then
      rm -f "${_tmp}"
      return 1
    fi
    if ! mv "${_tmp}" "${_file}"; then
      rm -f "${_tmp}"
      return 1
    fi
    log_debug "[DIAG] candidate ${_id}: filled manufacturer fallback code=${_code}"
  ) 9>"${STATUS_CANDIDATES_FILE}.lock"
}

# Map an OMS device-type byte (A/TYPE, raw[18:20]) to a human label. Covers the
# device types seen in practice plus a safe fallback — no need for a full
# 0x00-0xFF table.
map_device_type() {
  local dt="${1^^}"
  case "${dt}" in
    02) echo "Electricity meter (0x02)" ;;
    03) echo "Gas meter (0x03)" ;;
    04) echo "Heat meter (0x04)" ;;
    06) echo "Warm water meter (0x06)" ;;
    07) echo "Water meter (0x07)" ;;
    08) echo "Heat Cost Allocator (0x08)" ;;
    0C) echo "Heat meter inlet (0x0C)" ;;
    16) echo "Cold water meter (0x16)" ;;
    *)  printf 'Unknown meter type (0x%s)' "${dt}" ;;
  esac
}

status_raw_candidate_seen() {
  local raw="$1"
  local id mfr dev_type existing_driver

  raw="$(echo "${raw}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  id="$(meter_id_from_raw_hex "${raw}")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  # Manufacturer fallback: every raw telegram carries the M-field, so decode the
  # EN 13757 3-letter code and fill it into an existing candidate row that has no
  # manufacturer yet. This heals candidates whose only updates arrive via the
  # JSON path (a meter-preview-<id> file makes the parallel LISTEN decode the
  # telegram to JSON, which carries no manufacturer text), independent of LISTEN
  # reloads. Fill-only-when-empty keeps the full text name from the LISTEN text
  # path authoritative. Does NOT create rows or touch stats.
  local _mfct_code
  _mfct_code="$(mfct_code_from_raw_hex "${raw}")"
  [[ -n "${_mfct_code}" ]] && candidate_fill_manufacturer_code "${id}" "${_mfct_code}"

  # This runs on EVERY raw telegram (status_raw_seen) and OVERWRITES the
  # candidate row. Only register straight from the link-layer A-field for
  # Diehl/SAP IZAR (mfct 0x304C), which sometimes does NOT surface as a
  # wmbusmeters listen candidate. For every other manufacturer the normal
  # listen/decode path already provides the candidate WITH its real
  # driver/media — emitting a generic "auto / wMBus telegram" row here would
  # clobber that real classification on every raw telegram (the "auto / inne"
  # bug).
  mfr="${raw:4:4}"
  [[ "${mfr}" == "304C" ]] || return 0

  # Hard priority: a real LISTEN classification beats this RAW fallback. Without
  # this guard the fallback re-runs on every SAP telegram and keeps clobbering a
  # driver that LISTEN already resolved (e.g. non-water Diehl flapping
  # auto -> sharky -> auto). If the candidate already has a concrete driver
  # (anything other than "auto"), leave the existing row untouched.
  existing_driver="$(
    awk -F '\t' -v id="${id}" '
      $1 == id { print $2; exit }
    ' "${STATUS_CANDIDATES_FILE}" 2>/dev/null || true
  )"
  if [[ -n "${existing_driver}" && "${existing_driver}" != "auto" ]]; then
    return 0
  fi

  # A/TYPE = raw[18:20]. Diehl/SAP water (0x07) keeps the izarv2 fallback exactly
  # as before. Any other device type registers as auto + mapped label so we never
  # force izarv2 on non-water Diehl and LISTEN can later supply the real driver.
  dev_type="${raw:18:2}"
  if [[ "${dev_type}" == "07" ]]; then
    status_candidate_seen "${id}" "izarv2" "Water meter (0x07)" "false"
  else
    status_candidate_seen "${id}" "auto" "$(map_device_type "${dev_type}")" "false"
  fi
}

normalize_meter_id() {
  local mid_raw="$1"
  mid_raw="$(echo "${mid_raw}" | tr -d '[:space:]')"
  [[ -z "${mid_raw}" || "${mid_raw}" == "null" ]] && { echo ""; return 0; }

  mid_raw="${mid_raw#0x}"
  mid_raw="${mid_raw#0X}"
  mid_raw="$(echo "${mid_raw}" | tr '[:lower:]' '[:upper:]')"

  [[ "${mid_raw}" =~ ^[0-9A-F]+$ ]] || { echo ""; return 0; }

  if [[ "${#mid_raw}" -lt 8 ]]; then
    printf "%8s" "${mid_raw}" | tr ' ' '0'
  elif [[ "${#mid_raw}" -gt 8 ]]; then
    meter_id_from_raw_hex "${mid_raw}"
  else
    echo "${mid_raw}"
  fi
}

sanitize_obj_id() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9_]/_/g' -e 's/__*/_/g' -e 's/^_//' -e 's/_$//'
}

guess_unit() {
  local k
  k="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "${k}" in
    *_kvarh)   echo "kVARh";;
    *_kvah)    echo "kVAh";;
    *_m3c)     echo "m³°C";;
    *_m3ch)    echo "m³°C/h";;
    *_m3h)     echo "m³/h";;
    *_mjh)     echo "MJ/h";;
    *_kvar)    echo "kVAR";;
    *_kva)     echo "kVA";;
    *_kwh)     echo "kWh";;
    *_kw)      echo "kW";;
    *_wh)      echo "Wh";;
    *_w)       echo "W";;
    *_lh)      echo "l/h";;
    *_jh)      echo "J/h";;
    *_gj)      echo "GJ";;
    *_mj)      echo "MJ";;
    *_dbm)     echo "dBm";;
    *_hca)     echo "hca";;
    *_pct)     echo "%";;
    *_ppm)     echo "ppm";;
    *_rh|*humidity*|*hum*) echo "%";;
    *_hz)      echo "Hz";;
    *_bar)     echo "bar";;
    *_pa|*pressure*|*_hpa) echo "hPa";;
    *_m3|*volume*|*m3*)    echo "m³";;
    *_mol)     echo "mol";;
    *_min)     echo "min";;
    *_rad)     echo "rad";;
    *_deg)     echo "°";;
    *_utc|*_ut|*_datetime|*_date|*_time|*_month) echo "";;
    *_counter) echo "";;
    *_factor)  echo "";;
    *_txt)     echo "";;
    *_nr)      echo "";;
    *_kg)      echo "kg";;
    *_cd)      echo "cd";;
    *_v)       echo "V";;
    *_a)       echo "A";;
    *_k)       echo "K";;
    *temperature*|*temp*|*_c) echo "°C";;
    *_f)       echo "°F";;
    *_l)       echo "l";;
    *_m)       echo "m";;
    *_s)       echo "s";;
    *_h)       echo "h";;
    *_d)       echo "d";;
    *_y)       echo "y";;
    *)         echo "";;
  esac
}

guess_device_class() {
  local key_lc="$1"
  local unit="$2"
  local media="${3:-}"
  case "${unit}" in
    "°C") echo "temperature";;
    "%") echo "humidity";;
    "W"|"kW") echo "power";;
    "Wh"|"kWh") echo "energy";;
    "V") echo "voltage";;
    "A") echo "current";;
    "Hz") echo "frequency";;
    "dBm") echo "signal_strength";;
    "m³")
      # Prefer the media reported by wmbusmeters — it knows the meter's
      # nature better than a keyword match against the field name. Heat
      # meters carry volume too, but HA has no "heat-volume" class, so
      # we deliberately leave device_class empty for them.
      case "${media}" in
        water|warm_water|hot_water|cold_water) echo "water";;
        gas) echo "gas";;
        heat|cooling) echo "";;
        *)
          # Unknown media → fall back to old keyword heuristic.
          if [[ "${key_lc}" == *gas* ]]; then echo "gas"; else echo "water"; fi
          ;;
      esac
      ;;
    *)
      # battery device_class requires 0-100 % in HA.
      # Only apply when unit is empty or % — fields like battery_v (volts)
      # or battery_y (years) must NOT get device_class: battery.
      if [[ "${key_lc}" == *battery* && ( -z "${unit}" || "${unit}" == "%" ) ]]; then
        echo "battery"
      else
        echo ""
      fi
      ;;
  esac
}

guess_state_class() {
  local key_lc="$1"
  local device_class="$2"

  # total_increasing — cumulative counters that only go up
  if [[ "${key_lc}" == total_* || "${key_lc}" == *_total* || "${key_lc}" == *total_* ]]; then
    if [[ "${device_class}" == "energy" || "${device_class}" == "water" || "${device_class}" == "gas" ]]; then
      echo "total_increasing"; return 0
    fi
  fi

  if [[ "${device_class}" == "energy" && ( "${key_lc}" == *consumption* || "${key_lc}" == *production* ) ]]; then
    echo "total_increasing"; return 0
  fi

  if [[ "${key_lc}" == *backflow* ]]; then
    if [[ "${device_class}" == "water" || "${device_class}" == "gas" ]]; then
      echo "total_increasing"; return 0
    fi
  fi

  # measurement — only for fields where a long-term statistic actually
  # makes sense. Unknown numeric fields (error codes, status flags,
  # index numbers, version strings cast to int) get no state_class so
  # HA doesn't graph them as time series.
  case "${device_class}" in
    temperature|humidity|power|voltage|current|frequency|signal_strength|battery|water|gas|energy)
      echo "measurement"; return 0
      ;;
  esac

  echo ""
}


# ------------------------------------------------------------
# Search mode helpers
# ------------------------------------------------------------
float_or_default() {
  local value="$1"
  local def="$2"
  local normalized

  # Accept both decimal separators in add-on UI/options:
  #   22.901 and 22,901 are treated as the same value.
  # Spaces are ignored so pasted values like "22,901 " do not break search mode.
  normalized="$(echo "${value}" | tr -d '[:space:]' | tr ',' '.')"

  if [[ "${normalized}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    echo "${normalized}"
  else
    warn "Invalid numeric value '${value}', using default '${def}'. Use 22.901 or 22,901 format."
    echo "${def}"
  fi
}

SEARCH_EXPECTED_VALUE_M3="$(float_or_default "${SEARCH_EXPECTED_VALUE_M3}" "0")"
SEARCH_TOLERANCE_M3="$(float_or_default "${SEARCH_TOLERANCE_M3}" "0.05")"
SEARCH_MIN_DELTA_M3="$(float_or_default "${SEARCH_MIN_DELTA_M3}" "0.001")"

declare -A SEARCH_FIRST_VALUE

declare -A SEARCH_REPORTED_EXPECTED

declare -A SEARCH_REPORTED_DELTA

SEARCH_CANDIDATES_FILE="${BASE}/search_candidates.tsv"
SEARCH_USING_TEMP_METERS="false"
OFFICIAL_METERS_COUNT=0
SEARCH_IGNORED_COUNT=0
SEARCH_TEMP_METERS_LOADED=0
SEARCH_CHECKED_VALUES=0
SEARCH_DECODED_JSON_COUNT=0
SEARCH_MATCH_COUNT=0
SEARCH_LAST_CACHE_CHANGE=""
SEARCH_LAST_CANDIDATE_ID=""
SEARCH_LAST_CANDIDATE_DRIVER=""
SEARCH_LAST_CANDIDATE_TYPE=""
SEARCH_LAST_CHECKED_ID=""
SEARCH_LAST_CHECKED_DRIVER=""
SEARCH_LAST_CHECKED_FIELD=""
SEARCH_LAST_CHECKED_VALUE=""
SEARCH_LAST_CHECKED_DIFF=""
SEARCH_LAST_REASON="starting"
SEARCH_LAST_IGNORED_REASON=""

search_cached_count() {
  if [[ -f "${SEARCH_CANDIDATES_FILE}" ]]; then
    grep -Ec '^[0-9A-Fa-f]{8}[[:space:]]' "${SEARCH_CANDIDATES_FILE}" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

write_search_status() {
  local phase="${1:-auto}"
  local reason="${2:-}"
  local tmp="${SEARCH_STATUS_FILE}.tmp"
  local cached_count matches_count updated

  cached_count="$(search_cached_count)"
  [[ "${cached_count}" =~ ^[0-9]+$ ]] || cached_count=0
  matches_count="$(wc -l < "${SEARCH_MATCHES_FILE}" 2>/dev/null || echo 0)"
  [[ "${matches_count}" =~ ^[0-9]+$ ]] || matches_count=0

  if [[ "${phase}" == "auto" ]]; then
    if [[ "${SEARCH_MATCH_COUNT}" -gt 0 || "${matches_count}" -gt 0 ]]; then
      phase="matched"
    elif [[ "${SEARCH_USING_TEMP_METERS}" == "true" ]]; then
      phase="search"
    elif [[ "${SEARCH_MODE}" == "true" && "${SEARCH_EXPECTED_VALUE_M3}" != "0" ]]; then
      phase="collecting"
    else
      phase="listen"
    fi
  fi

  [[ -n "${reason}" ]] && SEARCH_LAST_REASON="${reason}"
  updated="$(iso_now)"

  jq -n \
    --arg updated_at "${updated}" \
    --arg phase "${phase}" \
    --arg search_mode "${SEARCH_MODE:-false}" \
    --arg expected "${SEARCH_EXPECTED_VALUE_M3:-0}" \
    --arg tolerance "${SEARCH_TOLERANCE_M3:-0}" \
    --arg cached "${cached_count}" \
    --arg ignored "${SEARCH_IGNORED_COUNT:-0}" \
    --arg loaded "${SEARCH_TEMP_METERS_LOADED:-0}" \
    --arg decoded "${SEARCH_DECODED_JSON_COUNT:-0}" \
    --arg checked "${SEARCH_CHECKED_VALUES:-0}" \
    --arg matches "${matches_count}" \
    --arg cache_changed_at "${SEARCH_LAST_CACHE_CHANGE:-}" \
    --arg last_candidate_id "${SEARCH_LAST_CANDIDATE_ID:-}" \
    --arg last_candidate_driver "${SEARCH_LAST_CANDIDATE_DRIVER:-}" \
    --arg last_candidate_type "${SEARCH_LAST_CANDIDATE_TYPE:-}" \
    --arg last_checked_id "${SEARCH_LAST_CHECKED_ID:-}" \
    --arg last_checked_driver "${SEARCH_LAST_CHECKED_DRIVER:-}" \
    --arg last_checked_field "${SEARCH_LAST_CHECKED_FIELD:-}" \
    --arg last_checked_value "${SEARCH_LAST_CHECKED_VALUE:-}" \
    --arg last_checked_diff "${SEARCH_LAST_CHECKED_DIFF:-}" \
    --arg last_reason "${SEARCH_LAST_REASON:-}" \
    --arg last_ignored_reason "${SEARCH_LAST_IGNORED_REASON:-}" \
    '{updated_at:$updated_at,
      phase:$phase,
      search_mode:($search_mode=="true"),
      expected_m3:($expected|tonumber? // 0),
      tolerance_m3:($tolerance|tonumber? // 0),
      cached_candidates:($cached|tonumber? // 0),
      ignored_candidates:($ignored|tonumber? // 0),
      loaded_temp_meters:($loaded|tonumber? // 0),
      decoded_json:($decoded|tonumber? // 0),
      checked_values:($checked|tonumber? // 0),
      matches:($matches|tonumber? // 0),
      cache_changed_at:$cache_changed_at,
      last_candidate:{id:$last_candidate_id,driver:$last_candidate_driver,type:$last_candidate_type},
      last_checked:{id:$last_checked_id,driver:$last_checked_driver,field:$last_checked_field,value:$last_checked_value,diff_m3:$last_checked_diff},
      last_reason:$last_reason,
      last_ignored_reason:$last_ignored_reason}' \
    > "${tmp}" 2>/dev/null && mv "${tmp}" "${SEARCH_STATUS_FILE}" 2>/dev/null || true
}


write_search_status "auto" "bridge_starting"

search_field_is_candidate() {
  local key_lc="$1"

  case "${key_lc}" in
    *total_volume*|*m3*) return 0 ;;
    *) return 1 ;;
  esac
}

emit_search_payload() {
  local kind="$1"
  local json_line="$2"
  local field="$3"
  local value="$4"
  local diff="$5"
  local delta="$6"

  local id meter media name payload
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
  media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
  name="$(jq -r '.name // empty' <<<"${json_line}" 2>/dev/null || true)"

  payload="$(jq -c -n \
    --arg kind "${kind}" \
    --arg id "${id}" \
    --arg meter "${meter}" \
    --arg media "${media}" \
    --arg name "${name}" \
    --arg field "${field}" \
    --argjson value "${value}" \
    --argjson expected "${SEARCH_EXPECTED_VALUE_M3}" \
    --argjson diff "${diff}" \
    --argjson delta "${delta}" \
    '{event:$kind,id:$id,meter:$meter,media:$media,name:$name,field:$field,value_m3:$value,expected_value_m3:$expected,diff_m3:$diff,delta_m3:$delta}' \
    2>/dev/null || true)"

  [[ -n "${payload}" ]] || return 0
  mqtt_pub "${SEARCH_TOPIC}" "${payload}" "false" || true
}


search_type_is_water_candidate() {
  local type_lc="$1"

  [[ -n "${type_lc}" ]] || return 1
  candidate_type_requires_aes "${type_lc}" && return 1

  case "${type_lc}" in
    *water*) return 0 ;;
    *) return 1 ;;
  esac
}

search_cache_candidate() {
  local id
  local driver="$2"
  local type_line="${3:-}"
  local type_lc

  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${driver}" ]] || driver="auto"

  type_lc="$(echo "${type_line}" | tr '[:upper:]' '[:lower:]')"
  if ! search_type_is_water_candidate "${type_lc}"; then
    SEARCH_IGNORED_COUNT=$((SEARCH_IGNORED_COUNT + 1))
    SEARCH_LAST_CANDIDATE_ID="${id}"
    SEARCH_LAST_CANDIDATE_DRIVER="${driver}"
    SEARCH_LAST_CANDIDATE_TYPE="${type_line:-unknown}"
    SEARCH_LAST_IGNORED_REASON="not_water_m3_candidate_or_encrypted"
    warn "SEARCH ignored: id=${id} driver=${driver} type=${type_line:-unknown} reason=not_water_m3_candidate_or_encrypted (ignored=${SEARCH_IGNORED_COUNT})."
    write_search_status "auto" "candidate_ignored"
    return 0
  fi

  touch "${SEARCH_CANDIDATES_FILE}"
  if grep -q "^${id}	" "${SEARCH_CANDIDATES_FILE}" 2>/dev/null; then
    return 0
  fi

  printf '%s	%s
' "${id}" "${driver}" >> "${SEARCH_CANDIDATES_FILE}"
  SEARCH_LAST_CACHE_CHANGE="$(iso_now)"
  SEARCH_LAST_CANDIDATE_ID="${id}"
  SEARCH_LAST_CANDIDATE_DRIVER="${driver}"
  SEARCH_LAST_CANDIDATE_TYPE="${type_line:-unknown}"

  local cached_count
  cached_count="$(grep -Ec '^[0-9A-Fa-f]{8}[[:space:]]' "${SEARCH_CANDIDATES_FILE}" 2>/dev/null || true)"
  [[ "${cached_count}" =~ ^[0-9]+$ ]] || cached_count=0

  warn "SEARCH discovered: id=${id} driver=${driver} type=${type_line:-unknown} stored as water candidate (cached=${cached_count}, ignored=${SEARCH_IGNORED_COUNT})."
  status_candidate_seen "${id}" "${driver}" "${type_line:-unknown}"
  write_search_status "auto" "candidate_cached"
}

create_search_meter_files_from_cache() {
  [[ -f "${SEARCH_CANDIDATES_FILE}" ]] || return 0

  local i=0
  local id driver file safe_driver
  while IFS=$'\t' read -r id driver; do
    id="$(normalize_meter_id "${id}")"
    [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || continue
    [[ -n "${driver}" ]] || driver="auto"
    [[ "${driver}" =~ ^[A-Za-z0-9_]+$ ]] || driver="auto"

    i=$((i+1))
    file="$(printf '%s/meter-%04d' "${METER_DIR}" "${i}")"
    safe_driver="${driver}"

    {
      echo "name=search_${id}"
      echo "id=${id,,}"
      if [[ "${safe_driver}" != "auto" ]]; then
        echo "driver=${safe_driver}"
      fi
    } > "${file}"

    # Do not spam logs with every temporary search meter. A summary is printed after cache load.
  done < "${SEARCH_CANDIDATES_FILE}"

  echo "${i}"
}

process_search_json() {
  local json_line="$1"
  [[ "${SEARCH_MODE}" == "true" ]] || return 0

  local id
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  if is_search_temp_json "${json_line}"; then
    SEARCH_DECODED_JSON_COUNT=$((SEARCH_DECODED_JSON_COUNT + 1))
  fi

  while IFS=$'\t' read -r field value; do
    [[ -n "${field}" && -n "${value}" ]] || continue

    local field_lc state_key diff absdiff in_tolerance delta
    field_lc="$(echo "${field}" | tr '[:upper:]' '[:lower:]')"
    search_field_is_candidate "${field_lc}" || continue

    local meter_name
    meter_name="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
    SEARCH_CHECKED_VALUES=$((SEARCH_CHECKED_VALUES + 1))
    SEARCH_LAST_CHECKED_ID="${id}"
    SEARCH_LAST_CHECKED_DRIVER="${meter_name:-auto}"
    SEARCH_LAST_CHECKED_FIELD="${field}"
    SEARCH_LAST_CHECKED_VALUE="${value}"

    state_key="${id}|${field}"
    diff="$(awk -v v="${value}" -v e="${SEARCH_EXPECTED_VALUE_M3}" 'BEGIN { printf "%.6f", v - e }')"
    absdiff="$(awk -v d="${diff}" 'BEGIN { if (d < 0) d = -d; printf "%.6f", d }')"
    SEARCH_LAST_CHECKED_DIFF="${absdiff}"
    SEARCH_LAST_REASON="value_out_of_tolerance"

    in_tolerance="$(awk -v d="${absdiff}" -v t="${SEARCH_TOLERANCE_M3}" 'BEGIN { print (d <= t) ? "yes" : "no" }')"
    if [[ "${SEARCH_EXPECTED_VALUE_M3}" != "0" && "${in_tolerance}" == "yes" && -z "${SEARCH_REPORTED_EXPECTED[${state_key}]+x}" ]]; then
      local media meter
      media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
      meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
      warn "SEARCH MATCH: id=${id} driver=${meter:-unknown} media=${media:-unknown} field=${field} value=${value} m3 expected=${SEARCH_EXPECTED_VALUE_M3} diff=${absdiff} m3"
      warn "SEARCH SUGGESTED CONFIG: {\"id\":\"meter_${id}\",\"meter_id\":\"${id}\",\"type\":\"${meter:-auto}\",\"type_other\":\"\",\"key\":\"\"}"
      emit_search_payload "value_match" "${json_line}" "${field}" "${value}" "${absdiff}" "0"
      search_record_match "${json_line}" "${field}" "${value}" "${absdiff}"
      SEARCH_MATCH_COUNT=$((SEARCH_MATCH_COUNT + 1))
      SEARCH_LAST_REASON="value_match"
      write_search_status "matched" "value_match"
      SEARCH_REPORTED_EXPECTED["${state_key}"]=1
    else
      write_search_status "auto" "value_out_of_tolerance"
    fi

    if [[ "${SEARCH_DELTA_MODE}" == "true" ]]; then
      if [[ -z "${SEARCH_FIRST_VALUE[${state_key}]+x}" ]]; then
        SEARCH_FIRST_VALUE["${state_key}"]="${value}"
      else
        delta="$(awk -v v="${value}" -v first="${SEARCH_FIRST_VALUE[${state_key}]}" 'BEGIN { printf "%.6f", v - first }')"
        in_tolerance="$(awk -v d="${delta}" -v min="${SEARCH_MIN_DELTA_M3}" 'BEGIN { print (d >= min) ? "yes" : "no" }')"
        if [[ "${in_tolerance}" == "yes" && -z "${SEARCH_REPORTED_DELTA[${state_key}]+x}" ]]; then
          warn "SEARCH delta: id=${id} field=${field} first=${SEARCH_FIRST_VALUE[${state_key}]} now=${value} delta=${delta} m3"
          emit_search_payload "delta_match" "${json_line}" "${field}" "${value}" "0" "${delta}"
          SEARCH_REPORTED_DELTA["${state_key}"]=1
        fi
      fi
    fi
  done < <(
    jq -r '
      to_entries[]
      | select((.value|type)=="number")
      | [.key, (.value|tostring)]
      | @tsv
    ' <<<"${json_line}" 2>/dev/null || true
  )
}

# ------------------------------------------------------------
# Meter registration — refresh_meter_files()
# Called once at startup AND before every run_once() iteration, so that
# meters added/removed by the user via options.json are picked up by a
# soft pipeline restart (touch ${RELOAD_FLAG}) without needing a full
# container restart. wmbusmeters reads its meter-NNNN files only at
# startup, so the pipeline must be restarted to pick up changes.
# ------------------------------------------------------------
refresh_meter_files() {
  rm -f "${METER_DIR}/meter-"* 2>/dev/null || true

  OFFICIAL_METERS_COUNT=0
  local configured_count=0
  if [[ -f "${OPTIONS_JSON}" ]] && jq -e '.meters and (.meters|length>0)' "${OPTIONS_JSON}" >/dev/null 2>&1; then
    configured_count="$(jq -r '.meters|length' "${OPTIONS_JSON}")"
  fi
  SEARCH_USING_TEMP_METERS="false"

  if [[ "${configured_count}" -eq 0 && "${SEARCH_MODE}" == "true" && "${SEARCH_EXPECTED_VALUE_M3}" != "0" ]]; then
    local cached_count
    cached_count="$(create_search_meter_files_from_cache)"
    if [[ "${cached_count}" =~ ^[0-9]+$ && "${cached_count}" -gt 0 ]]; then
      SEARCH_USING_TEMP_METERS="true"
      SEARCH_TEMP_METERS_LOADED="${cached_count}"
      warn "No user meters configured -> SEARCH MODE (temporary cached candidates=${cached_count}, expected=${SEARCH_EXPECTED_VALUE_M3} m3, tolerance=${SEARCH_TOLERANCE_M3} m3)."
      warn "SEARCH MODE uses cached candidates from ${SEARCH_CANDIDATES_FILE}. Remove that file or disable search_mode to return to pure LISTEN MODE."
      write_search_status "search" "loaded_temp_meters"
    else
      warn "No meters configured -> SEARCH DISCOVERY MODE."
      warn "SEARCH MODE needs decoded JSON values, but there are no cached candidates yet."
      warn "The bridge will collect id+driver candidates first. Let it run long enough to hear meters; restart later to decode cached candidates and compare m3 values."
      write_search_status "collecting" "no_cached_candidates"
    fi
  elif [[ "${configured_count}" -eq 0 ]]; then
    warn "No meters configured -> LISTEN MODE (will log DLL-ID + suggested driver)."
    write_search_status "listen" "listen_mode"
  else
    local loaded_count=0
    local meter_json file friendly_name driver driver_other mid_raw key mid
    while IFS= read -r meter_json; do
      friendly_name="$(echo "${meter_json}" | jq -r '.id // "meter"')"
      driver="$(echo "${meter_json}" | jq -r '.type // "auto"')"
      driver_other="$(echo "${meter_json}" | jq -r '.type_other // empty')"
      mid_raw="$(echo "${meter_json}" | jq -r '.meter_id // empty')"
      key="$(echo "${meter_json}" | jq -r '.key // empty')"

      if [[ -z "${key}" || "${key}" == "null" ]]; then
        key=""
      elif [[ ! "${key}" =~ ^[A-Fa-f0-9]{32}$ ]]; then
        warn "Invalid key for '${friendly_name}' -> skipping (expected empty or 32 hex chars, got: '${key}')"
        continue
      fi

      [[ -z "${driver}" || "${driver}" == "null" ]] && driver="auto"

      if [[ "${driver}" == "other" ]]; then
        if [[ -z "${driver_other}" || "${driver_other}" == "null" ]]; then
          warn "type=other but type_other is empty for '${friendly_name}' -> skipping"
          continue
        fi
        driver="${driver_other}"
      fi

      mid="$(normalize_meter_id "${mid_raw}")"
      if [[ -z "${mid}" ]]; then
        warn "Invalid meter_id for '${friendly_name}' -> skipping (got: '${mid_raw}')"
        continue
      fi

      loaded_count=$((loaded_count + 1))
      file="$(printf '%s/meter-%04d' "${METER_DIR}" "${loaded_count}")"
      {
        echo "name=${friendly_name}"
        # wmbusmeters matches the telegram address case-sensitively in
        # lowercase. meter_id is kept UPPERCASE for display, so lowercase it
        # in the config file — otherwise ids with hex letters (e.g. izar
        # 2156B4C2) never match and the meter silently doesn't decode, even
        # though the file loads. Numeric-only ids were unaffected.
        echo "id=${mid,,}"
        if [[ -n "${key}" ]]; then
          echo "key=${key}"
        fi
        if [[ "${driver}" != "auto" ]]; then
          echo "driver=${driver}"
        fi
      } > "${file}"

      log "meter: ${friendly_name} id=${mid} driver=${driver}"
    done < <(jq -c '.meters[]' "${OPTIONS_JSON}" 2>/dev/null || true)
    OFFICIAL_METERS_COUNT="${loaded_count}"
    if [[ "${loaded_count}" -gt 0 ]]; then
      write_search_status "configured" "official_meters_configured"
    else
      warn "Configured meters exist in options.json, but none produced a valid wmbusmeters meter file -> LISTEN MODE."
      write_search_status "listen" "configured_meters_invalid"
    fi
  fi
}

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
declare -A DISCOVERY_SENT_FIELD
declare -A DISCOVERY_CLEANED_LEGACY
declare -A SEARCH_DISCOVERY_CLEARED_FIELD

clean_legacy_totalm3() {
  local id
  [[ "${DISCOVERY_ENABLED}" == "true" ]] || return 0
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  if [[ -z "${DISCOVERY_CLEANED_LEGACY[${id}]+x}" ]]; then
    if mqtt_pub "${DISCOVERY_PREFIX}/sensor/wmbus_${id}/total_m3/config" "" "true"; then
      DISCOVERY_CLEANED_LEGACY["${id}"]=1
    else
      warn "discovery: failed to clear legacy total_m3 for id=${id} (will retry later)"
    fi
  fi
}

emit_discovery_from_json() {
  local json_line="$1"
  [[ "${DISCOVERY_ENABLED}" == "true" ]] || return 0

  local id name meter media
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  clean_legacy_totalm3 "${id}"

  name="$(jq -r '.name // .id // "wmbus"' <<<"${json_line}" 2>/dev/null || true)"
  meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
  media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"

  local uniq="wmbus_${id}"
  local state_topic="${STATE_PREFIX}/${id}/state"
  local dev_name="${name} (${id})"
  local dev_mdl="${meter:-wmbusmeter}"
  local dev_mfr="wmbusmeters"

  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue

    local obj cache_key key_lc unit device_class state_class cfg_topic unique_id sensor_name payload

    obj="$(sanitize_obj_id "${key}")"
    [[ -n "${obj}" ]] || continue

    key_lc="$(echo "${key}" | tr '[:upper:]' '[:lower:]')"
    unit="$(guess_unit "${key}")"
    device_class="$(guess_device_class "${key_lc}" "${unit}" "${media}")"
    state_class="$(guess_state_class "${key_lc}" "${device_class}")"

    cfg_topic="${DISCOVERY_PREFIX}/sensor/${uniq}/${obj}/config"
    unique_id="${uniq}_${obj}"
    sensor_name="${name} ${key}"

    # expire_after lets HA mark the entity unavailable once the meter
    # stops talking. Base it on the meter's observed average telegram
    # interval, multiplied by 2 for safety. Fall back to 3600s (1h)
    # before we have enough history — most consumer wMBus meters
    # transmit at intervals of 30s..1h, so 1h is a safe floor that
    # won't false-positive on fresh installs.
    local _seen_for_expire _avg_for_expire _s15_for_expire _s60_for_expire
    IFS=$'\t' read -r _seen_for_expire _avg_for_expire _s15_for_expire _s60_for_expire \
      < <(status_seen_stats "${id}" "meter")
    local expire_after=3600
    if [[ "${_avg_for_expire}" =~ ^[0-9]+$ ]]; then
      local _double=$(( _avg_for_expire * 2 ))
      if (( _double > expire_after )); then
        expire_after=${_double}
      fi
    fi
    # Round to nearest minute so small avg fluctuations don't churn
    # the discovery cache. Cache key includes the rounded value so
    # when expire_after changes (e.g. stats stabilize) HA gets an
    # updated config and the offline detection self-tunes.
    expire_after=$(( (expire_after / 60) * 60 ))

    cache_key="${id}|${obj}|${expire_after}"
    [[ -n "${DISCOVERY_SENT_FIELD[${cache_key}]+x}" ]] && continue

    payload="$(jq -c -n \
      --arg name "${sensor_name}" \
      --arg uniq "${unique_id}" \
      --arg st "${state_topic}" \
      --arg key "${key}" \
      --arg did "${uniq}" \
      --arg dname "${dev_name}" \
      --arg dmdl "${dev_mdl}" \
      --arg dmfr "${dev_mfr}" \
      --arg unit "${unit}" \
      --arg dc "${device_class}" \
      --arg sc "${state_class}" \
      --argjson expire "${expire_after}" \
      '(
        {
          name: $name,
          unique_id: $uniq,
          state_topic: $st,
          value_template: "{{ value_json.get('\''\($key)'\'') | default(none) }}",
          json_attributes_topic: $st,
          expire_after: $expire,
          device: {
            identifiers: [$did],
            name: $dname,
            model: $dmdl,
            manufacturer: $dmfr
          }
        }
        + (if ($unit|length)>0 then {unit_of_measurement:$unit} else {} end)
        + (if ($dc|length)>0 then {device_class:$dc} else {} end)
        + (if ($sc|length)>0 then {state_class:$sc} else {} end)
      )'
    )"

    if mqtt_pub "${cfg_topic}" "${payload}" "${DISCOVERY_RETAIN}"; then
      DISCOVERY_SENT_FIELD["${cache_key}"]=1
    else
      warn "discovery: failed to publish config for id=${id} field=${key} (will retry on next telegram)"
    fi
  done < <(
    jq -r '
      to_entries[]
      | select(.key as $k
        | ($k != "_")
        and ($k != "id")
        and ($k != "name")
        and ($k != "meter")
        and ($k != "media")
        and ($k != "timestamp")
        and ($k != "device_date_time")
        and ($k != "rssi")
        and ($k != "lqi")
      )
      | select((.value|type)=="number")
      | .key
    ' <<<"${json_line}" 2>/dev/null || true
  )
}


# ------------------------------------------------------------
# Search temporary meters must never create HA devices/entities.
# SEARCH uses temporary names search_<id> only to let wmbusmeters decode
# JSON values for matching. These decoded telegrams are internal search data,
# not real configured meters.
# ------------------------------------------------------------
is_search_temp_json() {
  local json_line="$1"
  [[ "${SEARCH_MODE}" == "true" ]] || return 1

  local name
  name="$(jq -r '.name // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ "${name}" == search_* ]]
}

clear_search_discovery_from_json() {
  local json_line="$1"

  is_search_temp_json "${json_line}" || return 0

  local id
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  # Clear older retained discovery configs if a previous buggy search run
  # already created HA entities. Use retain=true because MQTT Discovery
  # removal requires an empty retained config payload.
  clean_legacy_totalm3 "${id}"

  local uniq="wmbus_${id}"
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue

    local obj cache_key cfg_topic
    obj="$(sanitize_obj_id "${key}")"
    [[ -n "${obj}" ]] || continue

    cache_key="${id}|${obj}"
    [[ -n "${SEARCH_DISCOVERY_CLEARED_FIELD[${cache_key}]+x}" ]] && continue

    cfg_topic="${DISCOVERY_PREFIX}/sensor/${uniq}/${obj}/config"
    mqtt_pub "${cfg_topic}" "" "true" || true
    SEARCH_DISCOVERY_CLEARED_FIELD["${cache_key}"]=1
  done < <(
    jq -r '
      to_entries[]
      | select(.key as $k
        | ($k != "_")
        and ($k != "id")
        and ($k != "name")
        and ($k != "meter")
        and ($k != "media")
        and ($k != "timestamp")
        and ($k != "device_date_time")
        and ($k != "rssi")
        and ($k != "lqi")
      )
      | select((.value|type)=="number")
      | .key
    ' <<<"${json_line}" 2>/dev/null || true
  )
}

# ------------------------------------------------------------
# Listen-mode snippet (best-effort)
# ------------------------------------------------------------
SNIPPET_STATE="${BASE}/seen_ids.txt"
touch "${SNIPPET_STATE}"

emit_snippet_if_new() {
  local id
  local driver="$2"
  local type_line="${3:-}"
  local manufacturer="${4:-}"
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  # Update dashboard stats every time this candidate is heard.
  # Pass the real type_line from wmbusmeters output so the webui can
  # show encryption status (e.g. "Electricity meter (0x02) encrypted").
  status_candidate_seen "${id}" "${driver:-auto}" "${type_line:-listen}" "true" "${manufacturer}"

  if ! grep -qx "${id}" "${SNIPPET_STATE}" 2>/dev/null; then
    echo "${id}" >> "${SNIPPET_STATE}"
    warn "=== NEW METER CANDIDATE DETECTED ==="
    warn "Received telegram from: ${id}"
    [[ -n "${driver}" ]] && warn "Suggested driver: ${driver}"
    warn "Add to options.json meters[] (example):"
    warn "  no key:   {\"id\":\"meter_${id}\",\"meter_id\":\"${id}\",\"type\":\"auto\",\"type_other\":\"\",\"key\":\"\"}"
    warn "  zero key: {\"id\":\"meter_${id}\",\"meter_id\":\"${id}\",\"type\":\"auto\",\"type_other\":\"\",\"key\":\"00000000000000000000000000000000\"}"
    warn "=================================="
  fi
}

# ------------------------------------------------------------
# parse_listen_candidates
# Reads wmbusmeters listen-mode stdout from stdin and emits candidate
# updates (status_candidates.tsv, status_candidate_analysis.tsv, events).
# Mirrors the inline listen logic from run_once() (lines that match
# "Received telegram from:" / type: / driver:), but lives in a parallel
# subshell so it can run alongside the main DECODE pipeline.
#
# write_status_json is overridden to a no-op here — the candidate
# subshell holds a stale snapshot of the parent's STATUS_* vars at fork
# time, so letting it write status.json would clobber the parent's
# decoded-counter / last-seen state. The TSV files are still updated
# directly (status_candidate_seen writes them via awk+mv), which is
# what the WebGUI actually reads for the candidate panel.
# ------------------------------------------------------------
# _store_candidate_value: extracts (id, primary_numeric_value, value_key) from a
# decoded wmbusmeters JSON telegram and writes/updates a single row in
# status_candidate_values.tsv. Called only for telegrams from candidates that
# have a meter-preview-<id> file in /data/listen/etc/wmbusmeters.d/ (webui.py
# writes those when the user clicks "Preview value" on the Discover page).
#
# Picks the SAME primary field as status_meter_seen() — keeps preview values
# consistent with what the user sees on the Meters page after permanently adding
# the meter. Heuristic (cumulative meter reading first):
#   1. canonical current totals (total_m3, total_energy_consumption_kwh, etc.),
#      then other cumulative readings. Skips production/tariff registers and
#      fault/diagnostic counters (backflow_m3, fraud_*, leak_*, tamper_*, alarm_*).
#   2. instantaneous reading (_kw, _w, _m3h, _l_h) — only when no total exists.
#   3. last resort: first numeric field
_store_candidate_value() {
  local json_line="$1"
  local id value_key value now
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  # Step 1 — cumulative meter reading. Excludes historical/helper fields,
  # production/tariff registers and
  # fault counters that wmbusmeters sometimes emits with bogusly large values
  # (the bug that put 1291845 m³ of "backflow" in the WebGUI before).
  IFS=$'\t' read -r value_key value < <(_select_primary_meter_value "${json_line}") || true
  if [[ -z "${value_key}" ]]; then
    IFS=$'\t' read -r value_key value < <(
      jq -r '
        [to_entries[]
          | select((.value|type)=="number")
          | select(.key|test("^total_energy_consumption_tariff_[0-9]+_kwh$";"i"))
          | .value] as $vals
        | if ($vals|length) > 0 then "total_energy_consumption_kwh\t\($vals|add)" else empty end
      ' <<<"${json_line}" 2>/dev/null | head -n 1
    ) || true
  fi
  # Step 2 — instantaneous fields, only when no cumulative total was found.
  if [[ -z "${value_key}" ]]; then
    value_key="$(jq -r 'to_entries[] | select((.value|type)=="number") | select(.key|test("(_kw$|_w$|_m3h$|_l_h$)";"i")) | .key' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -n "${value_key}" ]]; then
    [[ -n "${value:-}" ]] || value="$(jq -r --arg k "${value_key}" '.[$k] // empty' <<<"${json_line}" 2>/dev/null || true)"
  else
    # Step 3 — any numeric (skip wmbusmeters metadata keys though).
    IFS=$'\t' read -r value_key value < <(
      jq -r '
        to_entries[]
        | select(.key as $k
            | (["_","id","name","meter","media","timestamp","device_date_time","rssi","lqi","status","driver","type"]
                | index($k)) | not)
        | select((.value|type)=="number")
        | "\(.key)\t\(.value)"
      ' <<<"${json_line}" 2>/dev/null | head -n 1
    )
  fi
  if [[ -z "${value}" ]]; then
    log_verbose "[DIAG] _store_candidate_value ${id}: no numeric value found, skipping"
    _set_preview_state "${id}" "decoded_without_numeric_value"
    return 0
  fi
  log_debug "[DIAG] _store_candidate_value ${id}: value_key=${value_key} value=${value}"
  now="$(iso_now)"
  _tsv_upsert "${STATUS_CANDIDATE_VALUES_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s' "${id}" "${value}" "${value_key}" "${now}")"
  _set_preview_state "${id}" "decoded_value"
  log_debug "[DIAG] _store_candidate_value ${id}: wrote to status_candidate_values.tsv"
}

status_candidate_seen_from_json() {
  local json_line="$1"
  local id driver type_line existing_driver existing_type
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  driver="$(jq -r '.meter // .driver // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ -n "${driver}" && "${driver}" != "null" ]] || driver="auto"
  type_line="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ "${type_line}" != "null" ]] || type_line=""

  IFS=$'\t' read -r existing_driver existing_type < <(
    awk -F '\t' -v id="${id}" '$1==id {print $2 "\t" $3; exit}' "${STATUS_CANDIDATES_FILE}" 2>/dev/null || true
  )
  # Decoded JSON wins: .meter is the real driver, .media the medium. Fall back
  # to a stored value only when the JSON gave none, and ignore the generic
  # placeholders ("auto" / "wMBus telegram") so a real decode heals a candidate
  # first registered from the raw A-field.
  if [[ "${driver}" == "auto" && -n "${existing_driver}" && "${existing_driver}" != "auto" ]]; then
    driver="${existing_driver}"
  fi
  if [[ -z "${type_line}" && -n "${existing_type}" && "${existing_type}" != "wMBus telegram" ]]; then
    type_line="${existing_type}"
  fi
  [[ -n "${type_line}" ]] || type_line="decoded"

  status_candidate_seen "${id}" "${driver}" "${type_line}"
}

# Process one completed text-output block from the parallel LISTEN instance.
# Called with a delayed flush — when the next "Received telegram from:" line
# arrives — so manufacturer: (which follows driver: in wmbusmeters output)
# is always captured before the block is dispatched.
# Arguments: id  driver  type  manufacturer
_process_listen_text_block() {
  local _id="$1" _drv="$2" _type="$3" _mfr="$4"
  [[ -n "${_id}" && -n "${_drv}" ]] || return 0
  # When there are no official meters, the primary pipeline already runs in
  # LISTEN mode and updates candidate stats. A secondary LISTEN may still be
  # running for preview decoding; do not double-count candidate receptions.
  if [[ "${OFFICIAL_METERS_COUNT:-0}" -gt 0 ]]; then
    if [[ "${SEARCH_MODE}" == "true" && "${SEARCH_EXPECTED_VALUE_M3}" != "0" ]]; then
      search_cache_candidate "${_id}" "${_drv}" "${_type}"
    else
      emit_snippet_if_new "${_id}" "${_drv}" "${_type}" "${_mfr}"
    fi
  fi
  # Track text-only telegrams (no JSON) for preview candidates.
  # When a preview file exists but wmbusmeters never emits JSON (driver not
  # recognised or unsupported telegram variant), the state stays "pending"
  # forever. After count >= 3 AND elapsed >= 60 s, set no_decode_result so
  # the UI shows "brak wyniku dekodowania" instead of "dekoduję..." forever.
  # JSON arriving later still overrides via _store_candidate_value → decoded_value
  # or decoded_without_numeric_value (both use _tsv_upsert which replaces the row).
  if ! candidate_type_requires_aes "${_type}"; then
    local _pf _cur_state _cnt_file _cnt _start _now _elapsed _cnt_tmp
    _pf="${LISTEN_METER_DIR}/meter-preview-${_id}"
    if [[ -f "${_pf}" ]]; then
      _cur_state="$(awk -F '\t' -v id="${_id}" '$1==id {print $2; exit}' \
        "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}" 2>/dev/null || true)"
      if [[ "${_cur_state}" == "pending" ]]; then
        _cnt_file="${BASE}/.preview_attempts/${_id}"
        _cnt=0
        _start=0
        if [[ -f "${_cnt_file}" ]]; then
          IFS=$'\t' read -r _cnt _start < "${_cnt_file}" 2>/dev/null || true
          [[ "${_cnt}" =~ ^[0-9]+$ ]] || _cnt=0
          [[ "${_start}" =~ ^[0-9]+$ ]] || _start=0
        fi
        _now="$(date +%s 2>/dev/null || echo 0)"
        (( _start > 0 )) || _start="${_now}"
        _cnt=$(( _cnt + 1 ))
        _elapsed=$(( _now - _start ))
        _cnt_tmp="$(mktemp "${_cnt_file}.tmp.XXXXXX" 2>/dev/null)" || true
        if [[ -n "${_cnt_tmp}" ]]; then
          printf '%d\t%d\n' "${_cnt}" "${_start}" > "${_cnt_tmp}"
          mv "${_cnt_tmp}" "${_cnt_file}" 2>/dev/null \
            || { rm -f "${_cnt_tmp}" 2>/dev/null || true; }
        fi
        if (( _cnt >= 3 && _elapsed >= 60 )); then
          log_verbose "[DIAG] LISTEN-parse: no JSON after ${_cnt} text-only telegrams (${_elapsed}s) for ${_id} → no_decode_result"
          _set_preview_state "${_id}" "no_decode_result"
        else
          log_debug "[DIAG] LISTEN-parse: text-only telegram #${_cnt} for preview ${_id} (elapsed=${_elapsed}s, need count>=3 AND elapsed>=60)"
        fi
      fi
    fi
  fi
}

parse_listen_candidates() {
  # Suppress status.json writes from this subshell to prevent races
  # with the parent shell's pipeline writes.
  write_status_json() { :; }

  local last_id="" last_driver="" last_type="" last_manufacturer=""
  while IFS= read -r line; do
    # Decoded JSON output — present only when LISTEN has a meter-preview-<id>
    # config matching this telegram's ID. Capture the primary numeric value
    # for the WebGUI "Preview value" feature.
    if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
      log_debug "[DIAG] LISTEN-parse: JSON telegram received: ${line:0:160}"
      if [[ "${OFFICIAL_METERS_COUNT:-0}" -gt 0 ]]; then
        status_candidate_seen_from_json "${line}"
      fi
      log_debug "[DIAG] LISTEN-parse: calling _store_candidate_value"
      _store_candidate_value "${line}"
      continue
    fi
    # Plain listen-mode text output — extract candidate metadata.
    # Flush the previous block when a new telegram starts so manufacturer:
    # (which follows driver: in wmbusmeters output) is captured before dispatch.
    if [[ "${line}" =~ ^Received\ telegram\ from:\ ([0-9A-Fa-f]{8}) ]]; then
      _process_listen_text_block "${last_id}" "${last_driver}" "${last_type}" "${last_manufacturer}"
      last_id="$(normalize_meter_id "${BASH_REMATCH[1]}")"
      last_type=""
      last_driver=""
      last_manufacturer=""
    elif [[ "${line}" =~ ^[[:space:]]*type:[[:space:]]*(.*)$ ]]; then
      last_type="${BASH_REMATCH[1]}"
    elif [[ "${line}" =~ ^[[:space:]]*driver:\ ([a-zA-Z0-9_]+) ]]; then
      last_driver="${BASH_REMATCH[1]}"
    elif [[ "${line}" =~ ^[[:space:]]*manufacturer:[[:space:]]*(.*)$ ]]; then
      last_manufacturer="${BASH_REMATCH[1]}"
    fi
  done
  # Flush the last block after the stream ends.
  _process_listen_text_block "${last_id}" "${last_driver}" "${last_type}" "${last_manufacturer}"
}

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
  # Watcher excludes itself (BASHPID) and LISTEN_PID from the kill list so
  # the parallel listen instance keeps running across pipeline restarts.
  (
    watcher_self="${BASHPID}"
    while sleep 2; do
      if [[ -f "${RELOAD_FLAG}" ]]; then
        rm -f "${RELOAD_FLAG}" 2>/dev/null || true
        log "Soft reload: ${RELOAD_FLAG} detected, restarting decode pipeline..."
        for child in $(pgrep -P "$$" 2>/dev/null); do
          [[ "${child}" == "${watcher_self}" ]] && continue
          [[ -n "${LISTEN_PID}" && "${child}" == "${LISTEN_PID}" ]] && continue
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
              mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
              emit_discovery_from_json "${line}"
              status_mark_discovery_published
              write_status_json
            fi
          fi
          continue
        fi

        echo "${line}"

        if [[ "${OFFICIAL_METERS_COUNT}" -eq 0 && "${SEARCH_USING_TEMP_METERS}" != "true" ]]; then
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
              mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
              emit_discovery_from_json "${line}"
              status_mark_discovery_published
              write_status_json
            fi
          fi
        else
          echo "${line}"
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

# ────────────────────────────────────────────────────────────────────────
# Parallel LISTEN instance lifecycle — managed at the script level so it
# persists across run_once() restarts (soft reload picks up new meters
# without disturbing the always-on candidate stream).
# ────────────────────────────────────────────────────────────────────────
LISTEN_PID=""

listen_preview_count() {
  local count=0 f
  for f in "${LISTEN_METER_DIR}"/meter-preview-*; do
    [[ -e "${f}" ]] || continue
    count=$((count + 1))
  done
  echo "${count}"
}

start_listen_instance() {
  # Already running? Done.
  if [[ -n "${LISTEN_PID}" ]] && kill -0 "${LISTEN_PID}" 2>/dev/null; then
    return 0
  fi
  (
    # ── LISTEN supervisor loop ──
    # Runs the listen pipeline (mosquitto_sub | awk | wmbusmeters | parse).
    # When /data/.reload_listen flag appears (touched by webui.py /api/preview-
    # candidate or /api/cancel-preview), kills the current pipeline and
    # restarts it. This lets wmbusmeters pick up newly added meter-preview-<id>
    # files in /data/listen/etc/wmbusmeters.d/ without touching the DECODE
    # pipeline. Reload cycle ~2-3 s.
    while true; do
      _diag_preview_count="$(find "${LISTEN_METER_DIR}" -maxdepth 1 -name 'meter-preview-*' 2>/dev/null | wc -l | tr -d ' ')"
      log_verbose "[DIAG] LISTEN supervisor: starting pipeline (meter-preview-* count=${_diag_preview_count} in ${LISTEN_METER_DIR})"
      ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" "${SUB_EXTRA[@]}" -t "${RAW_TOPIC}" -F '%p' \
        | awk '
            function ishex(s) { return (s ~ /^[0-9A-Fa-f]+$/) }
            {
              gsub(/[[:space:]]/, "", $0);
              sub(/^0x/i, "", $0);
              if (!ishex($0)) next;
              if ((length($0) % 2) != 0) next;
              print $0;
              fflush();
            }
          ' \
        | ${STDBUF_BIN} /usr/bin/wmbusmeters --useconfig="${LISTEN_BASE}" 2>&1 \
        | parse_listen_candidates &
      pipeline_pid=$!
      log_debug "[DIAG] LISTEN supervisor: pipeline started (pid=${pipeline_pid})"
      # Poll for reload flag or natural exit.
      while kill -0 "${pipeline_pid}" 2>/dev/null; do
        if [[ -f "${BASE}/.reload_listen" ]]; then
          log_verbose "[DIAG] LISTEN supervisor: .reload_listen detected, killing pid=${pipeline_pid}"
          rm -f "${BASE}/.reload_listen" 2>/dev/null || true
          pkill -TERM -P "${pipeline_pid}" 2>/dev/null || true
          kill -TERM "${pipeline_pid}" 2>/dev/null || true
          wait "${pipeline_pid}" 2>/dev/null || true
          log_verbose "[DIAG] LISTEN supervisor: pipeline stopped, restarting"
          break
        fi
        sleep 2
      done
      wait "${pipeline_pid}" 2>/dev/null || true
      # Brief pause before restart to avoid tight-looping on persistent failures.
      sleep 1
    done
  ) &
  LISTEN_PID=$!
  log "Parallel LISTEN instance started (pid=${LISTEN_PID}) — supervisor loop with .reload_listen support."
}

stop_listen_instance() {
  [[ -z "${LISTEN_PID}" ]] && return 0
  log "Stopping parallel LISTEN instance (pid=${LISTEN_PID})..."
  pkill -TERM -P "${LISTEN_PID}" 2>/dev/null || true
  kill -TERM "${LISTEN_PID}" 2>/dev/null || true
  wait "${LISTEN_PID}" 2>/dev/null || true
  pkill -KILL -P "${LISTEN_PID}" 2>/dev/null || true
  LISTEN_PID=""
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

wait_for_mqtt() {
  log "Waiting for MQTT broker ${MQTT_HOST}:${MQTT_PORT}..."
  for ((i=1; i<=MQTT_WAIT_RETRIES; i++)); do
    if /usr/bin/mosquitto_pub "${PUB_ARGS[@]}" -t "wmbus_bridge/status" -m "starting" --quiet 2>/dev/null; then
      log "MQTT broker ready (attempt ${i}/${MQTT_WAIT_RETRIES})"
      STATUS_MQTT_CONNECTED="true"
      STATUS_LAST_ERROR=""
      status_add_event "ok" "MQTT broker ready"
      write_status_json
      return 0
    fi
    warn "MQTT not ready (attempt ${i}/${MQTT_WAIT_RETRIES}), retrying in ${MQTT_WAIT_DELAY}s..."
    sleep "${MQTT_WAIT_DELAY}"
  done
  # Broker niedostępny po wszystkich próbach - ostrzegamy ale nie przerywamy,
  # pętla restart_on_exit zajmie się ponownym uruchomieniem pipeline.
  warn "MQTT broker not available after ${MQTT_WAIT_RETRIES} attempts, continuing anyway..."
  STATUS_MQTT_CONNECTED="false"
  STATUS_LAST_ERROR="MQTT broker not available"
  status_add_event "error" "MQTT broker not available"
  write_status_json
  return 1
}

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

  # Existing candidates from previous LISTEN ticks should be decodable by the
  # secondary LISTEN immediately after restart, not only after each one sends
  # one more telegram to create its meter-preview file.
  sync_candidate_autodecode_files

  # Remove any meter-preview-<id> that sync_candidate_autodecode_files just wrote
  # for an ID that is already an official configured meter. Keeps the LISTEN
  # instance free of redundant preview configs for meters the primary pipeline
  # already decodes.
  prune_official_meter_previews

  # Parallel LISTEN always starts unconditionally, including pure LISTEN /
  # Discover mode with no configured meters and no preview files yet.
  # Without this, no supervisor is alive when the first candidate triggers
  # ensure_candidate_autodecode() + _request_listen_reload(), so .reload_listen
  # is never handled and preview decoding never begins.
  # Double-counting in pure LISTEN mode is prevented inside parse_listen_candidates()
  # by the OFFICIAL_METERS_COUNT guard — not at the instance-start level.
  start_listen_instance

  run_once
  rc=$?
  set -e
  if [[ "${RESTART_ON_EXIT}" != "true" ]]; then
    exit ${rc}
  fi
  STATUS_WMBUSMETERS_RUNNING="false"
  if [[ "${rc}" -eq 0 ]]; then
    # rc=0 is a clean, intentional exit — typically a soft pipeline reload
    # requested via the WebUI (.reload_pipeline) to pick up added/removed
    # meters. Not an error: the loop just respawns the pipeline.
    log "Pipeline exited cleanly (rc=0), reloading in 2s..."
    status_add_event "ok" "Pipeline reloaded"
  else
    warn "Pipeline exited (rc=${rc}), restarting in 2s..."
    STATUS_LAST_ERROR="pipeline exited rc=${rc}"
    status_add_event "error" "Pipeline exited rc=${rc}"
  fi
  write_status_json
  sleep 2
  # continue
done

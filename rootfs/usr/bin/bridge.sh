#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# wMBus MQTT Bridge (core)
# - MQTT RAW HEX (payload-only) -> wmbusmeters stdin:hex
# - wmbusmeters JSON telegram -> MQTT state: <state_prefix>/<id>/state
# - Home Assistant MQTT Discovery (generic): sensor per numeric JSON field
# ============================================================

log()  { echo "[wmbus-bridge] $*"; }
warn() { echo "[wmbus-bridge][WARN] $*" >&2; }
err()  { echo "[wmbus-bridge][ERR] $*" >&2; }

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
SEARCH_MATCHES_FILE="${BASE}/search_matches.tsv"
SEARCH_STATUS_FILE="${BASE}/search_status.json"

STATUS_MQTT_CONNECTED="false"
STATUS_WMBUSMETERS_RUNNING="false"
STATUS_RAW_COUNT=0
STATUS_DECODED_COUNT=0
STATUS_DISCOVERY_PUBLISHED="false"
STATUS_LAST_RAW_SEEN=""
STATUS_LAST_DECODED_SEEN=""
STATUS_LAST_ERROR=""
STATUS_LAST_EVENT="starting"

touch "${STATUS_METERS_FILE}" "${STATUS_CANDIDATES_FILE}" "${STATUS_EVENTS_FILE}" "${STATUS_SEEN_FILE}" "${STATUS_LAST_RAW_FILE}" "${STATUS_RECENT_RAW_FILE}" "${STATUS_CANDIDATE_ANALYSIS_FILE}" "${STATUS_CANDIDATE_RAW_FILE}" "${SEARCH_MATCHES_FILE}" "${SEARCH_STATUS_FILE}"
[[ -f "${STATUS_RAW_COUNT_FILE}" ]] || echo "0" > "${STATUS_RAW_COUNT_FILE}"

iso_now() {
  date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

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

epoch_now() {
  date +%s 2>/dev/null || echo 0
}

status_record_seen() {
  local id="$1"
  local kind="${2:-meter}"
  local ts
  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0
  ts="$(epoch_now)"
  printf '%s\t%s\t%s\n' "${id}" "${kind}" "${ts}" >> "${STATUS_SEEN_FILE}" 2>/dev/null || true
  tail -n 5000 "${STATUS_SEEN_FILE}" > "${STATUS_SEEN_FILE}.tmp" 2>/dev/null && mv "${STATUS_SEEN_FILE}.tmp" "${STATUS_SEEN_FILE}" 2>/dev/null || true
}

status_seen_stats() {
  local id="$1"
  local kind="${2:-meter}"
  local now
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
  local id="$1"
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

status_upsert_candidate_analysis() {
  local id="$1"
  local encryption="$2"
  local note="$3"
  local ci="${4:-}"
  local security="${5:-}"
  local raw_len="${6:-0}"
  local last_seen="${7:-}"
  local tmp

  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0
  [[ -n "${last_seen}" ]] || last_seen="$(iso_now)"

  tmp="${STATUS_CANDIDATE_ANALYSIS_FILE}.tmp"
  awk -F '\t' -v id="${id}" '$1 != id {print}' "${STATUS_CANDIDATE_ANALYSIS_FILE}" 2>/dev/null > "${tmp}" || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${encryption:-unknown}" "${note:-}" "${ci:-}" "${security:-}" "${raw_len:-0}" "${last_seen}" >> "${tmp}"
  mv "${tmp}" "${STATUS_CANDIDATE_ANALYSIS_FILE}" 2>/dev/null || true
}

status_record_candidate_raw() {
  local id="$1"
  local raw="$2"
  local ts="${3:-}"
  local tmp
  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0
  [[ -n "${raw}" ]] || return 0
  [[ -n "${ts}" ]] || ts="$(iso_now)"

  tmp="${STATUS_CANDIDATE_RAW_FILE}.tmp"
  awk -F '\t' -v id="${id}" '$1 != id {print}' "${STATUS_CANDIDATE_RAW_FILE}" 2>/dev/null > "${tmp}" || true
  printf '%s\t%s\t%s\t%s\n' "${id}" "${ts}" "${#raw}" "${raw}" >> "${tmp}"
  mv "${tmp}" "${STATUS_CANDIDATE_RAW_FILE}" 2>/dev/null || true
}

status_analyze_candidate_from_text() {
  local id="$1"
  local driver="${2:-auto}"
  local type_line="${3:-}"
  local type_lc raw_row raw_ts raw_len raw ci encryption note security

  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0
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
  if [[ "${type_lc}" == *encrypted* || "${type_lc}" == *aes* ]]; then
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
  id="$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0

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

  id="$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0
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
  jq -n     --arg updated_at "$(iso_now)"     --arg raw_topic "${RAW_TOPIC:-}"     --arg state_prefix "${STATE_PREFIX:-}"     --arg discovery_prefix "${DISCOVERY_PREFIX:-}"     --arg search_mode "${SEARCH_MODE:-false}"     --arg loglevel "${LOGLEVEL:-}"     --arg mqtt_host "${MQTT_HOST:-}"     --arg mqtt_port "${MQTT_PORT:-}"     --arg mqtt_connected "${STATUS_MQTT_CONNECTED}"     --arg wmbusmeters_running "${STATUS_WMBUSMETERS_RUNNING}"     --arg raw_count "${STATUS_RAW_COUNT}"     --arg decoded_count "${STATUS_DECODED_COUNT}"     --arg discovery_published "${STATUS_DISCOVERY_PUBLISHED}"     --arg last_raw_seen "${STATUS_LAST_RAW_SEEN}"     --arg last_decoded_seen "${STATUS_LAST_DECODED_SEEN}"     --arg last_error "${STATUS_LAST_ERROR}"     --arg last_event "${STATUS_LAST_EVENT}"     '{updated_at:$updated_at,
      config:{raw_topic:$raw_topic,state_prefix:$state_prefix,discovery_prefix:$discovery_prefix,search_mode:($search_mode=="true"),loglevel:$loglevel},
      mqtt:{host:$mqtt_host,port:$mqtt_port,connected:($mqtt_connected=="true")},
      pipeline:{raw_count:($raw_count|tonumber? // 0),decoded_count:($decoded_count|tonumber? // 0),wmbusmeters_running:($wmbusmeters_running=="true"),discovery_published:($discovery_published=="true"),last_raw_seen:$last_raw_seen,last_decoded_seen:$last_decoded_seen,last_error:$last_error,last_event:$last_event}}'     > "${tmp}" 2>/dev/null && mv "${tmp}" "${STATUS_JSON}" 2>/dev/null || true
}

status_raw_seen() {
  local raw="${1:-}"
  # If a RAW telegram arrived from mosquitto_sub, MQTT and the input pipeline
  # are alive even if no configured meter JSON has been decoded yet.
  STATUS_MQTT_CONNECTED="true"
  STATUS_WMBUSMETERS_RUNNING="true"
  status_store_raw_seen "$(iso_now)"
  status_store_recent_raw "${raw}"
  if (( STATUS_RAW_COUNT == 1 || STATUS_RAW_COUNT % 25 == 0 )); then
    status_add_event "ok" "RAW telegram received (${#raw} hex chars)"
  fi
  write_status_json
}

status_meter_seen() {
  local json_line="$1"
  local id name meter media value_key value last_seen tmp
  id="$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ -n "${id}" ]] || return 0
  name="$(jq -r '.name // empty' <<<"${json_line}" 2>/dev/null || true)"
  meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
  media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
  # Prefer instantaneous fields (current power, flow rate) — they're what
  # users see as "live consumption" in HA. Anchor on power/flow-rate units
  # (_kw, _w, _m3h, _l_h) so temperatures (_c) don't qualify. Fall back to
  # cumulative totals/meter readings when no live field is published.
  # Examples: amiplus → current_power_consumption_kw (live);
  # water meters → total_m3 (no live field exists, cumulative is the reading).
  value_key="$(jq -r 'to_entries[] | select((.value|type)=="number") | select(.key|test("(_kw$|_w$|_m3h$|_l_h$)";"i")) | .key' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
  if [[ -z "${value_key}" ]]; then
    value_key="$(jq -r 'to_entries[] | select((.value|type)=="number") | select(.key|test("(^total|_m3$|kwh|wh$|energy|volume)";"i")) | select(.key|test("(backflow|fraud|leak|tamper|alarm)";"i")|not) | .key' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -n "${value_key}" ]]; then
    value="$(jq -r --arg k "${value_key}" '.[$k] // empty' <<<"${json_line}" 2>/dev/null || true)"
  else
    value_key="value"
    value="$(jq -r 'to_entries[] | select((.value|type)=="number") | .value' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
  fi
  status_record_seen "${id}" "meter"
  last_seen="$(iso_now)"
  IFS=$'\t' read -r seen_count avg_interval_s seen_15m seen_60m < <(status_seen_stats "${id}" "meter")
  tmp="${STATUS_METERS_FILE}.tmp"
  awk -F '	' -v id="${id}" '$1 != id {print}' "${STATUS_METERS_FILE}" 2>/dev/null > "${tmp}" || true
  printf '%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s	%s
' "${id}" "${name}" "${meter}" "${media}" "${value_key}" "${value}" "${last_seen}" "published" "${seen_count}" "${avg_interval_s}" "${seen_15m}" "${seen_60m}" >> "${tmp}"
  mv "${tmp}" "${STATUS_METERS_FILE}" 2>/dev/null || true
}

status_candidate_seen() {
  local id="$1"
  local driver="${2:-auto}"
  local type_line="${3:-}"
  local now tmp
  STATUS_WMBUSMETERS_RUNNING="true"
  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0
  local existed="false"
  if grep -q "^${id}	" "${STATUS_CANDIDATES_FILE}" 2>/dev/null; then
    existed="true"
  fi
  status_record_seen "${id}" "candidate"
  now="$(iso_now)"
  IFS=$'\t' read -r seen_count avg_interval_s seen_15m seen_60m < <(status_seen_stats "${id}" "candidate")
  tmp="${STATUS_CANDIDATES_FILE}.tmp"
  awk -F '	' -v id="${id}" '$1 != id {print}' "${STATUS_CANDIDATES_FILE}" 2>/dev/null > "${tmp}" || true
  printf '%s	%s	%s	%s	%s	%s	%s	%s
' "${id}" "${driver}" "${type_line}" "${now}" "${seen_count}" "${avg_interval_s}" "${seen_15m}" "${seen_60m}" >> "${tmp}"
  mv "${tmp}" "${STATUS_CANDIDATES_FILE}" 2>/dev/null || true
  status_analyze_candidate_from_text "${id}" "${driver}" "${type_line}"
  if [[ "${existed}" != "true" ]]; then
    status_add_event "candidate" "Candidate detected ${id} (${driver})"
  fi
  write_status_json
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
SEARCH_TOLERANCE_M3="${SEARCH_TOLERANCE_M3:-$(json_get '.search_tolerance_m3' '1')}"
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
# Helpers
# ------------------------------------------------------------
normalize_meter_id() {
  local mid_raw="$1"
  mid_raw="$(echo "${mid_raw}" | tr -d '[:space:]')"
  [[ -z "${mid_raw}" || "${mid_raw}" == "null" ]] && { echo ""; return 0; }

  mid_raw="${mid_raw#0x}"
  mid_raw="${mid_raw#0X}"
  mid_raw="$(echo "${mid_raw}" | tr '[:upper:]' '[:lower:]')"

  [[ "${mid_raw}" =~ ^[0-9a-f]+$ ]] || { echo ""; return 0; }

  if [[ "${#mid_raw}" -lt 8 ]]; then
    printf "%8s" "${mid_raw}" | tr ' ' '0'
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
SEARCH_TOLERANCE_M3="$(float_or_default "${SEARCH_TOLERANCE_M3}" "1")"
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
    grep -Ec '^[0-9]{8}[[:space:]]' "${SEARCH_CANDIDATES_FILE}" 2>/dev/null || echo 0
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
  id="$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ -n "${id}" ]] || return 0

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
  [[ "${type_lc}" == *encrypted* ]] && return 1

  case "${type_lc}" in
    *water*) return 0 ;;
    *) return 1 ;;
  esac
}

search_cache_candidate() {
  local id="$1"
  local driver="$2"
  local type_line="${3:-}"
  local type_lc

  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0
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
  cached_count="$(grep -Ec '^[0-9]{8}[[:space:]]' "${SEARCH_CANDIDATES_FILE}" 2>/dev/null || true)"
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
    [[ "${id}" =~ ^[0-9]{8}$ ]] || continue
    [[ -n "${driver}" ]] || driver="auto"
    [[ "${driver}" =~ ^[A-Za-z0-9_]+$ ]] || driver="auto"

    i=$((i+1))
    file="$(printf '%s/meter-%04d' "${METER_DIR}" "${i}")"
    safe_driver="${driver}"

    {
      echo "name=search_${id}"
      echo "id=${id}"
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
  id="$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ -n "${id}" ]] || return 0
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
# Meter registration
# ------------------------------------------------------------
rm -f "${METER_DIR}/meter-"* 2>/dev/null || true

METERS_COUNT=0
if [[ -f "${OPTIONS_JSON}" ]] && jq -e '.meters and (.meters|length>0)' "${OPTIONS_JSON}" >/dev/null 2>&1; then
  METERS_COUNT="$(jq -r '.meters|length' "${OPTIONS_JSON}")"
fi
OFFICIAL_METERS_COUNT="${METERS_COUNT}"

if [[ "${METERS_COUNT}" -eq 0 && "${SEARCH_MODE}" == "true" && "${SEARCH_EXPECTED_VALUE_M3}" != "0" ]]; then
  cached_count="$(create_search_meter_files_from_cache)"
  if [[ "${cached_count}" =~ ^[0-9]+$ && "${cached_count}" -gt 0 ]]; then
    METERS_COUNT="${cached_count}"
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
elif [[ "${METERS_COUNT}" -eq 0 ]]; then
  warn "No meters configured -> LISTEN MODE (will log DLL-ID + suggested driver)."
  write_search_status "listen" "listen_mode"
else
  i=0
  while IFS= read -r meter_json; do
    i=$((i+1))
    file="$(printf '%s/meter-%04d' "${METER_DIR}" "${i}")"

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

    {
      echo "name=${friendly_name}"
      echo "id=${mid}"
      if [[ -n "${key}" ]]; then
        echo "key=${key}"
      fi
      if [[ "${driver}" != "auto" ]]; then
        echo "driver=${driver}"
      fi
    } > "${file}"

    log "meter: ${friendly_name} id=${mid} driver=${driver}"
  done < <(jq -c '.meters[]' "${OPTIONS_JSON}" 2>/dev/null || true)
  write_search_status "configured" "official_meters_configured"
fi

# ------------------------------------------------------------
# Discovery
# ------------------------------------------------------------
declare -A DISCOVERY_SENT_FIELD
declare -A DISCOVERY_CLEANED_LEGACY
declare -A SEARCH_DISCOVERY_CLEARED_FIELD

clean_legacy_totalm3() {
  local id="$1"
  [[ "${DISCOVERY_ENABLED}" == "true" ]] || return 0
  [[ -n "${id}" ]] || return 0

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
  id="$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ -n "${id}" ]] || return 0

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
  id="$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ -n "${id}" ]] || return 0

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
  local id="$1"
  local driver="$2"
  local type_line="${3:-}"
  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0

  # Update dashboard stats every time this candidate is heard.
  # Pass the real type_line from wmbusmeters output so the webui can
  # show encryption status (e.g. "Electricity meter (0x02) encrypted").
  status_candidate_seen "${id}" "${driver:-auto}" "${type_line:-listen}"

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
# Pipeline
# ------------------------------------------------------------
log "Starting wmbusmeters..."

run_once() {
  last_id=""
  last_driver=""
  last_type=""

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
          id="$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
          ts="$(echo "${line}" | jq -r '.timestamp // .device_date_time // empty' 2>/dev/null || true)"
          if [[ -n "${id}" ]]; then
            if [[ "${REQUIRE_TIMESTAMP}" == "true" && -z "${ts}" ]]; then
              warn "Skip publish: missing timestamp for id=${id}"
            else
              mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
              emit_discovery_from_json "${line}"
              STATUS_DISCOVERY_PUBLISHED="true"
              write_status_json
            fi
          fi
          continue
        fi

        echo "${line}"

        if [[ "${OFFICIAL_METERS_COUNT}" -eq 0 && "${SEARCH_USING_TEMP_METERS}" != "true" ]]; then
          if [[ "${line}" =~ ^Received\ telegram\ from:\ ([0-9]{8}) ]]; then
            last_id="${BASH_REMATCH[1]}"
            last_type=""
            last_driver=""
          fi
          if [[ "${line}" =~ ^[[:space:]]*type:[[:space:]]*(.*)$ ]]; then
            last_type="${BASH_REMATCH[1]}"
          fi
          if [[ "${line}" =~ ^[[:space:]]*driver:\ ([a-zA-Z0-9_]+) ]]; then
            last_driver="${BASH_REMATCH[1]}"
          fi
          if [[ -n "${last_id}" && -n "${last_driver}" ]]; then
            if [[ "${SEARCH_MODE}" == "true" && "${SEARCH_EXPECTED_VALUE_M3}" != "0" ]]; then
              search_cache_candidate "${last_id}" "${last_driver}" "${last_type}"
            else
              emit_snippet_if_new "${last_id}" "${last_driver}" "${last_type}"
            fi
            last_id=""
            last_driver=""
            last_type=""
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
          id="$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
          ts="$(echo "${line}" | jq -r '.timestamp // .device_date_time // empty' 2>/dev/null || true)"
          if [[ -n "${id}" ]]; then
            if [[ "${REQUIRE_TIMESTAMP}" == "true" && -z "${ts}" ]]; then
              warn "Skip publish: missing timestamp for id=${id}"
            else
              mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
              emit_discovery_from_json "${line}"
              STATUS_DISCOVERY_PUBLISHED="true"
              write_status_json
            fi
          fi
        else
          echo "${line}"
        fi
done
fi
}

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
  run_once
  rc=$?
  set -e
  if [[ "${RESTART_ON_EXIT}" != "true" ]]; then
    exit ${rc}
  fi
  warn "Pipeline exited (rc=${rc}), restarting in 2s..."
  STATUS_WMBUSMETERS_RUNNING="false"
  STATUS_LAST_ERROR="pipeline exited rc=${rc}"
  status_add_event "error" "Pipeline exited rc=${rc}"
  write_status_json
  sleep 2
  # continue
done
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
    *_kw) echo "kW";;
    *_w) echo "W";;
    *_kwh) echo "kWh";;
    *_wh) echo "Wh";;
    *_v) echo "V";;
    *_a) echo "A";;
    *_hz) echo "Hz";;
    *_m3|*volume*|*m3*) echo "m³";;
    *temperature*|*temp*|*_c) echo "°C";;
    *humidity*|*hum*|*_rh) echo "%";;
    *pressure*|*_hpa) echo "hPa";;
    *) echo "";;
  esac
}

guess_device_class() {
  local key_lc="$1"
  local unit="$2"
  case "${unit}" in
    "°C") echo "temperature";;
    "%") echo "humidity";;
    "W"|"kW") echo "power";;
    "Wh"|"kWh") echo "energy";;
    "V") echo "voltage";;
    "A") echo "current";;
    "Hz") echo "frequency";;
    "m³")
      if [[ "${key_lc}" == *gas* ]]; then echo "gas"; else echo "water"; fi
      ;;
    *)
      if [[ "${key_lc}" == *battery* ]]; then echo "battery"; else echo ""; fi
      ;;
  esac
}

guess_state_class() {
  local key_lc="$1"
  local device_class="$2"

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

  echo "measurement"
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
    warn "SEARCH ignored: id=${id} driver=${driver} type=${type_line:-unknown} reason=not_water_m3_candidate_or_encrypted (ignored=${SEARCH_IGNORED_COUNT})."
    return 0
  fi

  touch "${SEARCH_CANDIDATES_FILE}"
  if grep -q "^${id}	" "${SEARCH_CANDIDATES_FILE}" 2>/dev/null; then
    return 0
  fi

  printf '%s	%s
' "${id}" "${driver}" >> "${SEARCH_CANDIDATES_FILE}"

  local cached_count
  cached_count="$(grep -Ec '^[0-9]{8}[[:space:]]' "${SEARCH_CANDIDATES_FILE}" 2>/dev/null || true)"
  [[ "${cached_count}" =~ ^[0-9]+$ ]] || cached_count=0

  warn "SEARCH discovered: id=${id} driver=${driver} type=${type_line:-unknown} stored as water candidate (cached=${cached_count}, ignored=${SEARCH_IGNORED_COUNT})."
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

    warn "SEARCH temporary meter: search_${id} id=${id} driver=${safe_driver}"
  done < "${SEARCH_CANDIDATES_FILE}"

  echo "${i}"
}

process_search_json() {
  local json_line="$1"
  [[ "${SEARCH_MODE}" == "true" ]] || return 0

  local id
  id="$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ -n "${id}" ]] || return 0

  while IFS=$'\t' read -r field value; do
    [[ -n "${field}" && -n "${value}" ]] || continue

    local field_lc state_key diff absdiff in_tolerance delta
    field_lc="$(echo "${field}" | tr '[:upper:]' '[:lower:]')"
    search_field_is_candidate "${field_lc}" || continue

    state_key="${id}|${field}"
    diff="$(awk -v v="${value}" -v e="${SEARCH_EXPECTED_VALUE_M3}" 'BEGIN { printf "%.6f", v - e }')"
    absdiff="$(awk -v d="${diff}" 'BEGIN { if (d < 0) d = -d; printf "%.6f", d }')"

    in_tolerance="$(awk -v d="${absdiff}" -v t="${SEARCH_TOLERANCE_M3}" 'BEGIN { print (d <= t) ? "yes" : "no" }')"
    if [[ "${SEARCH_EXPECTED_VALUE_M3}" != "0" && "${in_tolerance}" == "yes" && -z "${SEARCH_REPORTED_EXPECTED[${state_key}]+x}" ]]; then
      warn "SEARCH candidate: id=${id} field=${field} value=${value} m3 expected=${SEARCH_EXPECTED_VALUE_M3} diff=${absdiff} m3"
      emit_search_payload "value_match" "${json_line}" "${field}" "${value}" "${absdiff}" "0"
      SEARCH_REPORTED_EXPECTED["${state_key}"]=1
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
    warn "No user meters configured -> SEARCH MODE (temporary cached candidates=${cached_count}, expected=${SEARCH_EXPECTED_VALUE_M3} m3, tolerance=${SEARCH_TOLERANCE_M3} m3)."
    warn "SEARCH MODE uses cached candidates from ${SEARCH_CANDIDATES_FILE}. Remove that file or disable search_mode to return to pure LISTEN MODE."
  else
    warn "No meters configured -> SEARCH DISCOVERY MODE."
    warn "SEARCH MODE needs decoded JSON values, but there are no cached candidates yet."
    warn "The bridge will collect id+driver candidates first. Let it run long enough to hear meters; restart later to decode cached candidates and compare m3 values."
  fi
elif [[ "${METERS_COUNT}" -eq 0 ]]; then
  warn "No meters configured -> LISTEN MODE (will log DLL-ID + suggested driver)."
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

  local id name meter
  id="$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ -n "${id}" ]] || return 0

  clean_legacy_totalm3 "${id}"

  name="$(jq -r '.name // .id // "wmbus"' <<<"${json_line}" 2>/dev/null || true)"
  meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"

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

    cache_key="${id}|${obj}"
    [[ -n "${DISCOVERY_SENT_FIELD[${cache_key}]+x}" ]] && continue

    key_lc="$(echo "${key}" | tr '[:upper:]' '[:lower:]')"
    unit="$(guess_unit "${key}")"
    device_class="$(guess_device_class "${key_lc}" "${unit}")"
    state_class="$(guess_state_class "${key_lc}" "${device_class}")"

    cfg_topic="${DISCOVERY_PREFIX}/sensor/${uniq}/${obj}/config"
    unique_id="${uniq}_${obj}"
    sensor_name="${name} ${key}"

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
      '(
        {
          name: $name,
          unique_id: $uniq,
          state_topic: $st,
          value_template: "{{ value_json['\''\($key)'\'' ] }}",
          json_attributes_topic: $st,
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


# Clear retained HA MQTT Discovery configs left by older SEARCH runs.
# This is intentionally based on the cached candidate list and common numeric
# water-meter fields, because when SEARCH is disabled there are no search_*
# JSON telegrams anymore from which we could infer exact discovery fields.
clear_search_discovery_for_cached_id() {
  local id="$1"
  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0

  local uniq="wmbus_${id}"
  local field obj cache_key cfg_topic
  local fields=(
    total_m3
    backflow_m3
    voltage_v
    target_m3
    volume_m3
    total_volume_m3
    current_consumption_m3
  )

  # Legacy one-off config topic used by older bridge versions.
  cache_key="legacy|${id}|total_m3"
  if [[ -z "${SEARCH_DISCOVERY_CLEARED_FIELD[${cache_key}]+x}" ]]; then
    mqtt_pub "${DISCOVERY_PREFIX}/sensor/wmbus_${id}/total_m3/config" "" "true" || true
    SEARCH_DISCOVERY_CLEARED_FIELD["${cache_key}"]=1
  fi

  for field in "${fields[@]}"; do
    obj="$(sanitize_obj_id "${field}")"
    [[ -n "${obj}" ]] || continue

    cache_key="common|${id}|${obj}"
    [[ -n "${SEARCH_DISCOVERY_CLEARED_FIELD[${cache_key}]+x}" ]] && continue

    cfg_topic="${DISCOVERY_PREFIX}/sensor/${uniq}/${obj}/config"
    mqtt_pub "${cfg_topic}" "" "true" || true
    SEARCH_DISCOVERY_CLEARED_FIELD["${cache_key}"]=1
  done
}

cleanup_search_discovery_from_cache() {
  [[ -f "${SEARCH_CANDIDATES_FILE}" ]] || return 0

  local count=0
  local id driver
  while IFS=$'\t' read -r id driver; do
    [[ "${id}" =~ ^[0-9]{8}$ ]] || continue
    clear_search_discovery_for_cached_id "${id}"
    count=$((count + 1))
  done < "${SEARCH_CANDIDATES_FILE}"

  if [[ "${count}" -gt 0 ]]; then
    warn "SEARCH cleanup: cleared retained HA Discovery configs for cached search candidates (count=${count})."
  fi
}

# If SEARCH is no longer running in temporary-meter mode, clean up retained HA
# Discovery configs created by older buggy SEARCH runs. Without this, HA keeps
# stale search_* devices/entities even after search_mode is disabled.
if [[ "${SEARCH_USING_TEMP_METERS}" != "true" ]]; then
  cleanup_search_discovery_from_cache
fi

# ------------------------------------------------------------
# Listen-mode snippet (best-effort)
# ------------------------------------------------------------
SNIPPET_STATE="${BASE}/seen_ids.txt"
touch "${SNIPPET_STATE}"

emit_snippet_if_new() {
  local id="$1"
  local driver="$2"
  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0

  if ! grep -qx "${id}" "${SNIPPET_STATE}" 2>/dev/null; then
    echo "${id}" >> "${SNIPPET_STATE}"
    warn "=== NEW METER CANDIDATE DETECTED ==="
    warn "Received telegram from: ${id}"
    [[ -n "${driver}" ]] && warn "Suggested driver: ${driver}"
    warn "Add to options.json meters[] (example):"
    warn "  {\"id\":\"meter_${id}\",\"meter_id\":\"${id}\",\"type\":\"auto\",\"type_other\":\"\",\"key\":\"NOKEY\"}"
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
    | ${STDBUF_BIN} /usr/bin/wmbusmeters --useconfig="${BASE}" 2>&1 \
    | while IFS= read -r line; do
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
              emit_snippet_if_new "${last_id}" "${last_driver}"
            fi
            last_id=""
            last_driver=""
            last_type=""
          fi
        fi

        if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
          process_search_json "${line}"
          if is_search_temp_json "${line}"; then
            clear_search_discovery_from_json "${line}"
            continue
          fi
          id="$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
          ts="$(echo "${line}" | jq -r '.timestamp // .device_date_time // empty' 2>/dev/null || true)"
          if [[ -n "${id}" ]]; then
            if [[ "${REQUIRE_TIMESTAMP}" == "true" && -z "${ts}" ]]; then
              warn "Skip publish: missing timestamp for id=${id}"
            else
              mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
              emit_discovery_from_json "${line}"
            fi
          fi
        fi
done
else
  ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" "${SUB_EXTRA[@]}" -t "${RAW_TOPIC}" -F '%p' \
    | ${STDBUF_BIN} /usr/bin/wmbusmeters --useconfig="${BASE}" 2>&1 \
    | while IFS= read -r line; do
        echo "${line}"
        if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
          process_search_json "${line}"
          if is_search_temp_json "${line}"; then
            clear_search_discovery_from_json "${line}"
            continue
          fi
          id="$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
          ts="$(echo "${line}" | jq -r '.timestamp // .device_date_time // empty' 2>/dev/null || true)"
          if [[ -n "${id}" ]]; then
            if [[ "${REQUIRE_TIMESTAMP}" == "true" && -z "${ts}" ]]; then
              warn "Skip publish: missing timestamp for id=${id}"
            else
              mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
              emit_discovery_from_json "${line}"
            fi
          fi
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
      return 0
    fi
    warn "MQTT not ready (attempt ${i}/${MQTT_WAIT_RETRIES}), retrying in ${MQTT_WAIT_DELAY}s..."
    sleep "${MQTT_WAIT_DELAY}"
  done
  # Broker niedostępny po wszystkich próbach - ostrzegamy ale nie przerywamy,
  # pętla restart_on_exit zajmie się ponownym uruchomieniem pipeline.
  warn "MQTT broker not available after ${MQTT_WAIT_RETRIES} attempts, continuing anyway..."
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
  sleep 2
  # continue
done
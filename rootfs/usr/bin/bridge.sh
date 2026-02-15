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
RAW_TOPIC="${RAW_TOPIC:-$(json_get '.raw_topic' 'wmbus_bridge/telegram')}"
LOGLEVEL="${LOGLEVEL:-$(json_get '.loglevel' 'normal')}"
FILTER_HEX_ONLY="${FILTER_HEX_ONLY:-$(json_get_bool '.filter_hex_only' 'true')}"
DEBUG_EVERY_N="${DEBUG_EVERY_N:-$(json_get_int '.debug_every_n' '0')}"

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

log "core: bridge.sh (base=${BASE})"
log "MQTT: ${MQTT_HOST}:${MQTT_PORT} topic=${RAW_TOPIC}"
log "state: prefix=${STATE_PREFIX} retain=${STATE_RETAIN}"
log "discovery: enabled=${DISCOVERY_ENABLED} prefix=${DISCOVERY_PREFIX} retain=${DISCOVERY_RETAIN}"
log "wmbusmeters: loglevel=${LOGLEVEL} filter_hex_only=${FILTER_HEX_ONLY} debug_every_n=${DEBUG_EVERY_N}"

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

  [[ "${mid_raw}" =~ ^[0-9]+$ ]] || { echo ""; return 0; }

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

  echo "measurement"
}

# ------------------------------------------------------------
# Meter registration
# ------------------------------------------------------------
rm -f "${METER_DIR}/meter-"* 2>/dev/null || true

METERS_COUNT=0
if [[ -f "${OPTIONS_JSON}" ]] && jq -e '.meters and (.meters|length>0)' "${OPTIONS_JSON}" >/dev/null 2>&1; then
  METERS_COUNT="$(jq -r '.meters|length' "${OPTIONS_JSON}")"
fi

if [[ "${METERS_COUNT}" -eq 0 ]]; then
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
    key="$(echo "${meter_json}" | jq -r '.key // "NOKEY"')"

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
      echo "key=${key}"
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

clean_legacy_totalm3() {
  local id="$1"
  [[ "${DISCOVERY_ENABLED}" == "true" ]] || return 0
  [[ -n "${id}" ]] || return 0
  if [[ -z "${DISCOVERY_CLEANED_LEGACY[${id}]+x}" ]]; then
    mqtt_pub "${DISCOVERY_PREFIX}/sensor/wmbus_${id}/total_m3/config" "" "true" || true
    DISCOVERY_CLEANED_LEGACY["${id}"]=1
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
    DISCOVERY_SENT_FIELD["${cache_key}"]=1

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

    mqtt_pub "${cfg_topic}" "${payload}" "${DISCOVERY_RETAIN}" || true
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

last_id=""
last_driver=""

if [[ "${FILTER_HEX_ONLY}" == "true" ]]; then
  /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "${RAW_TOPIC}" -F '%p' \
    | awk -v dbg_n="${DEBUG_EVERY_N}" '
        function ishex(s) { return (s ~ /^[0-9A-Fa-f]+$/) }
        BEGIN { n=0 }
        {
          gsub(/[[:space:]]/, "", $0);
          sub(/^0x/i, "", $0);
          if (!ishex($0)) next;

          n++;
          if (dbg_n > 0 && (n % dbg_n) == 0) {
            printf("[MQTT HEX] #%d %s...\n", n, substr($0,1,16)) > "/dev/stderr";
          }
          print $0;
          fflush();
        }
      ' \
    | /usr/bin/wmbusmeters --useconfig="${BASE}" 2>&1 \
    | while IFS= read -r line; do
        echo "${line}"

        if [[ "${METERS_COUNT}" -eq 0 ]]; then
          if [[ "${line}" =~ ^Received\ telegram\ from:\ ([0-9]{8}) ]]; then
            last_id="${BASH_REMATCH[1]}"
          fi
          if [[ "${line}" =~ ^[[:space:]]*driver:\ ([a-zA-Z0-9_]+) ]]; then
            last_driver="${BASH_REMATCH[1]}"
          fi
          if [[ -n "${last_id}" && -n "${last_driver}" ]]; then
            emit_snippet_if_new "${last_id}" "${last_driver}"
            last_id=""
            last_driver=""
          fi
        fi

        if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
          id="$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
          if [[ -n "${id}" ]]; then
            mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
            emit_discovery_from_json "${line}"
          fi
        fi
      done
else
  /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "${RAW_TOPIC}" -F '%p' \
    | /usr/bin/wmbusmeters --useconfig="${BASE}" 2>&1 \
    | while IFS= read -r line; do
        echo "${line}"
        if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
          id="$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
          if [[ -n "${id}" ]]; then
            mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
            emit_discovery_from_json "${line}"
          fi
        fi
      done
fi

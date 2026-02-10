bashio::log.info "run.sh: autodiscovery generic v1.2.6"
#!/usr/bin/with-contenv bashio
set -euo pipefail

# ============================================================
# wMBus MQTT Bridge
# - Subskrybuje RAW HEX z MQTT (payload-only)
# - Karmi wmbusmeters przez stdin:hex
# - Odbiera JSON z wmbusmeters i publikuje:
#     * state topic:   <state_prefix>/<id>/state
#     * MQTT Discovery: <discovery_prefix>/sensor/<uniq>/<field>/config
#
# Tryb diagnostyczny:
# - Jeśli meters[] jest puste, wmbusmeters przechodzi w LISTEN MODE
#   i wypisuje "Received telegram from: XXXXXXXX" + sugerowany driver.
#   Add-on wypisze też gotowy snippet do wklejenia w opcjach.
# ============================================================

# =========================
# MQTT (z serwisu HA)
# =========================
MQTT_HOST="$(bashio::services mqtt "host")"
MQTT_PORT="$(bashio::services mqtt "port")"
MQTT_USER="$(bashio::services mqtt "username")"
MQTT_PASS="$(bashio::services mqtt "password")"

RAW_TOPIC="$(bashio::config 'raw_topic')"

LOGLEVEL="$(bashio::config 'loglevel')"
[[ -z "${LOGLEVEL}" || "${LOGLEVEL}" == "null" ]] && LOGLEVEL="normal"

FILTER_HEX_ONLY="$(bashio::config 'filter_hex_only')"
[[ -z "${FILTER_HEX_ONLY}" || "${FILTER_HEX_ONLY}" == "null" ]] && FILTER_HEX_ONLY="true"

DEBUG_EVERY_N="$(bashio::config 'debug_every_n')"
[[ -z "${DEBUG_EVERY_N}" || "${DEBUG_EVERY_N}" == "null" ]] && DEBUG_EVERY_N="0"

DISCOVERY_ENABLED="$(bashio::config 'discovery_enabled')"
[[ -z "${DISCOVERY_ENABLED}" || "${DISCOVERY_ENABLED}" == "null" ]] && DISCOVERY_ENABLED="true"

DISCOVERY_PREFIX="$(bashio::config 'discovery_prefix')"
[[ -z "${DISCOVERY_PREFIX}" || "${DISCOVERY_PREFIX}" == "null" ]] && DISCOVERY_PREFIX="homeassistant"

DISCOVERY_RETAIN="$(bashio::config 'discovery_retain')"
[[ -z "${DISCOVERY_RETAIN}" || "${DISCOVERY_RETAIN}" == "null" ]] && DISCOVERY_RETAIN="true"

STATE_PREFIX="$(bashio::config 'state_prefix')"
[[ -z "${STATE_PREFIX}" || "${STATE_PREFIX}" == "null" ]] && STATE_PREFIX="wmbusmeters"

STATE_RETAIN="$(bashio::config 'state_retain')"
[[ -z "${STATE_RETAIN}" || "${STATE_RETAIN}" == "null" ]] && STATE_RETAIN="false"

BASE="/data"
ETC_DIR="${BASE}/etc"
METER_DIR="${ETC_DIR}/wmbusmeters.d"
CONF_FILE="${ETC_DIR}/wmbusmeters.conf"
OPTIONS_JSON="${BASE}/options.json"

mkdir -p "${METER_DIR}" "${ETC_DIR}"

bashio::log.info "MQTT broker: ${MQTT_HOST}:${MQTT_PORT}"
bashio::log.info "Subscribing to: ${RAW_TOPIC}"
bashio::log.info "wmbusmeters loglevel: ${LOGLEVEL}"
bashio::log.info "filter_hex_only: ${FILTER_HEX_ONLY}"
bashio::log.info "debug_every_n: ${DEBUG_EVERY_N}"
bashio::log.info "discovery_enabled: ${DISCOVERY_ENABLED} (prefix=${DISCOVERY_PREFIX}, retain=${DISCOVERY_RETAIN})"
bashio::log.info "state_prefix: ${STATE_PREFIX} (retain=${STATE_RETAIN})"

# =========================
# MQTT args
# =========================
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

  if ! /usr/bin/mosquitto_pub "${PUB_ARGS[@]}" -t "${topic}" "${retain_flag[@]}" -m "${payload}"; then
    bashio::log.error "mosquitto_pub FAILED topic='${topic}'"
    return 1
  fi
  return 0
}

# =========================
# wmbusmeters.conf
# (bez mqtt_host/mqtt_port — w niektórych buildach to wywala 'No such key')
# =========================
cat > "${CONF_FILE}" <<EOF
loglevel=${LOGLEVEL}
device=stdin:hex
logfile=/dev/stdout
format=json
EOF

bashio::log.info "options.json:"
jq -c '.' "${OPTIONS_JSON}" | while read -r line; do bashio::log.info "${line}"; done

# =========================
# Normalizacja meter_id
# =========================
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

# =========================
# Generowanie /data/etc/wmbusmeters.d/meter-XXXX
# =========================
bashio::log.info "Registering meters ..."
rm -f "${METER_DIR}/meter-"* 2>/dev/null || true

METERS_COUNT="0"
if jq -e '.meters and (.meters|length>0)' "${OPTIONS_JSON}" >/dev/null 2>&1; then
  METERS_COUNT="$(jq -r '.meters|length' "${OPTIONS_JSON}")"
fi

if [[ "${METERS_COUNT}" == "0" ]]; then
  bashio::log.warning "No meters configured -> LISTEN MODE."
  bashio::log.warning "Zostaw addon chwilę. W logach zobaczysz: 'Received telegram from: XXXXXXXX'."
  bashio::log.warning "To jest DLL-ID, które wpisujesz jako meter_id."
else
  i=0
  while IFS= read -r meter_json; do
    i=$((i+1))
    file="$(printf '%s/meter-%04d' "${METER_DIR}" "${i}")"

    name="$(echo "${meter_json}" | jq -r '.id')"
    driver="$(echo "${meter_json}" | jq -r '.type')"
    mid_raw="$(echo "${meter_json}" | jq -r '.meter_id')"
    key="$(echo "${meter_json}" | jq -r '.key // "NOKEY"')"

    mid="$(normalize_meter_id "${mid_raw}")"
    if [[ -z "${mid}" ]]; then
      bashio::log.error "Niepoprawny meter_id dla '${name}' -> pomijam (dostałem: '${mid_raw}')."
      continue
    fi

    cat > "${file}" <<EOF
name=${name}
id=${mid}
key=${key}
driver=${driver}
EOF

    bashio::log.info "Added ${file} (name=${name}, driver=${driver}, id=${mid})"
  done < <(jq -c '.meters[]' "${OPTIONS_JSON}")
fi

bashio::log.info "Generated ${CONF_FILE}:"
sed 's/^/[CONF] /' "${CONF_FILE}" | while read -r line; do bashio::log.info "${line#[CONF] }"; done

bashio::log.info "Meters directory: ${METER_DIR}"
ls -la "${METER_DIR}" | while read -r line; do bashio::log.info "${line}"; done

# =========================
# MQTT Discovery (GENERIC)
# - Encja dla każdego pola numerycznego w JSON (driver-agnostic)
# - Config jest retained -> HA po restarcie sam odtwarza encje
# =========================
declare -A DISCOVERY_SENT_FIELD
declare -A DISCOVERY_CLEANED_TOTALM3

sanitize_obj_id() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_]+/_/g; s/^_+//; s/_+$//; s/__+/_/g'
}

guess_unit() {
  local key="$1"
  local sfx="${key##*_}"
  sfx="$(echo "${sfx}" | tr '[:upper:]' '[:lower:]')"
  case "${sfx}" in
    kwh) echo "kWh" ;;
    wh)  echo "Wh" ;;
    mwh) echo "MWh" ;;
    w)   echo "W" ;;
    kw)  echo "kW" ;;
    v)   echo "V" ;;
    a)   echo "A" ;;
    hz)  echo "Hz" ;;
    c|degc) echo "°C" ;;
    m3)  echo "m³" ;;
    l)   echo "L" ;;
    bar) echo "bar" ;;
    hpa) echo "hPa" ;;
    pa)  echo "Pa" ;;
    ppm) echo "ppm" ;;
    dbm) echo "dBm" ;;
    percent|pct) echo "%" ;;
    *)   echo "" ;;
  esac
}

guess_device_class() {
  local key_lc="$1"
  local unit="$2"

  if [[ "${key_lc}" == *battery* ]]; then echo "battery"; return 0; fi
  if [[ "${key_lc}" == *humidity* ]]; then echo "humidity"; return 0; fi
  if [[ "${key_lc}" == *temperature* ]]; then echo "temperature"; return 0; fi

  case "${unit}" in
    "kWh"|"Wh"|"MWh") echo "energy" ;;
    "W"|"kW")         echo "power" ;;
    "V")              echo "voltage" ;;
    "A")              echo "current" ;;
    "Hz")             echo "frequency" ;;
    "°C")             echo "temperature" ;;
    "m³"|"L")         echo "volume" ;;
    "bar"|"hPa"|"Pa") echo "pressure" ;;
    "dBm")            echo "signal_strength" ;;
    "%")              echo "battery" ;;
    *)                echo "" ;;
  esac
}

guess_state_class() {
  local key_lc="$1"
  local device_class="$2"

  if [[ "${device_class}" =~ ^(energy|volume)$ ]]; then
    if [[ "${key_lc}" == *total* || "${key_lc}" == *consumption* || "${key_lc}" == *meter* ]]; then
      echo "total_increasing"
      return 0
    fi
  fi

  [[ -n "${device_class}" ]] && echo "measurement" || echo ""
}

emit_discovery_from_json() {
  local json_line="$1"
  [[ "${DISCOVERY_ENABLED}" == "true" ]] || return 0

  local id name meter
  id="$(echo "${json_line}" | jq -r '.id // empty' 2>/dev/null || true)"
  [[ -n "${id}" ]] || return 0

  name="$(echo "${json_line}" | jq -r '.name // .id // "wmbus"' 2>/dev/null || true)"
  meter="$(echo "${json_line}" | jq -r '.meter // empty' 2>/dev/null || true)"

  local uniq="wmbus_${id}"
  local state_topic="${STATE_PREFIX}/${id}/state"
  local dev_name="${name} (${id})"
  local dev_mdl="${meter:-wmbusmeter}"
  local dev_mfr="wmbusmeters"

  # posprzątaj stary, sztywny discovery "total_m3" jeśli to NIE jest wodomierz
  if [[ -z "${DISCOVERY_CLEANED_TOTALM3[${id}]+x}" ]]; then
    if ! echo "${json_line}" | jq -e '.total_m3 and ((.total_m3|type)=="number")' >/dev/null 2>&1; then
      mqtt_pub "${DISCOVERY_PREFIX}/sensor/${uniq}/total_m3/config" "" "true" || true
    fi
    DISCOVERY_CLEANED_TOTALM3["${id}"]=1
  fi

  echo "${json_line}" \
    | jq -r '
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
      ' 2>/dev/null \
    | while IFS= read -r key; do
        [[ -n "${key}" ]] || continue

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
          '{
            name: $name,
            unique_id: $uniq,
            state_topic: $st,
            value_template: "{{ value_json[\"" + $key + "\"] }}",
            json_attributes_topic: $st,
            device: {
              identifiers: [$did],
              name: $dname,
              model: $dmdl,
              manufacturer: $dmfr
            }
          }
          + ( ($unit|length)>0 ? {unit_of_measurement:$unit} : {} )
          + ( ($dc|length)>0 ? {device_class:$dc} : {} )
          + ( ($sc|length)>0 ? {state_class:$sc} : {} )
          ')"

        mqtt_pub "${cfg_topic}" "${payload}" "${DISCOVERY_RETAIN}" || true
      done
}

# =========================
# Listen-mode: snippet gdy pojawi się nowy licznik
# =========================
SNIPPET_STATE="/data/seen_ids.txt"
touch "${SNIPPET_STATE}"

emit_snippet_if_new() {
  local id="$1"
  local driver="$2"

  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0
  if ! grep -qx "${id}" "${SNIPPET_STATE}"; then
    echo "${id}" >> "${SNIPPET_STATE}"

    bashio::log.warning "=== NEW METER CANDIDATE DETECTED ==="
    bashio::log.warning "Received telegram from: ${id}"
    [[ -n "${driver}" ]] && bashio::log.warning "Suggested driver: ${driver}"
    bashio::log.warning "Paste into add-on options:"
    bashio::log.warning "meters:"
    bashio::log.warning "  - id: meter_${id}"
    bashio::log.warning "    meter_id: \"${id}\""
    bashio::log.warning "    type: ${driver:-<set_driver_here>}"
    bashio::log.warning "    key: NOKEY"
    bashio::log.warning "=================================="
  fi
}

# =========================
# Pipeline: MQTT -> stdin -> wmbusmeters -> JSON -> MQTT (state + discovery)
# =========================
bashio::log.info "Starting wmbusmeters..."

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

        if [[ "${METERS_COUNT}" == "0" ]]; then
          if [[ "${line}" =~ ^Received\ telegram\ from:\ ([0-9]{8}) ]]; then
            last_id="${BASH_REMATCH[1]}"
          fi
          if [[ "${line}" =~ ^[[:space:]]*driver:\ ([a-zA-Z0-9_]+) ]]; then
            last_driver="${BASH_REMATCH[1]}"
          fi
          if [[ -n "${last_id:-}" && -n "${last_driver:-}" ]]; then
            emit_snippet_if_new "${last_id}" "${last_driver}"
            last_id=""
            last_driver=""
          fi
        fi

        if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
          id="$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
          if [[ -n "${id}" ]]; then
            state_topic="${STATE_PREFIX}/${id}/state"
            mqtt_pub "${state_topic}" "${line}" "${STATE_RETAIN}" || true
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
            state_topic="${STATE_PREFIX}/${id}/state"
            mqtt_pub "${state_topic}" "${line}" "${STATE_RETAIN}" || true
            emit_discovery_from_json "${line}"
          fi
        fi
      done
fi

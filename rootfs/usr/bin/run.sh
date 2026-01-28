#!/usr/bin/with-contenv bashio
set -euo pipefail

# ============================================================
# wMBus MQTT Bridge
# - Subskrybuje RAW HEX z MQTT (payload-only)
# - Karmi wmbusmeters przez stdin:hex
# - Odbiera JSON z wmbusmeters i publikuje:
#     * state topic:   <state_prefix>/<id>/state
#     * MQTT Discovery: <discovery_prefix>/sensor/<uniq>/total_m3/config
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
# Akceptuje:
# - "3528221"      -> "03528221"
# - "03528221"     -> "03528221"
# - "0x03528221"   -> "03528221"   (traktujemy jako zapis ID, NIE hex->dec)
#
# Uwaga: nie używamy printf %d, bo wartości z wiodącym zerem
# + cyframi 8/9 potrafią być interpretowane jako ósemkowe -> "invalid octal".
# =========================
normalize_meter_id() {
  local mid_raw="$1"
  mid_raw="$(echo "${mid_raw}" | tr -d '[:space:]')"
  [[ -z "${mid_raw}" || "${mid_raw}" == "null" ]] && { echo ""; return 0; }

  mid_raw="${mid_raw#0x}"
  mid_raw="${mid_raw#0X}"

  # tylko cyfry
  [[ "${mid_raw}" =~ ^[0-9]+$ ]] || { echo ""; return 0; }

  # dopaduj do 8 cyfr (DLL-ID zwykle ma 8 znaków)
  if [[ "${#mid_raw}" -lt 8 ]]; then
    printf "%8s" "${mid_raw}" | tr ' ' '0'
  else
    echo "${mid_raw}"
  fi
}

# =========================
# Generowanie /data/etc/wmbusmeters.d/meter-XXXX
# WAŻNE:
# - W meter-file NIE MA 'mode' (to nie jest klucz wmbusmeters)
# - driver jest potrzebny, ale w LISTEN MODE wmbusmeters sam go zasugeruje.
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
# MQTT Discovery
# - Minimalny sensor: total_m3 (m³)
# - Pozostałe pola w JSON lądują jako attributes (json_attributes_topic)
# =========================
declare -A DISCOVERY_SENT

emit_discovery() {
  local id="$1"
  local name="$2"
  local meter="$3"

  [[ "${DISCOVERY_ENABLED}" == "true" ]] || return 0
  [[ -n "${id}" ]] || return 0

  # nie wysyłaj tego samego configu w kółko
  if [[ -n "${DISCOVERY_SENT[${id}]+x}" ]]; then
    return 0
  fi
  DISCOVERY_SENT["${id}"]=1

  local uniq="wmbus_${id}"
  local state_topic="${STATE_PREFIX}/${id}/state"
  local cfg_topic="${DISCOVERY_PREFIX}/sensor/${uniq}/total_m3/config"

  # device group (żeby encje ładnie siedziały pod jednym urządzeniem)
  # identifiers: stały identyfikator urządzenia w HA
  local dev_name="wMBus ${id}"
  local dev_mdl="${meter:-wmbusmeter}"
  local dev_mfr="wmbusmeters"

  local payload
  payload="$(jq -c -n \
    --arg name "${name} total" \
    --arg uniq "${uniq}_total_m3" \
    --arg st "${state_topic}" \
    --arg did "${uniq}" \
    --arg dname "${dev_name}" \
    --arg dmdl "${dev_mdl}" \
    --arg dmfr "${dev_mfr}" \
    '{
      name: $name,
      unique_id: $uniq,
      state_topic: $st,
      unit_of_measurement: "m³",
      device_class: "water",
      state_class: "total_increasing",
      value_template: "{{ value_json.total_m3 }}",
      json_attributes_topic: $st,
      icon: "mdi:water",
      device: {
        identifiers: [$did],
        name: $dname,
        model: $dmdl,
        manufacturer: $dmfr
      }
    }')"

  mqtt_pub "${cfg_topic}" "${payload}" "${DISCOVERY_RETAIN}" || true
  bashio::log.info "MQTT discovery published for id=${id} (topic=${cfg_topic})"
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

# Wejście:
# - mosquitto_sub -F '%p' => tylko payload (bez topic)
# - opcjonalny filtr: zostaw tylko czysty HEX (usuń spacje / 0x / śmieci)
#
# Wyjście:
# - wmbusmeters loguje tekst + linie JSON
# - JSON publikujemy do state_topic, a discovery generujemy raz na ID
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
        # 1) loguj wszystko (przydaje się do debug)
        echo "${line}"

        # 2) Listen-mode: wyciągaj ID + driver z tekstu wmbusmeters
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

        # 3) JSON telegram -> publish state + discovery
        if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
          id="$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
          name="$(echo "${line}" | jq -r '.name // .id // "wmbus"' 2>/dev/null || true)"
          meter="$(echo "${line}" | jq -r '.meter // empty' 2>/dev/null || true)"

          if [[ -n "${id}" ]]; then
            state_topic="${STATE_PREFIX}/${id}/state"
            mqtt_pub "${state_topic}" "${line}" "${STATE_RETAIN}" || true
            emit_discovery "${id}" "${name}" "${meter}"
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
          name="$(echo "${line}" | jq -r '.name // .id // "wmbus"' 2>/dev/null || true)"
          meter="$(echo "${line}" | jq -r '.meter // empty' 2>/dev/null || true)"
          if [[ -n "${id}" ]]; then
            state_topic="${STATE_PREFIX}/${id}/state"
            mqtt_pub "${state_topic}" "${line}" "${STATE_RETAIN}" || true
            emit_discovery "${id}" "${name}" "${meter}"
          fi
        fi
      done
fi

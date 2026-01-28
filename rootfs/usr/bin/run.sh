#!/usr/bin/with-contenv bashio
set -euo pipefail

# ============================================================
#  MQTT (z usługi HA)
# ============================================================
MQTT_HOST="$(bashio::services mqtt "host")"
MQTT_PORT="$(bashio::services mqtt "port")"
MQTT_USER="$(bashio::services mqtt "username")"
MQTT_PASS="$(bashio::services mqtt "password")"

RAW_TOPIC="$(bashio::config 'raw_topic')"

# ============================================================
#  Opcje addona
# ============================================================
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

# ============================================================
#  Pliki konfiguracyjne wmbusmeters
# ============================================================
BASE="/data"
ETC_DIR="${BASE}/etc"
METER_DIR="${ETC_DIR}/wmbusmeters.d"
CONF_FILE="${ETC_DIR}/wmbusmeters.conf"
OPTIONS_JSON="${BASE}/options.json"

mkdir -p "${METER_DIR}" "${ETC_DIR}"

# ============================================================
#  Sprawdzenie narzędzi (tu najczęściej ludzie się wywalają)
# ============================================================
for bin in mosquitto_sub mosquitto_pub jq wmbusmeters awk; do
  if ! command -v "${bin}" >/dev/null 2>&1; then
    bashio::log.error "Brak binarki: ${bin}. Dodaj do obrazu (np. mosquitto-clients / jq)."
    exit 1
  fi
done

# ============================================================
#  MQTT args
# ============================================================
PUB_ARGS=( -h "${MQTT_HOST}" -p "${MQTT_PORT}" )
SUB_ARGS=( -h "${MQTT_HOST}" -p "${MQTT_PORT}" )

[[ -n "${MQTT_USER}" && "${MQTT_USER}" != "null" ]] && PUB_ARGS+=( -u "${MQTT_USER}" ) && SUB_ARGS+=( -u "${MQTT_USER}" )
[[ -n "${MQTT_PASS}" && "${MQTT_PASS}" != "null" ]] && PUB_ARGS+=( -P "${MQTT_PASS}" ) && SUB_ARGS+=( -P "${MQTT_PASS}" )

# ============================================================
#  Log start
# ============================================================
bashio::log.info "MQTT broker: ${MQTT_HOST}:${MQTT_PORT}"
bashio::log.info "Subscribing to: ${RAW_TOPIC}"
bashio::log.info "wmbusmeters loglevel: ${LOGLEVEL}"
bashio::log.info "filter_hex_only: ${FILTER_HEX_ONLY}"
bashio::log.info "debug_every_n: ${DEBUG_EVERY_N}"
bashio::log.info "discovery_enabled: ${DISCOVERY_ENABLED} (prefix=${DISCOVERY_PREFIX}, retain=${DISCOVERY_RETAIN})"
bashio::log.info "state_prefix: ${STATE_PREFIX}"

# ============================================================
#  wmbusmeters.conf
# ============================================================
cat > "${CONF_FILE}" <<EOF
loglevel=${LOGLEVEL}
device=stdin:hex
logfile=/dev/stdout
format=json
EOF

# ============================================================
#  Debug: pokaż options.json
# ============================================================
bashio::log.info "options.json:"
jq -c '.' "${OPTIONS_JSON}" | while read -r line; do bashio::log.info "${line}"; done

# ============================================================
#  Normalizacja meter_id:
#   - akceptujemy: "03528221" (z wiodącym zerem)
#   - akceptujemy: "0x03528221"
#   - akceptujemy: "55701281" (dziesiętnie)
#  W pliku meter-XXXX dla wmbusmeters najlepiej trzymać DLL-ID jako cyfry (np. 03528221).
# ============================================================
normalize_meter_id() {
  local mid_raw="$1"
  mid_raw="$(echo "${mid_raw}" | tr -d '[:space:]')"
  [[ -z "${mid_raw}" || "${mid_raw}" == "null" ]] && { echo ""; return 0; }

  if [[ "${mid_raw}" =~ ^0x[0-9a-fA-F]+$ ]]; then
    # HEX -> decimal (bezpieczniej do matchingów wmbusmeters)
    local hex="${mid_raw#0x}"
    printf "%d" "$((16#${hex}))"
    return 0
  fi

  echo "${mid_raw}"
}

# ============================================================
#  Generowanie plików liczników (może być 0 -> listen mode)
# ============================================================
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
    mode="$(echo "${meter_json}" | jq -r '.mode // empty')"
    mid_raw="$(echo "${meter_json}" | jq -r '.meter_id')"
    key="$(echo "${meter_json}" | jq -r '.key // "NOKEY"')"

    mid="$(normalize_meter_id "${mid_raw}")"
    [[ -z "${mid}" ]] && { bashio::log.error "Pusty meter_id dla '${name}' -> pomijam."; continue; }

    # Plik meter-XXXX: minimalny i stabilny zestaw
    cat > "${file}" <<EOF
name=${name}
id=${mid}
key=${key}
driver=${driver}
EOF

    # Mode trzymamy w opcjach dla usera, ale wmbusmeters i tak rozpoznaje po ramce.
    [[ -n "${mode}" && "${mode}" != "null" ]] && echo "mode=${mode}" >> "${file}"

    bashio::log.info "Added ${file} (name=${name}, driver=${driver}, id=${mid})"
  done < <(jq -c '.meters[]' "${OPTIONS_JSON}")
fi

bashio::log.info "Generated ${CONF_FILE}:"
sed 's/^/[CONF] /' "${CONF_FILE}" | while read -r line; do bashio::log.info "${line#[CONF] }"; done

bashio::log.info "Meters directory: ${METER_DIR}"
ls -la "${METER_DIR}" | while read -r line; do bashio::log.info "${line}"; done

# ============================================================
#  MQTT Discovery helpers
# ============================================================
retain_flag=""
[[ "${DISCOVERY_RETAIN}" == "true" ]] && retain_flag="-r"

publish_bridge_status() {
  mosquitto_pub "${PUB_ARGS[@]}" ${retain_flag} -t "${STATE_PREFIX}/bridge/status" -m "online" >/dev/null 2>&1 || true
}

publish_discovery_for_meter() {
  local meter_name="$1"
  local meter_id="$2"
  local meter_driver="$3"

  # Unikalne i stabilne unique_id
  local uid_base="wmbus_${meter_id}"

  # 1) total_m3
  mosquitto_pub "${PUB_ARGS[@]}" ${retain_flag} \
    -t "${DISCOVERY_PREFIX}/sensor/${uid_base}/total_m3/config" \
    -m "{
      \"name\":\"${meter_name} total\",
      \"unique_id\":\"${uid_base}_total_m3\",
      \"state_topic\":\"${STATE_PREFIX}/${meter_id}/state\",
      \"value_template\":\"{{ value_json.total_m3 }}\",
      \"unit_of_measurement\":\"m³\",
      \"device_class\":\"water\",
      \"state_class\":\"total_increasing\",
      \"json_attributes_topic\":\"${STATE_PREFIX}/${meter_id}/state\",
      \"availability_topic\":\"${STATE_PREFIX}/bridge/status\",
      \"payload_available\":\"online\",
      \"payload_not_available\":\"offline\",
      \"device\":{
        \"identifiers\":[\"${uid_base}\"],
        \"name\":\"wM-Bus ${meter_name}\",
        \"model\":\"${meter_driver}\",
        \"manufacturer\":\"wmbusmeters\"
      }
    }" >/dev/null 2>&1 || true

  # 2) voltage_v
  mosquitto_pub "${PUB_ARGS[@]}" ${retain_flag} \
    -t "${DISCOVERY_PREFIX}/sensor/${uid_base}/voltage_v/config" \
    -m "{
      \"name\":\"${meter_name} battery\",
      \"unique_id\":\"${uid_base}_voltage_v\",
      \"state_topic\":\"${STATE_PREFIX}/${meter_id}/state\",
      \"value_template\":\"{{ value_json.voltage_v }}\",
      \"unit_of_measurement\":\"V\",
      \"device_class\":\"voltage\",
      \"json_attributes_topic\":\"${STATE_PREFIX}/${meter_id}/state\",
      \"availability_topic\":\"${STATE_PREFIX}/bridge/status\",
      \"payload_available\":\"online\",
      \"payload_not_available\":\"offline\",
      \"device\":{
        \"identifiers\":[\"${uid_base}\"],
        \"name\":\"wM-Bus ${meter_name}\",
        \"model\":\"${meter_driver}\",
        \"manufacturer\":\"wmbusmeters\"
      }
    }" >/dev/null 2>&1 || true

  # 3) backflow_m3 (jak jest)
  mosquitto_pub "${PUB_ARGS[@]}" ${retain_flag} \
    -t "${DISCOVERY_PREFIX}/sensor/${uid_base}/backflow_m3/config" \
    -m "{
      \"name\":\"${meter_name} backflow\",
      \"unique_id\":\"${uid_base}_backflow_m3\",
      \"state_topic\":\"${STATE_PREFIX}/${meter_id}/state\",
      \"value_template\":\"{{ value_json.backflow_m3 }}\",
      \"unit_of_measurement\":\"m³\",
      \"device_class\":\"water\",
      \"json_attributes_topic\":\"${STATE_PREFIX}/${meter_id}/state\",
      \"availability_topic\":\"${STATE_PREFIX}/bridge/status\",
      \"payload_available\":\"online\",
      \"payload_not_available\":\"offline\",
      \"device\":{
        \"identifiers\":[\"${uid_base}\"],
        \"name\":\"wM-Bus ${meter_name}\",
        \"model\":\"${meter_driver}\",
        \"manufacturer\":\"wmbusmeters\"
      }
    }" >/dev/null 2>&1 || true
}

# Publikujemy status bridge + discovery na starcie (jeśli są metery)
publish_bridge_status

if [[ "${DISCOVERY_ENABLED}" == "true" && "${METERS_COUNT}" != "0" ]]; then
  while IFS= read -r meter_json; do
    mname="$(echo "${meter_json}" | jq -r '.id')"
    mdriver="$(echo "${meter_json}" | jq -r '.type')"
    mid_raw="$(echo "${meter_json}" | jq -r '.meter_id')"
    mid="$(normalize_meter_id "${mid_raw}")"
    [[ -n "${mid}" ]] && publish_discovery_for_meter "${mname}" "${mid}" "${mdriver}"
  done < <(jq -c '.meters[]' "${OPTIONS_JSON}")
  bashio::log.info "MQTT Discovery published (prefix=${DISCOVERY_PREFIX})."
fi

# ============================================================
#  Pipeline: MQTT RAW (HEX) -> wmbusmeters -> MQTT state
# ============================================================
bashio::log.info "Starting wmbusmeters..."

# Filtr: zostaw tylko HEX (bez spacji, bez 0x, bez śmieci)
# + opcjonalny debug co N-ty telegram (do stderr)
mqtt_stream() {
  if [[ "${FILTER_HEX_ONLY}" == "true" ]]; then
    mosquitto_sub "${SUB_ARGS[@]}" -t "${RAW_TOPIC}" -F '%p' \
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
          }'
  else
    mosquitto_sub "${SUB_ARGS[@]}" -t "${RAW_TOPIC}" -F '%p'
  fi
}

# State publisher: każdy JSON telegram idzie do:
#   wmbusmeters/<id>/state  (to jest state_topic dla discovery)
publish_state_from_json() {
  local line="$1"

  # tylko jeśli to JSON
  [[ "${line}" =~ ^\{.*\}$ ]] || return 0

  local mid
  mid="$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
  [[ -z "${mid}" ]] && return 0

  mosquitto_pub "${PUB_ARGS[@]}" -t "${STATE_PREFIX}/${mid}/state" -m "${line}" >/dev/null 2>&1 || true
}

# Listen-mode helper (wyciąga ID z logów wmbusmeters)
SNIPPET_STATE="/data/seen_ids.txt"
touch "${SNIPPET_STATE}"

emit_snippet_if_new() {
  local id="$1"
  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0

  if ! grep -qx "${id}" "${SNIPPET_STATE}"; then
    echo "${id}" >> "${SNIPPET_STATE}"
    bashio::log.warning "=== NEW METER DETECTED ==="
    bashio::log.warning "meter_id: ${id}"
    bashio::log.warning "Add-on options -> meters:"
    bashio::log.warning "  - id: meter_${id}"
    bashio::log.warning "    meter_id: \"${id}\""
    bashio::log.warning "    type: <driver>   # np. hydrodigit"
    bashio::log.warning "    mode: T1"
    bashio::log.warning "========================="
  fi
}

# Start: stream -> wmbusmeters -> obsługa logów/json
mqtt_stream \
  | wmbusmeters --useconfig="${BASE}" 2>&1 \
  | while IFS= read -r line; do
      # pokazujemy w logach addona
      echo "${line}"

      # listen mode: wyciągaj ID z "Received telegram from:"
      if [[ "${METERS_COUNT}" == "0" ]]; then
        if [[ "${line}" =~ Received[[:space:]]telegram[[:space:]]from:[[:space:]]([0-9]{8}) ]]; then
          emit_snippet_if_new "${BASH_REMATCH[1]}"
        fi
      fi

      # normal mode: publikuj JSON do MQTT state topic
      publish_state_from_json "${line}"
    done

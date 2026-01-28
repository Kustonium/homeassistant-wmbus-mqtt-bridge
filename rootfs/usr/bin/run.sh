#!/usr/bin/with-contenv bashio
set -euo pipefail

# ============================================================
# MQTT (z serwisu HA)
# ============================================================
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

MQTT_DISCOVERY="$(bashio::config 'mqtt_discovery')"
[[ -z "${MQTT_DISCOVERY}" || "${MQTT_DISCOVERY}" == "null" ]] && MQTT_DISCOVERY="true"

DISCOVERY_PREFIX="$(bashio::config 'discovery_prefix')"
[[ -z "${DISCOVERY_PREFIX}" || "${DISCOVERY_PREFIX}" == "null" ]] && DISCOVERY_PREFIX="homeassistant"

STATE_PREFIX="$(bashio::config 'state_topic_prefix')"
[[ -z "${STATE_PREFIX}" || "${STATE_PREFIX}" == "null" ]] && STATE_PREFIX="wmbusmeters"

RETAIN_STATE="$(bashio::config 'retain_state')"
[[ -z "${RETAIN_STATE}" || "${RETAIN_STATE}" == "null" ]] && RETAIN_STATE="true"

# ============================================================
# Ścieżki wmbusmeters
# ============================================================
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
bashio::log.info "mqtt_discovery: ${MQTT_DISCOVERY} (prefix: ${DISCOVERY_PREFIX})"
bashio::log.info "state_topic_prefix: ${STATE_PREFIX}"
bashio::log.info "retain_state: ${RETAIN_STATE}"

# ============================================================
# MQTT args
# ============================================================
PUB_ARGS=( -h "${MQTT_HOST}" -p "${MQTT_PORT}" )
[[ -n "${MQTT_USER}" && "${MQTT_USER}" != "null" ]] && PUB_ARGS+=( -u "${MQTT_USER}" )
[[ -n "${MQTT_PASS}" && "${MQTT_PASS}" != "null" ]] && PUB_ARGS+=( -P "${MQTT_PASS}" )

pub() {
  # pub <topic> <payload> [retain true/false]
  local topic="$1"
  local payload="$2"
  local retain="${3:-false}"

  if [[ "${retain}" == "true" ]]; then
    /usr/bin/mosquitto_pub "${PUB_ARGS[@]}" -t "${topic}" -m "${payload}" -r
  else
    /usr/bin/mosquitto_pub "${PUB_ARGS[@]}" -t "${topic}" -m "${payload}"
  fi
}

# ============================================================
# wmbusmeters.conf
# ============================================================
cat > "${CONF_FILE}" <<EOF
loglevel=${LOGLEVEL}
device=stdin:hex
logfile=/dev/stdout
format=json
EOF

bashio::log.info "options.json:"
jq -c '.' "${OPTIONS_JSON}" | while read -r line; do bashio::log.info "${line}"; done

# ============================================================
# Metery: jeśli puste -> LISTEN MODE
# meter_id ma być taki jak w logu: "Received telegram from: XXXXXXXX"
# ============================================================
rm -f "${METER_DIR}/meter-"* 2>/dev/null || true

METERS_COUNT="0"
if jq -e '.meters and (.meters|length>0)' "${OPTIONS_JSON}" >/dev/null 2>&1; then
  METERS_COUNT="$(jq -r '.meters|length' "${OPTIONS_JSON}")"
fi

if [[ "${METERS_COUNT}" == "0" ]]; then
  bashio::log.warning "No meters configured -> LISTEN MODE."
  bashio::log.warning "Zostaw addon chwilę. W logach zobaczysz: 'Received telegram from: XXXXXXXX'."
  bashio::log.warning "To (XXXXXXXX) wpisujesz jako meter_id."
else
  i=0
  while IFS= read -r meter_json; do
    i=$((i+1))
    file="$(printf '%s/meter-%04d' "${METER_DIR}" "${i}")"

    name="$(echo "${meter_json}" | jq -r '.id')"
    driver="$(echo "${meter_json}" | jq -r '.type')"
    mid="$(echo "${meter_json}" | jq -r '.meter_id')"
    key="$(echo "${meter_json}" | jq -r '.key // "NOKEY"')"

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

# ============================================================
# MQTT Discovery (publikujemy raz na sensor)
# ============================================================
PUBLISHED_FILE="${BASE}/published_discovery.txt"
touch "${PUBLISHED_FILE}"

is_published() {
  # is_published <unique_id>
  grep -qx "$1" "${PUBLISHED_FILE}" 2>/dev/null
}

mark_published() {
  echo "$1" >> "${PUBLISHED_FILE}"
}

publish_discovery_sensor() {
  # publish_discovery_sensor <meter_id> <meter_name> <key> <unit> <device_class> <state_class>
  local mid="$1"
  local mname="$2"
  local key="$3"
  local unit="$4"
  local dev_cla="$5"
  local stat_cla="$6"

  local node_id="wmbus_mqtt_bridge"
  local object_id="wmbus_${mid}_${key}"
  local uniq_id="wmbus_${mid}_${key}"

  if is_published "${uniq_id}"; then
    return 0
  fi

  local state_topic="${STATE_PREFIX}/${mid}/state"
  local config_topic="${DISCOVERY_PREFIX}/sensor/${node_id}/${object_id}/config"

  # JSON config do HA MQTT Discovery
  local payload
  payload="$(jq -nc \
    --arg name "${mname} ${key}" \
    --arg uniq_id "${uniq_id}" \
    --arg stat_t "${state_topic}" \
    --arg val_tpl "{{ value_json.${key} }}" \
    --arg unit "${unit}" \
    --arg dev_cla "${dev_cla}" \
    --arg stat_cla "${stat_cla}" \
    --argjson dev "$(jq -nc \
      --arg id "wmbus_${mid}" \
      --arg n "${mname}" \
      --arg via "wmbus_mqtt_bridge" \
      '{identifiers:[$id], name:$n, via_device:$via}')" \
    '{
      name:$name,
      uniq_id:$uniq_id,
      stat_t:$stat_t,
      val_tpl:$val_tpl,
      unit_of_meas: ( $unit | select(length>0) ),
      dev_cla: ( $dev_cla | select(length>0) ),
      stat_cla: ( $stat_cla | select(length>0) ),
      json_attr_t:$stat_t,
      dev:$dev
    }'
  )"

  pub "${config_topic}" "${payload}" "true"
  mark_published "${uniq_id}"

  bashio::log.info "MQTT Discovery published: ${config_topic} (uniq_id=${uniq_id})"
}

# ============================================================
# Start: MQTT -> (filter) -> wmbusmeters -> (state+discovery)
# ============================================================
bashio::log.info "Starting wmbusmeters..."

# Filtr wejścia: tylko HEX (bez spacji, bez 0x, bez śmieci)
FILTER_CMD='cat'
if [[ "${FILTER_HEX_ONLY}" == "true" ]]; then
  FILTER_CMD=$(cat <<'AWK'
awk -v dbg_n="${DEBUG_EVERY_N}" '
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
AWK
)
fi

/usr/bin/mosquitto_sub "${PUB_ARGS[@]}" -t "${RAW_TOPIC}" -F '%p' \
  | eval "${FILTER_CMD}" \
  | /usr/bin/wmbusmeters --useconfig="${BASE}" 2>&1 \
  | while IFS= read -r line; do
      # pokazuj pełny log w addonie
      echo "${line}"

      # JSON telegram (format=json)
      if [[ "${line}" =~ ^\{.*\}$ ]]; then
        mid="$(echo "${line}" | jq -r '.id // empty')"
        mname="$(echo "${line}" | jq -r '.name // .id // "wmbus_meter"')"

        # publish state JSON per meter
        if [[ -n "${mid}" ]]; then
          state_topic="${STATE_PREFIX}/${mid}/state"
          pub "${state_topic}" "${line}" "${RETAIN_STATE}"

          # MQTT Discovery: tylko jeśli włączone
          if [[ "${MQTT_DISCOVERY}" == "true" ]]; then
            # Kluczowe sensory (minimum sensowne, bez śmieci)
            if echo "${line}" | jq -e 'has("total_m3") and (.total_m3|type=="number")' >/dev/null 2>&1; then
              publish_discovery_sensor "${mid}" "${mname}" "total_m3" "m³" "water" "total_increasing"
            fi

            if echo "${line}" | jq -e 'has("voltage_v") and (.voltage_v|type=="number")' >/dev/null 2>&1; then
              publish_discovery_sensor "${mid}" "${mname}" "voltage_v" "V" "voltage" ""
            fi

            if echo "${line}" | jq -e 'has("backflow_m3") and (.backflow_m3|type=="number")' >/dev/null 2>&1; then
              publish_discovery_sensor "${mid}" "${mname}" "backflow_m3" "m³" "water" ""
            fi
          fi
        fi
      fi
    done

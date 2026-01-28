#!/usr/bin/with-contenv bashio
set -euo pipefail

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

cat > "${CONF_FILE}" <<EOF
loglevel=${LOGLEVEL}
device=stdin:hex
logfile=/dev/stdout
format=json
EOF

bashio::log.info "options.json:"
jq -c '.' "${OPTIONS_JSON}" | while read -r line; do bashio::log.info "${line}"; done

normalize_meter_id() {
  local mid_raw="$1"
  mid_raw="$(echo "${mid_raw}" | tr -d '[:space:]')"
  [[ -z "${mid_raw}" || "${mid_raw}" == "null" ]] && { echo ""; return 0; }

  if [[ "${mid_raw}" =~ ^0x[0-9a-fA-F]+$ ]]; then
    local hex="${mid_raw#0x}"
    printf "%d" "$((16#${hex}))"
    return 0
  fi

  echo "${mid_raw}"
}

bashio::log.info "Registering meters ..."
rm -f "${METER_DIR}/meter-"* 2>/dev/null || true

METERS_COUNT="0"
if jq -e '.meters and (.meters|length>0)' "${OPTIONS_JSON}" >/dev/null 2>&1; then
  METERS_COUNT="$(jq -r '.meters|length' "${OPTIONS_JSON}")"
fi

if [[ "${METERS_COUNT}" == "0" ]]; then
  bashio::log.warning "Brak meterów w konfiguracji -> TRYB NASŁUCHU."
  bashio::log.warning "Addon wypisze wykryte meter_id + gotowy snippet YAML do wklejenia."
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
    if [[ -z "${mid}" || "${mid}" == "null" ]]; then
      bashio::log.error "Pusty meter_id dla '${name}' -> pomijam."
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

PUB_ARGS=( -h "${MQTT_HOST}" -p "${MQTT_PORT}" )
[[ -n "${MQTT_USER}" && "${MQTT_USER}" != "null" ]] && PUB_ARGS+=( -u "${MQTT_USER}" )
[[ -n "${MQTT_PASS}" && "${MQTT_PASS}" != "null" ]] && PUB_ARGS+=( -P "${MQTT_PASS}" )

bashio::log.info "Starting wmbusmeters..."

SNIPPET_STATE="/data/seen_ids.txt"
touch "${SNIPPET_STATE}"

emit_snippet_if_new() {
  local id="$1"
  [[ "${id}" =~ ^[0-9]{8}$ ]] || return 0

  if ! grep -qx "${id}" "${SNIPPET_STATE}"; then
    echo "${id}" >> "${SNIPPET_STATE}"

    bashio::log.warning "=== NEW METER CANDIDATE DETECTED ==="
    bashio::log.warning "meter_id: ${id}"
    bashio::log.warning "Paste into add-on options:"
    bashio::log.warning "meters:"
    bashio::log.warning "  - id: meter_${id}"
    bashio::log.warning "    meter_id: \"${id}\""
    bashio::log.warning "    type: <driver>           # np. hydrodigit"
    bashio::log.warning "    mode: T1"
    bashio::log.warning "=================================="
  fi
}

if [[ "${FILTER_HEX_ONLY}" == "true" ]]; then
  /usr/bin/mosquitto_sub "${PUB_ARGS[@]}" -t "${RAW_TOPIC}" -F '%p' \
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
          if [[ "${line}" =~ address[[:space:]]+([0-9]{8}) ]]; then
            emit_snippet_if_new "${BASH_REMATCH[1]}"
          fi
          if [[ "${line}" =~ (^|[^0-9])id[=:][[:space:]]*([0-9]{8})($|[^0-9]) ]]; then
            emit_snippet_if_new "${BASH_REMATCH[2]}"
          fi
        fi
      done
else
  /usr/bin/mosquitto_sub "${PUB_ARGS[@]}" -t "${RAW_TOPIC}" -F '%p' \
    | /usr/bin/wmbusmeters --useconfig="${BASE}" 2>&1 \
    | while IFS= read -r line; do
        echo "${line}"

        if [[ "${METERS_COUNT}" == "0" ]]; then
          if [[ "${line}" =~ address[[:space:]]+([0-9]{8}) ]]; then
            emit_snippet_if_new "${BASH_REMATCH[1]}"
          fi
          if [[ "${line}" =~ (^|[^0-9])id[=:][[:space:]]*([0-9]{8})($|[^0-9]) ]]; then
            emit_snippet_if_new "${BASH_REMATCH[2]}"
          fi
        fi
      done
fi

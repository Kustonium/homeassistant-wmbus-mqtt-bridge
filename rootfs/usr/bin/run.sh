#!/usr/bin/with-contenv bashio
set -euo pipefail

# ============================================================
# 1) MQTT z serwisu HA
# ============================================================
MQTT_HOST="$(bashio::services mqtt "host")"
MQTT_PORT="$(bashio::services mqtt "port")"
MQTT_USER="$(bashio::services mqtt "username")"
MQTT_PASS="$(bashio::services mqtt "password")"

RAW_TOPIC="$(bashio::config 'raw_topic')"

# ============================================================
# 2) Opcje diagnostyczne
# ============================================================
LOGLEVEL="$(bashio::config 'loglevel')"
[[ -z "${LOGLEVEL}" || "${LOGLEVEL}" == "null" ]] && LOGLEVEL="normal"

FILTER_HEX_ONLY="$(bashio::config 'filter_hex_only')"
[[ -z "${FILTER_HEX_ONLY}" || "${FILTER_HEX_ONLY}" == "null" ]] && FILTER_HEX_ONLY="true"

DEBUG_EVERY_N="$(bashio::config 'debug_every_n')"
[[ -z "${DEBUG_EVERY_N}" || "${DEBUG_EVERY_N}" == "null" ]] && DEBUG_EVERY_N="0"

# ============================================================
# 3) Ścieżki w addonie + pliki konfiguracyjne wmbusmeters
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

# Global config wmbusmeters: czytamy HEX ze stdin, log na stdout, format=json
cat > "${CONF_FILE}" <<EOF
loglevel=${LOGLEVEL}
device=stdin:hex
logfile=/dev/stdout
format=json
EOF

# ============================================================
# 4) Pokaż options.json (żeby user widział co HA naprawdę podało)
# ============================================================
bashio::log.info "options.json:"
jq -c '.' "${OPTIONS_JSON}" | while read -r line; do bashio::log.info "${line}"; done

# ============================================================
# 5) Normalizacja meter_id:
#    - akceptujemy "03528221" oraz "0x03528221"
#    - hex konwertujemy na DEC i dopadujemy do 8 cyfr (bo w logach często są z zerem)
# ============================================================
normalize_meter_id() {
  local mid_raw="$1"
  mid_raw="$(echo "${mid_raw}" | tr -d '[:space:]')"
  [[ -z "${mid_raw}" || "${mid_raw}" == "null" ]] && { echo ""; return 0; }

  if [[ "${mid_raw}" =~ ^0x[0-9a-fA-F]+$ ]]; then
    local hex="${mid_raw#0x}"
    local dec
    dec="$(printf "%d" "$((16#${hex}))")"
    # 8 cyfr dla typowych DLL-ID (BMT/Techem itd.)
    if [[ "${#dec}" -le 8 ]]; then
      printf "%08d" "${dec}"
    else
      echo "${dec}"
    fi
    return 0
  fi

  # jak user podał już decimal/string, zostawiamy (np. "03528221")
  echo "${mid_raw}"
}

# ============================================================
# 6) Generowanie plików meter-XXXX
#    - jak meters puste -> tryb NASŁUCHU (wmbusmeters sam wypisze ID)
# ============================================================
bashio::log.info "Registering meters ..."
rm -f "${METER_DIR}/meter-"* 2>/dev/null || true

METERS_COUNT=0
if jq -e '.meters and (.meters|length>0)' "${OPTIONS_JSON}" >/dev/null 2>&1; then
  METERS_COUNT="$(jq -r '.meters|length' "${OPTIONS_JSON}")"
fi

if [[ "${METERS_COUNT}" -eq 0 ]]; then
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
    if [[ -z "${mid}" || "${mid}" == "null" ]]; then
      bashio::log.error "Empty meter_id for '${name}' -> skipping."
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

# ============================================================
# 7) MQTT SUB -> (opcjonalny filtr HEX) -> wmbusmeters
# ============================================================
SUB_ARGS=( -h "${MQTT_HOST}" -p "${MQTT_PORT}" )
[[ -n "${MQTT_USER}" && "${MQTT_USER}" != "null" ]] && SUB_ARGS+=( -u "${MQTT_USER}" )
[[ -n "${MQTT_PASS}" && "${MQTT_PASS}" != "null" ]] && SUB_ARGS+=( -P "${MQTT_PASS}" )

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
    | /usr/bin/wmbusmeters --useconfig="${BASE}"
else
  /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "${RAW_TOPIC}" -F '%p' \
    | /usr/bin/wmbusmeters --useconfig="${BASE}"
fi

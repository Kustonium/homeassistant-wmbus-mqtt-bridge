#!/usr/bin/with-contenv bashio
set -euo pipefail

# --- MQTT z serwisu HA ---
MQTT_HOST="$(bashio::services mqtt "host")"
MQTT_PORT="$(bashio::services mqtt "port")"
MQTT_USER="$(bashio::services mqtt "username")"
MQTT_PASS="$(bashio::services mqtt "password")"

RAW_TOPIC="$(bashio::config 'raw_topic')"

# --- ŚCIEŻKI DLA WMBUSMETERS (ważne!) ---
BASE="/data"
ETC_DIR="${BASE}/etc"
METER_DIR="${ETC_DIR}/wmbusmeters.d"
CONF_FILE="${ETC_DIR}/wmbusmeters.conf"

mkdir -p "${METER_DIR}"

bashio::log.info "MQTT broker: ${MQTT_HOST}:${MQTT_PORT}"
bashio::log.info "Subscribing to: ${RAW_TOPIC}"

# --- wmbusmeters.conf (tylko globalne rzeczy) ---
# NIE dawaj mqtt_host/mqtt_port - w Twojej wersji to jest 'No such key'
cat > "${CONF_FILE}" <<'EOF'
loglevel=normal
device=stdin:hex
logfile=/dev/stdout
format=json
EOF

# --- Pliki liczników: /data/etc/wmbusmeters.d/meter-0001, meter-0002, ...
# Z twoich opcji: id -> name, type -> driver, meter_id -> id
# UWAGA: meter_id najlepiej DAJ JAKO CYFRY (np. 55701281), a nie "0x...."
bashio::log.info "Registering meters ..."
rm -f "${METER_DIR}/meter-"* 2>/dev/null || true

i=0
while IFS= read -r meter_json; do
  i=$((i+1))
  file="$(printf '%s/meter-%04d' "${METER_DIR}" "${i}")"

  name="$(echo "${meter_json}" | jq -r '.id')"
  driver="$(echo "${meter_json}" | jq -r '.type')"
  mid="$(echo "${meter_json}" | jq -r '.meter_id')"

  # key: jak nie masz - daj NOKEY
  cat > "${file}" <<EOF
name=${name}
driver=${driver}
id=${mid}
key=NOKEY
EOF

  bashio::log.info "Added ${file} (name=${name}, driver=${driver}, id=${mid})"
done < <(bashio::config 'meters' | jq -c '.[]')

bashio::log.info "Generated ${CONF_FILE}:"
sed 's/^/[CONF] /' "${CONF_FILE}" | while read -r line; do bashio::log.info "${line#[CONF] }"; done

bashio::log.info "Meters directory: ${METER_DIR}"
ls -la "${METER_DIR}" | while read -r line; do bashio::log.info "${line}"; done

# --- Start wmbusmeters: czyta z stdin ---
# Karmimy go TYLKO payloadem z MQTT (bez topic!)
# Najlepiej użyć mosquitto_sub -F '%p' (payload only)
PUB_ARGS=( -h "${MQTT_HOST}" -p "${MQTT_PORT}" )
[[ -n "${MQTT_USER}" && "${MQTT_USER}" != "null" ]] && PUB_ARGS+=( -u "${MQTT_USER}" )
[[ -n "${MQTT_PASS}" && "${MQTT_PASS}" != "null" ]] && PUB_ARGS+=( -P "${MQTT_PASS}" )

bashio::log.info "Starting wmbusmeters..."
/usr/bin/mosquitto_sub "${PUB_ARGS[@]}" -t "${RAW_TOPIC}" -F '%p' \
  | /usr/bin/wmbusmeters --useconfig="${BASE}"

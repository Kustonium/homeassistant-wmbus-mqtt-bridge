#!/usr/bin/with-contenv bashio
set -euo pipefail

FIFO="/tmp/wmbus.hex"
CONF="/tmp/wmbusmeters.conf"

RAW_TOPIC="$(bashio::config.get raw_topic)"

MQTT_HOST="$(bashio::services mqtt host)"
MQTT_PORT="$(bashio::services mqtt port)"
MQTT_USER="$(bashio::services mqtt username || true)"
MQTT_PASS="$(bashio::services mqtt password || true)"

bashio::log.info "MQTT broker (HA service): ${MQTT_HOST}:${MQTT_PORT}"
bashio::log.info "Subscribing RAW: ${RAW_TOPIC}"
bashio::log.info "Generating wmbusmeters config: ${CONF}"

# --- generate wmbusmeters.conf ---
{
  echo "device=stdin:hex"
  echo "loglevel=normal"
  echo
  # publish decoded values back to MQTT
  echo "mqtt_host=${MQTT_HOST}"
  echo "mqtt_port=${MQTT_PORT}"
  echo "mqtt_topic=wmbusmeters"
  echo
} > "${CONF}"

meters_len="$(bashio::config.get meters | bashio::jq '. | length')"
i=0
while [ "$i" -lt "$meters_len" ]; do
  mid="$(bashio::config.get meters | bashio::jq -r ".[$i].meter_id")"
  mtype="$(bashio::config.get meters | bashio::jq -r ".[$i].type")"
  mmode="$(bashio::config.get meters | bashio::jq -r ".[$i].mode")"
  mid_lc="$(echo "$mid" | tr '[:upper:]' '[:lower:]')"
  mid_clean="${mid_lc#0x}"

  {
    echo "meter=${mtype}"
    echo "id=${mid_clean}"
    echo "mode=${mmode}"
    echo
  } >> "${CONF}"

  i=$((i+1))
done

# --- FIFO + start wmbusmeters ---
rm -f "${FIFO}"
mkfifo "${FIFO}"

bashio::log.info "Starting wmbusmeters (publishing to mqtt_topic=wmbusmeters)..."
/usr/bin/wmbusmeters --useconfig="${CONF}" < "${FIFO}" &
WMBUS_PID=$!

# --- mosquitto_sub args (raw frames in) ---
ARGS="-h ${MQTT_HOST} -p ${MQTT_PORT} -v -t ${RAW_TOPIC}"
if [ -n "${MQTT_USER:-}" ] && [ -n "${MQTT_PASS:-}" ]; then
  ARGS="${ARGS} -u ${MQTT_USER} -P ${MQTT_PASS}"
fi

bashio::log.info "Starting MQTT subscriber for RAW frames..."
mosquitto_sub ${ARGS} | while IFS= read -r line; do
  # "<topic> <payload>"
  hex="${line##* }"
  if echo "$hex" | grep -qiE '^[0-9a-f]+$' && [ "${#hex}" -ge 16 ]; then
    echo "${hex}" > "${FIFO}"
  fi
done &
SUB_PID=$!

trap 'kill ${SUB_PID} ${WMBUS_PID} 2>/dev/null || true' INT TERM
wait -n ${SUB_PID} ${WMBUS_PID}

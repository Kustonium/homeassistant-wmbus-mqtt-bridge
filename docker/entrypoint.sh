#!/bin/sh
set -eu

# Docker standalone entrypoint (DietPi / generic Docker).
# - Creates /config/options.json (if missing)
# - Generates /config/etc/wmbusmeters.conf (every start)
# - Optionally generates meter files from options.json (if provided)
# - Subscribes to raw MQTT telegrams, feeds HEX to wmbusmeters via stdin,
#   publishes decoded JSON state + optional HA discovery to MQTT.

log() { printf '%s %s\n' "[wmbus-bridge]" "$*"; }
warn() { printf '%s %s\n' "[wmbus-bridge][WARN]" "$*" >&2; }
err() { printf '%s %s\n' "[wmbus-bridge][ERR]" "$*" >&2; }

need_bin() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing binary: $1"; exit 1; }
}

need_bin jq
need_bin mosquitto_sub
need_bin mosquitto_pub
need_bin /usr/bin/wmbusmeters

BASE="${WMBUS_BASE:-/config}"
OPTIONS_JSON="${BASE}/options.json"
ETC_DIR="${BASE}/etc"
CONF_FILE="${ETC_DIR}/wmbusmeters.conf"
METER_DIR="${ETC_DIR}/wmbusmeters.d"

mkdir -p "${ETC_DIR}" "${METER_DIR}"

if [ ! -f "${OPTIONS_JSON}" ]; then
  cat > "${OPTIONS_JSON}" <<'EOF'
{
  "raw_topic": "wmbusmeters/raw/#",
  "state_prefix": "wmbusmeters",
  "discovery_prefix": "homeassistant",
  "filter_hex_only": false,
  "debug_every_n": 0,
  "loglevel": "normal",
  "discovery": true,
  "state_retain": true,
  "discovery_retain": true,

  "external_mqtt": true,
  "external_mqtt_host": "mosquitto",
  "external_mqtt_port": 1883,
  "external_mqtt_username": "",
  "external_mqtt_password": "",
  "external_mqtt_ssl": false,

  "meters": []
}
EOF
  log "Created default ${OPTIONS_JSON} (edit it + restart container)."
fi

# Read options with sane defaults
RAW_TOPIC="$(jq -r '.raw_topic // "wmbusmeters/raw/#"' "${OPTIONS_JSON}")"
STATE_PREFIX="$(jq -r '.state_prefix // "wmbusmeters"' "${OPTIONS_JSON}")"
DISCOVERY_PREFIX="$(jq -r '.discovery_prefix // "homeassistant"' "${OPTIONS_JSON}")"
FILTER_HEX_ONLY="$(jq -r '.filter_hex_only // false' "${OPTIONS_JSON}")"
DEBUG_EVERY_N="$(jq -r '.debug_every_n // 0' "${OPTIONS_JSON}")"
LOGLEVEL="$(jq -r '.loglevel // "normal"' "${OPTIONS_JSON}")"
DISCOVERY="$(jq -r '.discovery // true' "${OPTIONS_JSON}")"
STATE_RETAIN="$(jq -r '.state_retain // true' "${OPTIONS_JSON}")"
DISCOVERY_RETAIN="$(jq -r '.discovery_retain // true' "${OPTIONS_JSON}")"

MQTT_HOST="$(jq -r '.external_mqtt_host // "mosquitto"' "${OPTIONS_JSON}")"
MQTT_PORT="$(jq -r '.external_mqtt_port // 1883' "${OPTIONS_JSON}")"
MQTT_USER="$(jq -r '.external_mqtt_username // ""' "${OPTIONS_JSON}")"
MQTT_PASS="$(jq -r '.external_mqtt_password // ""' "${OPTIONS_JSON}")"
MQTT_SSL="$(jq -r '.external_mqtt_ssl // false' "${OPTIONS_JSON}")"

# Build mosquitto args (POSIX-safe)
SUB_ARGS=""
PUB_ARGS=""

if [ "${MQTT_SSL}" = "true" ]; then
  # Minimal SSL: user can mount CA and set EXTRA_SUB_ARGS/EXTRA_PUB_ARGS via env
  SUB_ARGS="${SUB_ARGS} --tls-version tlsv1.2"
  PUB_ARGS="${PUB_ARGS} --tls-version tlsv1.2"
fi

if [ -n "${MQTT_USER}" ]; then
  SUB_ARGS="${SUB_ARGS} -u ${MQTT_USER}"
  PUB_ARGS="${PUB_ARGS} -u ${MQTT_USER}"
fi
if [ -n "${MQTT_PASS}" ]; then
  SUB_ARGS="${SUB_ARGS} -P ${MQTT_PASS}"
  PUB_ARGS="${PUB_ARGS} -P ${MQTT_PASS}"
fi

# Allow advanced flags via env (e.g. --cafile /config/ca.pem)
SUB_ARGS="${SUB_ARGS} ${EXTRA_SUB_ARGS:-}"
PUB_ARGS="${PUB_ARGS} ${EXTRA_PUB_ARGS:-}"

# Generate wmbusmeters.conf (overwrite every start for predictable behavior)
cat > "${CONF_FILE}" <<EOF
loglevel=${LOGLEVEL}
device=stdin:hex
format=json
EOF

# Generate meter files if meters[] provided
METERS_COUNT="$(jq '.meters | length' "${OPTIONS_JSON}" 2>/dev/null || echo 0)"
if [ "${METERS_COUNT}" -gt 0 ] 2>/dev/null; then
  i=0
  while [ "${i}" -lt "${METERS_COUNT}" ]; do
    mid="$(jq -r ".meters[${i}].id // empty" "${OPTIONS_JSON}")"
    mname="$(jq -r ".meters[${i}].name // empty" "${OPTIONS_JSON}")"
    mtype="$(jq -r ".meters[${i}].type // empty" "${OPTIONS_JSON}")"
    mkey="$(jq -r ".meters[${i}].key // empty" "${OPTIONS_JSON}")"
    msuggest="$(jq -r ".meters[${i}].suggested_driver // empty" "${OPTIONS_JSON}")"

    if [ -n "${mid}" ] && [ -n "${mtype}" ]; then
      mf="${METER_DIR}/${mid}.conf"
      rm -f "${mf}"
      {
        echo "name=${mname:-meter_${mid}}"
        echo "type=${mtype}"
        [ -n "${mkey}" ] && echo "key=${mkey}"
        [ -n "${msuggest}" ] && echo "suggest_driver=${msuggest}"
      } > "${mf}"
    fi
    i=$((i+1))
  done
else
  warn "No meters configured -> LISTEN-like mode (will decode only if wmbusmeters can infer)."
fi

# Small helper: sanitize object_id
sanitize_obj_id() {
  # lower + replace non-alnum with _
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9_]/_/g' -e 's/__*/_/g' -e 's/^_//' -e 's/_$//'
}

publish() {
  # publish <topic> <payload> <retain:true|false>
  t="$1"
  p="$2"
  r="$3"
  if [ "${r}" = "true" ]; then
    # shellcheck disable=SC2086
    mosquitto_pub -h "${MQTT_HOST}" -p "${MQTT_PORT}" ${PUB_ARGS} -t "${t}" -r -m "${p}"
  else
    # shellcheck disable=SC2086
    mosquitto_pub -h "${MQTT_HOST}" -p "${MQTT_PORT}" ${PUB_ARGS} -t "${t}" -m "${p}"
  fi
}

emit_discovery_from_telegram() {
  # minimal HA discovery: publish one sensor per numeric field in the telegram JSON
  tel="$1"

  mid="$(echo "${tel}" | jq -r '.id // empty' 2>/dev/null || true)"
  mname="$(echo "${tel}" | jq -r '.name // .meter // "wmbus"' 2>/dev/null || true)"
  [ -n "${mid}" ] || return 0

  dev_name="${mname} (${mid})"
  dev_uid="wmbus_${mid}"
  base_obj="$(sanitize_obj_id "${mname}_${mid}")"

  # iterate numeric leafs (flat) and publish sensors
  # This intentionally keeps it simple; advanced mapping can be added later.
  keys="$(echo "${tel}" | jq -r 'to_entries[] | select(.value|type=="number") | .key' 2>/dev/null || true)"
  for k in ${keys}; do
    obj="$(sanitize_obj_id "${base_obj}_${k}")"
    cfg_topic="${DISCOVERY_PREFIX}/sensor/${dev_uid}/${obj}/config"

    # crude unit guesses
    unit=""
    device_class=""
    case "${k}" in
      *temperature*|*temp*) unit="°C"; device_class="temperature" ;;
      *humidity*|*hum*) unit="%"; device_class="humidity" ;;
      *power*|*watt*|*w) unit="W"; device_class="power" ;;
      *energy*|*kwh*) unit="kWh"; device_class="energy" ;;
      *volume*|*m3*) unit="m³"; device_class="water" ;;
      *voltage*|*volt*) unit="V"; device_class="voltage" ;;
      *current*|*amp*) unit="A"; device_class="current" ;;
      *) unit="" ;;
    esac

    cfg="$(jq -n       --arg name "${dev_name} ${k}"       --arg st "${STATE_PREFIX}/${mid}/state"       --argjson retain "$( [ "${STATE_RETAIN}" = "true" ] && echo true || echo false )"       --arg val_tmpl "{{ value_json.${k} }}"       --arg uniq "${dev_uid}_${obj}"       --arg dev_name "${dev_name}"       --arg dev_uid "${dev_uid}"       --arg unit "${unit}"       --arg dclass "${device_class}"       '{
        "name": $name,
        "state_topic": $st,
        "value_template": $val_tmpl,
        "unique_id": $uniq,
        "device": { "name": $dev_name, "identifiers": [$dev_uid] },
        "availability_topic": ($st + "/availability")
      }
      + ( ($unit|length)>0 ? {"unit_of_measurement":$unit} : {} )
      + ( ($dclass|length)>0 ? {"device_class":$dclass} : {} )
      ' 2>/dev/null || true)"

    [ -n "${cfg}" ] && publish "${cfg_topic}" "${cfg}" "${DISCOVERY_RETAIN}"
  done
}

# Wait for MQTT broker (best-effort)
tries=0
until mosquitto_pub -h "${MQTT_HOST}" -p "${MQTT_PORT}" ${PUB_ARGS} -t "${STATE_PREFIX}/_boot" -n >/dev/null 2>&1; do
  tries=$((tries+1))
  if [ "${tries}" -ge 30 ]; then
    err "MQTT broker not reachable at ${MQTT_HOST}:${MQTT_PORT}"
    exit 10
  fi
  sleep 1
done

log "MQTT: ${MQTT_HOST}:${MQTT_PORT} topic=${RAW_TOPIC}"
log "wmbusmeters: --useconfig=${BASE} (conf=${CONF_FILE})"

# Start pipeline
# shellcheck disable=SC2086
mosquitto_sub -h "${MQTT_HOST}" -p "${MQTT_PORT}" ${SUB_ARGS} -t "${RAW_TOPIC}" -F '%p' | (
  if [ "${FILTER_HEX_ONLY}" = "true" ]; then
    awk '{
      gsub(/\r/,"");
      # try to extract a long-ish hex blob from the payload
      if (match($0, /[0-9A-Fa-f]{20,}/)) {
        print substr($0, RSTART, RLENGTH);
      }
    }'
  else
    cat
  fi
) | /usr/bin/wmbusmeters --useconfig="${BASE}" 2>&1 | while IFS= read -r line; do
  # pass through logs to container logs
  echo "${line}"

  # decode telegram json
  ttype="$(echo "${line}" | jq -r '._ // empty' 2>/dev/null || true)"
  [ "${ttype}" = "telegram" ] || continue

  mid="$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)"
  [ -n "${mid}" ] || continue

  publish "${STATE_PREFIX}/${mid}/state" "${line}" "${STATE_RETAIN}"
  publish "${STATE_PREFIX}/${mid}/state/availability" "online" "${STATE_RETAIN}"

  if [ "${DISCOVERY}" = "true" ]; then
    emit_discovery_from_telegram "${line}"
  fi
done

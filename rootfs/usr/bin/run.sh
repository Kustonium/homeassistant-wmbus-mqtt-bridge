#!/usr/bin/with-contenv bashio
set -euo pipefail

# ============================================================
# HA add-on wrapper
# - Resolves MQTT broker (HA internal vs external)
# - Exports MQTT_* env vars
# - Runs core bridge (/usr/bin/bridge.sh)
# ============================================================

WMBUS_BASE="/data"
export WMBUS_BASE

MQTT_MODE="$(bashio::config 'mqtt_mode')"
[[ -z "${MQTT_MODE}" || "${MQTT_MODE}" == "null" ]] && MQTT_MODE="auto"

EXT_MQTT_HOST="$(bashio::config 'external_mqtt_host')"
EXT_MQTT_PORT="$(bashio::config 'external_mqtt_port')"
EXT_MQTT_USER="$(bashio::config 'external_mqtt_username')"
EXT_MQTT_PASS="$(bashio::config 'external_mqtt_password')"
[[ -z "${EXT_MQTT_PORT}" || "${EXT_MQTT_PORT}" == "null" ]] && EXT_MQTT_PORT="1883"

use_ha_mqtt() {
  bashio::services.available "mqtt" >/dev/null 2>&1
}

if [[ "${MQTT_MODE}" == "ha" ]]; then
  if ! use_ha_mqtt; then
    bashio::log.fatal "mqtt_mode=ha, ale w Home Assistant nie wykryto usługi MQTT. Zainstaluj/uruchom Mosquitto Broker add-on albo przełącz na mqtt_mode=external."
    exit 1
  fi
  MQTT_HOST="$(bashio::services mqtt "host")"
  MQTT_PORT="$(bashio::services mqtt "port")"
  MQTT_USER="$(bashio::services mqtt "username")"
  MQTT_PASS="$(bashio::services mqtt "password")"
elif [[ "${MQTT_MODE}" == "external" ]]; then
  if [[ -z "${EXT_MQTT_HOST}" || "${EXT_MQTT_HOST}" == "null" ]]; then
    bashio::log.fatal "mqtt_mode=external wymaga external_mqtt_host."
    exit 1
  fi
  MQTT_HOST="${EXT_MQTT_HOST}"
  MQTT_PORT="${EXT_MQTT_PORT}"
  MQTT_USER="${EXT_MQTT_USER}"
  MQTT_PASS="${EXT_MQTT_PASS}"
else
  # auto
  if use_ha_mqtt; then
    MQTT_HOST="$(bashio::services mqtt "host")"
    MQTT_PORT="$(bashio::services mqtt "port")"
    MQTT_USER="$(bashio::services mqtt "username")"
    MQTT_PASS="$(bashio::services mqtt "password")"
  else
    if [[ -z "${EXT_MQTT_HOST}" || "${EXT_MQTT_HOST}" == "null" ]]; then
      bashio::log.fatal "Nie wykryto usługi MQTT w HA (Mosquitto) i external_mqtt_host jest puste. Ustaw mqtt_mode=external oraz podaj external_mqtt_host, albo zainstaluj Mosquitto Broker add-on."
      exit 1
    fi
    MQTT_HOST="${EXT_MQTT_HOST}"
    MQTT_PORT="${EXT_MQTT_PORT}"
    MQTT_USER="${EXT_MQTT_USER}"
    MQTT_PASS="${EXT_MQTT_PASS}"
  fi
fi

export MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASS

bashio::log.info "Starting core bridge..."
exec /usr/bin/bridge.sh

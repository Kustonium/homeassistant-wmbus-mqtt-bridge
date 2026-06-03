#!/usr/bin/env bash
# MQTT publish and pipeline startup helpers.

mqtt_pub() {
  local topic="$1"
  local payload="$2"
  local retain="${3:-false}"

  local retain_flag=()
  [[ "${retain}" == "true" ]] && retain_flag=( -r )

  /usr/bin/mosquitto_pub "${PUB_ARGS[@]}" -t "${topic}" "${retain_flag[@]}" -m "${payload}" || true
}

wait_for_mqtt() {
  log "Waiting for MQTT broker ${MQTT_HOST}:${MQTT_PORT}..."
  for ((i=1; i<=MQTT_WAIT_RETRIES; i++)); do
    if /usr/bin/mosquitto_pub "${PUB_ARGS[@]}" -t "wmbus_bridge/status" -m "starting" --quiet 2>/dev/null; then
      log "MQTT broker ready (attempt ${i}/${MQTT_WAIT_RETRIES})"
      STATUS_MQTT_CONNECTED="true"
      STATUS_LAST_ERROR=""
      status_add_event "ok" "MQTT broker ready"
      write_status_json
      return 0
    fi
    warn "MQTT not ready (attempt ${i}/${MQTT_WAIT_RETRIES}), retrying in ${MQTT_WAIT_DELAY}s..."
    sleep "${MQTT_WAIT_DELAY}"
  done
  # Broker niedostępny po wszystkich próbach - ostrzegamy ale nie przerywamy,
  # pętla restart_on_exit zajmie się ponownym uruchomieniem pipeline.
  warn "MQTT broker not available after ${MQTT_WAIT_RETRIES} attempts, continuing anyway..."
  # shellcheck disable=SC2034
  STATUS_MQTT_CONNECTED="false"
  # shellcheck disable=SC2034
  STATUS_LAST_ERROR="MQTT broker not available"
  status_add_event "error" "MQTT broker not available"
  write_status_json
  return 1
}

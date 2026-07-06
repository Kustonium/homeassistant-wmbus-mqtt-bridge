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

# Machine-readable startup-failure marker for the WebUI. When run.sh FATALs,
# bridge.sh never starts, so until now the add-on log was the only witness —
# the WebUI showed dashes and a generic "stale" banner. The WebUI renders this
# file as a specific, actionable banner. Format: code<TAB>detail. Cleared on
# every successful broker resolution so a fixed config removes the banner.
RUN_ERROR_FILE="${WMBUS_BASE}/status_run_error.txt"

run_error() {
  printf '%s\t%s\n' "$1" "${2:-}" > "${RUN_ERROR_FILE}.tmp" 2>/dev/null \
    && mv "${RUN_ERROR_FILE}.tmp" "${RUN_ERROR_FILE}" 2>/dev/null \
    || true
}

run_error_clear() {
  rm -f "${RUN_ERROR_FILE}" "${RUN_ERROR_FILE}.tmp" 2>/dev/null || true
}

MQTT_MODE="$(bashio::config 'mqtt_mode')"
[[ -z "${MQTT_MODE}" || "${MQTT_MODE}" == "null" ]] && MQTT_MODE="auto"

EXT_MQTT_HOST="$(bashio::config 'external_mqtt_host')"
EXT_MQTT_PORT="$(bashio::config 'external_mqtt_port')"
EXT_MQTT_USER="$(bashio::config 'external_mqtt_username')"
EXT_MQTT_PASS="$(bashio::config 'external_mqtt_password')"
[[ -z "${EXT_MQTT_PORT}" || "${EXT_MQTT_PORT}" == "null" ]] && EXT_MQTT_PORT="1883"
# bashio returns the literal string "null" for unset optional options;
# bridge.sh already treats "null" credentials as empty, normalise here too so
# the probe below and the candidate scan see real emptiness.
[[ "${EXT_MQTT_USER}" == "null" ]] && EXT_MQTT_USER=""
[[ "${EXT_MQTT_PASS}" == "null" ]] && EXT_MQTT_PASS=""

use_ha_mqtt() {
  bashio::services.available "mqtt" >/dev/null 2>&1
}

# Probe a broker with one short, bounded CONNECT+SUBSCRIBE (mosquitto_sub -E
# exits right after SUBACK). Return codes:
#   0 — connected and authorised (broker usable with these credentials)
#   2 — broker is up but rejected the credentials (CONNACK not authorised)
#   1 — no broker there / unreachable / timeout
# The 0-vs-2 distinction is what makes auto mode actual detection: a broker
# that answers "not authorised" EXISTS, and the log can say precisely what is
# missing instead of a generic FATAL.
probe_mqtt() {
  local host="$1" port="$2" user="${3:-}" pass="${4:-}" out
  local args=( -h "${host}" -p "${port}" -t 'homeassistant/status' -E )
  [[ -n "${user}" ]] && args+=( -u "${user}" )
  [[ -n "${pass}" ]] && args+=( -P "${pass}" )
  if out="$(timeout 6 mosquitto_sub "${args[@]}" 2>&1)"; then
    return 0
  fi
  if grep -qiE 'not authori[sz]ed|bad user ?name or password' <<<"${out}"; then
    return 2
  fi
  return 1
}

# Non-fatal startup diagnostic for an explicitly configured broker. Behaviour
# is unchanged either way (bridge.sh keeps retrying a dead broker), but the
# add-on log states immediately whether the address or the credentials are
# the problem instead of leaving a silent wait.
diagnose_configured_broker() {
  local host="$1" port="$2" user="$3" pass="$4" rc=0
  probe_mqtt "${host}" "${port}" "${user}" "${pass}" || rc=$?
  case "${rc}" in
    0) bashio::log.info    "MQTT broker ${host}:${port} verified (connect + subscribe OK)." ;;
    2) bashio::log.warning "MQTT broker ${host}:${port} is up but REJECTED the credentials — check external_mqtt_username/external_mqtt_password." ;;
    *) bashio::log.warning "MQTT broker ${host}:${port} did not respond to a probe — check the address/port; the bridge will keep retrying." ;;
  esac
}

# Probe the well-known broker add-on hostnames (Supervisor DNS resolves
# add-on hostnames). On success sets MQTT_HOST/PORT/USER/PASS and returns 0.
# A broker that answers but rejects the credentials is remembered in
# DETECTED_NEEDS_AUTH so the caller can FATAL with the exact missing fields.
scan_broker_addons() {
  local cand rc
  DETECTED_NEEDS_AUTH=""
  for cand in core-mosquitto a0d7b954-emqx; do
    rc=0
    probe_mqtt "${cand}" 1883 "${EXT_MQTT_USER}" "${EXT_MQTT_PASS}" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
      bashio::log.info "mqtt_mode=auto: detected MQTT broker add-on at ${cand}:1883 — using it."
      MQTT_HOST="${cand}"
      MQTT_PORT="1883"
      MQTT_USER="${EXT_MQTT_USER}"
      MQTT_PASS="${EXT_MQTT_PASS}"
      return 0
    elif [[ "${rc}" -eq 2 ]]; then
      DETECTED_NEEDS_AUTH="${cand}"
    fi
  done
  return 1
}

# Wait (bounded) for HA's MQTT service to become available. A stopped or
# restarting Mosquitto add-on makes bashio::services report it as unavailable;
# this lets the wrapper ride out a transient restart instead of FATAL-ing and
# letting s6 thrash-restart it. Returns 0 once available, 1 after the timeout.
wait_for_ha_mqtt() {
  # ~60 s total; the 5 s cadence keeps bashio's "Service not enabled" API log to
  # about a dozen lines instead of one every 2 s while the broker is down.
  local retries="${MQTT_SERVICE_WAIT_RETRIES:-12}" delay="${MQTT_SERVICE_WAIT_DELAY:-5}" i
  use_ha_mqtt && return 0
  bashio::log.warning "HA MQTT service not available yet — waiting up to $(( retries * delay ))s (is the Mosquitto add-on starting or restarting?)."
  for (( i=1; i<=retries; i++ )); do
    sleep "${delay}"
    if use_ha_mqtt; then
      bashio::log.info "HA MQTT service available after ~$(( i * delay ))s."
      return 0
    fi
  done
  return 1
}

if [[ "${MQTT_MODE}" == "ha" ]]; then
  if ! wait_for_ha_mqtt; then
    run_error "no_ha_service" ""
    bashio::log.fatal "mqtt_mode=ha, ale w Home Assistant nie wykryto usługi MQTT. Zainstaluj/uruchom Mosquitto Broker add-on albo przełącz na mqtt_mode=external."
    exit 1
  fi
  MQTT_HOST="$(bashio::services mqtt "host")"
  MQTT_PORT="$(bashio::services mqtt "port")"
  MQTT_USER="$(bashio::services mqtt "username")"
  MQTT_PASS="$(bashio::services mqtt "password")"
elif [[ "${MQTT_MODE}" == "external" ]]; then
  if [[ -z "${EXT_MQTT_HOST}" || "${EXT_MQTT_HOST}" == "null" ]]; then
    run_error "external_host_missing" ""
    bashio::log.fatal "mqtt_mode=external wymaga external_mqtt_host."
    exit 1
  fi
  MQTT_HOST="${EXT_MQTT_HOST}"
  MQTT_PORT="${EXT_MQTT_PORT}"
  MQTT_USER="${EXT_MQTT_USER}"
  MQTT_PASS="${EXT_MQTT_PASS}"
  diagnose_configured_broker "${MQTT_HOST}" "${MQTT_PORT}" "${MQTT_USER}" "${MQTT_PASS}"
else
  # auto: honour an explicitly configured external_mqtt_host first. If the user
  # bothered to type a broker address, they almost certainly want to use that
  # broker — even when HA's Mosquitto is also available (e.g. EMQX configured
  # before installation, observed in the wild). With no external host set, fall
  # back to HA's MQTT service and ride out a transient restart with
  # wait_for_ha_mqtt instead of FATAL-looping.
  if [[ -n "${EXT_MQTT_HOST}" && "${EXT_MQTT_HOST}" != "null" ]]; then
    bashio::log.info "mqtt_mode=auto: external_mqtt_host is set ('${EXT_MQTT_HOST}') — using it instead of the HA broker."
    MQTT_HOST="${EXT_MQTT_HOST}"
    MQTT_PORT="${EXT_MQTT_PORT}"
    MQTT_USER="${EXT_MQTT_USER}"
    MQTT_PASS="${EXT_MQTT_PASS}"
    diagnose_configured_broker "${MQTT_HOST}" "${MQTT_PORT}" "${MQTT_USER}" "${MQTT_PASS}"
  else
    # Resolution order tuned for startup time (measured on the reference EMQX
    # box: the old wait-first order burned 65 s per start, 60 s of it waiting
    # for a Supervisor mqtt service that EMQX never registers):
    #   1. instant Supervisor-service check (Mosquitto up -> zero delay),
    #   2. quick scan of well-known broker add-on hostnames (seconds),
    #   3. only when BOTH found nothing: the full bounded wait_for_ha_mqtt
    #      (still needed — it rides out a restarting Mosquitto), then one
    #      re-scan of the candidates.
    # The scan exists because the Supervisor services API only lists brokers
    # that REGISTER the mqtt service (in practice: the official Mosquitto
    # add-on); community EMQX (a0d7b954_emqx) runs on this very host but is
    # invisible to bashio::services, which previously forced its users into
    # mqtt_mode=external with a hand-typed IP. Credentials:
    # external_mqtt_username/password are used when set — so an
    # auth-protected EMQX works in auto with just user+pass typed in, no
    # host/IP — otherwise the probe is anonymous.
    if use_ha_mqtt; then
      MQTT_HOST="$(bashio::services mqtt "host")"
      MQTT_PORT="$(bashio::services mqtt "port")"
      MQTT_USER="$(bashio::services mqtt "username")"
      MQTT_PASS="$(bashio::services mqtt "password")"
    else
      scan_broker_addons || true
      if [[ -z "${MQTT_HOST:-}" && -z "${DETECTED_NEEDS_AUTH}" ]]; then
        # Nothing answered at all — maybe Mosquitto is just restarting. Give
        # the Supervisor service the full bounded wait, then re-scan once.
        wait_for_ha_mqtt || true
        if use_ha_mqtt; then
          MQTT_HOST="$(bashio::services mqtt "host")"
          MQTT_PORT="$(bashio::services mqtt "port")"
          MQTT_USER="$(bashio::services mqtt "username")"
          MQTT_PASS="$(bashio::services mqtt "password")"
        else
          scan_broker_addons || true
        fi
      fi
      if [[ -z "${MQTT_HOST:-}" ]]; then
        if [[ -n "${DETECTED_NEEDS_AUTH}" ]]; then
          run_error "auth_required" "${DETECTED_NEEDS_AUTH}:1883"
          bashio::log.fatal "Wykryto działający broker MQTT pod ${DETECTED_NEEDS_AUTH}:1883, ale odrzuca logowanie. Wpisz external_mqtt_username/external_mqtt_password (tryb auto ich użyje), albo ustaw mqtt_mode=external z external_mqtt_host=${DETECTED_NEEDS_AUTH} i danymi logowania."
        else
          run_error "no_broker" ""
          bashio::log.fatal "Nie wykryto usługi MQTT w HA (Mosquitto), żadnego znanego brokera-add-onu (core-mosquitto, a0d7b954-emqx), a external_mqtt_host jest puste. Ustaw mqtt_mode=external oraz podaj external_mqtt_host, albo zainstaluj Mosquitto Broker add-on."
        fi
        # Pace the s6 restart loop: the auth-required FATAL can now fire
        # within seconds of start (no 60 s service wait on that path), and an
        # immediate s6 restart would thrash the same FATAL into the log every
        # few seconds. The old cadence (~65 s) came implicitly from the wait.
        sleep 30
        exit 1
      fi
    fi
  fi
fi

# Broker resolved — clear any startup-failure marker from a previous attempt
# so the WebUI banner disappears once the config is fixed.
run_error_clear

export MQTT_HOST MQTT_PORT MQTT_USER MQTT_PASS

bashio::log.info "Starting core bridge..."
exec /usr/bin/bridge.sh

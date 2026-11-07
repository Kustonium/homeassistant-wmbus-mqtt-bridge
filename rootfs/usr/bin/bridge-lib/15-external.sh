# shellcheck shell=bash
# ------------------------------------------------------------
# External instance: the meters on an external_* driver (custom .xmq files)
# ------------------------------------------------------------
# A wmbusmeters of its own, root ${EXT_BASE}: only the drivers custom_drivers.py
# accepted (etc/wmbusmeters.drivers.d) and only the meters on them
# (etc/wmbusmeters.d, written by refresh_meter_files). The main instance never
# loads an external driver: a file sharing an mvt with a built-in driver
# removes that built-in driver from the process that loads it, and a failing
# one ends the process (wmbusmeters 3.1.1, measured 2026-11-07).
#
# Its own raw subscription, like LISTEN. Its decoded telegrams go through a
# FIFO into the main pipeline (external_instance.py forward -> merge), so the
# one decode stage publishes them and writes the status files.
#
# Started only with custom_drivers_enabled and at least one external meter.
# A crash restarts it with the usual backoff; EXTERNAL_CRASH_LIMIT quick exits
# in a row stop it until the next pipeline reload, state in
# status_external_instance.json for the WebUI.
EXTERNAL_PID=""
EXTERNAL_TOOL="${EXTERNAL_TOOL:-${BRIDGE_SCRIPT_DIR:-${BASH_SOURCE[0]%/*}/..}/external_instance.py}"
EXTERNAL_CRASH_LIMIT="${EXTERNAL_CRASH_LIMIT:-5}"
EXTERNAL_QUICK_EXIT_S="${EXTERNAL_QUICK_EXIT_S:-60}"

external_merge_enabled() {
  [[ "${CUSTOM_DRIVERS_ENABLED:-false}" == "true" ]]
}

# The main decoding wmbusmeters, for run_once. With custom drivers off it is
# exactly the process it always was (exec); on, the external instance's lines
# are merged into its output.
_main_wmbusmeters_stage() {
  if external_merge_enabled; then
    # shellcheck disable=SC2086  # STDBUF_BIN is a command with its options
    ${STDBUF_BIN} /usr/bin/wmbusmeters --useconfig="${BASE}" 2>&1 \
      | python3 -u "${EXTERNAL_TOOL}" merge --fifo="${EXTERNAL_FIFO}"
  else
    # shellcheck disable=SC2086
    exec ${STDBUF_BIN} /usr/bin/wmbusmeters --useconfig="${BASE}" 2>&1
  fi
}

external_write_status() {
  local state="$1" extra="${2:-}"
  local tmp="${STATUS_EXTERNAL_INSTANCE_FILE}.tmp"
  printf '{"state":"%s","meters":%s,"updated_at":%s%s}\n' "${state}" "${EXTERNAL_METERS_COUNT:-0}" \
    "$(epoch_now)" "${extra}" > "${tmp}" 2>/dev/null \
    && mv "${tmp}" "${STATUS_EXTERNAL_INSTANCE_FILE}" 2>/dev/null || true
}

_external_write_conf() {
  mkdir -p "${EXT_BASE}/etc" 2>/dev/null || true
  {
    printf 'loglevel=%s\ndevice=stdin:hex\nlogfile=/dev/stdout\nformat=json\n' "${LOGLEVEL}"
    # The same as the main instance: the WebUI log shows the frame, and
    # _wmbusmeters_log_stage removes it before anything else sees the line.
    if [[ -n "${WEBUI_LOG_DIR:-}" ]]; then
      echo "addtelegramhex=true"
    fi
  } > "${EXT_BASE}/etc/wmbusmeters.conf"
}

start_external_instance() {
  if ! external_merge_enabled; then
    external_write_status "disabled"
    return 0
  fi
  if (( ${EXTERNAL_METERS_COUNT:-0} == 0 )); then
    external_write_status "no_meters"
    return 0
  fi
  _external_write_conf
  (
    local quick=0 t0 rc
    while true; do
      t0="$(epoch_now)"
      _raw_source \
        | awk '
            function ishex(s) { return (s ~ /^[0-9A-Fa-f]+$/) }
            {
              gsub(/[[:space:]]/, "", $0);
              sub(/^0x/i, "", $0);
              if (!ishex($0)) next;
              if ((length($0) % 2) != 0) next;
              print $0;
              fflush();
            }
          ' \
        | { # shellcheck disable=SC2086  # STDBUF_BIN is a command with its options
            ${STDBUF_BIN} /usr/bin/wmbusmeters --useconfig="${EXT_BASE}" 2>&1; echo "__EXTERNAL_RC__ $?"; } \
        | python3 -u "${EXTERNAL_TOOL}" forward --fifo="${EXTERNAL_FIFO}" \
            --status="${STATUS_EXTERNAL_INSTANCE_FILE}" &
      wait "$!" 2>/dev/null
      rc=$?
      if (( $(epoch_now) - t0 < EXTERNAL_QUICK_EXIT_S )); then
        quick=$((quick + 1))
      else
        quick=0
      fi
      if (( quick >= EXTERNAL_CRASH_LIMIT )); then
        warn "external instance: ${quick} quick exits in a row (last rc=${rc}) -> stopped until the next reload; the main instance is not affected"
        external_write_status "crash_loop" ",\"last_rc\":${rc},\"quick_exits\":${quick}"
        status_add_event "warn" "External drivers instance stopped after repeated crashes" 2>/dev/null || true
        exit 0
      fi
      log_verbose "[DIAG] external instance exited (rc=${rc}), restarting"
      _sub_reconnect_sleep "${t0}" 1
    done
  ) &
  EXTERNAL_PID=$!
  log "External drivers instance started (pid=${EXTERNAL_PID}, meters=${EXTERNAL_METERS_COUNT})"
}

stop_external_instance() {
  [[ -z "${EXTERNAL_PID}" ]] && return 0
  pkill -TERM -P "${EXTERNAL_PID}" 2>/dev/null || true
  kill -TERM "${EXTERNAL_PID}" 2>/dev/null || true
  wait "${EXTERNAL_PID}" 2>/dev/null || true
  pkill -KILL -P "${EXTERNAL_PID}" 2>/dev/null || true
  EXTERNAL_PID=""
}

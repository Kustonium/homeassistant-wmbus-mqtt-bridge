#!/usr/bin/env bash
# ============================================================
# Wired M-Bus: third wmbusmeters instance, polling a serial bus
# ============================================================
# The radio path feeds wmbusmeters through stdin:hex. This one is different:
# it opens a serial port and polls meters, so it drives itself and has its own
# lifecycle. It reuses the whole entity layer unchanged — decoded JSON goes to
# emit_discovery_from_json() exactly like a radio telegram, because that
# consumer never asks where the line came from.
#
# Facts below were measured against a real bus simulator, not assumed:
#   - the meter id in the JSON comes from the frame, not from the polling
#     address: polling p1 yields id=10000284 (meters.cc builds it from
#     addresses.back()), so it passes the ^[0-9A-Fa-f]{8}$ gate and entities
#     are created the normal way;
#   - pollinterval is NOT a wmbusmeters.conf key. The global config parser does
#     not know it and answers "No such key: pollinterval" without failing, and
#     --pollinterval cannot be combined with --useconfig. It has to be written
#     into every meter file or nothing is ever polled — and a meter that is
#     never polled looks exactly like a dead one;
#   - losing the port is handled by the decoder itself: it logs
#     SpecifiedDeviceNotFound and waits for the device to come back. The
#     supervisor here must therefore NOT restart on a missing port, only on the
#     process actually exiting.

MBUS_BASE=""
MBUS_ETC=""
MBUS_METER_DIR=""
MBUS_CONF_FILE=""
MBUS_LOG=""
MBUS_PID=""
MBUS_BUS_ALIAS="MAIN"
MBUS_POLL_DEFAULT="15m"
MBUS_STATUS_FILE=""
MBUS_METERS_OK=0
MBUS_METERS_SKIPPED=0
# The console log is what the read-only bus console in the WebUI reads. It is
# appended to for the life of the instance, so it needs a ceiling: with
# logtelegrams on and a short pollinterval it is the only file here that grows
# without bound.
MBUS_LOG_MAX_LINES=2000
MBUS_LINES_SINCE_TRIM=0

# Last id seen per configured meter name. A bus address that starts answering
# with a different id means two meters share one primary address — the decoder
# reports neither problem nor duplicate, it simply emits both telegrams, so the
# detection has to live here.
declare -A MBUS_LAST_ID=()
declare -A MBUS_LAST_OK=()
declare -A MBUS_CLASH=()

MBUS_TRAFFIC_STATE="unknown"

mbus_init_paths() {
  MBUS_BASE="${BASE}/mbus"
  MBUS_ETC="${MBUS_BASE}/etc"
  MBUS_METER_DIR="${MBUS_ETC}/wmbusmeters.d"
  MBUS_CONF_FILE="${MBUS_ETC}/wmbusmeters.conf"
  MBUS_LOG="${MBUS_BASE}/console.log"
  MBUS_STATUS_FILE="${BASE}/status_mbus.json"
}

# ------------------------------------------------------------
# Runtime state file
# ------------------------------------------------------------
# Everything below used to be computed and thrown away: the traffic state lives
# in the pipeline subshell that reads the decoder's output, so the parent shell
# - and therefore any function the WebUI could call - never sees it. A file is
# the only channel that crosses that boundary.
#
# It matters because the failure modes here share one symptom ("nothing
# arrives") and the decoder names the cause only in its log. Without this the
# user with a DLMS/COSEM electricity meter on the wire sees an open port, live
# bytes and no entities, with nothing anywhere saying why.
#
# States:
#   disabled            engine off
#   not_configured      armed with no port picked (reachable only through the
#                       Supervisor options editor - the WebUI refuses it)
#   device_missing      the configured path is gone
#   identity_changed    the /dev node now points at different hardware
#   no_meters           armed, port fine, nothing to poll
#   starting            running, no telegram yet
#   ok                  a telegram was accepted
#   no_reply            polled address stays silent
#   damaged_frames      checksum errors - damaged frame or an address clash
#   not_mbus_traffic    bytes flow, none of them shaped like an M-Bus frame
#   bus_down            the bus/device is not up for the decoder
mbus_write_status() {
  local state="$1"
  [[ -n "${MBUS_STATUS_FILE}" ]] || return 0
  local meters_json="{}" name
  # Guarded on the element count rather than on ${!array[@]+...}: under set -u
  # that form does not expand the keys of an associative array (measured - it
  # yields nothing while the array holds entries), so the loop silently never
  # ran and every meter vanished from the status file. Meter names come from
  # user configuration and may contain spaces, so the keys stay quoted.
  if (( ${#MBUS_LAST_ID[@]} > 0 )); then
    for name in "${!MBUS_LAST_ID[@]}"; do
      meters_json="$(printf '%s' "${meters_json}" | jq -c \
        --arg n "${name}" \
        --arg id "${MBUS_LAST_ID[${name}]:-}" \
        --arg clash "${MBUS_CLASH[${name}]:-}" \
        --argjson ts "${MBUS_LAST_OK[${name}]:-0}" \
        '. + {($n): {id: $id, last_ok_epoch: $ts, clash_with: $clash}}' 2>/dev/null \
        || printf '%s' "${meters_json}")"
    done
  fi
  jq -n \
    --arg state "${state}" \
    --arg device "$(mbus_opt mbus_device "")" \
    --arg alias "${MBUS_BUS_ALIAS}" \
    --argjson meters "${meters_json}" \
    --argjson configured "${MBUS_METERS_OK:-0}" \
    --argjson skipped "${MBUS_METERS_SKIPPED:-0}" \
    --argjson updated "$(epoch_now)" \
    '{state: $state, device: $device, bus_alias: $alias,
      meters_configured: $configured, meters_skipped: $skipped,
      meters: $meters, updated: $updated}' \
    > "${MBUS_STATUS_FILE}.tmp" 2>/dev/null \
    && mv -f "${MBUS_STATUS_FILE}.tmp" "${MBUS_STATUS_FILE}" 2>/dev/null \
    || true
}

# Keep the tail, drop the head. Checked every 500 lines rather than per line:
# the trim costs a read and a rewrite of the whole file, and the console only
# ever shows the tail anyway.
mbus_trim_log() {
  [[ -n "${MBUS_LOG}" && -f "${MBUS_LOG}" ]] || return 0
  local count
  count="$(wc -l < "${MBUS_LOG}" 2>/dev/null || echo 0)"
  (( count > MBUS_LOG_MAX_LINES )) || return 0
  # Do not rename over MBUS_LOG: tee keeps that file open for the lifetime of
  # the decoder. Replacing the pathname would leave tee appending to the old,
  # unlinked inode and the WebUI console would freeze at the trim point.
  if tail -n "${MBUS_LOG_MAX_LINES}" "${MBUS_LOG}" > "${MBUS_LOG}.tmp" 2>/dev/null; then
    cp -f "${MBUS_LOG}.tmp" "${MBUS_LOG}" 2>/dev/null || true
  fi
  rm -f "${MBUS_LOG}.tmp" 2>/dev/null || true
}

# Transitions only. Polling runs at minute-scale intervals so this is cheap
# either way, but rewriting the file per line would repeat the per-frame
# bookkeeping that is already the throughput ceiling on the radio path.
mbus_set_state() {
  local new="$1"
  [[ "${new}" == "${MBUS_TRAFFIC_STATE}" ]] && return 0
  MBUS_TRAFFIC_STATE="${new}"
  mbus_write_status "${new}"
}

mbus_opt() {
  local key="$1" fallback="${2:-}"
  [[ -f "${OPTIONS_JSON}" ]] || { printf '%s' "${fallback}"; return; }
  jq -r --arg k "${key}" --arg d "${fallback}" '.[$k] // $d' "${OPTIONS_JSON}" 2>/dev/null \
    || printf '%s' "${fallback}"
}

mbus_enabled() {
  [[ -f "${OPTIONS_JSON}" ]] || return 1
  jq -e '.mbus_enabled == true' "${OPTIONS_JSON}" >/dev/null 2>&1
}

# ------------------------------------------------------------
# Identity pinning
# ------------------------------------------------------------
# /dev node numbers are reused: after replugging boards, ttyACM0 pointed at a
# different device within minutes. Every health state would still read "ok"
# while we talk to somebody else's hardware, so the serial number of the device
# the user picked is stored with the path and compared on every start.
mbus_device_serial_now() {
  local path="$1" real
  [[ -e "${path}" ]] || return 1
  real="$(readlink -f "${path}" 2>/dev/null || printf '%s' "${path}")"
  local node="${real##*/}"
  local sys="/sys/class/tty/${node}/device/../serial"
  [[ -r "${sys}" ]] && { tr -d '\n' < "${sys}"; return 0; }
  return 1
}

# ok | changed | unknown_identity | pin_impossible | device_missing
mbus_identity_check() {
  local path="$1" pinned="$2" now
  [[ -e "${path}" ]] || { printf 'device_missing'; return; }
  if ! now="$(mbus_device_serial_now "${path}")" || [[ -z "${now}" ]]; then
    # CH340 and PL2303 report no serial number at all — measured. The guard
    # cannot be built for them and saying so is more honest than pretending.
    printf 'pin_impossible'
    return
  fi
  [[ -z "${pinned}" ]] && { printf 'unknown_identity'; return; }
  [[ "${now}" == "${pinned}" ]] && printf 'ok' || printf 'changed'
}

# ------------------------------------------------------------
# Configuration files
# ------------------------------------------------------------
write_mbus_conf() {
  local dev alias bps loglevel donotprobe logtelegrams ignoredup pinned identity

  dev="$(mbus_opt mbus_device "")"
  alias="$(mbus_opt mbus_bus_alias "MAIN")"
  bps="$(mbus_opt mbus_baudrate "2400")"
  loglevel="$(mbus_opt mbus_loglevel "normal")"
  donotprobe="$(mbus_opt mbus_donotprobe_all "true")"
  logtelegrams="$(mbus_opt mbus_logtelegrams "false")"
  ignoredup="$(mbus_opt mbus_ignoreduplicates "false")"
  pinned="$(mbus_opt mbus_device_serial "")"
  MBUS_POLL_DEFAULT="$(mbus_opt mbus_poll_interval "15m")"

  if [[ -z "${dev}" || "${dev}" == "null" ]]; then
    # Reachable only with mbus_enabled=true, so the user asked for polling and
    # gets a warning they did not cause on purpose. Say what to do about it: the
    # engine can be armed from the add-on options page, which has no way to
    # enforce "pick a port first" — that guard exists only in the WebUI.
    warn "M-Bus: polling is enabled but no port is selected -> not starting. Pick a port in the M-Bus tab, or turn mbus_enabled off."
    mbus_write_status "not_configured"
    return 1
  fi
  if [[ ! "${alias}" =~ ^[A-Za-z0-9_]+$ ]]; then
    warn "M-Bus: invalid bus alias '${alias}' -> falling back to MAIN"
    alias="MAIN"
  fi
  MBUS_BUS_ALIAS="${alias}"

  # Free string in the options schema, so the add-on options page accepts "15"
  # as readily as "15m" — and a meter file with a malformed pollinterval is
  # never polled, which looks exactly like a dead meter. Same class of silent
  # failure as a missing pollinterval, so it is caught here rather than passed
  # down to the decoder.
  if [[ ! "${MBUS_POLL_DEFAULT}" =~ ^[0-9]+[smh]$ ]]; then
    warn "M-Bus: invalid poll interval '${MBUS_POLL_DEFAULT}' -> using 15m. Write it as a number followed by s, m or h (for example 30s, 15m, 1h)."
    MBUS_POLL_DEFAULT="15m"
  fi

  identity="$(mbus_identity_check "${dev}" "${pinned}")"
  case "${identity}" in
    device_missing)
      # /dev names are not stable across replugs, so this is the expected
      # outcome of moving the converter to another socket, not a defect.
      warn "M-Bus: the configured port ${dev} is gone -> not starting. Re-pick it in the M-Bus tab; serial port names change when USB devices are replugged."
      mbus_write_status "device_missing"
      return 1
      ;;
    changed)
      # Refusing to poll is the right call: the alternative is talking M-Bus
      # into a Zigbee coordinator or into the user's own ESP bridge.
      err "M-Bus: ${dev} is now a different device than the one you selected -> refusing to poll. Something else took that port; re-pick the converter in the M-Bus tab to confirm."
      status_add_event "error" "M-Bus device identity changed on ${dev}"
      mbus_write_status "identity_changed"
      return 1
      ;;
    pin_impossible)
      log_verbose "[DIAG] M-Bus: ${dev} reports no serial number -> identity cannot be verified"
      ;;
  esac

  mkdir -p "${MBUS_METER_DIR}"
  # if/fi, not `[[ ]] && echo`: a false test as the LAST statement makes the
  # whole brace group exit 1, the `&& mv` never runs and only the .tmp file is
  # left behind. With the defaults (logtelegrams and ignoreduplicates off) that
  # happens every time, so the instance would start with no config at all.
  # Caught by tests/test_mbus_meter_files.sh, not by review.
  {
    echo "loglevel=${loglevel}"
    # Bus alias in the device spec is accepted in the config file, not only on
    # the command line: config.cc maps "device" to handleDeviceOrHex(), which
    # calls SpecifiedDevice::parse() — the same path as the CLI argument.
    echo "device=${alias}=${dev}:mbus:${bps}"
    if [[ "${donotprobe}" == "true" ]]; then echo "donotprobe=all"; fi
    echo "logfile=/dev/stdout"
    echo "format=json"
    if [[ "${logtelegrams}" == "true" ]]; then echo "logtelegrams=true"; fi
    if [[ "${ignoredup}" == "true" ]]; then echo "ignoreduplicates=true"; fi
  } > "${MBUS_CONF_FILE}.tmp" && mv -f "${MBUS_CONF_FILE}.tmp" "${MBUS_CONF_FILE}"

  log "M-Bus: config written for ${alias}=${dev}:mbus:${bps}"
  return 0
}

refresh_mbus_meter_files() {
  rm -f "${MBUS_METER_DIR}/meter-"* 2>/dev/null || true
  local n=0 skipped=0 meter_json name addr driver driver_other key poll calc stat calc_lines stat_lines file

  MBUS_METERS_OK=0
  MBUS_METERS_SKIPPED=0

  [[ -f "${OPTIONS_JSON}" ]] || return 0
  jq -e '.mbus_meters and (.mbus_meters|length>0)' "${OPTIONS_JSON}" >/dev/null 2>&1 || {
    warn "M-Bus: no meters configured -> nothing will be polled. Add a meter with its bus address in the M-Bus tab."
    return 0
  }

  while IFS= read -r meter_json; do
    name="$(echo "${meter_json}" | jq -r '.id // "mbus"')"
    addr="$(echo "${meter_json}" | jq -r '.address // empty')"
    driver="$(echo "${meter_json}" | jq -r '.type // "auto"')"
    driver_other="$(echo "${meter_json}" | jq -r '.type_other // empty')"
    key="$(echo "${meter_json}" | jq -r '.key // empty')"
    poll="$(echo "${meter_json}" | jq -r '.poll_interval // empty')"
    calc="$(echo "${meter_json}" | jq -r '.calculated_fields // empty')"
    stat="$(echo "${meter_json}" | jq -r '.static_fields // empty')"

    # Primary addresses are p1..p250; 0x00 is the factory "unset" value and
    # 0xFB-0xFF are reserved or broadcast. Secondary addressing uses 8 hex.
    if [[ ! "${addr}" =~ ^p([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|250)$ && ! "${addr}" =~ ^[0-9A-Fa-f]{8}$ ]]; then
      warn "M-Bus: invalid address '${addr}' for '${name}' -> skipped (expected p1..p250 or 8 hex)"
      skipped=$((skipped + 1))
      continue
    fi
    if [[ -n "${key}" && "${key}" != "null" && ! "${key}" =~ ^[A-Fa-f0-9]{32}$ ]]; then
      warn "M-Bus: invalid key for '${name}' -> skipped"
      skipped=$((skipped + 1))
      continue
    fi
    [[ -z "${driver}" || "${driver}" == "null" ]] && driver="auto"
    if [[ "${driver}" == "other" ]]; then
      [[ -n "${driver_other}" && "${driver_other}" != "null" ]] || {
        warn "M-Bus: type=other but type_other empty for '${name}' -> skipped"
        skipped=$((skipped + 1)); continue; }
      driver="${driver_other}"
    fi
    [[ -z "${poll}" || "${poll}" == "null" ]] && poll="${MBUS_POLL_DEFAULT}"
    # Not skipped over: falling back to the default keeps the meter polled,
    # where dropping it would take an otherwise valid meter out of service over
    # a typo in one field.
    if [[ ! "${poll}" =~ ^[0-9]+[smh]$ ]]; then
      warn "M-Bus: invalid poll interval '${poll}' for '${name}' -> using ${MBUS_POLL_DEFAULT}"
      poll="${MBUS_POLL_DEFAULT}"
    fi

    calc_lines=""
    [[ -n "${calc}" && "${calc}" != "null" ]] && calc_lines="$(build_calculated_field_lines "${calc}" "${name}")"
    stat_lines=""
    [[ -n "${stat}" && "${stat}" != "null" ]] && stat_lines="$(build_static_field_lines "${stat}" "${name}")"

    n=$((n + 1))
    file="$(printf '%s/meter-%04d' "${MBUS_METER_DIR}" "${n}")"
    {
      echo "name=${name}"
      # driver:alias:mbus binds the meter to this bus and marks it pollable.
      if [[ "${driver}" == "auto" ]]; then
        echo "driver=auto:${MBUS_BUS_ALIAS}:mbus"
      else
        echo "driver=${driver}:${MBUS_BUS_ALIAS}:mbus"
      fi
      echo "id=${addr}"
      if [[ -n "${key}" && "${key}" != "null" ]]; then echo "key=${key}"; fi
      # Mandatory, not optional — see the header note.
      echo "pollinterval=${poll}"
      if [[ -n "${stat_lines}" ]]; then printf '%s\n' "${stat_lines}"; fi
      if [[ -n "${calc_lines}" ]]; then printf '%s\n' "${calc_lines}"; fi
    } > "${file}.tmp" && mv -f "${file}.tmp" "${file}"
  done < <(jq -c '.mbus_meters[]?' "${OPTIONS_JSON}")

  MBUS_METERS_OK="${n}"
  MBUS_METERS_SKIPPED="${skipped}"
  if (( skipped > 0 )); then
    log "M-Bus: ${n} meter file(s) written, ${skipped} entr(ies) skipped"
  else
    log "M-Bus: ${n} meter file(s) written"
  fi
}

# ------------------------------------------------------------
# Line consumer
# ------------------------------------------------------------
# The decoder names the three failure causes itself, but only in the log — none
# of them reaches the JSON. Measured signatures:
#   "no 0x68 byte found"                     -> foreign protocol (DLMS/COSEM?)
#   "expected checksum 0xNN but got 0xMM"    -> damaged frame / address clash
#   "did not send a response!"               -> silence (an E5-only meter is
#                                               indistinguishable from silence)
mbus_consume_line() {
  local line="$1" id name

  MBUS_LINES_SINCE_TRIM=$(( MBUS_LINES_SINCE_TRIM + 1 ))
  if (( MBUS_LINES_SINCE_TRIM >= 500 )); then
    MBUS_LINES_SINCE_TRIM=0
    mbus_trim_log
  fi

  if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
    id="$(normalize_meter_id "$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)")"
    name="$(echo "${line}" | jq -r '.name // empty' 2>/dev/null || true)"

    if [[ -n "${name}" && -n "${id}" ]]; then
      local prev="${MBUS_LAST_ID[${name}]:-}"
      if [[ -n "${prev}" && "${prev}" != "${id}" ]]; then
        warn "M-Bus: '${name}' answered with id=${id} but previously ${prev} -> two meters on one address?"
        status_add_event "warn" "M-Bus address clash on '${name}': ${prev} vs ${id}"
        MBUS_CLASH["${name}"]="${prev}"
      fi
      MBUS_LAST_ID["${name}"]="${id}"
      # Counted from ARRIVAL, not from the poll that asked for it: there is no
      # timeout state on this path — a reply 3 s late for a 2 s pollinterval is
      # still accepted (measured on the simulator), so "when did we last hear
      # from it" is the only answer that means anything.
      MBUS_LAST_OK["${name}"]="$(epoch_now)"
    fi

    if [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]]; then
      # rssi_dbm arrives as 0 on a wired bus — a number that looks like a
      # measurement for a meter with no radio. Strip it here rather than let it
      # become a "0 dBm" entity. device is kept: on a bus it is the port alias
      # and genuinely meaningful.
      line="$(echo "${line}" | jq -c 'del(.rssi_dbm)' 2>/dev/null || printf '%s' "${line}")"
      # Feed the same runtime index as the radio decoder.  Discovery/state were
      # already published below, but without this call the WebUI had no meter
      # row to display even though the wired path was working correctly.
      status_meter_seen "${line}"
      emit_discovery_from_json "${line}"
      mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
      status_mark_discovery_published
      write_status_json
    fi
    # Written on every accepted telegram rather than only on the transition
    # into "ok", because the per-meter timestamps move even when the state does
    # not. At poll intervals measured in minutes this costs nothing.
    MBUS_TRAFFIC_STATE="ok"
    mbus_write_status "ok"
    echo "${line}"
    return
  fi

  case "${line}" in
    *"no 0x68 byte found"*)
      mbus_set_state "not_mbus_traffic" ;;
    *"expected checksum"*)
      mbus_set_state "damaged_frames" ;;
    *"did not send a response"*)
      # A named cause outranks plain silence: once the bus is known to carry
      # foreign or damaged bytes, "no reply" adds nothing and would hide it.
      [[ "${MBUS_TRAFFIC_STATE}" == "not_mbus_traffic" || "${MBUS_TRAFFIC_STATE}" == "damaged_frames" ]] \
        || mbus_set_state "no_reply" ;;
    *"no bus specified for meter"*|*"SpecifiedDeviceNotFound"*)
      mbus_set_state "bus_down" ;;
  esac
  echo "${line}"
}

# ------------------------------------------------------------
# Supervisor
# ------------------------------------------------------------
start_mbus_instance() {
  mbus_init_paths
  if ! mbus_enabled; then
    log_verbose "[DIAG] M-Bus: disabled"
    mbus_write_status "disabled"
    return 0
  fi
  write_mbus_conf || return 0
  refresh_mbus_meter_files

  # Armed, port fine, nothing to poll. Distinct from "no_reply": the decoder is
  # not silent, it was never asked to say anything.
  if (( MBUS_METERS_OK == 0 )); then
    MBUS_TRAFFIC_STATE="no_meters"
  else
    MBUS_TRAFFIC_STATE="starting"
  fi
  mbus_write_status "${MBUS_TRAFFIC_STATE}"

  (
    while true; do
      local _t0
      _t0="$(epoch_now)"
      ${STDBUF_BIN} /usr/bin/wmbusmeters --useconfig="${MBUS_BASE}" 2>&1 \
        | tee -a "${MBUS_LOG}" \
        | while IFS= read -r line; do mbus_consume_line "${line}"; done &
      local pipeline_pid=$!
      wait "${pipeline_pid}" 2>/dev/null || true
      # Only an exiting process gets here. A vanished port does not end the
      # decoder: it waits and reconnects on its own, verified on a full
      # detach/attach cycle.
      log_verbose "[DIAG] M-Bus supervisor: instance exited, restarting"
      _sub_reconnect_sleep "${_t0}" 1
    done
  ) &
  MBUS_PID=$!
  log "M-Bus instance started (pid=${MBUS_PID}) on bus ${MBUS_BUS_ALIAS}"
}

stop_mbus_instance() {
  [[ -z "${MBUS_PID}" ]] && return 0
  log "Stopping M-Bus instance (pid=${MBUS_PID})..."
  pkill -TERM -P "${MBUS_PID}" 2>/dev/null || true
  kill -TERM "${MBUS_PID}" 2>/dev/null || true
  wait "${MBUS_PID}" 2>/dev/null || true
  pkill -KILL -P "${MBUS_PID}" 2>/dev/null || true
  MBUS_PID=""
}

# There was an mbus_health() here that returned the state as a string. Nothing
# could ever call it: the traffic state it reported lives in the pipeline
# subshell reading the decoder's output, so in the parent shell it stayed
# "unknown" forever, and the WebUI runs in a different process again. The states
# it computed from the filesystem (device_missing, identity_changed, not
# openable) are the ones webui.py's mbus_access_state() already establishes by
# trying to open the port, which is the only thing that proves access. What was
# genuinely missing is the traffic half, and that now travels through
# status_mbus.json.

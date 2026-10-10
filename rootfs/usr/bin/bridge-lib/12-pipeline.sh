#!/usr/bin/env bash
# MQTT publish and pipeline startup helpers.

mqtt_pub() {
  local topic="$1"
  local payload="$2"
  local retain="${3:-false}"

  if [[ -n "${MQTT_PUB_PORT:-}" ]]; then
    local _r=0
    [[ "${retain}" == "true" ]] && _r=1
    _mqtt_pub_persistent "${topic}" "${payload}" "${_r}" && return 0
  fi

  # No persistent publisher (disabled, not started, or not answering): one
  # mosquitto_pub per message, as before it existed.
  local retain_flag=()
  [[ "${retain}" == "true" ]] && retain_flag=( -r )

  "${MOSQUITTO_PUB_BIN:-/usr/bin/mosquitto_pub}" "${PUB_ARGS[@]}" -t "${topic}" "${retain_flag[@]}" -m "${payload}" || true
}

# Hand one message to mqtt_publisher.py over loopback TCP ($1 topic, $2
# payload, $3 retain 0/1). /dev/tcp is bash's own, so this execs nothing. It
# runs in a subshell for two reasons: a publisher dying between accept and
# write raises SIGPIPE, which then ends this subshell (the message falls back
# to mosquitto_pub) instead of the process that publishes - the decode loop,
# the heartbeat ticker; and LC_ALL=C there makes ${#2} count bytes, which is
# what the frame header carries.
_mqtt_pub_persistent() {
  (
    exec 3>"/dev/tcp/127.0.0.1/${MQTT_PUB_PORT}" || exit 1
    LC_ALL=C
    printf 'PUB %s %s %s\n%s\n' "$3" "${#2}" "$1" "$2" >&3 || exit 1
  ) 2>/dev/null
}

# Start mqtt_publisher.py: one broker connection kept open for every publish
# of the add-on, instead of a mosquitto_pub (process + connection + login) per
# message. Called once from the main shell, before any process that publishes
# is forked, so MQTT_PUB_PORT is inherited by all of them. The loop restarts
# the publisher if it exits; it binds the same port again (port file), so the
# writers keep working. MQTT_PERSISTENT_PUBLISHER=false falls back to
# mosquitto_pub per message.
MQTT_PUB_PORT=""
MQTT_PUB_DEC="false"
MQTT_PUB_BOOKS="false"
MQTT_PUB_RAW_PORT=""
MQTT_PUBLISHER_PID=""
start_mqtt_publisher() {
  if [[ "${MQTT_PERSISTENT_PUBLISHER:-true}" != "true" ]]; then
    log "MQTT: persistent publisher disabled, using mosquitto_pub per message"
    return 0
  fi
  local port_file="${RUNTIME:-${BASE}}/mqtt_publisher.port"
  local script="${MQTT_PUBLISHER:-${BRIDGE_SCRIPT_DIR:-/usr/bin}/mqtt_publisher.py}"
  rm -f "${port_file}" 2>/dev/null || true
  local books=""
  [[ "${MQTT_PUBLISHER_SUBSCRIBE:-true}" == "true" ]] && books="$(_mqtt_publisher_books)"
  (
    while true; do
      # Credentials through the environment: argv is visible in ps. So is the
      # configuration wmbus_discovery.py needs to build Discovery the way
      # emit_discovery_from_json does.
      MQTT_USER="${MQTT_USER}" MQTT_PASS="${MQTT_PASS}" \
      DISCOVERY_ENABLED="${DISCOVERY_ENABLED:-true}" DISCOVERY_PREFIX="${DISCOVERY_PREFIX:-homeassistant}" \
      DISCOVERY_RETAIN="${DISCOVERY_RETAIN:-true}" STATE_PREFIX="${STATE_PREFIX:-wmbusmeters}" \
      STATE_RETAIN="${STATE_RETAIN:-false}" REQUIRE_TIMESTAMP="${REQUIRE_TIMESTAMP:-false}" \
      STATUS_RSSI_FILE="${STATUS_RSSI_FILE:-}" STATUS_SEEN_FILE="${STATUS_SEEN_FILE:-}" \
      RSSI_MAX_AGE_S="${RSSI_MAX_AGE_S:-300}" WMBUSMETERS_BIN="${WMBUSMETERS_BIN:-/usr/bin/wmbusmeters}" \
      MQTT_PUBLISHER_BOOKS="${books}" \
        python3 "${script}" --host "${MQTT_HOST}" --port "${MQTT_PORT}" --port-file "${port_file}"
      warn "MQTT: persistent publisher exited (rc=$?), restarting in 2s"
      sleep 2
    done
  ) &
  # shellcheck disable=SC2034  # for whoever has to stop it (the tests do)
  MQTT_PUBLISHER_PID=$!

  local _i _port="" _caps=""
  for (( _i = 0; _i < 50; _i++ )); do
    [[ -s "${port_file}" ]] && read -r _port _caps < "${port_file}"
    [[ "${_port}" =~ ^[0-9]+$ ]] && break
    _port=""
    sleep 0.1
  done
  if [[ -z "${_port}" ]]; then
    warn "MQTT: persistent publisher did not start, using mosquitto_pub per message"
    return 0
  fi
  MQTT_PUB_PORT="${_port}"
  # "dec": the publisher builds Discovery and state of decoded telegrams
  # itself (wmbus_discovery.py). Without it publish_decoded_json does it here.
  if [[ " ${_caps} " == *" dec "* && "${MQTT_PYTHON_DISCOVERY:-true}" == "true" ]]; then
    MQTT_PUB_DEC="true"
  fi
  # "books": the publisher also subscribes to the ESP rssi, /rx and RAW
  # topics and keeps their bookkeeping itself; start_esp_subscribers then
  # skips its own mosquitto_sub | bridge_ledger.py loops for them.
  [[ " ${_caps} " == *" books "* ]] && MQTT_PUB_BOOKS="true"
  # "raw=<port>": the RAW stream the two wmbusmeters pipelines read (_raw_source).
  local _w
  for _w in ${_caps}; do
    [[ "${_w}" =~ ^raw=([0-9]+)$ ]] && MQTT_PUB_RAW_PORT="${BASH_REMATCH[1]}"
  done
  log "MQTT: persistent publisher ready (one broker connection for all publishes; Discovery in Python: ${MQTT_PUB_DEC}; ESP subscriptions in it: ${MQTT_PUB_BOOKS}; RAW stream from it: $([[ -n "${MQTT_PUB_RAW_PORT}" ]] && echo true || echo false))"
}

# The RAW stream of the decoder and of the parallel LISTEN instance, as
# `mosquitto_sub -t RAW_TOPIC -F '%p'` prints it: from the publisher, which
# subscribes RAW_TOPIC on its own connection, when it announced a raw port;
# otherwise - or when that port does not answer (the publisher is
# restarting) - a mosquitto_sub of its own, as before. exec: the stage stays
# one process of the pipeline, which the soft-reload watcher stops as before.
_raw_source() {
  if [[ -n "${MQTT_PUB_RAW_PORT:-}" ]] && { exec 3<"/dev/tcp/127.0.0.1/${MQTT_PUB_RAW_PORT}"; } 2>/dev/null; then
    exec cat <&3
  fi
  # shellcheck disable=SC2086  # STDBUF_BIN is a command with its options
  exec ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" "${SUB_EXTRA[@]}" -t "${RAW_TOPIC}" -F '%p'
}

# The ESP subscriptions the publisher takes over, as JSON for
# MQTT_PUBLISHER_BOOKS: per bridge_ledger.py mode its topic filter, whether
# retained messages are dropped (SUB_EXTRA's -R, as the bash loops pass it to
# /rx and RAW but not to rssi) and the files it writes. The tracker needs the
# '+' segment of RAW_TOPIC; without one it is left out, as in bash.
_mqtt_publisher_books() {
  local no_ret=false _i _dev_pos=-1 _v
  # Every file the books write must be known, or bash keeps its own loops.
  for _v in METER_DIR STATUS_RSSI_FILE STATUS_ESP_RX_RECEPTION_FILE STATUS_ESP_RX_MODE_FILE \
            ESP_RF_RX_HISTORY_FILE STATUS_ESP_RX_SEQUENCE_FILE STATUS_ESP_RX_BOOTS_FILE \
            STATUS_ESP_RX_CLOCK_FILE STATUS_ESP_TELEGRAM_DEVICES_FILE STATUS_ESP_METER_DEVICE_FILE \
            STATUS_ESP_METER_RECEPTION_FILE ESP_RX_HISTORY_FILE RAW_TOPIC STATUS_HA_PRESENCE_FILE \
            STATUS_ESP_CONFIG_FILE ESP_DIAG_HISTORY_FILE STATUS_BROKER_INFO_FILE; do
    [[ -n "${!_v:-}" ]] || return 0
  done
  [[ "${IGNORE_RETAINED:-false}" == "true" ]] && no_ret=true
  local -a _parts=()
  IFS='/' read -ra _parts <<< "${RAW_TOPIC}"
  for _i in "${!_parts[@]}"; do
    [[ "${_parts[$_i]}" == "+" ]] && { _dev_pos="${_i}"; break; }
  done
  jq -c -n \
    --arg meter_dir "${METER_DIR}" --arg rssi_file "${STATUS_RSSI_FILE}" \
    --arg rx_rec "${STATUS_ESP_RX_RECEPTION_FILE}" --arg rx_mode "${STATUS_ESP_RX_MODE_FILE}" \
    --arg rx_hist "${ESP_RF_RX_HISTORY_FILE}" --arg rx_seq "${STATUS_ESP_RX_SEQUENCE_FILE}" \
    --arg rx_boots "${STATUS_ESP_RX_BOOTS_FILE}" --arg rx_clock "${STATUS_ESP_RX_CLOCK_FILE}" \
    --arg raw_topic "${RAW_TOPIC}" --argjson dev_pos "${_dev_pos}" \
    --arg tg_dev "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" --arg tg_md "${STATUS_ESP_METER_DEVICE_FILE}" \
    --arg tg_rec "${STATUS_ESP_METER_RECEPTION_FILE}" --arg tg_hist "${ESP_RX_HISTORY_FILE}" \
    --argjson no_ret "${no_ret}" \
    --arg health_file "${RUNTIME:-${BASE}}/status_esp_health.json" \
    --arg meters_file "${RUNTIME:-${BASE}}/status_esp_meters.json" \
    --arg summary_file "${RUNTIME:-${BASE}}/status_esp_diag.json" \
    --arg window_file "${RUNTIME:-${BASE}}/status_esp_meter_window.json" \
    --arg snapshot_file "${RUNTIME:-${BASE}}/status_esp_meter_snapshot.json" \
    --arg events_file "${RUNTIME:-${BASE}}/status_esp_events.tsv" \
    --arg suggestion_file "${RUNTIME:-${BASE}}/status_esp_suggestion.json" \
    --arg boot_file "${RUNTIME:-${BASE}}/status_esp_boot.json" \
    --arg config_file "${STATUS_ESP_CONFIG_FILE}" --arg diag_hist "${ESP_DIAG_HISTORY_FILE}" \
    --arg broker_info "${STATUS_BROKER_INFO_FILE}" \
    --argjson diag_hist_on "$([[ "${ESP_DIAG_HISTORY_ENABLED:-false}" == "true" ]] && echo true || echo false)" \
    --arg ha_topic "${DISCOVERY_PREFIX:-homeassistant}/status" --arg presence_file "${STATUS_HA_PRESENCE_FILE:-}" '
      {rssi: {filter: "wmbus/+/rssi/+", no_retained: false,
               meter_dir: $meter_dir, rssi_file: $rssi_file},
       health: {filter: "wmbus/+/health", no_retained: false, health_file: $health_file},
       meters: {filter: "wmbus/+/meters", no_retained: false, file: $meters_file},
       summary: {filter: "wmbus/+/diag/summary", no_retained: false, file: $summary_file},
       meter_window: {filter: "wmbus/+/diag/meter/+/+/window/+", no_retained: false, file: $window_file},
       meter_snapshot: {filter: "wmbus/+/diag/meter_snapshot", no_retained: false, file: $snapshot_file},
       ha_presence: {filter: $ha_topic, no_retained: false, format: "payload",
                     presence_file: $presence_file},
       # One filter for both of the loop: wmbus/+/diag/# matches the bare
       # wmbus/<board>/diag as well.
       diag_events: {filter: "wmbus/+/diag/#", no_retained: false, format: "retained",
                     events_file: $events_file, suggestion_file: $suggestion_file,
                     boot_file: $boot_file, config_file: $config_file,
                     history_file: $diag_hist, history_enabled: $diag_hist_on},
       # The $SYS filters are fixed in esp_books.BrokerInfoBook.FILTERS.
       broker_info: {no_retained: false, info_file: $broker_info},
       raw_feed: {filter: $raw_topic, no_retained: $no_ret},
       rx: {filter: "wmbus/+/rx", no_retained: $no_ret,
            reception_file: $rx_rec, mode_file: $rx_mode, history_file: $rx_hist,
            sequence_file: $rx_seq, boots_file: $rx_boots, clock_file: $rx_clock}}
      + (if $dev_pos >= 0 then
           {tracker: {filter: $raw_topic, no_retained: $no_ret, dev_pos: $dev_pos,
                      devices_file: $tg_dev, meter_device_file: $tg_md,
                      reception_file: $tg_rec, history_file: $tg_hist}}
         else {} end)' 2>/dev/null || true
}

# The decode pipeline's output in bash (the loop run_once ran inline): the
# fallback of _decode_stage. $1 "true": the lines that are not JSON also go
# to the main instance's LISTEN parser - while no meter is configured this
# instance prints a "Received telegram from:" block per telegram;
# bridge_ledger.py books them (the same parser as the parallel LISTEN
# instance, which books nothing then). It reads the official count file per
# block, so with meters it books nothing.
_decode_consume_bash() {
  local zero="$1" line _zero_fd=""
  while IFS= read -r line; do
    if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
      STATUS_WMBUSMETERS_RUNNING="true"
      STATUS_DECODED_COUNT=$((STATUS_DECODED_COUNT + 1))
      # shellcheck disable=SC2034
      STATUS_LAST_DECODED_SEEN="$(iso_now)"
      status_add_event "ok" "Decoded telegram received"
      write_status_json
      status_mark_search_decoded_no_aes "${line}"
      process_search_json "${line}"
      if is_search_temp_json "${line}"; then
        clear_search_discovery_from_json "${line}"
        continue
      fi
      status_meter_seen "${line}"
      echo "${line}"
      publish_decoded_json "${line}"
      continue
    fi
    echo "${line}"
    status_detect_key_problem "${line}" || true
    if [[ "${zero}" == "true" && "${SEARCH_USING_TEMP_METERS}" != "true" ]]; then
      [[ -n "${_zero_fd:-}" ]] || exec {_zero_fd}> >(_listen_parse_stage zero)
      printf '%s\n' "${line}" >&"${_zero_fd}"
    fi
  done
}

# The decode pipeline's output, by bridge_ledger.py decode (DecodeBook): the
# counters, the event, status.json, the meter table, the key problems, the
# zero-meter LISTEN parser, SEARCH (SearchBook, with the SEARCH_* variables
# this subshell inherited: _search_state) and the hand-over to the publisher
# in one process, instead of a dozen jq and awk runs per decoded telegram.
# Needs the publisher's Discovery (MQTT_PUB_DEC); everything runs in bash
# with LEDGER_DECODE_IN_PYTHON=false, and with search_mode on also with
# LEDGER_SEARCH_IN_PYTHON=false. The loop after it runs what the ledger
# asks, fields separated by 0x1F: "publish" with the pipeline's counters
# when the publisher did not take a telegram (the mosquitto_pub path of
# publish_decoded_json), "pub" for a SEARCH message the publisher did not
# take (mqtt_pub), and what the in-process LISTEN parser asks when it runs
# without its files (see _listen_parse_stage).
_decode_stage() {
  local zero="$1"
  if [[ "${LEDGER_DECODE_IN_PYTHON:-true}" != "true" || "${MQTT_PUB_DEC:-false}" != "true" \
        || -z "${MQTT_PUB_PORT:-}" \
        || ( "${SEARCH_MODE:-false}" == "true" && "${LEDGER_SEARCH_IN_PYTHON:-true}" != "true" ) ]]; then
    _decode_consume_bash "${zero}"
    return
  fi
  # METER_EXCLUDE_FIELDS (filled by refresh_meter_files) as "id<0x1F>patterns" lines.
  local _excl="" _k
  if (( ${#METER_EXCLUDE_FIELDS[@]} > 0 )); then
    for _k in "${!METER_EXCLUDE_FIELDS[@]}"; do
      _excl+="${_k}"$'\x1f'"${METER_EXCLUDE_FIELDS[${_k}]}"$'\n'
    done
  fi
  # --name=value: a value starting with "-" must not read as an option.
  local _search
  _search="$(_search_state)"
  until METER_EXCLUDE_LINES="${_excl}" SEARCH_STATE="${_search}" python3 -u "${BRIDGE_LEDGER}" decode \
      --status-json-file="${STATUS_JSON}" --raw-count-file="${STATUS_RAW_COUNT_FILE}" \
      --last-raw-file="${STATUS_LAST_RAW_FILE}" --discovery-flag-file="${STATUS_DISCOVERY_FLAG}" \
      --events-file="${STATUS_EVENTS_FILE}" --meters-file="${STATUS_METERS_FILE}" \
      --meter-last-json-file="${STATUS_METER_LAST_JSON_FILE}" \
      --key-problem-file="${STATUS_METER_KEY_PROBLEM_FILE}" --seen-file="${STATUS_SEEN_FILE}" \
      --publisher-port="${MQTT_PUB_PORT}" --zero="${zero}" \
      --raw-topic="${RAW_TOPIC:-}" --state-prefix="${STATE_PREFIX:-}" \
      --discovery-prefix="${DISCOVERY_PREFIX:-}" --search-mode="${SEARCH_MODE:-false}" \
      --loglevel="${LOGLEVEL:-}" --mqtt-host="${MQTT_HOST:-}" --mqtt-port="${MQTT_PORT:-}" \
      --mqtt-connected="${STATUS_MQTT_CONNECTED}" --wmbusmeters-running="${STATUS_WMBUSMETERS_RUNNING}" \
      --decoded-count="${STATUS_DECODED_COUNT}" --last-decoded-seen="${STATUS_LAST_DECODED_SEEN}" \
      --last-error="${STATUS_LAST_ERROR}" --last-event="${STATUS_LAST_EVENT}" \
      --discovery-published="${STATUS_DISCOVERY_PUBLISHED}" \
      --discovery-published-at="${STATUS_DISCOVERY_PUBLISHED_AT}" \
      --candidates-file="${STATUS_CANDIDATES_FILE}" --recent-raw-file="${STATUS_RECENT_RAW_FILE}" \
      --candidate-raw-file="${STATUS_CANDIDATE_RAW_FILE}" \
      --candidate-analysis-file="${STATUS_CANDIDATE_ANALYSIS_FILE}" --snippet-file="${SNIPPET_STATE}" \
      --official-count-file="${STATUS_OFFICIAL_METERS_COUNT_FILE}" \
      --official-count-default="${OFFICIAL_METERS_COUNT:-0}" --meter-dir="${METER_DIR}" \
      --preview-meter-dir="${PREVIEW_METER_DIR}" --search-expected="${SEARCH_EXPECTED_VALUE_M3:-0}" \
      --preview-state-file="${STATUS_CANDIDATE_PREVIEW_STATE_FILE}" \
      --preview-attempts-dir="${RUNTIME:-${BASE}}/.preview_attempts" \
      --candidate-values-file="${STATUS_CANDIDATE_VALUES_FILE}" \
      --preview-oneshot-runtime="$([[ "${LEDGER_PREVIEW_IN_PYTHON:-true}" == "true" ]] && echo "${RUNTIME:-${BASE}}")"; do
    sleep 1
  done | {
    local _act _a _b _c _d
    while IFS=$'\x1f' read -r _act _a _b _c _d; do
      case "${_act}" in
        publish)
          STATUS_WMBUSMETERS_RUNNING="true"
          STATUS_DECODED_COUNT="${_a}"
          # shellcheck disable=SC2034
          STATUS_LAST_DECODED_SEEN="${_b}"
          STATUS_LAST_EVENT="${_c}"
          publish_decoded_json "${_d}" ;;
        pub) mqtt_pub "${_a}" "${_b}" "${_c}" ;;
        snippet) emit_snippet_if_new "${_a}" "${_b}" "${_c}" "${_d}" ;;
        search) search_cache_candidate "${_a}" "${_b}" "${_c}" ;;
        json) _process_listen_json_line "${_a}" ;;
        preview) preview_decode_raw_if_requested "${_a}" "${_b}" ;;
      esac
    done
  }
}

# Hand one decoded telegram to the publisher ($1 exclude patterns of its meter,
# $2 the JSON line); same subshell and byte count as _mqtt_pub_persistent.
_mqtt_dec_persistent() {
  (
    exec 3>"/dev/tcp/127.0.0.1/${MQTT_PUB_PORT}" || exit 1
    LC_ALL=C
    local _payload="$1"$'\n'"$2"
    printf 'DEC %s\n%s\n' "${#_payload}" "${_payload}" >&3 || exit 1
  ) 2>/dev/null
}

# A new decode pipeline starts with empty Discovery caches, in bash because
# they live in the pipeline's subshell; this tells the publisher the same.
mqtt_reset_discovery() {
  [[ "${MQTT_PUB_DEC}" == "true" ]] || return 0
  ( exec 3>"/dev/tcp/127.0.0.1/${MQTT_PUB_PORT}" && printf 'RST\n' >&3 ) 2>/dev/null || true
}

# Publish one decoded telegram of a configured meter: its Discovery configs
# and its state. Both decode branches of run_once (FILTER_HEX_ONLY on/off) call
# this, and tests/test_publish_contract.sh records everything it publishes.
publish_decoded_json() {
  local line="$1" id ts
  # The publisher builds Discovery and state itself (wmbus_discovery.py): it
  # needs only the meter's exclude patterns, looked up here because
  # METER_EXCLUDE_FIELDS is filled by bash (options, M-Bus) and keyed by the
  # lower-case normalized id. The id is read with a regex, not jq - this runs
  # for every decoded telegram. If the hand-over fails, the bash path below
  # publishes instead.
  if [[ "${MQTT_PUB_DEC}" == "true" ]]; then
    local _patterns="" _key=""
    if (( ${#METER_EXCLUDE_FIELDS[@]} )) && [[ "${line}" =~ \"id\":\"?([^\",}]*) ]]; then
      _key="$(normalize_meter_id "${BASH_REMATCH[1]}")"
      _key="${_key,,}"
      [[ -n "${_key}" ]] && _patterns="${METER_EXCLUDE_FIELDS[${_key}]:-}"
    fi
    if _mqtt_dec_persistent "${_patterns}" "${line}"; then
      status_mark_discovery_published
      write_status_json
      return 0
    fi
  fi
  id="$(normalize_meter_id "$(echo "${line}" | jq -r '.id // empty' 2>/dev/null || true)")"
  ts="$(echo "${line}" | jq -r '.timestamp // .device_date_time // empty' 2>/dev/null || true)"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  if [[ "${REQUIRE_TIMESTAMP}" == "true" && -z "${ts}" ]]; then
    warn "Skip publish: missing timestamp for id=${id}"
    return 0
  fi
  # Join the opt-in per-meter RSSI before both the Discovery config and the
  # state payload, so the field is seen by the same machinery as every decoded
  # field and needs no special case downstream.
  line="$(inject_rssi_into_json "${id}" "${line}")"
  emit_discovery_from_json "${line}"
  mqtt_pub "${STATE_PREFIX}/${id}/state" "${line}" "${STATE_RETAIN}" || true
  status_mark_discovery_published
  write_status_json
}

wait_for_mqtt() {
  log "Waiting for MQTT broker ${MQTT_HOST}:${MQTT_PORT}..."
  local _wm_out _wm_code _wm_prev
  for ((i=1; i<=MQTT_WAIT_RETRIES; i++)); do
    # Capture stderr instead of --quiet: mosquitto's error text is the only
    # way to tell "broker down" apart from "broker up but credentials
    # rejected" — those two need different retry cadences and different
    # WebUI messages.
    if _wm_out="$(/usr/bin/mosquitto_pub "${PUB_ARGS[@]}" -t "wmbus_bridge/status" -m "starting" 2>&1)"; then
      log "MQTT broker ready (attempt ${i}/${MQTT_WAIT_RETRIES})"
      STATUS_MQTT_CONNECTED="true"
      STATUS_LAST_ERROR=""
      # Connection works again — clear the broker-error marker so the WebUI
      # banner disappears.
      if [[ -s "${STATUS_BROKER_ERROR_FILE}" ]]; then
        : > "${STATUS_BROKER_ERROR_FILE}" 2>/dev/null || true
      fi
      status_add_event "ok" "MQTT broker ready"
      write_status_json
      return 0
    fi
    _wm_code="unreachable"
    if grep -qiE 'not authori[sz]ed|bad user ?name or password' <<<"${_wm_out}"; then
      _wm_code="auth_rejected"
    fi
    # Marker for the WebUI banner: code<TAB>host:port. Written on every failed
    # attempt (cheap); the event is emitted only when the classification
    # changes, so the event log is not flooded across retry cycles.
    _wm_prev="$(head -n1 "${STATUS_BROKER_ERROR_FILE}" 2>/dev/null || true)"
    printf '%s\t%s\n' "${_wm_code}" "${MQTT_HOST}:${MQTT_PORT}" > "${STATUS_BROKER_ERROR_FILE}.tmp" 2>/dev/null \
      && mv "${STATUS_BROKER_ERROR_FILE}.tmp" "${STATUS_BROKER_ERROR_FILE}" 2>/dev/null || true
    if [[ "${_wm_prev%%$'\t'*}" != "${_wm_code}" && "${_wm_code}" == "auth_rejected" ]]; then
      status_add_event "error" "MQTT broker rejected the credentials — check external_mqtt_username/password"
    fi
    if [[ "${_wm_code}" == "auth_rejected" ]]; then
      # A broker that actively rejects the password will keep rejecting it —
      # retry slowly instead of hammering it (with a wrong password this
      # add-on once produced ~200 authentication failures per minute against
      # EMQX, throttled in the broker's own log).
      warn "MQTT broker REJECTED the credentials (attempt ${i}/${MQTT_WAIT_RETRIES}), retrying in $((MQTT_WAIT_DELAY * 5))s..."
      sleep "$((MQTT_WAIT_DELAY * 5))"
    else
      warn "MQTT not ready (attempt ${i}/${MQTT_WAIT_RETRIES}), retrying in ${MQTT_WAIT_DELAY}s..."
      sleep "${MQTT_WAIT_DELAY}"
    fi
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

# The soft reload's kill: SIGTERM to the direct children of the main shell
# ($1) - mosquitto_sub, awk, tee, wmbusmeters, the while-read subshells of
# the foreground pipeline - except the watcher itself ($2), LISTEN_PID,
# HEARTBEAT_PID, the ESP subscriber PIDs (ESP_SUBSCRIBER_PIDS) and the wired
# M-Bus supervisor (MBUS_PID), which keep running across pipeline restarts
# (otherwise a soft reload would silently stop them - e.g. a stale heartbeat
# falsely flags the dashboard). The M-Bus supervisor is restarted by the
# restart loop through stop_mbus_instance, which kills its decoder: killed
# here instead, only the supervisor shell died, its wmbusmeters and consumer
# were left running with nobody to stop them, and the next start added a
# second decoder on the same serial port (two readers splitting every reply).
_soft_reload_kill_children() {
  local parent="$1" self="$2" child
  for child in $(pgrep -P "${parent}" 2>/dev/null); do
    [[ "${child}" == "${self}" ]] && continue
    [[ -n "${LISTEN_PID:-}" && "${child}" == "${LISTEN_PID}" ]] && continue
    [[ -n "${HEARTBEAT_PID:-}" && "${child}" == "${HEARTBEAT_PID}" ]] && continue
    [[ -n "${ESP_SUBSCRIBER_PIDS:-}" && " ${ESP_SUBSCRIBER_PIDS} " == *" ${child} "* ]] && continue
    [[ -n "${MBUS_PID:-}" && "${child}" == "${MBUS_PID}" ]] && continue
    kill -TERM "${child}" 2>/dev/null
  done
}

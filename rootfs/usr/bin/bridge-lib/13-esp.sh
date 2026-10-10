#!/usr/bin/env bash
# ESP diagnostic and per-device background subscriber helpers.

# A stored RSSI older than this is ignored rather than attached to a fresh
# telegram. Normally the row is written moments before the frame it belongs to
# arrives, so the window is generous; it exists for the case where the firmware
# stops publishing RSSI while still forwarding telegrams, which would otherwise
# pin one value to a meter forever.
RSSI_MAX_AGE_S=300

# Join the last reported RSSI onto a decoded telegram, by meter id. Prints the
# line unchanged when there is nothing to add, so callers can use it inline.
# One field per board and nothing else: a single merged rssi_dbm was tried first
# and removed, because two ESPs hearing the same meter made it alternate between
# boards, which is a number nobody can act on.
inject_rssi_into_json() {
  local id="${1,,}" line="$2"
  [[ -s "${STATUS_RSSI_FILE}" ]] || { printf '%s' "${line}"; return 0; }
  local _rid dbm src ts now src_key field add=""
  now="$(epoch_now)"
  while IFS=$'\t' read -r _rid dbm src ts; do
    [[ "${dbm}" =~ ^-[0-9]+$ && "${ts}" =~ ^[0-9]+$ ]] || continue
    # Same range as the subscriber: a sentinel that slipped into the file (an
    # older row, a hand-edited file) must not become a reading either.
    (( dbm >= -125 && dbm <= -1 )) || continue
    (( now - ts <= RSSI_MAX_AGE_S )) || continue
    # MQTT's `+` topic segment becomes a stable JSON/HA field suffix. Keep the
    # board name recognizable while removing punctuation that cannot belong in
    # a portable entity id (e.g. "xiao-seed" -> "xiao_seed"). Same rule as
    # sanitize_obj_id, done in-process: this runs per board per telegram.
    _obj_id "${src}"
    src_key="${REPLY}"
    [[ -n "${src_key}" ]] || continue
    field="rssi_${src_key}_dbm"
    # Key is [a-z0-9_] and the value an integer, so the object can be built
    # here and merged with ONE jq call for all boards.
    add+="${add:+,}\"${field}\":${dbm}"
  # Case-insensitive: the subscriber stores normalize_meter_id output
  # (uppercase) while id is lowercased above, so a plain == never matched a
  # meter id containing A-F.
  done < <(awk -F'\t' -v id="${id}" 'tolower($1) == id {print}' "${STATUS_RSSI_FILE}" 2>/dev/null || true)

  [[ -n "${add}" ]] || { printf '%s' "${line}"; return 0; }
  jq -c --argjson add "{${add}}" '. + $add' <<<"${line}" 2>/dev/null \
    || printf '%s' "${line}"
}

# True (0) for a boot not seen yet from this ESP, false (1) for a repeat.
# The firmware publishes its boot event retained on <diag>/boot, and the broker
# hands it back on every subscribe - at start and after every reconnect (the
# subscriber used to resubscribe every 180 s: mosquitto_sub -W is a hard limit,
# not an idle timeout). Without this every copy was logged as a new boot - one
# every three minutes on a board with hours of uptime - and each copy cleared
# the suggestion panel.
# The payload carries the board's uptime at publish time, so a real restart
# never repeats it. This also collapses the second copy the firmware sends on
# the bare diag topic at the same moment.
# State lives in the caller's associative array _ESP_BOOT_SEEN (source -> payload).
_esp_boot_is_new() {
  local topic="$1" payload="$2" src
  src="${topic#wmbus/}"; src="${src%%/diag*}"
  [[ -n "${src}" ]] || return 0
  [[ "${_ESP_BOOT_SEEN[${src}]-}" != "${payload}" ]] || return 1
  _ESP_BOOT_SEEN["${src}"]="${payload}"
  return 0
}

# True (0) when a diag message is a retained replay the event log must skip.
# The broker hands every retained topic back on each resubscribe, and the diag
# subscriber resubscribes every 180 s. Stamped with its arrival time, a replay
# posed as fresh activity: stale debug samples (lr_fifo/lr_drop) refilled the
# event log, and a board removed long ago stayed in the device list through its
# retained topics, keeping "pulse stopped" raised for it indefinitely. The
# /diag/config snapshot is the one replay the bridge wants (it is retained so
# each board's settings are learned on subscribe); the subscriber stores it
# before asking this, so it never reaches the log either.
_esp_diag_replay_ignored() {
  [[ "$1" == "1" ]]
}

# Per-message bookkeeping of the subscribers below lives in a long-lived
# Python process per subscription (see its header).
BRIDGE_LEDGER="${BRIDGE_LEDGER:-${BRIDGE_SCRIPT_DIR:-/usr/bin}/bridge_ledger.py}"

# The rssi/<id> subscriber loop (see start_esp_subscribers for what it stores
# and why only for configured meters).
_esp_rssi_subscriber() {
  while true; do
    _rssi_t0="$(epoch_now)"
    # python3 reads the subscription through a descriptor rather than a pipe,
    # so the loop holds mosquitto_sub's PID and stops it as soon as python3
    # ends, for whatever reason; both then start again after the usual
    # reconnect pause, like a dropped connection. A plain pipe is not enough:
    # where SIGPIPE is ignored (service managers and CI runners can leave it
    # so), mosquitto_sub keeps writing into the dead pipe - and the
    # subscribers here have no -W timeout, so it would never reconnect.
    # Rows already written stay; only the message being handled when python3
    # died is lost. `|| true` keeps set -e from ending the loop.
    exec {_rssi_fd}< <(
      ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "wmbus/+/rssi/+" -F '%t\t%p' 2>/dev/null
    )
    _rssi_sub_pid=$!
    python3 -u "${BRIDGE_LEDGER}" rssi \
      --meter-dir "${METER_DIR}" --rssi-file "${STATUS_RSSI_FILE}" <&"${_rssi_fd}" || true
    kill "${_rssi_sub_pid}" 2>/dev/null || true
    exec {_rssi_fd}<&-
    _sub_reconnect_sleep "${_rssi_t0}"
  done
}

# The wmbus/+/rx subscriber loop (see start_esp_subscribers).
_esp_rx_subscriber() {
  _trim_esp_rx_history "${ESP_RF_RX_HISTORY_FILE}" 100000 90000 || true
  while true; do
    _sub_t0="$(epoch_now)"
    # Same arrangement as the rssi subscriber: python3 reads through a
    # descriptor and mosquitto_sub is stopped as soon as python3 ends.
    exec {_rx_fd}< <(
      ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" "${SUB_EXTRA[@]}" \
        -t 'wmbus/+/rx' -F '%t\t%p' 2>/dev/null
    )
    _rx_sub_pid=$!
    python3 -u "${BRIDGE_LEDGER}" rx \
      --reception-file "${STATUS_ESP_RX_RECEPTION_FILE}" \
      --mode-file "${STATUS_ESP_RX_MODE_FILE}" \
      --history-file "${ESP_RF_RX_HISTORY_FILE}" \
      --sequence-file "${STATUS_ESP_RX_SEQUENCE_FILE}" \
      --boots-file "${STATUS_ESP_RX_BOOTS_FILE}" \
      --clock-file "${STATUS_ESP_RX_CLOCK_FILE}" <&"${_rx_fd}" || true
    kill "${_rx_sub_pid}" 2>/dev/null || true
    exec {_rx_fd}<&-
    _sub_reconnect_sleep "${_sub_t0}"
  done
}

# The per-ESP /telegram tracker loop (see start_esp_subscribers).
_esp_tracker_subscriber() {
  # Pre-compute which segment of RAW_TOPIC holds the device name.
  IFS='/' read -ra _RT_PARTS <<< "${RAW_TOPIC}"
  _RT_DEV_POS=-1
  for _i in "${!_RT_PARTS[@]}"; do
    if [[ "${_RT_PARTS[$_i]}" == "+" ]]; then
      _RT_DEV_POS="${_i}"
      break
    fi
  done

  if [[ "${_RT_DEV_POS}" -ge 0 ]]; then
    log "ESP-device tracker: device name at topic segment ${_RT_DEV_POS} of '${RAW_TOPIC}'"
    _trim_esp_rx_history "${ESP_RX_HISTORY_FILE}" 100000 90000 || true
    while true; do
      _sub_t0="$(epoch_now)"
      # As for the rssi and /rx subscribers: python3 reads through a
      # descriptor and mosquitto_sub is stopped as soon as python3 ends (no
      # -W here either). -F '%t\t%p': the payload attributes the telegram to
      # a meter id. The last board per meter lives in python3, so after a
      # restart each meter's board row is written once more.
      exec {_tg_fd}< <(
        ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" "${SUB_EXTRA[@]}" -t "${RAW_TOPIC}" -F '%t\t%p' 2>/dev/null
      )
      _tg_sub_pid=$!
      python3 -u "${BRIDGE_LEDGER}" tracker --dev-pos "${_RT_DEV_POS}" \
        --devices-file "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" \
        --meter-device-file "${STATUS_ESP_METER_DEVICE_FILE}" \
        --reception-file "${STATUS_ESP_METER_RECEPTION_FILE}" \
        --history-file "${ESP_RX_HISTORY_FILE}" <&"${_tg_fd}" || true
      kill "${_tg_sub_pid}" 2>/dev/null || true
      exec {_tg_fd}<&-
      _sub_reconnect_sleep "${_sub_t0}"
    done
  else
    log "ESP-device tracker: RAW_TOPIC '${RAW_TOPIC}' has no '+' wildcard — per-device tracking disabled."
  fi
}

# The subscribers below stay connected: none has a -W timeout, which is a
# hard limit, not an idle one. With -W 90/180 each one disconnected and
# connected again every 90 or 180 s - about 4 broker connections a minute,
# each a login and log lines on the broker - and replayed every retained
# topic each time. mosquitto_sub reconnects and resubscribes by itself after a
# dropped connection; when it exits, its loop starts it again after
# _sub_reconnect_sleep.
start_esp_subscribers() {
# Track background subscriber PIDs so the soft-reload watcher in bridge.sh can
# exclude them from its kill — these subscribers must survive pipeline restarts
# (otherwise a soft reload would silently stop ESP/diag/HA-presence tracking).
# shellcheck disable=SC2034  # consumed by the soft-reload watcher in bridge.sh
ESP_SUBSCRIBER_PIDS=""
# Background subscriber for ESP diagnostic summaries (wmbus/+/diag/summary).
# ESP publishes every 60 s: {"event":"summary","interval_s":60,"total":N,...}
# bridge.sh injects _bridge_rx_epoch so webui.py can check freshness.
# When fresh (<90 s) webui.py uses ESP's exact "total" count as the live rate
# instead of its own per-minute counting — more accurate source of truth.
STATUS_ESP_DIAG_FILE="${RUNTIME:-${BASE}}/status_esp_diag.json"
# Booked by the publisher on its own connection when it announced "books"
# (esp_books.SummaryBook); this loop is the fallback.
if [[ "${MQTT_PUB_BOOKS:-false}" != "true" ]]; then
(
  while true; do
    _sub_t0="$(epoch_now)"
    # -F '%t\t%p' = "topic<TAB>payload" so we can record which ESP device sent
    # the summary. The topic segment between wmbus/ and /diag/summary is the
    # ESP device name (e.g. "esphome-wmbus-tx-lilygo"). webui.py uses _topic
    # to display the source in the Pipeline ESP node and to detect when more
    # than one ESP is publishing.
    while IFS=$'\t' read -r _diag_topic _diag_line; do
          [[ -n "${_diag_line}" ]] || continue
          _ts="$(date +%s 2>/dev/null || echo 0)"
          printf '%s\n' "${_diag_line}" \
            | jq --argjson t "${_ts}" --arg topic "${_diag_topic:-}" '. + {_bridge_rx_epoch: $t, _topic: $topic}' 2>/dev/null \
            > "${STATUS_ESP_DIAG_FILE}.tmp" \
            && mv "${STATUS_ESP_DIAG_FILE}.tmp" "${STATUS_ESP_DIAG_FILE}" 2>/dev/null \
            || true
        done < <(
          ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "wmbus/+/diag/summary" -F '%t\t%p' 2>/dev/null
        )
    _sub_reconnect_sleep "${_sub_t0}"
  done
) &
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
fi

# Background subscriber for the always-on ESP radio health pulse
# (wmbus/+/health). Unlike wmbus/+/diag/summary this is published every 60 s
# regardless of the ESP's diagnostic_mode (retain=false), so it works for users
# who never enable diagnostics. Payload:
#   {"uptime_s":N,"rx_total":N,"sec_since_last_rx":N,"chip":"SX1276","listen_mode":"..."}
# bridge.sh injects _bridge_rx_epoch (freshness). The file is a MAP keyed by ESP
# device (the segment between wmbus/ and /health), so multiple ESPs each keep
# their own entry — the aggregate verdict in webui.py can then surface a single
# stopped ESP instead of hiding it. Enriches — does NOT replace — the per-device
# telegram tracker, which stays the source of truth for ESP liveness.
STATUS_ESP_HEALTH_FILE="${RUNTIME:-${BASE}}/status_esp_health.json"
# Booked by the publisher on its own connection when it announced "books"
# (esp_books.HealthBook); this loop is the fallback.
if [[ "${MQTT_PUB_BOOKS:-false}" != "true" ]]; then
(
  while true; do
    _sub_t0="$(epoch_now)"
    while IFS=$'\t' read -r _health_topic _health_line; do
          [[ -n "${_health_line}" ]] || continue
          # Device = topic segment between "wmbus/" and "/health".
          _health_dev="${_health_topic#wmbus/}"
          _health_dev="${_health_dev%/health}"
          [[ -n "${_health_dev}" && "${_health_dev}" != "${_health_topic}" ]] || continue
          _ts="$(date +%s 2>/dev/null || echo 0)"
          # Merge this device's pulse into the existing map (read-modify-write;
          # single subscriber process, so no concurrent writers). Malformed JSON
          # or a missing/empty file falls back to {} and never wipes the map.
          # `|| true` is REQUIRED: under `set -euo pipefail`, var="$(cat MISSING)"
          # exits non-zero and aborts this subshell before the write ever runs —
          # which is exactly why the file was never created on first run.
          _health_cur="$(cat "${STATUS_ESP_HEALTH_FILE}" 2>/dev/null || true)"
          [[ -n "${_health_cur}" ]] || _health_cur="{}"
          printf '%s' "${_health_cur}" \
            | jq --argjson t "${_ts}" --arg dev "${_health_dev}" --argjson p "${_health_line}" \
                '. + {($dev): ($p + {_bridge_rx_epoch: $t})}' 2>/dev/null \
            > "${STATUS_ESP_HEALTH_FILE}.tmp" \
            && mv "${STATUS_ESP_HEALTH_FILE}.tmp" "${STATUS_ESP_HEALTH_FILE}" 2>/dev/null \
            || true
        done < <(
          ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "wmbus/+/health" -F '%t\t%p' 2>/dev/null
        )
    _sub_reconnect_sleep "${_sub_t0}"
  done
) &
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
fi

# Background subscriber for the always-on ESP meter-flags topic (wmbus/+/meters).
# The ESP publishes every 60 s (retain=false, independent of diagnostic_mode) the
# meters it is explicitly configured for:
#   {"target":"03534159","highlight":["12345678", ...]}
# Stored as a MAP keyed by ESP device. webui.py unions target + highlight across
# fresh entries and badges matching meters/candidates ("flagged on the ESP"), so
# the user can spot an ESP-vs-add-on mismatch. Empty target/highlight (the common
# listen-only case) simply yields no badges.
STATUS_ESP_METERS_FILE="${RUNTIME:-${BASE}}/status_esp_meters.json"

# Background subscriber for per-meter RSSI (wmbus/<dev>/rssi/<meter_id>).
# OPT-IN on the firmware side: the ESP publishes this topic only when its YAML
# enables it, so on a default install nothing ever arrives here and the file
# below simply never appears. The decoder cannot supply RSSI itself — the
# telegram topic carries bare hex, so wmbusmeters has nothing to report — which
# is why the value has to travel out of band and be joined back by meter id.
# The id comes from the topic rather than the payload because the ESP already
# parses it for its whitelist; no correlation against the frame is needed.
#
# Only meters the DECODE instance has a meter file for are stored: the file is
# read solely by inject_rssi_into_json, which runs for decoded telegrams. Boards
# publish RSSI for every meter they hear (hundreds on a busy site, times every
# board), and a locked rewrite of the TSV per message for meters that are never
# decoded was a quarter of a CPU core on a 5-ESP install. The set of configured
# ids is re-read from METER_DIR every 30 s (bash only, no forks), so meters added
# by a soft reload start getting RSSI without restarting this subscriber.
# With MQTT_PUB_BOOKS the publisher subscribes to rssi, /rx and RAW_TOPIC on
# its own connection and runs the same bridge_ledger.py books in-process
# (start_mqtt_publisher); these three loops are then not started.
if [[ "${MQTT_PUB_BOOKS:-false}" != "true" ]]; then
  _esp_rssi_subscriber &
  ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
fi

# Booked by the publisher on its own connection when it announced "books"
# (esp_books.MetersBook); this loop is the fallback.
if [[ "${MQTT_PUB_BOOKS:-false}" != "true" ]]; then
(
  while true; do
    _sub_t0="$(epoch_now)"
    while IFS=$'\t' read -r _meters_topic _meters_line; do
          [[ -n "${_meters_line}" ]] || continue
          # Device = topic segment between "wmbus/" and "/meters".
          _meters_dev="${_meters_topic#wmbus/}"
          _meters_dev="${_meters_dev%/meters}"
          [[ -n "${_meters_dev}" && "${_meters_dev}" != "${_meters_topic}" ]] || continue
          _ts="$(date +%s 2>/dev/null || echo 0)"
          # `|| true` is REQUIRED: under `set -euo pipefail`, var="$(cat MISSING)"
          # exits non-zero and aborts this subshell before the write — the root
          # cause of status_esp_meters.json never being created on first run.
          _meters_cur="$(cat "${STATUS_ESP_METERS_FILE}" 2>/dev/null || true)"
          [[ -n "${_meters_cur}" ]] || _meters_cur="{}"
          printf '%s' "${_meters_cur}" \
            | jq --argjson t "${_ts}" --arg dev "${_meters_dev}" --argjson p "${_meters_line}" \
                '. + {($dev): ($p + {_bridge_rx_epoch: $t})}' 2>/dev/null \
            > "${STATUS_ESP_METERS_FILE}.tmp" \
            && mv "${STATUS_ESP_METERS_FILE}.tmp" "${STATUS_ESP_METERS_FILE}" 2>/dev/null \
            || true
        done < <(
          ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "wmbus/+/meters" -F '%t\t%p' 2>/dev/null
        )
    _sub_reconnect_sleep "${_sub_t0}"
  done
) &
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
fi

# Background subscriber for per-meter reception windows (wmbus/+/diag/meter_snapshot).
# OPT-IN: only published when the ESP runs diagnostic_mode normal/debug/dev with
# highlight_meters (every summary_15min / summary_60min). Batch payload holds per
# highlight-meter {id, mode, count_window, avg_interval_s, elapsed_s, ...}; webui.py
# turns count_window/elapsed_s/avg_interval_s into a per-meter reception %, the real
# quality signal (RSSI was dropped — see BENCHMARKS.md). Stored as a MAP keyed by
# ESP device so multi-ESP best-of can be computed. Independent of /health,/meters.
STATUS_ESP_METER_SNAPSHOT_FILE="${RUNTIME:-${BASE}}/status_esp_meter_snapshot.json"
# Booked by the publisher on its own connection when it announced "books"
# (esp_books.MeterSnapshotBook); this loop is the fallback.
if [[ "${MQTT_PUB_BOOKS:-false}" != "true" ]]; then
(
  while true; do
    _sub_t0="$(epoch_now)"
    while IFS=$'\t' read -r _snap_topic _snap_line; do
          [[ -n "${_snap_line}" ]] || continue
          # Device = topic segment between "wmbus/" and "/diag/meter_snapshot".
          _snap_dev="${_snap_topic#wmbus/}"
          _snap_dev="${_snap_dev%/diag/meter_snapshot}"
          [[ -n "${_snap_dev}" && "${_snap_dev}" != "${_snap_topic}" ]] || continue
          _ts="$(date +%s 2>/dev/null || echo 0)"
          # `|| true` REQUIRED under set -euo pipefail: a missing file must not
          # abort the subshell before the write (the #16 cat-abort lesson).
          _snap_cur="$(cat "${STATUS_ESP_METER_SNAPSHOT_FILE}" 2>/dev/null || true)"
          [[ -n "${_snap_cur}" ]] || _snap_cur="{}"
          printf '%s' "${_snap_cur}" \
            | jq --argjson t "${_ts}" --arg dev "${_snap_dev}" --argjson p "${_snap_line}" \
                '. + {($dev): ($p + {_bridge_rx_epoch: $t})}' 2>/dev/null \
            > "${STATUS_ESP_METER_SNAPSHOT_FILE}.tmp" \
            && mv "${STATUS_ESP_METER_SNAPSHOT_FILE}.tmp" "${STATUS_ESP_METER_SNAPSHOT_FILE}" 2>/dev/null \
            || true
        done < <(
          ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "wmbus/+/diag/meter_snapshot" -F '%t\t%p' 2>/dev/null
        )
    _sub_reconnect_sleep "${_sub_t0}"
  done
) &
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
fi

# Background subscriber for per-meter reception WINDOWS
# (wmbus/+/diag/meter/<id>/<mode>/window/<trigger>). Same reception fields as
# meter_snapshot (id, count_window, avg_interval_s, elapsed_s) but published per
# meter on the frequent "count" trigger (every N telegrams) — so the per-ESP %
# in webui.py populates within minutes and for every ESP, instead of waiting for
# a board's first 15-min summary_15min batch. Stored as a nested MAP keyed by ESP
# device then meter id, so webui.py can merge it with the snapshot per-ESP data.
STATUS_ESP_METER_WINDOW_FILE="${RUNTIME:-${BASE}}/status_esp_meter_window.json"
# Booked by the publisher on its own connection when it announced "books"
# (esp_books.MeterWindowBook); this loop is the fallback.
if [[ "${MQTT_PUB_BOOKS:-false}" != "true" ]]; then
(
  while true; do
    _sub_t0="$(epoch_now)"
    while IFS=$'\t' read -r _mw_topic _mw_line; do
          [[ -n "${_mw_line}" ]] || continue
          # Device = topic segment between "wmbus/" and "/diag/meter/...".
          _mw_dev="${_mw_topic#wmbus/}"
          _mw_dev="${_mw_dev%%/diag/meter/*}"
          [[ -n "${_mw_dev}" && "${_mw_dev}" != "${_mw_topic}" ]] || continue
          _ts="$(date +%s 2>/dev/null || echo 0)"
          # `|| true` REQUIRED under set -euo pipefail (the #16 cat-abort lesson):
          # a missing file on the first message must not abort the subshell.
          _mw_cur="$(cat "${STATUS_ESP_METER_WINDOW_FILE}" 2>/dev/null || true)"
          [[ -n "${_mw_cur}" ]] || _mw_cur="{}"
          # Key the entry by the payload's own id; nest under the device map.
          printf '%s' "${_mw_cur}" \
            | jq --argjson t "${_ts}" --arg dev "${_mw_dev}" --argjson p "${_mw_line}" \
                '($p.id // "") as $id
                 | if $id == "" then .
                   else .[$dev] = ((.[$dev] // {}) + {($id): ($p + {_bridge_rx_epoch: $t})})
                   end' 2>/dev/null \
            > "${STATUS_ESP_METER_WINDOW_FILE}.tmp" \
            && mv "${STATUS_ESP_METER_WINDOW_FILE}.tmp" "${STATUS_ESP_METER_WINDOW_FILE}" 2>/dev/null \
            || true
        done < <(
          ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "wmbus/+/diag/meter/+/+/window/+" -F '%t\t%p' 2>/dev/null
        )
    _sub_reconnect_sleep "${_sub_t0}"
  done
) &
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
fi

# Background subscriber for per-ESP-device telegram tracking.
# Listens to the RAW telegram topic (with wildcard) and records each
# distinct device name + last-seen epoch + telegram count to a TSV.
# This is the SOURCE OF TRUTH for "which ESPs are alive right now" —
# telegrams arrive live, not retained, so dead ESPs naturally age out.
# Works even when the ESP has NO diagnostic publishing enabled.
#
# The device name is whatever segment of the received topic matches the
# `+` wildcard in RAW_TOPIC (e.g. RAW_TOPIC="wmbus/+/telegram", topic
# "wmbus/xiaoseed/telegram" → device "xiaoseed"). If RAW_TOPIC has no
# wildcard at all, this loop still runs but produces no device data
# (and the WebGUI falls back to diag-based detection as before).
#
# Structured per-frame RF metadata (/rx): new firmware publishes this in
# addition to the unchanged /telegram HEX stream. It is deliberately a separate
# subscription: a malformed or absent /rx topic can never interrupt the decoder
# pipeline or the legacy tracker used by older firmware.
if [[ "${MQTT_PUB_BOOKS:-false}" == "true" ]]; then
  # The publisher books both; the history files are trimmed here at start,
  # as the loops do before their first connection.
  _trim_esp_rx_history "${ESP_RX_HISTORY_FILE}" 100000 90000 || true
  _trim_esp_rx_history "${ESP_RF_RX_HISTORY_FILE}" 100000 90000 || true
else
  _esp_tracker_subscriber &
  ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
  _esp_rx_subscriber &
  ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
fi

# Background subscriber for all ESP diagnostic events.
# Subscribes to bare diag topic (dropped/truncated/rx_path) and all subtopics.
# Writes TSV: epoch<TAB>evtype<TAB>topic<TAB>payload  (rolling 200 lines).
# Extracts suggestion and boot events to their own JSON files for webui detail panels.
STATUS_ESP_EVENTS_FILE="${RUNTIME:-${BASE}}/status_esp_events.tsv"
STATUS_ESP_SUGGESTION_FILE="${RUNTIME:-${BASE}}/status_esp_suggestion.json"
STATUS_ESP_BOOT_FILE="${RUNTIME:-${BASE}}/status_esp_boot.json"
touch "${STATUS_ESP_EVENTS_FILE}" 2>/dev/null || true
if [[ "${ESP_DIAG_HISTORY_ENABLED:-false}" == "true" ]]; then
  touch "${ESP_DIAG_HISTORY_FILE}" 2>/dev/null || true
fi
# Booked by the publisher on its own connection when it announced "books"
# (esp_books.DiagEventsBook); this loop is the fallback. The history is
# trimmed here at start either way, as the loop does before connecting.
if [[ "${MQTT_PUB_BOOKS:-false}" == "true" ]]; then
  if [[ "${ESP_DIAG_HISTORY_ENABLED:-false}" == "true" ]]; then
    _trim_esp_rx_history "${ESP_DIAG_HISTORY_FILE}" 10000 9000 || true
  fi
else
(
  _n=0
  _diag_since_trim=0
  declare -A _ESP_BOOT_SEEN=()
  if [[ "${ESP_DIAG_HISTORY_ENABLED:-false}" == "true" ]]; then
    _trim_esp_rx_history "${ESP_DIAG_HISTORY_FILE}" 10000 9000 || true
  fi
  while true; do
    _sub_t0="$(epoch_now)"
    while IFS=$'\t' read -r _eretained _etopic _epayload; do
      [[ -n "${_etopic}" ]] || continue
      [[ -n "${_epayload}" ]] || continue
      _ets="$(date +%s 2>/dev/null || echo 0)"
      # Retained /diag/config snapshot: keyed by ESP source name (topic
      # segment between wmbus/ and /diag/config), refreshed once per boot.
      # The whole file is rewritten so a removed board eventually falls off.
      if [[ "${_etopic}" == wmbus/*/diag/config ]]; then
        _cfg_src="${_etopic#wmbus/}"; _cfg_src="${_cfg_src%/diag/config}"
        if [[ -n "${_cfg_src}" ]]; then
          _cfg_cur="{}"
          [[ -s "${STATUS_ESP_CONFIG_FILE}" ]] && _cfg_cur="$(cat "${STATUS_ESP_CONFIG_FILE}" 2>/dev/null || echo "{}")"
          if printf '%s' "${_cfg_cur}" | jq --arg src "${_cfg_src}" --argjson t "${_ets}" --argjson pl "${_epayload}" '. + {($src): ($pl + {_bridge_rx_epoch: $t})}' 2>/dev/null > "${STATUS_ESP_CONFIG_FILE}.tmp"; then
            mv "${STATUS_ESP_CONFIG_FILE}.tmp" "${STATUS_ESP_CONFIG_FILE}" 2>/dev/null || true
          else
            rm -f "${STATUS_ESP_CONFIG_FILE}.tmp" 2>/dev/null || true
          fi
        fi
      fi
      if _esp_diag_replay_ignored "${_eretained}"; then
        continue
      fi
      _evtype="$(printf '%s\n' "${_epayload}" | jq -r '.event // "unknown"' 2>/dev/null || echo "unknown")"
      [[ -n "${_evtype}" && "${_evtype}" != "null" ]] || _evtype="unknown"
      # summary_15min and summary_60min publish JSON with "event":"summary" (same as 60s).
      # Override evtype from the MQTT topic suffix so they appear distinctly in the log.
      case "${_etopic}" in
        */summary_15min) _evtype="summary_15min" ;;
        */summary_60min) _evtype="summary_60min" ;;
      esac
      # A retained boot redelivered on resubscribe is not a restart.
      if [[ "${_evtype}" == "boot" ]] && ! _esp_boot_is_new "${_etopic}" "${_epayload}"; then
        continue
      fi
      printf '%s\t%s\t%s\t%s\n' "${_ets}" "${_evtype}" "${_etopic}" "${_epayload}" \
        >> "${STATUS_ESP_EVENTS_FILE}" 2>/dev/null || true
      # The dev capture retains only evidence needed for radio-path analysis.
      # Other summary/config/boot traffic remains available in the rolling UI
      # log but is not duplicated into this larger persistent JSONL history.
      if [[ "${ESP_DIAG_HISTORY_ENABLED:-false}" == "true" \
          && ( "${_etopic}" == wmbus/*/diag/lr_fifo/* || "${_etopic}" == wmbus/*/diag/lr_drop/* ) ]]; then
        _diag_src="${_etopic#wmbus/}"; _diag_src="${_diag_src%%/diag/*}"
        _append_esp_diag_history "${ESP_DIAG_HISTORY_FILE}" "${_ets}" "${_diag_src}" "${_etopic}" "${_epayload}" || true
        _diag_since_trim=$((_diag_since_trim + 1))
        if (( _diag_since_trim >= 100 )); then
          _trim_esp_rx_history "${ESP_DIAG_HISTORY_FILE}" 10000 9000 || true
          _diag_since_trim=0
        fi
      fi
      _n=$(( _n + 1 ))
      if (( _n % 50 == 0 )); then
        tail -n 200 "${STATUS_ESP_EVENTS_FILE}" > "${STATUS_ESP_EVENTS_FILE}.tmp" 2>/dev/null \
          && mv "${STATUS_ESP_EVENTS_FILE}.tmp" "${STATUS_ESP_EVENTS_FILE}" 2>/dev/null || true
      fi
      if [[ "${_evtype}" == "suggestion" ]]; then
        printf '%s\n' "${_epayload}" \
          | jq --argjson t "${_ets}" '. + {_bridge_rx_epoch: $t}' 2>/dev/null \
          > "${STATUS_ESP_SUGGESTION_FILE}.tmp" \
          && mv "${STATUS_ESP_SUGGESTION_FILE}.tmp" "${STATUS_ESP_SUGGESTION_FILE}" 2>/dev/null \
          || true
      fi
      if [[ "${_evtype}" == "boot" ]]; then
        printf '%s\n' "${_epayload}" \
          | jq --argjson t "${_ets}" '. + {_bridge_rx_epoch: $t}' 2>/dev/null \
          > "${STATUS_ESP_BOOT_FILE}.tmp" \
          && mv "${STATUS_ESP_BOOT_FILE}.tmp" "${STATUS_ESP_BOOT_FILE}" 2>/dev/null \
          || true
        # Clear stale suggestion on ESP reboot — suggestions from previous session
        # are no longer actionable after the ESP restarts.
        rm -f "${STATUS_ESP_SUGGESTION_FILE}" 2>/dev/null || true
      fi
    done < <(
      ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" \
        -t "wmbus/+/diag" -t "wmbus/+/diag/#" \
        -F '%r\t%t\t%p' 2>/dev/null
    )
    _sub_reconnect_sleep "${_sub_t0}"
  done
) &
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
fi

# Background subscriber for the Home Assistant MQTT birth/availability message.
# HA's MQTT integration publishes <discovery_prefix>/status = "online" (retained,
# LWT "offline") on the broker it is connected to. Seeing it proves a live HA
# MQTT integration consumes Discovery on the SAME broker the bridge uses; silence
# means the bridge is likely on a different/foreign broker (e.g. a cloud/Supla
# broker) and HA entities will never appear — the core MQTT->HA healthcheck.
# NB: this subscriber must NOT use SUB_EXTRA (-R). The retained birth message IS
# the signal, so retained delivery must stay enabled.
# Booked by the publisher on its own connection when it announced "books"
# (esp_books.HaPresenceBook); this loop is the fallback.
if [[ "${MQTT_PUB_BOOKS:-false}" != "true" ]]; then
(
  _ha_birth_topic="${DISCOVERY_PREFIX:-homeassistant}/status"
  log "HA-presence: watching birth topic '${_ha_birth_topic}' for MQTT->HA healthcheck"
  while true; do
    _sub_t0="$(epoch_now)"
    while IFS= read -r _ha_payload; do
      [[ -n "${_ha_payload}" ]] || continue
      _ha_state="$(printf '%s' "${_ha_payload}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
      [[ "${_ha_state}" == "online" || "${_ha_state}" == "offline" ]] || continue
      _ha_now="$(date +%s 2>/dev/null || echo 0)"
      printf '%s\t%s\n' "${_ha_state}" "${_ha_now}" > "${STATUS_HA_PRESENCE_FILE}.tmp" 2>/dev/null \
        && mv "${STATUS_HA_PRESENCE_FILE}.tmp" "${STATUS_HA_PRESENCE_FILE}" 2>/dev/null \
        || true
    done < <(
      ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "${_ha_birth_topic}" -F '%p' 2>/dev/null
    )
    _sub_reconnect_sleep "${_sub_t0}"
  done
) &
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
fi

# Background subscriber for broker identity ($SYS). Mosquitto publishes
# $SYS/broker/version = "mosquitto version X.Y.Z"; EMQX publishes
# $SYS/brokers/<node>/version (number) plus $SYS/brokers/<node>/sysdescr = "EMQX".
# Subscribing to all three covers both brokers; the WebUI labels the MQTT tile
# with brand + version. NB: no SUB_EXTRA (-R) — $SYS broadcasts must be delivered.
# A broker may refuse $SYS: EMQX's default ACL allows it to localhost clients
# only. mosquitto_sub then says "All subscription requests were denied" and
# exits at once, and the reconnect pause retried it every 2 min - a broker
# connection and an authorization warning in the broker log each time, for an
# answer that does not change. A refusal is recorded (fourth column "denied",
# shown by the WebUI) and asked again after BROKER_SYS_DENIED_RETRY_S.
# Booked by the publisher on its own connection when it announced "books"
# (esp_books.BrokerInfoBook), on a SUBSCRIBE of its own; this loop is the
# fallback.
if [[ "${MQTT_PUB_BOOKS:-false}" != "true" ]]; then
(
  _bk_brand=""
  _bk_version=""
  _bk_clients=""
  while true; do
    _sub_t0="$(epoch_now)"
    while IFS=$'\t' read -r _bk_topic _bk_payload; do
      [[ -n "${_bk_payload}" ]] || continue
      case "${_bk_topic}" in
        '$SYS/broker/version')
          _bk_brand="Mosquitto"
          _bk_version="${_bk_payload##*version }"
          ;;
        '$SYS/brokers/'*/sysdescr)
          _bk_brand="${_bk_payload}"
          ;;
        '$SYS/brokers/'*/version)
          _bk_version="${_bk_payload}"
          ;;
        '$SYS/broker/clients/connected'|'$SYS/brokers/'*/clients/count)
          # Connected-client count: Mosquitto and EMQX expose it under different
          # paths. Numeric only (some brokers prefix labels) — strip non-digits.
          _bk_clients="${_bk_payload//[!0-9]/}"
          ;;
        *)
          continue
          ;;
      esac
      [[ -n "${_bk_brand}${_bk_version}${_bk_clients}" ]] || continue
      printf '%s\t%s\t%s\n' "${_bk_brand}" "${_bk_version}" "${_bk_clients}" > "${STATUS_BROKER_INFO_FILE}.tmp" 2>/dev/null \
        && mv "${STATUS_BROKER_INFO_FILE}.tmp" "${STATUS_BROKER_INFO_FILE}" 2>/dev/null \
        || true
    done < <(
      ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" \
        -t '$SYS/broker/version' \
        -t '$SYS/brokers/+/version' \
        -t '$SYS/brokers/+/sysdescr' \
        -t '$SYS/broker/clients/connected' \
        -t '$SYS/brokers/+/clients/count' \
        -F '%t\t%p' 2>"${STATUS_BROKER_INFO_FILE}.err"
    )
    if grep -qi 'denied' "${STATUS_BROKER_INFO_FILE}.err" 2>/dev/null; then
      if [[ -z "${_bk_brand}${_bk_version}${_bk_clients}" ]]; then
        printf '\t\t\tdenied\n' > "${STATUS_BROKER_INFO_FILE}.tmp" 2>/dev/null \
          && mv "${STATUS_BROKER_INFO_FILE}.tmp" "${STATUS_BROKER_INFO_FILE}" 2>/dev/null \
          || true
      fi
      sleep "${BROKER_SYS_DENIED_RETRY_S:-3600}"
      continue
    fi
    _sub_reconnect_sleep "${_sub_t0}"
  done
) &
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
fi

# HA entity verification worker (opt-in). Round-trips Discovery through the HA
# Core API: asks "does sensor.wmbus_bridge_health exist?" — the definitive check
# whether HA on this broker actually consumes our Discovery (ground-truth for the
# odlozony "verdict C"). Writes one of:
#   verified     — HTTP 200 (entity exists)
#   not_created  — HTTP 404 after a grace period (Discovery published, HA did not create it)
#   pending      — within the grace period (HA needs a moment after Discovery)
#   unavailable  — opt-in off, no SUPERVISOR_TOKEN, no homeassistant_api, no curl, or transient error
# Format: state<TAB>epoch. The verdict joins ha_link in webui.py: verified wins
# over native/birth (uzupelnia, nie nadpisuje — see PRD).
(
  _hv_grace="${VERIFY_HA_GRACE_SECONDS:-90}"
  _hv_interval="${VERIFY_HA_INTERVAL_SECONDS:-30}"
  _hv_url="http://supervisor/core/api/template"
  # NB: query by the canary's unique icon, NOT by entity_id. HA can prefix the
  # entity_id with the device-name slug (observed in the wild:
  # sensor.wmbus_bridge_wmbus_bridge_health), so a hardcoded entity_id is
  # fragile. mdi:check-network is unique to our canary across HA defaults.
  _hv_payload="$(jq -nc '{template: "{{ states.sensor | selectattr(\"attributes.icon\",\"eq\",\"mdi:check-network\") | list | length }}"}' 2>/dev/null)"
  # Status file format: state<TAB>epoch<TAB>reason.
  # state    = verified | not_created | pending | unavailable
  # reason   = optional, ONLY for unavailable; one of
  #   disabled | no_token | no_curl | no_payload | auth_error | network_error | api_error
  # The WebUI uses reason to render a precise, actionable hint ("enable
  # verify_ha_entities", "Docker standalone", "check homeassistant_api", ...).
  _hv_write() {
    local _state="$1" _reason="${2:-}" _now
    _now="$(date +%s 2>/dev/null || echo 0)"
    printf '%s\t%s\t%s\n' "${_state}" "${_now}" "${_reason}" > "${STATUS_HA_VERIFICATION_FILE}.tmp" 2>/dev/null \
      && mv "${STATUS_HA_VERIFICATION_FILE}.tmp" "${STATUS_HA_VERIFICATION_FILE}" 2>/dev/null \
      || true
  }
  if [[ "${VERIFY_HA_ENTITIES:-false}" != "true" ]]; then
    _hv_write "unavailable" "disabled"
    log "verify_ha_entities: disabled (opt-in)"
  elif [[ -z "${SUPERVISOR_TOKEN:-}" ]]; then
    _hv_write "unavailable" "no_token"
    log "verify_ha_entities: enabled but SUPERVISOR_TOKEN missing — Docker standalone? state: unavailable"
  elif ! command -v curl >/dev/null 2>&1; then
    _hv_write "unavailable" "no_curl"
    log "verify_ha_entities: curl not available — state: unavailable"
  elif [[ -z "${_hv_payload}" ]]; then
    _hv_write "unavailable" "no_payload"
    log "verify_ha_entities: failed to build template payload — state: unavailable"
  else
    log "verify_ha_entities: worker started (grace=${_hv_grace}s interval=${_hv_interval}s, template-API canary by icon)"
    _hv_started="$(date +%s 2>/dev/null || echo 0)"
    _hv_write "pending"
    while true; do
      _hv_now="$(date +%s 2>/dev/null || echo 0)"
      # Capture body + status code in one call (status on a separate line).
      _hv_resp="$(curl -s -w '\n%{http_code}' --max-time 5 \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "${_hv_payload}" \
        "${_hv_url}" 2>/dev/null || echo $'\n000')"
      _hv_code="${_hv_resp##*$'\n'}"
      _hv_body="$(printf '%s' "${_hv_resp%$'\n'*}" | tr -d '[:space:]')"
      case "${_hv_code}" in
        200)
          if [[ "${_hv_body}" == "1" ]]; then
            _hv_write "verified"
          elif [[ "${_hv_body}" == "0" ]]; then
            # Within the grace period a 0 just means HA has not processed
            # Discovery yet. After the grace period we report it firmly.
            if (( _hv_now - _hv_started >= _hv_grace )); then
              _hv_write "not_created"
            else
              _hv_write "pending"
            fi
          else
            # Multiple matches or unexpected body — be conservative.
            _hv_write "verified"
          fi
          ;;
        401|403)
          _hv_write "unavailable" "auth_error"
          log "verify_ha_entities: HA Core API returned ${_hv_code} (auth/permission) — check homeassistant_api"
          ;;
        000|"")
          # Network error, timeout, or curl unavailable — soft state.
          _hv_write "unavailable" "network_error"
          ;;
        *)
          _hv_write "unavailable" "api_error"
          ;;
      esac
      sleep "${_hv_interval}"
    done
  fi
) &
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"
}

#!/usr/bin/env bash
# ESP diagnostic and per-device background subscriber helpers.

start_esp_subscribers() {
# Background subscriber for ESP diagnostic summaries (wmbus/+/diag/summary).
# ESP publishes every 60 s: {"event":"summary","interval_s":60,"total":N,...}
# bridge.sh injects _bridge_rx_epoch so webui.py can check freshness.
# When fresh (<90 s) webui.py uses ESP's exact "total" count as the live rate
# instead of its own per-minute counting — more accurate source of truth.
STATUS_ESP_DIAG_FILE="${BASE}/status_esp_diag.json"
(
  while true; do
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
          ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "wmbus/+/diag/summary" -F '%t\t%p' -W 90 2>/dev/null
        )
    sleep 5
  done
) &

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
(
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
    while true; do
      # Read via process substitution, not a pipe: with set -euo pipefail a
      # mosquitto_sub timeout/disconnect would otherwise kill this tracker.
      while IFS= read -r _tg_topic; do
        [[ -n "${_tg_topic}" ]] || continue
        IFS='/' read -ra _T_PARTS <<< "${_tg_topic}"
        _dev="${_T_PARTS[${_RT_DEV_POS}]:-}"
        [[ -n "${_dev}" ]] || continue
        _now=$(date +%s 2>/dev/null || echo 0)
        _tmp="${STATUS_ESP_TELEGRAM_DEVICES_FILE}.tmp"
        # Upsert the row for this device — increment count if exists,
        # otherwise append a fresh row with count=1.
        awk -F'\t' -v dev="${_dev}" -v now="${_now}" -v tg="${_tg_topic}" '
          BEGIN { upd=0 }
          $1 == dev {
            cnt = (NF >= 4 ? $4+1 : 1)
            print dev "\t" now "\t" tg "\t" cnt
            upd=1
            next
          }
          { print }
          END { if (!upd) print dev "\t" now "\t" tg "\t1" }
        ' "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" 2>/dev/null > "${_tmp}" \
          && mv "${_tmp}" "${STATUS_ESP_TELEGRAM_DEVICES_FILE}" 2>/dev/null \
          || true
      done < <(
        ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" "${SUB_EXTRA[@]}" -t "${RAW_TOPIC}" -F '%t' -W 180 2>/dev/null
      )
      sleep 5
    done
  else
    log "ESP-device tracker: RAW_TOPIC '${RAW_TOPIC}' has no '+' wildcard — per-device tracking disabled."
  fi
) &

# Background subscriber for all ESP diagnostic events.
# Subscribes to bare diag topic (dropped/truncated/rx_path) and all subtopics.
# Writes TSV: epoch<TAB>evtype<TAB>topic<TAB>payload  (rolling 200 lines).
# Extracts suggestion and boot events to their own JSON files for webui detail panels.
STATUS_ESP_EVENTS_FILE="${BASE}/status_esp_events.tsv"
STATUS_ESP_SUGGESTION_FILE="${BASE}/status_esp_suggestion.json"
STATUS_ESP_BOOT_FILE="${BASE}/status_esp_boot.json"
touch "${STATUS_ESP_EVENTS_FILE}" 2>/dev/null || true
(
  _n=0
  while true; do
    while IFS=$'\t' read -r _etopic _epayload; do
      [[ -n "${_etopic}" ]] || continue
      [[ -n "${_epayload}" ]] || continue
      _ets="$(date +%s 2>/dev/null || echo 0)"
      _evtype="$(printf '%s\n' "${_epayload}" | jq -r '.event // "unknown"' 2>/dev/null || echo "unknown")"
      [[ -n "${_evtype}" && "${_evtype}" != "null" ]] || _evtype="unknown"
      # summary_15min and summary_60min publish JSON with "event":"summary" (same as 60s).
      # Override evtype from the MQTT topic suffix so they appear distinctly in the log.
      case "${_etopic}" in
        */summary_15min) _evtype="summary_15min" ;;
        */summary_60min) _evtype="summary_60min" ;;
      esac
      printf '%s\t%s\t%s\t%s\n' "${_ets}" "${_evtype}" "${_etopic}" "${_epayload}" \
        >> "${STATUS_ESP_EVENTS_FILE}" 2>/dev/null || true
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
        -F '%t\t%p' -W 180 2>/dev/null
    )
    sleep 5
  done
) &
}

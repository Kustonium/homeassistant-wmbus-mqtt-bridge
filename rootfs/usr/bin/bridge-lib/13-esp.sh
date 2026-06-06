#!/usr/bin/env bash
# ESP diagnostic and per-device background subscriber helpers.

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
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"

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
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"

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
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"

# Background subscriber for the Home Assistant MQTT birth/availability message.
# HA's MQTT integration publishes <discovery_prefix>/status = "online" (retained,
# LWT "offline") on the broker it is connected to. Seeing it proves a live HA
# MQTT integration consumes Discovery on the SAME broker the bridge uses; silence
# means the bridge is likely on a different/foreign broker (e.g. a cloud/Supla
# broker) and HA entities will never appear — the core MQTT->HA healthcheck.
# NB: this subscriber must NOT use SUB_EXTRA (-R). The retained birth message IS
# the signal, so retained delivery must stay enabled.
(
  _ha_birth_topic="${DISCOVERY_PREFIX:-homeassistant}/status"
  log "HA-presence: watching birth topic '${_ha_birth_topic}' for MQTT->HA healthcheck"
  while true; do
    while IFS= read -r _ha_payload; do
      [[ -n "${_ha_payload}" ]] || continue
      _ha_state="$(printf '%s' "${_ha_payload}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
      [[ "${_ha_state}" == "online" || "${_ha_state}" == "offline" ]] || continue
      _ha_now="$(date +%s 2>/dev/null || echo 0)"
      printf '%s\t%s\n' "${_ha_state}" "${_ha_now}" > "${STATUS_HA_PRESENCE_FILE}.tmp" 2>/dev/null \
        && mv "${STATUS_HA_PRESENCE_FILE}.tmp" "${STATUS_HA_PRESENCE_FILE}" 2>/dev/null \
        || true
    done < <(
      ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -t "${_ha_birth_topic}" -F '%p' -W 180 2>/dev/null
    )
    sleep 5
  done
) &
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"

# Background subscriber for broker identity ($SYS). Mosquitto publishes
# $SYS/broker/version = "mosquitto version X.Y.Z"; EMQX publishes
# $SYS/brokers/<node>/version (number) plus $SYS/brokers/<node>/sysdescr = "EMQX".
# Subscribing to all three covers both brokers; the WebUI labels the MQTT tile
# with brand + version. NB: no SUB_EXTRA (-R) — $SYS broadcasts must be delivered.
(
  _bk_brand=""
  _bk_version=""
  _bk_clients=""
  while true; do
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
        -F '%t\t%p' -W 180 2>/dev/null
    )
    sleep 5
  done
) &
ESP_SUBSCRIBER_PIDS="${ESP_SUBSCRIBER_PIDS} $!"

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

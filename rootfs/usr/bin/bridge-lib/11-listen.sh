#!/usr/bin/env bash
# Parallel LISTEN parsing, preview decoding, and supervisor lifecycle helpers.

emit_snippet_if_new() {
  local id
  local driver="$2"
  local type_line="${3:-}"
  local manufacturer="${4:-}"
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  # Update dashboard stats every time this candidate is heard.
  # Pass the real type_line from wmbusmeters output so the webui can
  # show encryption status (e.g. "Electricity meter (0x02) encrypted").
  status_candidate_seen "${id}" "${driver:-auto}" "${type_line:-listen}" "true" "${manufacturer}"

  if ! grep -qx "${id}" "${SNIPPET_STATE}" 2>/dev/null; then
    echo "${id}" >> "${SNIPPET_STATE}"
    warn "=== NEW METER CANDIDATE DETECTED ==="
    warn "Received telegram from: ${id}"
    [[ -n "${driver}" ]] && warn "Suggested driver: ${driver}"
    warn "Add to options.json meters[] (example):"
    warn "  no key:   {\"id\":\"meter_${id}\",\"meter_id\":\"${id}\",\"type\":\"auto\",\"type_other\":\"\",\"key\":\"\"}"
    warn "  zero key: {\"id\":\"meter_${id}\",\"meter_id\":\"${id}\",\"type\":\"auto\",\"type_other\":\"\",\"key\":\"00000000000000000000000000000000\"}"
    warn "=================================="
  fi
}

# ------------------------------------------------------------
# parse_listen_candidates
# Reads wmbusmeters listen-mode stdout from stdin and emits candidate
# updates (status_candidates.tsv, status_candidate_analysis.tsv, events).
# Mirrors the inline listen logic from run_once() (lines that match
# "Received telegram from:" / type: / driver:), but lives in a parallel
# subshell so it can run alongside the main DECODE pipeline.
#
# write_status_json is overridden to a no-op here — the candidate
# subshell holds a stale snapshot of the parent's STATUS_* vars at fork
# time, so letting it write status.json would clobber the parent's
# decoded-counter / last-seen state. The TSV files are still updated
# directly (status_candidate_seen writes them via awk+mv), which is
# what the WebGUI actually reads for the candidate panel.
# ------------------------------------------------------------
# _store_candidate_value: extracts (id, primary_numeric_value, value_key) from a
# decoded wmbusmeters JSON telegram and writes/updates a single row in
# status_candidate_values.tsv. Called only for telegrams from candidates that
# have a meter-preview-<id> file in /data/listen/etc/wmbusmeters.d/ (webui.py
# writes those when the user clicks "Preview value" on the Discover page).
#
# Picks the SAME primary field as status_meter_seen() — keeps preview values
# consistent with what the user sees on the Meters page after permanently adding
# the meter. Heuristic (cumulative meter reading first):
#   1. canonical current totals (total_m3, total_energy_consumption_kwh, etc.),
#      then other cumulative readings. Skips production/tariff registers and
#      fault/diagnostic counters (backflow_m3, fraud_*, leak_*, tamper_*, alarm_*).
#   2. instantaneous reading (_kw, _w, _m3h, _l_h) — only when no total exists.
#   3. last resort: first numeric field
_store_candidate_value() {
  local json_line="$1"
  local id value_key value now
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  # Step 1 — cumulative meter reading. Excludes historical/helper fields,
  # production/tariff registers and
  # fault counters that wmbusmeters sometimes emits with bogusly large values
  # (the bug that put 1291845 m³ of "backflow" in the WebGUI before).
  IFS=$'\t' read -r value_key value < <(_select_primary_meter_value "${json_line}") || true
  if [[ -z "${value_key}" ]]; then
    IFS=$'\t' read -r value_key value < <(
      jq -r '
        [to_entries[]
          | select((.value|type)=="number")
          | select(.key|test("^total_energy_consumption_tariff_[0-9]+_kwh$";"i"))
          | .value] as $vals
        | if ($vals|length) > 0 then "total_energy_consumption_kwh\t\($vals|add)" else empty end
      ' <<<"${json_line}" 2>/dev/null | head -n 1
    ) || true
  fi
  # Step 2 — instantaneous fields, only when no cumulative total was found.
  if [[ -z "${value_key}" ]]; then
    value_key="$(jq -r 'to_entries[] | select((.value|type)=="number") | select(.key|test("(_kw$|_w$|_m3h$|_l_h$)";"i")) | .key' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -n "${value_key}" ]]; then
    [[ -n "${value:-}" ]] || value="$(jq -r --arg k "${value_key}" '.[$k] // empty' <<<"${json_line}" 2>/dev/null || true)"
  else
    # Step 3 — any numeric (skip wmbusmeters metadata keys though).
    IFS=$'\t' read -r value_key value < <(
      jq -r '
        to_entries[]
        | select(.key as $k
            | (["_","id","name","meter","media","timestamp","device_date_time","rssi","lqi","status","driver","type"]
                | index($k)) | not)
        | select((.value|type)=="number")
        | "\(.key)\t\(.value)"
      ' <<<"${json_line}" 2>/dev/null | head -n 1
    )
  fi
  if [[ -z "${value}" ]]; then
    log_verbose "[DIAG] _store_candidate_value ${id}: no numeric value found, skipping"
    _set_preview_state "${id}" "decoded_without_numeric_value"
    return 0
  fi
  log_debug "[DIAG] _store_candidate_value ${id}: value_key=${value_key} value=${value}"
  now="$(iso_now)"
  _tsv_upsert "${STATUS_CANDIDATE_VALUES_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s' "${id}" "${value}" "${value_key}" "${now}")"
  _set_preview_state "${id}" "decoded_value"
  log_debug "[DIAG] _store_candidate_value ${id}: wrote to status_candidate_values.tsv"
}

status_candidate_seen_from_json() {
  local json_line="$1"
  local id driver type_line existing_driver existing_type
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  driver="$(jq -r '.meter // .driver // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ -n "${driver}" && "${driver}" != "null" ]] || driver="auto"
  type_line="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ "${type_line}" != "null" ]] || type_line=""

  IFS=$'\t' read -r existing_driver existing_type < <(
    awk -F '\t' -v id="${id}" '$1==id {print $2 "\t" $3; exit}' "${STATUS_CANDIDATES_FILE}" 2>/dev/null || true
  )
  # Decoded JSON wins: .meter is the real driver, .media the medium. Fall back
  # to a stored value only when the JSON gave none, and ignore the generic
  # placeholders ("auto" / "wMBus telegram") so a real decode heals a candidate
  # first registered from the raw A-field.
  if [[ "${driver}" == "auto" && -n "${existing_driver}" && "${existing_driver}" != "auto" ]]; then
    driver="${existing_driver}"
  fi
  if [[ -z "${type_line}" && -n "${existing_type}" && "${existing_type}" != "wMBus telegram" ]]; then
    type_line="${existing_type}"
  fi
  [[ -n "${type_line}" ]] || type_line="decoded"

  status_candidate_seen "${id}" "${driver}" "${type_line}"
}

# Process one completed text-output block from the parallel LISTEN instance.
# Called with a delayed flush — when the next "Received telegram from:" line
# arrives — so manufacturer: (which follows driver: in wmbusmeters output)
# is always captured before the block is dispatched.
# Arguments: id  driver  type  manufacturer
_process_listen_text_block() {
  local _id="$1" _drv="$2" _type="$3" _mfr="$4"
  # Update manufacturer from text output before the driver guard so that the
  # full text name (e.g. "(NES) NORA ELK MALZ SAN ve TIC") is stored even when
  # wmbusmeters omits the driver: line (encrypted or unrecognised telegrams).
  # candidate_update_manufacturer_text only overwrites empty or bare 3-letter
  # codes; full names already in the TSV are left untouched.
  [[ -n "${_id}" && -n "${_mfr}" ]] && candidate_update_manufacturer_text "${_id}" "${_mfr}"
  [[ -n "${_id}" && -n "${_drv}" ]] || return 0
  # When there are no official meters, the primary pipeline already runs in
  # LISTEN mode and updates candidate stats. A secondary LISTEN may still be
  # running for preview decoding; do not double-count candidate receptions.
  if [[ "${OFFICIAL_METERS_COUNT:-0}" -gt 0 ]]; then
    if [[ "${SEARCH_MODE}" == "true" && "${SEARCH_EXPECTED_VALUE_M3}" != "0" ]]; then
      search_cache_candidate "${_id}" "${_drv}" "${_type}"
    else
      emit_snippet_if_new "${_id}" "${_drv}" "${_type}" "${_mfr}"
    fi
  fi
  # Track text-only telegrams (no JSON) for preview candidates.
  # When a preview file exists but wmbusmeters never emits JSON (driver not
  # recognised or unsupported telegram variant), the state stays "pending"
  # forever. After count >= 3 AND elapsed >= 60 s, set no_decode_result so
  # the UI shows "brak wyniku dekodowania" instead of "dekoduję..." forever.
  # JSON arriving later still overrides via _store_candidate_value → decoded_value
  # or decoded_without_numeric_value (both use _tsv_upsert which replaces the row).
  if ! candidate_type_requires_aes "${_type}"; then
    local _pf _cur_state _cnt_file _cnt _start _now _elapsed _cnt_tmp
    _pf="${LISTEN_METER_DIR}/meter-preview-${_id}"
    if [[ -f "${_pf}" ]]; then
      _cur_state="$(awk -F '\t' -v id="${_id}" '$1==id {print $2; exit}' \
        "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}" 2>/dev/null || true)"
      if [[ "${_cur_state}" == "pending" ]]; then
        _cnt_file="${BASE}/.preview_attempts/${_id}"
        _cnt=0
        _start=0
        if [[ -f "${_cnt_file}" ]]; then
          IFS=$'\t' read -r _cnt _start < "${_cnt_file}" 2>/dev/null || true
          [[ "${_cnt}" =~ ^[0-9]+$ ]] || _cnt=0
          [[ "${_start}" =~ ^[0-9]+$ ]] || _start=0
        fi
        _now="$(date +%s 2>/dev/null || echo 0)"
        (( _start > 0 )) || _start="${_now}"
        _cnt=$(( _cnt + 1 ))
        _elapsed=$(( _now - _start ))
        _cnt_tmp="$(mktemp "${_cnt_file}.tmp.XXXXXX" 2>/dev/null)" || true
        if [[ -n "${_cnt_tmp}" ]]; then
          printf '%d\t%d\n' "${_cnt}" "${_start}" > "${_cnt_tmp}"
          mv "${_cnt_tmp}" "${_cnt_file}" 2>/dev/null \
            || { rm -f "${_cnt_tmp}" 2>/dev/null || true; }
        fi
        if (( _cnt >= 3 && _elapsed >= 60 )); then
          log_verbose "[DIAG] LISTEN-parse: no JSON after ${_cnt} text-only telegrams (${_elapsed}s) for ${_id} → no_decode_result"
          _set_preview_state "${_id}" "no_decode_result"
        else
          log_debug "[DIAG] LISTEN-parse: text-only telegram #${_cnt} for preview ${_id} (elapsed=${_elapsed}s, need count>=3 AND elapsed>=60)"
        fi
      fi
    fi
  fi
}

parse_listen_candidates() {
  # Suppress status.json writes from this subshell to prevent races
  # with the parent shell's pipeline writes.
  write_status_json() { :; }

  local last_id="" last_driver="" last_type="" last_manufacturer=""
  while IFS= read -r line; do
    # Decoded JSON output — present only when LISTEN has a meter-preview-<id>
    # config matching this telegram's ID. Capture the primary numeric value
    # for the WebGUI "Preview value" feature.
    if [[ "${line}" == \{*\"_\":\"telegram\"* ]]; then
      log_debug "[DIAG] LISTEN-parse: JSON telegram received: ${line:0:160}"
      if [[ "${OFFICIAL_METERS_COUNT:-0}" -gt 0 ]]; then
        status_candidate_seen_from_json "${line}"
      fi
      log_debug "[DIAG] LISTEN-parse: calling _store_candidate_value"
      _store_candidate_value "${line}"
      continue
    fi
    # Plain listen-mode text output — extract candidate metadata.
    # Flush the previous block when a new telegram starts so manufacturer:
    # (which follows driver: in wmbusmeters output) is captured before dispatch.
    if [[ "${line}" =~ ^Received\ telegram\ from:\ ([0-9A-Fa-f]{8}) ]]; then
      _process_listen_text_block "${last_id}" "${last_driver}" "${last_type}" "${last_manufacturer}"
      last_id="$(normalize_meter_id "${BASH_REMATCH[1]}")"
      last_type=""
      last_driver=""
      last_manufacturer=""
    elif [[ "${line}" =~ ^[[:space:]]*type:[[:space:]]*(.*)$ ]]; then
      last_type="${BASH_REMATCH[1]}"
    elif [[ "${line}" =~ ^[[:space:]]*driver:\ ([a-zA-Z0-9_]+) ]]; then
      last_driver="${BASH_REMATCH[1]}"
    elif [[ "${line}" =~ ^[[:space:]]*manufacturer:[[:space:]]*(.*)$ ]]; then
      last_manufacturer="${BASH_REMATCH[1]}"
    fi
  done
  # Flush the last block after the stream ends.
  _process_listen_text_block "${last_id}" "${last_driver}" "${last_type}" "${last_manufacturer}"
}

# ────────────────────────────────────────────────────────────────────────
# Parallel LISTEN instance lifecycle — managed at the script level so it
# persists across run_once() restarts (soft reload picks up new meters
# without disturbing the always-on candidate stream).
# ────────────────────────────────────────────────────────────────────────
LISTEN_PID=""

listen_preview_count() {
  local count=0 f
  for f in "${LISTEN_METER_DIR}"/meter-preview-*; do
    [[ -e "${f}" ]] || continue
    count=$((count + 1))
  done
  echo "${count}"
}

start_listen_instance() {
  # Already running? Done.
  if [[ -n "${LISTEN_PID}" ]] && kill -0 "${LISTEN_PID}" 2>/dev/null; then
    return 0
  fi
  (
    # ── LISTEN supervisor loop ──
    # Runs the listen pipeline (mosquitto_sub | awk | wmbusmeters | parse).
    # When /data/.reload_listen flag appears (touched by webui.py /api/preview-
    # candidate or /api/cancel-preview), kills the current pipeline and
    # restarts it. This lets wmbusmeters pick up newly added meter-preview-<id>
    # files in /data/listen/etc/wmbusmeters.d/ without touching the DECODE
    # pipeline. Reload cycle ~2-3 s.
    while true; do
      _diag_preview_count="$(find "${LISTEN_METER_DIR}" -maxdepth 1 -name 'meter-preview-*' 2>/dev/null | wc -l | tr -d ' ')"
      log_verbose "[DIAG] LISTEN supervisor: starting pipeline (meter-preview-* count=${_diag_preview_count} in ${LISTEN_METER_DIR})"
      ${STDBUF_BIN} /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" "${SUB_EXTRA[@]}" -t "${RAW_TOPIC}" -F '%p' \
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
        | ${STDBUF_BIN} /usr/bin/wmbusmeters --useconfig="${LISTEN_BASE}" 2>&1 \
        | parse_listen_candidates &
      pipeline_pid=$!
      log_debug "[DIAG] LISTEN supervisor: pipeline started (pid=${pipeline_pid})"
      # Poll for reload flag or natural exit.
      while kill -0 "${pipeline_pid}" 2>/dev/null; do
        if [[ -f "${BASE}/.reload_listen" ]]; then
          log_verbose "[DIAG] LISTEN supervisor: .reload_listen detected, killing pid=${pipeline_pid}"
          rm -f "${BASE}/.reload_listen" 2>/dev/null || true
          pkill -TERM -P "${pipeline_pid}" 2>/dev/null || true
          kill -TERM "${pipeline_pid}" 2>/dev/null || true
          wait "${pipeline_pid}" 2>/dev/null || true
          log_verbose "[DIAG] LISTEN supervisor: pipeline stopped, restarting"
          break
        fi
        sleep 2
      done
      wait "${pipeline_pid}" 2>/dev/null || true
      # Brief pause before restart to avoid tight-looping on persistent failures.
      sleep 1
    done
  ) &
  LISTEN_PID=$!
  log "Parallel LISTEN instance started (pid=${LISTEN_PID}) — supervisor loop with .reload_listen support."
}

stop_listen_instance() {
  [[ -z "${LISTEN_PID}" ]] && return 0
  log "Stopping parallel LISTEN instance (pid=${LISTEN_PID})..."
  pkill -TERM -P "${LISTEN_PID}" 2>/dev/null || true
  kill -TERM "${LISTEN_PID}" 2>/dev/null || true
  wait "${LISTEN_PID}" 2>/dev/null || true
  pkill -KILL -P "${LISTEN_PID}" 2>/dev/null || true
  LISTEN_PID=""
}

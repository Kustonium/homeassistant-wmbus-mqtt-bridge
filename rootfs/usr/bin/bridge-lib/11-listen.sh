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

  # reload=false (6th arg): this runs on every decoded preview telegram while
  # official meters are configured. Letting it trigger a parallel LISTEN reload
  # (auto -> real driver rewrites the meter-preview file) kills+restarts the
  # pipeline on every telegram, so previews never stabilise and stay on
  # "decoding...". Update the driver/stats only; the refreshed driver is picked
  # up on the next natural restart.
  status_candidate_seen "${id}" "${driver}" "${type_line}" "true" "" "false"
}

# Defensive legacy path: pure LISTEN should not emit decoded JSON because its
# config directory is empty. Keep handling it safely in case a stale external
# file appears; normal preview decoding runs through one-shot RAW workers.
_process_listen_json_line() {
  local line="$1"
  log_debug "[DIAG] LISTEN-parse: JSON telegram received: ${line:0:160}"
  if [[ "$(official_meters_count_current)" -gt 0 ]]; then
    status_candidate_seen_from_json "${line}"
  fi
  log_debug "[DIAG] LISTEN-parse: calling _store_candidate_value"
  _store_candidate_value "${line}"
}

# The parser behind the pure LISTEN instance. bridge_ledger.py parses the
# output and books every telegram of a candidate that is already registered
# with the same driver and type, already announced and whose preview config
# would stay as it is; the loop after it runs what stays in bash, when asked:
# a new or changed candidate (emit_snippet_if_new, with the preview config and
# its states), SEARCH (search_cache_candidate) and decoded JSON. Fields are
# separated by 0x1F, which `read` does not treat as whitespace, so empty ones
# survive. python3 exits 0 only at the end of its input; any other exit is a
# crash and it is started again on the same input, losing at most the block
# being collected.
#
# write_status_json is a no-op in the loop: this subshell holds a stale
# snapshot of the parent's STATUS_* variables from fork time, so writing
# status.json here would clobber the decoded counter and last-seen state. The
# candidate TSV files, which the WebUI reads, are written as usual.
_listen_parse_stage() {
  # $1: "nonzero" (default, the parallel LISTEN instance) or "zero" (the main
  # instance's listen output while no meter is configured; see run_once).
  local official="${1:-nonzero}"
  # --name=value: a value starting with "-" must not read as an option.
  until python3 -u "${BRIDGE_LEDGER}" listen \
      --candidates-file="${STATUS_CANDIDATES_FILE}" \
      --seen-file="${STATUS_SEEN_FILE}" \
      --recent-raw-file="${STATUS_RECENT_RAW_FILE}" \
      --candidate-raw-file="${STATUS_CANDIDATE_RAW_FILE}" \
      --candidate-analysis-file="${STATUS_CANDIDATE_ANALYSIS_FILE}" \
      --snippet-file="${SNIPPET_STATE}" \
      --official-count-file="${STATUS_OFFICIAL_METERS_COUNT_FILE}" \
      --meter-dir="${METER_DIR}" \
      --preview-meter-dir="${PREVIEW_METER_DIR}" \
      --official="${official}" \
      --official-count-default="${OFFICIAL_METERS_COUNT:-0}" \
      --search-mode="${SEARCH_MODE:-false}" \
      --search-expected="${SEARCH_EXPECTED_VALUE_M3:-0}" \
      --loglevel="${LOGLEVEL:-}"; do
    sleep 1
  done | {
    # No status.json from this subshell (see above).
    # shellcheck disable=SC2329  # overrides the one status_candidate_seen calls
    write_status_json() { :; }
    while IFS=$'\x1f' read -r _act _a _b _c _d; do
      case "${_act}" in
        snippet) emit_snippet_if_new "${_a}" "${_b}" "${_c}" "${_d}" ;;
        search) search_cache_candidate "${_a}" "${_b}" "${_c}" ;;
        json) _process_listen_json_line "${_a}" ;;
      esac
    done
  }
}

# ────────────────────────────────────────────────────────────────────────
# Parallel LISTEN instance lifecycle — managed at the script level so it
# persists across run_once() restarts (soft reload picks up new meters
# without disturbing the always-on candidate stream).
# ────────────────────────────────────────────────────────────────────────
LISTEN_PID=""

start_listen_instance() {
  # Already running? Done.
  if [[ -n "${LISTEN_PID}" ]] && kill -0 "${LISTEN_PID}" 2>/dev/null; then
    return 0
  fi
  (
    # Pure LISTEN supervisor loop. LISTEN_METER_DIR stays empty forever: no
    # meter-preview files and no reload flag. If the pipeline exits naturally,
    # restart it after a short pause.
    while true; do
      _sub_t0="$(epoch_now)"
      # Enforce the invariant on every start, including upgrades from versions
      # that polluted LISTEN_METER_DIR with meter-preview-* files.
      rm -f "${LISTEN_METER_DIR}/meter-"* 2>/dev/null || true
      log_verbose "[DIAG] LISTEN supervisor: starting pure-listen pipeline (empty config dir=${LISTEN_METER_DIR})"
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
        | _listen_parse_stage nonzero &
      pipeline_pid=$!
      log_debug "[DIAG] LISTEN supervisor: pure-listen pipeline started (pid=${pipeline_pid})"
      wait "${pipeline_pid}" 2>/dev/null || true
      log_verbose "[DIAG] LISTEN supervisor: pure-listen pipeline stopped, restarting"
      # Base delay 1 s keeps healthy restarts snappy; _sub_reconnect_sleep backs
      # off exponentially when the pipeline dies instantly (e.g. rejected
      # credentials), instead of reconnecting 60×/min forever.
      _sub_reconnect_sleep "${_sub_t0}" 1
    done
  ) &
  LISTEN_PID=$!
  log "Parallel LISTEN instance started (pid=${LISTEN_PID}) — pure listen mode."
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

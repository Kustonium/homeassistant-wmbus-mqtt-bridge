status_add_event() {
  local level="$1"
  local message="$2"
  local now
  now="$(iso_now)"
  STATUS_LAST_EVENT="${message}"
  printf '%s	%s	%s
' "${now}" "${level}" "${message}" >> "${STATUS_EVENTS_FILE}" 2>/dev/null || true
  tail -n 40 "${STATUS_EVENTS_FILE}" > "${STATUS_EVENTS_FILE}.tmp" 2>/dev/null && mv "${STATUS_EVENTS_FILE}.tmp" "${STATUS_EVENTS_FILE}" 2>/dev/null || true
}

status_record_seen() {
  local id
  local kind="${2:-meter}"
  local ts last_ts
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  ts="$(epoch_now)"
  # Appended to, and cut back to the newest 5000 rows only once it holds more
  # than 6000 (SEEN_KEEP / SEEN_MAX in bridge_ledger.py, which takes the same
  # lock); its readers look at the newest 5000 rows only.
  (
    flock -x 9
    local rows _tmp
    read -r last_ts rows < <(awk -F '\t' -v id="${id}" -v kind="${kind}" '
      $1 == id && $2 == kind && $3 ~ /^[0-9]+$/ { last = $3 + 0 }
      END { print last + 0, NR + 0 }
    ' "${STATUS_SEEN_FILE}" 2>/dev/null || true)
    if [[ "${last_ts}" =~ ^[0-9]+$ ]] && (( last_ts > 0 && ts - last_ts < 2 )); then
      exit 0
    fi
    printf '%s\t%s\t%s\n' "${id}" "${kind}" "${ts}" >> "${STATUS_SEEN_FILE}" 2>/dev/null || true
    if [[ "${rows}" =~ ^[0-9]+$ ]] && (( rows + 1 > 6000 )); then
      _tmp="$(mktemp "${STATUS_SEEN_FILE}.tmp.XXXXXX")" || exit 0
      if ! { tail -n 5000 "${STATUS_SEEN_FILE}" > "${_tmp}" 2>/dev/null && mv "${_tmp}" "${STATUS_SEEN_FILE}" 2>/dev/null; }; then
        rm -f "${_tmp}"
      fi
    fi
  ) 9>"${STATUS_SEEN_FILE}.lock"
}

status_seen_stats() {
  local id
  local now
  # $2 (kind) is accepted for call-site compatibility but intentionally unused:
  # reception is now counted per meter id across ALL kinds (see awk below), so a
  # meter's stats stay continuous when it is promoted candidate -> meter.
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || { printf '0\t0\t0\t0\n'; return 0; }
  now="$(epoch_now)"

  # The file is read twice: the first pass counts its rows, the second looks
  # at the newest 5000 only (see status_record_seen).
  awk -F '\t' -v id="${id}" -v now="${now}" '
    NR == FNR { rows++; next }
    FNR <= rows - 5000 { next }
    $1 == id && $3 ~ /^[0-9]+$/ {
      ts = $3 + 0
      # Count by meter id across BOTH kinds (meter + candidate). The decode and
      # parallel-listen instances each log the same physical transmission within
      # ~2 s; collapse those so the count is not doubled and stays continuous
      # across the candidate->meter promotion (when the kind switches). Rows are
      # appended in real time so the matched stream is ascending; the ">= 0"
      # guard tolerates rare cross-process interleave.
      if (prev > 0 && ts - prev >= 0 && ts - prev < 2) next
      count++
      if (ts >= now - 900) seen15++
      if (ts >= now - 3600) seen60++
      if (prev > 0 && ts >= prev) {
        sum += ts - prev
        intervals++
      }
      prev = ts
    }
    END {
      if (intervals > 0) {
        avg = int((sum / intervals) + 0.5)
      } else {
        avg = 0
      }
      printf "%d\t%d\t%d\t%d\n", count + 0, avg + 0, seen15 + 0, seen60 + 0
    }
  ' "${STATUS_SEEN_FILE}" "${STATUS_SEEN_FILE}" 2>/dev/null || printf '0\t0\t0\t0\n'
}

status_read_raw_count() {
  local v
  v="$(cat "${STATUS_RAW_COUNT_FILE}" 2>/dev/null || echo "0")"
  [[ "${v}" =~ ^[0-9]+$ ]] || v=0
  echo "${v}"
}

status_read_last_raw_seen() {
  cat "${STATUS_LAST_RAW_FILE}" 2>/dev/null || true
}

status_find_recent_raw_for_id() {
  local id="$1"
  local le raw n=0
  le="$(id_to_le_hex "${id}")"
  [[ -n "${le}" ]] || return 1
  # bridge_ledger.py appends to the file and cuts it back to 200 rows only
  # above 400: the ring is the newest 200.
  tac "${STATUS_RECENT_RAW_FILE}" 2>/dev/null | while IFS=$'\t' read -r ts len raw; do
    (( ++n <= 200 )) || return 1
    # In-process lowercase: this loop can visit all 200 rows per telegram.
    raw="${raw,,}"
    if [[ "${raw}" == *"${le}"* ]]; then
      printf '%s\t%s\t%s\n' "${ts}" "${len}" "${raw}"
      return 0
    fi
  done
}

write_status_json() {
  local tmp="${STATUS_JSON}.tmp"
  # RAW is counted in a process-substitution/subshell created by tee.
  # Keep it in files too, otherwise later writes from the main shell
  # would overwrite raw_count back to 0.
  STATUS_RAW_COUNT="$(status_read_raw_count)"
  STATUS_LAST_RAW_SEEN="$(status_read_last_raw_seen)"
  # discovery_published is file-backed too (see STATUS_DISCOVERY_FLAG) so the
  # frequent raw-counter subshell can't clobber a 'true' set by the decode loop.
  local _disc_pub="${STATUS_DISCOVERY_PUBLISHED}" _disc_at="${STATUS_DISCOVERY_PUBLISHED_AT}"
  if [[ -s "${STATUS_DISCOVERY_FLAG}" ]]; then
    _disc_pub="true"
    _disc_at="$(head -n1 "${STATUS_DISCOVERY_FLAG}" 2>/dev/null || true)"
  fi
  jq -n     --arg updated_at "$(iso_now)"     --arg raw_topic "${RAW_TOPIC:-}"     --arg state_prefix "${STATE_PREFIX:-}"     --arg discovery_prefix "${DISCOVERY_PREFIX:-}"     --arg search_mode "${SEARCH_MODE:-false}"     --arg loglevel "${LOGLEVEL:-}"     --arg mqtt_host "${MQTT_HOST:-}"     --arg mqtt_port "${MQTT_PORT:-}"     --arg mqtt_connected "${STATUS_MQTT_CONNECTED}"     --arg wmbusmeters_running "${STATUS_WMBUSMETERS_RUNNING}"     --arg raw_count "${STATUS_RAW_COUNT}"     --arg decoded_count "${STATUS_DECODED_COUNT}"     --arg discovery_published "${_disc_pub}"     --arg discovery_published_at "${_disc_at}"     --arg last_raw_seen "${STATUS_LAST_RAW_SEEN}"     --arg last_decoded_seen "${STATUS_LAST_DECODED_SEEN}"     --arg last_error "${STATUS_LAST_ERROR}"     --arg last_event "${STATUS_LAST_EVENT}"     '{updated_at:$updated_at,
      config:{raw_topic:$raw_topic,state_prefix:$state_prefix,discovery_prefix:$discovery_prefix,search_mode:($search_mode=="true"),loglevel:$loglevel},
      mqtt:{host:$mqtt_host,port:$mqtt_port,connected:($mqtt_connected=="true")},
      pipeline:{raw_count:($raw_count|tonumber? // 0),decoded_count:($decoded_count|tonumber? // 0),wmbusmeters_running:($wmbusmeters_running=="true"),discovery_published:($discovery_published=="true"),discovery_published_at:$discovery_published_at,last_raw_seen:$last_raw_seen,last_decoded_seen:$last_decoded_seen,last_error:$last_error,last_event:$last_event}}'     > "${tmp}" 2>/dev/null && mv "${tmp}" "${STATUS_JSON}" 2>/dev/null || true
}

status_mark_discovery_published() {
  STATUS_DISCOVERY_PUBLISHED="true"
  STATUS_DISCOVERY_PUBLISHED_AT="$(iso_now)"
  # Persist to a file so the flag survives subshell isolation — every other
  # subshell's write_status_json reads it (see STATUS_DISCOVERY_FLAG). Without
  # this, the raw-counter subshell (stale STATUS_DISCOVERY_PUBLISHED=false)
  # overwrites status.json back to "pending" on every raw telegram.
  printf '%s\n' "${STATUS_DISCOVERY_PUBLISHED_AT}" > "${STATUS_DISCOVERY_FLAG}.tmp" 2>/dev/null \
    && mv "${STATUS_DISCOVERY_FLAG}.tmp" "${STATUS_DISCOVERY_FLAG}" 2>/dev/null || true
}


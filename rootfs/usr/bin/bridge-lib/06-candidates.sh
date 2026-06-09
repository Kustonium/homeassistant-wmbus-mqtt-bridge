# Write or update a per-candidate preview lifecycle state row.
# States: pending | decoded_value | decoded_without_numeric_value | no_decode_result
_set_preview_state() {
  local id="$1" state="$2" note="${3:-}"
  _tsv_upsert "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s' "${id}" "${state}" "$(iso_now)" "${note}")"
  # Discard the attempt counter once a terminal decode outcome is known.
  case "${state}" in
    decoded_value|decoded_without_numeric_value|no_decode_result)
      rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
      ;;
  esac
}

# Decode candidate previews without contaminating the always-on LISTEN instance.
# Each candidate RAW frame is decoded by a short-lived wmbusmeters process with a
# temporary config containing only that candidate. Per-ID locking and throttling
# keep dense RF environments from spawning a process storm.
_record_preview_no_decode_attempt() {
  local id="$1" cnt_file cnt=0 start=0 now elapsed tmp
  cnt_file="${BASE}/.preview_attempts/${id}"
  if [[ -f "${cnt_file}" ]]; then
    IFS=$'\t' read -r cnt start < "${cnt_file}" 2>/dev/null || true
    [[ "${cnt}" =~ ^[0-9]+$ ]] || cnt=0
    [[ "${start}" =~ ^[0-9]+$ ]] || start=0
  fi
  now="$(date +%s 2>/dev/null || echo 0)"
  (( start > 0 )) || start="${now}"
  cnt=$((cnt + 1))
  elapsed=$((now - start))
  tmp="$(mktemp "${cnt_file}.tmp.XXXXXX" 2>/dev/null)" || true
  if [[ -n "${tmp}" ]]; then
    printf '%d\t%d\n' "${cnt}" "${start}" > "${tmp}"
    mv "${tmp}" "${cnt_file}" 2>/dev/null || rm -f "${tmp}" 2>/dev/null || true
  fi
  if (( cnt >= 3 && elapsed >= 60 )); then
    log_verbose "[DIAG] preview one-shot ${id}: no JSON after ${cnt} attempts (${elapsed}s)"
    _set_preview_state "${id}" "no_decode_result"
  else
    log_debug "[DIAG] preview one-shot ${id}: no JSON attempt #${cnt} (elapsed=${elapsed}s)"
  fi
}

_preview_acquire_slot() {
  local max_parallel="${PREVIEW_DECODE_MAX_PARALLEL:-2}" n slot
  [[ "${max_parallel}" =~ ^[0-9]+$ ]] || max_parallel=2
  (( max_parallel > 0 )) || max_parallel=1
  mkdir -p "${BASE}/.preview_decode_slots" 2>/dev/null || true
  for (( n=1; n<=max_parallel; n++ )); do
    slot="${BASE}/.preview_decode_slots/${n}"
    if mkdir "${slot}" 2>/dev/null; then
      printf '%s\n' "${slot}"
      return 0
    fi
  done
  return 1
}

preview_decode_raw_if_requested() {
  local raw="${1:-}" id cfg lock_dir slot_dir last_file now last min_interval
  raw="$(printf '%s' "${raw}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  [[ "${raw}" =~ ^[0-9A-F]+$ ]] || return 0
  id="$(meter_id_from_raw_hex "${raw}")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  cfg="$(candidate_autodecode_file "${id}")"
  [[ -f "${cfg}" ]] || return 0

  mkdir -p "${BASE}/.preview_decode_locks" "${BASE}/.preview_decode_last" 2>/dev/null || true
  lock_dir="${BASE}/.preview_decode_locks/${id}"
  last_file="${BASE}/.preview_decode_last/${id}"
  min_interval="${PREVIEW_DECODE_MIN_INTERVAL_SECONDS:-20}"
  now="$(date +%s 2>/dev/null || echo 0)"
  last="$(cat "${last_file}" 2>/dev/null || echo 0)"
  [[ "${last}" =~ ^[0-9]+$ ]] || last=0
  if (( now - last < min_interval )); then
    return 0
  fi
  mkdir "${lock_dir}" 2>/dev/null || return 0
  slot_dir="$(_preview_acquire_slot || true)"
  if [[ -z "${slot_dir}" ]]; then
    rmdir "${lock_dir}" 2>/dev/null || true
    return 0
  fi
  printf '%s\n' "${now}" > "${last_file}" 2>/dev/null || true

  (
    local tmp_base tmp_meter_dir output json_line
    # Prevent stale status.json writes from this detached helper process.
    write_status_json() { :; }
    tmp_base="$(mktemp -d "${BASE}/.preview_decode.${id}.XXXXXX" 2>/dev/null)" || {
      rmdir "${slot_dir}" 2>/dev/null || true
      rmdir "${lock_dir}" 2>/dev/null || true
      exit 0
    }
    tmp_meter_dir="${tmp_base}/etc/wmbusmeters.d"
    mkdir -p "${tmp_meter_dir}" 2>/dev/null || true
    cat > "${tmp_base}/etc/wmbusmeters.conf" <<EOFONESHOT
loglevel=${LOGLEVEL}
device=stdin:hex
logfile=/dev/stdout
format=json
EOFONESHOT
    cp "${cfg}" "${tmp_meter_dir}/meter-preview-${id}" 2>/dev/null || true
    output="$(printf '%s\n' "${raw}" | /usr/bin/wmbusmeters --useconfig="${tmp_base}" 2>&1 || true)"
    json_line="$(printf '%s\n' "${output}" | awk '/^\{.*"_":"telegram"/ { print; exit }')"
    if [[ -n "${json_line}" ]]; then
      log_debug "[DIAG] preview one-shot ${id}: decoded JSON"
      status_candidate_seen_from_json "${json_line}"
      _store_candidate_value "${json_line}"
    else
      _record_preview_no_decode_attempt "${id}"
    fi
    rm -rf "${tmp_base}" 2>/dev/null || true
    rmdir "${slot_dir}" 2>/dev/null || true
    rmdir "${lock_dir}" 2>/dev/null || true
  ) &
}

status_upsert_candidate_analysis() {
  local id
  local encryption="$2"
  local note="$3"
  local ci="${4:-}"
  local security="${5:-}"
  local raw_len="${6:-0}"
  local last_seen="${7:-}"

  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${last_seen}" ]] || last_seen="$(iso_now)"

  _tsv_upsert "${STATUS_CANDIDATE_ANALYSIS_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "${id}" "${encryption:-unknown}" "${note:-}" "${ci:-}" "${security:-}" "${raw_len:-0}" "${last_seen}")"
}

candidate_autodecode_file() {
  local id="$1"
  printf '%s/meter-preview-%s' "${PREVIEW_METER_DIR}" "${id}"
}

candidate_type_requires_aes() {
  local type_lc
  type_lc="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ "${type_lc}" == *not\ encrypted* || "${type_lc}" == *unencrypted* || "${type_lc}" == *no\ aes* || "${type_lc}" == *no_aes* ]] && return 1
  [[ "${type_lc}" == *encrypted* || "${type_lc}" == *aes* ]]
}

ensure_candidate_autodecode() {
  local id
  local driver="${2:-auto}"
  local type_line="${3:-}"
  local reload="${4:-true}"
  : "${reload}"  # retained for caller compatibility; LISTEN is never reloaded
  local file tmp

  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  file="$(candidate_autodecode_file "${id}")"

  # Skip preview for officially configured meters — they decode via the primary pipeline.
  # Checked via METER_DIR on disk so the guard works in LISTEN subshell forks where
  # in-memory variables from the parent process are stale after a soft pipeline reload.
  if grep -ql "^id=${id,,}$" "${METER_DIR}"/meter-* 2>/dev/null; then
    if [[ -f "${file}" ]]; then
      rm -f "${file}" 2>/dev/null || true
      rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
      log "autodecode ${id}: skipped (official meter), pruned orphaned preview"
    fi
    return 0
  fi

  log_debug "[DIAG] autodecode ${id}: file=${file} driver=${driver:-auto} type=${type_line:-?} reload=${reload}"

  if candidate_type_requires_aes "${type_line}"; then
    log_verbose "[DIAG] autodecode ${id}: AES required, skipping preview"
    if [[ -f "${file}" ]]; then
      rm -f "${file}" 2>/dev/null || true
      rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
    fi
    return 0
  fi

  mkdir -p "${PREVIEW_METER_DIR}" 2>/dev/null || true
  tmp="${file}.tmp"
  {
    echo "name=preview_${id}"
    echo "id=${id,,}"
    if [[ -n "${driver}" && "${driver}" != "auto" && "${driver}" != "unknown" ]]; then
      echo "driver=${driver}"
    fi
  } > "${tmp}" 2>/dev/null || return 0

  if [[ ! -f "${file}" ]] || ! cmp -s "${tmp}" "${file}" 2>/dev/null; then
    mv "${tmp}" "${file}" 2>/dev/null || true
    log_verbose "[DIAG] autodecode ${id}: wrote ${file} (driver=${driver:-auto})"
    _set_preview_state "${id}" "pending"
    rm -f "${BASE}/.preview_attempts/${id}" 2>/dev/null || true
    # Do not reload LISTEN here. Preview configs are consumed by the one-shot
    # decoder, while the always-on LISTEN pipeline stays permanently pure.
    local _recent_row _recent_raw
    _recent_row="$(status_find_recent_raw_for_id "${id}" || true)"
    if [[ -n "${_recent_row}" ]]; then
      IFS=$'\t' read -r _ _ _recent_raw <<< "${_recent_row}"
      [[ -n "${_recent_raw}" ]] && preview_decode_raw_if_requested "${_recent_raw}"
    fi
  else
    rm -f "${tmp}" 2>/dev/null || true
    log_debug "[DIAG] autodecode ${id}: ${file} unchanged, no reload triggered"
  fi
}

sync_candidate_autodecode_files() {
  local id driver type_line rest
  [[ -f "${STATUS_CANDIDATES_FILE}" ]] || return 0
  while IFS=$'\t' read -r id driver type_line rest; do
    id="$(normalize_meter_id "${id}")"
    [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || continue
    ensure_candidate_autodecode "${id}" "${driver:-auto}" "${type_line:-}" "false"
  done < "${STATUS_CANDIDATES_FILE}"
}

# Remove preview files for IDs that are now official configured meters.
# Preview files live under PREVIEW_METER_DIR and are consumed by one-shot decoders;
# the always-on LISTEN directory remains empty.
prune_official_meter_previews() {
  local mid pf _pruned=0
  [[ -d "${METER_DIR}" ]] || return 0
  for mf in "${METER_DIR}"/meter-*; do
    [[ -f "${mf}" ]] || continue
    mid="$(grep -m1 '^id=' "${mf}" | cut -d= -f2 | tr '[:lower:]' '[:upper:]')"
    [[ "${mid}" =~ ^[0-9A-Fa-f]{8}$ ]] || continue
    pf="${PREVIEW_METER_DIR}/meter-preview-${mid}"
    if [[ -f "${pf}" ]]; then
      rm -f "${pf}" 2>/dev/null || true
      rm -f "${BASE}/.preview_attempts/${mid}" 2>/dev/null || true
      log "pruned orphaned meter-preview-${mid} (now official configured meter)"
      _pruned=1
    fi
  done
  : "${_pruned}"  # preview files are one-shot inputs; LISTEN never reloads
}

# Physically remove candidate rows whose last telegram (column 4, ISO last_seen)
# is older than CANDIDATE_PRUNE_AFTER_SECONDS (default 24h). This is the bridge-side
# counterpart to the WebUI's 24h display freshness filter: until now the row only
# got HIDDEN, so it lingered in status_candidates.tsv and reappeared on every
# refresh. A long-silent candidate ("hanging", 0/0 reception) now self-deletes.
#
# A new telegram from the same ID later simply re-creates the candidate via
# status_candidate_seen() — pruning a quiet meter does not blacklist it.
#
# last_seen is ISO-8601 (date -Iseconds, e.g. 2026-06-09T11:35:00+02:00). busybox
# date cannot reliably parse that back to epoch, so python3 (already a runtime
# dependency) does the age comparison and rewrites the file under the same flock.
# Per-ID side state (preview value/state, attempt counter, preview config) is then
# cleaned to match the WebUI's _cleanup_preview_cache, so no orphan rows remain.
prune_stale_candidates() {
  local file="${STATUS_CANDIDATES_FILE}"
  local max_age="${CANDIDATE_PRUNE_AFTER_SECONDS:-86400}"
  [[ -f "${file}" ]] || return 0
  [[ "${max_age}" =~ ^[0-9]+$ ]] || max_age=86400
  command -v python3 >/dev/null 2>&1 || return 0

  local _dropped
  _dropped="$( (
    flock -x 9
    _tmp="$(mktemp "${file}.tmp.XXXXXX")" || exit 1
    if ! python3 - "${file}" "${_tmp}" "${max_age}" <<'PYEOF'
import sys, datetime
src, dst, max_age = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = datetime.datetime.now(datetime.timezone.utc)

def parse(ts):
    ts = ts.strip()
    if not ts:
        return None
    try:
        d = datetime.datetime.fromisoformat(ts)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return d

dropped = []
with open(src, "r", encoding="utf-8", errors="replace") as f, \
     open(dst, "w", encoding="utf-8") as out:
    for line in f:
        row = line.rstrip("\n")
        if not row:
            continue
        cols = row.split("\t")
        d = parse(cols[3]) if len(cols) >= 4 else None
        if d is not None and (now - d).total_seconds() > max_age:
            dropped.append(cols[0])
        else:
            out.write(row + "\n")
sys.stdout.write("\n".join(dropped))
PYEOF
    then
      rm -f "${_tmp}"
      exit 1
    fi
    mv "${_tmp}" "${file}" 2>/dev/null || { rm -f "${_tmp}"; exit 1; }
  ) 9>"${file}.lock" )" || return 0

  [[ -n "${_dropped}" ]] || return 0
  local _id
  while IFS= read -r _id; do
    _id="$(normalize_meter_id "${_id}")"
    [[ "${_id}" =~ ^[0-9A-Fa-f]{8}$ ]] || continue
    _tsv_remove_id "${STATUS_CANDIDATE_VALUES_FILE}" "${_id}"
    _tsv_remove_id "${STATUS_CANDIDATE_PREVIEW_STATE_FILE}" "${_id}"
    rm -f "${BASE}/.preview_attempts/${_id}" 2>/dev/null || true
    rm -f "${PREVIEW_METER_DIR}/meter-preview-${_id}" 2>/dev/null || true
    log "pruned stale candidate ${_id} (no telegram for >$((max_age / 3600))h)"
  done <<< "${_dropped}"
}

status_record_candidate_raw() {
  local id
  local raw="$2"
  local ts="${3:-}"
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${raw}" ]] || return 0
  [[ -n "${ts}" ]] || ts="$(iso_now)"

  _tsv_upsert "${STATUS_CANDIDATE_RAW_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s' "${id}" "${ts}" "${#raw}" "${raw}")"
}

status_analyze_candidate_from_text() {
  local id
  local driver="${2:-auto}"
  local type_line="${3:-}"
  local type_lc raw_row raw_ts raw_len raw ci encryption note security

  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  type_lc="$(echo "${type_line}" | tr '[:upper:]' '[:lower:]')"

  raw_row="$(status_find_recent_raw_for_id "${id}" || true)"
  raw_ts=""
  raw_len="0"
  raw=""
  if [[ -n "${raw_row}" ]]; then
    IFS=$'\t' read -r raw_ts raw_len raw <<< "${raw_row}"
    status_record_candidate_raw "${id}" "${raw}" "${raw_ts}"
    # Best-effort CI position for normal wM-Bus DLL frames:
    # L(1), C(1), M(2), A/id+ver+type(6), CI(1) => byte offset 10 => hex offset 20.
    # This is metadata only. AES decision below does NOT rely on this guess.
    if [[ "${#raw}" -ge 22 ]]; then
      ci="${raw:20:2}"
    else
      ci=""
    fi
  else
    ci=""
  fi

  security=""

  # Do not guess encryption from driver. Only use explicit backend evidence:
  # 1) wmbusmeters/listen text explicitly says encrypted/AES,
  # 2) process_search_json marks a temporary no-key search meter as decoded.
  if candidate_type_requires_aes "${type_line}"; then
    encryption="aes_required"
    note="wmbusmeters/listen output explicitly reports encrypted/AES telegram"
  elif [[ -n "${raw}" ]]; then
    encryption="unknown"
    note="RAW was mapped to this candidate, but no backend security parser has classified AES yet"
  else
    encryption="unknown"
    note="No RAW/security analysis mapped to this candidate yet"
  fi

  status_upsert_candidate_analysis "${id}" "${encryption}" "${note}" "${ci}" "${security}" "${raw_len}" "$(iso_now)"
}

# shellcheck disable=SC2034
status_mark_search_decoded_no_aes() {
  local json_line="$1"
  local id meter media field
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  # Search temporary meters are created without key=. If wmbusmeters decodes
  # numeric JSON from such a meter, then no AES key was required for that telegram.
  if is_search_temp_json "${json_line}"; then
    meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
    media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
    field="$(jq -r 'to_entries[] | select((.value|type)=="number") | .key' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
    status_upsert_candidate_analysis "${id}" "no_aes" "Temporary SEARCH meter decoded without key; no AES key was required for this telegram" "" "" "0" "$(iso_now)"
  fi
}

# Update the manufacturer column (9) of an EXISTING candidate row to the full
# text form captured by the LISTEN text path (e.g. "(NES) NORA ELK MALZ SAN ve TIC").
# Called from _process_listen_text_block BEFORE the driver guard so that
# manufacturer is recorded even when wmbusmeters omits the driver: line
# (e.g. for encrypted telegrams that can't be decrypted without the AES key).
# Only writes when column 9 is empty or holds a legacy bare 3-letter code;
# an existing full-text name is left untouched.
# Never creates rows, never touches reception stats or events.
candidate_update_manufacturer_text() {
  local _id="$1" _mfr="$2"
  [[ "${_id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${_mfr}" ]] || return 0
  local _file="${STATUS_CANDIDATES_FILE}"
  [[ -f "${_file}" ]] || return 0
  # Cheap lock-free pre-check: only take the lock when a fillable row exists.
  awk -F '\t' -v id="${_id}" \
    '$1 == id && (NF < 9 || $9 == "" || ($9 ~ /^[A-Z]{3}$/)) { found = 1 } END { exit found ? 0 : 1 }' \
    "${_file}" 2>/dev/null || return 0
  (
    flock -x 9
    local _tmp
    _tmp="$(mktemp "${_file}.tmp.XXXXXX")" || return 1
    if ! awk -F $'\t' -v OFS=$'\t' -v id="${_id}" -v mfr="${_mfr}" '
        $1 == id {
          while (NF < 9) { $(NF + 1) = "" }
          if ($9 == "" || ($9 ~ /^[A-Z]{3}$/)) { $9 = mfr }
        }
        { print }
      ' "${_file}" > "${_tmp}"; then
      rm -f "${_tmp}"
      return 1
    fi
    if ! mv "${_tmp}" "${_file}"; then
      rm -f "${_tmp}"
      return 1
    fi
    log_debug "[DIAG] candidate ${_id}: updated manufacturer text from LISTEN block to ${_mfr}"
  ) 9>"${STATUS_CANDIDATES_FILE}.lock"
}

# shellcheck disable=SC2034
status_candidate_seen() {
  local id
  local driver="${2:-auto}"
  local type_line="${3:-}"
  local update_status="${4:-true}"
  local manufacturer="${5:-}"
  # reload controls whether a changed meter-preview-<id> file triggers an
  # immediate parallel LISTEN reload. Defaults to true for the text/RAW callers.
  # The decoded-JSON path (status_candidate_seen_from_json) passes false: a
  # candidate that just produced JSON is already decoding fine, so relabelling
  # its driver auto -> <real driver> must NOT kill+restart the LISTEN pipeline
  # on every telegram (reload churn that left previews stuck on "decoding...").
  local reload="${6:-true}"
  local now
  STATUS_WMBUSMETERS_RUNNING="true"
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  local existed="false"
  if grep -q "^${id}	" "${STATUS_CANDIDATES_FILE}" 2>/dev/null; then
    existed="true"
  fi
  status_record_seen "${id}" "candidate"
  now="$(iso_now)"
  IFS=$'\t' read -r seen_count avg_interval_s seen_15m seen_60m < <(status_seen_stats "${id}" "candidate")
  _upsert_candidate_row "${id}" "${driver}" "${type_line}" "${now}" "${seen_count}" "${avg_interval_s}" "${seen_15m}" "${seen_60m}" "${manufacturer}"
  status_analyze_candidate_from_text "${id}" "${driver}" "${type_line}"
  ensure_candidate_autodecode "${id}" "${driver:-auto}" "${type_line:-}" "${reload}"
  if [[ "${existed}" != "true" ]]; then
    status_add_event "candidate" "Candidate detected ${id} (${driver})"
  fi
  [[ "${update_status}" == "true" ]] && write_status_json
}

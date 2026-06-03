#!/usr/bin/env bash

id_to_le_hex() {
  local id
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || { echo ""; return 0; }
  echo "${id:6:2}${id:4:2}${id:2:2}${id:0:2}" | tr '[:upper:]' '[:lower:]'
}

status_raw_seen() {
  local raw="${1:-}"
  # If a RAW telegram arrived from mosquitto_sub, MQTT and the input pipeline
  # are alive even if no configured meter JSON has been decoded yet.
  # shellcheck disable=SC2034
  STATUS_MQTT_CONNECTED="true"
  # shellcheck disable=SC2034
  STATUS_WMBUSMETERS_RUNNING="true"
  status_store_raw_seen "$(iso_now)"
  status_store_recent_raw "${raw}"
  status_raw_candidate_seen "${raw}"
  if (( STATUS_RAW_COUNT == 1 || STATUS_RAW_COUNT % 25 == 0 )); then
    status_add_event "ok" "RAW telegram received (${#raw} hex chars)"
  fi

  # Per-minute rate tracking for the WebGUI live dashboard.
  # Telegrams arriving within the same 60-second bucket increment current_min.
  # When the minute turns, current_min is rotated into prev_min and reset to 1.
  local _now_epoch _cur_min
  _now_epoch="$(epoch_now)"
  _cur_min=$(( _now_epoch / 60 ))
  if [[ "${RAW_RATE_CUR_MIN_EPOCH}" -ne "${_cur_min}" ]]; then
    # Minute boundary crossed: archive the finished minute's count into the
    # 15-entry rolling history (skip when there was no previous minute yet —
    # RAW_RATE_CUR_MIN_EPOCH==0 means this is the very first telegram). The
    # _prev_min epoch lets the WebGUI place each bar correctly on the axis.
    if [[ "${RAW_RATE_CUR_MIN_EPOCH}" -ne 0 ]]; then
      local _hist_tmp="${STATUS_RATE_HISTORY_FILE}.tmp"
      {
        tail -n 14 "${STATUS_RATE_HISTORY_FILE}" 2>/dev/null || true
        printf '%d\t%d\n' "${RAW_RATE_CUR_MIN_EPOCH}" "${RAW_RATE_CUR_MIN_COUNT}"
      } > "${_hist_tmp}" 2>/dev/null \
        && mv "${_hist_tmp}" "${STATUS_RATE_HISTORY_FILE}" 2>/dev/null || true
    fi
    RAW_RATE_PREV_MIN_COUNT="${RAW_RATE_CUR_MIN_COUNT}"
    RAW_RATE_CUR_MIN_COUNT=1
    RAW_RATE_CUR_MIN_EPOCH="${_cur_min}"
  else
    RAW_RATE_CUR_MIN_COUNT=$(( RAW_RATE_CUR_MIN_COUNT + 1 ))
  fi
  printf '{"current_min":%d,"prev_min":%d,"epoch":%d}\n' \
    "${RAW_RATE_CUR_MIN_COUNT}" "${RAW_RATE_PREV_MIN_COUNT}" "${_now_epoch}" \
    > "${STATUS_RATE_1M_FILE}.tmp" 2>/dev/null \
    && mv "${STATUS_RATE_1M_FILE}.tmp" "${STATUS_RATE_1M_FILE}" 2>/dev/null || true

  write_status_json
}

meter_id_from_raw_hex() {
  local raw="$1"
  local byte_count lfield id_le

  [[ "${raw}" =~ ^[0-9A-F]+$ ]] || { echo ""; return 0; }
  [[ "${#raw}" -ge 22 ]] || { echo ""; return 0; }
  (( ${#raw} % 2 == 0 )) || { echo ""; return 0; }

  byte_count=$(( ${#raw} / 2 ))
  lfield=$((16#${raw:0:2}))
  [[ "${lfield}" -eq $((byte_count - 1)) ]] || { echo ""; return 0; }

  # wMBus A-field stores the 4-byte meter ID little-endian after L/C/M-field.
  id_le="${raw:8:8}"
  echo "${id_le:6:2}${id_le:4:2}${id_le:2:2}${id_le:0:2}"
}

# Decode the 3-letter EN 13757 manufacturer code from a raw wMBus telegram.
# Frame layout (hex chars): L=0:2 C=2:4 M=4:8 A=8:20. The 2-byte M-field is
# little-endian; the 16-bit value packs three 5-bit letters (1..26 -> A..Z):
#   value = (L1<<10) | (L2<<5) | L3 , letter = code + 64.
# Returns the 3-letter code (e.g. "SAP", "DME") or "" when the field does not
# decode to three A..Z letters. Used only as a manufacturer fallback when the
# full wmbusmeters text name is not available (JSON-only candidate path).
mfct_code_from_raw_hex() {
  local raw="$1" m val l1 l2 l3
  raw="${raw//[[:space:]]/}"
  [[ "${#raw}" -ge 8 ]] || { echo ""; return 0; }
  m="${raw:4:4}"
  [[ "${m}" =~ ^[0-9A-Fa-f]{4}$ ]] || { echo ""; return 0; }
  # Byte-swap (little-endian) to get the 16-bit manufacturer value.
  val=$(( 16#${m:2:2}${m:0:2} ))
  l1=$(( (val >> 10) & 0x1f ))
  l2=$(( (val >> 5) & 0x1f ))
  l3=$(( val & 0x1f ))
  (( l1 >= 1 && l1 <= 26 && l2 >= 1 && l2 <= 26 && l3 >= 1 && l3 <= 26 )) \
    || { echo ""; return 0; }
  awk -v a="$((l1 + 64))" -v b="$((l2 + 64))" -v c="$((l3 + 64))" \
    'BEGIN { printf "%c%c%c", a, b, c }'
}

# Fallback fill of the manufacturer column (9) for an EXISTING candidate row
# whose manufacturer is still empty. Deliberately conservative:
#   - never creates a row (would spawn a phantom candidate for an official meter),
#   - only writes when column 9 is empty, so the richer full-text name captured
#     by the LISTEN text path (e.g. "DME ...") is never downgraded to the bare
#     code, and a later text update still overwrites the code via
#     _upsert_candidate_row,
#   - touches no reception stats and emits no events (no double counting).
candidate_fill_manufacturer_code() {
  local _id="$1" _code="$2"
  [[ "${_id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${_code}" ]] || return 0
  local _file="${STATUS_CANDIDATES_FILE}"
  [[ -f "${_file}" ]] || return 0
  # Cheap lock-free pre-check: only take the lock when a fillable row exists.
  awk -F '\t' -v id="${_id}" \
    '$1 == id && (NF < 9 || $9 == "") { found = 1 } END { exit found ? 0 : 1 }' \
    "${_file}" 2>/dev/null || return 0
  (
    flock -x 9
    local _tmp
    _tmp="$(mktemp "${_file}.tmp.XXXXXX")" || return 1
    if ! awk -F $'\t' -v OFS=$'\t' -v id="${_id}" -v code="${_code}" '
        $1 == id {
          while (NF < 9) { $(NF + 1) = "" }
          if ($9 == "") { $9 = code }
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
    log_debug "[DIAG] candidate ${_id}: filled manufacturer fallback code=${_code}"
  ) 9>"${STATUS_CANDIDATES_FILE}.lock"
}

# Map an OMS device-type byte (A/TYPE, raw[18:20]) to a human label. Covers the
# device types seen in practice plus a safe fallback — no need for a full
# 0x00-0xFF table.
map_device_type() {
  local dt="${1^^}"
  case "${dt}" in
    02) echo "Electricity meter (0x02)" ;;
    03) echo "Gas meter (0x03)" ;;
    04) echo "Heat meter (0x04)" ;;
    06) echo "Warm water meter (0x06)" ;;
    07) echo "Water meter (0x07)" ;;
    08) echo "Heat Cost Allocator (0x08)" ;;
    0C) echo "Heat meter inlet (0x0C)" ;;
    16) echo "Cold water meter (0x16)" ;;
    *)  printf 'Unknown meter type (0x%s)' "${dt}" ;;
  esac
}

status_raw_candidate_seen() {
  local raw="$1"
  local id mfr dev_type existing_driver

  raw="$(echo "${raw}" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"
  id="$(meter_id_from_raw_hex "${raw}")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  # Manufacturer fallback: every raw telegram carries the M-field, so decode the
  # EN 13757 3-letter code and fill it into an existing candidate row that has no
  # manufacturer yet. This heals candidates whose only updates arrive via the
  # JSON path (a meter-preview-<id> file makes the parallel LISTEN decode the
  # telegram to JSON, which carries no manufacturer text), independent of LISTEN
  # reloads. Fill-only-when-empty keeps the full text name from the LISTEN text
  # path authoritative. Does NOT create rows or touch stats.
  local _mfct_code
  _mfct_code="$(mfct_code_from_raw_hex "${raw}")"
  [[ -n "${_mfct_code}" ]] && candidate_fill_manufacturer_code "${id}" "${_mfct_code}"

  # This runs on EVERY raw telegram (status_raw_seen) and OVERWRITES the
  # candidate row. Only register straight from the link-layer A-field for
  # Diehl/SAP IZAR (mfct 0x304C), which sometimes does NOT surface as a
  # wmbusmeters listen candidate. For every other manufacturer the normal
  # listen/decode path already provides the candidate WITH its real
  # driver/media — emitting a generic "auto / wMBus telegram" row here would
  # clobber that real classification on every raw telegram (the "auto / inne"
  # bug).
  mfr="${raw:4:4}"
  [[ "${mfr}" == "304C" ]] || return 0

  # Hard priority: a real LISTEN classification beats this RAW fallback. Without
  # this guard the fallback re-runs on every SAP telegram and keeps clobbering a
  # driver that LISTEN already resolved (e.g. non-water Diehl flapping
  # auto -> sharky -> auto). If the candidate already has a concrete driver
  # (anything other than "auto"), leave the existing row untouched.
  existing_driver="$(
    awk -F '\t' -v id="${id}" '
      $1 == id { print $2; exit }
    ' "${STATUS_CANDIDATES_FILE}" 2>/dev/null || true
  )"
  if [[ -n "${existing_driver}" && "${existing_driver}" != "auto" ]]; then
    return 0
  fi

  # A/TYPE = raw[18:20]. Diehl/SAP water (0x07) keeps the izarv2 fallback exactly
  # as before. Any other device type registers as auto + mapped label so we never
  # force izarv2 on non-water Diehl and LISTEN can later supply the real driver.
  dev_type="${raw:18:2}"
  if [[ "${dev_type}" == "07" ]]; then
    status_candidate_seen "${id}" "izarv2" "Water meter (0x07)" "false"
  else
    status_candidate_seen "${id}" "auto" "$(map_device_type "${dev_type}")" "false"
  fi
}

normalize_meter_id() {
  local mid_raw="$1"
  mid_raw="$(echo "${mid_raw}" | tr -d '[:space:]')"
  [[ -z "${mid_raw}" || "${mid_raw}" == "null" ]] && { echo ""; return 0; }

  mid_raw="${mid_raw#0x}"
  mid_raw="${mid_raw#0X}"
  mid_raw="$(echo "${mid_raw}" | tr '[:lower:]' '[:upper:]')"

  [[ "${mid_raw}" =~ ^[0-9A-F]+$ ]] || { echo ""; return 0; }

  if [[ "${#mid_raw}" -lt 8 ]]; then
    printf "%8s" "${mid_raw}" | tr ' ' '0'
  elif [[ "${#mid_raw}" -gt 8 ]]; then
    meter_id_from_raw_hex "${mid_raw}"
  else
    echo "${mid_raw}"
  fi
}

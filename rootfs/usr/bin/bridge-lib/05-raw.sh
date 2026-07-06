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
  # Live traffic proves the credentials work — clear the broker-error marker
  # (guarded by -s so this hot path normally does zero writes).
  if [[ -s "${STATUS_BROKER_ERROR_FILE}" ]]; then
    : > "${STATUS_BROKER_ERROR_FILE}" 2>/dev/null || true
  fi
  # shellcheck disable=SC2034
  STATUS_WMBUSMETERS_RUNNING="true"
  status_store_raw_seen "$(iso_now)"
  status_store_recent_raw "${raw}"
  status_raw_candidate_seen "${raw}"
  # Preview decoding is deliberately separate from the always-on LISTEN
  # pipeline. If this RAW belongs to a candidate with a preview config, schedule
  # a throttled one-shot decode without blocking the RAW counter path.
  preview_decode_raw_if_requested "${raw}"
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

# Map a 3-letter EN 13757 FLAG manufacturer code to the full "(CODE) Vendor"
# string (same shape the LISTEN text path stores, so the WebGUI compactor renders
# e.g. "BMT · BMETERS"). This is the only way to get the full vendor name for a
# meter configured while another meter is already configured: in that mode the
# parallel LISTEN is loaded with preview files, leaves "print all" mode, and never
# emits the "manufacturer:" text block — so only the bare M-field code is known
# (see docs/CLAUDE_HANDOFF.md). Only codes confirmed from real telegrams are
# mapped; unknown codes return empty so the caller keeps the bare 3-letter code
# (no regression). Extend the case list as new vendors are seen in the wild.
mfct_name_from_code() {
  case "$1" in
    BMT) echo "(BMT) BMETERS" ;;
    NES) echo "(NES) NORA ELK MALZ SAN ve TIC" ;;
    SAP) echo "(SAP) Diehl Metering" ;;
    QDS) echo "(QDS) Qundis" ;;
    TCH) echo "(TCH) Techem" ;;
    *)   echo "" ;;
  esac
}

# Fallback fill of the manufacturer column (9) for an EXISTING candidate row
# whose manufacturer is empty or contains only a bare 3-letter EN 13757 code
# left by a pre-1.5.22 installation (upgrade path). Deliberately conservative:
#   - never creates a row (would spawn a phantom candidate for an official meter),
#   - only writes when column 9 is empty or a bare 3-letter code; the richer
#     full-text name captured by the LISTEN text path (e.g. "(NES) NORA ELK...")
#     is never downgraded — it does not match /^[A-Z]{3}$/ so is left untouched,
#   - touches no reception stats and emits no events (no double counting).
candidate_fill_manufacturer_code() {
  local _id="$1" _code="$2"
  [[ "${_id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${_code}" ]] || return 0
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
    if ! awk -F $'\t' -v OFS=$'\t' -v id="${_id}" -v code="${_code}" '
        $1 == id {
          while (NF < 9) { $(NF + 1) = "" }
          if ($9 == "" || ($9 ~ /^[A-Z]{3}$/)) { $9 = code }
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

# Heuristic AES detection straight from the raw frame, for candidates registered
# by the RAW path (where wmbusmeters' "encrypted" text is unavailable in DECODE
# mode). Only the common short TPL header (CI=0x7A) is decoded: after the 10-byte
# DLL the layout is CI(1) ACC(1) STS(1) CFG(2); a non-zero CFG security-mode
# nibble means the telegram is encrypted. Any other CI returns "not encrypted"
# (falls back to the device-type label / existing classification), so we never
# false-positive a non-0x7A meter. Returns 0 (true) when encrypted.
raw_is_encrypted() {
  local r="${1//[[:space:]]/}" ci cfg_hi mode
  r="${r^^}"
  [[ "${#r}" -ge 30 ]] || return 1
  ci="${r:20:2}"
  [[ "${ci}" == "7A" ]] || return 1
  cfg_hi="${r:28:2}"                       # high byte of the little-endian CFG word
  [[ "${cfg_hi}" =~ ^[0-9A-F]{2}$ ]] || return 1
  mode=$(( 16#${cfg_hi} & 0x1f ))          # CFG security mode: 0 = none, else AES
  (( mode != 0 ))
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
  local _mfct_code _mfct_full
  _mfct_code="$(mfct_code_from_raw_hex "${raw}")"
  if [[ -n "${_mfct_code}" ]]; then
    # Prefer the full "(CODE) Vendor" form when the code is known, so meters
    # discovered in DECODE mode (no LISTEN text block) still get a full name and
    # not just the bare 3-letter code. Unknown codes fall back to the bare code.
    _mfct_full="$(mfct_name_from_code "${_mfct_code}")"
    candidate_fill_manufacturer_code "${id}" "${_mfct_full:-${_mfct_code}}"
  fi

  # This runs on EVERY raw telegram (status_raw_seen). In pure LISTEN mode (no
  # official meters) the run_once inline parser already registers every candidate
  # with its real driver/media from wmbusmeters listen output, so RAW only needs
  # the Diehl/SAP IZAR special case (mfct 0x304C), which sometimes does NOT
  # surface as a listen candidate. Registering other manufacturers here in that
  # mode would clobber the real classification on every raw telegram (the
  # "auto / inne" bug).
  #
  # The secondary LISTEN pipeline is kept permanently pure (empty config dir),
  # so it continues to discover all normal telegrams even after official meters
  # are configured. RAW fallback is therefore needed only for the Diehl/SAP IZAR
  # special case (M-field 0x304C), which may not surface as a listen candidate.
  mfr="${raw:4:4}"
  [[ "${mfr}" == "304C" ]] || return 0

  # Hard priority: a real LISTEN classification beats this RAW fallback. Without
  # this guard the fallback re-runs on every SAP telegram and keeps clobbering a
  # driver that LISTEN already resolved (e.g. non-water Diehl flapping
  # auto -> sharky -> auto). If the candidate already has a concrete driver
  # (anything other than "auto"), leave the existing row untouched.
  local existing_type=""
  IFS=$'\t' read -r existing_driver existing_type < <(
    awk -F '\t' -v id="${id}" '$1 == id { print $2 "\t" $3; exit }' "${STATUS_CANDIDATES_FILE}" 2>/dev/null || true
  )
  if [[ -n "${existing_driver}" && "${existing_driver}" != "auto" ]]; then
    return 0
  fi
  # Never downgrade an encrypted classification. Only the LISTEN text path, the
  # decoded JSON, or the TPL layer can tell a meter is AES — the bare device-type
  # label cannot. Dropping the "encrypted" marker would make
  # candidate_type_requires_aes stop matching, so a preview would be wrongly
  # created for an AES meter and the candidate would sit on "decoding..." forever
  # instead of showing "requires AES".
  if printf '%s' "${existing_type}" | grep -qiE 'encrypted|(^|[^a-z])aes([^a-z]|$)'; then
    return 0
  fi

  # A/TYPE = raw[18:20]. Only Diehl/SAP water (0x07) keeps the izarv2 fallback;
  # every other manufacturer (now reachable when meters are configured) registers
  # as auto + a mapped device-type label, so we never mislabel e.g. a QDS/BMETERS
  # water meter (also type 0x07) as izarv2 — the LISTEN text path or the decoded
  # preview JSON supplies the real driver once it is available.
  dev_type="${raw:18:2}"
  if [[ "${mfr}" == "304C" && "${dev_type}" == "07" ]]; then
    status_candidate_seen "${id}" "izarv2" "Water meter (0x07)" "false"
  else
    local _type_label
    _type_label="$(map_device_type "${dev_type}")"
    # The device-type byte does not carry encryption; mark AES from the TPL CFG so
    # candidate_type_requires_aes skips the preview (an encrypted meter without a
    # key never decodes — it must show "requires AES", not "decoding..." forever).
    raw_is_encrypted "${raw}" && _type_label="${_type_label} encrypted"
    status_candidate_seen "${id}" "auto" "${_type_label}" "false"
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

#!/usr/bin/env bash

# Atomic, serialized replace-or-insert for a single-keyed TSV file.
# Holds an exclusive flock on FILE.lock for the entire read-modify-write.
# Uses mktemp so concurrent writers never collide on a shared .tmp path.
_tsv_upsert() {
  local file="$1" id="$2" row="$3"
  (
    flock -x 9
    local _tmp
    _tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    awk -F '\t' -v id="${id}" '$1 != id {print}' "${file}" 2>/dev/null > "${_tmp}" || true
    printf '%s\n' "${row}" >> "${_tmp}"
    mv "${_tmp}" "${file}" 2>/dev/null || { rm -f "${_tmp}"; true; }
  ) 9>"${file}.lock"
}

# Atomic, serialized removal of a single keyed row from a TSV file.
# Mirrors _tsv_upsert's locking model (exclusive flock + mktemp + atomic mv).
# No-op when the file is absent. Comparison is on the literal first column.
_tsv_remove_id() {
  local file="$1" id="$2"
  [[ -f "${file}" ]] || return 0
  (
    flock -x 9
    local _tmp
    _tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    awk -F '\t' -v id="${id}" '$1 != id {print}' "${file}" 2>/dev/null > "${_tmp}" || true
    mv "${_tmp}" "${file}" 2>/dev/null || { rm -f "${_tmp}"; true; }
  ) 9>"${file}.lock"
}

# Session-scoped reception totals keyed by meter id + ESP device.
# Format: id<TAB>device<TAB>first_seen_epoch<TAB>last_seen_epoch<TAB>count<TAB>last_topic
_upsert_esp_meter_reception() {
  local file="$1" id="$2" device="$3" now="$4" topic="$5"
  (
    flock -x 9
    [[ -f "${file}" ]] || : > "${file}"
    local _tmp
    _tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    if ! awk -F $'\t' -v OFS=$'\t' \
      -v id="${id}" -v device="${device}" -v now="${now}" -v topic="${topic}" '
        BEGIN { updated = 0 }
        $1 == id && $2 == device {
          first = ($3 ~ /^[0-9]+$/ && $3 > 0) ? $3 : now
          count = ($5 ~ /^[0-9]+$/) ? $5 + 1 : 1
          print id, device, first, now, count, topic
          updated = 1
          next
        }
        { print }
        END { if (!updated) print id, device, now, now, 1, topic }
      ' "${file}" > "${_tmp}"; then
      rm -f "${_tmp}"
      return 1
    fi
    mv "${_tmp}" "${file}" 2>/dev/null || { rm -f "${_tmp}"; true; }
  ) 9>"${file}.lock"
}

# Persistent, bounded event history. The payload deliberately contains no RAW
# telegram and no AES material: only data needed to answer when a given ESP
# received a given meter. Appends and rotations share one lock.
_append_esp_rx_history() {
  local file="$1" now="$2" device="$3" id="$4" topic="$5"
  local line
  line="$(jq -cn \
    --argjson time "${now}" --arg source "${device}" --arg meter_id "${id}" --arg topic "${topic}" \
    '{time:$time,source:$source,meter_id:$meter_id,topic:$topic}')" || return 1
  (
    flock -x 9
    printf '%s\n' "${line}" >> "${file}"
  ) 9>"${file}.lock"
}

# Persist a validated ESP /rx payload with the bridge receive time and source
# derived from the MQTT topic. The firmware payload contains no RAW frame.
_append_esp_rf_rx_history() {
  local file="$1" now="$2" device="$3" payload="$4"
  local line
  line="$(jq -c --argjson bridge_rx_time "${now}" --arg source "${device}" \
    '. + {bridge_rx_time:$bridge_rx_time,source:$source}' <<< "${payload}")" || return 1
  (
    flock -x 9
    printf '%s\n' "${line}" >> "${file}"
  ) 9>"${file}.lock"
}

_normalize_esp_rx_payload() {
  jq -c '
    select(.schema == 1)
    | select((.boot_id | type) == "string" and (.boot_id | test("^[0-9A-Fa-f]{8}$")))
    | select((.seq | type) == "number" and .seq >= 1 and (.seq | floor) == .seq)
    | select((.rx_task_wakeup_us | type) == "number" and .rx_task_wakeup_us >= 0)
    | select((.meter_id | type) == "string" and (.meter_id | test("^[0-9A-Fa-f]{8}$")))
    | select(.mode == "T1" or .mode == "C1" or .mode == "S1")
    | select(.rssi_dbm == null or ((.rssi_dbm | type) == "number" and .rssi_dbm >= -125 and .rssi_dbm <= -1))
    | select((.frame_crc32 | type) == "string" and (.frame_crc32 | test("^[0-9A-Fa-f]{8}$")))
    | select((.frame_length | type) == "number" and .frame_length > 0 and (.frame_length | floor) == .frame_length)
    # received_at is optional decoration, so a malformed one drops the FIELD,
    # never the frame. Rejecting a whole telegram over a cosmetic timestamp
    # would let one firmware bug silence a board completely.
    | if (.received_at != null and (((.received_at | type) != "string")
        or ((.received_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$")) | not)))
      then del(.received_at) else . end
    | .boot_id |= ascii_upcase
    | .meter_id |= ascii_upcase
    | .frame_crc32 |= ascii_upcase
  ' 2>/dev/null
}

# Current sequence continuity per ESP source.
# Format: source<TAB>boot_id<TAB>last_seq<TAB>missing<TAB>out_of_order<TAB>last_seen
#
# last_seq is the HIGHEST sequence number seen for this boot, not the most
# recent one. That distinction is the whole point: a duplicate or a late
# delivery used to overwrite the baseline, and the next in-order frame then
# looked like a jump and was counted as missing. One reordering event could
# therefore invent a gap that never happened - observed 2026-08-21, when three
# boards reported missing=1 in the same second while the broker was simply
# redelivering. Frames at or below the maximum are counted as out_of_order and
# never move the baseline.
_upsert_esp_rx_sequence() {
  local file="$1" source="$2" boot_id="$3" seq="$4" now="$5"
  (
    flock -x 9
    [[ -f "${file}" ]] || : > "${file}"
    local _tmp
    _tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    if ! awk -F $'\t' -v OFS=$'\t' \
      -v source="${source}" -v boot_id="${boot_id}" -v seq="${seq}" -v now="${now}" '
        BEGIN { updated = 0 }
        $1 == source {
          missing = 0
          out_of_order = 0
          # Prefix both operands so awk cannot interpret hex-looking boot IDs
          # such as 651E6871 as overflowing scientific notation.
          if ("boot:" $2 == "boot:" boot_id) {
            last = ($3 ~ /^[0-9]+$/) ? $3 : 0
            missing = ($4 ~ /^[0-9]+$/) ? $4 : 0
            out_of_order = ($5 ~ /^[0-9]+$/) ? $5 : 0
            if (last > 0 && seq > last + 1) missing += seq - last - 1
            if (last > 0 && seq <= last) out_of_order++
            if (seq < last) seq = last
          }
          print source, boot_id, seq, missing, out_of_order, now
          updated = 1
          next
        }
        { print }
        END { if (!updated) print source, boot_id, seq, 0, 0, now }
      ' "${file}" > "${_tmp}"; then
      rm -f "${_tmp}"
      return 1
    fi
    mv "${_tmp}" "${file}" 2>/dev/null || { rm -f "${_tmp}"; true; }
  ) 9>"${file}.lock"
}

# One row per ESP boot, so a restart leaves a trace instead of silently
# resetting the sequence counters.
#
# WHY THIS EXISTS: on 2026-08-20/21 four boards were restarting every 15 minutes
# and nobody noticed for a day - reception simply looked "a bit worse". The
# cause was an empty `api:` block, where ESPHome applies reboot_timeout: 15min
# and restarts the device whenever no Native API client is connected. Without a
# boot history the evidence is destroyed by the very event you are looking for.
#
# Format: source<TAB>boot_id<TAB>first_seen<TAB>last_seen<TAB>events
_upsert_esp_rx_boot() {
  local file="$1" source="$2" boot_id="$3" now="$4"
  (
    flock -x 9
    [[ -f "${file}" ]] || : > "${file}"
    local _tmp
    _tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    if ! awk -F $'\t' -v OFS=$'\t' \
      -v source="${source}" -v boot_id="${boot_id}" -v now="${now}" '
        BEGIN { updated = 0 }
        # Force a string comparison. BusyBox awk otherwise treats values such
        # as 651E6871 and 999E9999 as equal numeric infinities.
        $1 == source && "boot:" $2 == "boot:" boot_id {
          events = ($5 ~ /^[0-9]+$/) ? $5 + 1 : 1
          print $1, $2, $3, now, events
          updated = 1
          next
        }
        { print }
        END { if (!updated) print source, boot_id, now, now, 1 }
      ' "${file}" > "${_tmp}"; then
      rm -f "${_tmp}"
      return 1
    fi
    mv "${_tmp}" "${file}" 2>/dev/null || { rm -f "${_tmp}"; true; }
  ) 9>"${file}.lock"
}

# Clock view per ESP: the board's own reception time against the time the
# bridge saw the message. The difference is the only way to notice that a
# board's clock never synced, or that frames are arriving late.
#
# Format: source<TAB>last_received_epoch<TAB>last_bridge_epoch<TAB>skew_s<TAB>stamped<TAB>unstamped
_upsert_esp_rx_clock() {
  local file="$1" source="$2" received_epoch="$3" bridge_epoch="$4"
  (
    flock -x 9
    [[ -f "${file}" ]] || : > "${file}"
    local _tmp
    _tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    if ! awk -F $'\t' -v OFS=$'\t' \
      -v source="${source}" -v rcv="${received_epoch}" -v now="${bridge_epoch}" '
        BEGIN { updated = 0 }
        $1 == source {
          stamped = ($5 ~ /^[0-9]+$/) ? $5 : 0
          unstamped = ($6 ~ /^[0-9]+$/) ? $6 : 0
          if (rcv == "") { unstamped++; print source, $2, now, $4, stamped, unstamped }
          else { stamped++; print source, rcv, now, now - rcv, stamped, unstamped }
          updated = 1
          next
        }
        { print }
        END {
          if (!updated) {
            if (rcv == "") print source, 0, now, 0, 0, 1
            else print source, rcv, now, now - rcv, 1, 0
          }
        }
      ' "${file}" > "${_tmp}"; then
      rm -f "${_tmp}"
      return 1
    fi
    mv "${_tmp}" "${file}" 2>/dev/null || { rm -f "${_tmp}"; true; }
  ) 9>"${file}.lock"
}

_trim_esp_rx_history() {
  local file="$1" max_lines="$2" keep_lines="$3"
  [[ -f "${file}" ]] || return 0
  (
    flock -x 9
    local lines _tmp
    lines="$(wc -l < "${file}" 2>/dev/null || echo 0)"
    [[ "${lines}" =~ ^[0-9]+$ ]] || lines=0
    (( lines > max_lines )) || return 0
    _tmp="$(mktemp "${file}.tmp.XXXXXX")" || return 1
    if ! tail -n "${keep_lines}" "${file}" > "${_tmp}"; then
      rm -f "${_tmp}"
      return 1
    fi
    if ! mv "${_tmp}" "${file}"; then
      rm -f "${_tmp}"
      return 1
    fi
  ) 9>"${file}.lock"
}

_upsert_candidate_row() {
  local _id="$1" _driver="$2" _type="$3" _last_seen="$4" _seen_count="$5"
  local _avg_interval_s="$6" _seen_15m="$7" _seen_60m="$8" _manufacturer="${9:-}"
  local _file="${STATUS_CANDIDATES_FILE}"
  (
    flock -x 9
    # Self-heal: a factory reset (or any external cleanup) removes the TSV
    # while the bridge keeps running — unlike _tsv_upsert above, this awk
    # reads the file directly and would fail on a missing one, silently
    # dropping EVERY candidate until the next add-on restart (observed live:
    # "awk: /data/status_candidates.tsv: No such file or directory" looping
    # in the log while the WebUI showed zero candidates).
    [[ -f "${_file}" ]] || : > "${_file}"
    local _tmp
    _tmp="$(mktemp "${_file}.tmp.XXXXXX")" || return 1
    if ! awk -F $'\t' -v OFS=$'\t' \
      -v id="${_id}" \
      -v driver="${_driver}" \
      -v type_line="${_type}" \
      -v last_seen="${_last_seen}" \
      -v seen_count="${_seen_count}" \
      -v avg_interval_s="${_avg_interval_s}" \
      -v seen_15m="${_seen_15m}" \
      -v seen_60m="${_seen_60m}" \
      -v manufacturer="${_manufacturer}" '
        BEGIN { final_manufacturer = manufacturer }
        $1 == id {
          if (final_manufacturer == "" && NF >= 9 && $9 != "") {
            final_manufacturer = $9
          }
          next
        }
        { print }
        END {
          print id, driver, type_line, last_seen, seen_count, avg_interval_s, seen_15m, seen_60m, final_manufacturer
        }
      ' "${_file}" > "${_tmp}"; then
      rm -f "${_tmp}"
      return 1
    fi
    if ! mv "${_tmp}" "${_file}"; then
      rm -f "${_tmp}"
      return 1
    fi
  ) 9>"${STATUS_CANDIDATES_FILE}.lock"
}

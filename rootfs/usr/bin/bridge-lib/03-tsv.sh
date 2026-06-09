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

_upsert_candidate_row() {
  local _id="$1" _driver="$2" _type="$3" _last_seen="$4" _seen_count="$5"
  local _avg_interval_s="$6" _seen_15m="$7" _seen_60m="$8" _manufacturer="${9:-}"
  local _file="${STATUS_CANDIDATES_FILE}"
  (
    flock -x 9
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

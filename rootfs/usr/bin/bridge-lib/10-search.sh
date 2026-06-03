declare -A SEARCH_FIRST_VALUE

declare -A SEARCH_REPORTED_EXPECTED

declare -A SEARCH_REPORTED_DELTA

search_cached_count() {
  if [[ -f "${SEARCH_CANDIDATES_FILE}" ]]; then
    grep -Ec '^[0-9A-Fa-f]{8}[[:space:]]' "${SEARCH_CANDIDATES_FILE}" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

write_search_status() {
  local phase="${1:-auto}"
  local reason="${2:-}"
  local tmp="${SEARCH_STATUS_FILE}.tmp"
  local cached_count matches_count updated

  cached_count="$(search_cached_count)"
  [[ "${cached_count}" =~ ^[0-9]+$ ]] || cached_count=0
  matches_count="$(wc -l < "${SEARCH_MATCHES_FILE}" 2>/dev/null || echo 0)"
  [[ "${matches_count}" =~ ^[0-9]+$ ]] || matches_count=0

  if [[ "${phase}" == "auto" ]]; then
    if [[ "${SEARCH_MATCH_COUNT}" -gt 0 || "${matches_count}" -gt 0 ]]; then
      phase="matched"
    elif [[ "${SEARCH_USING_TEMP_METERS}" == "true" ]]; then
      phase="search"
    elif [[ "${SEARCH_MODE}" == "true" && "${SEARCH_EXPECTED_VALUE_M3}" != "0" ]]; then
      phase="collecting"
    else
      phase="listen"
    fi
  fi

  [[ -n "${reason}" ]] && SEARCH_LAST_REASON="${reason}"
  updated="$(iso_now)"

  jq -n \
    --arg updated_at "${updated}" \
    --arg phase "${phase}" \
    --arg search_mode "${SEARCH_MODE:-false}" \
    --arg expected "${SEARCH_EXPECTED_VALUE_M3:-0}" \
    --arg tolerance "${SEARCH_TOLERANCE_M3:-0}" \
    --arg cached "${cached_count}" \
    --arg ignored "${SEARCH_IGNORED_COUNT:-0}" \
    --arg loaded "${SEARCH_TEMP_METERS_LOADED:-0}" \
    --arg decoded "${SEARCH_DECODED_JSON_COUNT:-0}" \
    --arg checked "${SEARCH_CHECKED_VALUES:-0}" \
    --arg matches "${matches_count}" \
    --arg cache_changed_at "${SEARCH_LAST_CACHE_CHANGE:-}" \
    --arg last_candidate_id "${SEARCH_LAST_CANDIDATE_ID:-}" \
    --arg last_candidate_driver "${SEARCH_LAST_CANDIDATE_DRIVER:-}" \
    --arg last_candidate_type "${SEARCH_LAST_CANDIDATE_TYPE:-}" \
    --arg last_checked_id "${SEARCH_LAST_CHECKED_ID:-}" \
    --arg last_checked_driver "${SEARCH_LAST_CHECKED_DRIVER:-}" \
    --arg last_checked_field "${SEARCH_LAST_CHECKED_FIELD:-}" \
    --arg last_checked_value "${SEARCH_LAST_CHECKED_VALUE:-}" \
    --arg last_checked_diff "${SEARCH_LAST_CHECKED_DIFF:-}" \
    --arg last_reason "${SEARCH_LAST_REASON:-}" \
    --arg last_ignored_reason "${SEARCH_LAST_IGNORED_REASON:-}" \
    '{updated_at:$updated_at,
      phase:$phase,
      search_mode:($search_mode=="true"),
      expected_m3:($expected|tonumber? // 0),
      tolerance_m3:($tolerance|tonumber? // 0),
      cached_candidates:($cached|tonumber? // 0),
      ignored_candidates:($ignored|tonumber? // 0),
      loaded_temp_meters:($loaded|tonumber? // 0),
      decoded_json:($decoded|tonumber? // 0),
      checked_values:($checked|tonumber? // 0),
      matches:($matches|tonumber? // 0),
      cache_changed_at:$cache_changed_at,
      last_candidate:{id:$last_candidate_id,driver:$last_candidate_driver,type:$last_candidate_type},
      last_checked:{id:$last_checked_id,driver:$last_checked_driver,field:$last_checked_field,value:$last_checked_value,diff_m3:$last_checked_diff},
      last_reason:$last_reason,
      last_ignored_reason:$last_ignored_reason}' \
    > "${tmp}" 2>/dev/null && mv "${tmp}" "${SEARCH_STATUS_FILE}" 2>/dev/null || true
}

search_field_is_candidate() {
  local key_lc="$1"

  case "${key_lc}" in
    *total_volume*|*m3*) return 0 ;;
    *) return 1 ;;
  esac
}

emit_search_payload() {
  local kind="$1"
  local json_line="$2"
  local field="$3"
  local value="$4"
  local diff="$5"
  local delta="$6"

  local id meter media name payload
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
  media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
  name="$(jq -r '.name // empty' <<<"${json_line}" 2>/dev/null || true)"

  payload="$(jq -c -n \
    --arg kind "${kind}" \
    --arg id "${id}" \
    --arg meter "${meter}" \
    --arg media "${media}" \
    --arg name "${name}" \
    --arg field "${field}" \
    --argjson value "${value}" \
    --argjson expected "${SEARCH_EXPECTED_VALUE_M3}" \
    --argjson diff "${diff}" \
    --argjson delta "${delta}" \
    '{event:$kind,id:$id,meter:$meter,media:$media,name:$name,field:$field,value_m3:$value,expected_value_m3:$expected,diff_m3:$diff,delta_m3:$delta}' \
    2>/dev/null || true)"

  [[ -n "${payload}" ]] || return 0
  mqtt_pub "${SEARCH_TOPIC}" "${payload}" "false" || true
}

search_type_is_water_candidate() {
  local type_lc="$1"

  [[ -n "${type_lc}" ]] || return 1
  candidate_type_requires_aes "${type_lc}" && return 1

  case "${type_lc}" in
    *water*) return 0 ;;
    *) return 1 ;;
  esac
}

search_cache_candidate() {
  local id
  local driver="$2"
  local type_line="${3:-}"
  local type_lc

  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  [[ -n "${driver}" ]] || driver="auto"

  type_lc="$(echo "${type_line}" | tr '[:upper:]' '[:lower:]')"
  if ! search_type_is_water_candidate "${type_lc}"; then
    SEARCH_IGNORED_COUNT=$((SEARCH_IGNORED_COUNT + 1))
    SEARCH_LAST_CANDIDATE_ID="${id}"
    SEARCH_LAST_CANDIDATE_DRIVER="${driver}"
    SEARCH_LAST_CANDIDATE_TYPE="${type_line:-unknown}"
    SEARCH_LAST_IGNORED_REASON="not_water_m3_candidate_or_encrypted"
    warn "SEARCH ignored: id=${id} driver=${driver} type=${type_line:-unknown} reason=not_water_m3_candidate_or_encrypted (ignored=${SEARCH_IGNORED_COUNT})."
    write_search_status "auto" "candidate_ignored"
    return 0
  fi

  touch "${SEARCH_CANDIDATES_FILE}"
  if grep -q "^${id}	" "${SEARCH_CANDIDATES_FILE}" 2>/dev/null; then
    return 0
  fi

  printf '%s	%s
' "${id}" "${driver}" >> "${SEARCH_CANDIDATES_FILE}"
  SEARCH_LAST_CACHE_CHANGE="$(iso_now)"
  SEARCH_LAST_CANDIDATE_ID="${id}"
  SEARCH_LAST_CANDIDATE_DRIVER="${driver}"
  SEARCH_LAST_CANDIDATE_TYPE="${type_line:-unknown}"

  local cached_count
  cached_count="$(grep -Ec '^[0-9A-Fa-f]{8}[[:space:]]' "${SEARCH_CANDIDATES_FILE}" 2>/dev/null || true)"
  [[ "${cached_count}" =~ ^[0-9]+$ ]] || cached_count=0

  warn "SEARCH discovered: id=${id} driver=${driver} type=${type_line:-unknown} stored as water candidate (cached=${cached_count}, ignored=${SEARCH_IGNORED_COUNT})."
  status_candidate_seen "${id}" "${driver}" "${type_line:-unknown}"
  write_search_status "auto" "candidate_cached"
}

create_search_meter_files_from_cache() {
  [[ -f "${SEARCH_CANDIDATES_FILE}" ]] || return 0

  local i=0
  local id driver file safe_driver
  while IFS=$'\t' read -r id driver; do
    id="$(normalize_meter_id "${id}")"
    [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || continue
    [[ -n "${driver}" ]] || driver="auto"
    [[ "${driver}" =~ ^[A-Za-z0-9_]+$ ]] || driver="auto"

    i=$((i+1))
    file="$(printf '%s/meter-%04d' "${METER_DIR}" "${i}")"
    safe_driver="${driver}"

    {
      echo "name=search_${id}"
      echo "id=${id,,}"
      if [[ "${safe_driver}" != "auto" ]]; then
        echo "driver=${safe_driver}"
      fi
    } > "${file}"

    # Do not spam logs with every temporary search meter. A summary is printed after cache load.
  done < "${SEARCH_CANDIDATES_FILE}"

  echo "${i}"
}

process_search_json() {
  local json_line="$1"
  [[ "${SEARCH_MODE}" == "true" ]] || return 0

  local id
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  if is_search_temp_json "${json_line}"; then
    SEARCH_DECODED_JSON_COUNT=$((SEARCH_DECODED_JSON_COUNT + 1))
  fi

  while IFS=$'\t' read -r field value; do
    [[ -n "${field}" && -n "${value}" ]] || continue

    local field_lc state_key diff absdiff in_tolerance delta
    field_lc="$(echo "${field}" | tr '[:upper:]' '[:lower:]')"
    search_field_is_candidate "${field_lc}" || continue

    local meter_name
    meter_name="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
    SEARCH_CHECKED_VALUES=$((SEARCH_CHECKED_VALUES + 1))
    SEARCH_LAST_CHECKED_ID="${id}"
    SEARCH_LAST_CHECKED_DRIVER="${meter_name:-auto}"
    SEARCH_LAST_CHECKED_FIELD="${field}"
    SEARCH_LAST_CHECKED_VALUE="${value}"

    state_key="${id}|${field}"
    diff="$(awk -v v="${value}" -v e="${SEARCH_EXPECTED_VALUE_M3}" 'BEGIN { printf "%.6f", v - e }')"
    absdiff="$(awk -v d="${diff}" 'BEGIN { if (d < 0) d = -d; printf "%.6f", d }')"
    SEARCH_LAST_CHECKED_DIFF="${absdiff}"
    SEARCH_LAST_REASON="value_out_of_tolerance"

    in_tolerance="$(awk -v d="${absdiff}" -v t="${SEARCH_TOLERANCE_M3}" 'BEGIN { print (d <= t) ? "yes" : "no" }')"
    if [[ "${SEARCH_EXPECTED_VALUE_M3}" != "0" && "${in_tolerance}" == "yes" && -z "${SEARCH_REPORTED_EXPECTED[${state_key}]+x}" ]]; then
      local media meter
      media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
      meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
      warn "SEARCH MATCH: id=${id} driver=${meter:-unknown} media=${media:-unknown} field=${field} value=${value} m3 expected=${SEARCH_EXPECTED_VALUE_M3} diff=${absdiff} m3"
      warn "SEARCH SUGGESTED CONFIG: {\"id\":\"meter_${id}\",\"meter_id\":\"${id}\",\"type\":\"${meter:-auto}\",\"type_other\":\"\",\"key\":\"\"}"
      emit_search_payload "value_match" "${json_line}" "${field}" "${value}" "${absdiff}" "0"
      search_record_match "${json_line}" "${field}" "${value}" "${absdiff}"
      SEARCH_MATCH_COUNT=$((SEARCH_MATCH_COUNT + 1))
      SEARCH_LAST_REASON="value_match"
      write_search_status "matched" "value_match"
      SEARCH_REPORTED_EXPECTED["${state_key}"]=1
    else
      write_search_status "auto" "value_out_of_tolerance"
    fi

    if [[ "${SEARCH_DELTA_MODE}" == "true" ]]; then
      if [[ -z "${SEARCH_FIRST_VALUE[${state_key}]+x}" ]]; then
        SEARCH_FIRST_VALUE["${state_key}"]="${value}"
      else
        delta="$(awk -v v="${value}" -v first="${SEARCH_FIRST_VALUE[${state_key}]}" 'BEGIN { printf "%.6f", v - first }')"
        in_tolerance="$(awk -v d="${delta}" -v min="${SEARCH_MIN_DELTA_M3}" 'BEGIN { print (d >= min) ? "yes" : "no" }')"
        if [[ "${in_tolerance}" == "yes" && -z "${SEARCH_REPORTED_DELTA[${state_key}]+x}" ]]; then
          warn "SEARCH delta: id=${id} field=${field} first=${SEARCH_FIRST_VALUE[${state_key}]} now=${value} delta=${delta} m3"
          emit_search_payload "delta_match" "${json_line}" "${field}" "${value}" "0" "${delta}"
          SEARCH_REPORTED_DELTA["${state_key}"]=1
        fi
      fi
    fi
  done < <(
    jq -r '
      to_entries[]
      | select((.value|type)=="number")
      | [.key, (.value|tostring)]
      | @tsv
    ' <<<"${json_line}" 2>/dev/null || true
  )
}

search_record_match() {
  local json_line="$1"
  local field="$2"
  local value="$3"
  local diff="$4"
  local id meter media now tmp

  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
  media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
  now="$(iso_now)"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${now}" "${id}" "${meter:-auto}" "${media:-}" "${field}" "${value}" "${SEARCH_EXPECTED_VALUE_M3}" "${diff}" "${SEARCH_TOLERANCE_M3}" >> "${SEARCH_MATCHES_FILE}" 2>/dev/null || true
  tail -n 100 "${SEARCH_MATCHES_FILE}" > "${SEARCH_MATCHES_FILE}.tmp" 2>/dev/null && mv "${SEARCH_MATCHES_FILE}.tmp" "${SEARCH_MATCHES_FILE}" 2>/dev/null || true
}


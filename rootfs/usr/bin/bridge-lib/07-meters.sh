_select_primary_meter_value() {
  local json_line="$1"
  jq -r '
    [ "total_m3",
      "total_kwh",
      "total_wh",
      "total_energy_consumption_kwh",
      "total_volume_m3" ] as $canonical
    | (
        [ $canonical[] as $k
          | select((.[$k] | type) == "number")
          | [$k, .[$k]]
        ][0]
        // [ to_entries[]
          | select((.value|type)=="number")
          | select(.key|test("(^total|_m3$|kwh|wh$|energy|volume)";"i"))
          | select(.key|test("(last_month|last_year|previous_month|previous_year|previous|prev|at_history|history|historic|billing|due_date|target|backflow|fraud|leak|tamper|alarm|production|tariff)";"i")|not)
          | [.key, .value]
        ][0]
      )
    | if . == null then empty else @tsv end
  ' <<<"${json_line}" 2>/dev/null | head -n 1 || true
}

status_meter_seen() {
  local json_line="$1"
  local id name meter media value_key value value_parts last_seen
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0
  name="$(jq -r '.name // empty' <<<"${json_line}" 2>/dev/null || true)"
  meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
  media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"
  value_parts="$(jq -rc '
    [to_entries[]
      | select((.value|type)=="number")
      | select(.key|test("^total_energy_consumption_tariff_[0-9]+_kwh$";"i"))
      | . as $entry
      | ($entry.key | capture("^total_energy_consumption_tariff_(?<tariff>[0-9]+)_kwh$";"i")) as $m
      | {label: ("T" + $m.tariff), key: $entry.key, value: $entry.value, order: ($m.tariff|tonumber)}
    ]
    | sort_by(.order)
    | map(del(.order))
    | if length > 0 then . else empty end
  ' <<<"${json_line}" 2>/dev/null || true)"
  # Prefer the cumulative METER READING (what's shown on the meter's own
  # display) as the primary value — total_m3, total_energy_consumption_kwh,
  # etc. Consistent across media: water shows total_m3, electricity shows
  # total_energy_consumption_kwh (not the live kW draw). Exclude production,
  # raw tariff registers and fault/alarm counters on the first pass; if an
  # electricity meter only publishes consumption tariffs, sum them below.
  IFS=$'\t' read -r value_key value < <(_select_primary_meter_value "${json_line}") || true
  if [[ -z "${value_key}" ]]; then
    # Some electricity meters publish only per-tariff import registers. When
    # the aggregate total is missing, sum consumption tariffs and expose that
    # as the meter reading. Production tariffs remain excluded.
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
  if [[ -z "${value_key}" ]]; then
    # This telegram carries NO cumulative total. Some electricity meters send
    # mostly instantaneous-only telegrams (current_power, voltage) and a total
    # only occasionally. Do NOT downgrade a meter that already showed a
    # total — reuse the last cumulative reading from the TSV so the value stays
    # the meter reading and does not flicker back to the live kW draw on every
    # power-only telegram. For electricity, never show live power as the meter
    # reading; leave the value empty until a cumulative total arrives. Other
    # media keep the historical instantaneous fallback.
    local prev_key prev_val prev_parts
    IFS=$'\t' read -r prev_key prev_val prev_parts < <(awk -F '\t' -v id="${id}" '$1==id {print $5 "\t" $6 "\t" $13; exit}' "${STATUS_METERS_FILE}" 2>/dev/null || true)
    if [[ -n "${prev_key}" ]] \
       && printf '%s' "${prev_key}" | grep -qiE '(^total|_m3$|kwh|wh$|energy|volume)' \
       && ! printf '%s' "${prev_key}" | grep -qiE '(last_month|last_year|previous_month|previous_year|previous|prev|at_history|history|historic|billing|due_date|target|backflow|fraud|leak|tamper|alarm|production|tariff)'; then
      value_key="${prev_key}"
      value="${prev_val}"
      value_parts="${prev_parts}"
    else
      local media_lc meter_lc
      media_lc="$(printf '%s' "${media}" | tr '[:upper:]' '[:lower:]')"
      meter_lc="$(printf '%s' "${meter}" | tr '[:upper:]' '[:lower:]')"
      if [[ "${media_lc}" == *electric* || "${media_lc}" == *energy* || "${meter_lc}" == *electric* ]] \
         || jq -e 'any(to_entries[]; (.key | test("(energy|power|voltage|current).*(_kwh|_wh|_kw|_w|_v|_a)$"; "i")))' <<<"${json_line}" >/dev/null 2>&1; then
        value_key=""
        value=""
      else
        value_key="$(jq -r 'to_entries[] | select((.value|type)=="number") | select(.key|test("(_kw$|_w$|_m3h$|_l_h$)";"i")) | .key' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
        if [[ -n "${value_key}" ]]; then
          value="$(jq -r --arg k "${value_key}" '.[$k] // empty' <<<"${json_line}" 2>/dev/null || true)"
        else
          value_key="value"
          value="$(jq -r 'to_entries[] | select((.value|type)=="number") | .value' <<<"${json_line}" 2>/dev/null | head -n 1 || true)"
        fi
      fi
    fi
  fi
  status_record_seen "${id}" "meter"
  last_seen="$(iso_now)"
  IFS=$'\t' read -r seen_count avg_interval_s seen_15m seen_60m < <(status_seen_stats "${id}" "meter")
  _tsv_upsert "${STATUS_METERS_FILE}" "${id}" \
    "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "${id}" "${name}" "${meter}" "${media}" "${value_key}" "${value}" "${last_seen}" "published" "${seen_count}" "${avg_interval_s}" "${seen_15m}" "${seen_60m}" "${value_parts}")"
}

# shellcheck disable=SC2034
refresh_meter_files() {
  rm -f "${METER_DIR}/meter-"* 2>/dev/null || true

  OFFICIAL_METERS_COUNT=0
  local configured_count=0
  if [[ -f "${OPTIONS_JSON}" ]] && jq -e '.meters and (.meters|length>0)' "${OPTIONS_JSON}" >/dev/null 2>&1; then
    configured_count="$(jq -r '.meters|length' "${OPTIONS_JSON}")"
  fi
  SEARCH_USING_TEMP_METERS="false"

  if [[ "${configured_count}" -eq 0 && "${SEARCH_MODE}" == "true" && "${SEARCH_EXPECTED_VALUE_M3}" != "0" ]]; then
    local cached_count
    cached_count="$(create_search_meter_files_from_cache)"
    if [[ "${cached_count}" =~ ^[0-9]+$ && "${cached_count}" -gt 0 ]]; then
      SEARCH_USING_TEMP_METERS="true"
      SEARCH_TEMP_METERS_LOADED="${cached_count}"
      warn "No user meters configured -> SEARCH MODE (temporary cached candidates=${cached_count}, expected=${SEARCH_EXPECTED_VALUE_M3} m3, tolerance=${SEARCH_TOLERANCE_M3} m3)."
      warn "SEARCH MODE uses cached candidates from ${SEARCH_CANDIDATES_FILE}. Remove that file or disable search_mode to return to pure LISTEN MODE."
      write_search_status "search" "loaded_temp_meters"
    else
      warn "No meters configured -> SEARCH DISCOVERY MODE."
      warn "SEARCH MODE needs decoded JSON values, but there are no cached candidates yet."
      warn "The bridge will collect id+driver candidates first. Let it run long enough to hear meters; restart later to decode cached candidates and compare m3 values."
      write_search_status "collecting" "no_cached_candidates"
    fi
  elif [[ "${configured_count}" -eq 0 ]]; then
    warn "No meters configured -> LISTEN MODE (will log DLL-ID + suggested driver)."
    write_search_status "listen" "listen_mode"
  else
    local loaded_count=0
    local meter_json file friendly_name driver driver_other mid_raw key mid
    while IFS= read -r meter_json; do
      friendly_name="$(echo "${meter_json}" | jq -r '.id // "meter"')"
      driver="$(echo "${meter_json}" | jq -r '.type // "auto"')"
      driver_other="$(echo "${meter_json}" | jq -r '.type_other // empty')"
      mid_raw="$(echo "${meter_json}" | jq -r '.meter_id // empty')"
      key="$(echo "${meter_json}" | jq -r '.key // empty')"

      if [[ -z "${key}" || "${key}" == "null" ]]; then
        key=""
      elif [[ ! "${key}" =~ ^[A-Fa-f0-9]{32}$ ]]; then
        warn "Invalid key for '${friendly_name}' -> skipping (expected empty or 32 hex chars, got: '${key}')"
        continue
      fi

      [[ -z "${driver}" || "${driver}" == "null" ]] && driver="auto"

      if [[ "${driver}" == "other" ]]; then
        if [[ -z "${driver_other}" || "${driver_other}" == "null" ]]; then
          warn "type=other but type_other is empty for '${friendly_name}' -> skipping"
          continue
        fi
        driver="${driver_other}"
      fi

      mid="$(normalize_meter_id "${mid_raw}")"
      if [[ -z "${mid}" ]]; then
        warn "Invalid meter_id for '${friendly_name}' -> skipping (got: '${mid_raw}')"
        continue
      fi

      loaded_count=$((loaded_count + 1))
      file="$(printf '%s/meter-%04d' "${METER_DIR}" "${loaded_count}")"
      {
        echo "name=${friendly_name}"
        # wmbusmeters matches the telegram address case-sensitively in
        # lowercase. meter_id is kept UPPERCASE for display, so lowercase it
        # in the config file — otherwise ids with hex letters (e.g. izar
        # 2156B4C2) never match and the meter silently doesn't decode, even
        # though the file loads. Numeric-only ids were unaffected.
        echo "id=${mid,,}"
        if [[ -n "${key}" ]]; then
          echo "key=${key}"
        fi
        if [[ "${driver}" != "auto" ]]; then
          echo "driver=${driver}"
        fi
      } > "${file}"

      log "meter: ${friendly_name} id=${mid} driver=${driver}"
    done < <(jq -c '.meters[]' "${OPTIONS_JSON}" 2>/dev/null || true)
    OFFICIAL_METERS_COUNT="${loaded_count}"
    if [[ "${loaded_count}" -gt 0 ]]; then
      write_search_status "configured" "official_meters_configured"
    else
      warn "Configured meters exist in options.json, but none produced a valid wmbusmeters meter file -> LISTEN MODE."
      write_search_status "listen" "configured_meters_invalid"
    fi
  fi
}

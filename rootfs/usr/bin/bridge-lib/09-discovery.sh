declare -A DISCOVERY_SENT_FIELD


declare -A DISCOVERY_CLEANED_LEGACY


declare -A SEARCH_DISCOVERY_CLEARED_FIELD


clean_legacy_totalm3() {
  local id
  [[ "${DISCOVERY_ENABLED}" == "true" ]] || return 0
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  if [[ -z "${DISCOVERY_CLEANED_LEGACY[${id}]+x}" ]]; then
    if mqtt_pub "${DISCOVERY_PREFIX}/sensor/wmbus_${id}/total_m3/config" "" "true"; then
      DISCOVERY_CLEANED_LEGACY["${id}"]=1
    else
      warn "discovery: failed to clear legacy total_m3 for id=${id} (will retry later)"
    fi
  fi
}


emit_discovery_from_json() {
  local json_line="$1"
  [[ "${DISCOVERY_ENABLED}" == "true" ]] || return 0

  local id name meter media
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  clean_legacy_totalm3 "${id}"

  name="$(jq -r '.name // .id // "wmbus"' <<<"${json_line}" 2>/dev/null || true)"
  meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
  media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"

  local uniq="wmbus_${id}"
  local state_topic="${STATE_PREFIX}/${id}/state"
  local dev_name="${name} (${id})"
  local dev_mdl="${meter:-wmbusmeter}"
  local dev_mfr="wmbusmeters"

  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue

    local obj cache_key key_lc unit device_class state_class cfg_topic unique_id sensor_name payload

    obj="$(sanitize_obj_id "${key}")"
    [[ -n "${obj}" ]] || continue

    key_lc="$(echo "${key}" | tr '[:upper:]' '[:lower:]')"
    unit="$(guess_unit "${key}")"
    device_class="$(guess_device_class "${key_lc}" "${unit}" "${media}")"
    state_class="$(guess_state_class "${key_lc}" "${device_class}")"

    cfg_topic="${DISCOVERY_PREFIX}/sensor/${uniq}/${obj}/config"
    unique_id="${uniq}_${obj}"
    sensor_name="${name} ${key}"

    # expire_after lets HA mark the entity unavailable once the meter
    # stops talking. Base it on the meter's observed average telegram
    # interval, multiplied by 2 for safety. Fall back to 3600s (1h)
    # before we have enough history — most consumer wMBus meters
    # transmit at intervals of 30s..1h, so 1h is a safe floor that
    # won't false-positive on fresh installs.
    local _seen_for_expire _avg_for_expire _s15_for_expire _s60_for_expire
    IFS=$'\t' read -r _seen_for_expire _avg_for_expire _s15_for_expire _s60_for_expire \
      < <(status_seen_stats "${id}" "meter")
    local expire_after=3600
    if [[ "${_avg_for_expire}" =~ ^[0-9]+$ ]]; then
      local _double=$(( _avg_for_expire * 2 ))
      if (( _double > expire_after )); then
        expire_after=${_double}
      fi
    fi
    # Round to nearest minute so small avg fluctuations don't churn
    # the discovery cache. Cache key includes the rounded value so
    # when expire_after changes (e.g. stats stabilize) HA gets an
    # updated config and the offline detection self-tunes.
    expire_after=$(( (expire_after / 60) * 60 ))

    cache_key="${id}|${obj}|${expire_after}"
    [[ -n "${DISCOVERY_SENT_FIELD[${cache_key}]+x}" ]] && continue

    payload="$(jq -c -n \
      --arg name "${sensor_name}" \
      --arg uniq "${unique_id}" \
      --arg st "${state_topic}" \
      --arg key "${key}" \
      --arg did "${uniq}" \
      --arg dname "${dev_name}" \
      --arg dmdl "${dev_mdl}" \
      --arg dmfr "${dev_mfr}" \
      --arg unit "${unit}" \
      --arg dc "${device_class}" \
      --arg sc "${state_class}" \
      --argjson expire "${expire_after}" \
      '(
        {
          name: $name,
          unique_id: $uniq,
          state_topic: $st,
          value_template: "{{ value_json.get('\''\($key)'\'') | default(none) }}",
          json_attributes_topic: $st,
          expire_after: $expire,
          device: {
            identifiers: [$did],
            name: $dname,
            model: $dmdl,
            manufacturer: $dmfr
          }
        }
        + (if ($unit|length)>0 then {unit_of_measurement:$unit} else {} end)
        + (if ($dc|length)>0 then {device_class:$dc} else {} end)
        + (if ($sc|length)>0 then {state_class:$sc} else {} end)
      )'
    )"

    if mqtt_pub "${cfg_topic}" "${payload}" "${DISCOVERY_RETAIN}"; then
      DISCOVERY_SENT_FIELD["${cache_key}"]=1
    else
      warn "discovery: failed to publish config for id=${id} field=${key} (will retry on next telegram)"
    fi
  done < <(
    jq -r '
      to_entries[]
      | select(.key as $k
        | ($k != "_")
        and ($k != "id")
        and ($k != "name")
        and ($k != "meter")
        and ($k != "media")
        and ($k != "timestamp")
        and ($k != "device_date_time")
        and ($k != "rssi")
        and ($k != "lqi")
      )
      | select((.value|type)=="number")
      | .key
    ' <<<"${json_line}" 2>/dev/null || true
  )
}


# ------------------------------------------------------------
# Search temporary meters must never create HA devices/entities.
# SEARCH uses temporary names search_<id> only to let wmbusmeters decode
# JSON values for matching. These decoded telegrams are internal search data,
# not real configured meters.
# ------------------------------------------------------------


is_search_temp_json() {
  local json_line="$1"
  [[ "${SEARCH_MODE}" == "true" ]] || return 1

  local name
  name="$(jq -r '.name // empty' <<<"${json_line}" 2>/dev/null || true)"
  [[ "${name}" == search_* ]]
}


clear_search_discovery_from_json() {
  local json_line="$1"

  is_search_temp_json "${json_line}" || return 0

  local id
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  # Clear older retained discovery configs if a previous buggy search run
  # already created HA entities. Use retain=true because MQTT Discovery
  # removal requires an empty retained config payload.
  clean_legacy_totalm3 "${id}"

  local uniq="wmbus_${id}"
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue

    local obj cache_key cfg_topic
    obj="$(sanitize_obj_id "${key}")"
    [[ -n "${obj}" ]] || continue

    cache_key="${id}|${obj}"
    [[ -n "${SEARCH_DISCOVERY_CLEARED_FIELD[${cache_key}]+x}" ]] && continue

    cfg_topic="${DISCOVERY_PREFIX}/sensor/${uniq}/${obj}/config"
    mqtt_pub "${cfg_topic}" "" "true" || true
    SEARCH_DISCOVERY_CLEARED_FIELD["${cache_key}"]=1
  done < <(
    jq -r '
      to_entries[]
      | select(.key as $k
        | ($k != "_")
        and ($k != "id")
        and ($k != "name")
        and ($k != "meter")
        and ($k != "media")
        and ($k != "timestamp")
        and ($k != "device_date_time")
        and ($k != "rssi")
        and ($k != "lqi")
      )
      | select((.value|type)=="number")
      | .key
    ' <<<"${json_line}" 2>/dev/null || true
  )
}

# ------------------------------------------------------------


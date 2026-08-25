declare -A DISCOVERY_SENT_FIELD


declare -A DISCOVERY_CLEANED_LEGACY


declare -A SEARCH_DISCOVERY_CLEARED_FIELD


clean_legacy_entities() {
  local id
  [[ "${DISCOVERY_ENABLED}" == "true" ]] || return 0
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  # rssi_dbm was the first shape of the opt-in RSSI join: one merged value per
  # meter, whichever board reported last. Per-board rssi_<esp>_dbm replaced it,
  # so the retained config has to be cleared or Home Assistant keeps showing the
  # old entity for every meter that ever had one.
  if [[ -z "${DISCOVERY_CLEANED_LEGACY[${id}]+x}" ]]; then
    if mqtt_pub "${DISCOVERY_PREFIX}/sensor/wmbus_${id}/total_m3/config" "" "true" \
      && mqtt_pub "${DISCOVERY_PREFIX}/sensor/wmbus_${id}/rssi_dbm/config" "" "true"; then
      DISCOVERY_CLEANED_LEGACY["${id}"]=1
    else
      warn "discovery: failed to clear legacy entities for id=${id} (will retry later)"
    fi
  fi
}


emit_discovery_from_json() {
  local json_line="$1"
  [[ "${DISCOVERY_ENABLED}" == "true" ]] || return 0

  local id name meter media
  id="$(normalize_meter_id "$(jq -r '.id // empty' <<<"${json_line}" 2>/dev/null || true)")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  clean_legacy_entities "${id}"

  name="$(jq -r '.name // .id // "wmbus"' <<<"${json_line}" 2>/dev/null || true)"
  meter="$(jq -r '.meter // empty' <<<"${json_line}" 2>/dev/null || true)"
  media="$(jq -r '.media // empty' <<<"${json_line}" 2>/dev/null || true)"

  local uniq="wmbus_${id}"
  local state_topic="${STATE_PREFIX}/${id}/state"
  local dev_name="${name} (${id})"
  local dev_mdl="${meter:-wmbusmeter}"
  local dev_mfr="wmbusmeters"

  # expire_after lets HA mark the entity unavailable once the meter stops
  # talking. Base it on the meter's observed average telegram interval, x2 for
  # safety, falling back to 3600s (1h) before we have history. It depends only
  # on the meter id (identical for every field), so compute it once here and
  # reuse it for the measurement loop and the status entities below.
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
  # Round to nearest minute so small avg fluctuations don't churn the discovery
  # cache. Cache key includes the rounded value so when expire_after changes
  # (e.g. stats stabilize) HA gets an updated config and offline detection
  # self-tunes.
  expire_after=$(( (expire_after / 60) * 60 ))

  # Field loop. The feeder below emits "<json type><TAB><key>" for every field
  # the driver publishes, so one payload builder covers them all. The split is
  # by what the field measures, not by its JSON type:
  #
  #   - a numeric field that HA can classify (device_class) or that carries a
  #     consumption unit (m³/GJ/MJ/kWh/Wh/l, incl. heat volume where HA has no
  #     device_class) stays a plain measurement sensor, enabled;
  #   - everything else — numeric fields with no class (record ages, error
  #     counters), text fields (status words, datetimes) and fields the driver
  #     currently reports as null (fraud_date before any fraud) — becomes a
  #     diagnostic sensor published with enabled_by_default:false.
  #
  # NB enabled_by_default is read by HA only when it first adds an entity, so
  # this never disables an entity that already exists; entity_category IS
  # re-applied on every config update, so previously created fields do move
  # into the device's Diagnostics section.
  while IFS=$'\t' read -r ftype key; do
    [[ -n "${key}" ]] || continue

    local obj cache_key key_lc unit device_class state_class entity_category cfg_topic unique_id sensor_name payload field_desc

    obj="$(sanitize_obj_id "${key}")"
    [[ -n "${obj}" ]] || continue

    # Field excluded by this meter's configuration. Clearing the retained config
    # once (rather than only skipping the publish) is what makes the option act
    # on entities that already exist: an empty retained payload is the MQTT
    # Discovery removal protocol, so Home Assistant drops the entity instead of
    # leaving it behind to expire.
    if field_excluded_for_meter "${id}" "${key}"; then
      cache_key="${id}|${obj}|excluded"
      if [[ -z "${DISCOVERY_SENT_FIELD[${cache_key}]+x}" ]]; then
        if mqtt_pub "${DISCOVERY_PREFIX}/sensor/${uniq}/${obj}/config" "" "true"; then
          DISCOVERY_SENT_FIELD["${cache_key}"]=1
          log "discovery: field ${key} excluded for id=${id} (config cleared)"
        fi
      fi
      continue
    fi

    key_lc="$(echo "${key}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${ftype}" == "number" ]]; then
      unit="$(guess_unit "${key}")"
      device_class="$(guess_device_class "${key_lc}" "${unit}" "${media}")"
      state_class="$(guess_state_class "${key_lc}" "${device_class}")"
      if [[ -n "${device_class}" ]] || is_consumption_unit "${unit}"; then
        entity_category=""
      else
        entity_category="diagnostic"
      fi
    else
      unit=""
      device_class=""
      state_class=""
      entity_category="diagnostic"
    fi

    cfg_topic="${DISCOVERY_PREFIX}/sensor/${uniq}/${obj}/config"
    unique_id="${uniq}_${obj}"
    sensor_name="${name} ${key}"
    # The driver's own words for this field, surfaced as an entity attribute.
    # Looked up here rather than per telegram: the block below runs once per
    # entity, guarded by the DISCOVERY_SENT_FIELD cache.
    field_desc="$(field_description "${meter}" "${key}")"

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
      --arg ecat "${entity_category}" \
      --arg desc "${field_desc}" \
      --argjson expire "${expire_after}" \
      '(
        {
          name: $name,
          unique_id: $uniq,
          state_topic: $st,
          value_template: "{{ value_json.get('\''\($key)'\'') | default(none) }}",
          availability: [
            {
              topic: $st,
              value_template: "{{ '\''online'\'' if value_json.get('\''\($key)'\'') is not none else '\''offline'\'' }}"
            }
          ],
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
        + (if ($ecat|length)>0 then {entity_category:$ecat, enabled_by_default:false} else {} end)
        # The attributes topic already carries the whole decoded telegram, and
        # there is only one of them per entity — so the description is MERGED
        # into that payload rather than replacing it. Without the merge, adding
        # the description would cost the pass-through every other field relies on.
        + (if ($desc|length)>0
           then {json_attributes_template: "{{ dict(value_json, Description=\"\($desc)\") | tojson }}"}
           else {} end)
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
        and ($k != "status")
      )
      | select((.value|type) != "object" and (.value|type) != "array")
      | "\(.value|type)\t\(.key)"
    ' <<<"${json_line}" 2>/dev/null || true
  )

  # --- status diagnostic entities ---
  # The wmbusmeters "status" field is a string (OK, or space-separated error
  # flags), so it never matches the numeric filter above and would get no
  # entity. Surface it explicitly as two diagnostic entities under the same
  # device: a text sensor with the raw status, and a binary_sensor
  # (device_class problem) that is ON for any non-OK value. Passthrough only --
  # the text shown is exactly what wmbusmeters emits; the only literal is the
  # OK baseline (wmbusmeters' default_message for the error-flags lookup).
  local has_status
  has_status="$(jq -r 'has("status")' <<<"${json_line}" 2>/dev/null || echo false)"
  if [[ "${has_status}" == "true" ]] && ! field_excluded_for_meter "${id}" "status"; then
    local st_cache st_cfg st_payload bp_cache bp_cfg bp_payload

    st_cache="${id}|status|${expire_after}"
    if [[ -z "${DISCOVERY_SENT_FIELD[${st_cache}]+x}" ]]; then
      st_cfg="${DISCOVERY_PREFIX}/sensor/${uniq}/status/config"
      st_payload="$(jq -c -n \
        --arg name "${name} status" \
        --arg uniq "${uniq}_status" \
        --arg st "${state_topic}" \
        --arg did "${uniq}" \
        --arg dname "${dev_name}" \
        --arg dmdl "${dev_mdl}" \
        --arg dmfr "${dev_mfr}" \
        --arg desc "$(field_description "${meter}" "status")" \
        --argjson expire "${expire_after}" \
        '{
           name: $name,
           unique_id: $uniq,
           state_topic: $st,
           value_template: "{{ value_json.get('\''status'\'') | default(none) }}",
           availability: [
             {
               topic: $st,
               value_template: "{{ '\''online'\'' if value_json.get('\''status'\'') is not none else '\''offline'\'' }}"
             }
           ],
           json_attributes_topic: $st,
           entity_category: "diagnostic",
           icon: "mdi:alert-circle-outline",
           expire_after: $expire,
           device: {
             identifiers: [$did],
             name: $dname,
             model: $dmdl,
             manufacturer: $dmfr
           }
         }
         + (if ($desc|length)>0
            then {json_attributes_template: "{{ dict(value_json, Description=\"\($desc)\") | tojson }}"}
            else {} end)')"
      if mqtt_pub "${st_cfg}" "${st_payload}" "${DISCOVERY_RETAIN}"; then
        DISCOVERY_SENT_FIELD["${st_cache}"]=1
      else
        warn "discovery: failed to publish status sensor for id=${id} (will retry on next telegram)"
      fi
    fi

    bp_cache="${id}|status_problem|${expire_after}"
    if [[ -z "${DISCOVERY_SENT_FIELD[${bp_cache}]+x}" ]]; then
      bp_cfg="${DISCOVERY_PREFIX}/binary_sensor/${uniq}/status_problem/config"
      bp_payload="$(jq -c -n \
        --arg name "${name} problem" \
        --arg uniq "${uniq}_status_problem" \
        --arg st "${state_topic}" \
        --arg did "${uniq}" \
        --arg dname "${dev_name}" \
        --arg dmdl "${dev_mdl}" \
        --arg dmfr "${dev_mfr}" \
        --argjson expire "${expire_after}" \
        '{
           name: $name,
           unique_id: $uniq,
           state_topic: $st,
           value_template: "{{ '\''ON'\'' if value_json.get('\''status'\'') not in [none, '\''OK'\'', '\'''\''] else '\''OFF'\'' }}",
           payload_on: "ON",
           payload_off: "OFF",
           device_class: "problem",
           availability: [
             {
               topic: $st,
               value_template: "{{ '\''online'\'' if value_json.get('\''status'\'') is not none else '\''offline'\'' }}"
             }
           ],
           entity_category: "diagnostic",
           expire_after: $expire,
           device: {
             identifiers: [$did],
             name: $dname,
             model: $dmdl,
             manufacturer: $dmfr
           }
         }')"
      if mqtt_pub "${bp_cfg}" "${bp_payload}" "${DISCOVERY_RETAIN}"; then
        DISCOVERY_SENT_FIELD["${bp_cache}"]=1
      else
        warn "discovery: failed to publish status problem binary_sensor for id=${id} (will retry on next telegram)"
      fi
    fi
  elif [[ "${has_status}" == "true" ]]; then
    # Excluding "status" has to take both entities of the dedicated pair with
    # it, otherwise the problem binary_sensor would survive the text sensor it
    # reports on.
    local st_excl_cache="${id}|status|excluded"
    if [[ -z "${DISCOVERY_SENT_FIELD[${st_excl_cache}]+x}" ]]; then
      mqtt_pub "${DISCOVERY_PREFIX}/sensor/${uniq}/status/config" "" "true" || true
      mqtt_pub "${DISCOVERY_PREFIX}/binary_sensor/${uniq}/status_problem/config" "" "true" || true
      DISCOVERY_SENT_FIELD["${st_excl_cache}"]=1
      log "discovery: field status excluded for id=${id} (sensor and problem binary_sensor cleared)"
    fi
  fi
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
  clean_legacy_entities "${id}"

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
        and ($k != "status")
      )
      | select((.value|type) != "object" and (.value|type) != "array")
      | .key
    ' <<<"${json_line}" 2>/dev/null || true
  )

  # Mirror emit_discovery_from_json's status block: clear the status diagnostic
  # entities too, in case a previous buggy search run created them.
  if [[ -z "${SEARCH_DISCOVERY_CLEARED_FIELD[${id}|status]+x}" ]]; then
    mqtt_pub "${DISCOVERY_PREFIX}/sensor/${uniq}/status/config" "" "true" || true
    mqtt_pub "${DISCOVERY_PREFIX}/binary_sensor/${uniq}/status_problem/config" "" "true" || true
    SEARCH_DISCOVERY_CLEARED_FIELD["${id}|status"]=1
  fi
}

# Remove ALL retained MQTT Discovery configs for one meter id, so its Home
# Assistant entities disappear (factory reset). Enumerates the retained
# per-field config topics the same way discovery_doctor_probe counts them
# (subscribe with a short bounded -W to the wildcard config topic) and clears
# each with an empty retained payload — the MQTT Discovery removal protocol.
# Unlike clear_search_discovery_from_json this is keyed on a bare id (no JSON
# telegram needed) and clears whatever is actually retained on the broker.
clear_meter_discovery() {
  [[ "${DISCOVERY_ENABLED}" == "true" ]] || return 0
  local id
  id="$(normalize_meter_id "$1")"
  [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || return 0

  clean_legacy_entities "${id}"

  local topic _rest
  while read -r topic _rest; do
    [[ -n "${topic}" ]] || continue
    case "${topic}" in
      "${DISCOVERY_PREFIX}/sensor/wmbus_${id}/"*/config | "${DISCOVERY_PREFIX}/binary_sensor/wmbus_${id}/"*/config)
        mqtt_pub "${topic}" "" "true" || true ;;
    esac
  done < <(timeout 5 /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -W 2 -v \
      -t "${DISCOVERY_PREFIX}/sensor/wmbus_${id}/+/config" \
      -t "${DISCOVERY_PREFIX}/binary_sensor/wmbus_${id}/+/config" 2>/dev/null || true)
}

# Per-ESP coverage sensor: how many DISTINCT meters that board has heard this
# session, published as its own Home Assistant entity.
#
# WHY THIS EXISTS: unique-meter coverage is the measurement this project actually
# cares about - it is what separates a sensitive board from a deaf one, and
# drop_pct notoriously IMPROVES when reception gets worse, because a frame that is
# never attempted is never counted as dropped. Yet that number lived only in
# status_esp_rx_reception.tsv, which is session-scoped and wiped on every add-on
# restart, while far less interesting frame counters already had permanent history
# in HA. Publishing it as a measurement sensor puts it into HA long-term
# statistics - and therefore InfluxDB and Grafana - like any other sensor.
#
# The count is session-scoped by nature: it can only mean "distinct meters since
# this session began". Recorded over time that is exactly what is wanted - the
# curve climbs while a board discovers meters and its plateau is real coverage.
declare -A ESP_COVERAGE_CFG_SENT
ESP_COVERAGE_LAST_S=0
ESP_COVERAGE_INTERVAL_S="${ESP_COVERAGE_INTERVAL_S:-60}"

publish_esp_coverage() {
  [[ "${DISCOVERY_ENABLED:-true}" == "true" ]] || return 0
  [[ -s "${STATUS_ESP_RX_RECEPTION_FILE}" ]] || return 0

  # Throttled: the heartbeat ticker runs every few seconds and this rereads the
  # whole reception table. Once a minute is plenty for a number that moves in
  # steps of one.
  local _now
  _now="$(epoch_now)"
  (( _now - ESP_COVERAGE_LAST_S >= ESP_COVERAGE_INTERVAL_S )) || return 0
  ESP_COVERAGE_LAST_S="${_now}"

  # Column 1 = meter id, column 2 = source board (_upsert_esp_meter_reception).
  local _total
  _total="$(awk -F '\t' 'NF>=2 && $1!="" {a[$1]=1} END{print length(a)+0}' "${STATUS_ESP_RX_RECEPTION_FILE}" 2>/dev/null || echo 0)"
  [[ "${_total}" =~ ^[0-9]+$ ]] && (( _total > 0 )) || return 0

  local _src _meters _frames _uniq _cfg_topic _state_topic _attr_topic _payload
  while IFS=$'\t' read -r _src _meters _frames; do
    [[ -n "${_src}" ]] || continue
    # The board name arrives from an MQTT topic segment, so validate it before it
    # becomes a unique_id and a topic of ours.
    [[ "${_src}" =~ ^[A-Za-z0-9_-]+$ ]] || continue

    _uniq="wmbus_${_src}_meters_heard"
    _cfg_topic="${DISCOVERY_PREFIX}/sensor/${_uniq}/config"
    _state_topic="${STATE_PREFIX}/bridge/coverage/${_src}/state"
    _attr_topic="${STATE_PREFIX}/bridge/coverage/${_src}/attrs"

    if [[ -z "${ESP_COVERAGE_CFG_SENT[${_src}]+x}" ]]; then
      # Explicit name instead of has_entity_name: it yields
      # sensor.wmbus_<board>_meters_heard, matching the naming the ESP diagnostic
      # sensors already use, so both sit together in one Grafana query.
      _payload="$(jq -c -n \
        --arg name "wmbus ${_src} meters_heard" \
        --arg uniq "${_uniq}" \
        --arg st "${_state_topic}" \
        --arg at "${_attr_topic}" \
        '{
           name: $name,
           unique_id: $uniq,
           state_topic: $st,
           json_attributes_topic: $at,
           state_class: "measurement",
           icon: "mdi:access-point-network",
           device: {
             identifiers: ["wmbus_bridge_coverage"],
             name: "wMBus Bridge",
             model: "per-board meter coverage",
             manufacturer: "wmbus-mqtt-bridge"
           }
         }' 2>/dev/null)"
      if [[ -n "${_payload}" ]] && mqtt_pub "${_cfg_topic}" "${_payload}" "${DISCOVERY_RETAIN}"; then
        ESP_COVERAGE_CFG_SENT["${_src}"]=1
      fi
    fi

    mqtt_pub "${_state_topic}" "${_meters}" "true" || true
    # coverage_pct is measured against every meter ANY board heard, so it answers
    # "how much of what is out there does this one get?" - the question a second
    # board is bought to answer.
    _payload="$(jq -c -n \
      --argjson meters "${_meters}" \
      --argjson frames "${_frames}" \
      --argjson total "${_total}" \
      '{meters_heard: $meters, frames: $frames, meters_total_all_boards: $total,
        coverage_pct: (if $total > 0 then (($meters * 1000 / $total) | floor) / 10 else 0 end)}' 2>/dev/null)"
    [[ -n "${_payload}" ]] && { mqtt_pub "${_attr_topic}" "${_payload}" "true" || true; }
  done < <(
    awk -F '\t' '
      NF>=2 && $1!="" && $2!="" {
        k = $2 SUBSEP $1
        if (!(k in seen)) { seen[k] = 1; meters[$2]++ }
        frames[$2] += ($5 ~ /^[0-9]+$/) ? $5 : 0
      }
      END { for (s in meters) printf "%s\t%d\t%d\n", s, meters[s], frames[s] }
    ' "${STATUS_ESP_RX_RECEPTION_FILE}" 2>/dev/null
  )
}


# Canary entity for the opt-in HA verification (verify_ha_entities).
# A hidden diagnostic sensor with a STABLE entity_id (sensor.wmbus_bridge_health)
# that lets the verification worker ask HA Core API "did you create this entity?".
# Published once per bridge start (via mqtt_pub directly, not via the rate-limited
# field cache). NB: stable object_id "wmbus_bridge_health" -> entity_id is
# predictable regardless of user labels, so the API check is reliable.
publish_canary_entity() {
  [[ "${VERIFY_HA_ENTITIES:-false}" == "true" ]] || return 0
  [[ "${DISCOVERY_ENABLED:-true}" == "true" ]] || return 0
  local uniq="wmbus_bridge_health"
  local cfg_topic="${DISCOVERY_PREFIX}/sensor/${uniq}/config"
  local state_topic="${STATE_PREFIX}/${uniq}/state"
  # NB: has_entity_name + short name "Health" so HA composes the friendly name as
  # "wMBus Bridge Health" (device + entity) instead of doubling like
  # "wMBus Bridge wMBus Bridge health" we hit in the wild. object_id is dropped —
  # the verification worker queries by unique attributes via HA template, not by
  # entity_id, so we never depend on HA's slugification rules.
  local payload
  payload="$(jq -c -n \
    --arg name "Health" \
    --arg uniq "${uniq}" \
    --arg st "${state_topic}" \
    --arg did "${uniq}" \
    '{
       name: $name,
       has_entity_name: true,
       unique_id: $uniq,
       state_topic: $st,
       entity_category: "diagnostic",
       icon: "mdi:check-network",
       device: {
         identifiers: [$did],
         name: "wMBus Bridge",
         model: "MQTT->HA verification canary",
         manufacturer: "wmbus-mqtt-bridge"
       }
     }' 2>/dev/null)"
  [[ -n "${payload}" ]] || return 0
  mqtt_pub "${cfg_topic}" "${payload}" "${DISCOVERY_RETAIN}" || true
  mqtt_pub "${state_topic}" "ok" "true" || true
  log "verify_ha_entities: published canary entity ${uniq}"
}

# ------------------------------------------------------------
# Discovery Doctor — on-demand broker probe behind the WebUI checklist.
# webui.py touches DISCOVERY_DOCTOR_REQUEST_FILE; the heartbeat ticker in
# bridge.sh calls discovery_doctor_probe, which subscribes (with the same
# credentials the bridge publishes with) to:
#   - <DISCOVERY_PREFIX>/status            — HA's retained birth message; a
#     retained "online" here proves the HA MQTT integration listens on THIS
#     prefix on THIS broker,
#   - <DISCOVERY_PREFIX>/sensor/wmbus_<id>/+/config per configured meter —
#     retained config messages are delivered immediately on subscribe, so a
#     short bounded wait (-W) is enough to count them and capture one sample
#     payload for the WebUI preview.
# Results land atomically in STATUS_DISCOVERY_DOCTOR_FILE (JSON).
discovery_doctor_probe() {
  local out="${STATUS_DISCOVERY_DOCTOR_FILE}"
  local tmp id line count payload ha_status meters_json ids
  tmp="$(mktemp "${out}.tmp.XXXXXX")" || return 0

  ha_status="$(timeout 5 /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -C 1 -W 3 \
      -t "${DISCOVERY_PREFIX}/status" 2>/dev/null | head -n 1 || true)"

  meters_json="[]"
  ids="$(jq -r '.meters[]?.meter_id // empty' "${OPTIONS_JSON}" 2>/dev/null | head -n 50 || true)"
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    id="$(normalize_meter_id "${id}")"
    [[ "${id}" =~ ^[0-9A-Fa-f]{8}$ ]] || continue
    count=0
    payload=""
    while IFS= read -r line; do
      [[ -n "${line}" ]] || continue
      count=$((count + 1))
      [[ -n "${payload}" ]] || payload="${line}"
    done < <(timeout 5 /usr/bin/mosquitto_sub "${SUB_ARGS[@]}" -W 2 -v \
        -t "${DISCOVERY_PREFIX}/sensor/wmbus_${id}/+/config" 2>/dev/null || true)
    meters_json="$(jq -c \
      --arg id "${id}" \
      --argjson n "${count}" \
      --arg sample "${payload:0:2000}" \
      '. + [{id: $id, retained_configs: $n, sample: $sample}]' \
      <<<"${meters_json}" 2>/dev/null || printf '%s' "${meters_json}")"
  done <<< "${ids}"

  if jq -n -c \
      --arg ts "$(iso_now)" \
      --arg prefix "${DISCOVERY_PREFIX}" \
      --arg ha_status "${ha_status}" \
      --arg enabled "${DISCOVERY_ENABLED}" \
      --arg retain "${DISCOVERY_RETAIN}" \
      --argjson meters "${meters_json}" \
      '{ts: $ts, discovery_prefix: $prefix, ha_status_topic: $ha_status,
        discovery_enabled: ($enabled == "true"),
        discovery_retain: ($retain == "true"), meters: $meters}' \
      > "${tmp}" 2>/dev/null; then
    mv "${tmp}" "${out}" 2>/dev/null || rm -f "${tmp}"
  else
    rm -f "${tmp}"
  fi
}

# ------------------------------------------------------------


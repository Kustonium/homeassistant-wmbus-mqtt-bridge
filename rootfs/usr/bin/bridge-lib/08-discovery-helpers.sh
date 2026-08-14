#!/usr/bin/env bash

guess_unit() {
  local k
  k="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "${k}" in
    *_kvarh)   echo "kVARh";;
    *_kvah)    echo "kVAh";;
    *_m3c)     echo "m³°C";;
    *_m3ch)    echo "m³°C/h";;
    *_m3h)     echo "m³/h";;
    *_mjh)     echo "MJ/h";;
    *_kvar)    echo "kVAR";;
    *_kva)     echo "kVA";;
    *_kwh)     echo "kWh";;
    *_kw)      echo "kW";;
    *_wh)      echo "Wh";;
    *_w)       echo "W";;
    *_lh)      echo "l/h";;
    *_jh)      echo "J/h";;
    *_gj)      echo "GJ";;
    *_mj)      echo "MJ";;
    *_dbm)     echo "dBm";;
    *_hca)     echo "hca";;
    *_pct)     echo "%";;
    *_ppm)     echo "ppm";;
    *_rh|*humidity*|*hum*) echo "%";;
    *_hz)      echo "Hz";;
    *_bar)     echo "bar";;
    *_pa|*pressure*|*_hpa) echo "hPa";;
    *_m3|*volume*|*m3*)    echo "m³";;
    *_mol)     echo "mol";;
    *_min)     echo "min";;
    *_rad)     echo "rad";;
    *_deg)     echo "°";;
    *_utc|*_ut|*_datetime|*_date|*_time|*_month) echo "";;
    *_counter) echo "";;
    *_factor)  echo "";;
    *_txt)     echo "";;
    *_nr)      echo "";;
    *_kg)      echo "kg";;
    *_cd)      echo "cd";;
    *_v)       echo "V";;
    *_a)       echo "A";;
    *_k)       echo "K";;
    *temperature*|*temp*|*_c) echo "°C";;
    *_f)       echo "°F";;
    *_l)       echo "l";;
    *_m)       echo "m";;
    *_s)       echo "s";;
    *_h)       echo "h";;
    *_d)       echo "d";;
    *_y)       echo "y";;
    *)         echo "";;
  esac
}

guess_device_class() {
  local key_lc="$1"
  local unit="$2"
  local media="${3:-}"
  case "${unit}" in
    "°C") echo "temperature";;
    "%") echo "humidity";;
    "W"|"kW") echo "power";;
    "Wh"|"kWh") echo "energy";;
    "V") echo "voltage";;
    "A") echo "current";;
    "Hz") echo "frequency";;
    "dBm") echo "signal_strength";;
    "m³")
      # Prefer the media reported by wmbusmeters — it knows the meter's
      # nature better than a keyword match against the field name. Heat
      # meters carry volume too, but HA has no "heat-volume" class, so
      # we deliberately leave device_class empty for them.
      case "${media}" in
        water|warm_water|hot_water|cold_water) echo "water";;
        gas) echo "gas";;
        heat|cooling) echo "";;
        *)
          # Unknown media → fall back to old keyword heuristic.
          if [[ "${key_lc}" == *gas* ]]; then echo "gas"; else echo "water"; fi
          ;;
      esac
      ;;
    *)
      # battery device_class requires 0-100 % in HA.
      # Only apply when unit is empty or % — fields like battery_v (volts)
      # or battery_y (years) must NOT get device_class: battery.
      if [[ "${key_lc}" == *battery* && ( -z "${unit}" || "${unit}" == "%" ) ]]; then
        echo "battery"
      else
        echo ""
      fi
      ;;
  esac
}

# Field descriptions written by the driver author, from
# `wmbusmeters --listfields=<driver>`. Keyed "<driver>|<pattern>"; the catalog
# uses templated names for repeated fields
# (consumption_at_history_{storage_counter-7counter}_m3), so lookups match with
# a glob rather than by equality. Loaded once per driver — the decoder binary is
# pinned, so its catalog cannot change while the container runs.
declare -A FIELD_CATALOG
declare -A FIELD_CATALOG_LOADED
declare -A FIELD_DESCRIPTION_CACHE
# Overridable so the test suite can point the catalog loader at a stub and
# exercise the parser without the decoder binary.
WMBUSMETERS_BIN="${WMBUSMETERS_BIN:-/usr/bin/wmbusmeters}"

load_field_catalog() {
  local driver="${1,,}"
  [[ -n "${driver}" && "${driver}" != "auto" && "${driver}" != "unknown" ]] || return 0
  [[ "${driver}" =~ ^[a-z0-9_]+$ ]] || return 0
  [[ -z "${FIELD_CATALOG_LOADED[${driver}]+x}" ]] || return 0
  FIELD_CATALOG_LOADED["${driver}"]=1

  local line name desc
  # --listfields prints "<padding><name><2+ spaces><description>". The split is
  # done with bash parameter expansion rather than sed: the add-on image is
  # Alpine and ships busybox sed, which does not turn a "\t" in the replacement
  # into a tab the way GNU sed does. Descriptions contain single spaces, so
  # splitting on any whitespace would truncate them.
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "${line}" ]] || continue
    name="${line%%  *}"
    if [[ "${name}" == "${line}" ]]; then
      desc=""
    else
      desc="${line#"${name}"}"
      desc="${desc#"${desc%%[![:space:]]*}"}"
    fi
    [[ -n "${name}" ]] || continue
    # Quotes and backslashes would land inside a Jinja string literal in the
    # Discovery payload; drop them rather than escape through two layers.
    desc="${desc//\"/}"
    desc="${desc//\\/}"
    FIELD_CATALOG["${driver}|${name}"]="${desc}"
  done < <(timeout 10 "${WMBUSMETERS_BIN}" "--listfields=${driver}" 2>/dev/null || true)
}

# Description for one decoded field, or empty. Memoised per driver+field so the
# glob scan runs once per entity rather than once per telegram.
field_description() {
  local driver="${1,,}" key="${2,,}"
  [[ -n "${driver}" && -n "${key}" ]] || return 0
  local cache="${driver}|${key}"
  if [[ -n "${FIELD_DESCRIPTION_CACHE[${cache}]+x}" ]]; then
    printf '%s' "${FIELD_DESCRIPTION_CACHE[${cache}]}"
    return 0
  fi
  load_field_catalog "${driver}"
  local entry pattern found=""
  for entry in "${!FIELD_CATALOG[@]}"; do
    [[ "${entry}" == "${driver}|"* ]] || continue
    pattern="${entry#*|}"
    # Templated placeholders behave as a wildcard for the concrete field name.
    pattern="${pattern//\{*\}/*}"
    # shellcheck disable=SC2053
    if [[ "${key}" == ${pattern,,} ]]; then
      found="${FIELD_CATALOG[${entry}]}"
      break
    fi
  done
  FIELD_DESCRIPTION_CACHE["${cache}"]="${found}"
  printf '%s' "${found}"
}

# Per-meter Discovery field filter, keyed by lowercase meter id; the value is a
# whitespace-separated list of glob patterns. Declared here, beside the function
# that reads it, rather than in 07-meters.sh where refresh_meter_files() fills
# it: an undeclared associative array makes bash evaluate the subscript as
# arithmetic, and a meter id with a leading zero then aborts the lookup with
# "value too great for base". Declaring it next to its consumer removes the
# dependency on library sourcing order.
declare -A METER_EXCLUDE_FIELDS

# Has this meter's configuration excluded this field from Discovery?
# METER_EXCLUDE_FIELDS holds whitespace-separated glob patterns per lowercase
# meter id (filled by refresh_meter_files). Matching is case-insensitive and
# uses shell globs, so one pattern covers a whole family of fields — the case
# this exists for is a driver like evo868, which reports twelve monthly history
# readings plus twelve matching dates on every telegram.
field_excluded_for_meter() {
  local id="${1,,}" key="${2,,}" patterns pat
  patterns="${METER_EXCLUDE_FIELDS[${id}]:-}"
  [[ -n "${patterns}" ]] || return 1
  for pat in ${patterns}; do
    # Unquoted on purpose: this is a glob match, not a string comparison.
    # shellcheck disable=SC2053
    [[ "${key}" == ${pat,,} ]] && return 0
  done
  return 1
}

# Does this unit measure the quantity the meter bills for (volume, energy,
# allocation units)? Used to decide whether a field is a primary measurement or
# a diagnostic: device_class alone is not enough, because Home Assistant has no
# class for several billing quantities. guess_device_class deliberately returns
# an empty class for m³ on heat/cooling meters, and GJ/MJ, hca (heat cost
# allocator units — the whole reading of an fhkvdataiii-style device) and
# kVARh/kVAh carry no HA device_class at all. All of them are consumption.
is_consumption_unit() {
  case "$1" in
    "m³"|"GJ"|"MJ"|"kWh"|"Wh"|"l"|"hca"|"kVARh"|"kVAh") return 0;;
    *) return 1;;
  esac
}

guess_state_class() {
  local key_lc="$1"
  local device_class="$2"

  # total_increasing — cumulative counters that only go up
  if [[ "${key_lc}" == total_* || "${key_lc}" == *_total* || "${key_lc}" == *total_* ]]; then
    if [[ "${device_class}" == "energy" || "${device_class}" == "water" || "${device_class}" == "gas" ]]; then
      echo "total_increasing"; return 0
    fi
  fi

  if [[ "${device_class}" == "energy" && ( "${key_lc}" == *consumption* || "${key_lc}" == *production* ) ]]; then
    echo "total_increasing"; return 0
  fi

  if [[ "${key_lc}" == *backflow* ]]; then
    if [[ "${device_class}" == "water" || "${device_class}" == "gas" ]]; then
      echo "total_increasing"; return 0
    fi
  fi

  # measurement — only for fields where a long-term statistic actually
  # makes sense. Unknown numeric fields (error codes, status flags,
  # index numbers, version strings cast to int) get no state_class so
  # HA doesn't graph them as time series.
  case "${device_class}" in
    temperature|humidity|power|voltage|current|frequency|signal_strength|battery|water|gas|energy)
      echo "measurement"; return 0
      ;;
  esac

  echo ""
}

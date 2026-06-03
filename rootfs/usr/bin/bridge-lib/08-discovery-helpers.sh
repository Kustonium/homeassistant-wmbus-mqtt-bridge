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

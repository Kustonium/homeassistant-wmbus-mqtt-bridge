#!/usr/bin/env bash

json_get() {
  local expr="$1"
  local def="${2:-}"
  if [[ -f "${OPTIONS_JSON}" ]]; then
    local v
    v="$(jq -r "${expr} // empty" "${OPTIONS_JSON}" 2>/dev/null || true)"
    if [[ -n "${v}" && "${v}" != "null" ]]; then
      echo "${v}"
      return 0
    fi
  fi
  echo "${def}"
}

json_get_bool() {
  local expr="$1"
  local def="${2:-true}"
  local v
  v="$(json_get "${expr}" "")"
  if [[ "${v}" == "true" || "${v}" == "false" ]]; then
    echo "${v}"
  else
    echo "${def}"
  fi
}

json_get_int() {
  local expr="$1"
  local def="${2:-0}"
  local v
  v="$(json_get "${expr}" "")"
  if [[ "${v}" =~ ^-?[0-9]+$ ]]; then
    echo "${v}"
  else
    echo "${def}"
  fi
}

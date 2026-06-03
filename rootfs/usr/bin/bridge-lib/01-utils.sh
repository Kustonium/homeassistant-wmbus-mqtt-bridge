#!/usr/bin/env bash

iso_now() {
  date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

epoch_now() {
  date +%s 2>/dev/null || echo 0
}

sanitize_obj_id() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9_]/_/g' -e 's/__*/_/g' -e 's/^_//' -e 's/_$//'
}

float_or_default() {
  local value="$1"
  local def="$2"
  local normalized

  # Accept both decimal separators in add-on UI/options:
  #   22.901 and 22,901 are treated as the same value.
  # Spaces are ignored so pasted values like "22,901 " do not break search mode.
  normalized="$(echo "${value}" | tr -d '[:space:]' | tr ',' '.')"

  if [[ "${normalized}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
    echo "${normalized}"
  else
    warn "Invalid numeric value '${value}', using default '${def}'. Use 22.901 or 22,901 format."
    echo "${def}"
  fi
}

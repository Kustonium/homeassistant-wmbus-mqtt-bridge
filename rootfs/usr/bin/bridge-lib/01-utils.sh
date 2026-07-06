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

# Adaptive reconnect pause for the background mosquitto_sub loops. Call with
# the epoch taken just before the subscriber (re)connected and an optional
# base delay (default 5 s). A run of >=30 s counts as a healthy connection and
# resets the delay to the base; a run that died sooner (typical for rejected
# credentials — the broker answers instantly with "not authorised") doubles
# the delay up to a 120 s cap. Without this, ~10 reconnect loops retrying
# every 1-5 s hammered the broker with ~200 connections/min for as long as the
# password stayed wrong (observed live: EMQX throttling
# authentication_failure log events from this add-on's host).
# Uses one per-process variable (_SUB_RETRY_DELAY); every subscriber loop runs
# in its own subshell, so the state never leaks between loops.
_sub_reconnect_sleep() {
  local _started="$1" _base="${2:-5}" _now _ran
  _now="$(date +%s 2>/dev/null || echo 0)"
  _ran=$(( _now - _started ))
  if (( _ran >= 30 )); then
    _SUB_RETRY_DELAY="${_base}"
  else
    _SUB_RETRY_DELAY=$(( ${_SUB_RETRY_DELAY:-${_base}} * 2 ))
    (( _SUB_RETRY_DELAY > 120 )) && _SUB_RETRY_DELAY=120
  fi
  sleep "${_SUB_RETRY_DELAY}"
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

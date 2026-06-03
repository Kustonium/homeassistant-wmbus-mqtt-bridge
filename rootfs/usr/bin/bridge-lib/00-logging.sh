#!/usr/bin/env bash

log()         { echo "[wmbus-bridge] $*"; }
warn()        { echo "[wmbus-bridge][WARN] $*" >&2; }
err()         { echo "[wmbus-bridge][ERR] $*" >&2; }
log_verbose() { [[ "${LOGLEVEL}" == "verbose" || "${LOGLEVEL}" == "debug" ]] && echo "[wmbus-bridge] $*" || true; }
log_debug()   { [[ "${LOGLEVEL}" == "debug" ]] && echo "[wmbus-bridge] $*" || true; }

need_bin() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing binary: $1"; exit 1; }
}

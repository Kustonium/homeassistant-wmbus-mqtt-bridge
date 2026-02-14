#!/bin/sh
set -eu

BASE="${WMBUS_BASE:-/config}"

if [ ! -f "$BASE/etc/wmbusmeters.conf" ]; then
  echo "[ERROR] Brak $BASE/etc/wmbusmeters.conf"
  exit 2
fi

echo "[INFO] Starting wmbusmeters with --useconfig=$BASE"
exec /usr/bin/wmbusmeters --useconfig="$BASE"


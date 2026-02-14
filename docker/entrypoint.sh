#!/bin/sh
set -eu

CONF="${WMBUS_CONF:-/config/wmbusmeters.conf}"

if [ ! -f "$CONF" ]; then
  echo "[ERROR] Brak pliku config: $CONF"
  exit 2
fi

echo "[INFO] Starting wmbusmeters with config: $CONF"
exec /usr/bin/wmbusmeters -c "$CONF"

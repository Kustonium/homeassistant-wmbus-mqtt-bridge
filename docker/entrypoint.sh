#!/bin/sh
set -eu

CONF="${WMBUS_CONF:-/config/wmbusmeters.conf}"

if [ ! -f "$CONF" ]; then
  echo "[ERROR] Brak pliku config: $CONF"
  echo "        Zamontuj go jako /config/wmbusmeters.conf (volume) albo ustaw WMBUS_CONF."
  exit 2
fi

echo "[INFO] Starting wmbusmeters with config: $CONF"
exec /usr/bin/wmbusmeters --config "$CONF"

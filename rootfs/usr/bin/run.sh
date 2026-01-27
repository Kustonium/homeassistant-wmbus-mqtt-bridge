#!/usr/bin/with-contenv bashio
set -euo pipefail

bashio::log.info "wMBus MQTT Bridge: addon started OK (test mode)"
bashio::log.info "Nothing else is running. Sleeping..."

# keep container alive
exec sleep infinity

# syntax=docker/dockerfile:1

ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.20

# --- build wmbusmeters ---
FROM ${BUILD_FROM} AS builder

ENV LANG=C.UTF-8

RUN apk add --no-cache \
  bash git build-base make linux-headers \
  openssl-dev zlib-dev \
  libusb-dev librtlsdr-dev \
  libxml2-dev

WORKDIR /src

# Pin to a known-good upstream commit instead of tracking master HEAD. The pin
# gives reproducible image builds plus a CI gate (decode-smoke + the standalone
# boot-test run on every bump), independent of upstream master moving under us.
# It originally also worked around master being briefly uncompilable
# (wmbusmeters/wmbusmeters#1940, util.h missing <ctime>, 2026-06-11) — long fixed
# — but the pin stays for reproducibility, not just that incident.
#
# Bumped ad20d83a (2.0.0-541) -> ac4f2953 (tag 3.0.0, 2026-06-17). This is a
# MAJOR upstream release, so it was verified locally before pinning: builds
# clean, passes all 13 golden decode fixtures (tests/fixtures/golden.tsv) with no
# field/value regression, and `--listdrivers` still lists the built-in izar
# driver (123 drivers) consumed by the WebUI catalog below.
# NB: 3.0.0 removed `--listmeters`; the drivers.json step already prefers
# `--listdrivers`, so the legacy fallback there is now historical (harmless).
# A full clone (not --depth 1) is required: the Makefile derives the version
# string via `git describe --tags`. The Alpine build itself is the final gate in
# CI's build + boot-test jobs (local verification above is Ubuntu/WSL).
ARG WMBUSMETERS_COMMIT=ac4f295369a48ef51cb835e6920b62cbee743bd6
RUN git clone https://github.com/wmbusmeters/wmbusmeters.git . \
  && git checkout --detach "${WMBUSMETERS_COMMIT}" \
  && ./configure \
  && make \
  && install -d /out \
  && install -m 0755 build/wmbusmeters /out/wmbusmeters

# Driver catalog for the WebUI "Add meter" driver suggestions. Generated at
# build time from the pinned wmbusmeters sources (drivers/src/*.xmq) plus the
# built-in C++ drivers reported by --listdrivers (or the older --listmeters).
# Keep the compatibility fallback: upstream renamed the option and a silent
# empty list would hide built-in drivers such as izar from the WebUI.
RUN set -eu; \
    if /out/wmbusmeters --listdrivers > /tmp/wmbus-driver-list 2>/dev/null; then \
      :; \
    elif /out/wmbusmeters --listmeters > /tmp/wmbus-driver-list 2>/dev/null; then \
      :; \
    else \
      echo "wmbusmeters exposes neither --listdrivers nor --listmeters" >&2; \
      exit 1; \
    fi; \
    { awk '{print $1"\t"$2}' /tmp/wmbus-driver-list; \
      for f in drivers/src/*.xmq; do \
        awk -F= '/^[[:space:]]*name[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);n=$2} /^[[:space:]]*meter_type[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);t=$2; print n"\t"t; exit}' "$f"; \
      done; \
    } | sort -u \
      | awk -F'\t' 'BEGIN{printf "["; s=""} $1!=""{printf "%s{\"driver\":\"%s\",\"type\":\"%s\"}",s,$1,$2; s=","} END{print "]"}' \
      > /out/drivers.json; \
    grep -q '"driver":"izar"' /out/drivers.json || { echo "built-in driver izar missing from drivers.json" >&2; exit 1; }

# --- runtime: HA add-on ---
FROM ${BUILD_FROM} AS addon

RUN apk add --no-cache \
  bash \
  python3 \
  mosquitto-clients jq \
  curl \
  libstdc++ zlib libxml2 \
  libusb librtlsdr

COPY --from=builder /out/wmbusmeters /usr/bin/wmbusmeters
# Build-time driver catalog consumed by the WebUI driver <datalist>.
COPY --from=builder /out/drivers.json /usr/share/wmbus-webui/assets/drivers.json
ARG ADDON_VERSION=dev
ENV ADDON_VERSION=${ADDON_VERSION}
COPY rootfs /
# Bake the addon manifest next to webui.py so read_addon_version()
# can pick up the real version at runtime (HA does not mount
# config.yaml into the container).
COPY config.yaml /usr/bin/config.yaml

COPY docker/entrypoint.sh /usr/bin/docker-entrypoint.sh
# docker standalone entry point — used when running outside HA supervisor

RUN sed -i 's/\r$//' /usr/bin/run.sh /usr/bin/bridge.sh /usr/bin/docker-entrypoint.sh \
  && chmod a+x \
       /usr/bin/run.sh \
       /usr/bin/bridge.sh \
       /usr/bin/webui.py \
       /usr/bin/docker-entrypoint.sh \
       /etc/services.d/wmbus_mqtt_bridge/run \
       /etc/services.d/wmbus_webui/run

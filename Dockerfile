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

# Pin to a known-good upstream commit instead of master HEAD.
# Upstream is mid-restructuring (wmbusmeters/wmbusmeters#1940) and master
# does not always compile (e.g. util.h missing <ctime> after the util.cc
# split, 2026-06-11). This SHA is the state of the last working image
# (wmbusmeters --version reported 2.0.0-521-g8c35c4a1), so behaviour is
# identical to what is deployed. Bump the SHA deliberately — ideally
# gated by the decode smoke-test (roadmap task 5) — to pick up new
# upstream drivers.
# NB: the old `sed` stripping -flto from DEBUG_FLAGS is gone — at this
# commit -flto appears only in a Makefile comment, so it was a no-op.
# A full clone (not --depth 1) is required: the Makefile derives the
# binary's version string via `git describe --tags`, which needs the
# tag history to report e.g. 2.0.0-521-g8c35c4a1.
ARG WMBUSMETERS_COMMIT=8c35c4a142c505f3a9e2791daa7a27930b9de5ce
RUN git clone https://github.com/wmbusmeters/wmbusmeters.git . \
  && git checkout --detach "${WMBUSMETERS_COMMIT}" \
  && ./configure \
  && make \
  && install -d /out \
  && install -m 0755 build/wmbusmeters /out/wmbusmeters

# Driver catalog for the WebUI "Add meter" driver suggestions. Generated at
# build time from the pinned wmbusmeters sources (drivers/src/*.xmq) plus the
# built-in C++ drivers reported by --listmeters, so a WMBUSMETERS_COMMIT bump
# refreshes the list automatically. NB: at this pin --listmeters prints only
# the built-in C++ drivers (the xmq drivers were added to its output upstream
# after the pin), hence the explicit xmq scan.
RUN { /out/wmbusmeters --listmeters 2>/dev/null | awk '{print $1"\t"$2}'; \
      for f in drivers/src/*.xmq; do \
        awk -F= '/^[[:space:]]*name[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);n=$2} /^[[:space:]]*meter_type[[:space:]]*=/{gsub(/[[:space:]]/,"",$2);t=$2; print n"\t"t; exit}' "$f"; \
      done; \
    } | sort -u \
      | awk -F'\t' 'BEGIN{printf "["; s=""} $1!=""{printf "%s{\"driver\":\"%s\",\"type\":\"%s\"}",s,$1,$2; s=","} END{print "]"}' \
      > /out/drivers.json

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

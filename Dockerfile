# syntax=docker/dockerfile:1

# UWAGA: to musi istnieć, inaczej build padnie nawet przy target=docker
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.20

# --- build wmbusmeters ---
FROM alpine:3.20 AS builder

RUN apk add --no-cache \
  bash git build-base make linux-headers \
  openssl-dev zlib-dev \
  libusb-dev librtlsdr-dev \
  libxml2-dev

WORKDIR /src
ARG WMBUSMETERS_REF=master
RUN git clone https://github.com/wmbusmeters/wmbusmeters.git . \
  && git checkout "${WMBUSMETERS_REF}" \
  && make \
  && install -d /out \
  && install -m 0755 build/wmbusmeters /out/wmbusmeters


# --- runtime: docker standalone (DietPi / generic Docker) ---
FROM alpine:3.20 AS docker

RUN apk add --no-cache \
  bash \
  ca-certificates \
  mosquitto-clients jq \
  libstdc++ zlib libxml2 \
  libusb librtlsdr

COPY --from=builder /out/wmbusmeters /usr/bin/wmbusmeters

# jeśli robisz refaktor core+wrapper:
COPY rootfs/usr/bin/bridge.sh /usr/bin/bridge.sh
COPY docker/entrypoint.sh /entrypoint.sh

RUN sed -i 's/\r$//' /entrypoint.sh /usr/bin/bridge.sh \
  && chmod +x /entrypoint.sh /usr/bin/bridge.sh

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]


# --- runtime: HA add-on ---
FROM ${BUILD_FROM} AS addon

RUN apk add --no-cache \
  bash \
  mosquitto-clients jq \
  libstdc++ zlib libxml2 \
  libusb librtlsdr

COPY --from=builder /out/wmbusmeters /usr/bin/wmbusmeters
COPY rootfs /

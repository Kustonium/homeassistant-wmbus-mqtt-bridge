# syntax=docker/dockerfile:1

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


# --- runtime: docker standalone (DietPi) ---
FROM alpine:3.20 AS docker

RUN apk add --no-cache \
  ca-certificates \
  mosquitto-clients jq \
  libstdc++ zlib libxml2 \
  libusb librtlsdr

COPY --from=builder /out/wmbusmeters /usr/bin/wmbusmeters
COPY docker/entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]


# --- runtime: HA add-on (zostawiasz jak było, tylko bez :latest) ---
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.20
FROM ${BUILD_FROM} AS addon

RUN apk add --no-cache \
  mosquitto-clients jq \
  libstdc++ zlib libxml2 \
  libusb librtlsdr

COPY --from=builder /out/wmbusmeters /usr/bin/wmbusmeters
COPY rootfs /

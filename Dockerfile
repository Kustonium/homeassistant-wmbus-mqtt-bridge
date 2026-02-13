# syntax=docker/dockerfile:1

# --------------------------
# build wmbusmeters
# --------------------------
FROM alpine:3.20 AS builder

RUN apk add --no-cache \
  bash git build-base make linux-headers \
  openssl-dev zlib-dev \
  libusb-dev librtlsdr-dev \
  libxml2-dev

WORKDIR /src

# Uwaga: to buduje "latest z mastera" — powtarzalność ogarniesz pinem w ARG niżej (opcjonalnie)
ARG WMBUSMETERS_REF=master
RUN git clone https://github.com/wmbusmeters/wmbusmeters.git . \
  && git checkout "${WMBUSMETERS_REF}" \
  && make \
  && install -d /out \
  && install -m 0755 build/wmbusmeters /out/wmbusmeters


# --------------------------
# runtime (Home Assistant add-on base)
# --------------------------
# HA w czasie builda add-onów wstrzykuje BUILD_FROM (właściwy base dla arch).
# Poza HA możesz nadpisać BUILD_FROM ręcznie, a default jest przypięty (nie latest).
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:3.20
FROM ${BUILD_FROM}

RUN apk add --no-cache \
  mosquitto-clients jq \
  libstdc++ zlib libxml2 \
  libusb librtlsdr

COPY --from=builder /out/wmbusmeters /usr/bin/wmbusmeters
COPY rootfs /

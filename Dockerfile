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

RUN git clone https://github.com/wmbusmeters/wmbusmeters.git . \
# Aktualny upstream wmbusmeters potrafi wywalać build przy LTO (-flto)
# na toolchainie używanym w tym add-onie (błąd lto-wrapper / vsnprintf / fortify).
# Dlatego usuwamy -flto z Makefile, ale nadal bierzemy najnowszy upstream.
  && sed -i 's/DEBUG_FLAGS=-O2 -g -flto/DEBUG_FLAGS=-O2 -g/' Makefile \
  && ./configure \
  && make \
  && install -d /out \
  && install -m 0755 build/wmbusmeters /out/wmbusmeters

# --- runtime: docker standalone (DietPi / generic Docker) ---
FROM alpine:3.23 AS docker

RUN apk add --no-cache \
  bash \
  ca-certificates \
  mosquitto-clients jq \
  libstdc++ zlib libxml2 \
  libusb librtlsdr

COPY --from=builder /out/wmbusmeters /usr/bin/wmbusmeters

COPY rootfs/usr/bin/bridge.sh /usr/bin/bridge.sh
COPY docker/entrypoint.sh /entrypoint.sh

RUN sed -i 's/\r$//' /entrypoint.sh /usr/bin/bridge.sh \
  && chmod +x /entrypoint.sh /usr/bin/bridge.sh

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]

# --- runtime: HA add-on ---
FROM ${BUILD_FROM} AS addon

RUN apk add --no-cache \
  bash \
  python3 \
  mosquitto-clients jq \
  libstdc++ zlib libxml2 \
  libusb librtlsdr

COPY --from=builder /out/wmbusmeters /usr/bin/wmbusmeters
COPY rootfs /

RUN sed -i 's/\r$//' /usr/bin/run.sh /usr/bin/bridge.sh \
  && chmod a+x /usr/bin/run.sh /usr/bin/bridge.sh /usr/bin/webui.py
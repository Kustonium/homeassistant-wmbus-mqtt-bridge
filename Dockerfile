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
  && install -d /out \
  && git describe --tags --always --dirty > /out/wmbusmeters-build-version.txt \
  && git rev-parse HEAD > /out/wmbusmeters-build-commit.txt \
  && ./configure \
  && make -j2\
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
COPY --from=builder /out/wmbusmeters-build-version.txt /usr/share/wmbusmeters-build-version.txt
COPY --from=builder /out/wmbusmeters-build-commit.txt /usr/share/wmbusmeters-build-commit.txt

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
COPY --from=builder /out/wmbusmeters-build-version.txt /usr/share/wmbusmeters-build-version.txt
COPY --from=builder /out/wmbusmeters-build-commit.txt /usr/share/wmbusmeters-build-commit.txt
COPY rootfs /
RUN sed -i 's/\r$//' /usr/bin/run.sh /usr/bin/bridge.sh \
  && chmod a+x /usr/bin/run.sh /usr/bin/bridge.sh
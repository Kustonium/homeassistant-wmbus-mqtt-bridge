# --- build wmbusmeters ---
FROM alpine:3.20 AS builder

RUN apk add --no-cache \
  git build-base make linux-headers \
  openssl-dev zlib-dev \
  libusb-dev librtlsdr-dev \
  libxml2-dev

WORKDIR /src
RUN git clone --depth 1 https://github.com/wmbusmeters/wmbusmeters.git .
RUN set -eux; make V=1
RUN install -m 0755 ./wmbusmeters /out/wmbusmeters



# --- runtime (HA add-on base) ---
FROM ghcr.io/home-assistant/amd64-base:latest

RUN apk add --no-cache mosquitto-clients jq openssl zlib libstdc++ libxml2

COPY --from=builder /out/wmbusmeters /usr/bin/wmbusmeters
COPY rootfs /


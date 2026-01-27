FROM alpine:3.20 AS builder

RUN apk add --no-cache \
  bash git build-base make linux-headers \
  openssl-dev zlib-dev \
  libusb-dev librtlsdr-dev \
  libxml2-dev
  mosquitto-clients jq \
  libstdc++ zlib libxml2 \
  libusb librtlsdr

WORKDIR /src
RUN git clone https://github.com/wmbusmeters/wmbusmeters.git .
RUN set -eux; make V=1
RUN install -d /out && install -m 0755 build/wmbusmeters /out/wmbusmeters


# --- runtime (HA add-on base) ---
FROM ghcr.io/home-assistant/amd64-base:latest

RUN apk add --no-cache mosquitto-clients jq openssl zlib libstdc++ libxml2

COPY --from=builder /out/wmbusmeters /usr/bin/wmbusmeters
COPY rootfs /


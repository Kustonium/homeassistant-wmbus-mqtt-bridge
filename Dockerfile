ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-python:3.12-alpine3.20
FROM ${BUILD_FROM}

RUN pip install --no-cache-dir paho-mqtt

COPY rootfs /

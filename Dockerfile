ARG BUILD_FROM
FROM ${BUILD_FROM}

RUN pip install --no-cache-dir paho-mqtt

COPY rootfs /

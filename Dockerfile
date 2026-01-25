ARG BUILD_FROM
FROM ${BUILD_FROM}

COPY rootfs /

RUN chmod a+x /etc/services.d/mqtt-bridge/run
EOF
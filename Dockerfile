ARG BUILD_FROM
FROM ${BUILD_FROM}

COPY rootfs /
RUN chmod a+x /run.sh

ARG BUILD_FROM
FROM ${BUILD_FROM}

COPY rootfs /

WORKDIR /
CMD [ "/run.sh" ]

ARG BUILD_FROM
FROM ${BUILD_FROM}

# 1. Wymuszamy IPv4 dla APK (częsty fix na dual-stack)
ENV APK_FORCE_IPV4=1

# 2. Pętla retry - jeśli DNS chrupnie, próbuje 5 razy co 5 sekund
RUN \
    for i in 1 2 3 4 5; do \
        echo "Próba instalacji $i..."; \
        apk add --no-cache mosquitto-clients && break; \
        sleep 5; \
    done

COPY rootfs /

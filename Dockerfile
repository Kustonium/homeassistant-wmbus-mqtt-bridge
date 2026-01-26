ARG BUILD_FROM
FROM ${BUILD_FROM}

# Wymuś sensowny resolv.conf w trakcie builda
RUN printf "nameserver 1.1.1.1\nnameserver 8.8.8.8\n" > /etc/resolv.conf

# (opcjonalnie) mniej wrażliwe na IPv6/dual-wan
ENV APK_FORCE_IPV4=1

RUN apk add --no-cache mosquitto-clients

COPY rootfs /

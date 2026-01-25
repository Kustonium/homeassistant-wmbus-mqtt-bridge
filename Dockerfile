ARG BUILD_FROM
FROM $BUILD_FROM

# Generuj run.sh bezpośrednio
RUN echo '#!/usr/bin/env bash' > /run.sh && \
    echo 'set -e' >> /run.sh && \
    echo '' >> /run.sh && \
    echo 'echo "====================================="' >> /run.sh && \
    echo 'echo " TEST RAW MQTT - NC"' >> /run.sh && \
    echo 'echo "====================================="' >> /run.sh && \
    echo '' >> /run.sh && \
    echo 'MQTT_HOST="${MQTT_HOST:-core-mosquitto}"' >> /run.sh && \
    echo 'MQTT_PORT="${MQTT_PORT:-1883}"' >> /run.sh && \
    echo '' >> /run.sh && \
    echo 'echo "Łączę przez nc z $MQTT_HOST:$MQTT_PORT..."' >> /run.sh && \
    echo 'echo "Czekam na dane MQTT..."' >> /run.sh && \
    echo '' >> /run.sh && \
    echo 'nc "$MQTT_HOST" "$MQTT_PORT" | hexdump -C' >> /run.sh && \
    chmod +x /run.sh

CMD ["/run.sh"]

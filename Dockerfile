ARG BUILD_FROM
FROM ${BUILD_FROM}

COPY rootfs /

RUN mkdir -p /etc/services.d/mqtt-bridge && \
    echo '#!/usr/bin/with-contenv bashio' > /etc/services.d/mqtt-bridge/run && \
    echo '' >> /etc/services.d/mqtt-bridge/run && \
    echo 'bashio::log.info "===================================="' >> /etc/services.d/mqtt-bridge/run && \
    echo 'bashio::log.info " wMBus MQTT Bridge v1.0.10"' >> /etc/services.d/mqtt-bridge/run && \
    echo 'bashio::log.info "===================================="' >> /etc/services.d/mqtt-bridge/run && \
    echo '' >> /etc/services.d/mqtt-bridge/run && \
    echo 'MQTT_TOPIC=$(bashio::config "mqtt_topic" "wmbus/raw")' >> /etc/services.d/mqtt-bridge/run && \
    echo 'bashio::log.info "MQTT Topic: ${MQTT_TOPIC}"' >> /etc/services.d/mqtt-bridge/run && \
    echo '' >> /etc/services.d/mqtt-bridge/run && \
    echo 'if bashio::services.available "mqtt"; then' >> /etc/services.d/mqtt-bridge/run && \
    echo '    MQTT_HOST=$(bashio::services mqtt "host")' >> /etc/services.d/mqtt-bridge/run && \
    echo '    MQTT_PORT=$(bashio::services mqtt "port")' >> /etc/services.d/mqtt-bridge/run && \
    echo '    bashio::log.info "MQTT Broker: ${MQTT_HOST}:${MQTT_PORT}"' >> /etc/services.d/mqtt-bridge/run && \
    echo 'else' >> /etc/services.d/mqtt-bridge/run && \
    echo '    bashio::log.warning "MQTT service not available"' >> /etc/services.d/mqtt-bridge/run && \
    echo 'fi' >> /etc/services.d/mqtt-bridge/run && \
    echo '' >> /etc/services.d/mqtt-bridge/run && \
    echo 'bashio::log.info "Bridge service RUNNING!"' >> /etc/services.d/mqtt-bridge/run && \
    echo '' >> /etc/services.d/mqtt-bridge/run && \
    echo 'exec tail -f /dev/null' >> /etc/services.d/mqtt-bridge/run && \
    chmod +x /etc/services.d/mqtt-bridge/run

ARG BUILD_FROM
FROM $BUILD_FROM

# Zainstaluj Python i pip, potem paho-mqtt
RUN apk add --no-cache python3 py3-pip && \
    pip3 install --break-system-packages paho-mqtt

# Generuj test_mqtt.py
RUN echo 'import paho.mqtt.client as mqtt' > /test_mqtt.py && \
    echo 'import time' >> /test_mqtt.py && \
    echo '' >> /test_mqtt.py && \
    echo 'def on_connect(client, userdata, flags, rc):' >> /test_mqtt.py && \
    echo '    print("POŁĄCZONO Z MQTT! Code:", rc)' >> /test_mqtt.py && \
    echo '    client.subscribe("wmbus_bridge/debug")' >> /test_mqtt.py && \
    echo '    print("Nasłuchuję: wmbus_bridge/debug")' >> /test_mqtt.py && \
    echo '' >> /test_mqtt.py && \
    echo 'def on_message(client, userdata, msg):' >> /test_mqtt.py && \
    echo '    print("="*40)' >> /test_mqtt.py && \
    echo '    print(f"OTRZYMANO: {msg.topic}")' >> /test_mqtt.py && \
    echo '    print(f"DANE: {msg.payload.decode()}")' >> /test_mqtt.py && \
    echo '    print("="*40)' >> /test_mqtt.py && \
    echo '' >> /test_mqtt.py && \
    echo 'client = mqtt.Client()' >> /test_mqtt.py && \
    echo 'client.on_connect = on_connect' >> /test_mqtt.py && \
    echo 'client.on_message = on_message' >> /test_mqtt.py && \
    echo '' >> /test_mqtt.py && \
    echo 'print("Łączę z core-mosquitto:1883...")' >> /test_mqtt.py && \
    echo 'client.connect("core-mosquitto", 1883, 60)' >> /test_mqtt.py && \
    echo 'client.loop_forever()' >> /test_mqtt.py && \
    chmod +x /test_mqtt.py

# Generuj run.sh
RUN echo '#!/usr/bin/env bash' > /run.sh && \
    echo 'set -e' >> /run.sh && \
    echo 'echo "====================================="' >> /run.sh && \
    echo 'echo " TEST MQTT - PYTHON CLIENT"' >> /run.sh && \
    echo 'echo "====================================="' >> /run.sh && \
    echo 'python3 /test_mqtt.py' >> /run.sh && \
    chmod +x /run.sh

CMD ["/run.sh"]

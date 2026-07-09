Standalone Docker example — the decoder plus a local Mosquitto broker.

1. Provide the config file (copy the template):

     cp docker/examples/config/options.json.example docker/examples/config/options.json

   The template already points at the bundled Mosquitto (host "mosquitto",
   anonymous, port 1883), so it works out of the box. For your own broker,
   edit external_mqtt_host / external_mqtt_username / external_mqtt_password.

   (If you skip this step, the container generates a default options.json on
   first start — same content — which you then edit.)

2. Start (from repo root):

     docker compose -f docker/examples/docker-compose.yml up -d --build

3. Open the WebUI at http://<host>:8099 — the "Received / Search" view lists
   every meter heard (LISTEN mode). Add meters from there, or edit the
   "meters" list in options.json by hand, e.g.:

     "meters": [
       { "id": "cold_water", "meter_id": "12345678", "type": "izar", "key": "" }
     ]

   AES-encrypted meters need the 32-hex "key". After editing options.json:

     docker compose -f docker/examples/docker-compose.yml restart wmbus

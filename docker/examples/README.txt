Start example (from repo root):

  docker compose -f docker/examples/docker-compose.yml up -d --build

Then edit:
  docker/examples/config/options.json

and restart:
  docker compose -f docker/examples/docker-compose.yml restart wmbus

#!/usr/bin/env bash
#
# Promote runtime files from the dev addon to the stable addon.
#
# What it does:
#   wmbus_mqtt_bridge_dev/{rootfs,Dockerfile,translations}
#     ->  wmbus_mqtt_bridge/{rootfs,Dockerfile,translations}
#
# What it does NOT touch:
#   - config.yaml (per-channel: slug, name, version, image, panel_title)
#   - README.md   (per-channel notices may differ)
#   - CHANGELOG.md
#
# Usage:
#   ./scripts/promote-rootfs.sh
#
# After running:
#   git status
#   git add wmbus_mqtt_bridge/
#   git commit -m "Promote dev runtime to stable"
#
# CI (.github/workflows/sync-rootfs.yaml) does the same thing automatically
# on every push to dev that touches wmbus_mqtt_bridge_dev/{rootfs,Dockerfile,translations}.
# This script is the manual escape hatch.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

SRC="wmbus_mqtt_bridge_dev"
DST="wmbus_mqtt_bridge"

if [[ ! -d "${SRC}" ]]; then
  echo "ERROR: source addon folder '${SRC}' not found." >&2
  exit 1
fi
if [[ ! -d "${DST}" ]]; then
  echo "ERROR: destination addon folder '${DST}' not found." >&2
  exit 1
fi

changed=0
for item in rootfs Dockerfile translations; do
  if [[ -e "${SRC}/${item}" ]]; then
    rm -rf "${DST:?}/${item}"
    cp -r "${SRC}/${item}" "${DST}/${item}"
    echo "synced ${item}"
    changed=1
  fi
done

# Drop bytecode caches that may have travelled in.
find "${DST}/rootfs" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

# Restore executable bit on shipping scripts (Windows cp drops it).
chmod_targets=(
  "${DST}/rootfs/etc/services.d/wmbus_mqtt_bridge/run"
  "${DST}/rootfs/etc/services.d/wmbus_webui/run"
  "${DST}/rootfs/usr/bin/run.sh"
  "${DST}/rootfs/usr/bin/bridge.sh"
  "${DST}/rootfs/usr/bin/webui.py"
)
for f in "${chmod_targets[@]}"; do
  if [[ -e "${f}" ]]; then
    chmod +x "${f}" || true
    git update-index --add --chmod=+x "${f}" 2>/dev/null || true
  fi
done

if (( changed == 0 )); then
  echo "nothing to sync."
  exit 0
fi

echo
echo "Done. Review with: git status -- ${DST}/"
echo "Then: git add ${DST}/ && git commit -m 'Promote dev runtime to stable'"

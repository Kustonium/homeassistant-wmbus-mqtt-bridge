#!/usr/bin/env bash
# Apply add-on-local patches to the pinned wmbusmeters checkout, and retire them
# by themselves once upstream grows its own support.
#
# The rule, in one sentence: UPSTREAM WINS. Every patch here declares a "signal"
# that upstream has solved the problem. If the signal is present the patch is
# skipped and the build says so; if the patch no longer applies the build FAILS
# rather than silently shipping without it.
#
# That failure is a feature, not an accident. The pin is bumped by a monthly cron
# (.github/workflows/wmbusmeters-pin-bump.yml), so a moved code region has to be
# looked at by a human — the alternative is a workaround that quietly stops
# existing while the release notes still imply it works.
set -euo pipefail

SRC_DIR="${1:-.}"
PATCH_DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

cd "${SRC_DIR}"

# ── 0001: Tauron/KPL non-standard decrypt check bytes ────────────────────────
# Upstream signal: any mention of KPL in the decryption path, or a driver named
# after the manufacturer/utility. manufacturers.h is deliberately NOT part of the
# signal — the KPL flag code has been listed there for years (as "KPLC Power,
# Kenya") without any telegram handling attached to it.
# NB: one glob at a time. `ls a b c` exits non-zero when ANY argument is missing,
# so a single `ls` over several patterns reports "not found" even when one of
# them matched — the signal would never have fired. Caught by the dry run, not
# by reading it.
# Upstream calls this meter by its manufacturer, not by the utility: it is a Sanxing
# S34U28, and the pending work (issues #2042, #2043) adds drivers/src/sanxing.xmq plus a
# transform_payload=sanxing_609B hook. The first version of this signal looked for
# *kpl* / *tauron* names and for MANUFACTURER_KPL in src/wmbus.cc; #2043 puts that
# constant in src/generated_database.cc instead, so NONE of it would have matched and
# this patch would have kept rewriting bytes underneath upstream's own handling. Match
# on the marker and the hook, which are what the behaviour is actually named after.
upstream_handles_609b() {
  local p
  if grep -qiE '609b|sanxing' src/wmbus.cc 2>/dev/null; then return 0; fi
  # NOT a bare 'transform_payload' grep: that hook already exists upstream for
  # diehl_prios (driver_dynamic.cc:170), so it matches on a clean 3.0.0 and the patch
  # would never be applied at all. Match the sanxing-specific name #2043 introduces.
  if grep -qiE 'sanxing_609b|setSanxing609BDecode' src/driver_dynamic.cc src/meters*.h 2>/dev/null; then return 0; fi
  for p in src/driver_*kpl*.cc src/driver_*tauron*.cc src/driver_*sanxing*.cc \
           drivers/src/*kpl*.xmq drivers/src/*tauron*.xmq drivers/src/*sanxing*.xmq; do
    if [ -e "${p}" ]; then return 0; fi
  done
  return 1
}

if grep -q 'MANUFACTURER_KPL' src/wmbus.cc 2>/dev/null || upstream_handles_609b; then
  echo "local-patch: upstream now handles KPL itself -> skipping 0001-kpl-decrypt-check-bytes.patch"
else
  git apply --verbose "${PATCH_DIR}/0001-kpl-decrypt-check-bytes.patch"
  echo "local-patch: applied 0001-kpl-decrypt-check-bytes.patch"
fi

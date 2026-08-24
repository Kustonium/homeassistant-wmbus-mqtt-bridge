#!/usr/bin/env python3
"""
wMBus MQTT Bridge dashboard.

Interactive Home Assistant add-on dashboard:
- shows runtime status, configured meters and detected candidates,
- supports LISTEN / SEARCH onboarding workflow,
- can add/remove meter entries through Home Assistant Supervisor API,
- can enable/disable SEARCH mode through Home Assistant Supervisor API,
- falls back to direct options.json writes outside Home Assistant Supervisor.
"""
from __future__ import annotations

import fnmatch
import glob
import html
import json
import mimetypes
import os
import re
import select
import subprocess
import time
import urllib.request
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse

BASE = Path(os.environ.get("WMBUS_BASE", "/data"))
# POSIX-only, and the only thing that needs it is the wired M-Bus bus probe. It
# is imported conditionally so the WebUI still starts where the module does not
# exist: the add-on always runs on Linux, but the documented way to check a UI
# change is to run this file directly on the maintainer's machine, and an
# unconditional import made that impossible. The probe endpoint reports the
# absence instead of the process failing to start at all.
try:
    import termios
except ImportError:  # pragma: no cover - non-POSIX developer machines only
    termios = None

PORT = int(os.environ.get("WEBUI_PORT", "8099"))
STATIC_DIR = Path(__file__).resolve().parent.parent / "share" / "wmbus-webui"

STATUS_JSON = BASE / "status.json"
METERS_TSV = BASE / "status_meters.tsv"
CANDIDATES_TSV = BASE / "status_candidates.tsv"
EVENTS_TSV = BASE / "status_events.tsv"
IGNORED_CANDIDATES = BASE / "status_ignored_candidates.tsv"
SEARCH_CANDIDATES_TSV = BASE / "search_candidates.tsv"
SEARCH_MATCHES_TSV = BASE / "search_matches.tsv"
SEARCH_STATUS_JSON = BASE / "search_status.json"
CANDIDATE_ANALYSIS_TSV = BASE / "status_candidate_analysis.tsv"
# Last raw telegram per candidate, written by status_record_candidate_raw
# (bridge-lib/06-candidates.sh). Feeds the "export for issue report" action.
CANDIDATE_RAW_TSV = BASE / "status_candidate_raw.tsv"
# Rolling RAW frames (tail 200), written by status_raw_seen — used to find a
# configured meter's last frame (by little-endian id substring) for the
# on-demand driver comparison.
RECENT_RAW_TSV = BASE / "status_recent_raw.tsv"
# Last full decoded JSON per configured meter (status_meter_seen in
# bridge-lib/07-meters.sh). Feeds the "published fields" expander.
METER_LAST_JSON_TSV = BASE / "status_meter_last_json.tsv"
# Per-meter AES key problem (key_missing | key_invalid) detected by
# status_detect_key_problem in bridge-lib/07-meters.sh from wmbusmeters
# warnings; cleared by the next successfully decoded JSON.
METER_KEY_PROBLEM_TSV = BASE / "status_meter_key_problem.tsv"
# Discovery Doctor: the WebUI touches the request flag; bridge.sh's heartbeat
# ticker runs the broker probe (discovery_doctor_probe, 09-discovery.sh) and
# writes the JSON result.
DISCOVERY_DOCTOR_REQUEST = BASE / ".discovery_doctor_request"
STATUS_DISCOVERY_DOCTOR_JSON = BASE / "status_discovery_doctor.json"
# Factory reset: this endpoint empties options.json (meters=[]) and writes the
# removed ids here (one per line). bridge.sh's heartbeat ticker consumes the
# flag, clears each meter's retained discovery, wipes runtime state and
# soft-reloads — returning the add-on to its post-install state.
FACTORY_RESET_REQUEST = BASE / ".factory_reset_request"
WMBUSMETERS_BIN = "/usr/bin/wmbusmeters"
OPTIONS_JSON = BASE / "options.json"
# Add-on manifest, baked next to this script (Dockerfile: COPY config.yaml
# /usr/bin/config.yaml). Source of truth for the options schema that drives the
# editable Settings form — parsing it means the form never drifts from HA's own.
CONFIG_YAML_PATH = Path(__file__).parent / "config.yaml"
# Per-minute rate dashboard files written by bridge.sh
STATUS_RATE_1M_JSON = BASE / "status_rate_1m.json"
# 15-entry rolling history of telegrams/min (one row per finished minute).
# Feeds the sparkline in the WebGUI Statystyki view.
STATUS_RATE_HISTORY_FILE = BASE / "status_rate_history.tsv"
STATUS_BRIDGE_START_FILE = BASE / "status_bridge_start.txt"
# ESP diagnostic summary written by background subscriber in bridge.sh
STATUS_ESP_DIAG_JSON = BASE / "status_esp_diag.json"
# Always-on ESP radio health pulse (wmbus/+/health), written by bridge.sh's
# background subscriber. Published every 60 s regardless of the ESP's
# diagnostic_mode, so it works even when diagnostics are off. Carries
# uptime_s, rx_total, sec_since_last_rx (proof the RX path is alive, not just
# the loop), chip and listen_mode. _bridge_rx_epoch = freshness stamp.
STATUS_ESP_HEALTH_JSON = BASE / "status_esp_health.json"
# Always-on ESP meter flags (wmbus/+/meters), written by bridge.sh's background
# subscriber as a map keyed by ESP device: {"<device>": {"target","highlight"[],
# "_bridge_rx_epoch"}}. Union of target + highlight (across fresh entries) is the
# set of meters the ESP is explicitly configured for; the WebUI badges matching
# meters/candidates so an ESP-vs-add-on mismatch is visible.
STATUS_ESP_METERS_JSON = BASE / "status_esp_meters.json"
# Opt-in per-meter reception windows: the ESP's diag meter_snapshot (batch of
# highlight meters, every summary_15min/60min), written per ESP device by the
# wmbus/+/diag/meter_snapshot subscriber. webui turns count_window / elapsed_s /
# avg_interval_s into a per-meter reception % (the real quality signal, #15) —
# best across ESPs. Absent when diagnostics are off / no highlight_meters.
STATUS_ESP_METER_SNAPSHOT_JSON = BASE / "status_esp_meter_snapshot.json"
# Per-meter reception window (wmbus/+/diag/meter/<id>/<mode>/window/<trigger>).
# Same reception fields as the 15-min snapshot but published per meter on the
# frequent "count" trigger (every N telegrams), so the per-ESP % populates in
# minutes instead of waiting for the 15-min batch. Map keyed dev -> id -> fields.
STATUS_ESP_METER_WINDOW_JSON = BASE / "status_esp_meter_window.json"
# Wired M-Bus runtime state, written by bridge-lib/14-mbus.sh. Access ("can the
# port be opened") is established here in webui.py; this file carries the other
# half, which only the process reading the decoder's output can know: whether
# anything actually answers on the bus, and if not, which of the several causes
# it is. The decoder names them only in its log, and on this path they all share
# one symptom - nothing arrives.
# {state, device, bus_alias, meters_configured, meters_skipped, updated,
#  meters: {"<name>": {id, last_ok_epoch, clash_with}}}
STATUS_MBUS_JSON = BASE / "status_mbus.json"
# Meter -> ESP device attribution (bridge.sh, from the RAW topic itself). Used
# only for the wM-Bus band fallback: combined with that device's listen_mode
# from status_esp_health.json it gives an approximate band for meters that have
# no per-meter diagnostic topic (no highlight_meters on the ESP).
# Format: meter_id<TAB>device_name<TAB>last_seen_epoch
STATUS_ESP_METER_DEVICE_FILE = BASE / "status_esp_meter_device.tsv"
# Session-scoped, bridge-observed reception counts. These rows all start at the
# same bridge start and therefore replace ESP-self-referential diagnostic counts
# when available.
STATUS_ESP_METER_RECEPTION_FILE = BASE / "status_esp_meter_reception.tsv"
# Same session view populated from structured ESP RF metadata. When rows exist
# for a meter, these replace /telegram-derived counts for that meter.
STATUS_ESP_RX_RECEPTION_FILE = BASE / "status_esp_rx_reception.tsv"
STATUS_ESP_RX_SEQUENCE_FILE = BASE / "status_esp_rx_sequence.tsv"
STATUS_ESP_RX_BOOTS_FILE = BASE / "status_esp_rx_boots.tsv"
STATUS_ESP_RX_CLOCK_FILE = BASE / "status_esp_rx_clock.tsv"
STATUS_ESP_CONFIG_FILE = BASE / "status_esp_config.json"
ESP_RF_RX_HISTORY_FILE = BASE / "esp_rf_rx_history.jsonl"
# ESP events TSV and per-event detail files (written by bridge.sh event subscriber)
STATUS_ESP_EVENTS_FILE = BASE / "status_esp_events.tsv"
STATUS_ESP_SUGGESTION_FILE = BASE / "status_esp_suggestion.json"
STATUS_ESP_BOOT_FILE = BASE / "status_esp_boot.json"
# Per-candidate preview values written by short-lived one-shot decoders
# using PREVIEW_BASE/etc/wmbusmeters.d/.
STATUS_CANDIDATE_VALUES_FILE = BASE / "status_candidate_values.tsv"
# Per-candidate preview lifecycle state: pending | decoded_value | decoded_without_numeric_value
STATUS_CANDIDATE_PREVIEW_STATE_FILE = BASE / "status_candidate_preview_state.tsv"
# Per-ESP-device telegram tracking — written by bridge.sh's background
# subscriber listening to RAW_TOPIC. The PRIMARY source of truth for which
# ESPs were seen in the current bridge session (works without ESP diagnostics).
# Format: device<TAB>last_seen_epoch<TAB>last_topic<TAB>telegram_count
STATUS_ESP_TELEGRAM_DEVICES_FILE = BASE / "status_esp_telegram_devices.tsv"
# MQTT->HA healthcheck: presence of HA's MQTT integration on the broker the
# bridge uses, from HA's retained birth message. Written by bridge.sh.
# Format: state<TAB>epoch  (state = online | offline).
STATUS_HA_PRESENCE_FILE = BASE / "status_ha_presence.txt"
# Broker identity (brand<TAB>version) from $SYS, written by bridge.sh. Used to
# label the MQTT tile, e.g. "Mosquitto 2.1.2 (native)" / "EMQX 5.8.8 (other)".
STATUS_BROKER_INFO_FILE = BASE / "status_broker_info.txt"
# Opt-in HA entity verification verdict written by bridge-lib/13-esp.sh's
# worker. One of: verified | not_created | unavailable | pending. Joined with
# ha_link in status_model — verified > native > birth.
STATUS_HA_VERIFICATION_FILE = BASE / "status_ha_verification.txt"
# wmbusmeters version triplet written once at bridge start by bridge.sh.
# Format: runtime_version<TAB>build_version<TAB>build_commit.
STATUS_WMBUSMETERS_VERSION_FILE = BASE / "status_wmbusmeters_version.txt"
# Liveness heartbeat stamped by bridge.sh every few seconds, independent of
# telegram flow. A stale heartbeat means the bridge is down or run.sh is still
# waiting for the broker — the rest of the snapshot is then stale, not live.
STATUS_HEARTBEAT_FILE = BASE / "status_heartbeat.txt"
# Startup-failure marker written by run.sh before a FATAL exit (broker could
# not be resolved, so bridge.sh never started). Format: code<TAB>detail.
# run.sh clears it on every successful broker resolution. Rendered by the
# WebUI as a specific, actionable banner (codes: auth_required, no_broker,
# no_ha_service, external_host_missing).
STATUS_RUN_ERROR_FILE = BASE / "status_run_error.txt"
# Runtime broker-connection failure marker written by wait_for_mqtt while the
# bridge KEEPS RUNNING (codes: auth_rejected, unreachable; detail host:port).
# Cleared on the first successful publish or received telegram. Rendered as a
# banner even though the heartbeat is alive — a wrong password otherwise
# manifests only as a quiet offline MQTT tile.
STATUS_BROKER_ERROR_FILE = BASE / "status_broker_error.txt"
# LISTEN-only config dir — separate from /data/etc which holds the user's
# permanent meters. This directory must stay empty so the secondary wmbusmeters
# process remains a true always-on discovery listener.
LISTEN_METER_DIR = BASE / "listen" / "etc" / "wmbusmeters.d"
# Preview requests are stored separately and consumed by short-lived one-shot
# decoders. They must never be written into LISTEN_METER_DIR.
PREVIEW_BASE = BASE / "preview"
PREVIEW_METER_DIR = PREVIEW_BASE / "etc" / "wmbusmeters.d"
RELOAD_LISTEN_FLAG = BASE / ".reload_listen"  # legacy cleanup only
RELOAD_PIPELINE_FLAG = BASE / ".reload_pipeline"
STATUS_PIPELINE_RELOAD_FILE = BASE / "status_pipeline_reload.txt"
ZERO_AES_KEY = "00000000000000000000000000000000"


def read_addon_version() -> tuple[str, bool]:
    import re as _re, os as _os
    # Read config.yaml once — used both for version and slug-based dev detection.
    cfg_text = ""
    is_dev_slug = False
    try:
        cfg_path = Path(__file__).parent / "config.yaml"
        cfg_text = cfg_path.read_text(encoding="utf-8")
        slug_m = _re.search(r'^slug:\s*["\']?(\S+?)["\']?\s*$', cfg_text, _re.MULTILINE)
        if slug_m:
            is_dev_slug = "dev" in slug_m.group(1).lower()
    except Exception:
        pass

    def _is_dev(ver: str) -> bool:
        # A build is dev if: version contains "-" (e.g. 1.5.9-dev.15),
        # "dev" appears anywhere in the version string,
        # or the addon slug ends with "_dev" / contains "dev".
        return "-" in ver or "dev" in ver.lower() or is_dev_slug

    # 1. Env var injected by CI build-arg (most accurate for dev builds)
    env_ver = _os.environ.get("ADDON_VERSION", "").strip()
    if env_ver:
        return env_ver, _is_dev(env_ver)
    # 2. Fallback: read version from config.yaml next to this script
    if cfg_text:
        m = _re.search(r'^version:\s*["\']?([^\s"\']+)["\']?', cfg_text, _re.MULTILINE)
        if m:
            v = m.group(1).strip()
            return v, _is_dev(v)
    return "dev", True


ADDON_VERSION, ADDON_IS_DEV = read_addon_version()

VALID_ID_RE = re.compile(r"^[0-9A-Fa-f]{8}$")
MEDIA_FILTERS = {"all", "water", "warm_water", "electricity", "heat", "other"}


def meter_id_from_raw_hex(hex_value: str) -> str:
    if not re.fullmatch(r"[0-9A-F]+", hex_value or ""):
        return ""
    if len(hex_value) < 22 or len(hex_value) % 2:
        return ""
    try:
        length_field = int(hex_value[:2], 16)
    except ValueError:
        return ""
    if length_field != (len(hex_value) // 2) - 1:
        return ""
    # wMBus A-field stores the 4-byte meter ID little-endian after L/C/M-field.
    id_le = hex_value[8:16]
    return id_le[6:8] + id_le[4:6] + id_le[2:4] + id_le[0:2]


def normalize_meter_id(value: object) -> str:
    mid = re.sub(r"\s+", "", str(value or "")).upper()
    if mid.startswith("0X"):
        mid = mid[2:]
    if not mid or not re.fullmatch(r"[0-9A-F]+", mid):
        return ""
    if len(mid) > 8:
        return meter_id_from_raw_hex(mid)
    return mid.zfill(8) if len(mid) < 8 else mid


# ---------------------------------------------------------------------------
# Localisation — all translations and helpers live in i18n.py
# ---------------------------------------------------------------------------
from i18n import (  # noqa: E402
    SUPPORTED_LANGS, DEFAULT_LANG, LANG_COOKIE, I18N,
    tr, localize_html, lang_switcher, detect_lang,
)


def read_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def read_options() -> dict:
    return read_json(OPTIONS_JSON)


def read_search_status() -> dict:
    status = read_json(SEARCH_STATUS_JSON)
    return status if isinstance(status, dict) else {}


def read_search_candidates() -> list[dict]:
    """Candidates used by the old/working bridge SEARCH mode.

    bridge.sh writes /data/search_candidates.tsv as:
      id<TAB>driver

    This is different from status_candidates.tsv, which is the general dashboard
    candidate list. Search UI must show both, otherwise the UI appears to lie
    when logs say "cached=23" but the dashboard list shows fewer rows.
    """
    rows = read_tsv(SEARCH_CANDIDATES_TSV, ["id", "driver"])
    for row in rows:
        row["type"] = "search-cache"
        # bridge.sh already ran search_type_is_water_candidate() before writing this file.
        # Re-classifying by driver name here (media_class("", driver)) would be wrong:
        # e.g. multical21/iperl/flowiq2200 don't contain "water"/"hydro" in driver name
        # but ARE water meters – that's exactly why bridge.sh stores the type_line
        # from wmbusmeters output, not just the driver. Trust the upstream filter.
        row["media"] = "water"
    return rows


def read_search_matches() -> list[dict]:
    """Optional future SEARCH match results.

    Current bridge.sh mainly logs SEARCH MATCH to add-on logs and publishes MQTT.
    If bridge.sh later writes /data/search_matches.tsv, the UI will show it
    without another frontend rewrite.
    """
    return read_tsv(
        SEARCH_MATCHES_TSV,
        ["time", "id", "driver", "media", "field", "value_m3", "expected_m3", "diff_m3", "tolerance_m3"],
        limit=100,
        reverse=True,
    )


def read_candidate_analysis() -> dict[str, dict]:
    """Optional backend-provided candidate analysis.

    Do not guess AES from driver. If bridge.sh later maps RAW HEX -> candidate
    and writes analysis here, the UI uses it as factual data.

    Expected TSV:
      id<TAB>encryption<TAB>note<TAB>ci<TAB>security<TAB>raw_len<TAB>last_seen

    encryption examples:
      encrypted
      not_encrypted
      aes_required
      no_aes
      unknown
    """
    result: dict[str, dict] = {}
    rows = read_tsv(
        CANDIDATE_ANALYSIS_TSV,
        ["id", "encryption", "note", "ci", "security", "raw_len", "last_seen"],
    )
    for row in rows:
        mid = str(row.get("id") or "")
        if VALID_ID_RE.match(mid):
            result[mid] = row
    return result


def candidate_issue_report(meter_id: str) -> tuple[bool, dict]:
    """Build a ready-to-paste upstream issue block for an undecoded candidate.

    Uses the candidate's last raw telegram (status_candidate_raw.tsv, written
    by status_record_candidate_raw in bridge-lib/06-candidates.sh) and an
    on-demand `wmbusmeters --analyze` run. The AES key is NEVER included:
    the report must stay safe to paste into a public wmbusmeters issue.
    """
    mid = normalize_meter_id(meter_id)
    if not mid or not VALID_ID_RE.match(mid):
        return False, {"ok": False, "error": "invalid_meter_id"}

    # Candidates keep a RAW row of their own; a configured meter does not, so
    # the frame comes from the rolling all-frames buffer, matched on the id in
    # little-endian order. That is the same lookup the preview path uses and it
    # is what makes the report available for meters that are already added —
    # asked for by a user who had no way to see the raw frame after adding one.
    raw, raw_ts = _resolve_raw_for_id(mid)
    if not raw:
        return False, {"ok": False, "error": "no_raw_telegram"}

    candidates = read_tsv(
        CANDIDATES_TSV,
        ["id", "driver", "type", "last_seen", "seen_count", "avg_interval_s", "seen_15m", "seen_60m", "manufacturer"],
    )
    cand = next((c for c in candidates if normalize_meter_id(c.get("id")) == mid), {})
    driver = str(cand.get("driver") or "").strip() or "unknown"
    mtype = str(cand.get("type") or "").strip() or "unknown"
    manufacturer = str(cand.get("manufacturer") or "").strip() or "unknown"

    # When a 32-hex AES key is configured for this id in options.json, run
    # the analysis decrypted (--analyze=<key>). The analyze output then shows
    # the decoded DV entries — far more useful for an upstream driver author —
    # while the key itself is never part of the output or the report. The
    # report does reveal meter readings in that case (flagged to the UI).
    key = ""
    meter_entry: dict = {}
    options = read_json(OPTIONS_JSON)
    if isinstance(options, dict):
        for m in options.get("meters", []) or []:
            if isinstance(m, dict) and normalize_meter_id(m.get("meter_id")) == mid:
                meter_entry = m
                cand_key = str(m.get("key") or "").strip()
                if re.match(r"^[0-9A-Fa-f]{32}$", cand_key):
                    key = cand_key
                break

    # A configured meter usually has no candidate row left, so the header lines
    # come from its own configuration and its last decoded telegram. The
    # manufacturer is in the analyze output below either way.
    if meter_entry:
        cfg_driver = str(meter_entry.get("type") or "").strip()
        if cfg_driver == "other":
            cfg_driver = str(meter_entry.get("type_other") or "").strip()
        if driver == "unknown" and cfg_driver:
            driver = cfg_driver
    if mtype == "unknown":
        last_row = next(
            (r for r in read_tsv(METER_LAST_JSON_TSV, ["id", "ts", "json"])
             if normalize_meter_id(r.get("id")) == mid),
            None,
        )
        try:
            last_json = json.loads(str((last_row or {}).get("json") or "") or "{}")
        except (ValueError, TypeError):
            last_json = {}
        if isinstance(last_json, dict):
            mtype = str(last_json.get("media") or "").strip() or "unknown"

    analyze_arg = f"--analyze={key}" if key else "--analyze"
    analyze_output = ""
    try:
        proc = subprocess.run(
            [WMBUSMETERS_BIN, analyze_arg, raw],
            capture_output=True, text=True, timeout=20,
        )
        analyze_output = (proc.stdout or "") + (proc.stderr or "")
    except FileNotFoundError:
        analyze_output = "(wmbusmeters binary not available)"
    except subprocess.TimeoutExpired:
        analyze_output = "(wmbusmeters --analyze timed out)"
    analyze_output = analyze_output.strip()

    # The candidate table knows the manufacturer, the meters table does not —
    # but the analysis just printed it (dll-mfct), so take it from there rather
    # than sending "unknown" upstream in a report about an unrecognised meter.
    if manufacturer == "unknown":
        mfct = re.search(r"dll-mfct \(([A-Z0-9]{2,4})\)", analyze_output)
        if mfct:
            manufacturer = mfct.group(1)

    analyze_note = (
        "--- wmbusmeters --analyze output (decrypted with the configured AES key; key not included) ---"
        if key
        else "--- wmbusmeters --analyze output ---"
    )
    report = "\n".join([
        f"telegram=|{raw}|",
        f"manufacturer: {manufacturer}",
        f"type/medium: {mtype}",
        f"suggested driver: {driver}",
        "",
        analyze_note,
        "```",
        analyze_output or "(no output)",
        "```",
    ])
    return True, {
        "ok": True,
        "meter_id": mid,
        "report": report,
        "raw_ts": raw_ts,
        "key_used": bool(key),
    }


def _id_le_hex(mid: str) -> str:
    """Meter id in little-endian byte order, lowercase — the form it appears in
    inside a wMBus frame's A-field (e.g. 22344799 -> 99473422)."""
    pairs = [mid[i:i + 2] for i in range(0, len(mid), 2)]
    return "".join(reversed(pairs)).lower()


def _resolve_raw_for_id(mid: str) -> tuple[str, str]:
    """Return (raw_hex, ts) of the most recent stored frame for this id, or
    ("",""). Candidates have a keyed RAW row; configured meters do not, so fall
    back to the most recent frame in status_recent_raw.tsv whose hex contains the
    id in little-endian order (the same matching the preview path uses)."""
    rows = read_tsv(CANDIDATE_RAW_TSV, ["id", "ts", "raw_len", "raw"])
    row = next((r for r in rows if normalize_meter_id(r.get("id")) == mid), None)
    if row and str(row.get("raw") or "").strip():
        return str(row["raw"]).strip(), str(row.get("ts") or "")

    le = _id_le_hex(mid)
    match = ("", "")
    if le:
        for r in read_tsv(RECENT_RAW_TSV, ["ts", "raw_len", "raw"]):
            raw = str(r.get("raw") or "").strip()
            if le in raw.lower():
                match = (raw, str(r.get("ts") or ""))  # keep last (most recent)
    return match


def _decode_with_driver(raw: str, driver: str, mid: str, key: str) -> dict | None:
    """Decode one RAW frame with a forced driver and return its data fields
    (meta keys stripped), {} if nothing decoded, or None on a hard failure.
    wmbusmeters validates the driver itself, so a wrong driver yields few/odd
    fields rather than an error — which is exactly why the UI shows values."""
    driver = (driver or "auto").strip() or "auto"
    if not re.match(r"^[A-Za-z0-9_]+$", driver):
        return None
    raw = re.sub(r"\s+", "", raw or "")
    if not re.fullmatch(r"[0-9A-Fa-f]+", raw or ""):
        return None
    mid_lc = mid.lower()
    key_arg = key if key else "NOKEY"
    try:
        proc = subprocess.run(
            [
                WMBUSMETERS_BIN,
                "--silent",
                "--format=json",
                "stdin:hex",
                f"compare_{mid_lc}",
                driver,
                mid_lc,
                key_arg,
            ],
            input=f"{raw}\n",
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    for line in reversed((proc.stdout or "").splitlines()):
        line = line.strip()
        if line.startswith("{") and '"_":"telegram"' in line:
            try:
                obj = json.loads(line)
            except ValueError:
                return None
            drop = {"_", "name", "id", "meter", "timestamp", "media"}
            return {k: v for k, v in obj.items() if k not in drop}
    return {}


def _analyze_auto_driver(raw: str, key: str) -> str:
    """Return the driver name from wmbusmeters' "Auto driver" line, if any."""
    raw = re.sub(r"\s+", "", raw or "")
    if not re.fullmatch(r"[0-9A-Fa-f]+", raw or ""):
        return ""
    analyze_arg = f"--analyze={key}" if key else "--analyze"
    try:
        proc = subprocess.run(
            [WMBUSMETERS_BIN, analyze_arg, raw],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return ""
    output = (proc.stdout or "") + (proc.stderr or "")
    match = re.search(r"(?im)^\s*Auto driver\s*:\s*([A-Za-z0-9_]+)\b", output)
    if not match:
        return ""
    driver = match.group(1).strip()
    if not driver or driver.lower() == "unknown":
        return ""
    return driver


def compare_meter_drivers(meter_id: str, requested_driver: str, key_override: str | None = None) -> tuple[bool, dict]:
    """Decode a meter's last frame with wmbusmeters' auto driver (when useful)
    or the saved driver, and with the requested driver. Pure read + short-lived
    wmbusmeters calls (~ms each); no pipeline interaction."""
    mid = normalize_meter_id(meter_id)
    if not VALID_ID_RE.match(mid):
        return False, {"ok": False, "error": "invalid_meter_id"}

    raw, raw_ts = _resolve_raw_for_id(mid)
    if not raw:
        return False, {"ok": False, "error": "no_raw_telegram"}

    key = ""
    current_driver = "auto"
    configured = False
    options = read_json(OPTIONS_JSON)
    if isinstance(options, dict):
        for m in options.get("meters", []) or []:
            if isinstance(m, dict) and normalize_meter_id(m.get("meter_id")) == mid:
                configured = True
                k = str(m.get("key") or "").strip()
                if re.match(r"^[0-9A-Fa-f]{32}$", k):
                    key = k
                current_driver = str(m.get("type") or "").strip() or "auto"
                break

    requested_driver = (requested_driver or "").strip() or current_driver
    if not re.match(r"^[A-Za-z0-9_]+$", requested_driver):
        return False, {"ok": False, "error": "invalid_driver"}

    key_override = (key_override or "").strip()
    if key_override:
        if not re.match(r"^[0-9A-Fa-f]{32}$", key_override):
            return False, {"ok": False, "error": "invalid_key"}
        key = key_override

    auto_driver = _analyze_auto_driver(raw, key)
    baseline_driver = current_driver
    baseline_source = "saved" if configured else "auto"
    if not configured and auto_driver:
        baseline_driver = auto_driver
    elif (
        current_driver.lower() == requested_driver.lower()
        and auto_driver
        and auto_driver.lower() != requested_driver.lower()
    ):
        baseline_driver = auto_driver
        baseline_source = "auto"

    cur = _decode_with_driver(raw, baseline_driver, mid, key)
    cand = _decode_with_driver(raw, requested_driver, mid, key)
    if cur is None or cand is None:
        return False, {"ok": False, "error": "decode_failed"}

    return True, {
        "ok": True,
        "meter_id": mid,
        "raw_ts": raw_ts,
        "key_used": bool(key),
        "auto_driver": auto_driver,
        "saved_driver": current_driver,
        "same_driver": baseline_driver.lower() == requested_driver.lower(),
        "current": {"driver": baseline_driver, "source": baseline_source, "fields": cur},
        "candidate": {"driver": requested_driver, "fields": cand},
    }


def read_tsv(path: Path, fields: list[str], limit: int | None = None, reverse: bool = False) -> list[dict]:
    rows: list[dict] = []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        lines = []
    if reverse:
        lines = list(reversed(lines))
    for line in lines:
        if not line.strip():
            continue
        parts = line.split("\t")
        row = {name: parts[i] if i < len(parts) else "" for i, name in enumerate(fields)}
        rows.append(row)
        if limit and len(rows) >= limit:
            break
    return rows


def esp_rx_api_payload(limit: int = 1000, since: int = 0, until: int = 0,
                       max_limit: int = 10000) -> dict:
    """Return bounded, secret-free structured RX evidence for the opt-in API."""
    from collections import deque

    limit = max(1, min(int(limit), max(1, int(max_limit))))
    since = max(0, int(since))
    until = max(0, int(until))
    reception = read_tsv(
        STATUS_ESP_RX_RECEPTION_FILE,
        ["meter_id", "source", "first_seen", "last_seen", "count", "last_topic"],
    )
    sequence = read_tsv(
        STATUS_ESP_RX_SEQUENCE_FILE,
        ["source", "boot_id", "last_seq", "missing", "out_of_order", "last_seen"],
    )
    history: deque[dict] = deque(maxlen=limit)
    invalid_lines = 0
    try:
        with ESP_RF_RX_HISTORY_FILE.open("r", encoding="utf-8", errors="replace") as stream:
            for line in stream:
                try:
                    event = json.loads(line)
                except (TypeError, ValueError):
                    invalid_lines += 1
                    continue
                if not isinstance(event, dict):
                    invalid_lines += 1
                    continue
                event_time = safe_int(event.get("bridge_rx_time", 0))
                if since and event_time < since:
                    continue
                if until and event_time >= until:
                    continue
                # Explicit allow-list: additions to the internal history do not
                # silently widen this external contract.
                history.append({key: event.get(key) for key in (
                    "bridge_rx_time", "source", "schema", "boot_id", "seq",
                    "rx_task_wakeup_us", "meter_id", "mode", "rssi_dbm",
                    "frame_crc32", "frame_length",
                )})
    except OSError:
        pass
    return {
        "ok": True,
        "schema": 1,
        "generated_at": int(time.time()),
        "filters": {"since": since, "until": until, "limit": limit},
        "reception": reception,
        "sequence": sequence,
        "history": list(history),
        "history_invalid_lines": invalid_lines,
    }


def write_lines_atomic(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Use ".webui.tmp" suffix to avoid colliding with bridge.sh which also
    # writes "<file>.tmp" for the same TSV files (e.g. status_meters.tsv.tmp).
    # If both processes used the same temp name they could overwrite each other.
    tmp = path.with_suffix(path.suffix + ".webui.tmp")
    tmp.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    tmp.replace(path)


def ignored_ids() -> set[str]:
    try:
        return {line.strip() for line in IGNORED_CANDIDATES.read_text(encoding="utf-8", errors="replace").splitlines() if VALID_ID_RE.match(line.strip())}
    except Exception:
        return set()


def add_ignored(mid: str) -> None:
    mid = mid.strip()
    if not VALID_ID_RE.match(mid):
        return
    ids = sorted(ignored_ids() | {mid})
    write_lines_atomic(IGNORED_CANDIDATES, ids)


def remove_ignored(mid: str) -> None:
    mid = mid.strip()
    ids = sorted(x for x in ignored_ids() if x != mid)
    write_lines_atomic(IGNORED_CANDIDATES, ids)


def safe_int(value: object) -> int:
    try:
        return int(str(value or "0"))
    except Exception:
        return 0


def _esp_device_from_topic(topic: object) -> str:
    """Return the ESP device segment from wmbus/<device>/... topics."""
    parts = str(topic or "").split("/")
    if len(parts) < 3 or parts[0] != "wmbus":
        return ""
    return parts[1].strip()


def _current_raw_esp_source() -> tuple[str, str, bool]:
    """Return the freshest live RAW ESP source and whether tracker rows exist.

    The RAW telegram tracker is the source of truth for what the bridge is
    currently reading. Diagnostic summaries may be retained or may come from a
    different ESP, so they must not drive the dashboard tile when a live RAW
    source is known.
    """
    import time as _time

    rows = read_tsv(
        STATUS_ESP_TELEGRAM_DEVICES_FILE,
        ["name", "last_telegram_epoch", "topic", "telegram_count"],
    )
    latest: dict = {}
    for row in rows:
        ep = safe_int(row.get("last_telegram_epoch"))
        if ep > safe_int(latest.get("last_telegram_epoch")):
            latest = row

    if not latest:
        return "", "", False

    name = str(latest.get("name") or "").strip()
    topic = str(latest.get("topic") or "").strip()
    ep = safe_int(latest.get("last_telegram_epoch"))
    if name and ep > 0 and (_time.time() - ep) <= 5 * 60:
        return name, topic, True
    return "", "", True


def _diag_matches_current_raw_source(diag: dict, current_raw_device: str, tracker_has_rows: bool) -> bool:
    """Allow diag data to drive the tile only for the live RAW source.

    Backward compatibility: when per-device RAW tracking is unavailable (for
    example RAW_TOPIC has no '+' wildcard), keep the previous diag-only fallback.
    """
    if not diag:
        return False
    diag_device = _esp_device_from_topic(diag.get("_topic"))
    if current_raw_device:
        return diag_device == current_raw_device
    return not tracker_has_rows


# ── REMOVED: legacy HTML helpers ────────────────────────────────────────────
# esc(), fmt_ts(), fmt_interval(), reception_line(), media_icon(), tr_media(),
# media_class(), candidate_config(), candidate_encryption_hint() — all only
# served the dormant page_*/render_* HTML pages. The new SPA (app.js) does
# its own escaping, formatting, media icons, and encryption-hint logic.
# ────────────────────────────────────────────────────────────────────────────


def normalize_decimal(value: str, default: str) -> tuple[str, str]:
    raw = (value or "").strip().replace(" ", "").replace(",", ".")
    if not raw:
        raw = default
    if not re.match(r"^-?[0-9]+([.][0-9]+)?$", raw):
        return default, f"Invalid number '{value}', used default {default}."
    try:
        number = float(raw)
    except Exception:
        return default, f"Invalid number '{value}', used default {default}."
    if number < 0:
        return default, f"Negative number '{value}' is not valid here, used default {default}."
    return raw, ""


def write_json_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def webui_add_event(level: str, message: str) -> None:
    """Append a short UI action event to the runtime event stream."""
    try:
        now = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
        EVENTS_TSV.parent.mkdir(parents=True, exist_ok=True)
        with EVENTS_TSV.open("a", encoding="utf-8") as fh:
            fh.write(f"{now}\t{level}\t{message}\n")
        lines = EVENTS_TSV.read_text(encoding="utf-8", errors="replace").splitlines()[-80:]
        EVENTS_TSV.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    except Exception:
        pass


def update_options_for_search(expected: str, tolerance: str, enabled: bool = True) -> tuple[bool, str]:
    import urllib.request
    options = read_json(OPTIONS_JSON)
    if not isinstance(options, dict):
        options = {}
    expected_norm, expected_err = normalize_decimal(expected, "0")
    tolerance_norm, tolerance_err = normalize_decimal(tolerance, "0.05")
    options["search_mode"] = bool(enabled)
    if enabled:
        options["search_expected_value_m3"] = float(expected_norm)
        options["search_tolerance_m3"] = float(tolerance_norm)
        options.setdefault("search_delta_mode", False)
        options.setdefault("search_min_delta_m3", 0.001)
        options.setdefault("search_topic", "wmbus/search/candidates")

    msg_parts = [x for x in [expected_err, tolerance_err] if x]
    user_msg = "; ".join(msg_parts)

    token = os.environ.get("SUPERVISOR_TOKEN", "")
    if token:
        try:
            payload = json.dumps({"options": options}, ensure_ascii=False).encode("utf-8")
            req = urllib.request.Request(
                "http://supervisor/addons/self/options",
                data=payload,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status in (200, 201):
                    if enabled:
                        return True, user_msg or f"Search enabled: expected={expected_norm} m³ tolerance={tolerance_norm} m³."
                    return True, "Search mode disabled."
                body = resp.read().decode("utf-8", errors="replace")
                return False, f"Supervisor API returned HTTP {resp.status}: {body[:200]}"
        except Exception as exc:
            webui_add_event("error", f"Supervisor API options failed: {exc}, falling back to file write")

    # Fallback for non-HA environments
    write_json_atomic(OPTIONS_JSON, options)
    if enabled:
        return True, user_msg or f"Search enabled: expected={expected_norm} m³ tolerance={tolerance_norm} m³."
    return True, "Search mode disabled."



# Field catalog per driver, from `wmbusmeters --listfields=<driver>`. The output
# is one field per line: the name right-aligned in a column, two spaces, then the
# description written by the driver author. The decoder binary is pinned by the
# Dockerfile, so a driver's catalog cannot change while the container runs and a
# process-lifetime cache is enough.
DRIVER_FIELDS_CACHE: dict[str, list[dict]] = {}

# Every driver's catalog opens with the same ten universal fields, and none of
# them can become a Home Assistant entity here. Marking them is what keeps the
# table honest: a checkbox next to a field that cannot be published reads as a
# broken switch (reported from a live install: all fields ticked, five of them
# never appeared). Two distinct causes, both taken from the decoder's own
# behaviour rather than assumed:
#
#   not_in_json — the field is not in the decoder's JSON output at all.
#     timestamp_ut / timestamp_lt / timestamp_utc are deliberately left out of
#     JSON by wmbusmeters (they exist for the `fields`/CSV formats), while
#     device and rssi_dbm are written only when a radio device received the
#     telegram. The bridge feeds the decoder through stdin:hex, so there is no
#     receiving device to report and the keys are omitted.
#   identity — the field is in the JSON, but emit_discovery_from_json() keeps
#     the meter's identity out of the entity list on purpose: it is already the
#     device name and it travels in every entity's attributes.
#
# NB the decoder's own rssi_dbm is unrelated to the opt-in per-board RSSI this
# add-on joins on as rssi_<board>_dbm — same idea, different origin.
NON_ENTITY_FIELDS: dict[str, str] = {
    "timestamp_ut": "not_in_json",
    "timestamp_lt": "not_in_json",
    "timestamp_utc": "not_in_json",
    "device": "not_in_json",
    "rssi_dbm": "not_in_json",
    "id": "identity",
    "name": "identity",
    "meter": "identity",
    "media": "identity",
    "timestamp": "identity",
}


def driver_fields(driver: str) -> tuple[bool, list[dict], str]:
    """Return (ok, [{"name":…, "description":…}], error) for one driver."""
    driver = (driver or "").strip()
    if not re.match(r"^[A-Za-z0-9_]+$", driver):
        return False, [], f"Invalid driver: {driver}"
    if driver in DRIVER_FIELDS_CACHE:
        return True, DRIVER_FIELDS_CACHE[driver], ""
    try:
        proc = subprocess.run(
            [WMBUSMETERS_BIN, f"--listfields={driver}"],
            capture_output=True, text=True, timeout=10,
        )
    except FileNotFoundError:
        return False, [], "wmbusmeters binary not available"
    except subprocess.TimeoutExpired:
        return False, [], "wmbusmeters --listfields timed out"
    fields: list[dict] = []
    for line in (proc.stdout or "").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        # Name and description are separated by a run of spaces; a description
        # may contain single spaces, so split on the first double space only.
        parts = re.split(r"\s{2,}", stripped, maxsplit=1)
        name = parts[0].strip()
        if not name:
            continue
        fields.append({
            "name": name,
            "description": parts[1].strip() if len(parts) > 1 else "",
            "no_entity": NON_ENTITY_FIELDS.get(name.lower(), ""),
        })
    if not fields:
        # An unknown driver prints nothing useful; do not cache that.
        return False, [], (proc.stderr or "").strip() or f"No fields reported for driver {driver}"
    DRIVER_FIELDS_CACHE[driver] = fields
    return True, fields, ""


# Glob patterns for exclude_fields. Field names are [a-z0-9_], the pattern
# syntax adds * and ?, and the separators are commas/spaces. Anything else is
# rejected rather than stored: the value ends up word-split in bridge.sh, and a
# tidy charset keeps options.json readable and the matcher predictable.
EXCLUDE_FIELDS_RE = re.compile(r"^[A-Za-z0-9_*?,.\- ]*$")


def _clean_exclude_fields(value: str) -> tuple[bool, str, str]:
    """Return (ok, cleaned, error). Empty means "publish every field".

    Besides normalising separators, this drops entries that another entry
    already covers: a plain field name is redundant next to a glob that matches
    it. The field table writes exact names while a human writes globs, so the
    two mix easily — and a name kept beside its glob is not just noise, it
    outlives the glob. Removing `history_*_date` would otherwise leave
    `history_reference_date` excluded on its own, which reads as the UI
    ignoring the click. Globs are never dropped, including by wider globs:
    losing a pattern someone typed is worse than keeping a redundant one.
    """
    tokens = (value or "").replace(",", " ").split()
    cleaned = " ".join(tokens)
    if not EXCLUDE_FIELDS_RE.match(cleaned):
        return False, "", (
            "Invalid exclude_fields — allowed: letters, digits, _ . - * ? "
            "separated by commas or spaces."
        )
    globs = [t for t in tokens if "*" in t or "?" in t]
    kept: list[str] = []
    seen: set[str] = set()
    for token in tokens:
        low = token.lower()
        if low in seen:
            continue
        is_glob = "*" in token or "?" in token
        if not is_glob and any(fnmatch.fnmatchcase(low, g.lower()) for g in globs):
            continue
        seen.add(low)
        kept.append(token)
    return True, " ".join(kept), ""


# Extra fields the DECODER computes from the telegram ("name=formula",
# semicolon separated). The arithmetic is upstream's: wmbusmeters accepts
# calculate_<name>=<formula> in a meter config file and publishes the result as
# an ordinary JSON field, which then becomes an entity through the normal
# Discovery path. The bridge only has to carry the user's line into the file it
# regenerates. Semicolons separate entries because a formula contains spaces
# and commas ("flow_temperature_c - return_temperature_c").
#
# Only the SHAPE is validated here. Whether the formula makes sense is the
# decoder's judgement, and it reports a bad one on its own; guessing at it here
# would mean maintaining a second, worse copy of its grammar.
CALC_NAME_RE = re.compile(r"^[a-z][a-z0-9_]*$")


def _clean_calculated_fields(value: str) -> tuple[bool, str, str]:
    """Return (ok, cleaned, error). Empty means "no calculated fields"."""
    entries: list[str] = []
    for raw_entry in re.split(r"[;\n]", value or ""):
        entry = raw_entry.strip()
        if not entry:
            continue
        if "=" not in entry:
            return False, "", f"Invalid calculated field '{entry}' - expected name=formula."
        name, formula = entry.split("=", 1)
        name = name.strip()
        formula = formula.strip()
        if not CALC_NAME_RE.match(name):
            return False, "", (
                f"Invalid field name '{name}' - lowercase letters, digits and _ only, "
                "starting with a letter (e.g. difftemp_c).")
        if not formula:
            return False, "", f"Field '{name}' has an empty formula."
        entries.append(f"{name}={formula}")
    return True, "; ".join(entries), ""


# Constant fields the user attaches to a meter (upstream's field_/json_ keys).
# The decoder copies the value into the JSON verbatim and always as a string, so
# they surface as diagnostic entities and as attributes on every entity of that
# meter - a label like a location or an apartment number, not a measurement.
# Same entry shape as the formulas, and for the same reason: a value may contain
# spaces, so entries are separated by semicolons rather than by commas.
def _clean_static_fields(value: str) -> tuple[bool, str, str]:
    """Return (ok, cleaned, error). Empty means "no constant fields"."""
    entries: list[str] = []
    for raw_entry in re.split(r"[;\n]", value or ""):
        entry = raw_entry.strip()
        if not entry:
            continue
        if "=" not in entry:
            return False, "", f"Invalid constant field '{entry}' - expected name=value."
        name, text = entry.split("=", 1)
        name = name.strip()
        text = text.strip()
        if not CALC_NAME_RE.match(name):
            return False, "", (
                f"Invalid field name '{name}' - lowercase letters, digits and _ only, "
                "starting with a letter (e.g. location).")
        # An empty value is a template the user inserted from a chip and did not
        # fill in. Refusing the whole save for it would punish the convenience:
        # clicking four chips and filling two is the normal way to use them.
        # A constant with no value has nothing to publish anyway, so it is
        # dropped rather than rejected. Formulas keep the error - an empty one
        # is a typo, not an unused template.
        if not text:
            continue
        entries.append(f"{name}={text}")
    return True, "; ".join(entries), ""


def add_meter_to_options(meter_id: str, driver: str, key: str, meter_name: str = "",
                         exclude_fields: str = "",
                         calculated_fields: str = "",
                         static_fields: str = "") -> tuple[bool, str]:
    """Add a meter entry to addon options via HA Supervisor API.

    Writing directly to /data/options.json does NOT persist across restarts —
    Supervisor overwrites it from its own database on every addon start.
    The correct way is POST http://supervisor/addons/self/options with the full
    options payload. Supervisor then persists it and writes options.json on next start.
    """
    import urllib.request
    import urllib.error

    meter_id = normalize_meter_id(meter_id)
    if not VALID_ID_RE.match(meter_id):
        return False, f"Invalid meter_id: {meter_id}"

    key = (key or "").strip()
    if key and not re.match(r"^[0-9A-Fa-f]{32}$", key):
        return False, f"Invalid AES key — must be exactly 32 HEX chars, got {len(key)}."

    driver = (driver or "").strip()
    if driver and not re.match(r"^[A-Za-z0-9_]+$", driver):
        return False, f"Invalid driver: {driver}"

    # Read current state from options.json (Supervisor-written, most recent values)
    options = read_json(OPTIONS_JSON)
    if not isinstance(options, dict):
        options = {}

    meters = options.get("meters", [])
    if not isinstance(meters, list):
        meters = []

    # Check duplicate
    for m in meters:
        if isinstance(m, dict) and normalize_meter_id(m.get("meter_id")) == meter_id:
            return False, f"Meter {meter_id} already exists in options."

    # Build entry id: use provided name (sanitized) or fall back to meter_XXXXXXXX
    import re as _re, unicodedata as _ud
    if meter_name:
        # Keep Unicode letters and numbers, replace everything else with _
        safe_name = _re.sub(r'[^\w\-]', '_', meter_name.strip())
        safe_name = _re.sub(r'_+', '_', safe_name).strip('_')
        entry_id = safe_name if safe_name else f"meter_{meter_id}"
    else:
        entry_id = f"meter_{meter_id}"

    entry = {
        "id": entry_id,
        "meter_id": meter_id,
        "type": driver if driver and driver != "unknown" else "auto",
        "type_other": "",
        "key": key,
    }
    if exclude_fields:
        entry["exclude_fields"] = exclude_fields
    if calculated_fields:
        entry["calculated_fields"] = calculated_fields
    if static_fields:
        entry["static_fields"] = static_fields
    meters.append(entry)
    options["meters"] = meters

    # Try Supervisor API first — this persists across restarts
    token = os.environ.get("SUPERVISOR_TOKEN", "")
    # Captured Supervisor rejection reason, surfaced to the user/log. urlopen
    # raises HTTPError on 4xx, so a schema rejection (e.g. a driver value the
    # addon's options schema does not accept) never reaches the resp.status
    # branch below — without reading the error BODY here the real reason was
    # lost and the meter silently fell back to a file-only write that does not
    # survive an upgrade/restart. This is the "meter X disappears after upgrade"
    # report (notably Diehl/Izar). Capturing the body makes the cause visible.
    sup_detail = ""
    if token:
        try:
            payload = json.dumps({"options": options}, ensure_ascii=False).encode("utf-8")
            req = urllib.request.Request(
                "http://supervisor/addons/self/options",
                data=payload,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status in (200, 201):
                    # Also write locally so the next add_meter call reads the updated list
                    # (Supervisor may not have written options.json yet when user adds quickly)
                    write_json_atomic(OPTIONS_JSON, options)
                    key_info = f"key={key[:4]}..." if key else "no key"
                    msg = f"Meter {meter_id} ({driver}) saved. {key_info}. Reloading pipeline to apply."
                    webui_add_event("ok", msg)
                    return True, msg
                body = resp.read().decode("utf-8", errors="replace")
                return False, f"Supervisor API returned HTTP {resp.status}: {body[:200]}"
        except urllib.error.HTTPError as http_err:
            try:
                sup_detail = http_err.read().decode("utf-8", errors="replace").strip()
            except Exception:
                sup_detail = ""
            webui_add_event(
                "error",
                f"Supervisor API REJECTED meter {meter_id} ({driver}) save: "
                f"HTTP {http_err.code} {sup_detail[:300]} — falling back to a file-only "
                f"write that will NOT survive an upgrade/restart.",
            )
        except Exception as exc:
            webui_add_event("error", f"Supervisor API options failed: {exc}, falling back to file write")

    # Fallback: write directly. Reached EITHER outside HA (no token, plain
    # Docker) OR when the Supervisor API call failed/raised (e.g. HTTP 400).
    # Distinguish the two so the log doesn't blame a missing token when the
    # token was present but Supervisor rejected the options.
    write_json_atomic(OPTIONS_JSON, options)
    key_info = f"key={key[:4]}..." if key else "no key"
    if token:
        reason = f" Supervisor rejected it: {sup_detail[:200]}" if sup_detail else " Supervisor API rejected the change."
        msg = (f"Meter {meter_id} ({driver}) saved to options.json as a fallback —{reason} "
               f"It will NOT survive an HA restart/upgrade. {key_info}. Reloading pipeline to apply.")
    else:
        msg = f"Meter {meter_id} ({driver}) saved to options.json (file only — no SUPERVISOR_TOKEN). {key_info}. Reloading pipeline to apply."
    webui_add_event("warn", msg)
    return True, msg



def _remove_meter_from_tsv(meter_id: str) -> None:
    """Remove a row from status_meters.tsv so the meter disappears from the WebGUI immediately.

    bridge.sh only appends/updates TSV rows when a decoded telegram arrives.
    Without this cleanup the deleted meter would remain visible until the next
    addon restart (when bridge.sh stops receiving telegrams for the removed meter
    and the row naturally ages out — which can take hours).
    """
    _remove_id_from_tsv(METERS_TSV, meter_id)


def _remove_id_from_tsv(path: Path, meter_id: str) -> None:
    try:
        if not path.exists():
            return
        meter_id = normalize_meter_id(meter_id)
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        new_lines = [l for l in lines if normalize_meter_id(l.split("\t")[0]) != meter_id]
        write_lines_atomic(path, new_lines)
    except Exception:
        pass  # non-fatal — worst case the row disappears after restart


def _cleanup_preview_cache(meter_id: str, remove_preview_file: bool = True) -> None:
    meter_id = normalize_meter_id(meter_id)
    if not VALID_ID_RE.match(meter_id):
        return

    _remove_id_from_tsv(STATUS_CANDIDATE_VALUES_FILE, meter_id)
    _remove_id_from_tsv(STATUS_CANDIDATE_PREVIEW_STATE_FILE, meter_id)

    try:
        attempt_file = BASE / ".preview_attempts" / meter_id
        if attempt_file.exists():
            attempt_file.unlink()
    except OSError:
        pass

    if remove_preview_file:
        try:
            preview_file = PREVIEW_METER_DIR / f"meter-preview-{meter_id}"
            if preview_file.exists():
                preview_file.unlink()
        except OSError:
            pass


def remove_meter_from_options(meter_id: str) -> tuple[bool, str]:
    """Remove a meter from options via HA Supervisor API."""
    import urllib.request

    meter_id = normalize_meter_id(meter_id)
    if not VALID_ID_RE.match(meter_id):
        return False, f"Invalid meter_id: {meter_id}"

    options = read_json(OPTIONS_JSON)
    if not isinstance(options, dict):
        return False, "Cannot read options.json."

    meters = options.get("meters", [])
    if not isinstance(meters, list):
        return False, "No meters list in options."

    before = len(meters)
    meters = [m for m in meters if not (isinstance(m, dict) and normalize_meter_id(m.get("meter_id")) == meter_id)]
    if len(meters) == before:
        _remove_meter_from_tsv(meter_id)
        _cleanup_preview_cache(meter_id)
        return True, f"Meter {meter_id} was already absent from options; removed stale runtime row if present."

    options["meters"] = meters

    token = os.environ.get("SUPERVISOR_TOKEN", "")
    if token:
        try:
            payload = json.dumps({"options": options}, ensure_ascii=False).encode("utf-8")
            req = urllib.request.Request(
                "http://supervisor/addons/self/options",
                data=payload,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status in (200, 201):
                    # Also write locally so subsequent reads see the updated list
                    write_json_atomic(OPTIONS_JSON, options)
                    # Remove from TSV immediately — bridge.sh won't clean it on its own
                    _remove_meter_from_tsv(meter_id)
                    _cleanup_preview_cache(meter_id)
                    msg = f"Meter {meter_id} removed. Reloading pipeline to apply."
                    webui_add_event("ok", msg)
                    return True, msg
                body = resp.read().decode("utf-8", errors="replace")
                return False, f"Supervisor API HTTP {resp.status}: {body[:200]}"
        except Exception as exc:
            webui_add_event("error", f"Supervisor API remove failed: {exc}")
            return False, f"Supervisor API failed: {exc}"

    # Fallback
    write_json_atomic(OPTIONS_JSON, options)
    _remove_meter_from_tsv(meter_id)
    _cleanup_preview_cache(meter_id)
    msg = f"Meter {meter_id} removed (file only — no SUPERVISOR_TOKEN). Reloading pipeline to apply."
    webui_add_event("warn", msg)
    return True, msg


def update_meter_in_options(meter_id: str, driver: str, key: str | None = None,
                            exclude_fields: str | None = None,
                            calculated_fields: str | None = None,
                            static_fields: str | None = None) -> tuple[bool, str]:
    """Change the driver (and optionally the AES key) of an existing meter.

    Same Supervisor-first persistence as add/remove_meter_from_options. The
    driver is a free string — wmbusmeters validates it at decode time — so a
    wrong first guess (e.g. istawater vs evo868) can be corrected without
    removing and re-adding the meter.
    """
    import urllib.request

    meter_id = normalize_meter_id(meter_id)
    if not VALID_ID_RE.match(meter_id):
        return False, f"Invalid meter_id: {meter_id}"

    driver = (driver or "").strip()
    if not driver:
        return False, "Driver must not be empty."
    if not re.match(r"^[A-Za-z0-9_]+$", driver):
        return False, f"Invalid driver: {driver}"

    if key:
        key = key.strip()
        if key and not re.match(r"^[0-9A-Fa-f]{32}$", key):
            return False, f"Invalid AES key — must be exactly 32 HEX chars, got {len(key)}."

    options = read_json(OPTIONS_JSON)
    if not isinstance(options, dict):
        return False, "Cannot read options.json."
    meters = options.get("meters", [])
    if not isinstance(meters, list):
        return False, "No meters list in options."

    entry = next(
        (m for m in meters if isinstance(m, dict) and normalize_meter_id(m.get("meter_id")) == meter_id),
        None,
    )
    if entry is None:
        return False, f"Meter {meter_id} not found in options."

    entry["type"] = driver
    entry["type_other"] = ""
    if key:
        entry["key"] = key
    # None means the caller did not touch the field; an empty string is an
    # explicit "publish every field again", so the key is dropped rather than
    # stored empty.
    if exclude_fields is not None:
        if exclude_fields:
            entry["exclude_fields"] = exclude_fields
        else:
            entry.pop("exclude_fields", None)
    if calculated_fields is not None:
        if calculated_fields:
            entry["calculated_fields"] = calculated_fields
        else:
            entry.pop("calculated_fields", None)
    if static_fields is not None:
        if static_fields:
            entry["static_fields"] = static_fields
        else:
            entry.pop("static_fields", None)
    options["meters"] = meters

    token = os.environ.get("SUPERVISOR_TOKEN", "")
    if token:
        try:
            payload = json.dumps({"options": options}, ensure_ascii=False).encode("utf-8")
            req = urllib.request.Request(
                "http://supervisor/addons/self/options",
                data=payload,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status in (200, 201):
                    write_json_atomic(OPTIONS_JSON, options)
                    msg = f"Meter {meter_id} driver changed to {driver}. Reloading pipeline to apply."
                    webui_add_event("ok", msg)
                    return True, msg
                body = resp.read().decode("utf-8", errors="replace")
                return False, f"Supervisor API HTTP {resp.status}: {body[:200]}"
        except Exception as exc:
            webui_add_event("error", f"Supervisor API update failed: {exc}")
            return False, f"Supervisor API failed: {exc}"

    # Fallback: file-only write (plain Docker / no SUPERVISOR_TOKEN).
    write_json_atomic(OPTIONS_JSON, options)
    msg = f"Meter {meter_id} driver changed to {driver} (file only — no SUPERVISOR_TOKEN). Reloading pipeline to apply."
    webui_add_event("warn", msg)
    return True, msg


def factory_reset() -> tuple[bool, str]:
    """Remove ALL configured meters and return the add-on to its post-install state.

    Persists meters=[] (Supervisor-first, same as remove_meter_from_options),
    then writes the removed ids to FACTORY_RESET_REQUEST. bridge.sh's heartbeat
    ticker consumes that flag: it clears each meter's retained MQTT Discovery
    (so the entities disappear from Home Assistant), wipes runtime state
    (status_*/search_*/seen + preview meter files) and soft-reloads the pipeline.
    The flag is written only after options are persisted, so a failed persist
    never triggers a teardown.
    """
    import urllib.request

    options = read_json(OPTIONS_JSON)
    if not isinstance(options, dict):
        return False, "Cannot read options.json."

    meters = options.get("meters", [])
    if not isinstance(meters, list):
        meters = []

    ids = []
    for m in meters:
        if isinstance(m, dict) and m.get("meter_id"):
            mid = normalize_meter_id(m.get("meter_id"))
            if VALID_ID_RE.match(mid):
                ids.append(mid)

    options["meters"] = []

    def _signal_bridge() -> None:
        # Hand the removed ids to bridge.sh for discovery teardown + state wipe.
        try:
            FACTORY_RESET_REQUEST.write_text(
                "".join(f"{i}\n" for i in ids), encoding="utf-8"
            )
        except OSError as exc:
            webui_add_event("warn", f"Factory reset: cannot write request flag: {exc}")

    token = os.environ.get("SUPERVISOR_TOKEN", "")
    if token:
        try:
            payload = json.dumps({"options": options}, ensure_ascii=False).encode("utf-8")
            req = urllib.request.Request(
                "http://supervisor/addons/self/options",
                data=payload,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status in (200, 201):
                    write_json_atomic(OPTIONS_JSON, options)
                    _signal_bridge()
                    msg = (f"Factory reset: removed {len(ids)} meter(s); clearing entities "
                           f"and runtime state, reloading pipeline.")
                    webui_add_event("ok", msg)
                    return True, msg
                body = resp.read().decode("utf-8", errors="replace")
                return False, f"Supervisor API HTTP {resp.status}: {body[:200]}"
        except Exception as exc:
            webui_add_event("error", f"Supervisor API factory reset failed: {exc}")
            return False, f"Supervisor API failed: {exc}"

    # Fallback: file-only write (plain Docker / no SUPERVISOR_TOKEN).
    write_json_atomic(OPTIONS_JSON, options)
    _signal_bridge()
    msg = (f"Factory reset: removed {len(ids)} meter(s) (file only — no SUPERVISOR_TOKEN); "
           f"clearing entities and runtime state, reloading pipeline.")
    webui_add_event("warn", msg)
    return True, msg


def config_options_spec() -> list[dict]:
    """Parse the scalar add-on options from config.yaml (schema + defaults) and
    merge the current values from options.json. Drives the editable Settings
    form so it can never drift from HA's own config schema. `meters` (a nested
    list) is intentionally excluded — it has its own views. Secret fields
    (password) never expose their value; only whether one is set."""
    try:
        text = CONFIG_YAML_PATH.read_text(encoding="utf-8")
    except Exception:
        return []

    def _block(name: str) -> list[str]:
        out, inside = [], False
        for line in text.splitlines():
            if re.match(rf"^{name}:\s*$", line):
                inside = True
                continue
            if inside:
                if re.match(r"^\S", line):  # next top-level key ends the block
                    break
                out.append(line)
        return out

    # defaults from the options: block (used only when options.json lacks a key)
    defaults: dict[str, str] = {}
    for line in _block("options"):
        m = re.match(r"^  (\w+):\s*(\S.*)$", line)
        if m and m.group(1) != "meters":
            defaults[m.group(1)] = m.group(2).strip().strip('"')

    cur = read_options()
    cur = cur if isinstance(cur, dict) else {}

    specs: list[dict] = []
    for line in _block("schema"):
        # `  key: type` — meters: has no inline type (nested list) so it is skipped
        m = re.match(r"^  (\w+):\s*(\S.*)$", line)
        if not m:
            continue
        key, raw_type = m.group(1), m.group(2).strip()
        optional = raw_type.endswith("?")
        t = raw_type[:-1] if optional else raw_type
        spec: dict = {"key": key, "optional": optional, "secret": "password" in key}
        if t == "bool":
            spec["type"] = "bool"
        elif t == "int":
            spec["type"] = "int"
        elif t == "float":
            spec["type"] = "float"
        elif t.startswith("list(") and t.endswith(")"):
            spec["type"] = "enum"
            spec["choices"] = t[5:-1].split("|")
        else:
            spec["type"] = "str"

        if spec["secret"]:
            spec["secret_set"] = bool(str(cur.get(key, "") or ""))
            spec["value"] = ""
        else:
            spec["value"] = cur.get(key, defaults.get(key))
        specs.append(spec)
    return specs


def save_config_options(values: dict) -> tuple[bool, str]:
    """Validate edited scalar options against the schema and persist them to
    options.json via the Supervisor API (same Supervisor-first path as the meter
    edits). `meters` and any unknown keys are ignored; secret fields left blank
    keep their current value. Core options only take effect after a restart —
    the WebUI triggers that separately, exactly like the HA config tab."""
    import urllib.request

    options = read_json(OPTIONS_JSON)
    if not isinstance(options, dict):
        return False, "Cannot read options.json."

    spec_by_key = {s["key"]: s for s in config_options_spec()}
    for key, raw in values.items():
        s = spec_by_key.get(key)
        if s is None:  # unknown key or meters — never written from this form
            continue
        if s["secret"]:
            if raw is None or str(raw) == "":
                continue  # blank = keep current secret
            options[key] = str(raw)
            continue
        t = s["type"]
        if t == "bool":
            options[key] = str(raw).strip().lower() in ("true", "1", "on", "yes")
        elif t == "int":
            try:
                options[key] = int(str(raw).strip())
            except ValueError:
                return False, f"{key}: expected an integer."
        elif t == "float":
            try:
                options[key] = float(str(raw).strip().replace(",", "."))
            except ValueError:
                return False, f"{key}: expected a number."
        elif t == "enum":
            if str(raw) not in s.get("choices", []):
                return False, f"{key}: invalid value '{raw}'."
            options[key] = str(raw)
        else:
            options[key] = str(raw)

    token = os.environ.get("SUPERVISOR_TOKEN", "")
    if token:
        try:
            payload = json.dumps({"options": options}, ensure_ascii=False).encode("utf-8")
            req = urllib.request.Request(
                "http://supervisor/addons/self/options",
                data=payload,
                headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status in (200, 201):
                    write_json_atomic(OPTIONS_JSON, options)
                    msg = "Options saved. Restart the add-on to apply."
                    webui_add_event("ok", msg)
                    return True, msg
                body = resp.read().decode("utf-8", errors="replace")
                return False, f"Supervisor API HTTP {resp.status}: {body[:200]}"
        except Exception as exc:
            webui_add_event("error", f"Supervisor API save-config failed: {exc}")
            return False, f"Supervisor API failed: {exc}"

    # Fallback: file-only write (plain Docker / no SUPERVISOR_TOKEN).
    write_json_atomic(OPTIONS_JSON, options)
    msg = "Options saved (file only — no SUPERVISOR_TOKEN). Restart to apply."
    webui_add_event("warn", msg)
    return True, msg


# ============================================================
# Wired M-Bus: serial port discovery, identity, bus probe
# ============================================================
# Everything here was shaped by measurements on real hardware, and two
# comfortable assumptions died in the process:
#
#   1. "by-id is always safer than the raw path" — false. Two identical CH340
#      cables produce the SAME /dev/serial/by-id link; udev lists it for both
#      devices and only one symlink can exist, so the path is ambiguous rather
#      than stable. /dev/serial/by-path distinguishes them because it encodes
#      the physical USB socket.
#   2. "the USB interface class tells a port from a non-port" — false. A CP2102N
#      (SkyConnect), a PL2303 and a DVB-T tuner all report :ff0000: and only the
#      first two have a tty. The only reliable criterion is the existence of a
#      tty node, which is what the listing below is based on.
#
# Supervisor bind-mounts the host's whole /dev into every add-on unconditionally,
# so ports are visible even without `uart: true`. Visibility proves nothing;
# only opening the port the user picked does.

SERIAL_BY_ID = Path('/dev/serial/by-id')
SERIAL_BY_PATH = Path('/dev/serial/by-path')
SERIAL_GLOBS = ('/dev/ttyUSB*', '/dev/ttyACM*', '/dev/ttyAMA*', '/dev/ttyS*')

# Devices people genuinely mistake for an M-Bus converter. Matching is on
# VID:PID where the device has its own USB controller, and on the product
# string where it does not — a CP210x or CH340 VID:PID identifies the bridge
# chip, not the device behind it.
_KNOWN_NON_MBUS = {
    '0bda:2838': 'rtl_sdr', '0bda:2832': 'rtl_sdr',
    '0bda:2834': 'rtl_sdr', '0bda:2839': 'rtl_sdr',
    '048d:9135': 'dvbt_tuner',
    '303a:1001': 'esp_native_usb',
}
_KNOWN_NON_MBUS_PRODUCT = (
    ('espressif_usb_jtag', 'esp_native_usb'),
    ('skyconnect', 'zigbee_coordinator'),
    ('conbee', 'zigbee_coordinator'),
    ('sonoff_zigbee', 'zigbee_coordinator'),
    ('im871a', 'wmbus_radio'), ('amb8465', 'wmbus_radio'),
    ('iu891a', 'wmbus_radio'), ('rc1180', 'wmbus_radio'),
)


def _sysfs_usb_ids(node: str) -> tuple[str, str]:
    """Walk up from /sys/class/tty/<node> until idVendor/idProduct appear."""
    base = Path('/sys/class/tty') / node / 'device'
    try:
        cur = base.resolve()
    except OSError:
        return '', ''
    for _ in range(6):
        vid = cur / 'idVendor'
        pid = cur / 'idProduct'
        if vid.is_file() and pid.is_file():
            try:
                return vid.read_text().strip(), pid.read_text().strip()
            except OSError:
                return '', ''
        if cur.parent == cur:
            break
        cur = cur.parent
    return '', ''


def _links_for(real: str, directory: Path) -> list[str]:
    if not directory.is_dir():
        return []
    out = []
    try:
        for link in sorted(directory.iterdir()):
            try:
                if os.path.realpath(link) == real:
                    out.append(str(link))
            except OSError:
                continue
    except OSError:
        return []
    return out


def _classify_device(by_id: str, vid: str, pid: str) -> str:
    if vid and pid:
        hit = _KNOWN_NON_MBUS.get(f'{vid.lower()}:{pid.lower()}')
        if hit:
            return hit
    low = (by_id or '').lower()
    for needle, kind in _KNOWN_NON_MBUS_PRODUCT:
        if needle in low:
            return kind
    return ''


def list_serial_devices() -> list[dict]:
    """Enumerate serial ports. Never opens anything.

    Probing is not an option: detectMBUS in wmbusmeters only opens the device
    and declares success, and on a typical HA box /dev/ttyUSB0 is a Zigbee
    coordinator — talking M-Bus into it breaks somebody's network.
    """
    devices: list[dict] = []
    for pattern in SERIAL_GLOBS:
        for path in sorted(glob.glob(pattern)):
            try:
                real = os.path.realpath(path)
            except OSError:
                continue
            node = real.rsplit('/', 1)[-1]
            by_id_links = _links_for(real, SERIAL_BY_ID)
            by_path_links = _links_for(real, SERIAL_BY_PATH)
            vid, pid = _sysfs_usb_ids(node)
            by_id = by_id_links[0] if by_id_links else ''
            devices.append({
                'dev_path': path,
                'by_id': by_id,
                'by_path': by_path_links[0] if by_path_links else '',
                'vid_pid': f'{vid}:{pid}' if vid and pid else '',
                'serial': _tty_serial(node),
                'warning': _classify_device(by_id, vid, pid),
                # Motherboard serial ports have no USB identity and no by-id.
                # They are legitimate M-Bus candidates (an RS-232 converter
                # plugs straight into one), so they are listed — but the picker
                # should rank them below USB devices instead of hiding them.
                'kind': 'usb' if (vid and pid) else 'onboard',
            })

    # A by-id string claimed by more than one device is worse than no by-id:
    # it looks like a stable identifier and is not.
    counts: dict[str, int] = {}
    for dev in devices:
        if dev['by_id']:
            counts[dev['by_id']] = counts.get(dev['by_id'], 0) + 1
    for dev in devices:
        dev['by_id_ambiguous'] = bool(dev['by_id']) and counts[dev['by_id']] > 1
        dev['path'], dev['path_reason'] = _stable_path_for(dev)
    return devices


def _stable_path_for(dev: dict) -> tuple[str, str]:
    if dev['by_id'] and not dev['by_id_ambiguous']:
        return dev['by_id'], 'by_id_unique'
    if dev['by_path']:
        return dev['by_path'], 'by_id_ambiguous' if dev['by_id'] else 'no_serial'
    return dev['dev_path'], 'unstable_only'


def _tty_serial(node: str) -> str:
    base = Path('/sys/class/tty') / node / 'device'
    try:
        cur = base.resolve()
    except OSError:
        return ''
    for _ in range(6):
        candidate = cur / 'serial'
        if candidate.is_file():
            try:
                return candidate.read_text().strip()
            except OSError:
                return ''
        if cur.parent == cur:
            break
        cur = cur.parent
    return ''


def mbus_access_state(configured: str | None) -> dict:
    """Visibility is not access — see the section header."""
    state_out = {
        'any_port_listed': bool(list_serial_devices()),
        'by_id_available': SERIAL_BY_ID.is_dir(),
        'mode': 'addon' if os.environ.get('SUPERVISOR_TOKEN') else 'docker',
        'openable': None,
    }
    if not configured:
        return state_out
    if not os.path.exists(configured):
        state_out['openable'] = 'device_missing'
        return state_out
    try:
        fd = os.open(configured, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        os.close(fd)
        state_out['openable'] = 'ok'
    except PermissionError:
        state_out['openable'] = 'denied'
    except OSError:
        state_out['openable'] = 'busy_or_error'
    return state_out


def mbus_probe_bus(device: str, baudrate: int = 2400, wait_s: float = 2.0) -> tuple[str, str]:
    """Send SND_NKE to the test broadcast 0xFE and report whether anything answers.

    0xFE is the broadcast every meter replies to (0xFF, used by the decoder's
    own deviceReset, expects no reply at all). One request replaces scanning
    250 addresses, which at multi-second poll intervals takes hours.

    With more than one meter the replies overlap electrically and come back
    damaged — that is NOT a fault, it is what 0xFE does, and the UI has to say
    so or a healthy bus reads as broken.

    Returns (state, hex_of_reply). SND_NKE is used rather than REQ_UD2 because
    the answer is a single byte instead of 62 — less traffic on somebody's bus.
    """
    if termios is None:
        # Only reachable on a non-POSIX machine, i.e. never in the add-on or in
        # the Docker image. Reported rather than raised so the rest of the tab
        # keeps working while a maintainer runs this file locally.
        return 'busy_or_error', ''
    if not device or not os.path.exists(device):
        return 'device_missing', ''
    frame = bytes([0x10, 0x40, 0xFE, 0x3E, 0x16])  # CS = (0x40 + 0xFE) & 0xFF
    try:
        fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except PermissionError:
        return 'denied', ''
    except OSError:
        return 'busy_or_error', ''
    try:
        _set_serial_8e1(fd, baudrate)
        try:
            while os.read(fd, 4096):
                pass
        except OSError:
            pass
        os.write(fd, frame)
        deadline = time.monotonic() + wait_s
        received = b''
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(fd, 4096)
                except OSError:
                    break
                if chunk:
                    received += chunk
        if not received:
            return 'bus_silent', ''
        if received[:1] == b'\xE5' or received[:1] == b'\x68' or received[:1] == b'\x10':
            return 'bus_alive_clean', received.hex()
        return 'bus_alive_garbled', received.hex()
    finally:
        os.close(fd)


def _set_serial_8e1(fd: int, baudrate: int) -> None:
    """2400 8E1 — even parity is what the decoder forces for the mbus device
    type (createSerialDeviceTTY(..., PARITY::EVEN, "mbus"))."""
    speeds = {300: termios.B300, 600: termios.B600, 1200: termios.B1200,
              2400: termios.B2400, 4800: termios.B4800, 9600: termios.B9600}
    speed = speeds.get(int(baudrate), termios.B2400)
    attrs = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    cflag = (cflag & ~termios.CSIZE) | termios.CS8
    cflag |= termios.PARENB
    cflag &= ~termios.PARODD
    cflag &= ~termios.CSTOPB
    cflag &= ~termios.CRTSCTS
    cflag |= (termios.CLOCAL | termios.CREAD)
    # HUPCL off: on boards with an auto-reset circuit, dropping DTR on close
    # reboots the device and its ROM loader then spits bytes at 74880 baud into
    # what we are about to read as 2400.
    cflag &= ~termios.HUPCL
    iflag = 0
    oflag = 0
    lflag = 0
    cc = list(cc)
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW,
                      [iflag, oflag, cflag, lflag, speed, speed, cc])
    termios.tcflush(fd, termios.TCIOFLUSH)


def mbus_panel_payload() -> dict:
    """Everything the M-Bus tab needs in one call."""
    opts = read_options()
    opts = opts if isinstance(opts, dict) else {}
    configured = str(opts.get('mbus_device') or '')
    return {
        'tab_visible': bool(opts.get('mbus_tab_visible')),
        'enabled': bool(opts.get('mbus_enabled')),
        'device': configured,
        'device_serial': str(opts.get('mbus_device_serial') or ''),
        'bus_alias': str(opts.get('mbus_bus_alias') or 'MAIN'),
        'baudrate': str(opts.get('mbus_baudrate') or '2400'),
        'poll_interval': str(opts.get('mbus_poll_interval') or '15m'),
        'donotprobe_all': bool(opts.get('mbus_donotprobe_all', True)),
        'loglevel': str(opts.get('mbus_loglevel') or 'normal'),
        'logtelegrams': bool(opts.get('mbus_logtelegrams')),
        'ignoreduplicates': bool(opts.get('mbus_ignoreduplicates')),
        'meters': opts.get('mbus_meters') or [],
        'devices': list_serial_devices(),
        'access': mbus_access_state(configured or None),
        'runtime': mbus_runtime_state(),
    }


def mbus_transmit_allowed() -> tuple[bool, str]:
    """Guard for every action that puts bytes on the bus.

    M-Bus has one master. While the engine polls it owns that role, and a second
    transmitter overlapping its frames produces exactly the checksum errors the
    tab reports as a fault. Opening the tty a second time does not fail - POSIX
    grants it - so nothing except this check stands between the two.
    """
    opts = read_options()
    opts = opts if isinstance(opts, dict) else {}
    if opts.get('mbus_enabled'):
        return False, ("Polling is running and it is the bus master. Turn it off "
                       "and restart the add-on before transmitting from here, or "
                       "the two will talk over each other.")
    # Saving mbus_enabled=false changes options.json immediately, but the wired
    # decoder is a long-lived bridge child and only stops on add-on/container
    # restart. Do not mistake the newly saved option for the actual process
    # state: status remains non-disabled until the restarted bridge writes the
    # disabled transition.
    runtime_state = mbus_runtime_state().get('state', 'unknown')
    if runtime_state not in ('unknown', 'disabled'):
        return False, ("Polling was disabled in the settings, but the previous "
                       "bus-master process may still be running. Restart the add-on "
                       "before transmitting from here.")
    return True, ""


# One address at a time, with a cap: the reply window cannot be skipped, so a
# full 1..250 sweep would hold an HTTP request for minutes. The UI walks the
# range in chunks and says how far it got - a silently truncated scan would read
# as "there is nothing else on this bus".
MBUS_SCAN_MAX = 32


def mbus_scan_range(first: int, last: int) -> tuple[int, int]:
    """Clamp, order and cap a requested primary-address range."""
    first = max(1, min(250, first))
    last = max(1, min(250, last))
    if last < first:
        first, last = last, first
    return first, min(last, first + MBUS_SCAN_MAX - 1)


def _mbus_read_until_idle(fd: int, wait_s: float, idle_s: float = 0.2) -> bytes:
    """Read one reply, retaining concatenated/colliding frames until the bus is idle."""
    deadline = time.monotonic() + wait_s
    last_byte = None
    received = b''
    while time.monotonic() < deadline:
        if received and last_byte is not None and time.monotonic() - last_byte >= idle_s:
            break
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if chunk:
            received += chunk
            last_byte = time.monotonic()
    return received


def mbus_reply_diagnostic(hex_text: str) -> str:
    """Classify a diagnostic reply, including checksum and multiple-frame faults."""
    try:
        raw = bytes.fromhex(hex_text or '')
    except ValueError:
        return 'not_mbus'
    shape = mbus_frame_shape(hex_text)
    if shape != 'frame_long':
        return 'no_reply' if shape == 'empty' else shape
    expected = raw[1] + 6
    if len(raw) > expected:
        return 'multiple'
    if len(raw) != expected or raw[-1:] != b'\x16':
        return 'incomplete'
    if (sum(raw[4:-2]) & 0xFF) != raw[-2]:
        return 'checksum'
    return 'frame_long'


def mbus_scan_addresses(device: str, first: int, last: int, baudrate: int = 2400,
                        wait_s: float = 0.4, data_wait_s: float = 3.5) -> tuple[str, list]:
    """Check presence and immediately request data from every primary address.

    Valid primaries are 1..250. 0 is the factory "unset" value and is not part
    of a normal address sweep; 251..255 are reserved or broadcast and are never
    scanned.

    Returns one row for every scanned address. SND_NKE supplies the independent
    presence result; addresses that acknowledge are then sent REQ_UD2 so the UI
    can show the telegram diagnosis without nine separate button presses.
    """
    if termios is None:
        return 'busy_or_error', []
    if not device or not os.path.exists(device):
        return 'device_missing', []
    first, last = mbus_scan_range(first, last)
    try:
        fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except PermissionError:
        return 'denied', []
    except OSError:
        return 'busy_or_error', []
    results = []
    try:
        _set_serial_8e1(fd, baudrate)
        for addr in range(first, last + 1):
            try:
                while os.read(fd, 4096):
                    pass
            except OSError:
                pass
            # SND_NKE: start 0x10, C=0x40, A=addr, checksum, stop 0x16.
            os.write(fd, bytes([0x10, 0x40, addr, (0x40 + addr) & 0xFF, 0x16]))
            presence = _mbus_read_until_idle(fd, wait_s)
            answered = bool(presence)
            row = {'address': addr, 'answered': answered,
                   'presence_hex': presence.hex(), 'data_state': 'not_requested',
                   'hex': ''}
            if answered:
                # REQ_UD2: request user data. The long window also covers slow
                # meters; reading stops 200 ms after the reply becomes idle.
                os.write(fd, bytes([0x10, 0x5B, addr,
                                    (0x5B + addr) & 0xFF, 0x16]))
                data = _mbus_read_until_idle(fd, data_wait_s)
                row['hex'] = data.hex()
                row['data_state'] = mbus_reply_diagnostic(row['hex'])
            results.append(row)
    finally:
        os.close(fd)
    return 'ok', results


def mbus_poll_once(device: str, address: int, baudrate: int = 2400,
                   wait_s: float = 3.5) -> tuple[str, str]:
    """Ask one address for its data once and return the raw reply as hex.

    REQ_UD2 rather than SND_NKE: the point is to see whether a real telegram
    comes back and what it looks like. Nothing here decodes it - that is the
    decoder's job, and duplicating it would mean a second implementation of the
    thing this project exists not to reimplement.
    """
    if not 1 <= address <= 250:
        return 'bad_address', ''
    if termios is None:
        return 'busy_or_error', ''
    if not device or not os.path.exists(device):
        return 'device_missing', ''
    try:
        fd = os.open(device, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    except PermissionError:
        return 'denied', ''
    except OSError:
        return 'busy_or_error', ''
    try:
        _set_serial_8e1(fd, baudrate)
        try:
            while os.read(fd, 4096):
                pass
        except OSError:
            pass
        # REQ_UD2: C=0x5B (request user data, FCB set).
        os.write(fd, bytes([0x10, 0x5B, address, (0x5B + address) & 0xFF, 0x16]))
        # Match the diagnostic scan: allow a slow meter to start replying, but
        # return promptly once an ordinary response has left the bus idle.
        received = _mbus_read_until_idle(fd, wait_s)
        if not received:
            return 'no_reply', ''
        return mbus_reply_diagnostic(received.hex()), received.hex()
    finally:
        os.close(fd)


def mbus_frame_shape(hex_text: str) -> str:
    """Classify a reply by the shape of its first bytes, nothing more.

    This is the whole DLMS defence and it is deliberately shallow: a long frame
    starts 0x68 LL LL 0x68, a short frame 0x10, a bare acknowledgement is 0xE5.
    Bytes that match none of those are not M-Bus, and saying so costs one line
    where the alternative is a support thread about an open port with no
    entities. It does not attempt to say what the traffic *is* - an electricity
    meter speaking DLMS/COSEM is a guess offered to the reader, not a verdict.
    """
    raw = (hex_text or '').strip().lower()
    if not raw:
        return 'empty'
    if raw.startswith('e5'):
        return 'ack'
    if raw.startswith('10'):
        return 'frame_short'
    if raw.startswith('68') and len(raw) >= 8 and raw[2:4] == raw[4:6] and raw[6:8] == '68':
        return 'frame_long'
    return 'not_mbus'


# Line kinds the console marks up. The three failure signatures are the
# decoder's own words - they exist nowhere else, least of all in the JSON.
MBUS_CONSOLE_MARKERS = (
    ('no 0x68 byte found', 'not_mbus'),
    ('expected checksum', 'checksum'),
    ('did not send a response', 'no_reply'),
    ('SpecifiedDeviceNotFound', 'bus_down'),
    ('no bus specified for meter', 'bus_down'),
)


def mbus_console_lines(limit: int = 200) -> list:
    """Tail the M-Bus instance log, classified, read-only.

    Read-only on purpose. A writable terminal would mean sending arbitrary bytes
    into somebody's metering hardware - the same class of risk as shell hooks,
    which is the single deliberate exception this project makes to passing
    upstream through. Watching is enough to tell a silent address from a wrong
    protocol; the two bounded actions that do transmit (scan, poll once) are
    separate, explicit and refuse to run while the engine holds the bus.
    """
    path = BASE / "mbus" / "console.log"
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    out = []
    for line in lines[-max(1, min(1000, limit)):]:
        kind = 'info'
        for needle, name in MBUS_CONSOLE_MARKERS:
            if needle in line:
                kind = name
                break
        else:
            if line.lstrip().startswith('{') and '"_":"telegram"' in line.replace(' ', ''):
                kind = 'telegram'
        # --logtelegrams writes the raw frame as telegram=|<hex>| and this is
        # the only place it ever appears: the decoder's shell hooks get the
        # JSON, the id and the name, never the bytes.
        shape = ''
        marker = 'telegram=|'
        if marker in line:
            tail = line.split(marker, 1)[1]
            hex_text = tail.split('|', 1)[0].replace('_', '')
            shape = mbus_frame_shape(hex_text)
            kind = 'frame'
        out.append({'text': line[:400], 'kind': kind, 'shape': shape})
    return out


def mbus_runtime_state() -> dict:
    """Traffic-side state, as last written by the bridge.

    Deliberately not merged with access: the two answer different questions and
    a stale runtime state must never be able to override a live open() result.
    A missing file is the normal state before the engine has ever run, and is
    reported as such rather than as an error.
    """
    raw = read_json(STATUS_MBUS_JSON)
    if not isinstance(raw, dict) or not raw.get('state'):
        return {'state': 'unknown', 'meters': {}}
    meters = raw.get('meters')
    return {
        'state': str(raw.get('state') or 'unknown'),
        'bus_alias': str(raw.get('bus_alias') or ''),
        'meters_configured': int(raw.get('meters_configured') or 0),
        'meters_skipped': int(raw.get('meters_skipped') or 0),
        'updated': int(raw.get('updated') or 0),
        'meters': meters if isinstance(meters, dict) else {},
    }


def save_options_patch(patch: dict) -> tuple[bool, str]:
    """Merge `patch` into options.json — Supervisor first, file as fallback.

    Same order as every other write in this file: Supervisor is the owner of
    options.json under HA, and writing the file alone would be silently
    overwritten on the next Supervisor save.
    """
    options = read_options()
    options = options if isinstance(options, dict) else {}
    options.update(patch)

    token = os.environ.get("SUPERVISOR_TOKEN", "")
    if token:
        try:
            payload = json.dumps({"options": options}, ensure_ascii=False).encode("utf-8")
            req = urllib.request.Request(
                "http://supervisor/addons/self/options",
                data=payload,
                headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status in (200, 201):
                    write_json_atomic(OPTIONS_JSON, options)
                    return True, "Saved. Restart the add-on to apply."
                body = resp.read().decode("utf-8", errors="replace")
                return False, f"Supervisor API HTTP {resp.status}: {body[:200]}"
        except Exception as exc:
            webui_add_event("error", f"Supervisor API M-Bus save failed: {exc}")
            return False, f"Supervisor API failed: {exc}"

    write_json_atomic(OPTIONS_JSON, options)
    return True, "Saved (file only — no SUPERVISOR_TOKEN). Restart to apply."


def mbus_save_device(device: str, alias: str, baudrate: str, poll_interval: str,
                     donotprobe: bool, enabled: bool | None = None) -> tuple[bool, str]:
    """Store the picked port together with its serial number.

    Pinning the serial is what stops the add-on from politely polling whatever
    ends up on that /dev node next — measured: ttyACM0 pointed at a different
    board minutes after a replug, and every health check still read "ok".
    """
    if device and not os.path.exists(device):
        return False, f"{device}: no such device."
    if alias and not re.fullmatch(r'[A-Za-z0-9_]+', alias):
        return False, "Bus alias must be [A-Za-z0-9_]."
    if baudrate not in ('300', '600', '1200', '2400', '4800', '9600'):
        return False, f"Unsupported baud rate '{baudrate}'."
    if not re.fullmatch(r'\d+[smh]', poll_interval or ''):
        return False, "Poll interval must look like 15m, 30s or 1h."

    serial = ''
    if device:
        node = os.path.realpath(device).rsplit('/', 1)[-1]
        serial = _tty_serial(node)
    patch = {
        'mbus_device': device,
        'mbus_device_serial': serial,   # empty for CH340/PL2303 — no serial exists
        'mbus_bus_alias': alias or 'MAIN',
        'mbus_baudrate': baudrate,
        'mbus_poll_interval': poll_interval,
        'mbus_donotprobe_all': bool(donotprobe),
    }
    if enabled is not None:
        # Refuse to arm the engine without a port: it would start, find nothing
        # and log a failure the user cannot act on.
        if enabled and not device:
            return False, "Pick a port before enabling polling."
        patch['mbus_enabled'] = bool(enabled)
    return save_options_patch(patch)


def mbus_save_meters(meters: list) -> tuple[bool, str]:
    cleaned = []
    for entry in meters:
        if not isinstance(entry, dict):
            continue
        name = str(entry.get('id') or '').strip()
        address = str(entry.get('address') or '').strip()
        if not name:
            return False, "Every meter needs a name."
        # p1..p250 (0 is the factory 'unset' value, 0xFB-0xFF are reserved or
        # broadcast) or an 8-hex secondary address.
        if not (re.fullmatch(r'p([1-9]|[1-9]\d|1\d\d|2[0-4]\d|250)', address)
                or re.fullmatch(r'[0-9A-Fa-f]{8}', address)):
            return False, f"{name}: address must be p1..p250 or 8 hex characters."
        key = str(entry.get('key') or '').strip()
        if key and not re.fullmatch(r'[0-9A-Fa-f]{32}', key):
            return False, f"{name}: key must be 32 hex characters."
        poll = str(entry.get('poll_interval') or '').strip()
        if poll and not re.fullmatch(r'\d+[smh]', poll):
            return False, f"{name}: poll interval must look like 15m."
        cleaned.append({k: v for k, v in {
            'id': name,
            'address': address,
            'type': str(entry.get('type') or 'auto').strip(),
            'type_other': str(entry.get('type_other') or '').strip() or None,
            'key': key or None,
            'poll_interval': poll or None,
            'calculated_fields': str(entry.get('calculated_fields') or '').strip() or None,
            'static_fields': str(entry.get('static_fields') or '').strip() or None,
        }.items() if v is not None})
    return save_options_patch({'mbus_meters': cleaned})


def restart_addon_via_supervisor() -> tuple[bool, str]:
    """Restart the whole addon via HA Supervisor API.

    Requires hassio_api: true in config.yaml.
    SUPERVISOR_TOKEN is injected by HA into the addon environment.
    NOTE: this call kills the current process — the HTTP response may
    not reach the browser. HA Ingress will show a brief "not ready" dialog
    which is normal — click Retry/Ponów after a few seconds.
    """
    import urllib.request
    token = os.environ.get("SUPERVISOR_TOKEN", "")
    if not token:
        # Docker standalone: no Supervisor. PID 1 is docker-entrypoint.sh,
        # which traps SIGTERM and exits — the container stops and comes back
        # under a restart policy (docker/examples compose: unless-stopped).
        # Without a restart policy this degrades to a container stop, which
        # the README documents. The kill is delayed so this HTTP response
        # still reaches the browser before the WebUI dies with the container.
        import signal
        import threading

        def _kill_pid1() -> None:
            try:
                os.kill(1, signal.SIGTERM)
            except OSError:
                pass

        msg = ("Container restart requested (SIGTERM to PID 1) — it comes back "
               "only under a Docker restart policy (compose example: "
               "restart: unless-stopped).")
        webui_add_event("ok", msg)
        threading.Timer(1.0, _kill_pid1).start()
        return True, msg
    try:
        req = urllib.request.Request(
            "http://supervisor/addons/self/restart",
            data=b"{}",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            msg = f"Addon restart requested via Supervisor API (HTTP {resp.status})."
            webui_add_event("ok", msg)
            return True, msg
    except Exception as exc:
        msg = f"Supervisor API restart failed: {exc}"
        webui_add_event("error", msg)
        return False, msg


def parse_iso_time(value: str) -> datetime | None:
    try:
        if not value:
            return None
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None


# ── REMOVED: discover_stability() — dead code (never called).
# ── REMOVED: event_level_for_ui() — ported to app.js as eventLevelForUi().


def _sync_meters_tsv(valid_ids: set[str]) -> None:
    """Rewrite status_meters.tsv keeping only rows whose id is in valid_ids.

    This must not be called from read-only state assembly: if Supervisor briefly
    exposes default/empty options, a page refresh would erase live decoded values.
    """
    try:
        if not METERS_TSV.exists():
            return
        lines = METERS_TSV.read_text(encoding="utf-8", errors="replace").splitlines()
        new_lines = [l for l in lines if normalize_meter_id(l.split("\t")[0]) in valid_ids]
        if len(new_lines) != len(lines):
            write_lines_atomic(METERS_TSV, new_lines)
    except Exception:
        pass  # non-fatal


def mbus_source_map(runtime: dict) -> dict[str, str]:
    """Map frame IDs seen by the wired instance to their bus alias."""
    if not isinstance(runtime, dict):
        return {}
    meters = runtime.get("meters")
    if not isinstance(meters, dict):
        return {}
    alias = str(runtime.get("bus_alias") or "M-Bus")
    return {
        normalize_meter_id(v.get("id")): alias
        for v in meters.values()
        if isinstance(v, dict) and normalize_meter_id(v.get("id"))
    }


def state(include_ignored: bool = False) -> dict:
    status = read_json(STATUS_JSON)
    options = read_options()
    mbus_runtime = mbus_runtime_state()
    meters = read_tsv(
        METERS_TSV,
        ["id", "name", "driver", "media", "value_key", "value", "last_seen", "discovery", "seen_count", "avg_interval_s", "seen_15m", "seen_60m", "value_parts"],
    )
    # Attach the last full decoded JSON (string, parsed client-side) so the
    # meters view can expand a row into the list of published fields.
    last_json_rows = read_tsv(METER_LAST_JSON_TSV, ["id", "ts", "json"])
    last_json_by_id = {
        normalize_meter_id(r.get("id")): r
        for r in last_json_rows
        if normalize_meter_id(r.get("id"))
    }
    # AES key problems detected from wmbusmeters warnings — a wrong/missing
    # key makes wmbusmeters permanently ignore the meter until the next
    # pipeline reload, so without this the user only sees a silent "no data".
    key_problem_rows = read_tsv(METER_KEY_PROBLEM_TSV, ["id", "reason", "ts"])
    key_problem_by_id = {
        normalize_meter_id(r.get("id")): str(r.get("reason") or "")
        for r in key_problem_rows
        if normalize_meter_id(r.get("id"))
    }
    # Whether a meter has an AES key configured in options.json — feeds the
    # green/red lock badge under the meter id in the meters tables.
    _opts_for_keys = read_options()
    has_key_by_id = {}
    if isinstance(_opts_for_keys, dict):
        for _om in _opts_for_keys.get("meters") or []:
            if isinstance(_om, dict):
                _omid = normalize_meter_id(_om.get("meter_id"))
                if _omid:
                    has_key_by_id[_omid] = bool(str(_om.get("key") or "").strip())
    for m in meters:
        mid_norm = normalize_meter_id(m.get("id"))
        lj = last_json_by_id.get(mid_norm)
        if lj:
            m["last_json"] = lj.get("json", "")
            m["last_json_ts"] = lj.get("ts", "")
        if mid_norm in key_problem_by_id:
            m["key_problem"] = key_problem_by_id[mid_norm]
        if has_key_by_id.get(mid_norm):
            m["has_key"] = True
    candidates = read_tsv(
        CANDIDATES_TSV,
        ["id", "driver", "type", "last_seen", "seen_count", "avg_interval_s", "seen_15m", "seen_60m", "manufacturer"],
    )
    events = read_tsv(EVENTS_TSV, ["time", "level", "message"], limit=80, reverse=True)
    search_candidates = read_search_candidates()
    search_matches = read_search_matches()
    search_status = read_search_status()
    analysis = read_candidate_analysis()
    ignored = ignored_ids()
    # Preview values written by bridge.sh one-shot RAW decoders when a preview
    # config exists. Indexed by id for fast lookup below.
    preview_rows = read_tsv(
        STATUS_CANDIDATE_VALUES_FILE,
        ["id", "preview_value", "preview_value_key", "preview_ts"],
    )
    preview_by_id = {normalize_meter_id(r.get("id")): r for r in preview_rows if normalize_meter_id(r.get("id"))}
    preview_state_rows = read_tsv(
        STATUS_CANDIDATE_PREVIEW_STATE_FILE,
        ["id", "state", "ts", "note"],
    )
    preview_state_by_id = {normalize_meter_id(r.get("id")): r for r in preview_state_rows if normalize_meter_id(r.get("id"))}
    candidate_by_id = {
        normalize_meter_id(c.get("id")): c
        for c in candidates
        if normalize_meter_id(c.get("id"))
    }
    analysis_by_id = {
        normalize_meter_id(v.get("id") or k): v
        for k, v in analysis.items()
        if normalize_meter_id(v.get("id") or k)
    }
    # Meters the ESP is explicitly configured for (target + highlight), unioned
    # across fresh wmbus/<device>/meters entries. Used to badge matching
    # meters/candidates ("flagged on the ESP"). Stale entries (>150 s, mirrors the
    # health window) are ignored so a since-removed ESP's flags don't linger.
    import time as _time_esp
    esp_flagged_ids: set[str] = set()
    _esp_meters_raw = read_json(STATUS_ESP_METERS_JSON)
    if isinstance(_esp_meters_raw, dict):
        _esp_now = _time_esp.time()
        for _dev, _m in _esp_meters_raw.items():
            if not isinstance(_m, dict):
                continue
            if (_esp_now - safe_int(_m.get("_bridge_rx_epoch", 0))) > 150:
                continue
            _t = normalize_meter_id(_m.get("target"))
            if _t:
                esp_flagged_ids.add(_t)
            _hl = _m.get("highlight")
            if isinstance(_hl, list):
                for _h in _hl:
                    _hn = normalize_meter_id(_h)
                    if _hn:
                        esp_flagged_ids.add(_hn)

    # Per-meter reception % (#15) from the opt-in diag meter_snapshot. For each
    # fresh per-ESP snapshot, reception% = count_window / (elapsed_s/avg_interval_s),
    # capped at 100; take the BEST across ESPs (a meter reads well if any receiver
    # gets it well). -1 (absent) when there is no usable data — diagnostics off, no
    # highlight_meters, stale, or the window is shorter than one interval.
    reception_by_id: dict[str, int] = {}
    # Per-ESP breakdown: mid -> {esp_device: {"pct": int, "count": int}}. Lets the
    # UI show how each board behaves for the same meter (architectural differences
    # and how many telegrams each receiver actually read), not just the best
    # aggregate. Scales to N receivers.
    reception_by_esp: dict[str, dict[str, dict]] = {}
    _snap_raw = read_json(STATUS_ESP_METER_SNAPSHOT_JSON)
    if isinstance(_snap_raw, dict):
        _rx_now = _time_esp.time()
        for _sdev, _snap in _snap_raw.items():
            if not isinstance(_snap, dict):
                continue
            # ~20 min freshness (snapshot fires every 15 min).
            if (_rx_now - safe_int(_snap.get("_bridge_rx_epoch", 0))) > 1200:
                continue
            _elapsed = safe_int(_snap.get("elapsed_s", 0))
            _mlist = _snap.get("meters")
            if _elapsed <= 0 or not isinstance(_mlist, list):
                continue
            for _mw in _mlist:
                if not isinstance(_mw, dict):
                    continue
                _mid = normalize_meter_id(_mw.get("id"))
                _ai = safe_int(_mw.get("avg_interval_s", 0))
                if not _mid or _ai <= 0:
                    continue
                _expected = _elapsed / _ai
                if _expected < 1:   # window shorter than one interval → unreliable
                    continue
                _pct = int(round(min(100.0, (safe_int(_mw.get("count_window", 0)) / _expected) * 100.0)))
                _ct = safe_int(_mw.get("count_total", _mw.get("count_window", 0)))
                if _pct > reception_by_id.get(_mid, -1):
                    reception_by_id[_mid] = _pct
                _per = reception_by_esp.setdefault(_mid, {})
                _cur = _per.get(_sdev)
                if _cur is None or _ct >= _cur["count"]:
                    _per[_sdev] = {"pct": _pct, "count": _ct}

    # Per-meter reception windows (count-triggered, frequent). Same formula and
    # the same reception maps as the 15-min snapshot, merged with max() — this
    # makes the per-ESP % appear within minutes and for every ESP, instead of
    # only after a board's first 15-min summary. Map: dev -> {id -> fields}.
    _win_raw = read_json(STATUS_ESP_METER_WINDOW_JSON)
    if isinstance(_win_raw, dict):
        _rx_now_w = _time_esp.time()
        for _wdev, _wmeters in _win_raw.items():
            if not isinstance(_wmeters, dict):
                continue
            for _wmid_raw, _wrow in _wmeters.items():
                if not isinstance(_wrow, dict):
                    continue
                # ~30 min freshness: the count trigger cadence is 10*interval, so
                # a slow meter legitimately updates less often than the snapshot.
                if (_rx_now_w - safe_int(_wrow.get("_bridge_rx_epoch", 0))) > 1800:
                    continue
                _wmid = normalize_meter_id(_wrow.get("id") or _wmid_raw)
                _wai = safe_int(_wrow.get("avg_interval_s", 0))
                _welapsed = safe_int(_wrow.get("elapsed_s", 0))
                if not _wmid or _wai <= 0 or _welapsed <= 0:
                    continue
                _wexpected = _welapsed / _wai
                if _wexpected < 1:
                    continue
                _wpct = int(round(min(100.0, (safe_int(_wrow.get("count_window", 0)) / _wexpected) * 100.0)))
                _wct = safe_int(_wrow.get("count_total", _wrow.get("count_window", 0)))
                if _wpct > reception_by_id.get(_wmid, -1):
                    reception_by_id[_wmid] = _wpct
                _wper = reception_by_esp.setdefault(_wmid, {})
                _wcur = _wper.get(_wdev)
                if _wcur is None or _wct >= _wcur["count"]:
                    _wper[_wdev] = {"pct": _wpct, "count": _wct}

    # Prefer counts observed directly by this bridge from RAW_TOPIC. They share
    # one session start across all ESPs, unlike diagnostic count_total values
    # whose denominators reset independently with each board. Diagnostic
    # percentages remain only as a fallback for installations upgraded before
    # the first new RAW telegram arrives.
    _bridge_reception: dict[str, dict[str, dict]] = {}
    for _rrow in read_tsv(
        STATUS_ESP_METER_RECEPTION_FILE,
        ["id", "device", "first_seen", "last_seen", "count", "last_topic"],
    ):
        _rmid = normalize_meter_id(_rrow.get("id"))
        _rdev = str(_rrow.get("device") or "").strip()
        _rcount = safe_int(_rrow.get("count", 0))
        if not _rmid or not _rdev or _rcount <= 0:
            continue
        _bridge_reception.setdefault(_rmid, {})[_rdev] = {
            "pct": None,
            "count": _rcount,
            "first_seen": safe_int(_rrow.get("first_seen", 0)),
            "last_seen": safe_int(_rrow.get("last_seen", 0)),
            "count_source": "bridge_session",
        }
    for _rmid, _rper in _bridge_reception.items():
        reception_by_esp[_rmid] = _rper

    _esp_rx_sequence = {
        str(row.get("source") or ""): row
        for row in read_tsv(
            STATUS_ESP_RX_SEQUENCE_FILE,
            ["source", "boot_id", "last_seq", "missing", "out_of_order", "last_seen"],
        )
        if str(row.get("source") or "")
    }
    _esp_rx_reception: dict[str, dict[str, dict]] = {}
    for _rrow in read_tsv(
        STATUS_ESP_RX_RECEPTION_FILE,
        ["id", "device", "first_seen", "last_seen", "count", "last_topic"],
    ):
        _rmid = normalize_meter_id(_rrow.get("id"))
        _rdev = str(_rrow.get("device") or "").strip()
        _rcount = safe_int(_rrow.get("count", 0))
        if not _rmid or not _rdev or _rcount <= 0:
            continue
        _seq = _esp_rx_sequence.get(_rdev, {})
        _esp_rx_reception.setdefault(_rmid, {})[_rdev] = {
            "pct": None,
            "count": _rcount,
            "first_seen": safe_int(_rrow.get("first_seen", 0)),
            "last_seen": safe_int(_rrow.get("last_seen", 0)),
            "count_source": "esp_rx",
            "last_seq": safe_int(_seq.get("last_seq", 0)),
            "missing": safe_int(_seq.get("missing", 0)),
            "out_of_order": safe_int(_seq.get("out_of_order", 0)),
            "boot_id": str(_seq.get("boot_id") or ""),
        }
    for _rmid, _rper in _esp_rx_reception.items():
        reception_by_esp[_rmid] = _rper

    # wM-Bus band (T1/C1/S1) per meter, from two sources with different accuracy.
    #
    # EXACT — the ESP publishes the link mode it actually decoded the telegram
    # with, per meter, in both diag meter topics ("mode" field). That is a
    # property of the received frame. It exists only for meters listed in the
    # ESP's highlight_meters, because that is what those topics are gated on.
    #
    # APPROXIMATE — for every other meter, take the ESP device that delivered its
    # telegrams (status_esp_meter_device.tsv) and read that node's listen_mode
    # from the always-on health pulse. On a node running listen_mode t1/c1/s1
    # every frame it receives is by definition on that band, so the answer is
    # right; it is called approximate because it is inferred from the receiver's
    # configuration and not read out of the telegram. A node in "both" mode
    # yields no answer at all rather than a guess between T1 and C1.
    #
    # Exact always wins. band_source_by_id lets the UI say which one it showed.
    band_by_id: dict[str, str] = {}
    band_source_by_id: dict[str, str] = {}

    def _band_norm(v) -> str:
        _b = str(v or "").strip().upper()
        return _b if _b in ("T1", "C1", "S1") else ""

    # Exact, pass 1: per-meter windows (frequent).
    if isinstance(_win_raw, dict):
        for _bmeters in _win_raw.values():
            if not isinstance(_bmeters, dict):
                continue
            for _bid_raw, _brow in _bmeters.items():
                if not isinstance(_brow, dict):
                    continue
                _bmid = normalize_meter_id(_brow.get("id") or _bid_raw)
                _bmode = _band_norm(_brow.get("mode"))
                if _bmid and _bmode:
                    band_by_id[_bmid] = _bmode
                    band_source_by_id[_bmid] = "exact"

    # Exact, pass 2: the 15-min snapshot batch. Only fills gaps — a window entry
    # is newer, so it is not overwritten here.
    if isinstance(_snap_raw, dict):
        for _bsnap in _snap_raw.values():
            if not isinstance(_bsnap, dict):
                continue
            _blist = _bsnap.get("meters")
            if not isinstance(_blist, list):
                continue
            for _bm in _blist:
                if not isinstance(_bm, dict):
                    continue
                _bmid = normalize_meter_id(_bm.get("id"))
                _bmode = _band_norm(_bm.get("mode"))
                if _bmid and _bmode and _bmid not in band_by_id:
                    band_by_id[_bmid] = _bmode
                    band_source_by_id[_bmid] = "exact"

    # Approximate: meter -> device -> that device's listen_mode.
    _listen_by_dev: dict[str, str] = {}
    _health_for_band = read_json(STATUS_ESP_HEALTH_JSON)
    if isinstance(_health_for_band, dict):
        for _hdev, _hrow in _health_for_band.items():
            if not isinstance(_hrow, dict):
                continue
            # "T1 only" / "S1 only" / "T1+C1 (both, 3:1 bias)" -> first token.
            _lm = str(_hrow.get("listen_mode") or "").strip().upper()
            _lm_band = _band_norm(_lm.split()[0]) if _lm else ""
            # A node listening to more than one band cannot attribute a frame,
            # so it contributes nothing rather than a coin flip.
            if _lm_band and "+" not in _lm and "BOTH" not in _lm:
                _listen_by_dev[_hdev] = _lm_band
    if _listen_by_dev:
        for _arow in read_tsv(STATUS_ESP_METER_DEVICE_FILE, ["id", "device", "last_seen"]):
            _amid = normalize_meter_id(_arow.get("id"))
            _aband = _listen_by_dev.get(_arow.get("device", ""), "")
            if _amid and _aband and _amid not in band_by_id:
                band_by_id[_amid] = _aband
                band_source_by_id[_amid] = "listen_mode"

    def _rx_esps(mid: str) -> list:
        _per = reception_by_esp.get(mid)
        if not _per:
            return []
        # Sort most-reading first: by telegram count, then %, then name.
        return [{"esp": k, **v}
                for k, v in sorted(_per.items(),
                                   key=lambda kv: (-kv[1]["count"], kv[0]))]

    for c in candidates:
        c["ignored"] = "true" if c.get("id") in ignored else "false"
        c["analysis"] = analysis_by_id.get(normalize_meter_id(c.get("id")), {})
        c["esp_flagged"] = "true" if normalize_meter_id(c.get("id")) in esp_flagged_ids else "false"
        # Per-meter reception % (#15); -1 = no data (diag off / not highlighted / stale).
        c["reception_pct"] = reception_by_id.get(normalize_meter_id(c.get("id")), -1)
        c["reception_esps"] = _rx_esps(normalize_meter_id(c.get("id")))
        # wM-Bus band the telegrams arrived on; "" when nothing can say so.
        c["band"] = band_by_id.get(normalize_meter_id(c.get("id")), "")
        c["band_source"] = band_source_by_id.get(normalize_meter_id(c.get("id")), "")
        # preview_active = there's a preview config for this candidate.
        # Single source of truth = filesystem; one-shot RAW decoders consume the
        # config without touching the always-on LISTEN pipeline.
        cid = normalize_meter_id(c.get("id"))
        if cid:
            preview_file = PREVIEW_METER_DIR / f"meter-preview-{cid}"
            c["preview_active"] = "true" if preview_file.exists() else "false"
            pv = preview_by_id.get(cid)
            if pv:
                c["preview_value"]     = pv.get("preview_value", "")
                c["preview_value_key"] = pv.get("preview_value_key", "")
                c["preview_ts"]        = pv.get("preview_ts", "")
            ps = preview_state_by_id.get(cid)
            c["preview_state"] = ps.get("state", "") if ps else ""

    # Same ESP flag for configured meters: when both sides agree (ESP flags it and
    # it is in the add-on's meters), the badge confirms alignment.
    for m in meters:
        m["esp_flagged"] = "true" if normalize_meter_id(m.get("id") or m.get("meter_id")) in esp_flagged_ids else "false"
        m["reception_pct"] = reception_by_id.get(normalize_meter_id(m.get("id") or m.get("meter_id")), -1)
        m["reception_esps"] = _rx_esps(normalize_meter_id(m.get("id") or m.get("meter_id")))
        m["band"] = band_by_id.get(normalize_meter_id(m.get("id") or m.get("meter_id")), "")
        m["band_source"] = band_source_by_id.get(normalize_meter_id(m.get("id") or m.get("meter_id")), "")

    # A wired meter's frame id is learned only from its first valid reply.  The
    # M-Bus runtime file is therefore the authoritative link between a decoded
    # status row and the separate serial polling instance.
    mbus_source_by_id = mbus_source_map(mbus_runtime)
    for m in meters:
        mid = normalize_meter_id(m.get("id"))
        if mid in mbus_source_by_id:
            m["source"] = "mbus"
            m["source_label"] = mbus_source_by_id[mid]
            # Radio-only diagnostics must never be shown for a wired reading.
            m["esp_flagged"] = "false"
            m["reception_pct"] = -1
            m["reception_esps"] = []
            m["band"] = ""
            m["band_source"] = ""
        else:
            m["source"] = "radio"

    # Build normalized options_meter_ids early — used both for TSV filtering and
    # candidate dedup. Do not write back to status_meters.tsv from this read path.
    options_meters_list = options.get("meters") if isinstance(options, dict) and "meters" in options else None
    options_meters_valid = isinstance(options_meters_list, list)
    options_meter_ids = {
        normalize_meter_id(m.get("meter_id"))
        for m in (options_meters_list if options_meters_valid else [])
        if isinstance(m, dict) and normalize_meter_id(m.get("meter_id"))
    }

    # Filter in memory whenever options.json contains a valid meters list.
    # An empty list is a valid empty config; missing/invalid options keep the
    # cautious fallback and do not hide runtime rows automatically.
    if options_meters_valid:
        meters = [m for m in meters if normalize_meter_id(m.get("id")) in (options_meter_ids | set(mbus_source_by_id))]

    # Remove candidates that are already in configured meters (decoded)
    configured_ids = {normalize_meter_id(m.get("id")) for m in meters if normalize_meter_id(m.get("id"))}
    pending_meters: list[dict] = []
    if options_meters_valid:
        for opt in options_meters_list:
            if not isinstance(opt, dict):
                continue
            mid = normalize_meter_id(opt.get("meter_id"))
            if not mid or mid in configured_ids:
                continue
            opt_type = str(opt.get("type") or "auto")
            opt_type_other = str(opt.get("type_other") or "")
            candidate = candidate_by_id.get(mid, {})
            preview = preview_by_id.get(mid, {})
            preview_state = preview_state_by_id.get(mid, {})
            candidate_analysis = analysis_by_id.get(mid, {})
            driver = opt_type_other if opt_type == "other" and opt_type_other else opt_type
            if not driver or driver in ("unknown", "auto"):
                driver = candidate.get("driver") or driver or "auto"
            pending_meters.append({
                "meter_id": mid,
                "type": opt_type,
                "type_other": opt_type_other,
                "driver": driver,
                "has_key": bool(str(opt.get("key") or "").strip()),
                "key_problem": key_problem_by_id.get(mid, ""),
                "manufacturer": candidate.get("manufacturer", ""),
                "preview_value": preview.get("preview_value", ""),
                "preview_value_key": preview.get("preview_value_key", ""),
                "preview_state": preview_state.get("state", ""),
                "preview_ts": preview.get("preview_ts", "") or preview_state.get("ts", ""),
                "preview_active": "true" if (PREVIEW_METER_DIR / f"meter-preview-{mid}").exists() else "false",
                "encryption": candidate_analysis.get("encryption", ""),
                "analysis_note": candidate_analysis.get("note", ""),
                "last_seen": candidate.get("last_seen", ""),
                "seen_15m": candidate.get("seen_15m", ""),
                "seen_60m": candidate.get("seen_60m", ""),
                "avg_interval_s": candidate.get("avg_interval_s", ""),
            })
    candidates = [c for c in candidates if normalize_meter_id(c.get("id")) not in configured_ids]

    # Also remove candidates that are pending (in options.json but not yet decoded)
    # so the user doesn't see them twice (once in pending panel, once in candidate table)
    if options_meter_ids:
        candidates = [c for c in candidates if normalize_meter_id(c.get("id")) not in options_meter_ids]

    if not include_ignored:
        candidates = [c for c in candidates if c.get("ignored") != "true"]

    # Drop STALE candidates from the active list: a meter last heard long ago is
    # not "being heard" now, so listing it (and counting it) as a current
    # candidate is misleading — it was heard, in the past. Keep discovery to what
    # is actually arriving (honest-witness). Only hide when last_seen is
    # confidently older than the window; a missing/unparseable timestamp is kept.
    # status_candidates.tsv is NOT modified — this is a display freshness filter.
    CANDIDATE_STALE_AFTER_S = 24 * 60 * 60
    _now_utc = datetime.now(timezone.utc)
    def _candidate_fresh(c: dict) -> bool:
        dt = parse_iso_time(str(c.get("last_seen") or ""))
        if dt is None:
            return True
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return (_now_utc - dt).total_seconds() <= CANDIDATE_STALE_AFTER_S
    candidates = [c for c in candidates if _candidate_fresh(c)]

    meters = sorted(meters, key=lambda m: (m.get("last_seen") or ""), reverse=True)
    for m in meters:
        mid = normalize_meter_id(m.get("id") or "")
        if mid:
            m["preview_active"] = "true" if (PREVIEW_METER_DIR / f"meter-preview-{mid}").exists() else "false"
            if not m.get("manufacturer"):
                m["manufacturer"] = candidate_by_id.get(mid, {}).get("manufacturer", "")
    # Candidate order: STABLE, grouped by media, then "biggest chatterbox" first.
    # Primary = media group (water / warm water / heat / electricity / other) —
    # a meter's media never changes, so rows don't reshuffle. Secondary = total
    # telegrams (seen_count) descending — the chattiest candidate sits at the top
    # of its group; seen_count grows slowly so it does not reorder on every
    # refresh (no "elevator" effect, unlike last_seen/seen_15m). Tertiary = id,
    # a fully stable tie-break. NB ascending sort: group asc, -count for desc.
    def _media_group(c: dict) -> int:
        t = (str(c.get("type") or "") + " " + str(c.get("driver") or "")).lower()
        if "warm water" in t or "0x06" in t or "0x62" in t or "0x72" in t:
            return 1  # warm water
        if "heat" in t or "0xc3" in t:
            return 2  # heat
        if "electric" in t or "0x02" in t:
            return 3  # electricity
        if "water" in t or "0x07" in t or "0x16" in t:
            return 0  # (cold) water
        return 4      # other
    # "Silent" = no telegram in the last hour (seen_15m == seen_60m == 0). These
    # candidates (still inside the 24h freshness window, but currently quiet /
    # "decoding…") sink BELOW the actively-heard ones as their own block — they
    # are not part of the live "known" listing. Flag exposed so the table can draw
    # a divider before the block.
    #
    # IMPORTANT: age-adjust the stored counters exactly like app.js does before
    # display (seen15mAdj/seen60mAdj). status_candidates.tsv keeps the LAST known
    # positive seen_15m/seen_60m even after the meter goes quiet; without this the
    # backend sort would treat a long-silent candidate (UI shows 0/0) as active
    # and float it to the TOP of its group, contradicting the displayed 0/0.
    def _seen_age_s(c: dict):
        dt = parse_iso_time(str(c.get("last_seen") or ""))
        if dt is None:
            return None
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return (_now_utc - dt).total_seconds()

    def _silent(c: dict) -> int:
        age_s = _seen_age_s(c)
        seen_15m = safe_int(c.get("seen_15m")) if (age_s is None or age_s <= 15 * 60) else 0
        seen_60m = safe_int(c.get("seen_60m")) if (age_s is None or age_s <= 60 * 60) else 0
        return 0 if (seen_15m > 0 or seen_60m > 0) else 1
    for c in candidates:
        c["recent_silent"] = "true" if _silent(c) else "false"
    candidates = sorted(
        candidates,
        key=lambda c: (
            _silent(c),
            _media_group(c),
            -safe_int(c.get("seen_count")),
            normalize_meter_id(c.get("id")) or str(c.get("id") or ""),
        ),
    )
    return {"status": status, "options": options, "config_options": config_options_spec(), "meters": meters, "pending_meters": pending_meters, "candidates": candidates, "events": events, "ignored": sorted(ignored), "search_candidates": search_candidates, "search_matches": search_matches, "search_status": search_status, "analysis": analysis, "mbus": mbus_runtime}


def search_config_model(data: dict) -> dict:
    """Return search config with options.json as source of truth.

    status.json is runtime state and may lag right after form submission/restart.
    options.json is what the form just saved, so use it for form values.
    """
    status = data.get("status", {})
    cfg = status.get("config", {}) if isinstance(status.get("config"), dict) else {}
    options = data.get("options", {}) if isinstance(data.get("options"), dict) else {}

    def pick(name: str, default: object = "") -> object:
        if name in options and options.get(name) is not None:
            return options.get(name)
        return cfg.get(name, default)

    return {
        "search_mode": bool(pick("search_mode", False)),
        "search_expected_value_m3": str(pick("search_expected_value_m3", "0") or "0"),
        "search_tolerance_m3": str(pick("search_tolerance_m3", "0.05") or "0.05"),
    }


def status_model(data: dict) -> dict:
    status = data["status"]
    cfg = status.get("config", {}) if isinstance(status.get("config"), dict) else {}
    mqtt = status.get("mqtt", {}) if isinstance(status.get("mqtt"), dict) else {}
    pipe = status.get("pipeline", {}) if isinstance(status.get("pipeline"), dict) else {}
    meters = data["meters"]
    candidates = data["candidates"]
    raw_count = safe_int(pipe.get("raw_count"))
    decoded_count = safe_int(pipe.get("decoded_count"))
    candidate_count = len(candidates)
    decoded_meter_count = len(meters)
    options = data.get("options", {}) if isinstance(data.get("options"), dict) else {}
    options_meters = options.get("meters") if isinstance(options.get("meters"), list) else None
    configured_meter_ids = {
        normalize_meter_id(m.get("meter_id"))
        for m in (options_meters or [])
        if isinstance(m, dict) and normalize_meter_id(m.get("meter_id"))
    }
    wired_meter_ids = {
        normalize_meter_id(v.get("id"))
        for v in ((data.get("mbus") or {}).get("meters") or {}).values()
        if isinstance(v, dict) and normalize_meter_id(v.get("id"))
    }
    meter_count = len(configured_meter_ids | wired_meter_ids) if (configured_meter_ids or wired_meter_ids) else decoded_meter_count
    mqtt_ok = bool(mqtt.get("connected"))
    raw_ok = raw_count > 0
    wmbus_ok = bool(pipe.get("wmbusmeters_running")) or candidate_count > 0 or decoded_count > 0
    decoded_ok = decoded_count > 0
    discovery_ok = bool(pipe.get("discovery_published"))
    raw_15m = 0
    try:
        last_raw = pipe.get("last_raw_seen") or ""
        if last_raw:
            last_raw_dt = datetime.fromisoformat(last_raw.replace("Z", "+00:00"))
            age = datetime.now(timezone.utc) - last_raw_dt
            if age <= timedelta(minutes=15):
                raw_15m = raw_count
    except Exception:
        pass

    # MQTT->HA healthcheck: is a live HA MQTT integration present on the broker
    # the bridge uses? Inferred from HA's retained birth message
    # (homeassistant/status), recorded by bridge.sh. Silence on a non-native
    # broker likely means the bridge is on a different/foreign broker and HA
    # entities will never appear. Informational only — never a hard error, so
    # intentional external/bridged topologies are not falsely alarmed.
    ha_presence = "unknown"
    try:
        _ha_raw = STATUS_HA_PRESENCE_FILE.read_text(encoding="utf-8").strip()
        if _ha_raw:
            _ha_state = _ha_raw.split("\t", 1)[0].strip().lower()
            if _ha_state in ("online", "offline"):
                ha_presence = _ha_state
    except OSError:
        pass
    ha_present = ha_presence == "online"
    # A seen "online" birth confirms HA on this broker. Birth ABSENCE is NOT proof
    # of a foreign broker (HA birth is often not retained, so a subscriber that
    # starts after HA connected never sees it) — so it never alarms.
    # The native HA broker is an authoritative positive signal: when the add-on
    # talks to HA's own Supervisor-provided broker (host "core-mosquitto" or
    # mqtt_mode "ha"), the HA MQTT integration is present by definition — no
    # birth/Discovery timing needed.
    _mqtt_host = str(mqtt.get("host") or "").strip().lower()
    _mqtt_mode = str((options.get("mqtt_mode") if isinstance(options, dict) else "") or "auto").lower()
    ha_native_broker = _mqtt_host == "core-mosquitto" or _mqtt_mode == "ha"
    # HA entity verification (opt-in): the worker round-trips Discovery through
    # HA Core API and writes the result. "verified" is the strongest possible
    # signal — it bumps ha_link to "ok" regardless of birth/native priors;
    # "not_created" is the strongest negative — it overrides native/birth (HA may
    # be reachable on this broker but still not create entities, e.g. wrong
    # discovery_prefix or integration disabled). Other states do not change the
    # existing ha_link decision (it falls back to the inferred path).
    ha_verification = "unavailable"
    ha_verification_reason = ""
    try:
        _hv_raw = STATUS_HA_VERIFICATION_FILE.read_text(encoding="utf-8").strip()
        if _hv_raw:
            _hv_parts = _hv_raw.split("\t")
            _hv_state = _hv_parts[0].strip().lower()
            if _hv_state in ("verified", "not_created", "pending", "unavailable"):
                ha_verification = _hv_state
            if len(_hv_parts) > 2:
                ha_verification_reason = _hv_parts[2].strip()
    except OSError:
        pass

    if not mqtt_ok:
        ha_link = "mqtt_down"
    elif ha_verification == "verified":
        ha_link = "ok"
    elif ha_verification == "not_created":
        ha_link = "not_created"
    elif ha_present or ha_native_broker:
        ha_link = "ok"
    else:
        ha_link = "unknown"

    # Broker identity ($SYS), written by bridge.sh as brand<TAB>version.
    # broker_native reuses the HA-presence prior (the add-on uses HA's own
    # Supervisor-provided broker), so the MQTT tile can show e.g.
    # "Mosquitto 2.1.2 (native)" vs "EMQX 5.8.8 (other)".
    broker_brand = ""
    broker_version = ""
    broker_clients = ""
    try:
        _bk = STATUS_BROKER_INFO_FILE.read_text(encoding="utf-8").strip()
        if _bk:
            _parts = _bk.split("\t")
            broker_brand = _parts[0].strip()
            broker_version = _parts[1].strip() if len(_parts) > 1 else ""
            broker_clients = _parts[2].strip() if len(_parts) > 2 else ""
    except OSError:
        pass
    broker_native = bool(ha_native_broker)
    # TLS capability: the add-on does not support TLS connections yet. When the
    # configured port looks like MQTT-over-TLS (8883/8884) the user almost
    # certainly expects TLS, so the UI says so plainly instead of leaving a
    # silent connection failure unexplained.
    mqtt_tls_supported = False
    _mqtt_port = safe_int(mqtt.get("port"))
    mqtt_tls_intent = _mqtt_port in (8883, 8884)

    # Telegrams-per-minute: sum seen_60m across active sources.
    # Divide by actual elapsed minutes (capped at 60) instead of always 60 —
    # dividing by 60 when the bridge is young (e.g. 4 min uptime) produces an
    # inflated rate because stale TSV counters can hold values from the previous
    # listen session.
    #
    # In DECODE mode (meter_count > 0) the candidates TSV is NEVER updated by
    # bridge.sh (gated by OFFICIAL_METERS_COUNT == 0). Including stale candidate
    # seen_60m values in the sum causes badly inflated rates at startup.
    # In decode mode use only meters TSV (which IS kept current per telegram).
    # In LISTEN mode (no configured meters) use only candidates TSV.
    _meters_list     = data.get("meters", [])
    _candidates_list = data.get("candidates", [])
    _in_decode_mode  = meter_count > 0 or len(_meters_list) > 0
    if _in_decode_mode:
        total_60m = sum(safe_int(m.get("seen_60m")) for m in _meters_list)
    else:
        total_60m = sum(safe_int(c.get("seen_60m")) for c in _candidates_list)
    import time as _time
    bridge_start_epoch = 0
    try:
        bridge_start_epoch = int(STATUS_BRIDGE_START_FILE.read_text(encoding="utf-8").strip())
    except Exception:
        pass
    if bridge_start_epoch > 0:
        elapsed_min = min(60.0, max(1.0, (_time.time() - bridge_start_epoch) / 60.0))
    else:
        elapsed_min = 60.0
    raw_per_min = round(total_60m / elapsed_min, 1) if total_60m > 0 else 0.0

    # Per-minute live rate from bridge.sh (rotates every 60 s wall-clock).
    rate_1m = read_json(STATUS_RATE_1M_JSON)
    rate_current_min = safe_int(rate_1m.get("current_min", 0))
    rate_prev_min = safe_int(rate_1m.get("prev_min", 0))
    # Staleness check: if status_rate_1m.json epoch is >90 s old the bridge
    # may be idle — show 0 for current_min so the UI reflects reality.
    rate_epoch = safe_int(rate_1m.get("epoch", 0))
    if rate_epoch > 0 and (_time.time() - rate_epoch) > 90:
        rate_current_min = 0

    # Prefer ESP diagnostic summary when available and fresh.
    # bridge.sh subscribes to wmbus/+/diag/summary in background and writes
    # each payload to status_esp_diag.json with a _bridge_rx_epoch timestamp.
    # ESP publishes every 60 s; "total" = exact telegram count in that window —
    # the ground truth. Falls back to own counting when absent or stale.
    # Threshold is 150 s (2.5× the typical 60 s publish interval) so a single
    # delayed/missed publish does not immediately fall back to the bridge calc.
    rate_source = "bridge"
    current_raw_device, current_raw_topic, tracker_has_rows = _current_raw_esp_source()
    esp_diag = read_json(STATUS_ESP_DIAG_JSON)
    if _diag_matches_current_raw_source(esp_diag, current_raw_device, tracker_has_rows):
        esp_rx_epoch = safe_int(esp_diag.get("_bridge_rx_epoch", 0))
        if esp_rx_epoch > 0 and (_time.time() - esp_rx_epoch) <= 150:
            esp_total = safe_int(esp_diag.get("total", 0))
            rate_current_min = esp_total
            rate_source = "esp"
            # ESP total = exact count in the last 60-second window = telegrams/min.
            # Override raw_per_min so the session-average bar doesn't show an
            # inflated value from stale TSV counters / short elapsed_min at startup.
            raw_per_min = float(esp_total)

    # Pending restart: options.json is newer than the last full bridge start or
    # explicit soft pipeline reload requested by this UI. status.json is rewritten
    # constantly, so it is not a reliable "config applied" marker.
    pending_restart = False
    try:
        opts_mtime         = OPTIONS_JSON.stat().st_mtime
        bridge_start_mtime = STATUS_BRIDGE_START_FILE.stat().st_mtime
        reload_mtime = 0.0
        try:
            reload_mtime = STATUS_PIPELINE_RELOAD_FILE.stat().st_mtime
        except OSError:
            reload_mtime = 0.0
        applied_mtime = max(bridge_start_mtime, reload_mtime)
        pending_restart = opts_mtime > applied_mtime
    except OSError:
        pass

    # 15-minute rate history (sparkline) — read the rolling TSV written by
    # bridge.sh whenever a minute boundary is crossed. Each row is
    # epoch_minute<TAB>count. Returned as a list of {epoch_min, count} dicts;
    # the WebGUI renders them as a sparkline polyline.
    rate_history: list[dict] = []
    try:
        if STATUS_RATE_HISTORY_FILE.exists():
            for line in STATUS_RATE_HISTORY_FILE.read_text(encoding="utf-8", errors="replace").splitlines():
                if not line.strip():
                    continue
                parts = line.split("\t")
                if len(parts) >= 2:
                    rate_history.append({"epoch_min": safe_int(parts[0]), "count": safe_int(parts[1])})
    except OSError:
        pass

    # wmbusmeters version triplet (write-once at bridge start). Surface on the
    # wmbusmeters workspace panel so the user can tell which build is running.
    wmbusmeters_runtime = ""
    wmbusmeters_build_version = ""
    wmbusmeters_build_commit = ""
    try:
        _wv_raw = STATUS_WMBUSMETERS_VERSION_FILE.read_text(encoding="utf-8").strip()
        if _wv_raw:
            _wv_parts = _wv_raw.split("\t")
            wmbusmeters_runtime = _wv_parts[0].strip() if len(_wv_parts) > 0 else ""
            wmbusmeters_build_version = _wv_parts[1].strip() if len(_wv_parts) > 1 else ""
            wmbusmeters_build_commit = _wv_parts[2].strip() if len(_wv_parts) > 2 else ""
    except OSError:
        pass

    # Bridge liveness: bridge.sh stamps status_heartbeat.txt every few seconds
    # regardless of telegram flow. A stale heartbeat (or none) means the bridge is
    # down or run.sh is still waiting for the broker, so the whole snapshot is
    # stale and the WebUI must not present it as live truth.
    bridge_alive = False
    try:
        _hb = int(STATUS_HEARTBEAT_FILE.read_text(encoding="utf-8").strip())
        if _hb > 0 and (_time.time() - _hb) <= 30:
            bridge_alive = True
    except Exception:
        bridge_alive = False

    # Startup failure from run.sh (broker resolution FATAL — bridge.sh never
    # started). Only meaningful while the bridge is NOT alive: once bridge.sh
    # runs, the marker is stale by definition (run.sh clears it on success,
    # but guard anyway so a leftover file cannot shadow a live bridge).
    run_error = None
    if not bridge_alive:
        try:
            _re_raw = STATUS_RUN_ERROR_FILE.read_text(encoding="utf-8").strip()
            if _re_raw:
                _re_parts = _re_raw.split("\t")
                run_error = {
                    "code": _re_parts[0].strip(),
                    "detail": _re_parts[1].strip() if len(_re_parts) > 1 else "",
                }
        except OSError:
            run_error = None

    # Runtime broker failure (bridge alive, broker refusing) — no bridge_alive
    # gate on purpose: this marker exists precisely because the bridge keeps
    # running while the broker rejects it. bridge.sh clears the file on the
    # first successful publish or received telegram.
    broker_error = None
    try:
        _be_raw = STATUS_BROKER_ERROR_FILE.read_text(encoding="utf-8").strip()
        if _be_raw:
            _be_parts = _be_raw.split("\t")
            broker_error = {
                "code": _be_parts[0].strip(),
                "detail": _be_parts[1].strip() if len(_be_parts) > 1 else "",
            }
    except OSError:
        broker_error = None

    return {
        "status": status,
        "cfg": cfg,
        "mqtt": mqtt,
        "pipe": pipe,
        "raw_count": raw_count,
        "decoded_count": decoded_count,
        "candidate_count": candidate_count,
        "ignored_count": len(data.get("ignored", [])),
        "search_cached_count": len(data.get("search_candidates", [])),
        "search_match_count": len(data.get("search_matches", [])),
        "meter_count": meter_count,
        "decoded_meter_count": decoded_meter_count,
        "mqtt_ok": mqtt_ok,
        "raw_ok": raw_ok,
        "wmbus_ok": wmbus_ok,
        "decoded_ok": decoded_ok,
        "discovery_ok": discovery_ok,
        "ha_presence": ha_presence,
        "ha_link": ha_link,
        "ha_verification": ha_verification,
        "ha_verification_reason": ha_verification_reason,
        "broker_brand": broker_brand,
        "broker_version": broker_version,
        "broker_native": broker_native,
        "broker_clients": broker_clients,
        "mqtt_tls_supported": mqtt_tls_supported,
        "mqtt_tls_intent": mqtt_tls_intent,
        "raw_15m": raw_15m,
        "raw_per_min": raw_per_min,
        "rate_current_min": rate_current_min,
        "rate_prev_min": rate_prev_min,
        "rate_source": rate_source,
        "current_raw_esp_device": current_raw_device,
        "current_raw_esp_topic": current_raw_topic,
        "rate_history_15m": rate_history,
        "pending_restart": pending_restart,
        "bridge_alive": bridge_alive,
        "run_error": run_error,
        "broker_error": broker_error,
        "wmbusmeters_runtime": wmbusmeters_runtime,
        "wmbusmeters_build_version": wmbusmeters_build_version,
        "wmbusmeters_build_commit": wmbusmeters_build_commit,
    }


# ─────────────────────────────────────────────────────────────────────────
# REMOVED: legacy HTML page rendering (1505 lines)
#   • status_dot, mini_bar, link, nav, shell — HTML chrome helpers
#   • render_restart_block, render_pending_panel, render_pending_meter_card,
#     render_filter_links, render_system_status, render_stats, render_discovery,
#     _signal_bars, unit_from_key, render_meter_card, render_configured_meters,
#     render_search_cache_table, render_search_matches, render_candidates_table,
#     render_waiting_panel, render_candidate_summary, render_events — render funcs
#   • page_dashboard, page_meters, page_discover, page_search, page_candidate,
#     page_logs, page_esp_logs, page_settings, page_about — page builders
#   • render_esp_events, render_esp_diag_panel, render_esp_suggestion_panel,
#     render_esp_boot_panel — ESP-Logs HTML panels
#   • filter_by_media, pending_meters, _search_matches_cards, _fmt_epoch,
#     _esp_event_summary, _ESP_EVENT_COLORS, _ESP_EVENT_ICONS — render-only utils
#   • render_page — legacy dispatcher
#
# All replaced by the SPA in /usr/share/wmbus-webui/assets/app.js, which talks
# to the API endpoints in the Handler class below. The /api/app endpoint
# (served by frontend_payload) is the only thing the frontend needs from here.
# ─────────────────────────────────────────────────────────────────────────


# ── Diagnostics tab ──────────────────────────────────────────────────────────
#
# One row per ESP, answering the two questions a multi-board setup actually
# raises: which board is behaving differently, and has any of them been
# restarting behind my back.
#
# The restart half exists because of a real miss: on 2026-08-20/21 four boards
# rebooted every 15 minutes for a whole day and the only visible symptom was
# "reception looks a bit worse". The cause was an empty `api:` block, where
# ESPHome applies its default reboot_timeout of 15 minutes and restarts the
# device whenever no Native API client is connected. A restart also resets the
# sequence counters, so the event erases its own evidence unless it is recorded
# separately - which is what status_esp_rx_boots.tsv is for.

# Sequence gaps are only meaningful once there is enough sequence to judge.
ESP_DIAG_MIN_EVENTS = 500
# Fraction of expected events. Chosen so a handful of redeliveries cannot raise
# an alert on a board that has been running for hours.
ESP_DIAG_WARN_RATIO = 0.001
ESP_DIAG_ALARM_RATIO = 0.01
# A single hole this large is a different symptom from a trickle of losses:
# it means something was down, not that the network is lossy.
ESP_DIAG_ALARM_SINGLE_GAP = 100
# A board that has just booted has no useful statistics yet.
ESP_DIAG_BOOT_GRACE_S = 300
ESP_DIAG_REBOOT_WINDOW_S = 86400
ESP_DIAG_REBOOT_WARN = 1
ESP_DIAG_REBOOT_ALARM = 3
# ESPHome's api.reboot_timeout defaults to 15 minutes. Restarts clustered around
# that interval are the signature of an MQTT-only receiver with a bare `api:`.
ESP_DIAG_API_TIMEOUT_LO_S = 840
ESP_DIAG_API_TIMEOUT_HI_S = 960


def _esp_diag_boots() -> dict:
    """Boot history per source, newest last."""
    out: dict[str, list[dict]] = {}
    for row in read_tsv(
        STATUS_ESP_RX_BOOTS_FILE,
        ["source", "boot_id", "first_seen", "last_seen", "events"],
    ):
        src = str(row.get("source") or "").strip()
        if not src:
            continue
        out.setdefault(src, []).append({
            "boot_id": str(row.get("boot_id") or ""),
            "first_seen": safe_int(row.get("first_seen")),
            "last_seen": safe_int(row.get("last_seen")),
            "events": safe_int(row.get("events")),
        })
    for src in out:
        out[src].sort(key=lambda b: b["first_seen"])
    return out


def _esp_diag_reboot_view(boots: list[dict], now: int) -> dict:
    """Reboot count in the last 24 h plus the median interval between them."""
    starts = [b["first_seen"] for b in boots if b["first_seen"] > 0]
    starts.sort()
    recent = [t for t in starts if now - t <= ESP_DIAG_REBOOT_WINDOW_S]
    gaps = [b - a for a, b in zip(recent, recent[1:]) if b > a]
    median_gap = 0
    if gaps:
        gaps.sort()
        median_gap = gaps[len(gaps) // 2]
    # The first boot we ever saw is not a reboot - it is the board appearing.
    reboots = max(0, len(recent) - 1)
    looks_like_api_timeout = bool(
        reboots >= ESP_DIAG_REBOOT_ALARM
        and ESP_DIAG_API_TIMEOUT_LO_S <= median_gap <= ESP_DIAG_API_TIMEOUT_HI_S
    )
    return {
        "reboots_24h": reboots,
        "median_interval_s": median_gap,
        "looks_like_api_reboot_timeout": looks_like_api_timeout,
        "boot_started_at": starts[-1] if starts else 0,
    }


def _esp_diag_clock() -> dict:
    """The board's own reception time against the time the bridge saw it.

    A board whose clock never synced still publishes frames, just without
    received_at - and that is worth showing rather than leaving the reader to
    wonder why one column is empty. A large skew is the other case: the frames
    are arriving, but not when the board thinks they were received.
    """
    out: dict[str, dict] = {}
    for row in read_tsv(
        STATUS_ESP_RX_CLOCK_FILE,
        ["source", "last_received", "last_bridge", "skew_s", "stamped", "unstamped"],
    ):
        src = str(row.get("source") or "").strip()
        if not src:
            continue
        stamped = safe_int(row.get("stamped"))
        unstamped = safe_int(row.get("unstamped"))
        out[src] = {
            "stamped": stamped,
            "unstamped": unstamped,
            "skew_s": safe_int(row.get("skew_s")),
            # A board is only "synced" once it is actually stamping frames, not
            # because it once did: firmware without the field looks identical to
            # firmware whose clock never came up.
            "synced": stamped > 0 and unstamped == 0,
            "partial": stamped > 0 and unstamped > 0,
        }
    return out




def _esp_diag_config() -> dict:
    """Latest /diag/config snapshot per ESP source.

    Each value carries the effective radio configuration as one list of
    text lines already annotated with (default) / (CHANGED, default: X) /
    (set) / (required); the panel splits that marker off for the badge and
    prints the rest verbatim. A source appears here once the board has
    published /diag/config after boot; older firmware simply is not there.
    """
    try:
        with open(STATUS_ESP_CONFIG_FILE, "r", encoding="utf-8") as fh:
            raw = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(raw, dict):
        return {}
    out: dict[str, dict] = {}
    for src, snap in raw.items():
        if not isinstance(snap, dict):
            continue
        lines = snap.get("lines")
        if not isinstance(lines, list):
            continue
        clean = [str(line) for line in lines if line]
        out[str(src)] = {
            "radio": str(snap.get("radio") or "").strip(),
            "lines": clean,
            "epoch": safe_int(snap.get("_bridge_rx_epoch")),
        }
    return out

def _esp_diag_payload() -> dict:
    """Per-board diagnostics for the Diagnostics tab."""
    now = int(time.time())
    seq_rows = {
        str(r.get("source") or ""): r
        for r in read_tsv(
            STATUS_ESP_RX_SEQUENCE_FILE,
            ["source", "boot_id", "last_seq", "missing", "out_of_order", "last_seen"],
        )
        if str(r.get("source") or "")
    }
    boots = _esp_diag_boots()
    clocks = _esp_diag_clock()
    configs = _esp_diag_config()

    frames: dict[str, int] = {}
    meters: dict[str, int] = {}
    for row in read_tsv(
        STATUS_ESP_RX_RECEPTION_FILE,
        ["id", "device", "first_seen", "last_seen", "count", "last_topic"],
    ):
        dev = str(row.get("device") or "").strip()
        cnt = safe_int(row.get("count"))
        if not dev or cnt <= 0:
            continue
        frames[dev] = frames.get(dev, 0) + cnt
        meters[dev] = meters.get(dev, 0) + 1

    names = set(seq_rows) | set(boots) | set(frames) | set(configs)
    rows = []
    for name in sorted(names):
        seq_row = seq_rows.get(name) or {}
        last_seq = safe_int(seq_row.get("last_seq"))
        missing = safe_int(seq_row.get("missing"))
        ooo = safe_int(seq_row.get("out_of_order"))
        last_seen = safe_int(seq_row.get("last_seen"))
        reboot = _esp_diag_reboot_view(boots.get(name) or [], now)

        expected = last_seq + missing
        young = reboot["boot_started_at"] > 0 and now - reboot["boot_started_at"] < ESP_DIAG_BOOT_GRACE_S
        ratio = (missing / expected) if expected > 0 else 0.0

        reasons = []
        status = "ok"
        if last_seq < ESP_DIAG_MIN_EVENTS or young:
            status = "unknown"
            reasons.append("not_enough_data")
        else:
            if ratio > ESP_DIAG_ALARM_RATIO or missing >= ESP_DIAG_ALARM_SINGLE_GAP:
                status = "alarm"
                reasons.append("sequence_gaps")
            elif ratio > ESP_DIAG_WARN_RATIO:
                status = "warn"
                reasons.append("sequence_gaps")

        if reboot["reboots_24h"] >= ESP_DIAG_REBOOT_ALARM:
            status = "alarm"
            reasons.append("reboot_loop")
        elif reboot["reboots_24h"] >= ESP_DIAG_REBOOT_WARN and status in ("ok", "unknown"):
            status = "warn"
            reasons.append("reboots")
        if reboot["looks_like_api_reboot_timeout"]:
            reasons.append("api_reboot_timeout")

        rows.append({
            "name": name,
            "boot_id": str(seq_row.get("boot_id") or ""),
            "last_seq": last_seq,
            "missing": missing,
            "out_of_order": ooo,
            "gap_ratio_pct": round(ratio * 100, 3),
            "frames": frames.get(name, 0),
            "meters": meters.get(name, 0),
            "last_seen": last_seen,
            "age_s": max(0, now - last_seen) if last_seen else 0,
            "uptime_s": max(0, now - reboot["boot_started_at"]) if reboot["boot_started_at"] else 0,
            "reboots_24h": reboot["reboots_24h"],
            "reboot_median_interval_s": reboot["median_interval_s"],
            "status": status,
            "config": configs.get(name) or {},
            "clock": clocks.get(name) or {},
            "reasons": reasons,
        })

    return {
        "now": now,
        "devices": rows,
        "thresholds": {
            "min_events": ESP_DIAG_MIN_EVENTS,
            "warn_ratio_pct": ESP_DIAG_WARN_RATIO * 100,
            "alarm_ratio_pct": ESP_DIAG_ALARM_RATIO * 100,
            "alarm_single_gap": ESP_DIAG_ALARM_SINGLE_GAP,
            "reboot_warn": ESP_DIAG_REBOOT_WARN,
            "reboot_alarm": ESP_DIAG_REBOOT_ALARM,
        },
    }


def _esp_payload() -> dict:
    """Assemble the ESP section of /api/app.

    ESP device detection is intentionally limited to two independent sources:

      1. PRIMARY: status_esp_telegram_devices.tsv, filled from RAW_TOPIC
         (for example wmbus/+/telegram). This works without ESP diagnostics.

      2. SECONDARY: wmbus/+/diag/summary, used as an optional heartbeat when
         the ESP firmware publishes diagnostics.

    Other diagnostic topics (boot, suggestion, meter_window, dropped, ...)
    remain visible in the event log, but they do not create an active ESP and
    they must not overwrite the detection topic shown for a device.
    """
    import time as _time

    diag_latest = read_json(STATUS_ESP_DIAG_JSON)
    current_raw_device, current_raw_topic, tracker_has_rows = _current_raw_esp_source()
    diag = (
        diag_latest
        if _diag_matches_current_raw_source(diag_latest, current_raw_device, tracker_has_rows)
        else {}
    )
    suggestion = read_json(STATUS_ESP_SUGGESTION_FILE)
    boot       = read_json(STATUS_ESP_BOOT_FILE)
    events     = read_tsv(STATUS_ESP_EVENTS_FILE, ["epoch", "evtype", "topic", "payload"], limit=100, reverse=True)
    telegram_rows = read_tsv(STATUS_ESP_TELEGRAM_DEVICES_FILE, ["name", "last_telegram_epoch", "topic", "telegram_count"])

    WARN_AFTER_S = 2 * 60
    OFFLINE_AFTER_S = 5 * 60
    now_epoch       = int(_time.time())
    SUMMARY_TOPIC_SUFFIX = "/diag/summary"

    # Per-device aggregation. Seeded from telegram tracker (primary), then
    # enriched from the diag events buffer (secondary).
    devices: dict[str, dict] = {}

    def device_from_topic(topic: str) -> str:
        return _esp_device_from_topic(topic)

    def blank_device(dev: str) -> dict:
        return {
            "name": dev,
            "topic": "",
            "telegram_topic": "",
            "summary_topic": "",
            "event_topic": "",
            "last_telegram_epoch": 0,
            "telegram_count": 0,
            "last_summary_epoch": 0,
            "last_event_epoch": 0,
            "last_seen_epoch": 0,
            "last_evtype": "",
        }

    def apply_summary(dev: str, topic: str, epoch: int) -> None:
        if not dev or not topic or epoch <= 0:
            return
        entry = devices.setdefault(dev, blank_device(dev))
        if epoch > entry["last_summary_epoch"]:
            entry["last_summary_epoch"] = epoch
            entry["summary_topic"] = topic

    # ── Seed from telegram tracker ──
    # This is the primary source of truth. bridge.sh clears the tracker file at
    # start, so a row means the current bridge process has seen that ESP publish
    # on the configured RAW_TOPIC.
    for row in telegram_rows:
        dev = (row.get("name") or "").strip()
        if not dev:
            continue
        topic = row.get("topic") or ""
        ep = safe_int(row.get("last_telegram_epoch"))
        entry = devices.setdefault(dev, blank_device(dev))
        if ep >= entry["last_telegram_epoch"]:
            entry["telegram_topic"] = topic
            entry["last_telegram_epoch"] = ep
            entry["telegram_count"] = safe_int(row.get("telegram_count"))

    # The latest diag summary JSON is written by a separate subscriber. Use it
    # as a direct heartbeat source in addition to the rolling event buffer.
    diag_topic = (diag_latest.get("_topic") or "").strip()
    diag_epoch = safe_int(diag_latest.get("_bridge_rx_epoch", 0))
    if diag_topic.endswith(SUMMARY_TOPIC_SUFFIX):
        apply_summary(device_from_topic(diag_topic), diag_topic, diag_epoch)

    # ── Enrich / merge from diag events ──
    # Only the exact wmbus/<device>/diag/summary topic participates in device
    # detection. All other events are retained as event-only context.
    for ev in events:
        topic = (ev.get("topic") or "").strip()
        dev = device_from_topic(topic)
        if not dev:
            continue
        epoch  = safe_int(ev.get("epoch"))
        evtype = ev.get("evtype") or ""
        if topic.endswith(SUMMARY_TOPIC_SUFFIX):
            apply_summary(dev, topic, epoch)
            continue

        # Keep boot/suggestion/etc. visible as event-only rows, but do not let
        # them replace the telegram or summary topic used for detection.
        entry = devices.setdefault(dev, blank_device(dev))
        if epoch > entry["last_event_epoch"]:
            entry["last_event_epoch"] = epoch
            entry["event_topic"] = topic
            if entry["last_telegram_epoch"] <= 0 and entry["last_summary_epoch"] <= 0:
                entry["last_seen_epoch"] = epoch
                entry["last_evtype"] = evtype

    # ── Always-on radio health pulse, keyed per ESP device ──
    # status_esp_health.json is a map { "<device>": {uptime_s, rx_total,
    # sec_since_last_rx, chip, listen_mode, _bridge_rx_epoch} }, written by the
    # wmbus/+/health subscriber (one entry per ESP, published every 60 s
    # regardless of diagnostic_mode). It enriches each device row with chip +
    # reception ("ear alive", from the RX path not the loop) and feeds the
    # aggregate verdict. Only devices present in the tracker are considered, so a
    # health entry for an ESP no longer seen does not linger as a forever-stale
    # ghost. Quality (ok/total, RSSI) is deliberately NOT here — it stays in diag.
    # NOTE: a signal-strength band from the pulse RSSI was intentionally removed.
    # Field testing showed RSSI is not trustworthy across boards (same SX1276 read
    # -53 dBm on one board and a pinned -119 on another; an SX1262 + FEM board
    # reported a flat -83 for every meter) — it is hardware/front-end dependent and
    # often stuck, while reception itself is perfect. Reception (telegrams decoding)
    # is the honest signal; real per-meter quality is reception % from the opt-in
    # diag meter_window (planned), not RSSI.
    health_raw = read_json(STATUS_ESP_HEALTH_JSON)
    health_map: dict[str, dict] = {}
    if isinstance(health_raw, dict):
        for _hdev, _h in health_raw.items():
            if not isinstance(_h, dict):
                continue
            _hep = safe_int(_h.get("_bridge_rx_epoch", 0))
            if _hep <= 0:
                continue
            _hfresh = (now_epoch - _hep) <= 150
            _hsec = safe_int(_h.get("sec_since_last_rx", -1))
            health_map[_hdev] = {
                # alive = fresh pulse (ESP alive). stale = had a pulse, now silent
                # (ESP stopped publishing) — NOT a firmware problem.
                "state": "alive" if _hfresh else "stale",
                "chip": str(_h.get("chip", "")).strip(),
                "listen_mode": str(_h.get("listen_mode", "")).strip(),
                "uptime_s": safe_int(_h.get("uptime_s", 0)),
                "rx_total": safe_int(_h.get("rx_total", 0)),
                "sec_since_last_rx": _hsec,
                # hears = heard ether traffic recently (~1.5x the 60 s pulse); NOT
                # a per-meter rhythm verdict (learned cadence is deferred).
                "hears": _hfresh and 0 <= _hsec <= 90,
                "last_pulse_epoch": _hep,
            }

    # ── Finalize display + active flag ──
    # ESP receiver status is based on the primary telegram topic only. A fresh
    # wmbus/<device>/telegram means green; after 2 minutes without telegrams it
    # becomes warning; after 5 minutes it is offline. diag/summary remains
    # optional context and never keeps a receiver green by itself.
    for entry in devices.values():
        last_tg  = entry.get("last_telegram_epoch", 0)
        last_sum = entry.get("last_summary_epoch", 0)
        telegram_age_s = max(0, now_epoch - last_tg) if last_tg > 0 else 0
        if last_tg <= 0 or telegram_age_s > OFFLINE_AFTER_S:
            health = "offline"
            active = False
        elif telegram_age_s > WARN_AFTER_S:
            health = "warn"
            active = True
        else:
            health = "online"
            active = True
        entry["telegram_age_s"] = telegram_age_s
        entry["health"] = health
        entry["active"] = active
        # has_diag tells the frontend whether this ESP exposes diag/events
        # (useful for the "diag required" notice — we can soften it when
        # at least one ESP IS publishing diag).
        entry["has_diag"] = last_sum > 0
        # Per-device radio health PULSE (alive/stale/unknown). DISTINCT key from
        # entry["health"] above — that one is the telegram-age status string
        # (online/warn/offline) the STATUS column relies on; clobbering it would
        # make every row read as Offline. "unknown" when this ESP never published
        # /health (e.g. older firmware).
        entry["radio_health"] = health_map.get(entry["name"], {"state": "unknown"})
        entry["topic"] = (
            entry.get("telegram_topic")
            or entry.get("summary_topic")
            or entry.get("event_topic")
            or entry.get("topic")
            or ""
        )
        if last_tg > 0 or last_sum > 0:
            if last_tg >= last_sum:
                entry["last_seen_epoch"] = last_tg
                entry["last_evtype"] = "telegram"
            else:
                entry["last_seen_epoch"] = last_sum
                entry["last_evtype"] = "summary"
        entry["detection_source"] = (
            "telegram" if last_tg > 0 else
            ("summary" if last_sum > 0 else "event")
        )

    # Drop devices not seen for over 12 h: long-dead ghosts (e.g. an ESP whose
    # topic_name was renamed) fall off the list entirely. The window is long on
    # purpose — a genuinely stopped ESP stays visible (and keeps raising the
    # "pulse stopped" verdict) well within it, so this never hides a recently
    # silenced receiver (honest-witness).
    HIDE_AFTER_S = 12 * 60 * 60
    # Sort: active first (by recency), then inactive. Stale ghost entries
    # from MQTT retained messages drift to the bottom.
    devices_list = sorted(
        (d for d in devices.values()
         if d["last_seen_epoch"] > 0 and (now_epoch - d["last_seen_epoch"]) <= HIDE_AFTER_S),
        key=lambda d: (not d["active"], -d["last_seen_epoch"]),
    )
    devices_active_count = sum(1 for d in devices_list if d["active"])

    # Aggregate radio-health verdict (#24: the aggregate must never hide a dead
    # ESP). Computed only over devices that actually published /health; a stopped
    # ESP is surfaced by name so a multi-ESP setup cannot show all-green while one
    # receiver is silent.
    _h_alive = [d for d in devices_list if d.get("radio_health", {}).get("state") == "alive"]
    _h_stale = [d for d in devices_list if d.get("radio_health", {}).get("state") == "stale"]
    _h_known = _h_alive + _h_stale
    if not _h_known:
        health_aggregate: dict = {"state": "unknown"}
    elif not _h_stale:
        health_aggregate = {
            "state": "alive",
            "total": len(_h_known),
            "alive": len(_h_alive),
            # N==1: surface the single ESP's chip so the headline can show detail.
            "chip": _h_alive[0]["radio_health"].get("chip", "") if len(_h_known) == 1 else "",
        }
    else:
        health_aggregate = {
            "state": "some_stale",
            "total": len(_h_known),
            "alive": len(_h_alive),
            "stale": len(_h_stale),
            "stopped": [d["name"] for d in _h_stale],
        }

    return {
        # diag is filtered for the dashboard tile: never mix metrics from a
        # stale/other ESP with the currently received RAW telegram source.
        "diag": diag,
        # Keep the latest summary available for the diagnostics page.
        "diag_latest": diag_latest,
        "current_raw_device": current_raw_device,
        "current_raw_topic": current_raw_topic,
        "suggestion": suggestion,
        "boot": boot,
        "events": events,
        "devices": devices_list,
        # Aggregate radio-health verdict for the workspace headline (#24).
        "health_aggregate": health_aggregate,
        # devices_count = ACTIVE only (drives the Pipeline badge "N × ESP").
        # devices_total = all distinct names seen.
        "devices_count": devices_active_count,
        "devices_total": len(devices_list),
        # any_diag_active tells the UI whether to show or soften the
        # "ESP diagnostics required" notice on the ESP Logs page.
        "any_diag_active": any(d["active"] and d["has_diag"] for d in devices_list),
    }


def frontend_payload(lang: str = DEFAULT_LANG, include_i18n: bool = True) -> dict:
    """Return the data contract used by the static WebGUI."""
    data = state()
    lang = lang if lang in SUPPORTED_LANGS else DEFAULT_LANG
    payload = {
        "meta": {
            "version": ADDON_VERSION,
            "is_dev": ADDON_IS_DEV,
            "runtime": "home_assistant" if os.environ.get("SUPERVISOR_TOKEN") else "docker",
            "base": str(BASE),
        },
        "model": status_model(data),
        "search_config": search_config_model(data),
        "esp": _esp_payload(),
        "esp_diag": _esp_diag_payload(),
        # The nav needs this before anything M-Bus specific is fetched. Without
        # it the tab could never appear: its visibility flag lived only in the
        # /api/mbus payload, which is loaded lazily when the tab is opened —
        # the tab the user cannot reach while it is hidden.
        "mbus_tab_visible": bool((read_options() or {}).get("mbus_tab_visible")),
        **data,
    }
    if include_i18n:
        text = {
            **I18N.get(DEFAULT_LANG, {}),
            **I18N.get(lang, {}),
        }
        payload["i18n"] = {
            "lang": lang,
            "supported": sorted(SUPPORTED_LANGS),
            "labels": {"en": "English", "pl": "Polski", "de": "Deutsch", "cs": "Česky", "sk": "Slovenčina"},
            "text": text,
        }
    return payload


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        return

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'no-store')
        lang = getattr(self, '_wmbus_lang', '')
        if lang in SUPPORTED_LANGS:
            self.send_header('Set-Cookie', f'{LANG_COOKIE}={lang}; Path=/; SameSite=Lax')
        self.end_headers()
        self.wfile.write(body)

    def _send_json(self, status: int, payload: dict) -> None:
        self._send(status, json.dumps(payload, ensure_ascii=True, indent=2).encode("utf-8"), "application/json; charset=utf-8")

    def _send_json_download(self, status: int, payload: dict, filename: str) -> None:
        body = json.dumps(payload, ensure_ascii=True, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_event_stream(self, lang: str) -> None:
        import time as _time

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("X-Accel-Buffering", "no")
        if lang in SUPPORTED_LANGS:
            self.send_header("Set-Cookie", f"{LANG_COOKIE}={lang}; Path=/; SameSite=Lax")
        self.end_headers()

        last_body = ""
        last_write = 0.0
        while True:
            try:
                body = json.dumps(frontend_payload(lang, include_i18n=False), ensure_ascii=True, separators=(",", ":"))
                now = _time.time()
                if body != last_body:
                    self.wfile.write(f"event: state\ndata: {body}\n\n".encode("utf-8"))
                    self.wfile.flush()
                    last_body = body
                    last_write = now
                elif now - last_write >= 25:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    last_write = now
                _time.sleep(0.5)
            except (BrokenPipeError, ConnectionResetError, OSError):
                return

    def _send_static_index(self) -> bool:
        index_path = STATIC_DIR / "index.html"
        if not index_path.is_file():
            return False
        self._send(200, index_path.read_bytes(), "text/html; charset=utf-8")
        return True

    def _send_static_asset(self, raw_path: str) -> bool:
        marker = "/assets/"
        if marker not in raw_path:
            return False
        asset_name = raw_path.rsplit(marker, 1)[1].split("?", 1)[0].split("#", 1)[0].lstrip("/")
        if not asset_name or "\\" in asset_name or ".." in asset_name.split("/"):
            return False
        asset_path = STATIC_DIR / "assets" / Path(*asset_name.split("/"))
        if not asset_path.is_file():
            return False
        content_type = mimetypes.guess_type(str(asset_path))[0] or "application/octet-stream"
        if asset_path.suffix == ".js":
            content_type = "text/javascript; charset=utf-8"
        elif asset_path.suffix == ".css":
            content_type = "text/css; charset=utf-8"
        self._send(200, asset_path.read_bytes(), content_type)
        return True

    def _redirect(self, target: str) -> None:
        self.send_response(303)
        self.send_header('Location', target)
        self.send_header('Cache-Control', 'no-store')
        lang = getattr(self, '_wmbus_lang', '')
        if lang in SUPPORTED_LANGS:
            self.send_header('Set-Cookie', f'{LANG_COOKIE}={lang}; Path=/; SameSite=Lax')
        self.end_headers()


    def _read_form(self) -> dict[str, list[str]]:
        length = safe_int(self.headers.get('Content-Length'))
        if length <= 0:
            return {}
        body = self.rfile.read(length).decode('utf-8', errors='replace')
        return parse_qs(body)

    def _read_params(self) -> dict[str, list[str]]:
        length = safe_int(self.headers.get("Content-Length"))
        if length <= 0:
            return {}
        body = self.rfile.read(length).decode("utf-8", errors="replace")
        content_type = (self.headers.get("Content-Type") or "").lower()
        if "application/json" in content_type:
            try:
                payload = json.loads(body)
            except Exception:
                payload = {}
            if isinstance(payload, dict):
                return {str(k): [str(v)] for k, v in payload.items() if v is not None}
            return {}
        return parse_qs(body)

    def _route_path(self, raw_path: str) -> str:
        path = raw_path.rstrip('/') or '/'
        ingress_match = re.match(r"^/api/hassio_ingress/[^/]+(?P<rest>/.*)?$", path)
        if ingress_match:
            path = (ingress_match.group("rest") or "/").rstrip("/") or "/"
        api_suffixes = (
            '/api/app', '/api/events', '/api/status', '/api/add-meter', '/api/remove-meter',
            '/api/search-control', '/api/restart-bridge', '/api/reload-pipeline',
            '/api/preview-candidate', '/api/cancel-preview',
            '/api/ignore', '/api/unignore', '/api/factory-reset',
            '/api/compare-driver', '/api/save-config', '/api/driver-fields',
            '/api/esp-rx',
            '/api/mbus', '/api/mbus/device', '/api/mbus/meters', '/api/mbus/probe',
            '/api/mbus/console', '/api/mbus/scan', '/api/mbus/poll-one',
            '/api/mbus/detect-driver',
        )
        if any(path.endswith(suffix) for suffix in api_suffixes):
            return path
        known = {'/', '/meters', '/discover', '/search', '/search-discover', '/candidate', '/logs', '/esp-logs', '/settings', '/about', '/ignore', '/unignore', '/config', '/search-control', '/restart-bridge', '/add-meter', '/remove-meter'}
        if path not in known and not path.endswith('/api/app') and not path.endswith('/api/status') and not path.endswith('/healthz'):
            last = '/' + path.rsplit('/', 1)[-1]
            if last in known:
                path = last
        return path

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = self._route_path(parsed.path)
        params = self._read_params()
        lang = detect_lang(self.headers, params)
        self._wmbus_lang = lang
        if path.endswith('/api/mbus/device'):
            ok, msg = mbus_save_device(
                (params.get('device') or [''])[0].strip(),
                (params.get('bus_alias') or ['MAIN'])[0].strip(),
                (params.get('baudrate') or ['2400'])[0].strip(),
                (params.get('poll_interval') or ['15m'])[0].strip(),
                (params.get('donotprobe_all') or ['true'])[0].strip().lower()
                in ('true', '1', 'on', 'yes'),
                (params['mbus_enabled'][0].strip().lower() in ('true', '1', 'on', 'yes')
                 if 'mbus_enabled' in params else None),
            )
            self._send_json(200 if ok else 400, {"ok": ok, "message": msg})
            return
        if path.endswith('/api/mbus/meters'):
            raw = (params.get('meters') or ['[]'])[0]
            try:
                meters = json.loads(raw)
            except ValueError:
                self._send_json(400, {"ok": False, "message": "meters: invalid JSON."})
                return
            if not isinstance(meters, list):
                self._send_json(400, {"ok": False, "message": "meters: expected a list."})
                return
            ok, msg = mbus_save_meters(meters)
            self._send_json(200 if ok else 400, {"ok": ok, "message": msg})
            return
        if path.endswith('/api/mbus/probe'):
            # Deliberately probes only the port the user picked. Never the
            # listed ones: on a typical HA box one of them is a Zigbee
            # coordinator, and this call transmits.
            opts = read_options()
            opts = opts if isinstance(opts, dict) else {}
            allowed, why = mbus_transmit_allowed()
            if not allowed:
                self._send_json(409, {"ok": False, "state": "engine_running",
                                      "message": why})
                return
            device = (params.get('device') or [str(opts.get('mbus_device') or '')])[0].strip()
            try:
                baud = int(str(opts.get('mbus_baudrate') or '2400'))
            except ValueError:
                baud = 2400
            state_name, reply_hex = mbus_probe_bus(device, baud)
            self._send_json(200, {"ok": True, "state": state_name,
                                  "reply_hex": reply_hex, "device": device})
            return
        if path.endswith('/api/mbus/scan'):
            opts = read_options()
            opts = opts if isinstance(opts, dict) else {}
            allowed, why = mbus_transmit_allowed()
            if not allowed:
                self._send_json(409, {"ok": False, "state": "engine_running",
                                      "message": why})
                return
            device = str(opts.get('mbus_device') or '')
            try:
                baud = int(str(opts.get('mbus_baudrate') or '2400'))
            except ValueError:
                baud = 2400
            try:
                first = int((params.get('first') or ['1'])[0])
                last = int((params.get('last') or ['32'])[0])
            except ValueError:
                self._send_json(400, {"ok": False, "message": "first/last must be numbers."})
                return
            first, last = mbus_scan_range(first, last)
            state_name, results = mbus_scan_addresses(device, first, last, baud)
            found = [row for row in results if row.get('answered')]
            # The scanned range is reported back rather than assumed: it is
            # capped, and a caller that does not know where the sweep stopped
            # would read a partial result as a complete one.
            self._send_json(200, {"ok": state_name == 'ok', "state": state_name,
                                  "found": found, "results": results, "first": first,
                                  "last": last, "chunk": MBUS_SCAN_MAX})
            return
        if path.endswith('/api/mbus/poll-one') or path.endswith('/api/mbus/detect-driver'):
            opts = read_options()
            opts = opts if isinstance(opts, dict) else {}
            allowed, why = mbus_transmit_allowed()
            if not allowed:
                self._send_json(409, {"ok": False, "state": "engine_running",
                                      "message": why})
                return
            # Primary addresses only, and the range is checked here rather than
            # left to the poller: "68123456" is a perfectly valid secondary
            # address made of digits, so isdigit() alone accepted it and passed
            # 68123456 down as an address. Secondary addressing needs a select
            # cycle the decoder performs; this button sends one bare REQ_UD2.
            raw_addr = (params.get('address') or [''])[0].strip().lstrip('pP')
            if not raw_addr.isdigit() or not 1 <= int(raw_addr) <= 250:
                self._send_json(400, {"ok": False, "state": "bad_address",
                                      "message": "Only a primary address (p1..p250) can be polled from here. "
                                                 "A secondary (8-hex) address needs the selection the decoder does."})
                return
            device = str(opts.get('mbus_device') or '')
            try:
                baud = int(str(opts.get('mbus_baudrate') or '2400'))
            except ValueError:
                baud = 2400
            state_name, reply_hex = mbus_poll_once(device, int(raw_addr), baud)
            if path.endswith('/api/mbus/detect-driver'):
                driver = (_analyze_auto_driver(reply_hex, '')
                          if state_name == 'frame_long' else '')
                self._send_json(200, {"ok": True, "state": state_name,
                                      "reply_hex": reply_hex,
                                      "address": int(raw_addr),
                                      "detected": bool(driver),
                                      "driver": driver})
                return
            self._send_json(200, {"ok": True, "state": state_name,
                                  "reply_hex": reply_hex, "address": int(raw_addr)})
            return
        if path.endswith('/api/remove-meter'):
            meter_id = (params.get('meter_id') or [''])[0].strip()
            # NB: remove_meter_from_options already emits the appropriate
            # webui_add_event ("ok" on Supervisor-API success, "warn" on file
            # fallback, "error" on raised exception). Re-logging here would
            # double-stamp status_events.tsv in the same second.
            ok, msg = remove_meter_from_options(meter_id)
            self._send_json(200 if ok else 400, {"ok": ok, "message": msg})
            return
        if path.endswith('/api/update-meter'):
            meter_id = (params.get('meter_id') or [''])[0].strip()
            driver = (params.get('driver') or [''])[0].strip()
            # Empty/absent key keeps the currently configured key.
            key = (params.get('key') or [''])[0].strip()
            # Absent parameter = leave the pattern alone (older front-end);
            # present but empty = clear it.
            if 'exclude_fields' in params:
                ok_ex, exclude_fields, err = _clean_exclude_fields((params.get('exclude_fields') or [''])[0])
                if not ok_ex:
                    self._send_json(400, {"ok": False, "message": err})
                    return
            else:
                exclude_fields = None
            if 'calculated_fields' in params:
                ok_calc, calculated_fields, err = _clean_calculated_fields(
                    (params.get('calculated_fields') or [''])[0])
                if not ok_calc:
                    self._send_json(400, {"ok": False, "message": err})
                    return
            else:
                calculated_fields = None
            if 'static_fields' in params:
                ok_st, static_fields, err = _clean_static_fields(
                    (params.get('static_fields') or [''])[0])
                if not ok_st:
                    self._send_json(400, {"ok": False, "message": err})
                    return
            else:
                static_fields = None
            ok, msg = update_meter_in_options(meter_id, driver, key or None, exclude_fields,
                                              calculated_fields, static_fields)
            self._send_json(200 if ok else 400, {"ok": ok, "message": msg})
            return
        if path.endswith('/api/factory-reset'):
            ok, msg = factory_reset()
            self._send_json(200 if ok else 400, {"ok": ok, "message": msg})
            return
        if path.endswith('/api/compare-driver'):
            meter_id = (params.get('meter_id') or [''])[0].strip()
            driver = (params.get('driver') or [''])[0].strip()
            key = (params.get('key') or [''])[0].strip()
            ok, payload = compare_meter_drivers(meter_id, driver, key)
            self._send_json(200 if ok else 400, payload)
            return
        if path.endswith('/api/save-config'):
            # Flattened {key: [strval]} from _read_params; save_config_options
            # coerces each by the schema type. meters/unknown keys are ignored.
            values = {k: (v[0] if isinstance(v, list) and v else "") for k, v in params.items()}
            ok, msg = save_config_options(values)
            self._send_json(200 if ok else 400, {"ok": ok, "message": msg})
            return
        if path.endswith('/api/discovery-doctor'):
            # Ask the bridge for a live broker probe and wait for the result.
            # The heartbeat ticker polls the request flag every ~10 s and the
            # probe itself takes a few bounded mosquitto_sub waits, so 25 s
            # covers the worst case; the UI shows a spinner meanwhile.
            import time as _time
            started = _time.time()
            try:
                DISCOVERY_DOCTOR_REQUEST.touch()
            except OSError as exc:
                self._send_json(500, {"ok": False, "message": f"cannot request probe: {exc}"})
                return
            probe = None
            while _time.time() - started < 25:
                try:
                    if STATUS_DISCOVERY_DOCTOR_JSON.stat().st_mtime >= started:
                        probe = read_json(STATUS_DISCOVERY_DOCTOR_JSON)
                        break
                except OSError:
                    pass
                _time.sleep(0.5)
            status = read_json(STATUS_JSON)
            status = status if isinstance(status, dict) else {}
            mqtt = status.get("mqtt", {}) if isinstance(status.get("mqtt"), dict) else {}
            pipeline = status.get("pipeline", {}) if isinstance(status.get("pipeline"), dict) else {}
            ha_presence = "unknown"
            try:
                _ha_raw = STATUS_HA_PRESENCE_FILE.read_text(encoding="utf-8").strip()
                _ha_state = _ha_raw.split("\t")[0]
                if _ha_state in ("online", "offline"):
                    ha_presence = _ha_state
            except OSError:
                pass
            # Third, strongest signal for the prefix check: the opt-in
            # verify_ha_entities canary — "verified" means the HA Core API
            # confirmed the canary entity exists, i.e. HA consumes Discovery
            # from this broker on this prefix.
            ha_verification = "unavailable"
            try:
                _hv_raw = STATUS_HA_VERIFICATION_FILE.read_text(encoding="utf-8").strip()
                _hv_state = _hv_raw.split("\t")[0].strip().lower()
                if _hv_state in ("verified", "not_created", "pending", "unavailable"):
                    ha_verification = _hv_state
            except OSError:
                pass
            options = read_options()
            options = options if isinstance(options, dict) else {}
            self._send_json(200, {
                "ok": True,
                # probe is None when the bridge did not answer in time
                # (e.g. pipeline down) — the UI renders that as its own ✗.
                "probe": probe,
                "mqtt_connected": bool(mqtt.get("connected")),
                "mqtt_host": str(mqtt.get("host") or ""),
                "discovery_published": bool(pipeline.get("discovery_published")),
                "ha_presence": ha_presence,
                "ha_verification": ha_verification,
                "discovery_enabled": bool(options.get("discovery_enabled", True)),
                "discovery_prefix": str(options.get("discovery_prefix") or "homeassistant"),
                "discovery_retain": bool(options.get("discovery_retain", True)),
                "meters_configured": len(options.get("meters") or []),
            })
            return
        if path.endswith('/api/add-meter'):
            meter_id = (params.get('meter_id') or [''])[0].strip()
            driver = (params.get('driver') or ['auto'])[0].strip()
            key = (params.get('key') or [''])[0].strip()
            meter_name = (params.get('meter_name') or [''])[0].strip()
            ok_ex, exclude_fields, err = _clean_exclude_fields((params.get('exclude_fields') or [''])[0])
            if not ok_ex:
                self._send_json(400, {"ok": False, "message": err})
                return
            ok_calc, calculated_fields, err = _clean_calculated_fields(
                (params.get('calculated_fields') or [''])[0])
            if not ok_calc:
                self._send_json(400, {"ok": False, "message": err})
                return
            ok_st, static_fields, err = _clean_static_fields(
                (params.get('static_fields') or [''])[0])
            if not ok_st:
                self._send_json(400, {"ok": False, "message": err})
                return
            # NB: add_meter_to_options already emits the appropriate
            # webui_add_event (ok / warn / error) with the most accurate
            # context — re-logging here would double-stamp status_events.tsv
            # in the same second.
            ok, msg = add_meter_to_options(meter_id, driver, key, meter_name=meter_name,
                                           exclude_fields=exclude_fields,
                                           calculated_fields=calculated_fields,
                                           static_fields=static_fields)
            # When a previewed candidate is added permanently, drop the
            # preview meter file so the LISTEN instance doesn't keep
            # decoding the same telegrams that DECODE now handles.
            if ok and meter_id:
                meter_id_norm = normalize_meter_id(meter_id)
                preview_path = PREVIEW_METER_DIR / f"meter-preview-{meter_id_norm}"
                try:
                    if preview_path.exists():
                        preview_path.unlink()
                except OSError:
                    pass
            self._send_json(200 if ok else 400, {"ok": ok, "message": msg})
            return
        if path.endswith('/api/preview-candidate'):
            # Store a preview request outside the always-on LISTEN config dir.
            # The next matching RAW telegram is decoded by a short-lived one-shot
            # worker, so neither LISTEN nor PRIMARY needs to restart.
            cid = normalize_meter_id((params.get('id') or [''])[0])
            drv = (params.get('driver') or ['auto'])[0].strip()
            if not VALID_ID_RE.match(cid):
                self._send_json(400, {"ok": False, "message": f"Invalid id: {cid}"})
                return
            try:
                PREVIEW_METER_DIR.mkdir(parents=True, exist_ok=True)
                pf = PREVIEW_METER_DIR / f"meter-preview-{cid}"
                pf.write_text(
                    f"name=preview_{cid}\nid={cid}\n" + (f"driver={drv}\n" if drv and drv != 'auto' else ""),
                    encoding='utf-8'
                )
                webui_add_event('ok', f'Preview value requested for {cid}.')
                self._send_json(200, {"ok": True, "message": "Preview requested. Value will appear within ~10 s once a telegram arrives."})
            except Exception as exc:
                webui_add_event('error', f'Preview failed for {cid}: {exc}')
                self._send_json(500, {"ok": False, "message": f"Preview failed: {exc}"})
            return
        if path.endswith('/api/cancel-preview'):
            # Remove preview request and cached TSV rows. No pipeline reload.
            cid = normalize_meter_id((params.get('id') or [''])[0])
            if not VALID_ID_RE.match(cid):
                self._send_json(400, {"ok": False, "message": f"Invalid id: {cid}"})
                return
            try:
                _cleanup_preview_cache(cid)
                webui_add_event('ok', f'Preview canceled for {cid}.')
                self._send_json(200, {"ok": True, "message": "Preview canceled."})
            except Exception as exc:
                webui_add_event('error', f'Cancel preview failed for {cid}: {exc}')
                self._send_json(500, {"ok": False, "message": f"Cancel failed: {exc}"})
            return
        if path.endswith('/api/search-control'):
            action = (params.get('action') or ['start'])[0]
            # NB: update_options_for_search already emits the appropriate
            # webui_add_event. Re-logging here would double-stamp.
            if action == 'stop':
                ok, msg = update_options_for_search('0', '0.05', enabled=False)
            else:
                ok, msg = update_options_for_search((params.get('expected') or ['0'])[0], (params.get('tolerance') or ['0.05'])[0], enabled=True)
            restart_ok, restart_msg = restart_addon_via_supervisor()
            if restart_ok:
                webui_add_event('ok', restart_msg)
            elif os.environ.get("SUPERVISOR_TOKEN"):
                webui_add_event('error', restart_msg)
            self._send_json(200 if ok else 400, {"ok": ok, "message": msg, "restart_ok": restart_ok, "restart_message": restart_msg})
            return
        if path.endswith('/api/restart-bridge'):
            restart_ok, restart_msg = restart_addon_via_supervisor()
            webui_add_event('ok' if restart_ok else 'error', restart_msg)
            self._send_json(200 if restart_ok else 400, {"ok": restart_ok, "message": restart_msg})
            return
        if path.endswith('/api/reload-pipeline'):
            # Soft reload: touch /data/.reload_pipeline. bridge.sh's watcher
            # picks this up within 2 s, kills the decode pipeline, and the
            # restart_on_exit loop respawns it after refreshing meter files
            # from options.json. Listen instance stays running.
            # Works in BOTH Docker standalone and HA Supervisor — no
            # SUPERVISOR_TOKEN required.
            try:
                flag = BASE / '.reload_pipeline'
                flag.parent.mkdir(parents=True, exist_ok=True)
                flag.touch()
                STATUS_PIPELINE_RELOAD_FILE.write_text(str(datetime.now(timezone.utc).timestamp()), encoding='utf-8')
                webui_add_event('ok', 'Pipeline soft-reload requested.')
                self._send_json(200, {"ok": True, "message": "Pipeline reload requested."})
            except Exception as exc:
                webui_add_event('error', f'Pipeline reload failed: {exc}')
                self._send_json(500, {"ok": False, "message": f"Reload failed: {exc}"})
            return
        if path.endswith('/api/ignore'):
            add_ignored((params.get('id') or [''])[0])
            self._send_json(200, {"ok": True, "message": "Candidate ignored."})
            return
        if path.endswith('/api/unignore'):
            remove_ignored((params.get('id') or [''])[0])
            self._send_json(200, {"ok": True, "message": "Candidate restored."})
            return
        # ── REMOVED: legacy POST form handlers ──
        # /remove-meter, /add-meter, /search-control, /restart-bridge — all used
        # by the dormant HTML forms with redirect responses. New SPA uses the
        # /api/* equivalents above, which return JSON.
        self._send(404, b'not found\n', 'text/plain; charset=utf-8')

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        lang = detect_lang(self.headers, params)
        self._wmbus_lang = lang
        path = self._route_path(parsed.path)

        # Static assets (app.js / app.css / images) first — fast path.
        if self._send_static_asset(parsed.path):
            return
        # API endpoints used by the SPA.
        if path.endswith('/api/events'):
            self._send_event_stream(lang)
            return
        if path.endswith('/api/app'):
            self._send_json(200, frontend_payload(lang))
            return
        if path.endswith('/api/status'):
            self._send(200, json.dumps(state(), ensure_ascii=False, indent=2).encode('utf-8'), 'application/json; charset=utf-8')
            return
        if path.endswith('/api/esp-rx'):
            options = read_options()
            if not isinstance(options, dict) or not bool(options.get('esp_rx_api_enabled', False)):
                self._send_json(404, {"ok": False, "message": "ESP RX API is disabled."})
                return
            try:
                limit = int((params.get('limit') or ['1000'])[0])
                since = int((params.get('since') or ['0'])[0])
                until = int((params.get('until') or ['0'])[0])
            except ValueError:
                self._send_json(400, {"ok": False, "message": "limit, since and until must be integers."})
                return
            download = (params.get('download') or [''])[0].strip().lower() in ('1', 'true', 'yes')
            payload = esp_rx_api_payload(
                limit=limit, since=since, until=until,
                max_limit=100000 if download else 10000,
            )
            if download:
                stamp = time.strftime('%Y%m%d-%H%M%S', time.gmtime(payload['generated_at']))
                self._send_json_download(200, payload, f'esp-rx-{stamp}Z.json')
            else:
                self._send_json(200, payload)
            return
        if path.endswith('/api/candidate-report'):
            meter_id = (params.get('meter_id') or [''])[0].strip()
            ok, payload = candidate_issue_report(meter_id)
            self._send_json(200 if ok else 404, payload)
            return
        if path.endswith('/api/mbus/console'):
            try:
                limit = int((params.get('limit') or ['200'])[0])
            except ValueError:
                limit = 200
            self._send_json(200, {"ok": True, "lines": mbus_console_lines(limit)})
            return
        if path.endswith('/api/mbus'):
            self._send_json(200, mbus_panel_payload())
            return
        if path.endswith('/api/driver-fields'):
            driver = (params.get('driver') or [''])[0].strip()
            ok, fields, err = driver_fields(driver)
            self._send_json(200 if ok else 400,
                            {"ok": ok, "driver": driver, "fields": fields, "message": err})
            return
        if path.endswith('/healthz'):
            self._send(200, b'ok\n', 'text/plain; charset=utf-8')
            return
        # Anything else: serve the SPA shell (index.html) — client-side router
        # handles the deep paths (#discover, #meters, …) so the server just needs
        # to deliver the same shell for every non-asset GET.
        if self._send_static_index():
            return
        self._send(404, b'not found\n', 'text/plain; charset=utf-8')


def main() -> None:
    BASE.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    print(f'[wmbus-webui] serving dashboard on 0.0.0.0:{PORT} base={BASE}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()

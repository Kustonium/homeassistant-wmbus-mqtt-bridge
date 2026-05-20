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

import html
import json
import os
import re
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse

BASE = Path(os.environ.get("WMBUS_BASE", "/data"))
PORT = int(os.environ.get("WEBUI_PORT", "8099"))

STATUS_JSON = BASE / "status.json"
METERS_TSV = BASE / "status_meters.tsv"
CANDIDATES_TSV = BASE / "status_candidates.tsv"
EVENTS_TSV = BASE / "status_events.tsv"
IGNORED_CANDIDATES = BASE / "status_ignored_candidates.tsv"
SEARCH_CANDIDATES_TSV = BASE / "search_candidates.tsv"
SEARCH_MATCHES_TSV = BASE / "search_matches.tsv"
SEARCH_STATUS_JSON = BASE / "search_status.json"
CANDIDATE_ANALYSIS_TSV = BASE / "status_candidate_analysis.tsv"
OPTIONS_JSON = BASE / "options.json"
ZERO_AES_KEY = "00000000000000000000000000000000"


def read_addon_version() -> tuple[str, bool]:
    import re as _re, os as _os
    # 1. Env var injected by CI build-arg (most accurate for dev builds)
    env_ver = _os.environ.get("ADDON_VERSION", "").strip()
    if env_ver:
        return env_ver, "-" in env_ver
    # 2. Fallback: read from config.yaml next to this script
    try:
        cfg_path = Path(__file__).parent / "config.yaml"
        text = cfg_path.read_text(encoding="utf-8")
        m = _re.search(r'^version:\s*["\']?([^\s"\']+)["\']?', text, _re.MULTILINE)
        if m:
            v = m.group(1).strip()
            return v, "-" in v
    except Exception:
        pass
    return "dev", True


ADDON_VERSION, ADDON_IS_DEV = read_addon_version()

VALID_ID_RE = re.compile(r"^[0-9A-Fa-f]{8}$")
MEDIA_FILTERS = {"all", "water", "warm_water", "electricity", "heat", "other"}


# ---------------------------------------------------------------------------
# Localisation — all translations and helpers live in i18n.py
# ---------------------------------------------------------------------------
from i18n import (  # noqa: E402
    SUPPORTED_LANGS, DEFAULT_LANG, LANG_COOKIE,
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


def write_lines_atomic(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
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


def esc(value: object) -> str:
    return html.escape(str(value if value is not None else ""), quote=True)


def safe_int(value: object) -> int:
    try:
        return int(str(value or "0"))
    except Exception:
        return 0


def fmt_ts(iso: str) -> str:
    """Convert ISO timestamp to human-readable: 18.05.2026 10:32:19"""
    if not iso:
        return ''
    try:
        # Handle both Z and +HH:MM timezone
        s = str(iso).replace('Z', '+00:00')
        # Split off timezone
        if '+' in s[10:]:
            s = s[:s.rindex('+')]
        elif s.count('-') > 2:
            s = s[:s.rindex('-')]
        s = s.strip().replace('T', ' ')[:19]
        if len(s) >= 19:
            date, time = s[:10], s[11:19]
            y, m, d = date.split('-')
            return f'{d}.{m}.{y} {time}'
        return iso
    except Exception:
        return str(iso)


def fmt_interval(seconds: object) -> str:
    sec = safe_int(seconds)
    if sec <= 0:
        return "not enough data"
    if sec < 90:
        return f"~{sec}s"
    minutes = int(round(sec / 60))
    if minutes < 90:
        return f"~{minutes} min"
    return f"~{sec / 3600:.1f} h"


def reception_line(row: dict) -> str:
    return (
        f"seen: {row.get('seen_count') or '0'} · "
        f"avg: {fmt_interval(row.get('avg_interval_s'))} · "
        f"15m: {row.get('seen_15m') or '0'} · "
        f"60m: {row.get('seen_60m') or '0'}"
    )


def media_icon(media: str, driver: str = "", html: bool = False) -> str:
    mc = media_class(media, driver)
    if mc == "electricity":
        return "⚡"
    if mc == "heat":
        return "🔥"
    if mc == "warm_water":
        return "🔶"
    if mc == "water":
        return "💧"
    return "📡"



def tr_media(lang: str, mc: str) -> str:
    """Translate media class name to localized string."""
    from i18n import I18N, DEFAULT_LANG
    lang = lang if lang in I18N else DEFAULT_LANG
    key = f"media_{mc}"
    return I18N[lang].get(key) or I18N["en"].get(key) or mc


def media_class(media: str, driver: str = "") -> str:
    media_lc = (media or "").lower()
    if media_lc and media_lc not in {"listen", "search-cache"}:
        if ("warm water" in media_lc or "hot water" in media_lc) and "encrypted" not in media_lc:
            return "warm_water"
        if ("water" in media_lc or "hydro" in media_lc or "cold" in media_lc) and "encrypted" not in media_lc:
            return "water"
        if "electric" in media_lc:
            return "electricity"
        if "heat" in media_lc or "warm" in media_lc:
            return "heat"

    # Fallback: driver name heuristics
    driver_lc = (driver or "").lower()
    if "electric" in driver_lc or "amiplus" in driver_lc or "vario" in driver_lc:
        return "electricity"
    if ("water" in driver_lc or "hydro" in driver_lc or "kamwater" in driver_lc) and "encrypted" not in driver_lc:
        return "water"
    if "warm" in driver_lc or "heat" in driver_lc or "hca" in driver_lc:
        return "heat"
    return "other"


def candidate_config(candidate: dict, key: str = "") -> dict:
    mid = str(candidate.get("id") or "")
    driver = str(candidate.get("driver") or "auto")
    if not driver or driver == "unknown":
        driver = "auto"
    return {
        "id": f"meter_{mid}",
        "meter_id": mid,
        "type": driver,
        "type_other": "",
        "key": key,
    }


def candidate_encryption_hint(candidate: dict) -> tuple[str, str, str]:
    """Return encryption status.

    Returns (label, note, css_class) where css_class is one of: bad / ok / muted.

    Sources of truth (in priority order):
    1. status_candidate_analysis.tsv — bridge.sh explicit analysis (aes_required / no_aes / unknown)
    2. type field from wmbusmeters text — only meaningful when NOT "listen"
       (in LISTEN mode bridge.sh writes type="listen", not the real device description)

    "warn" pill is NOT used here — yellow means "you must act". We use:
      bad  = AES required (red)   — use a real 32-char key
      ok   = no AES (green)       — empty key is fine
      muted = not analyzed (gray) — neutral, not a warning
    """
    analysis = candidate.get("analysis") if isinstance(candidate.get("analysis"), dict) else {}
    enc = str(analysis.get("encryption") or "").strip().lower()
    note = str(analysis.get("note") or "").strip()

    # 1. Explicit backend analysis
    if enc in {"encrypted", "aes_required", "aes"}:
        return "AES required", note or "Bridge analysis: encrypted telegram. Use a real 32-char HEX AES key.", "bad"
    if enc in {"not_encrypted", "no_aes", "plain", "unencrypted"}:
        return "no AES", note or "Bridge analysis: no AES encryption detected.", "ok"

    # 2. Type text from wmbusmeters — only useful when it's not the LISTEN-mode placeholder
    type_val = str(candidate.get("type") or "").strip()
    if type_val and type_val.lower() not in {"listen", "search-cache", ""}:
        text = f"{type_val} {candidate.get('driver', '')}".lower()
        if "encrypted" in text or "aes" in text:
            return "AES required", "wmbusmeters type description contains encrypted/AES.", "bad"
        # Real type present but no AES mention → likely plain
        return "no AES", f"wmbusmeters type: {type_val}", "ok"

    # 3. No useful data — gray, not yellow: this is informational, not a warning
    mode_note = ("In LISTEN mode bridge.sh stores type='listen' — real device description is only "
                 "available in SEARCH mode after wmbusmeters decodes the telegram.")
    return "—", mode_note, "muted"


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



def add_meter_to_options(meter_id: str, driver: str, key: str, meter_name: str = "") -> tuple[bool, str]:
    """Add a meter entry to addon options via HA Supervisor API.

    Writing directly to /data/options.json does NOT persist across restarts —
    Supervisor overwrites it from its own database on every addon start.
    The correct way is POST http://supervisor/addons/self/options with the full
    options payload. Supervisor then persists it and writes options.json on next start.
    """
    import urllib.request

    if not VALID_ID_RE.match(meter_id):
        return False, f"Invalid meter_id: {meter_id}"

    key = (key or "").strip()
    if key and not re.match(r"^[0-9A-Fa-f]{32}$", key):
        return False, f"Invalid AES key — must be exactly 32 HEX chars, got {len(key)}."

    # Read current state from options.json (Supervisor-written, most recent values)
    options = read_json(OPTIONS_JSON)
    if not isinstance(options, dict):
        options = {}

    meters = options.get("meters", [])
    if not isinstance(meters, list):
        meters = []

    # Check duplicate
    for m in meters:
        if isinstance(m, dict) and m.get("meter_id") == meter_id:
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
    meters.append(entry)
    options["meters"] = meters

    # Try Supervisor API first — this persists across restarts
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
                    # Also write locally so the next add_meter call reads the updated list
                    # (Supervisor may not have written options.json yet when user adds quickly)
                    write_json_atomic(OPTIONS_JSON, options)
                    key_info = f"key={key[:4]}..." if key else "no key"
                    msg = f"Meter {meter_id} ({driver}) added via Supervisor API. {key_info}. Restart addon to apply."
                    webui_add_event("ok", msg)
                    return True, msg
                body = resp.read().decode("utf-8", errors="replace")
                return False, f"Supervisor API returned HTTP {resp.status}: {body[:200]}"
        except Exception as exc:
            webui_add_event("error", f"Supervisor API options failed: {exc}, falling back to file write")

    # Fallback: write directly (works outside HA, e.g. plain Docker)
    write_json_atomic(OPTIONS_JSON, options)
    key_info = f"key={key[:4]}..." if key else "no key"
    msg = f"Meter {meter_id} ({driver}) added to options.json (file only — no SUPERVISOR_TOKEN). {key_info}."
    webui_add_event("warn", msg)
    return True, msg



def remove_meter_from_options(meter_id: str) -> tuple[bool, str]:
    """Remove a meter from options via HA Supervisor API."""
    import urllib.request

    if not VALID_ID_RE.match(meter_id):
        return False, f"Invalid meter_id: {meter_id}"

    options = read_json(OPTIONS_JSON)
    if not isinstance(options, dict):
        return False, "Cannot read options.json."

    meters = options.get("meters", [])
    if not isinstance(meters, list):
        return False, "No meters list in options."

    before = len(meters)
    meters = [m for m in meters if not (isinstance(m, dict) and m.get("meter_id") == meter_id)]
    if len(meters) == before:
        return False, f"Meter {meter_id} not found in options."

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
                    msg = f"Meter {meter_id} removed. Restart addon to apply."
                    webui_add_event("ok", msg)
                    return True, msg
                body = resp.read().decode("utf-8", errors="replace")
                return False, f"Supervisor API HTTP {resp.status}: {body[:200]}"
        except Exception as exc:
            webui_add_event("error", f"Supervisor API remove failed: {exc}")
            return False, f"Supervisor API failed: {exc}"

    # Fallback
    write_json_atomic(OPTIONS_JSON, options)
    msg = f"Meter {meter_id} removed (file only — no SUPERVISOR_TOKEN)."
    webui_add_event("warn", msg)
    return True, msg


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
        return False, "SUPERVISOR_TOKEN not available — add 'hassio_api: true' to config.yaml."
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


def discover_stability(candidates: list[dict]) -> tuple[str, str]:
    if not candidates:
        return "no candidates yet", "No candidates are stored yet. Let LISTEN mode run longer."
    newest = None
    for c in candidates:
        dt = parse_iso_time(str(c.get("last_seen") or ""))
        if dt and (newest is None or dt > newest):
            newest = dt
    if newest is None:
        return "unknown", "Candidate timestamps are missing or invalid."
    now = datetime.now(newest.tzinfo or timezone.utc)
    age_s = max(0, int((now - newest).total_seconds()))
    if age_s >= 600:
        return "stable", f"No new candidate has appeared for {fmt_interval(age_s)}. The candidate list probably stopped growing."
    if age_s >= 180:
        return "almost stable", f"No new candidate for {fmt_interval(age_s)}. Wait a bit more before deciding the list is complete."
    return "learning", f"Last new/updated candidate was {fmt_interval(age_s)} ago. Discovery is still active."


def event_level_for_ui(event: dict) -> tuple[str, str, str]:
    level = str(event.get("level") or "")
    message = str(event.get("message") or "")
    if level == "warn" and "Detected unconfigured meter" in message:
        return "candidate", "candidate", message.replace("Detected unconfigured meter", "Candidate detected")
    return level, level, message


def state(include_ignored: bool = False) -> dict:
    status = read_json(STATUS_JSON)
    options = read_options()
    meters = read_tsv(
        METERS_TSV,
        ["id", "name", "driver", "media", "value_key", "value", "last_seen", "discovery", "seen_count", "avg_interval_s", "seen_15m", "seen_60m"],
    )
    candidates = read_tsv(
        CANDIDATES_TSV,
        ["id", "driver", "type", "last_seen", "seen_count", "avg_interval_s", "seen_15m", "seen_60m"],
    )
    events = read_tsv(EVENTS_TSV, ["time", "level", "message"], limit=80, reverse=True)
    search_candidates = read_search_candidates()
    search_matches = read_search_matches()
    search_status = read_search_status()
    analysis = read_candidate_analysis()
    ignored = ignored_ids()
    for c in candidates:
        c["ignored"] = "true" if c.get("id") in ignored else "false"
        c["analysis"] = analysis.get(c.get("id") or "", {})

    # Remove candidates that are already in configured meters (decoded)
    configured_ids = {m.get("id") for m in meters if m.get("id")}
    candidates = [c for c in candidates if c.get("id") not in configured_ids]

    # Also remove candidates that are pending (in options.json but not yet decoded)
    # so the user doesn't see them twice (once in pending panel, once in candidate table)
    options_meter_ids = {
        str(m.get("meter_id") or "").strip().lower()
        for m in (options.get("meters") or [])
        if isinstance(m, dict) and m.get("meter_id")
    }
    if options_meter_ids:
        candidates = [c for c in candidates if str(c.get("id") or "").lower() not in options_meter_ids]

    if not include_ignored:
        candidates = [c for c in candidates if c.get("ignored") != "true"]
    meters = sorted(meters, key=lambda m: (m.get("last_seen") or ""), reverse=True)
    candidates = sorted(
        candidates,
        key=lambda c: (
            safe_int(c.get("seen_15m")),
            safe_int(c.get("seen_60m")),
            safe_int(c.get("seen_count")),
            c.get("last_seen") or "",
        ),
        reverse=True,
    )
    return {"status": status, "options": options, "meters": meters, "candidates": candidates, "events": events, "ignored": sorted(ignored), "search_candidates": search_candidates, "search_matches": search_matches, "search_status": search_status, "analysis": analysis}


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
    meter_count = len(meters)
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
        "mqtt_ok": mqtt_ok,
        "raw_ok": raw_ok,
        "wmbus_ok": wmbus_ok,
        "decoded_ok": decoded_ok,
        "discovery_ok": discovery_ok,
        "raw_15m": raw_15m,
    }


def status_dot(ok: bool, warn: bool = False) -> str:
    cls = "ok" if ok else ("warn" if warn else "bad")
    return f'<span class="dot {cls}"></span>'


def mini_bar(value: int, max_value: int) -> str:
    max_value = max(max_value, 1)
    pct = max(4, min(100, int((value / max_value) * 100)))
    return f'<div class="mini-bar"><span style="width:{pct}%"></span></div>'


def link(path: str, **params: object) -> str:
    qs = {k: str(v) for k, v in params.items() if v is not None and str(v) != ""}
    return path + (("?" + urlencode(qs)) if qs else "")


def nav(active: str, lang: str) -> str:
    items = [
        (".", tr(lang, "nav_dashboard"), "dashboard"),
        ("meters", tr(lang, "nav_meters"), "meters"),
        ("discover", tr(lang, "nav_discover"), "discover"),
        ("search", tr(lang, "nav_search"), "search"),
        ("logs", tr(lang, "nav_logs"), "logs"),
        ("settings", tr(lang, "nav_settings"), "settings"),
        ("about", tr(lang, "nav_about"), "about"),
    ]
    return "".join(f'<a class="{("active" if key == active else "")}" href="{href}">{label}</a>' for href, label, key in items)


def shell(active: str, body: str, updated_at: str, refresh: bool = True, lang: str = DEFAULT_LANG, localize_body: bool = True) -> str:
    lang = lang if lang in SUPPORTED_LANGS else DEFAULT_LANG
    if localize_body:
        body = localize_html(body, lang)
    # discover: smart refresh — reload only when tab is hidden, every 60s
    # other pages: standard 15s meta refresh
    if refresh and active == "discover":
        refresh_meta = ""
        smart_refresh_js = "<script>document.addEventListener('visibilitychange',function(){if(!document.hidden)return;if(!window._discoverTimer)window._discoverTimer=setTimeout(function(){location.reload()},60000);});document.addEventListener('visibilitychange',function(){if(document.hidden)return;clearTimeout(window._discoverTimer);window._discoverTimer=null;});</script>"
    elif refresh:
        refresh_meta = '<meta http-equiv="refresh" content="15">'
        smart_refresh_js = ""
    else:
        refresh_meta = ""
        smart_refresh_js = ""
    return f'''<!doctype html>
<html lang="{esc(lang)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  {refresh_meta}
  <title>wMBus MQTT Bridge</title>
  <style>
    :root {{ --bg:#0f171d; --top:#0b1920; --panel:#151f27; --panel2:#1a2731; --line:#263c4a; --line2:#31536a; --text:#e8f1f8; --muted:#95adbd; --ok:#24d26f; --warn:#f3c84b; --bad:#ff646b; --cyan:#00bcd4; --purple:#963de8; }}
    * {{ box-sizing:border-box; }}
    body {{ margin:0; font-family:system-ui,-apple-system,Segoe UI,sans-serif; background:var(--bg); color:var(--text); }}
    .app {{ min-height:100vh; }} .main {{ min-width:0; }}
    .topbar {{ min-height:64px; background:var(--top); border-bottom:1px solid #16313d; display:flex; align-items:flex-end; padding:0 28px; gap:24px; position:sticky; top:0; z-index:10; }}
    .top-left {{ align-self:center; display:flex; align-items:center; gap:12px; margin-right:8px; font-size:19px; color:#f2f7fb; white-space:nowrap; }}
    .tabs {{ display:flex; gap:20px; height:100%; align-items:flex-end; overflow-x:auto; }}
    .tabs a {{ color:#aebfca; text-decoration:none; padding:0 12px 15px; height:48px; font-size:13px; font-weight:700; letter-spacing:.02em; border-bottom:2px solid transparent; white-space:nowrap; }}
    .tabs a.active {{ color:#24c7ff; border-bottom-color:#00bcd4; }} .kebab {{ margin-left:auto; align-self:center; color:#b9c7d1; font-size:22px; }}
    .lang-switch {{ align-self:center; display:flex; gap:4px; margin-left:auto; }} .lang-switch a {{ color:#9fb4c1; text-decoration:none; border:1px solid #2b4656; border-radius:999px; padding:4px 7px; font-size:11px; font-weight:800; }} .lang-switch a.active {{ color:#32cfff; border-color:#176b8c; background:#113349; }}
    main {{ padding:18px 28px 34px; max-width:1420px; }} .updated {{ float:right; color:#8ea4b1; font-size:11px; margin-top:-8px; }}
    h1 {{ margin:0 0 4px; font-size:28px; }} .sub {{ color:var(--muted); font-size:14px; }}
    .grid3 {{ display:grid; grid-template-columns:1.05fr 1fr .95fr; gap:14px; margin-top:18px; }} .grid2 {{ display:grid; grid-template-columns:1.55fr .85fr; gap:14px; margin-top:14px; }}
    .card {{ background:var(--panel); border:1px solid #213544; border-radius:8px; padding:18px; box-shadow:0 2px 8px rgba(0,0,0,.18); }} .card h2 {{ margin:0 0 16px; font-size:16px; }}
    .status-list {{ display:grid; gap:13px; }} .status-row {{ display:grid; grid-template-columns:22px 1fr auto; align-items:center; gap:8px; color:#dfeaf2; font-size:14px; }} .status-row .right {{ color:#d9e8f2; font-size:13px; }}
    .dot {{ width:14px; height:14px; border-radius:50%; display:inline-block; background:var(--bad); box-shadow:0 0 10px rgba(255,100,107,.25); }} .dot.ok {{ background:var(--ok); }} .dot.warn {{ background:var(--warn); }}
    .last-line {{ border-top:1px solid #243641; margin-top:14px; padding-top:12px; display:grid; grid-template-columns:1fr auto; gap:8px; color:#c8d9e4; font-size:13px; }}
    .pill {{ display:inline-block; border-radius:999px; padding:3px 8px; font-size:11px; font-weight:800; }} .pill.raw {{ background:#7a37db; color:#fff; }} .pill.ok {{ background:#0e3f22; color:#31e17d; }} .pill.warn {{ background:#3b3210; color:#f5cd55; }} .pill.bad {{ background:#3b1010; color:#ff8c98; }} .pill.muted {{ background:#1e2e38; color:#7a99aa; }}
    .metric-list {{ display:grid; gap:11px; }} .metric-row {{ display:grid; grid-template-columns:46px 1fr 120px; gap:12px; align-items:center; }}
    .metric-icon {{ width:36px; height:36px; border-radius:8px; display:grid; place-items:center; background:#123247; color:#27c4ff; font-size:20px; }} .metric-icon.purple {{ background:#321b4b; color:#b05cff; }} .metric-icon.green {{ background:#123922; color:#35de7a; }}
    .metric-title {{ color:#aebfca; font-size:13px; }} .metric-value {{ font-size:24px; font-weight:800; line-height:1.1; }} .mini-bar {{ height:8px; background:#0f1a21; border:1px solid #25404f; border-radius:999px; overflow:hidden; }} .mini-bar span {{ display:block; height:100%; background:#00bcd4; border-radius:999px; }}
    .discovery-kv {{ display:grid; grid-template-columns:1fr auto; gap:14px; font-size:14px; }} .discovery-kv span:nth-child(odd) {{ color:#b5c7d2; }} .discovery-kv span:nth-child(even) {{ font-weight:700; }} .button {{ border:1px solid #087aa8; background:#102b3b; color:#19c4ff; border-radius:4px; padding:10px 12px; text-align:center; font-weight:800; font-size:12px; margin-top:22px; text-decoration:none; display:inline-block; }}
    .button.danger {{ border-color:#974554; color:#ff8c98; background:#2a1720; }} .button.good {{ border-color:#168b4d; color:#4df08d; background:#102819; }}
    .form-grid {{ display:grid; grid-template-columns:1fr 1fr; gap:12px; }} .field label {{ display:block; color:#9fb4c1; font-size:12px; margin-bottom:6px; }} .field input {{ width:100%; background:#0f1a21; border:1px solid #2b4656; color:#e8f1f8; border-radius:6px; padding:10px; font-size:14px; }} .notice {{ border:1px solid #2d5368; background:#102532; border-radius:8px; padding:12px; color:#cfe1eb; margin-top:12px; }} .notice.warn {{ border-color:#6d5b1c; background:#2b2715; }} .notice.good {{ border-color:#23633c; background:#102819; }}
    .button.inline {{ margin-top:0; text-decoration:none; display:inline-flex; align-items:center; justify-content:center; white-space:nowrap; }}
    .section-head {{ display:flex; justify-content:space-between; align-items:center; margin-bottom:12px; gap:12px; }} .section-head h2 {{ margin:0; font-size:16px; }} .filters {{ display:flex; gap:8px; align-items:center; color:#9eafba; font-size:12px; flex-wrap:wrap; }} .filter {{ padding:5px 10px; border:1px solid #2b4656; border-radius:999px; color:#cbd9e1; text-decoration:none; }} .filter.active {{ background:#113349; color:#32cfff; border-color:#176b8c; }}
    .meter-grid {{ display:grid; grid-template-columns:repeat(auto-fit, minmax(280px, 1fr)); gap:12px; }} .meter-card {{ background:#121b22; border:1px solid #243744; border-radius:8px; padding:16px; min-height:188px; display:grid; grid-template-rows:auto 1fr auto; }} .meter-top {{ display:grid; grid-template-columns:42px 1fr auto; gap:12px; align-items:start; }} .micon {{ width:38px; height:38px; display:grid; place-items:center; font-size:27px; border-radius:10px; background:#102d3d; }} .mname {{ font-weight:800; }} .mid {{ color:#b5c9d4; font-size:12px; line-height:1.45; }} .online {{ color:#2de36f; font-size:12px; font-weight:800; text-align:right; }} .value-main {{ font-size:30px; font-weight:800; margin:16px 0 6px; }} .value-key {{ color:#a9bac5; font-size:12px; }} .meter-meta {{ display:grid; grid-template-columns:1fr 1fr; gap:8px 16px; border-top:1px solid #253946; padding-top:12px; color:#c9d7df; font-size:12px; }} .meter-meta strong {{ display:block; color:#fff; font-size:13px; margin-top:3px; }} .entity-row {{ border-top:1px solid #253946; margin:12px -16px -16px; padding:10px 16px; display:flex; justify-content:space-between; align-items:center; color:#b8c8d2; font-size:12px; }} .published {{ background:#0f3f21; color:#36dc73; border-radius:4px; padding:7px 18px; font-weight:800; }}
    .table-wrap {{ overflow:auto; }} .table {{ width:100%; border-collapse:collapse; font-size:13px; min-width:860px; }} .table th,.table td {{ padding:11px 10px; border-bottom:1px solid #273944; text-align:left; vertical-align:middle; }} .table th {{ color:#8fa3af; font-weight:700; }} .table td {{ color:#dce8ef; }} .table .muted {{ color:#90a7b5; font-size:12px; display:block; margin-top:3px; }} .small-button {{ display:inline-block; border:1px solid #087aa8; color:#19c4ff; background:#102b3b; border-radius:4px; padding:7px 10px; margin:2px 4px 2px 0; font-size:11px; font-weight:800; text-decoration:none; cursor:pointer; }} .small-button.danger {{ border-color:#974554; color:#ff8c98; }}
    .candidate-summary {{ display:grid; grid-template-columns:auto 1fr minmax(260px,.9fr) auto; align-items:center; gap:18px; }} .summary-big {{ font-size:42px; font-weight:900; color:#fff; line-height:1; }} .summary-title {{ font-size:16px; font-weight:800; }} .summary-sub {{ color:var(--muted); font-size:13px; margin-top:4px; }} .summary-best {{ display:grid; gap:3px; color:#cfe1eb; font-size:12px; }} .summary-best strong {{ font-size:15px; color:#fff; }}
    .event-row {{ display:grid; grid-template-columns:180px 82px 1fr; gap:10px; padding:9px 0; border-bottom:1px solid #273944; font-size:13px; }} .event-row strong.ok {{ color:var(--ok); }} .event-row strong.candidate,.event-row strong.warn {{ color:var(--warn); }} .event-row strong.error {{ color:var(--bad); }} .legend {{ margin:8px 0 12px; padding:10px 12px; border:1px dashed var(--line2); border-radius:8px; color:var(--muted); font-size:12px; display:grid; gap:4px; }} .legend b {{ color:var(--text); }} .empty {{ padding:20px; border:1px dashed #2c4555; border-radius:8px; color:#91a7b4; }}
    .footer {{ margin-top:14px; display:grid; grid-template-columns:1fr 1fr 1fr; gap:10px; background:#121d24; border:1px solid #213544; border-radius:8px; padding:11px 16px; color:#cbd9e1; font-size:12px; }} .about-text {{ color:#c5d5de; line-height:1.6; font-size:14px; }} .codebox, textarea.codebox {{ background:#0e151b; border:1px solid #253946; border-radius:8px; padding:14px; color:#c9d7df; font-family:ui-monospace,SFMono-Regular,Consolas,monospace; font-size:13px; white-space:pre-wrap; width:100%; }}
    .toast {{ position:fixed; right:18px; bottom:18px; background:#0d3321; color:#6ff0a2; border:1px solid #1b6b42; padding:10px 14px; border-radius:8px; display:none; z-index:30; }}
    @media (max-width:1100px) {{ .topbar {{ padding:0 14px; overflow-x:auto; }} main {{ padding:14px; }} .grid3,.grid2 {{ grid-template-columns:1fr; }} .tabs {{ gap:8px; }} .tabs a {{ white-space:nowrap; }} .event-row {{ grid-template-columns:1fr; gap:3px; }} .candidate-summary {{ grid-template-columns:1fr; align-items:start; }} .button.inline {{ width:100%; }} .metric-row {{ grid-template-columns:46px 1fr 80px; }} }}
  </style>
</head>
<body>
  <div class="app">
    <div class="main"><div class="topbar"><div class="top-left"><span>wMBus MQTT Bridge <span style="font-size:11px;color:#8ea4b1;">v{esc(ADDON_VERSION)}</span>{"<span style='font-size:10px;font-weight:800;background:#3b2010;color:#f3c84b;border-radius:4px;padding:2px 6px;margin-left:5px;'>DEV</span>" if ADDON_IS_DEV else ""}</span></div><nav class="tabs">{nav(active, lang)}</nav>{lang_switcher(lang)}<div class="kebab">⋮</div></div><main><div class="updated">{esc(tr(lang, "updated_label"))} {esc(fmt_ts(updated_at) if updated_at else tr(lang, "unknown_value"))}</div>{body}</main></div>
  </div>
  <div id="toast" class="toast">{esc(tr(lang, "copied_toast"))}</div>
  <script>
    async function copyText(text) {{
      try {{ await navigator.clipboard.writeText(text); showToast({json.dumps(tr(lang, "copied_config_toast"))}); }}
      catch (e) {{ window.prompt({json.dumps(tr(lang, "copy_config_prompt"))}, text); }}
    }}
    function showToast(text) {{
      const t = document.getElementById('toast'); t.textContent = text; t.style.display = 'block';
      setTimeout(() => {{ t.style.display = 'none'; }}, 1800);
    }}
    function setLang(code) {{
      const url = new URL(window.location.href);
      url.searchParams.set('lang', code);
      window.location.href = url.toString();
    }}
  </script>
  {smart_refresh_js}
</body>
</html>'''


def filter_by_media(rows: list[dict], media: str) -> list[dict]:
    media = media if media in MEDIA_FILTERS else "all"
    if media == "all":
        return rows
    if media == "water":
        return [r for r in rows if media_class(r.get("media", "") or r.get("type", ""), r.get("driver", "")) in ("water", "warm_water")]
    return [r for r in rows if media_class(r.get("media", "") or r.get("type", ""), r.get("driver", "")) == media]


def is_supervisor_mode() -> bool:
    """True when running under HA Supervisor (token injected into env).

    Drives Docker-aware UI: when False we hide RESTART buttons that would
    silently fail and show a 'restart the container manually' hint instead.
    """
    return bool(os.environ.get("SUPERVISOR_TOKEN", "").strip())


def render_restart_block(lang: str, button_label_key: str = "restart_addon", extra_note_html: str = "") -> str:
    """Render restart UI appropriate for the current mode.

    HA Supervisor mode: POST form with button + supervisor_api_notice (when
    extra_note_html is empty, default notice is shown).
    Docker mode: a hint card with `docker restart <container>` snippet and no
    button (the button would silently fail without SUPERVISOR_TOKEN).
    """
    if is_supervisor_mode():
        notice = extra_note_html or (
            f'<div class="notice" style="margin-top:8px;">{esc(tr(lang, "supervisor_api_notice"))}</div>'
        )
        return (
            f'<form method="post" action="restart-bridge" style="margin-top:8px;">'
            f'<button class="button danger" type="submit" style="margin:0;">{esc(tr(lang, button_label_key))}</button>'
            f'</form>{notice}'
        )
    return (
        f'<div class="notice warn" style="margin-top:8px;">'
        f'<b>{esc(tr(lang, "docker_mode_title"))}</b><br>'
        f'{esc(tr(lang, "docker_restart_hint"))}<br>'
        f'<code style="display:inline-block;margin-top:6px;padding:4px 8px;background:#0e151b;border-radius:4px;">docker restart &lt;container&gt;</code>'
        f'</div>'
    )


def pending_meters(data: dict) -> list[dict]:
    """Meters saved in options.json but not yet decoded by wmbusmeters."""
    # Read directly from OPTIONS_JSON for freshness — state() may have cached stale data
    options = read_json(OPTIONS_JSON)
    if not isinstance(options, dict):
        options = {}
    configured = options.get("meters", []) if isinstance(options.get("meters"), list) else []
    if not configured:
        return []

    # If bridge started AFTER options.json was last written, it already loaded the meters.
    # Pending panel should only show when meters were added AFTER the last bridge start.
    try:
        options_mtime = OPTIONS_JSON.stat().st_mtime
        status_mtime  = STATUS_JSON.stat().st_mtime
        if status_mtime > options_mtime:
            # bridge restarted after options were saved — no longer pending
            return []
    except OSError:
        pass

    decoded_ids = set()
    for m in data.get("meters", []):
        mid = str(m.get("id") or "").lower()
        if mid:
            decoded_ids.add(mid)
            bare = mid[6:] if mid.startswith("meter_") else mid
            decoded_ids.add(bare)
    out: list[dict] = []
    for entry in configured:
        if not isinstance(entry, dict):
            continue
        mid = str(entry.get("meter_id") or "").strip()
        if not mid or mid.lower() in decoded_ids:
            continue
        out.append({
            "id": mid,
            "name": str(entry.get("id") or mid),
            "driver": str(entry.get("type") or "auto"),
            "has_key": bool((entry.get("key") or "").strip()),
        })
    return out
def render_pending_panel(pending: list[dict], lang: str = DEFAULT_LANG) -> str:
    if not pending:
        return ''
    rows = []
    for m in pending:
        key_label = tr(lang, "aes_key_set") if m["has_key"] else tr(lang, "no_aes_key")
        rows.append(
            f"<tr><td><strong>{esc(m['id'])}</strong>"
            f"<span class='muted'>{esc(m['name'])}</span></td>"
            f"<td>{esc(m['driver'])}</td>"
            f"<td><span class='pill muted'>{esc(key_label)}</span></td></tr>"
        )
    return (
        f'<section class="card notice warn" style="margin-top:14px;">'
        f'<h2 style="margin-top:0;">{esc(tr(lang, "pending_title"))} ({len(pending)})</h2>'
        f'<div class="sub" style="margin-bottom:12px;">{esc(tr(lang, "pending_text"))}</div>'
        f'<div class="table-wrap"><table class="table">'
        f'<thead><tr><th>{esc(tr(lang, "meter_id"))}</th>'
        f'<th>{esc(tr(lang, "driver"))}</th><th>AES</th></tr></thead>'
        f'<tbody>{"".join(rows)}</tbody></table></div>'
        f'{render_restart_block(lang)}'
        f'</section>'
    )


def render_pending_meter_card(m: dict, lang: str = DEFAULT_LANG) -> str:
    mc = media_class(m.get("media", "") or m.get("type", ""), m.get("driver", ""))
    icon = media_icon(m.get("media", "") or m.get("type", ""), m.get("driver", ""))
    icon_bg = {"electricity": "#1a2a3b", "heat": "#3b2010", "water": "#0f2a3b", "warm_water": "#3b2010"}.get(mc, "#2a2a2a")
    icon_color = {"electricity": "#60b4f0", "heat": "#f07840", "water": "#40c0e0", "warm_water": "#f09040"}.get(mc, "#888")
    return f'''
    <article class="meter-card" style="opacity:0.75;border-style:dashed;border-color:#f3c84b44;">
      <div class="meter-top">
        <div class="micon" style="background:{icon_bg};color:{icon_color};">{icon}</div>
        <div>
          <div class="mname">{esc(m["name"])}</div>
          <div class="mid">{esc(m["id"])}<br>{esc(m["driver"])}</div>
        </div>
        <div class="online" style="color:#f3c84b;">{esc(tr(lang, "pending_label"))}<br><span class="mid">{esc(tr(lang, "pending_short"))}</span></div>
      </div>
      <div><div class="value-key">—</div><div class="value-main">—</div></div>
      <div><div class="meter-meta"><span>AES<strong>{esc(tr(lang, "aes_key_set") if m["has_key"] else tr(lang, "no_aes_key"))}</strong></span></div>
      <div class="entity-row"><span class="pill warn">{esc(tr(lang, "pending_short"))}</span></div>
      </div>
    </article>'''


def render_filter_links(base: str, active: str, lang: str = DEFAULT_LANG) -> str:
    active = active if active in MEDIA_FILTERS else "all"
    labels = [("all", tr(lang, "all")), ("water", tr(lang, "water")), ("electricity", tr(lang, "electricity")), ("heat", tr(lang, "heat")), ("other", tr(lang, "other"))]
    return f'<div class="filters"><span>{esc(tr(lang, "show"))}</span>' + ''.join(
        f'<a class="filter {"active" if key == active else ""}" href="{link(base, media=key)}">{label}</a>'
        for key, label in labels
    ) + '</div>'


def render_system_status(model: dict) -> str:
    mqtt = model["mqtt"]
    pipe = model["pipe"]
    cfg = model["cfg"]
    meter_count = model["meter_count"]
    candidate_count = model["candidate_count"]
    return f'''
    <section class="card"><h2>System status</h2><div class="status-list">
      <div class="status-row">{status_dot(model['mqtt_ok'])}<span>MQTT connected</span><span class="right">broker: {esc(mqtt.get('host') or '')}</span></div>
      <div class="status-row">{status_dot(model['raw_ok'])}<span>RAW telegrams received</span><span class="right">{model['raw_count']} this session</span></div>
      <div class="status-row">{status_dot(model['wmbus_ok'])}<span>wmbusmeters running</span><span class="right">{'LISTEN mode' if meter_count == 0 and candidate_count else 'configured decoder'}</span></div>
      <div class="status-row">{status_dot(model['decoded_ok'], warn=candidate_count > 0)}<span>Decoded JSON received</span><span class="right">{model['decoded_count']}</span></div>
      <div class="status-row">{status_dot(meter_count > 0, warn=candidate_count > 0)}<span>Configured meters</span><span class="right">{meter_count}</span></div>
      <div class="status-row">{status_dot(model['discovery_ok'], warn=candidate_count > 0)}<span>HA Discovery published</span><span class="right">{'yes' if model['discovery_ok'] else 'not yet'}</span></div>
      <div class="status-row"><span style="width:14px;display:inline-block;"></span><span>MQTT topic</span><span class="right"><code style="font-size:11px;background:#0e151b;padding:2px 6px;border-radius:4px;">{esc(cfg.get("raw_topic") or "—")}</code></span></div>
      <div class="status-row">{status_dot(model["raw_15m"] > 0)}<span>Telegramy RAW (15 min)</span><span class="right">{model["raw_15m"]}</span></div>
    </div><div class="last-line"><span>Last RAW telegram</span><span>{esc(fmt_ts(pipe.get('last_raw_seen') or '') or 'not seen this session')} <span class="pill raw">RAW</span></span></div></section>'''


def render_stats(model: dict) -> str:
    raw = model['raw_count']
    decoded = model['decoded_count']
    candidates = model['candidate_count']
    meters = model['meter_count']
    max_value = max(raw, decoded, candidates, meters, 1)
    return f'''
    <section class="card"><h2>Statistics</h2><div class="metric-list">
      <div class="metric-row"><div class="metric-icon">📡</div><div><div class="metric-title">RAW telegrams</div><div class="metric-value">{raw}</div></div>{mini_bar(raw, max_value)}</div>
      <div class="metric-row"><div class="metric-icon">⌘</div><div><div class="metric-title">Decoded JSON</div><div class="metric-value">{decoded}</div></div>{mini_bar(decoded, max_value)}</div>
      <div class="metric-row"><div class="metric-icon purple">▣</div><div><div class="metric-title">Detected candidates</div><div class="metric-value">{candidates}</div></div>{mini_bar(candidates, max_value)}</div>
      <div class="metric-row"><div class="metric-icon green">◇</div><div><div class="metric-title">Configured meters</div><div class="metric-value">{meters}</div></div>{mini_bar(meters, max_value)}</div>
    </div><div class="sub" style="margin-top:12px;font-size:12px;">Bars are relative to the largest visible value, not historical charts.</div></section>'''


def render_discovery(model: dict) -> str:
    cfg = model["cfg"]
    return f'''
    <section class="card"><h2>Discovery status</h2><div class="discovery-kv">
      <span>Discovery</span><span class="{('pill ok' if model['discovery_ok'] else 'pill warn')}">{'published' if model['discovery_ok'] else 'waiting'}</span>
      <span>Prefix</span><span>{esc(cfg.get('discovery_prefix') or '')}</span><span>State prefix</span><span>{esc(cfg.get('state_prefix') or '')}</span>
      <span>Configured meters</span><span>{model['meter_count']}</span><span>Detected candidates</span><span>{model['candidate_count']}</span>
    </div><a class="button" href="settings">OPEN SETTINGS</a></section>'''


def _signal_bars(seen_15m: int) -> str:
    """Return 4 signal strength bars based on seen_15m count."""
    n = 4 if seen_15m >= 10 else 3 if seen_15m >= 5 else 2 if seen_15m >= 2 else 1
    ok = "#4df08d"
    off = "#2a3a3a"
    bars = "".join(
        f'<span style="display:inline-block;width:4px;height:{4+i*3}px;background:{"'+ ok +'" if i < n else "'+ off +'"};border-radius:1px;vertical-align:bottom;margin-right:1px;"></span>'
        for i in range(4)
    )
    return f'<span style="display:inline-flex;align-items:flex-end;height:16px;gap:1px;">{bars}</span>'


def unit_from_key(value_key: str) -> str:
    """Extract display unit (with icon) from wmbusmeters field name suffix.
    Longest suffixes checked first to avoid false matches (e.g. _kwh before _kw).
    """
    k = (value_key or "").lower()
    if k.endswith("_kvarh"):   return "kVARh ⚡"
    if k.endswith("_kvah"):    return "kVAh ⚡"
    if k.endswith("_m3c"):     return "m³°C 🌡"
    if k.endswith("_m3ch"):    return "m³°C/h 🌡"
    if k.endswith("_m3h"):     return "m³/h 💧"
    if k.endswith("_mjh"):     return "MJ/h 🔥"
    if k.endswith("_kvar"):    return "kVAR ⚡"
    if k.endswith("_kva"):     return "kVA ⚡"
    if k.endswith("_kwh"):     return "kWh ⚡"
    if k.endswith("_kw"):      return "kW ⚡"
    if k.endswith("_wh"):      return "Wh ⚡"
    if k.endswith("_w"):       return "W ⚡"
    if k.endswith("_lh"):      return "l/h 💧"
    if k.endswith("_jh"):      return "J/h 🔥"
    if k.endswith("_gj"):      return "GJ 🔥"
    if k.endswith("_mj"):      return "MJ 🔥"
    if k.endswith("_dbm"):     return "dBm 📡"
    if k.endswith("_hca"):     return "hca 🔥"
    if k.endswith("_pct"):     return "% 📊"
    if k.endswith("_ppm"):     return "ppm 📊"
    if k.endswith("_rh"):      return "RH% 💧"
    if k.endswith("_hz"):      return "Hz ⚡"
    if k.endswith("_bar"):     return "bar 🌡"
    if k.endswith("_pa"):      return "Pa 🌡"
    if k.endswith("_m3"):      return "m³ 💧"
    if k.endswith("_mol"):     return "mol 🧪"
    if k.endswith("_min"):     return "min ⏱"
    if k.endswith("_rad"):     return "rad 📐"
    if k.endswith("_deg"):     return "° 📐"
    if k.endswith("_counter"): return "cnt 📊"
    if k.endswith("_factor"):  return "× 📊"
    if k.endswith("_nr"):      return "nr 📊"
    if k.endswith("_kg"):      return "kg ⚖"
    if k.endswith("_cd"):      return "cd 💡"
    if k.endswith("_v"):       return "V ⚡"
    if k.endswith("_a"):       return "A ⚡"
    if k.endswith("_k"):       return "K 🌡"
    if k.endswith("_c"):       return "°C 🌡"
    if k.endswith("_f"):       return "°F 🌡"
    if k.endswith("_l"):       return "l 💧"
    if k.endswith("_m"):       return "m 📏"
    if k.endswith("_s"):       return "s ⏱"
    if k.endswith("_h"):       return "h ⏱"
    if k.endswith("_d"):       return "d 📅"
    if k.endswith("_y"):       return "y 📅"
    return ""


def render_meter_card(m: dict, lang: str = DEFAULT_LANG, cfg: dict = {}) -> str:
    icon = media_icon(m.get("media", ""), m.get("driver", ""))
    mc = media_class(m.get("media", ""), m.get("driver", ""))
    icon_bg = {"electricity": "#1a2a3b", "heat": "#3b2010", "water": "#0f2a3b", "warm_water": "#2a1f0a"}.get(mc, "#1a2a2a")
    icon_color = {"electricity": "#60b4f0", "heat": "#f07840", "water": "#40c0e0", "warm_water": "#f09040"}.get(mc, "#888")
    seen_15m = int(m.get("seen_15m") or 0)
    seen_60m = int(m.get("seen_60m") or 0)
    if seen_15m > 0:
        status_label = tr(lang, "online_label")
        status_color = "#2de36f"
    elif seen_60m > 0:
        status_label = tr(lang, "silent_label")
        status_color = "#f3c84b"
    else:
        status_label = tr(lang, "offline_label")
        status_color = "#ff646b"
    signal = _signal_bars(seen_15m)
    meter_id = m.get("id") or ""
    unit = unit_from_key(m.get("value_key") or "")
    value_str = m.get('value') or '—'
    value_display = f"{value_str} {unit}" if unit and value_str != '—' else value_str
    raw_topic = (cfg.get("raw_topic") or "").replace("+", esc(meter_id))
    confirm_msg = tr(lang, "confirm_delete").format(mid=meter_id)
    return f'''
    <article class="meter-card"><div class="meter-top"><div class="micon" style="background:{icon_bg};color:{icon_color};">{icon}</div><div><div class="mname">{esc(m.get('name') or m.get('id'))}</div><div class="mid">{esc(m.get('id'))}<br>{esc(m.get('driver'))}</div></div><div class="online" style="color:{status_color};">{esc(status_label)} {signal}<br><span class="mid">{fmt_ts(m.get('last_seen') or '')}</span></div></div>
      <div><div class="value-key">{esc(m.get('value_key') or tr(lang, "value_label"))}</div><div class="value-main">{esc(value_display)}</div></div>
      <div><div style="font-size:10px;color:#607a88;margin-bottom:6px;font-family:monospace;">{esc(raw_topic)}</div><div class="meter-meta"><span>{esc(tr(lang, "media"))}<strong>{esc(tr_media(lang, media_class(m.get('media',''), m.get('driver',''))))}</strong></span><span>{esc(tr(lang, "reception"))}<strong>{esc(fmt_interval(m.get('avg_interval_s')))}</strong></span><span>{esc(tr(lang, "seen_15m_label"))}<strong>{esc(m.get('seen_15m') or '0')}</strong></span><span>{esc(tr(lang, "seen_60m_label"))}<strong>{esc(m.get('seen_60m') or '0')}</strong></span></div>
      <div class="entity-row"><span class="published">{esc(m.get('discovery') or tr(lang, "state_label"))}</span>
        <form method="post" action="remove-meter" style="margin:0;" onsubmit="return confirm({json.dumps(confirm_msg)});">
          <input type="hidden" name="meter_id" value="{esc(meter_id)}">
          <button class="small-button danger" type="submit">{esc(tr(lang, "delete"))}</button>
        </form>
      </div></div></article>'''


def render_configured_meters(meters: list[dict], max_items: int | None = None, lang: str = DEFAULT_LANG, pending: list[dict] | None = None, cfg: dict = {}) -> str:
    shown = meters if max_items is None else meters[:max_items]
    pending = pending or []
    if not shown and not pending:
        return f'<div class="empty">{esc(tr(lang, "no_configured_meters_yet"))}</div>'
    cards = [render_meter_card(m, lang, cfg) for m in shown]
    cards += [render_pending_meter_card(m, lang) for m in pending]
    return '<div class="meter-grid">' + ''.join(cards) + '</div>'


def render_search_cache_table(rows: list[dict], max_items: int | None = None, lang: str = DEFAULT_LANG) -> str:
    shown = rows if max_items is None else rows[:max_items]
    if not shown:
        return f'<div class="empty">{esc(tr(lang, "no_search_cache_yet"))}</div>'
    body = []
    for row in shown:
        driver = row.get("driver") or "auto"
        media  = row.get("media") or ""
        body.append(
            f"<tr><td><strong>{esc(row.get('id'))}</strong><span class='muted'>from /data/search_candidates.tsv</span></td>"
            f"<td>{esc(driver)}</td><td>{media_icon(media, driver)} {esc(tr_media(lang, media_class(media, driver)))}</td>"
            f"<td><span class='pill ok'>{esc(tr(lang, 'used_by_search_label'))}</span><span class='muted'>{esc(tr(lang, 'loaded_as_temp_meter'))}</span></td></tr>"
        )
    return f"<div class='table-wrap'><table class='table'><thead><tr><th>{esc(tr(lang, 'meter_id'))}</th><th>{esc(tr(lang, 'driver'))}</th><th>{esc(tr(lang, 'media'))}</th><th>{esc(tr(lang, 'role_label'))}</th></tr></thead><tbody>{''.join(body)}</tbody></table></div>"


def render_search_matches(rows: list[dict], lang: str = DEFAULT_LANG) -> str:
    if not rows:
        return f'<div class="empty">{esc(tr(lang, "no_search_matches_yet"))}</div>'
    body = []
    for row in rows:
        body.append(
            f"<tr><td>{esc(row.get('time'))}</td><td><strong>{esc(row.get('id'))}</strong></td><td>{esc(row.get('driver'))}</td>"
            f"<td>{esc(row.get('field'))}</td><td>{esc(row.get('value_m3'))}</td><td>{esc(row.get('expected_m3'))}</td>"
            f"<td>{esc(row.get('diff_m3'))}</td><td>{esc(row.get('tolerance_m3'))}</td></tr>"
        )
    return (
        f"<div class='table-wrap'><table class='table'><thead><tr>"
        f"<th>{esc(tr(lang, 'time_label'))}</th><th>{esc(tr(lang, 'id_label'))}</th><th>{esc(tr(lang, 'driver'))}</th>"
        f"<th>{esc(tr(lang, 'field_label'))}</th><th>{esc(tr(lang, 'value_m3_label'))}</th><th>{esc(tr(lang, 'expected_short'))}</th>"
        f"<th>{esc(tr(lang, 'diff_label'))}</th><th>{esc(tr(lang, 'tolerance_short'))}</th>"
        f"</tr></thead><tbody>{''.join(body)}</tbody></table></div>"
    )



def render_candidates_table(candidates: list[dict], max_items: int | None = None, show_restore: bool = False, lang: str = DEFAULT_LANG) -> str:
    shown = candidates if max_items is None else candidates[:max_items]
    if not shown:
        return f'<div class="empty">{esc(tr(lang, "no_candidates_yet"))}</div>'
    rows = []
    for c in shown:
        mid = c.get('id') or ''
        driver = c.get('driver') or 'auto'
        mclass = media_class(c.get('type', ''), driver)
        enc, enc_note, enc_cls = candidate_encryption_hint(c)
        if show_restore:
            actions = f'<a class="small-button" href="{link("unignore", id=mid)}">{esc(tr(lang, "restore"))}</a>'
        else:
            # Inline ADD only when the candidate doesn't need an AES key —
            # AES-required candidates still go through /candidate so the user
            # can paste the 32-char HEX key before submitting.
            add_inline = ''
            if enc_cls != 'bad':
                mtype = (c.get('type') or '').strip()
                mtype_lc = mtype.lower()
                last4 = mid[-4:]
                if 'warm water' in mtype_lc or 'hot water' in mtype_lc:
                    suggested_name = f"Warm_Water_{last4}"
                elif 'cold water' in mtype_lc:
                    suggested_name = f"Cold_Water_{last4}"
                elif 'water' in mtype_lc or 'hydro' in mtype_lc:
                    suggested_name = f"Cold_Water_{last4}"
                elif 'electric' in mtype_lc:
                    suggested_name = f"Electricity_{last4}"
                elif 'heat' in mtype_lc:
                    suggested_name = f"Heat_{last4}"
                else:
                    suggested_name = f"meter_{mid}" if not mtype else f"{mtype[:12]}_{last4}"
                popup_id = f"add-popup-{esc(mid)}"
                add_inline = (
                    f'<span style="position:relative;display:inline-block;">'
                    f'<button class="small-button" type="button" '
                    f'onclick="document.getElementById(\'{popup_id}\').style.display=\'block\';'
                    f'this.style.display=\'none\';">'
                    f'{esc(tr(lang, "add_meter_short_btn"))}</button>'
                    f'<span id="{popup_id}" style="display:none;position:absolute;right:0;top:28px;'
                    f'z-index:99;background:#1a2a35;border:1px solid #2a4555;border-radius:8px;'
                    f'padding:10px;min-width:220px;white-space:normal;">'
                    f'<form method="post" action="add-meter" style="margin:0;">'
                    f'<input type="hidden" name="meter_id" value="{esc(mid)}">'
                    f'<input type="hidden" name="driver" value="{esc(driver)}">'
                    f'<input type="hidden" name="key" value="">'
                    f'<input type="hidden" name="return_to" value="discover">'
                    f'<label style="font-size:11px;color:#95adbd;display:block;margin-bottom:4px;">'
                    f'{esc(tr(lang, "meter_name_label"))}</label>'
                    f'<input type="text" name="meter_name" value="{esc(suggested_name)}" '
                    f'style="width:100%;background:#0e151b;border:1px solid #2a4555;color:#e8f1f8;'
                    f'border-radius:4px;padding:5px 7px;font-size:12px;margin-bottom:6px;box-sizing:border-box;">'
                    f'<div style="display:flex;gap:6px;">'
                    f'<button class="small-button" type="submit" style="flex:1;">{esc(tr(lang, "save_label"))}</button>'
                    f'<button class="small-button" type="button" style="flex:1;" '
                    f'onclick="document.getElementById(\'{popup_id}\').style.display=\'none\';'
                    f'this.closest(\'span\').previousElementSibling.style.display=\'\';">'
                    f'{esc(tr(lang, "cancel_label"))}</button>'
                    f'</div></form></span></span>'
                )
            actions = (
                add_inline
                + f'<a class="small-button" href="{link("candidate", id=mid)}">{esc(tr(lang, "analyze"))}</a>'
                + f'<a class="small-button danger" href="{link("ignore", id=mid)}">{esc(tr(lang, "ignore"))}</a>'
            )
        rows.append(
            f'''<tr><td><strong>{esc(mid)}</strong><span class="muted">{esc(c.get('type') or tr(lang, "listen_label"))}</span></td>'''
            f'''<td>{esc(driver)}</td><td>{media_icon(c.get('type',''), driver)} {esc(tr_media(lang, mclass))}</td>'''
            f'''<td><span class="pill {esc(enc_cls)}">{esc(enc)}</span><span class="muted">{esc(enc_note)}</span></td>'''
            f'''<td>{esc(c.get('seen_count') or '0')}<span class="muted">{esc(reception_line(c))}</span></td>'''
            f'''<td>{fmt_ts(c.get('last_seen') or '')}</td><td>{actions}</td></tr>'''
        )
    return (
        f'<div class="table-wrap"><table class="table"><thead><tr>'
        f'<th>{esc(tr(lang, "meter_id"))}</th><th>{esc(tr(lang, "driver"))}</th><th>{esc(tr(lang, "media"))}</th>'
        f'<th>{esc(tr(lang, "encryption_aes"))}</th><th>{esc(tr(lang, "reception"))}</th>'
        f'<th>{esc(tr(lang, "last_telegram"))}</th><th>{esc(tr(lang, "action"))}</th>'
        f'</tr></thead><tbody>{"".join(rows)}</tbody></table></div>'
    )


def render_waiting_panel(data: dict, lang: str = DEFAULT_LANG) -> str:
    """Show info banner after restart: meters loaded, waiting for first telegrams."""
    try:
        options_mtime = OPTIONS_JSON.stat().st_mtime
        status_mtime  = STATUS_JSON.stat().st_mtime
        if status_mtime <= options_mtime:
            return ""  # pending panel handles this case
    except OSError:
        return ""

    options = read_json(OPTIONS_JSON)
    if not isinstance(options, dict):
        return ""
    configured = [m for m in (options.get("meters") or []) if isinstance(m, dict) and m.get("meter_id")]
    if not configured:
        return ""

    decoded_ids = set()
    for m in data.get("meters", []):
        mid = str(m.get("id") or "").lower()
        if mid:
            decoded_ids.add(mid)
            bare = mid[6:] if mid.startswith("meter_") else mid
            decoded_ids.add(bare)

    waiting = [m for m in configured if str(m.get("meter_id") or "").lower() not in decoded_ids]
    if not waiting:
        return ""

    rows = []
    for m in waiting:
        mid = esc(m.get("meter_id", ""))
        name = esc(m.get("id") or mid)
        driver = esc(m.get("type") or "auto")
        rows.append(
            f'<div style="display:grid;grid-template-columns:130px 100px 1fr;gap:8px;'
            f'padding:5px 0;border-bottom:0.5px solid #1e3040;font-size:12px;">'
            f'<strong style="font-family:monospace;">{mid}</strong>'
            f'<span style="color:#95adbd;">{name}</span>'
            f'<span style="color:#95adbd;">{driver}</span>'
            f'</div>'
        )

    return (
        f'<div class="notice" style="margin-top:14px;background:#0d1f2d;border-color:#1e3a50;">'
        f'<div style="display:flex;align-items:center;gap:8px;margin-bottom:8px;">'
        f'<span style="font-size:16px;">&#x23F3;</span>'
        f'<strong>{esc(tr(lang, "waiting_for_telegrams_title"))} ({len(waiting)})</strong>'
        f'</div>'
        f'<div style="color:#95adbd;font-size:12px;margin-bottom:10px;">'
        f'{esc(tr(lang, "waiting_for_telegrams_text"))}'
        f'</div>'
        f'{"".join(rows)}'
        f'<div style="margin-top:8px;color:#6a8a9a;font-size:11px;">'
        f'{esc(tr(lang, "waiting_for_telegrams_hint"))}'
        f'</div>'
        f'</div>'
    )


def render_candidate_summary(candidates: list[dict], lang: str = DEFAULT_LANG) -> str:
    count = len(candidates)
    if count <= 0:
        return f'''
        <div style="display:flex;justify-content:space-between;align-items:center;gap:16px;flex-wrap:wrap;">
          <div class="sub">{esc(tr(lang, "no_candidates_listen"))}</div>
          <a class="button inline" href="discover">{esc(tr(lang, "open_discover_btn"))}</a>
        </div>'''
    best = candidates[0]
    best_driver = best.get("driver") or "auto"
    best_media = media_class(best.get("type", ""), best_driver)
    return f'''
    <div class="candidate-summary">
      <div class="summary-big">{count}</div>
      <div><div class="summary-title">{esc(tr(lang, "detected_candidates_lower"))}</div><div class="summary-sub">{esc(tr(lang, "full_list_in_discover"))}</div></div>
      <div class="summary-best"><span class="muted">{esc(tr(lang, "best_candidate"))}</span><strong>{esc(best.get('id'))} / {esc(best_driver)}</strong><span>{media_icon(best.get('type',''), best_driver)} {esc(tr_media(lang, best_media))} · {esc(reception_line(best))}</span></div>
      <a class="button inline" href="discover">{esc(tr(lang, "open_discover_btn"))}</a>
    </div>'''


def render_events(events: list[dict], max_items: int | None = None, lang: str = DEFAULT_LANG) -> str:
    shown = events if max_items is None else events[:max_items]
    if not shown:
        return f'<div class="empty">{esc(tr(lang, "no_events_yet"))}</div>'
    rows = []
    for e in shown:
        css, label, message = event_level_for_ui(e)
        rows.append(f'<div class="event-row"><span>{esc(e.get("time"))}</span><strong class="{esc(css)}">{esc(label)}</strong><em>{esc(message)}</em></div>')
    return ''.join(rows)


def page_dashboard(data: dict, params: dict[str, list[str]], lang: str = DEFAULT_LANG) -> str:
    model = status_model(data)
    media = (params.get("media") or ["all"])[0]
    media = media if media in MEDIA_FILTERS else "all"
    meters = filter_by_media(data["meters"], media)
    pending = pending_meters(data)
    body = f'''
      <h1>{esc(tr(lang, "dashboard_title"))}</h1><div class="sub">{esc(tr(lang, "dashboard_sub"))}</div>
      <section class="grid3">{render_system_status(model)}{render_stats(model)}{render_discovery(model)}</section>
      {render_pending_panel(pending, lang)}
      {render_waiting_panel(data, lang)}
      <section class="card" style="margin-top:14px;"><div class="section-head"><h2>{esc(tr(lang, "configured_meters"))}</h2>{render_filter_links('.', media, lang)}</div>{render_configured_meters(meters, max_items=6, lang=lang, pending=pending, cfg=model["cfg"])}</section>
      <section class="card" style="margin-top:14px;"><div class="section-head"><h2>{esc(tr(lang, "detected_candidates"))}</h2></div>{render_candidate_summary(data['candidates'], lang)}</section>
      <div class="footer"><span>wMBus MQTT Bridge</span><span>{esc(tr(lang, "footer_subtitle"))}</span><span>{esc(tr(lang, "footer_caption"))}</span></div>'''
    return shell('dashboard', body, model['status'].get('updated_at', ''), lang=lang)


def page_meters(data: dict, params: dict[str, list[str]], lang: str = DEFAULT_LANG) -> str:
    model = status_model(data)
    media = (params.get("media") or ["all"])[0]
    media = media if media in MEDIA_FILTERS else "all"
    meters = filter_by_media(data["meters"], media)
    pending = pending_meters(data)
    body = (
        f'<h1>{esc(tr(lang, "meters_title"))}</h1><div class="sub">{esc(tr(lang, "meters_sub"))}</div>'
        f'{render_pending_panel(pending, lang)}'
        f'{render_waiting_panel(data, lang)}'
        f'<section class="card" style="margin-top:18px;"><div class="section-head">'
        f'<h2>{esc(tr(lang, "configured_meters"))} ({len(meters)} / {model["meter_count"]})</h2>'
        f'{render_filter_links("meters", media, lang)}</div>'
        f'{render_configured_meters(meters, lang=lang, pending=pending, cfg=model["cfg"])}</section>'
    )
    return shell('meters', body, model['status'].get('updated_at', ''), lang=lang)



def page_discover(data: dict, params: dict[str, list[str]], lang: str = DEFAULT_LANG) -> str:
    model = status_model(data)
    media = (params.get("media") or ["all"])[0]
    media = media if media in MEDIA_FILTERS else "all"
    show_ignored = (params.get("ignored") or ["0"])[0] == "1"
    search_cached = model["search_cached_count"]
    added_msg = (params.get("added") or [""])[0]
    error_msg = (params.get("error") or [""])[0]
    banner = ""
    if added_msg:
        banner = (
            f'<div class="notice good" style="margin-top:14px;">&#10003; {esc(added_msg)}'
            f'<br><span style="font-size:13px;">{esc(tr(lang, "add_more_before_restart"))}</span></div>'
        )
    elif error_msg:
        banner = f'<div class="notice warn" style="margin-top:14px;">&#9888; {esc(error_msg)}</div>'
    pending_html = render_pending_panel(pending_meters(data), lang)

    if show_ignored:
        full_data = state(include_ignored=True)
        ignored = [c for c in full_data["candidates"] if c.get("ignored") == "true"]
        list_html = render_candidates_table(filter_by_media(ignored, media), show_restore=True, lang=lang)
        title = f'{esc(tr(lang, "ignored_candidates_label"))} ({len(ignored)})'
        ignored_link = f'<a class="filter" href="discover">{esc(tr(lang, "active_filter"))} ({model["candidate_count"]})</a>'
    else:
        ignored_count = model["ignored_count"]
        candidates = filter_by_media(data["candidates"], media)
        list_html = render_candidates_table(candidates, lang=lang)
        title = f'{esc(tr(lang, "detected_candidates"))} — {len(candidates)} / {model["candidate_count"]}'
        ignored_label = f'{esc(tr(lang, "ignored_filter"))} ({ignored_count})' if ignored_count > 0 else esc(tr(lang, "ignored_filter"))
        ignored_link = f'<a class="filter" href="discover?ignored=1">{ignored_label}</a>'

    body = f'''
    <h1>{esc(tr(lang, "discover_title"))}</h1>
    <div class="sub">{esc(tr(lang, "discover_sub"))}</div>
    {banner}
    {pending_html}
    <section class="card" style="margin-top:18px;">
      <h2>{esc(tr(lang, "listen_observation_title"))}</h2>
      <div class="notice">
        {esc(tr(lang, "listen_observation_text"))}<br>
        {esc(tr(lang, "candidates_for_search_label"))}: <b>{search_cached}</b> · <code>search_candidates.tsv</code>.
      </div>
    </section>
    <section class="card" style="margin-top:14px;">
      <div class="section-head"><h2>{title}</h2><div class="filters">{ignored_link}</div></div>
      {render_filter_links("discover", media, lang)}
      <div style="height:10px"></div>
      {list_html}
    </section>'''
    return shell('discover', body, model['status'].get('updated_at', ''), refresh=True, lang=lang)


def _search_matches_cards(matches: list[dict], lang: str = DEFAULT_LANG) -> str:
    if not matches:
        return ''
    cards = []
    for m in matches:
        mid = str(m.get("id") or "")
        driver = str(m.get("driver") or "auto")
        cfg_snippet = json.dumps({"id": f"meter_{mid}", "meter_id": mid, "type": driver, "type_other": "", "key": ""}, ensure_ascii=False)
        cfg_js = esc(cfg_snippet)
        cards.append(f'''
        <div style="background:#091a10;border:1px solid #1e6b3a;border-radius:8px;padding:14px;margin-bottom:10px;">
          <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:12px;flex-wrap:wrap;">
            <div>
              <div style="font-size:22px;font-weight:900;color:#4df08d;">{esc(mid)}<span style="font-size:13px;font-weight:400;color:#9ed8b4;margin-left:8px;">{esc(driver)} · {esc(m.get("media") or "")}</span></div>
              <div style="margin-top:6px;font-size:13px;color:#cfe8d8;">{esc(tr(lang, "value_label"))}: <b>{esc(m.get("value_m3"))} m³</b> · {esc(tr(lang, "expected_short").lower())}: {esc(m.get("expected_m3"))} m³ · {esc(tr(lang, "diff_label").lower())}: {esc(m.get("diff_m3"))} m³ · {esc(m.get("time"))}</div>
              <div style="margin-top:8px;font-family:monospace;font-size:12px;color:#a8d8bc;background:#060f09;padding:7px 10px;border-radius:5px;">{esc(cfg_snippet)}</div>
            </div>
            <div style="display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end;">
              <form method="post" action="add-meter" style="margin:0;"><input type="hidden" name="meter_id" value="{esc(mid)}"><input type="hidden" name="driver" value="{esc(driver)}"><input type="hidden" name="key" value=""><button class="button good" type="submit" style="margin:0;white-space:nowrap;">{esc(tr(lang, "add_meter_short_btn"))}</button></form>
              <button class="button" style="margin:0;white-space:nowrap;" onclick="copyText('{cfg_js}')">{esc(tr(lang, "copy_config"))}</button>
            </div>
          </div>
        </div>''')
    return ''.join(cards)


def page_search(data: dict, params: dict[str, list[str]], lang: str = DEFAULT_LANG) -> str:
    model = status_model(data)
    search_cfg = search_config_model(data)
    st = data.get("search_status", {}) if isinstance(data.get("search_status"), dict) else {}
    matches = data.get("search_matches", [])
    search_mode = bool(search_cfg.get("search_mode")) or bool(st.get("search_mode"))
    phase = str(st.get("phase") or ("search" if search_mode else "idle"))
    cached = safe_int(st.get("cached_candidates", model["search_cached_count"]))
    ignored = safe_int(st.get("ignored_candidates", 0))
    loaded = safe_int(st.get("loaded_temp_meters", 0))
    decoded = safe_int(st.get("decoded_json", 0))
    checked = safe_int(st.get("checked_values", 0))
    match_count = max(len(matches), safe_int(st.get("matches", 0)))
    expected = str(st.get("expected_m3") if st.get("expected_m3") not in (None, "") else search_cfg["search_expected_value_m3"])
    tolerance = str(st.get("tolerance_m3") if st.get("tolerance_m3") not in (None, "") else search_cfg["search_tolerance_m3"])
    last_candidate = st.get("last_candidate") if isinstance(st.get("last_candidate"), dict) else {}
    last_checked = st.get("last_checked") if isinstance(st.get("last_checked"), dict) else {}
    last_reason = str(st.get("last_reason") or "")
    updated = str(st.get("updated_at") or model['status'].get('updated_at', ''))

    if match_count > 0:
        banner_cls = "good"
        banner_title = tr(lang, "search_match_banner_title")
        banner_text = tr(lang, "search_match_banner_text").format(matches=match_count)
    elif search_mode:
        banner_cls = "good" if phase == "search" else "warn"
        banner_title = tr(lang, "search_active_banner_title")
        banner_text = tr(lang, "search_active_banner_text").format(loaded=loaded)
    else:
        banner_cls = "warn"
        banner_title = tr(lang, "search_cfg_banner_title")
        banner_text = tr(lang, "search_cfg_banner_text")

    if matches:
        matches_section = (
            f'<section class="card" style="margin-top:14px;border-color:#1e6b3a;">'
            f'<h2 style="color:#4df08d;">{esc(tr(lang, "matches_found_title").format(n=len(matches)))}</h2>'
            f'{_search_matches_cards(matches, lang)}'
            f'<div class="notice good">{esc(tr(lang, "disable_search_after_add"))}</div></section>'
        )
    elif search_mode:
        matches_section = (
            f'<section class="card" style="margin-top:14px;"><h2>{esc(tr(lang, "no_match_yet_title"))}</h2>'
            f'<div class="notice">{tr(lang, "bridge_compares_text").format(expected=esc(expected), tolerance=esc(tolerance))}</div></section>'
        )
    else:
        matches_section = ''

    form_section = (
        f'<section class="card" style="margin-top:14px;">'
        f'<h2>{esc(tr(lang, "search_config_h2"))}</h2>'
        f'<div class="sub" style="margin-bottom:14px;">{tr(lang, "search_uses_candidates_sub")}</div>'
        f'<form method="post" action="search-control"><div class="form-grid">'
        f'<div class="field"><label>{esc(tr(lang, "meter_reading_label"))}</label>'
        f'<input name="expected" value="{esc(expected)}" placeholder="22.907"></div>'
        f'<div class="field"><label>{esc(tr(lang, "tolerance_m3_label"))}</label>'
        f'<input name="tolerance" value="{esc(tolerance)}" placeholder="0.05"></div></div>'
        f'<div style="margin-top:12px;display:flex;gap:10px;flex-wrap:wrap;align-items:center;">'
        f'<button class="button good" name="action" value="start" type="submit">{esc(tr(lang, "save_enable_search_btn"))}</button>'
        f'<button class="button danger" name="action" value="stop" type="submit">{esc(tr(lang, "disable_search_btn"))}</button>'
        f'</div></form>'
        f'<div class="notice" style="margin-top:12px;">{esc(tr(lang, "aes_search_note"))}</div></section>'
    )

    debug_section = (
        f'<section class="card" style="margin-top:14px;">'
        f'<h2>{esc(tr(lang, "live_status_title"))}</h2>'
        f'<div class="discovery-kv">'
        f'<span>{esc(tr(lang, "phase_kv"))}</span><span>{esc(phase)}</span>'
        f'<span>{esc(tr(lang, "cached_candidates_kv"))}</span><span>{cached}</span>'
        f'<span>{esc(tr(lang, "ignored_candidates_kv"))}</span><span>{ignored}</span>'
        f'<span>{esc(tr(lang, "temp_meters_loaded_kv"))}</span><span>{loaded}</span>'
        f'<span>{esc(tr(lang, "decoded_json_kv"))}</span><span>{decoded}</span>'
        f'<span>{esc(tr(lang, "checked_values_kv"))}</span><span>{checked}</span>'
        f'<span>{esc(tr(lang, "matches_kv"))}</span><span>{match_count}</span>'
        f'<span>{esc(tr(lang, "last_candidate_kv"))}</span>'
        f'<span>{esc(last_candidate.get("id") or "")} / {esc(last_candidate.get("driver") or "")} / {esc(last_candidate.get("type") or "")}</span>'
        f'<span>{esc(tr(lang, "last_checked_kv"))}</span>'
        f'<span>{esc(last_checked.get("id") or "")} / {esc(last_checked.get("field") or "")}={esc(last_checked.get("value") or "")}, diff={esc(last_checked.get("diff_m3") or "")}</span>'
        f'<span>{esc(tr(lang, "last_reason_kv"))}</span><span>{esc(last_reason)}</span>'
        f'<span>{esc(tr(lang, "status_updated_kv"))}</span><span>{esc(fmt_ts(updated))}</span>'
        f'</div></section>'
    )
    events_section = (
        f'<section class="card" style="margin-top:14px;">'
        f'<h2>{esc(tr(lang, "recent_events_title"))}</h2>'
        f'{render_events(data.get("events", []), max_items=20, lang=lang)}</section>'
    )

    body = (
        f'<h1>{esc(tr(lang, "search_page_title"))}</h1>'
        f'<div class="sub">{esc(tr(lang, "service_mode_sub"))}</div>'
        f'<section class="card notice {banner_cls}" style="margin-top:18px;">'
        f'<h2>{esc(banner_title)}</h2><div>{esc(banner_text)}</div>'
        f'<div class="legend" style="margin-top:12px;">'
        f'<span>{esc(tr(lang, "cached_candidates_kv"))}: <b>{cached}</b></span>'
        f'<span>{esc(tr(lang, "temp_meters_loaded_kv"))}: <b>{loaded}</b></span>'
        f'<span>{esc(tr(lang, "decoded_json_kv"))}: <b>{decoded}</b></span>'
        f'<span>{esc(tr(lang, "checked_values_kv"))}: <b>{checked}</b></span>'
        f'<span>{esc(tr(lang, "matches_kv"))}: <b>{match_count}</b></span>'
        f'</div></section>{matches_section}{form_section}{debug_section}{events_section}'
    )
    return shell('search', body, model['status'].get('updated_at', ''), lang=lang)

def page_candidate(data: dict, params: dict[str, list[str]], lang: str = DEFAULT_LANG) -> str:
    mid = (params.get("id") or [""])[0]
    added_msg = (params.get("added") or [""])[0]
    error_msg  = (params.get("error") or [""])[0]
    all_data = state(include_ignored=True)
    candidate = next((c for c in all_data["candidates"] if c.get("id") == mid), None)
    model = status_model(data)
    updated = model["status"].get("updated_at", "")

    if not candidate:
        body = (
            '<div style="margin-top:24px;">'
            f'<a class="button" href="discover">{esc(tr(lang, "back_to_discover_short"))}</a>'
            '<section class="card" style="margin-top:14px;">'
            f'<div class="empty">{esc(tr(lang, "candidate_not_found").format(mid=mid))}</div>'
            '</section></div>'
        )
        return shell("discover", body, updated, refresh=False, lang=lang)

    enc, enc_note, enc_cls = candidate_encryption_hint(candidate)
    driver = str(candidate.get("driver") or "auto")
    aes_required = enc_cls == "bad"

    # Check if already in options.json
    options = read_json(OPTIONS_JSON)
    existing_meters = options.get("meters", []) if isinstance(options, dict) else []
    already_added = any(
        isinstance(m, dict) and m.get("meter_id") == mid
        for m in existing_meters
    )

    def make_cfg(key: str) -> str:
        return json.dumps({
            "id": f"meter_{mid}",
            "meter_id": mid,
            "type": driver,
            "type_other": "",
            "key": key,
        }, ensure_ascii=False, indent=2)

    cfg_nokey    = esc(make_cfg(""))
    cfg_zerokey  = esc(make_cfg(ZERO_AES_KEY))
    cfg_nokey_1  = esc(json.dumps({"id": f"meter_{mid}", "meter_id": mid, "type": driver, "type_other": "", "key": ""}, ensure_ascii=False))
    cfg_zerokey_1 = esc(json.dumps({"id": f"meter_{mid}", "meter_id": mid, "type": driver, "type_other": "", "key": ZERO_AES_KEY}, ensure_ascii=False))
    cfg_placeholder = esc(make_cfg("ENTER_32_HEX_KEY_HERE"))

    # Status banners
    if added_msg:
        status_banner = (
            f'<div class="notice good" style="margin-bottom:14px;">'
            f'&#10003; {esc(added_msg)}'
            f'<br><b>{esc(tr(lang, "restart_to_apply" if is_supervisor_mode() else "restart_to_apply_docker"))}</b>'
            f'</div>'
        )
    elif error_msg:
        status_banner = f'<div class="notice warn" style="margin-bottom:14px;">&#9888; {esc(error_msg)}</div>'
    elif already_added:
        status_banner = (
            f'<div class="notice good" style="margin-bottom:14px;">&#10003; '
            f'{esc(tr(lang, "already_added_note").format(mid=mid))}</div>'
        )
    else:
        status_banner = ""

    # AES key input + add-meter form
    if aes_required:
        add_form = f"""
<div style="background:#1a0d0d;border:1px solid #7a2a2a;border-radius:8px;padding:16px;margin-bottom:16px;">
  <div style="font-size:14px;font-weight:800;color:#ff8c98;margin-bottom:10px;">
    {esc(tr(lang, "aes_required_header"))}
  </div>
  <form method="post" action="add-meter">
    <input type="hidden" name="meter_id" value="{esc(mid)}">
    <input type="hidden" name="driver"   value="{esc(driver)}">
    <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:10px;">
      <div style="flex:1;min-width:260px;">
        <label style="color:#95adbd;font-size:12px;display:block;margin-bottom:4px;">{esc(tr(lang, "aes_key_label"))}</label>
        <input id="aes-key-input" name="key" type="text" maxlength="32"
          placeholder="{esc(tr(lang, "key_input_placeholder"))}"
          oninput="onKeyInput(this.value)"
          style="width:100%;background:#0e151b;border:1px solid #5a2020;
                 color:#e8f1f8;border-radius:6px;padding:10px;font-family:monospace;font-size:13px;">
      </div>
      <span id="key-status" style="font-size:12px;font-weight:800;min-width:50px;margin-top:18px;"></span>
    </div>
    <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">
      <button id="btn-add" class="button good" type="submit" disabled
        style="opacity:0.4;cursor:not-allowed;">{esc(tr(lang, "add_meter_btn"))}</button>
      <span style="color:#95adbd;font-size:12px;">{esc(tr(lang, "saves_then_restart"))}</span>
    </div>
  </form>
  <div style="margin-top:8px;color:#95adbd;font-size:11px;">
    {esc(tr(lang, "key_hint"))}
  </div>
</div>"""
        main_label   = tr(lang, "preview_with_key")
        main_initial = cfg_placeholder
    else:
        add_form = f"""
<form method="post" action="add-meter" style="margin-bottom:16px;">
  <input type="hidden" name="meter_id" value="{esc(mid)}">
  <input type="hidden" name="driver"   value="{esc(driver)}">
  <input type="hidden" name="key"      value="">
  <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center;">
    <button class="button good" type="submit"{'disabled style="opacity:0.5;cursor:not-allowed;"' if already_added else ''}>{esc(tr(lang, "add_meter_btn"))}</button>
    <span style="color:#95adbd;font-size:12px;">{esc(tr(lang, "saves_then_restart"))}</span>
  </div>
</form>"""
        main_label   = tr(lang, "no_key_recommended")
        main_initial = cfg_nokey

    mid_js    = json.dumps(mid)
    driver_js = json.dumps(driver)
    ok_js     = json.dumps(tr(lang, "key_status_ok"))

    body = f"""
<div style="margin-bottom:14px;">
  <a class="button" href="discover" style="margin:0;">{esc(tr(lang, "back_to_discover"))}</a>
</div>
{status_banner}
<h1>{esc(tr(lang, "candidate_title"))} {esc(mid)}</h1>
<div class="sub">{esc(tr(lang, "candidate_detected_sub"))}</div>

<section class="grid2" style="margin-top:18px;">

  <section class="card">
    <h2>{esc(tr(lang, "candidate_details"))}</h2>
    <div class="discovery-kv">
      <span>{esc(tr(lang, "meter_id"))}</span><span style="font-family:monospace;font-size:15px;font-weight:800;">{esc(mid)}</span>
      <span>{esc(tr(lang, "driver"))}</span><span>{esc(driver)}</span>
      <span>{esc(tr(lang, "media"))}</span><span>{media_icon(candidate.get('type',''), driver)} {esc(tr_media(lang, media_class(candidate.get('type',''), driver)))}</span>
      <span>{esc(tr(lang, "encryption_label"))}</span><span class="pill {esc(enc_cls)}">{esc(enc)}</span>
      <span>{esc(tr(lang, "last_seen_label"))}</span><span>{fmt_ts(candidate.get('last_seen') or '')}</span>
      <span>{esc(tr(lang, "reception"))}</span><span>{esc(reception_line(candidate))}</span>
    </div>
    <div class="notice {'warn' if aes_required else ''}" style="margin-top:14px;">
      <b>{esc(tr(lang, "aes_prefix"))}</b> {esc(enc_note)}<br>
      <code>{esc(tr(lang, "no_aes_key_note"))}</code> &nbsp;\u00b7&nbsp;
      {esc(tr(lang, "zero_key"))} = <code style="font-size:10px;">{ZERO_AES_KEY}</code><br>
      {esc(tr(lang, "real_aes_key_note"))}
    </div>
    <div style="margin-top:16px;">
      <a class="button danger" href="{link('ignore', id=mid)}">{esc(tr(lang, "ignore_candidate_btn"))}</a>
    </div>
  </section>

  <section class="card" id="config">
    <h2>{esc(tr(lang, "add_meter"))}</h2>
    <p class="sub">{esc(tr(lang, "saves_to_options_note"))}</p>
    {render_restart_block(lang)}

    {add_form}

    <hr style="border:none;border-top:1px solid #263c4a;margin:16px 0;">
    <h3 style="margin-top:0;">{esc(tr(lang, "json_preview"))}</h3>
    <p class="sub" style="margin-bottom:8px;">{esc(tr(lang, "manual_copy_tip"))}</p>

    <h4 style="margin:10px 0 6px;">{esc(main_label)}</h4>
    <textarea id="cfg-main" class="codebox" rows="8" readonly>{main_initial}</textarea>
    <button class="button" style="margin-top:6px;"
      onclick="copyText(document.getElementById('cfg-main').value)">{esc(tr(lang, "copy"))}</button>

    <h4 style="margin:14px 0 6px;">{esc(tr(lang, "zero_key"))}</h4>
    <textarea class="codebox" rows="8" readonly>{cfg_zerokey}</textarea>
    <button class="button" style="margin-top:6px;"
      onclick="copyText('{cfg_zerokey_1}')">{esc(tr(lang, "copy"))}</button>

    <h4 style="margin:14px 0 6px;">{esc(tr(lang, "no_key"))}</h4>
    <textarea class="codebox" rows="8" readonly>{cfg_nokey}</textarea>
    <button class="button" style="margin-top:6px;"
      onclick="copyText('{cfg_nokey_1}')">{esc(tr(lang, "copy"))}</button>
  </section>

</section>

<script>
  var mid = {mid_js};
  var driver = {driver_js};

  function makeCfg(key) {{
    return JSON.stringify({{
      "id": "meter_" + mid,
      "meter_id": mid,
      "type": driver,
      "type_other": "",
      "key": key
    }}, null, 2);
  }}

  function onKeyInput(val) {{
    var status = document.getElementById("key-status");
    var input  = document.getElementById("aes-key-input");
    var main   = document.getElementById("cfg-main");
    var btn    = document.getElementById("btn-add");
    var valid  = /^[0-9A-Fa-f]{{32}}$/.test(val);
    if (val.length === 0) {{
      status.textContent = "";
      main.value = makeCfg("ENTER_32_HEX_KEY_HERE");
      input.style.borderColor = "#5a2020";
      btn.disabled = true; btn.style.opacity = "0.4"; btn.style.cursor = "not-allowed";
    }} else if (valid) {{
      status.textContent = {ok_js};
      status.style.color = "#4df08d";
      main.value = makeCfg(val.toUpperCase());
      input.style.borderColor = "#1e6b3a";
      btn.disabled = false; btn.style.opacity = "1"; btn.style.cursor = "pointer";
    }} else {{
      status.textContent = val.length + "/32";
      status.style.color = "#f3c84b";
      main.value = makeCfg("ENTER_32_HEX_KEY_HERE");
      input.style.borderColor = "#6b4a1e";
      btn.disabled = true; btn.style.opacity = "0.4"; btn.style.cursor = "not-allowed";
    }}
  }}
</script>"""

    return shell("discover", body, updated, refresh=False, lang=lang)


def page_logs(data: dict, params: dict[str, list[str]], lang: str = DEFAULT_LANG) -> str:
    model = status_model(data)
    body = (
        f'<h1>{esc(tr(lang, "logs_title"))}</h1>'
        f'<div class="sub">{esc(tr(lang, "logs_sub"))}</div>'
        f'<section class="card" style="margin-top:18px;">'
        f'<div class="legend">'
        f'<span>{tr(lang, "raw_legend")}</span>'
        f'<span>{tr(lang, "candidate_legend")}</span>'
        f'</div>{render_events(data["events"], max_items=50, lang=lang)}</section>'
    )
    return shell('logs', body, model['status'].get('updated_at', ''), lang=lang)


def page_settings(data: dict, params: dict[str, list[str]], lang: str = DEFAULT_LANG) -> str:
    model = status_model(data)
    cfg   = model['cfg']
    mqtt  = model['mqtt']
    opts  = data.get("options", {}) if isinstance(data.get("options"), dict) else {}
    search_expected = esc(opts.get('search_expected_value_m3', cfg.get('search_expected_value_m3', '')))
    search_tolerance = esc(opts.get('search_tolerance_m3', cfg.get('search_tolerance_m3', '')))
    body = f'''<h1>{esc(tr(lang, "settings_title"))}</h1>
    <div class="sub">{esc(tr(lang, "settings_runtime"))}</div>
    <section class="grid2">
      <section class="card">
        <h2>{esc(tr(lang, "active_runtime_config"))}</h2>
        <div class="discovery-kv">
          <span>raw_topic</span><span>{esc(cfg.get('raw_topic'))}</span>
          <span>state_prefix</span><span>{esc(cfg.get('state_prefix'))}</span>
          <span>discovery_prefix</span><span>{esc(cfg.get('discovery_prefix'))}</span>
          <span>search_mode</span><span>{esc(cfg.get('search_mode'))}</span>
          <span>search_expected_value_m3</span><span>{search_expected}</span>
          <span>search_tolerance_m3</span><span>{search_tolerance}</span>
          <span>loglevel</span><span>{esc(cfg.get('loglevel'))}</span>
          <span>{esc(tr(lang, "mqtt_host_label"))}</span><span>{esc(mqtt.get('host'))}:{esc(mqtt.get('port'))}</span>
          <span>{esc(tr(lang, "ignored_candidates_label"))}</span><span>{model['ignored_count']}</span>
        </div>
        {render_restart_block(lang)}
      </section>
      <section class="card">
        <h2>{esc(tr(lang, "runtime_files"))}</h2>
        <div class="codebox">/data/options.json
/data/status.json
/data/status_meters.tsv
/data/status_candidates.tsv
/data/status_events.tsv
/data/status_seen.tsv
/data/status_ignored_candidates.tsv
/data/search_candidates.tsv
/data/search_matches.tsv
/data/status_candidate_analysis.tsv</div>
        <a class="button" href="discover?ignored=1" style="margin-top:14px;display:inline-block;">{esc(tr(lang, "manage_ignored"))}</a>
      </section>
    </section>'''
    return shell('settings', body, model['status'].get('updated_at', ''), lang=lang)


def page_about(data: dict, params: dict[str, list[str]], lang: str = DEFAULT_LANG) -> str:
    model = status_model(data)
    body = (
        f'<h1>{esc(tr(lang, "about_title"))}</h1>'
        f'<div class="sub">{esc(tr(lang, "about_sub"))}</div>'
        f'<section class="card" style="margin-top:18px;"><div class="about-text">'
        f'<p>{tr(lang, "about_body_p1")}</p>'
        f'<p>{tr(lang, "about_body_p2")}</p>'
        f'</div><div class="codebox">ESP32 / Gateway / Bridge\n→ MQTT raw HEX\n→ wmbusmeters stdin:hex\n→ MQTT decoded JSON\n→ Home Assistant Discovery</div></section>'
    )
    return shell('about', body, model['status'].get('updated_at', ''), lang=lang)


def render_page(path: str, params: dict[str, list[str]], lang: str = DEFAULT_LANG) -> str:
    data = state()
    # SEARCH is a modal/service mode. When enabled, normal UI pages render
    # the SEARCH screen instead of pretending the dashboard/discover flow is normal.
    search_cfg = search_config_model(data)
    st = data.get("search_status", {}) if isinstance(data.get("search_status"), dict) else {}
    search_active = bool(search_cfg.get("search_mode")) or bool(st.get("search_mode")) or str(st.get("phase") or "") in {"collecting", "search", "matched"}
    if search_active and path not in {'/search', '/search-discover'}:
        return page_search(data, params, lang)
    if path == '/meters': return page_meters(data, params, lang)
    if path == '/discover': return page_discover(data, params, lang)
    if path in {'/search', '/search-discover'}: return page_search(data, params, lang)
    if path == '/candidate': return page_candidate(data, params, lang)
    if path == '/logs': return page_logs(data, params, lang)
    if path == '/settings': return page_settings(data, params, lang)
    if path == '/about': return page_about(data, params, lang)
    return page_dashboard(data, params, lang)


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

    def _route_path(self, raw_path: str) -> str:
        path = raw_path.rstrip('/') or '/'
        known = {'/', '/meters', '/discover', '/search', '/search-discover', '/candidate', '/logs', '/settings', '/about', '/ignore', '/unignore', '/config', '/search-control', '/restart-bridge', '/add-meter', '/remove-meter'}
        if path not in known and not path.endswith('/api/status') and not path.endswith('/healthz'):
            last = '/' + path.rsplit('/', 1)[-1]
            if last in known:
                path = last
        return path

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = self._route_path(parsed.path)
        params = self._read_form()
        lang = detect_lang(self.headers, params)
        self._wmbus_lang = lang
        if path == '/remove-meter':
            meter_id = (params.get('meter_id') or [''])[0].strip()
            ok, msg = remove_meter_from_options(meter_id)
            webui_add_event('ok' if ok else 'error', msg)
            self._redirect('meters')
            return
        if path == '/add-meter':
            meter_id   = (params.get('meter_id')   or [''])[0].strip()
            driver     = (params.get('driver')     or ['auto'])[0].strip()
            key        = (params.get('key')        or [''])[0].strip()
            meter_name = (params.get('meter_name') or [''])[0].strip()
            return_to  = (params.get('return_to')  or [''])[0].strip()
            ok, msg    = add_meter_to_options(meter_id, driver, key, meter_name=meter_name)
            webui_add_event('ok' if ok else 'error', msg)
            if return_to == 'discover':
                if ok:
                    self._redirect(link('discover', added=msg))
                else:
                    self._redirect(link('discover', error=msg))
            else:
                if ok:
                    self._redirect(link('candidate', id=meter_id, added=msg))
                else:
                    self._redirect(link('candidate', id=meter_id, error=msg))
            return
        if path == '/search-control':
            action = (params.get('action') or ['start'])[0]
            if action == 'stop':
                ok, msg = update_options_for_search('0', '0.05', enabled=False)
                webui_add_event('ok' if ok else 'error', msg)
            else:
                ok, msg = update_options_for_search((params.get('expected') or ['0'])[0], (params.get('tolerance') or ['0.05'])[0], enabled=True)
                webui_add_event('ok' if ok else 'error', msg)
            restart_ok, restart_msg = restart_addon_via_supervisor()
            webui_add_event('ok' if restart_ok else 'error', restart_msg)
            self._redirect('search')
            return
        if path == '/restart-bridge':
            restart_ok, restart_msg = restart_addon_via_supervisor()
            webui_add_event('ok' if restart_ok else 'error', restart_msg)
            self._redirect('settings')
            return
        self._send(404, b'not found\n', 'text/plain; charset=utf-8')

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query)
        lang = detect_lang(self.headers, params)
        self._wmbus_lang = lang
        path = self._route_path(parsed.path)
        known = {'/', '/meters', '/discover', '/search', '/search-discover', '/candidate', '/logs', '/settings', '/about', '/ignore', '/unignore', '/config', '/search-control', '/restart-bridge', '/add-meter', '/remove-meter'}

        if path.endswith('/api/status'):
            self._send(200, json.dumps(state(), ensure_ascii=False, indent=2).encode('utf-8'), 'application/json; charset=utf-8')
            return
        if path.endswith('/healthz'):
            self._send(200, b'ok\n', 'text/plain; charset=utf-8')
            return
        if path == '/ignore':
            add_ignored((params.get('id') or [''])[0])
            self._redirect('discover')
            return
        if path == '/unignore':
            remove_ignored((params.get('id') or [''])[0])
            self._redirect('discover?ignored=1')
            return
        if path == '/config':
            mid = (params.get('id') or [''])[0]
            all_data = state(include_ignored=True)
            candidate = next((c for c in all_data['candidates'] if c.get('id') == mid), None)
            payload = json.dumps(candidate_config(candidate or {'id': mid}), ensure_ascii=False, indent=2)
            self._send(200, payload.encode('utf-8'), 'application/json; charset=utf-8')
            return
        if path in known:
            self._send(200, render_page(path, params, lang).encode('utf-8'), 'text/html; charset=utf-8')
            return
        self._send(404, b'not found\n', 'text/plain; charset=utf-8')


def main() -> None:
    BASE.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    print(f'[wmbus-webui] serving dashboard on 0.0.0.0:{PORT} base={BASE}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
#!/usr/bin/env python3
"""Home Assistant Discovery and state for decoded telegrams, in one process.

A Python port of the publishing path of bridge-lib: publish_decoded_json
(12-pipeline.sh), inject_rssi_into_json (13-esp.sh), emit_discovery_from_json
and clean_legacy_entities (09-discovery.sh) and the classification helpers of
08-discovery-helpers.sh. It runs inside mqtt_publisher.py, so a decoded
telegram costs no process and no broker connection; bash keeps its own copy as
the fallback when the publisher is not available.

What it publishes has to be byte for byte what the bash path publishes:
tests/test_publish_contract.sh runs the same scenarios through both and
compares them with one recorded file. JSON is therefore read and written with
bridge_ledger's jq equivalents, not with the json module defaults.
"""

from __future__ import annotations

import fnmatch
import re
import subprocess
from typing import Any, Callable, Dict, List, Optional, Tuple

import bridge_ledger as bl

Publish = Tuple[str, bytes, bool]

_SKIP_KEYS = frozenset(("_", "id", "name", "meter", "media", "timestamp", "device_date_time",
                        "rssi", "lqi", "status"))
_BASH_SPACE = re.compile(r"[ \t\n\v\f\r]")
_HEX = re.compile(r"[0-9A-F]+")
_HEX8 = re.compile(r"[0-9A-Fa-f]{8}")
_DIGITS = re.compile(r"[0-9]+")
_NEG_DIGITS = re.compile(r"-[0-9]+")
_DRIVER = re.compile(r"[a-z0-9_]+")
_TEMPLATED = re.compile(r"\{.*\}")


# ── helpers shared with bash ────────────────────────────────────────────────

def obj_id(text: str) -> str:
    """01-utils.sh _obj_id."""
    s = re.sub(r"[^a-z0-9_]", "_", text.lower())
    while "__" in s:
        s = s.replace("__", "_")
    if s.startswith("_"):
        s = s[1:]
    if s.endswith("_"):
        s = s[:-1]
    return s


def normalize_meter_id(raw: str) -> str:
    """05-raw.sh normalize_meter_id."""
    mid = _BASH_SPACE.sub("", raw)
    if not mid or mid == "null":
        return ""
    if mid.startswith("0x"):
        mid = mid[2:]
    if mid.startswith("0X"):
        mid = mid[2:]
    mid = mid.upper()
    if not _HEX.fullmatch(mid):
        return ""
    if len(mid) < 8:
        return mid.rjust(8, "0")
    if len(mid) > 8:
        return bl.meter_id_from_raw_hex(mid)
    return mid


def _alt(value: Any, default: Any) -> Any:
    """jq's `a // b`: b when a is null or false."""
    return default if value is None or value is False else value


def _jq_type(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, str):
        return "string"
    if isinstance(value, dict):
        return "object"
    if isinstance(value, list):
        return "array"
    return "number"


def _glob(name: str, pattern: str) -> bool:
    """bash `[[ name == pattern ]]` with an unquoted pattern."""
    return fnmatch.fnmatchcase(name, pattern)


# ── 08-discovery-helpers.sh ─────────────────────────────────────────────────

_UNITS: List[Tuple[Tuple[str, ...], str]] = [
    (("*_kvarh",), "kVARh"), (("*_kvah",), "kVAh"), (("*_m3c",), "m³°C"), (("*_m3ch",), "m³°C/h"),
    (("*_m3h",), "m³/h"), (("*_mjh",), "MJ/h"), (("*_kvar",), "kVAR"), (("*_kva",), "kVA"),
    (("*_kwh",), "kWh"), (("*_kw",), "kW"), (("*_wh",), "Wh"), (("*_w",), "W"),
    (("*_lh",), "l/h"), (("*_jh",), "J/h"), (("*_gj",), "GJ"), (("*_mj",), "MJ"),
    (("*_dbm",), "dBm"), (("*_hca",), "hca"), (("*_pct",), "%"), (("*_ppm",), "ppm"),
    (("*_rh", "*humidity*", "*hum*"), "%"), (("*_hz",), "Hz"), (("*_bar",), "bar"),
    (("*_pa", "*pressure*", "*_hpa"), "hPa"), (("*_m3", "*volume*", "*m3*"), "m³"),
    (("*_mol",), "mol"), (("*_min",), "min"), (("*_rad",), "rad"), (("*_deg",), "°"),
    (("*_utc", "*_ut", "*_datetime", "*_date", "*_time", "*_month"), ""),
    (("*_counter",), ""), (("*_factor",), ""), (("*_txt",), ""), (("*_nr",), ""),
    (("*_kg",), "kg"), (("*_cd",), "cd"), (("*_v",), "V"), (("*_a",), "A"), (("*_k",), "K"),
    (("*temperature*", "*temp*", "*_c"), "°C"), (("*_f",), "°F"), (("*_l",), "l"),
    (("*_m",), "m"), (("*_s",), "s"), (("*_h",), "h"), (("*_d",), "d"), (("*_y",), "y"),
]


def guess_unit(key: str) -> str:
    k = key.lower()
    for patterns, unit in _UNITS:
        if any(_glob(k, p) for p in patterns):
            return unit
    return ""


def guess_device_class(key_lc: str, unit: str, media: str) -> str:
    simple = {"°C": "temperature", "%": "humidity", "W": "power", "kW": "power",
              "Wh": "energy", "kWh": "energy", "V": "voltage", "A": "current",
              "Hz": "frequency", "dBm": "signal_strength"}
    if unit in simple:
        return simple[unit]
    if unit == "m³":
        if media in ("water", "warm_water", "hot_water", "cold_water"):
            return "water"
        if media == "gas":
            return "gas"
        if media in ("heat", "cooling"):
            return ""
        return "gas" if "gas" in key_lc else "water"
    if "battery" in key_lc and unit in ("", "%"):
        return "battery"
    return ""


def is_consumption_unit(unit: str) -> bool:
    return unit in ("m³", "GJ", "MJ", "kWh", "Wh", "l", "hca", "kVARh", "kVAh")


def guess_state_class(key_lc: str, device_class: str) -> str:
    totals = ("energy", "water", "gas")
    if _glob(key_lc, "total_*") or _glob(key_lc, "*_total*") or _glob(key_lc, "*total_*"):
        if device_class in totals:
            return "total_increasing"
    if device_class == "energy" and ("consumption" in key_lc or "production" in key_lc):
        return "total_increasing"
    if "backflow" in key_lc and device_class in ("water", "gas"):
        return "total_increasing"
    if device_class in totals:
        return "total_increasing" if key_lc.startswith("current_") else ""
    if device_class in ("temperature", "humidity", "power", "voltage", "current", "frequency",
                        "signal_strength", "battery"):
        return "measurement"
    return ""


def excluded(patterns: str, key: str) -> bool:
    """field_excluded_for_meter for the patterns of one meter."""
    k = key.lower()
    return any(_glob(k, pat.lower()) for pat in patterns.split())


# ── the engine ──────────────────────────────────────────────────────────────

class Config:
    def __init__(self, env: Dict[str, str]):
        self.discovery_enabled = env.get("DISCOVERY_ENABLED", "true") == "true"
        self.discovery_prefix = env.get("DISCOVERY_PREFIX", "homeassistant")
        self.discovery_retain = env.get("DISCOVERY_RETAIN", "true") == "true"
        self.state_prefix = env.get("STATE_PREFIX", "wmbusmeters")
        self.state_retain = env.get("STATE_RETAIN", "false") == "true"
        self.require_timestamp = env.get("REQUIRE_TIMESTAMP", "false") == "true"
        self.rssi_file = env.get("STATUS_RSSI_FILE", "")
        self.seen_file = env.get("STATUS_SEEN_FILE", "")
        self.rssi_max_age_s = int(env.get("RSSI_MAX_AGE_S", "300") or 300)
        self.wmbusmeters_bin = env.get("WMBUSMETERS_BIN", "/usr/bin/wmbusmeters")


class Discovery:
    """The per-process caches of 09-discovery.sh, and what fills them."""

    def __init__(self, cfg: Config,
                 epoch: Callable[[], int] = lambda: int(bl.now()),
                 seen_avg: Optional[Callable[[str], int]] = None):
        self.cfg = cfg
        self.epoch = epoch
        self.seen_avg = seen_avg or (lambda mid: bl.seen_stats(cfg.seen_file, mid)[1])
        self.catalog: Dict[str, Dict[str, str]] = {}
        self.descriptions: Dict[str, str] = {}
        self.reset()

    def reset(self) -> None:
        """A new pipeline: bash starts it with empty Discovery caches."""
        self.sent: set = set()
        self.cleaned_legacy: set = set()

    # 13-esp.sh inject_rssi_into_json
    def inject_rssi(self, mid: str, line: str) -> str:
        path = self.cfg.rssi_file
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            return line
        if not data:
            return line
        mid = mid.lower()
        now = self.epoch()
        add: Dict[str, Any] = {}
        for raw in data.split(b"\n"):
            text = raw.decode("utf-8", "surrogateescape")
            if text.split("\t", 1)[0].lower() != mid:
                continue
            _rid, dbm, src, ts = bl._bash_read_tabs(text, 4)
            if not (_NEG_DIGITS.fullmatch(dbm) and _DIGITS.fullmatch(ts)):
                continue
            value = int(dbm)
            if not -125 <= value <= -1 or now - int(ts) > self.cfg.rssi_max_age_s:
                continue
            key = obj_id(src)
            if key:
                add[f"rssi_{key}_dbm"] = value
        if not add:
            return line
        values = bl.jq_values(line)
        if not values or not isinstance(values[0], dict):
            return line
        merged = dict(values[0])
        merged.update(add)
        return bl.jq_dumps(merged)

    # 08-discovery-helpers.sh load_field_catalog / field_description
    def _load_catalog(self, driver: str) -> Dict[str, str]:
        if driver in self.catalog:
            return self.catalog[driver]
        entries: Dict[str, str] = {}
        self.catalog[driver] = entries
        if not driver or driver in ("auto", "unknown") or not _DRIVER.fullmatch(driver):
            return entries
        try:
            out = subprocess.run([self.cfg.wmbusmeters_bin, f"--listfields={driver}"],
                                 capture_output=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            return entries
        for raw in out.decode("utf-8", "surrogateescape").split("\n"):
            line = raw.lstrip(" \t\n\v\f\r")
            if not line:
                continue
            name, sep, rest = line.partition("  ")
            desc = rest.lstrip(" \t\n\v\f\r") if sep else ""
            if not name:
                continue
            entries[name] = desc.replace('"', "").replace("\\", "")
        return entries

    def field_description(self, meter: str, key: str) -> str:
        driver, key = meter.lower(), key.lower()
        if not driver or not key:
            return ""
        cache = f"{driver}|{key}"
        if cache in self.descriptions:
            return self.descriptions[cache]
        found = ""
        for name, desc in self._load_catalog(driver).items():
            if _glob(key, _TEMPLATED.sub("*", name).lower()):
                found = desc
                break
        self.descriptions[cache] = found
        return found

    # 09-discovery.sh emit_discovery_from_json
    def emit_discovery(self, line: str, patterns: str, out: List[Publish]) -> None:
        cfg = self.cfg
        if not cfg.discovery_enabled:
            return
        values = bl.jq_values(line)
        if not values or not isinstance(values[0], dict):
            return
        obj = values[0]
        id_raw = bl._jq_tostring(_alt(obj.get("id"), ""))
        name = bl._jq_tostring(_alt(obj.get("name"), _alt(obj.get("id"), "wmbus")))
        meter = bl._jq_tostring(_alt(obj.get("meter"), ""))
        media = bl._jq_tostring(_alt(obj.get("media"), ""))
        mid = normalize_meter_id(id_raw)
        if not _HEX8.fullmatch(mid):
            return
        dp = cfg.discovery_prefix
        if mid not in self.cleaned_legacy:
            out.append((f"{dp}/sensor/wmbus_{mid}/rssi_dbm/config", b"", True))
            self.cleaned_legacy.add(mid)

        uniq = f"wmbus_{mid}"
        state_topic = f"{cfg.state_prefix}/{mid}/state"
        device = {"identifiers": [uniq], "name": f"{name} ({mid})",
                  "model": meter or "wmbusmeter", "manufacturer": "wmbusmeters"}
        expire = 3600
        avg = self.seen_avg(mid)
        if avg * 2 > expire:
            expire = avg * 2
        expire = (expire // 60) * 60

        for key, value in obj.items():
            if key in _SKIP_KEYS or isinstance(value, (dict, list)):
                continue
            ftype = _jq_type(value)
            obj_name = obj_id(key)
            if not key or not obj_name:
                continue
            cfg_topic = f"{dp}/sensor/{uniq}/{obj_name}/config"
            if excluded(patterns, key):
                cache = f"{mid}|{obj_name}|excluded"
                if cache not in self.sent:
                    out.append((cfg_topic, b"", True))
                    self.sent.add(cache)
                continue
            cache = f"{mid}|{obj_name}|{expire}"
            if cache in self.sent:
                continue
            key_lc = key.lower()
            if ftype == "number":
                unit = guess_unit(key)
                dclass = guess_device_class(key_lc, unit, media)
                sclass = guess_state_class(key_lc, dclass)
                ecat = "" if dclass or is_consumption_unit(unit) else "diagnostic"
            else:
                unit = dclass = sclass = ""
                ecat = "diagnostic"
            desc = self.field_description(meter, key)
            payload: Dict[str, Any] = {
                "name": f"{name} {key}",
                "unique_id": f"{uniq}_{obj_name}",
                "state_topic": state_topic,
                "value_template": "{{ value_json.get('%s') | default(none) }}" % key,
                "availability": [{
                    "topic": state_topic,
                    "value_template": "{{ 'online' if value_json.get('%s') is not none else 'offline' }}" % key,
                }],
                "json_attributes_topic": state_topic,
                "expire_after": expire,
                "device": device,
            }
            if unit:
                payload["unit_of_measurement"] = unit
            if dclass:
                payload["device_class"] = dclass
            if sclass:
                payload["state_class"] = sclass
            if ecat:
                payload["entity_category"] = ecat
                payload["enabled_by_default"] = False
            if desc:
                payload["json_attributes_template"] = (
                    '{{ dict(value_json, Description="%s") | tojson }}' % desc)
            out.append((cfg_topic, bl.jq_dumps(payload).encode(), cfg.discovery_retain))
            self.sent.add(cache)

        if "status" not in obj:
            return
        status_on = "{{ 'online' if value_json.get('status') is not none else 'offline' }}"
        if not excluded(patterns, "status"):
            cache = f"{mid}|status|{expire}"
            if cache not in self.sent:
                desc = self.field_description(meter, "status")
                payload = {
                    "name": f"{name} status",
                    "unique_id": f"{uniq}_status",
                    "state_topic": state_topic,
                    "value_template": "{{ value_json.get('status') | default(none) }}",
                    "availability": [{"topic": state_topic, "value_template": status_on}],
                    "json_attributes_topic": state_topic,
                    "entity_category": "diagnostic",
                    "icon": "mdi:alert-circle-outline",
                    "expire_after": expire,
                    "device": device,
                }
                if desc:
                    payload["json_attributes_template"] = (
                        '{{ dict(value_json, Description="%s") | tojson }}' % desc)
                out.append((f"{dp}/sensor/{uniq}/status/config", bl.jq_dumps(payload).encode(),
                            cfg.discovery_retain))
                self.sent.add(cache)
            cache = f"{mid}|status_problem|{expire}"
            if cache not in self.sent:
                payload = {
                    "name": f"{name} problem",
                    "unique_id": f"{uniq}_status_problem",
                    "state_topic": state_topic,
                    "value_template": ("{{ 'ON' if value_json.get('status') not in "
                                       "[none, 'OK', ''] else 'OFF' }}"),
                    "payload_on": "ON",
                    "payload_off": "OFF",
                    "device_class": "problem",
                    "availability": [{"topic": state_topic, "value_template": status_on}],
                    "entity_category": "diagnostic",
                    "expire_after": expire,
                    "device": device,
                }
                out.append((f"{dp}/binary_sensor/{uniq}/status_problem/config",
                            bl.jq_dumps(payload).encode(), cfg.discovery_retain))
                self.sent.add(cache)
        else:
            cache = f"{mid}|status|excluded"
            if cache not in self.sent:
                out.append((f"{dp}/sensor/{uniq}/status/config", b"", True))
                out.append((f"{dp}/binary_sensor/{uniq}/status_problem/config", b"", True))
                self.sent.add(cache)

    # 12-pipeline.sh publish_decoded_json
    def decoded(self, line: str, patterns: str) -> List[Publish]:
        """Everything one decoded telegram publishes, in order."""
        out: List[Publish] = []
        values = bl.jq_values(line)
        obj = values[0] if values and isinstance(values[0], dict) else {}
        raw_id = _alt(obj.get("id"), None)
        mid = normalize_meter_id(bl._jq_tostring(raw_id) if raw_id is not None else "")
        if not _HEX8.fullmatch(mid):
            return out
        ts = _alt(obj.get("timestamp"), _alt(obj.get("device_date_time"), None))
        if self.cfg.require_timestamp and (ts is None or bl._jq_tostring(ts) == ""):
            return out
        line = self.inject_rssi(mid, line)
        self.emit_discovery(line, patterns, out)
        out.append((f"{self.cfg.state_prefix}/{mid}/state", line.encode(), self.cfg.state_retain))
        return out

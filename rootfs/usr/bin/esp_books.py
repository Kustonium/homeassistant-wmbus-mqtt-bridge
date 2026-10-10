#!/usr/bin/env python3
"""Bookkeeping of the ESP subscribers that were bash loops in 13-esp.sh.

Each class is one subscriber, ported line for line: it is handed what
mosquitto_sub printed (one line at a time, split as the bash `read` did) and
writes the same file the loop wrote, byte for byte. mqtt_publisher.py runs
them on its broker connection (make_books); tests/test_esp_books.py runs the
bash loop and the class on one corpus and compares the files.
"""

from __future__ import annotations

import os
import re
from typing import Any, Optional

import bridge_ledger as bl

_SPACE = re.compile(r"[ \t\n\v\f\r]")


def jq_pretty(value: Any, indent: int = 0) -> str:
    """`jq .` output of one value (two-space indent), without the final newline."""
    pad, inner = " " * indent, " " * (indent + 2)
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = [inner + bl._jq_string(k) + ": " + jq_pretty(v, indent + 2) for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(value, list):
        if not value:
            return "[]"
        return "[\n" + ",\n".join(inner + jq_pretty(v, indent + 2) for v in value) + "\n" + pad + "]"
    return bl.jq_dumps(value)


def jq_argjson(text: str) -> Optional[Any]:
    """The value of `--argjson p "$text"`, or None where jq refuses it: the
    text must be exactly one JSON value (whitespace around it allowed)."""
    i, n = 0, len(text)
    while i < n and text[i] in bl._JQ_WS:
        i += 1
    try:
        value, j = bl._DECODER.raw_decode(text, i)
    except ValueError:
        return None
    while j < n and text[j] in bl._JQ_WS:
        j += 1
    return value if j == n else None


class _JqError(Exception):
    """The jq program would stop with an error: bash then writes nothing."""


def jq_add(a: Any, b: dict) -> dict:
    """jq's `a + b` for an object b: null + b is b; anything but an object fails."""
    if a is None:
        return dict(b)
    if not isinstance(a, dict):
        raise _JqError(f"cannot add an object to {type(a).__name__}")
    out = dict(a)
    out.update(b)
    return out


def jq_inputs(text: str) -> list:
    """The values jq reads from text; _JqError when it would stop at a parse error."""
    values = bl.jq_values(text)
    if _trailing_garbage(text):
        raise _JqError("parse error")
    return values


def _read_current(path: str) -> str:
    """`$(cat file)`, {} when missing or empty (command substitution drops the
    trailing newlines)."""
    try:
        with open(path, "rb") as fh:
            text = fh.read().decode("utf-8", "surrogateescape")
    except OSError:
        text = ""
    return text.rstrip("\n") or "{}"


def _write_outputs(path: str, outputs: list) -> None:
    _replace(path, "".join(jq_pretty(v) + "\n" for v in outputs).encode("utf-8", "surrogateescape"))


def _replace(path: str, data: bytes) -> None:
    """`... > path.tmp && mv path.tmp path`: the same temporary name as bash."""
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)


class DeviceMapBook:
    """wmbus/<board><suffix> -> a JSON map keyed by board (13-esp.sh's health,
    meters and meter_snapshot loops, which differ only in suffix and file).

    `jq '. + {($dev): ($p + {_bridge_rx_epoch: $t})}'` over the current file
    ({} when missing or empty). A payload jq cannot take, or a current file
    that is not an object, leaves the file as it is.
    """

    suffix = ""

    def __init__(self, path: str) -> None:
        self.path = path

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not payload_b:
            return
        topic = bl._s(topic_b)
        dev = topic[len("wmbus/"):] if topic.startswith("wmbus/") else topic
        dev = dev[:-len(self.suffix)] if dev.endswith(self.suffix) else dev
        if not dev or dev == topic:
            return
        ts = int(bl.now())
        text = bl._s(payload_b)
        payload = jq_argjson(text)
        if payload is None and text.strip(bl._JQ_WS) != "null":
            return  # --argjson refused it: jq does not run
        try:
            entry = jq_add(payload, {"_bridge_rx_epoch": ts})
            # The filter runs once per value of the current file.
            outputs = [jq_add(cur, {dev: entry}) for cur in jq_inputs(_read_current(self.path))]
        except _JqError:
            return
        _write_outputs(self.path, outputs)


class SummaryBook:
    """wmbus/+/diag/summary -> status_esp_diag.json (the last summary).

    13-esp.sh pipes the payload line into `jq '. + {_bridge_rx_epoch: $t,
    _topic: $topic}'`: every JSON value of the line is one input, and a parse
    or type error anywhere keeps the file as it is.
    """

    def __init__(self, path: str) -> None:
        self.path = path

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not payload_b:
            return
        add = {"_bridge_rx_epoch": int(bl.now()), "_topic": bl._s(topic_b)}
        try:
            outputs = [jq_add(v, add) for v in jq_inputs(bl._s(payload_b) + "\n")]
        except _JqError:
            return
        _write_outputs(self.path, outputs)


class MeterWindowBook:
    """wmbus/<board>/diag/meter/<id>/<mode>/window/<trigger> ->
    status_esp_meter_window.json, a map board -> meter id -> last window.

    `($p.id // "") as $id | if $id == "" then .
     else .[$dev] = ((.[$dev] // {}) + {($id): ($p + {_bridge_rx_epoch: $t})}) end`
    """

    def __init__(self, path: str) -> None:
        self.path = path

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not payload_b:
            return
        topic = bl._s(topic_b)
        dev = topic[len("wmbus/"):] if topic.startswith("wmbus/") else topic
        cut = dev.find("/diag/meter/")
        dev = dev[:cut] if cut >= 0 else dev
        if not dev or dev == topic:
            return
        ts = int(bl.now())
        text = bl._s(payload_b)
        p = jq_argjson(text)
        if p is None and text.strip(bl._JQ_WS) != "null":
            return
        try:
            if p is None:
                mid = None
            elif isinstance(p, dict):
                mid = p.get("id")
            else:
                raise _JqError("cannot index")
            mid = "" if mid is None or mid is False else mid
            outputs = []
            for cur in jq_inputs(_read_current(self.path)):
                if mid == "":
                    outputs.append(cur)
                    continue
                if not isinstance(mid, str):
                    raise _JqError("object keys must be strings")
                if cur is not None and not isinstance(cur, dict):
                    raise _JqError("cannot index with a string")
                board = (cur or {}).get(dev)
                board = {} if board is None or board is False else board
                merged = dict(cur or {})
                merged[dev] = jq_add(board, {mid: jq_add(p, {"_bridge_rx_epoch": ts})})
                outputs.append(merged)
        except _JqError:
            return
        _write_outputs(self.path, outputs)


class HealthBook(DeviceMapBook):
    """wmbus/+/health -> status_esp_health.json (always-on radio pulse)."""
    suffix = "/health"


class MetersBook(DeviceMapBook):
    """wmbus/+/meters -> status_esp_meters.json (target/highlight per board)."""
    suffix = "/meters"


class MeterSnapshotBook(DeviceMapBook):
    """wmbus/+/diag/meter_snapshot -> status_esp_meter_snapshot.json."""
    suffix = "/diag/meter_snapshot"


def jq_add_each(text: str, add: dict) -> tuple:
    """`printf '%s\\n' "$text" | jq '. + $add'`: (outputs, exit status 0).

    jq goes on to the next input after a type error and stops at a parse
    error; either way the outputs written so far stay in the redirect."""
    outputs, ok = [], not _trailing_garbage(text)
    for v in bl.jq_values(text):
        try:
            outputs.append(jq_add(v, add))
        except _JqError:
            ok = False
    return outputs, ok


def _jq_raw(value: Any) -> str:
    """One output of `jq -r`: a string as it is, anything else as `jq .`."""
    return value if isinstance(value, str) else jq_pretty(value)


def _event_type(payload: str) -> str:
    """`$(printf '%s\\n' "$p" | jq -r '.event // "unknown"' || echo unknown)`,
    then 13-esp.sh's fallback for an empty or "null" answer."""
    text = payload + "\n"
    out, failed = [], _trailing_garbage(text)
    for v in bl.jq_values(text):
        if v is None:
            out.append("unknown")
        elif isinstance(v, dict):
            e = v.get("event")
            out.append("unknown" if e is None or e is False else _jq_raw(e))
        else:
            failed = True  # cannot index a number, string, array or boolean
    evtype = ("".join(o + "\n" for o in out) + ("unknown\n" if failed else "")).rstrip("\n")
    return evtype if evtype and evtype != "null" else "unknown"


def _is_one(value: Any) -> bool:
    """jq's `. == 1` (numbers compare as doubles; true is not 1)."""
    return isinstance(value, bl.Decimal) and float(value) == 1.0


def split_retained_line(line: bytes) -> tuple:
    """`IFS=$'\\t' read -r retained topic payload` of one `-F '%r\\t%t\\t%p'` line."""
    rest = line.rstrip(b"\n").strip(b"\t")
    fields = []
    for _ in range(2):
        head, sep, rest = rest.partition(b"\t")
        fields.append(head)
        rest = rest.lstrip(b"\t") if sep else b""
    return fields[0], fields[1], rest


class DiagEventsBook:
    """wmbus/+/diag and wmbus/+/diag/# -> the ESP event log and its side files
    (13-esp.sh's diagnostic events loop, which read `-F '%r\\t%t\\t%p'`).

    - <board>/diag/config: the board's settings, merged into the config file
      (retained ones too: that is how the settings are learned);
    - retained replays stop there; a boot repeated with the same payload too;
    - every other message is a row of the events TSV (epoch, type, topic,
      payload), cut to the last 200 rows every 50 rows;
    - lr_fifo/lr_drop samples go to the persistent diag history when enabled;
    - a suggestion or boot is kept as its own JSON (a boot drops the suggestion).
    """

    def __init__(self, events_file: str, suggestion_file: str, boot_file: str, config_file: str,
                 history_file: str = "", history_enabled: bool = False) -> None:
        self.events_file = events_file
        self.suggestion_file = suggestion_file
        self.boot_file = boot_file
        self.config_file = config_file
        self.history_file = history_file
        self.history_enabled = history_enabled and bool(history_file)
        self.n = 0
        self.since_trim = 0
        self.boot_seen: dict = {}

    def __call__(self, retained_b: bytes, topic_b: bytes, payload_b: bytes) -> None:
        if not topic_b or not payload_b:
            return
        topic, payload = bl._s(topic_b), bl._s(payload_b)
        ts = int(bl.now())
        if topic.startswith("wmbus/") and topic.endswith("/diag/config") and len(topic) > 18:
            self._config(topic[6:-12], ts, payload)
        if retained_b == b"1":
            return
        evtype = _event_type(payload)
        if topic.endswith("/summary_15min"):
            evtype = "summary_15min"
        elif topic.endswith("/summary_60min"):
            evtype = "summary_60min"
        if evtype == "boot" and not self._boot_is_new(topic, payload):
            return
        with open(self.events_file, "ab") as fh:
            fh.write(bl._b(f"{ts}\t{evtype}\t{topic}\t{payload}\n"))
        tail = topic[6:] if topic.startswith("wmbus/") else None
        if self.history_enabled and tail is not None and (
                "/diag/lr_fifo/" in tail or "/diag/lr_drop/" in tail):
            src = topic[6:]
            src = src[:src.find("/diag/")] if "/diag/" in src else src
            self._history(ts, src, topic, payload)
            self.since_trim += 1
            if self.since_trim >= 100:
                bl.trim_locked(self.history_file, 10000, 9000)
                self.since_trim = 0
        self.n += 1
        if self.n % 50 == 0:
            bl._replace_with(self.events_file, bl._tail_lines(self.events_file, 200))
        if evtype == "suggestion":
            self._keep(self.suggestion_file, payload, ts)
        if evtype == "boot":
            self._keep(self.boot_file, payload, ts)
            # A suggestion from before the restart is no longer actionable.
            try:
                os.unlink(self.suggestion_file)
            except OSError:
                pass

    def _config(self, src: str, ts: int, payload: str) -> None:
        if not src:
            return
        pl = jq_argjson(payload)
        if pl is None and payload.strip(bl._JQ_WS) != "null":
            return  # --argjson refused it: jq does not run, the file stays
        # `[[ -s file ]] && cur="$(cat file)"`, else {}: unlike _read_current a
        # file of newlines gives jq no input at all, and an empty file results.
        try:
            with open(self.config_file, "rb") as fh:
                data = fh.read()
        except OSError:
            data = b""
        cur = bl._s(data).rstrip("\n") if data else "{}"
        try:
            outputs = [jq_add(c, {src: jq_add(pl, {"_bridge_rx_epoch": ts})}) for c in jq_inputs(cur)]
        except _JqError:
            return
        _write_outputs(self.config_file, outputs)

    def _boot_is_new(self, topic: str, payload: str) -> bool:
        src = topic[6:] if topic.startswith("wmbus/") else topic
        cut = src.find("/diag")
        src = src[:cut] if cut >= 0 else src
        if not src:
            return True
        if self.boot_seen.get(src) == payload:
            return False
        self.boot_seen[src] = payload
        return True

    def _history(self, ts: int, src: str, topic: str, payload: str) -> None:
        """_append_esp_diag_history: the fifo_sample/pipeline_drop records, -c."""
        text = payload + "\n"
        if _trailing_garbage(text):
            return
        lines = []
        for v in bl.jq_values(text):
            if v is None:
                continue
            if not isinstance(v, dict):
                return  # jq stops with an error: nothing is appended
            if not _is_one(v.get("schema")) or v.get("kind") not in ("fifo_sample", "pipeline_drop"):
                continue
            lines.append(bl.jq_dumps(jq_add(v, {"bridge_rx_time": ts, "source": src, "topic": topic})))
        if lines:
            bl.append_locked(self.history_file, "\n".join(lines))

    @staticmethod
    def _keep(path: str, payload: str, ts: int) -> None:
        """`jq '. + {_bridge_rx_epoch: $t}' > path.tmp && mv path.tmp path`."""
        outputs, ok = jq_add_each(payload + "\n", {"_bridge_rx_epoch": ts})
        data = "".join(jq_pretty(v) + "\n" for v in outputs).encode("utf-8", "surrogateescape")
        tmp = path + ".tmp"
        with open(tmp, "wb") as fh:
            fh.write(data)
        if ok:
            os.replace(tmp, path)


def _glob_mid(topic: str, prefix: str, suffix: str) -> bool:
    """bash `[[ $topic == prefix*suffix ]]` (the * may hold slashes or nothing)."""
    return topic.startswith(prefix) and topic.endswith(suffix) and len(topic) >= len(prefix) + len(suffix)


class BrokerInfoBook:
    """$SYS broker identity -> status_broker_info.txt ("brand<TAB>version<TAB>clients").

    Mosquitto publishes $SYS/broker/version ("mosquitto version X.Y.Z") and
    $SYS/broker/clients/connected; EMQX $SYS/brokers/<node>/sysdescr ("EMQX"),
    .../version and .../clients/count. The three values are kept across
    messages and reconnects, as the bash loop kept them.
    """

    FILTERS = ("$SYS/broker/version", "$SYS/brokers/+/version", "$SYS/brokers/+/sysdescr",
               "$SYS/broker/clients/connected", "$SYS/brokers/+/clients/count")

    def __init__(self, path: str) -> None:
        self.path = path
        self.brand = self.version = self.clients = ""

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not payload_b:
            return
        topic, payload = bl._s(topic_b), bl._s(payload_b)
        if topic == "$SYS/broker/version":
            self.brand = "Mosquitto"
            cut = payload.rfind("version ")
            self.version = payload[cut + len("version "):] if cut >= 0 else payload
        elif _glob_mid(topic, "$SYS/brokers/", "/sysdescr"):
            self.brand = payload
        elif _glob_mid(topic, "$SYS/brokers/", "/version"):
            self.version = payload
        elif topic == "$SYS/broker/clients/connected" or _glob_mid(topic, "$SYS/brokers/", "/clients/count"):
            # Mosquitto and EMQX count under different paths; digits only.
            self.clients = re.sub(r"[^0-9]", "", payload)
        else:
            return
        if not (self.brand or self.version or self.clients):
            return
        _replace(self.path, bl._b(f"{self.brand}\t{self.version}\t{self.clients}\n"))

    def refused(self) -> None:
        """The broker refused every $SYS filter (EMQX's default ACL gives $SYS
        to localhost clients only): recorded for the WebUI unless an answer
        came earlier."""
        if not (self.brand or self.version or self.clients):
            _replace(self.path, b"\t\t\tdenied\n")


def _trailing_garbage(text: str) -> bool:
    """True when text holds anything after its JSON values that jq would fail on."""
    i, n = 0, len(text)
    while True:
        while i < n and text[i] in bl._JQ_WS:
            i += 1
        if i >= n:
            return False
        try:
            _, i = bl._DECODER.raw_decode(text, i)
        except ValueError:
            return True


class HaPresenceBook:
    """<discovery_prefix>/status -> status_ha_presence.txt ("state<TAB>epoch").

    The loop read `mosquitto_sub -F '%p'`, so it is handed payload lines; all
    whitespace is dropped and case folded, and only online/offline count.
    """

    def __init__(self, presence_file: str) -> None:
        self.path = presence_file

    def __call__(self, _topic_b: bytes, line_b: bytes) -> None:
        if not line_b:
            return
        state = _SPACE.sub("", bl._s(line_b)).lower()
        if state not in ("online", "offline"):
            return
        _replace(self.path, f"{state}\t{int(bl.now())}\n".encode())

#!/usr/bin/env python3
"""Per-message bookkeeping of the bridge, in one long-lived process.

WHY
---
Every MQTT message from every ESP used to be booked by bash: the RAW counter,
the per-board tracker, the /rx and rssi/<id> subscribers and the LISTEN block
handler. Each of them started tens of processes per message (awk, jq, mv,
mktemp, flock, date and $(...) subshells - see tests/test_perf_fork_budget.sh),
which on a 5-ESP site kept a CPU core busy doing nothing but process start-up.
This module does the same bookkeeping in-process. It is introduced one path at
a time; each path keeps its bash implementation until it is switched over.

CONTRACT
--------
* Files keep their exact formats. webui.py and the bash code that stays (the
  decode loop, tickers, inject_rssi_into_json) read them unchanged.
* Locking is shared with bash. flock(1) and fcntl.flock() take the same kind of
  lock (BSD flock on an open file description), so taking "<file>.lock" here
  serialises with _tsv_upsert and the other locked helpers in 03-tsv.sh.
* Temporary files are created next to the target as "<file>.tmp.XXXXXX" with
  mode 0600, like mktemp(1), and moved into place with one rename.
* Keys are compared as strings. BusyBox awk in the add-on image compares two
  numeric-looking fields numerically, so the bash helpers treat ids such as
  00001000 and 0001E003 as equal (both are 1000) and one row replaces the
  other. Here they stay two rows, which is what the ids mean.
* No MQTT client library: input is the stdout of mosquitto_sub -F '%t\\t%p',
  one "topic<TAB>payload" message per line. A message that fails is reported
  on stderr and skipped; the process never exits because of its input.
"""
from __future__ import annotations

import argparse
import fcntl
import glob
import json
import math
import os
import re
import sys
import tempfile
import time
from decimal import Decimal
from contextlib import contextmanager
from typing import Any, Callable, Dict, Iterator, List, Optional, Set, Tuple

# The clock every handler reads. Tests replace it to get fixed timestamps.
now: Callable[[], float] = time.time


@contextmanager
def locked(path: str) -> Iterator[None]:
    """Hold the exclusive lock bash takes with `( flock -x 9 ...) 9>"$path.lock"`."""
    fd = os.open(path + ".lock", os.O_WRONLY | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)  # closing the descriptor releases the lock


def _read_lines(path: str) -> List[bytes]:
    """Lines of a file without their newline; a missing file has none."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except FileNotFoundError:
        return []
    if not data:
        return []
    lines = data.split(b"\n")
    if data.endswith(b"\n"):
        lines.pop()
    return lines


def _replace_with(path: str, lines: List[bytes]) -> None:
    """Write lines to a fresh temporary file and rename it over path."""
    directory, base = os.path.split(path)
    fd, tmp = tempfile.mkstemp(prefix=base + ".tmp.", dir=directory or ".")
    try:
        with os.fdopen(fd, "wb") as fh:
            for line in lines:
                fh.write(line + b"\n")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _first_field(line: bytes) -> bytes:
    return line.split(b"\t", 1)[0]


def _b(text: str) -> bytes:
    """Back to the exact bytes that arrived (see _s)."""
    return text.encode("utf-8", "surrogateescape")


def _s(data: bytes) -> str:
    """Text for processing; bytes that are not UTF-8 survive the round trip."""
    return data.decode("utf-8", "surrogateescape")


def tsv_upsert(path: str, key: str, row: str) -> None:
    """_tsv_upsert: drop the rows keyed `key`, append `row`, atomically."""
    k = _b(key)
    with locked(path):
        lines = [ln for ln in _read_lines(path) if _first_field(ln) != k]
        lines.append(_b(row))
        _replace_with(path, lines)


def tsv_remove(path: str, key: str) -> None:
    """_tsv_remove_id: drop the rows keyed `key`; no-op for a missing file."""
    if not os.path.isfile(path):
        return
    k = _b(key)
    with locked(path):
        lines = [ln for ln in _read_lines(path) if _first_field(ln) != k]
        _replace_with(path, lines)


def append_locked(path: str, line: str) -> None:
    """Append one line under the file's lock (the JSONL history appends)."""
    with locked(path):
        with open(path, "ab") as fh:
            fh.write(_b(line) + b"\n")


def trim_locked(path: str, max_lines: int, keep_lines: int) -> None:
    """_trim_esp_rx_history: above max_lines, keep only the last keep_lines."""
    if not os.path.isfile(path):
        return
    with locked(path):
        lines = _read_lines(path)
        if len(lines) <= max_lines:
            return
        _replace_with(path, lines[-keep_lines:] if keep_lines > 0 else [])


def split_message(line: bytes) -> Tuple[bytes, bytes]:
    """Split one mosquitto_sub line the way `IFS=$'\\t' read -r topic payload` does.

    TAB is IFS whitespace there, so leading and trailing tabs are dropped and a
    run of tabs counts as one separator; spaces are kept.
    """
    line = line.rstrip(b"\n").strip(b"\t")
    topic, sep, payload = line.partition(b"\t")
    if sep:
        payload = payload.lstrip(b"\t")
    return topic, payload


Handler = Callable[[bytes, bytes], None]

_HEX8 = re.compile(r"[0-9A-Fa-f]{8}")
_NEG_INT = re.compile(r"-[0-9]+")


def bash_int(text: str) -> Optional[int]:
    """A decimal-looking string as bash arithmetic reads it, None where bash errors.

    A leading 0 makes bash read the digits as octal ("-070" is -56), and 8 or 9
    after it is an error, which the bash handlers treat as a rejected value.
    """
    sign = -1 if text.startswith("-") else 1
    digits = text.lstrip("-")
    try:
        if len(digits) > 1 and digits.startswith("0"):
            return sign * int(digits, 8)
        return sign * int(digits, 10)
    except ValueError:
        return None


def meter_ids_in(meter_dir: str) -> Set[str]:
    """Configured meter ids: the id= lines of METER_DIR/meter-* (_rssi_load_wanted).

    Like `while IFS= read -r` there, a line is taken verbatim and a last line
    without a newline is not read at all.
    """
    wanted: Set[str] = set()
    for path in glob.glob(os.path.join(meter_dir, "meter-*")):
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "rb") as fh:
                complete_lines = fh.read().split(b"\n")[:-1]
        except OSError:
            continue
        for line in complete_lines:
            text = _s(line)
            if text.startswith("id=") and _HEX8.fullmatch(text[3:]):
                wanted.add(text[3:].upper())
    return wanted


class RssiBook:
    """_esp_rssi_handle_message: last RSSI per (meter, board) for configured meters.

    status_rssi.tsv: id<TAB>dbm<TAB>board<TAB>epoch, one row per (id, board).
    """

    RELOAD_S = 30

    def __init__(self, meter_dir: str, rssi_file: str) -> None:
        self.meter_dir = meter_dir
        self.rssi_file = rssi_file
        self.wanted: Set[str] = set()
        self.wanted_at = 0

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not payload_b:
            return
        topic, val = _s(topic_b), _s(payload_b)
        # Topic tail after the last ".../rssi/" is the meter id.
        meter_id = topic.rsplit("/rssi/", 1)[-1]
        if not _HEX8.fullmatch(meter_id):
            return
        meter_id = meter_id.upper()
        ts = int(now())
        if ts - self.wanted_at >= self.RELOAD_S:
            self.wanted = meter_ids_in(self.meter_dir)
            self.wanted_at = ts
        if meter_id not in self.wanted:
            return
        # Board = topic segment between "wmbus/" and the first "/rssi/".
        board = topic[len("wmbus/"):] if topic.startswith("wmbus/") else topic
        board = board.split("/rssi/", 1)[0]
        # A plausible measured level only; the firmware's "no data" sentinels
        # (1, 0, -127) must never become a reading.
        if not _NEG_INT.fullmatch(val):
            return
        dbm = bash_int(val)
        if dbm is None or not -125 <= dbm <= -1:
            return
        rssi_upsert(self.rssi_file, meter_id, board, f"{meter_id}\t{val}\t{board}\t{ts}")


def rssi_upsert(path: str, meter_id: str, board: str, row: str) -> None:
    """_rssi_tsv_upsert: replace the row of (meter_id, board), keep the other boards."""
    k1, k3 = _b(meter_id), _b(board)
    with locked(path):
        kept = []
        for line in _read_lines(path):
            fields = line.split(b"\t")
            if fields[0] != k1 or (fields[2] if len(fields) > 2 else b"") != k3:
                kept.append(line)
        kept.append(_b(row))
        _replace_with(path, kept)

# ── jq-compatible JSON ──────────────────────────────────────────────────────
# The /rx history is a JSONL file other tools read, so it is written exactly as
# jq 1.7.1 in the add-on image writes it: numbers keep the literal they arrived
# with in the canonical decNumber form (1.0 stays 1.0, 1e3 becomes 1E+3 - the
# same form Python's Decimal prints), a repeated key keeps its first position
# and its last value, and control characters and DEL are escaped as \u00XX.

class _JqDecoder(json.JSONDecoder):
    def __init__(self) -> None:
        super().__init__(parse_float=Decimal, parse_int=Decimal,
                         parse_constant=self._reject, object_pairs_hook=self._pairs)

    @staticmethod
    def _reject(name: str) -> Any:
        raise ValueError(f"unsupported literal {name}")

    @staticmethod
    def _pairs(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
        obj: Dict[str, Any] = {}
        for key, value in pairs:
            obj[key] = value
        return obj


_DECODER = _JqDecoder()
_JQ_WS = " \t\n\r"


def jq_values(text: str) -> List[Any]:
    """The JSON values of a jq input stream, up to the first parse error."""
    values: List[Any] = []
    i, n = 0, len(text)
    while True:
        while i < n and text[i] in _JQ_WS:
            i += 1
        if i >= n:
            return values
        try:
            value, i = _DECODER.raw_decode(text, i)
        except ValueError:
            return values
        values.append(value)


_JQ_ESCAPES = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f", "\n": "\\n",
               "\r": "\\r", "\t": "\\t"}


def _jq_string(text: str) -> str:
    out = []
    for ch in text:
        esc = _JQ_ESCAPES.get(ch)
        if esc is not None:
            out.append(esc)
        elif ch < " " or ch == "\x7f":
            out.append("\\u%04x" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def jq_dumps(value: Any) -> str:
    """`jq -c` output for a value read by jq_values (or built from str/int)."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (Decimal, int)):
        return str(value)
    if isinstance(value, str):
        return _jq_string(value)
    if isinstance(value, list):
        return "[" + ",".join(jq_dumps(v) for v in value) + "]"
    if isinstance(value, dict):
        return "{" + ",".join(_jq_string(k) + ":" + jq_dumps(v) for k, v in value.items()) + "}"
    raise TypeError(f"not a JSON value: {value!r}")


def _is_number(value: Any) -> bool:
    return isinstance(value, Decimal)


def _num(value: Decimal) -> float:
    """jq compares numbers as doubles."""
    return float(value)


def _integral(x: float) -> bool:
    """jq's `(x|floor) == x`; an infinite value passes, as it does in jq."""
    return math.isinf(x) or math.floor(x) == x


# jq's test() is Oniguruma with Perl syntax: "$" also matches before a final
# newline, exactly as Python's re.search with "$" does.
_RX_HEX8 = re.compile(r"^[0-9A-Fa-f]{8}$")
_RX_RECEIVED_AT = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$")
_RX_MODES = ("T1", "C1", "S1")


def normalize_rx(value: Any) -> Optional[Dict[str, Any]]:
    """_normalize_esp_rx_payload for one JSON value; None where jq selects nothing.

    Every check reads like the jq filter it replaces, including its `and`
    short-circuits; a value jq cannot index (number, string, array) is
    skipped as the error jq reports for it.
    """
    if not isinstance(value, dict):
        return None
    v = value
    schema = v.get("schema")
    if not (_is_number(schema) and _num(schema) == 1):
        return None
    boot = v.get("boot_id")
    if not (isinstance(boot, str) and _RX_HEX8.search(boot)):
        return None
    seq = v.get("seq")
    if not (_is_number(seq) and _num(seq) >= 1 and _integral(_num(seq))):
        return None
    wake = v.get("rx_task_wakeup_us")
    if not (_is_number(wake) and _num(wake) >= 0):
        return None
    meter = v.get("meter_id")
    if not (isinstance(meter, str) and _RX_HEX8.search(meter)):
        return None
    if v.get("mode") not in _RX_MODES or not isinstance(v.get("mode"), str):
        return None
    rssi = v.get("rssi_dbm")
    if not (rssi is None or (_is_number(rssi) and -125 <= _num(rssi) <= -1)):
        return None
    crc = v.get("frame_crc32")
    if not (isinstance(crc, str) and _RX_HEX8.search(crc)):
        return None
    length = v.get("frame_length")
    if not (_is_number(length) and _num(length) > 0 and _integral(_num(length))):
        return None
    out = dict(v)
    # A malformed received_at drops the field, never the frame.
    if "received_at" in out and out["received_at"] is not None:
        rcv = out["received_at"]
        if not isinstance(rcv, str) or not _RX_RECEIVED_AT.search(rcv):
            del out["received_at"]
    for key in ("boot_id", "meter_id", "frame_crc32"):
        out[key] = _ascii_upper(out[key])
    return out


def _ascii_upper(text: str) -> str:
    return "".join(chr(ord(c) - 32) if "a" <= c <= "z" else c for c in text)


_RX_DATE = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z\n?")


def received_epoch(value: Any) -> str:
    """The received_at field as the bash handler's jq turns it into an epoch.

    `sub("\\.[0-9]+Z$";"Z") | fromdateiso8601`, caught to "" on error. On the
    image (musl strptime + timegm) a day past the month's end rolls over,
    second 60 is accepted, and a result of -1 counts as an error.
    """
    if not value:
        return ""
    if not isinstance(value, str):
        return ""
    text = re.sub(r"\.[0-9]+Z(?=\n?$)", "Z", value, count=1)
    m = _RX_DATE.fullmatch(text)
    if not m:
        return ""
    year, mon, day, hour, minute, sec = (int(g) for g in m.groups())
    if not (1 <= mon <= 12 and 1 <= day <= 31 and hour <= 23 and minute <= 59 and sec <= 60):
        return ""
    epoch = (_days_from_civil(year, mon, 1) + day - 1) * 86400 + hour * 3600 + minute * 60 + sec
    return "" if epoch == -1 else str(epoch)


def _days_from_civil(year: int, month: int, day: int) -> int:
    """Days since 1970-01-01 in the proleptic Gregorian calendar, year 0 included
    (timegm handles it; Python's datetime stops at year 1)."""
    year -= month <= 2
    era = (year if year >= 0 else year - 399) // 400
    yoe = year - era * 400
    doy = (153 * (month + (-3 if month > 2 else 9)) + 2) // 5 + day - 1
    doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _jq_tostring(value: Any) -> str:
    return value if isinstance(value, str) else jq_dumps(value)


def bash_read_fields(line: str, count: int, sep: str) -> List[str]:
    """`IFS=<sep> read -r f1 .. fN`: only the first line, the last field takes the rest."""
    line = line.split("\n", 1)[0]
    parts = line.split(sep, count - 1) if line else []
    return parts + [""] * (count - len(parts))


def _awk_digits(field: str) -> bool:
    return bool(re.fullmatch(r"[0-9]+", field))


def _awk_text_or_zero(field: str) -> str:
    """`($n ~ /^[0-9]+$/) ? $n : 0`, kept as the text awk would print."""
    return field if _awk_digits(field) else "0"


def _fields(line: bytes) -> List[str]:
    return _s(line).split("\t")


def _field(fields: List[str], n: int) -> str:
    return fields[n - 1] if len(fields) >= n else ""


def _rewrite_keyed(path: str, match: Callable[[List[str]], bool],
                   update: Callable[[List[str]], str], new_row: Callable[[], str]) -> None:
    """The awk upserts of 03-tsv.sh: rewrite the first matching row(s), or append."""
    with locked(path):
        out: List[bytes] = []
        updated = False
        for line in _read_lines(path):
            fields = _fields(line)
            if match(fields):
                out.append(_b(update(fields)))
                updated = True
            else:
                out.append(line)
        if not updated:
            out.append(_b(new_row()))
        _replace_with(path, out)


def upsert_meter_reception(path: str, meter: str, device: str, ts: int, topic: str) -> None:
    """_upsert_esp_meter_reception: id dev first last count topic."""
    def update(f: List[str]) -> str:
        first = f[2] if (_awk_digits(_field(f, 3)) and int(_field(f, 3)) > 0) else str(ts)
        count = int(_field(f, 5)) + 1 if _awk_digits(_field(f, 5)) else 1
        return "\t".join([meter, device, first, str(ts), str(count), topic])
    _rewrite_keyed(path, lambda f: _field(f, 1) == meter and _field(f, 2) == device, update,
                   lambda: "\t".join([meter, device, str(ts), str(ts), "1", topic]))


def upsert_meter_mode(path: str, meter: str, mode: str, ts: int) -> None:
    """_upsert_esp_meter_mode: id mode count last; other modes are ignored."""
    if mode not in _RX_MODES:
        return
    def update(f: List[str]) -> str:
        count = int(_field(f, 3)) + 1 if _awk_digits(_field(f, 3)) else 1
        return "\t".join([meter, mode, str(count), str(ts)])
    _rewrite_keyed(path, lambda f: _field(f, 1) == meter and _field(f, 2) == mode, update,
                   lambda: "\t".join([meter, mode, "1", str(ts)]))


def _awk_num(text: str) -> float:
    """awk's numeric value of a string: its leading number, else 0."""
    m = re.match(r"\s*[-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?", text)
    return float(m.group(0)) if m else 0.0


def _awk_str(number: float) -> str:
    """How awk prints a computed number: integers plainly, others with %.6g."""
    return str(int(number)) if number == int(number) else "%.6g" % number


def upsert_rx_sequence(path: str, source: str, boot: str, seq: str, ts: int) -> None:
    """_upsert_esp_rx_sequence: source boot last_seq missing out_of_order last_seen.

    last_seq is the highest sequence seen for the boot; see 03-tsv.sh for why.
    """
    def update(f: List[str]) -> str:
        # Unchanged values are printed as the text they were read as, computed
        # ones as awk prints numbers - like the awk program.
        missing_text, ooo_text, out_seq = "0", "0", seq
        if _field(f, 2) == boot:
            last_text = _awk_text_or_zero(_field(f, 3))
            missing_text = _awk_text_or_zero(_field(f, 4))
            ooo_text = _awk_text_or_zero(_field(f, 5))
            last, s = _awk_num(last_text), _awk_num(seq)
            if last > 0 and s > last + 1:
                missing_text = _awk_str(_awk_num(missing_text) + s - last - 1)
            if last > 0 and s <= last:
                ooo_text = _awk_str(_awk_num(ooo_text) + 1)
            if s < last:
                out_seq = last_text
        return "\t".join([source, boot, out_seq, missing_text, ooo_text, str(ts)])
    _rewrite_keyed(path, lambda f: _field(f, 1) == source, update,
                   lambda: "\t".join([source, boot, seq, "0", "0", str(ts)]))


def upsert_rx_boot(path: str, source: str, boot: str, ts: int) -> None:
    """_upsert_esp_rx_boot: source boot first_seen last_seen events."""
    def update(f: List[str]) -> str:
        events = int(_field(f, 5)) + 1 if _awk_digits(_field(f, 5)) else 1
        return "\t".join([_field(f, 1), _field(f, 2), _field(f, 3), str(ts), str(events)])
    _rewrite_keyed(path, lambda f: _field(f, 1) == source and _field(f, 2) == boot, update,
                   lambda: "\t".join([source, boot, str(ts), str(ts), "1"]))


def upsert_rx_clock(path: str, source: str, received: str, ts: int) -> None:
    """_upsert_esp_rx_clock: source last_received last_bridge skew stamped unstamped."""
    def update(f: List[str]) -> str:
        stamped = _awk_text_or_zero(_field(f, 5))
        unstamped = _awk_text_or_zero(_field(f, 6))
        if received == "":
            return "\t".join([source, _field(f, 2), str(ts), _field(f, 4), stamped,
                              _awk_str(_awk_num(unstamped) + 1)])
        return "\t".join([source, received, str(ts), _awk_str(ts - _awk_num(received)),
                          _awk_str(_awk_num(stamped) + 1), unstamped])

    def new_row() -> str:
        if received == "":
            return "\t".join([source, "0", str(ts), "0", "0", "1"])
        return "\t".join([source, received, str(ts), _awk_str(ts - _awk_num(received)), "1", "0"])
    _rewrite_keyed(path, lambda f: _field(f, 1) == source, update, new_row)


class RxBook:
    """_esp_rx_handle_message: structured /rx metadata into six files."""

    TRIM_EVERY = 1000

    def __init__(self, reception: str, mode: str, history: str, sequence: str,
                 boots: str, clock: str) -> None:
        self.reception, self.mode, self.history = reception, mode, history
        self.sequence, self.boots, self.clock = sequence, boots, clock
        self.since_trim = 0

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not topic_b or not payload_b:
            return
        topic = _s(topic_b)
        payload = payload_b.decode("utf-8", "replace")
        normalized = [n for n in (normalize_rx(v) for v in jq_values(payload)) if n is not None]
        if not normalized:
            return
        # `IFS='/' read -ra parts`: a trailing "/" adds no empty field.
        parts = topic.split("/")
        if topic.endswith("/"):
            parts.pop()
        device = parts[1] if len(parts) > 1 else ""
        if not device:
            return
        first = normalized[0]
        joined = "\x1f".join(_jq_tostring(x) for x in (
            first["meter_id"], first["boot_id"], first["seq"], first["mode"],
            received_epoch(first.get("received_at"))))
        meter, boot, seq, mode, rcv = bash_read_fields(joined, 5, "\x1f")
        ts = int(now())
        upsert_meter_reception(self.reception, meter, device, ts, topic)
        upsert_meter_mode(self.mode, meter, mode, ts)
        lines = []
        for n in normalized:
            merged = dict(n)
            merged["bridge_rx_time"] = ts
            merged["source"] = device
            lines.append(jq_dumps(merged))
        append_locked(self.history, "\n".join(lines))
        upsert_rx_sequence(self.sequence, device, boot, seq, ts)
        upsert_rx_boot(self.boots, device, boot, ts)
        upsert_rx_clock(self.clock, device, rcv, ts)
        self.since_trim += 1
        if self.since_trim >= self.TRIM_EVERY:
            trim_locked(self.history, 100000, 90000)
            self.since_trim = 0



def run(handler: Handler, stream=None, err=None) -> None:
    """Feed every line of stream to handler until EOF; a failing message is skipped."""
    stream = stream if stream is not None else sys.stdin.buffer
    err = err if err is not None else sys.stderr
    for raw in stream:
        topic, payload = split_message(raw)
        try:
            handler(topic, payload)
        except Exception as exc:  # one bad message must not stop the bookkeeping
            print(f"[wmbus-bridge][WARN] ledger: message on {topic!r} skipped: {exc!r}",
                  file=err, flush=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge_ledger.py")
    modes = parser.add_subparsers(dest="mode", required=True)
    rssi = modes.add_parser("rssi", help="wmbus/<board>/rssi/<meter_id> messages")
    rssi.add_argument("--meter-dir", required=True)
    rssi.add_argument("--rssi-file", required=True)
    rx = modes.add_parser("rx", help="wmbus/<board>/rx messages")
    for name in ("reception", "mode", "history", "sequence", "boots", "clock"):
        rx.add_argument(f"--{name}-file", required=True)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    try:
        args = _parser().parse_args(argv)
    except SystemExit as exc:  # usage errors: report, never raise out of main
        return int(exc.code or 0)
    if args.mode == "rssi":
        run(RssiBook(args.meter_dir, args.rssi_file))
    elif args.mode == "rx":
        run(RxBook(args.reception_file, args.mode_file, args.history_file,
                   args.sequence_file, args.boots_file, args.clock_file))
    return 0


if __name__ == "__main__":
    sys.exit(main())

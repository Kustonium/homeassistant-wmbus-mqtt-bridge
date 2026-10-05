#!/usr/bin/env python3
"""Per-message bookkeeping of the bridge, in one long-lived process.

WHY
---
Every MQTT message from every ESP used to be booked by bash: the RAW counter,
the per-board tracker, the /rx and rssi/<id> subscribers and the LISTEN block
handler. Each of them started tens of processes per message (awk, jq, mv,
mktemp, flock, date and $(...) subshells - see tests/test_perf_fork_budget.sh),
which on a 5-ESP site kept a CPU core busy doing nothing but process start-up.
This module does the same bookkeeping in-process, for every path: the rssi/<id>
and /rx subscribers, the per-board /telegram tracker, the RAW counter and the
pure LISTEN parser. The bash implementations were removed once every site ran
on this; the docstrings below still name the bash function each piece
replaced, and what those functions wrote for the test corpora is kept in
tests/fixtures/ledger/, which the equivalence tests compare against.

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
* Per-message tables are written at most every FLUSH_EVERY_S seconds (see
  Deferred), with the same bytes; status_recent_raw.tsv is appended to.
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
import select
import signal
import sys
import tempfile
import time
from decimal import Decimal
from contextlib import contextmanager
from datetime import datetime
from typing import Any, Callable, Dict, Iterator, List, NamedTuple, Optional, Set, Tuple

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


# ── deferred writes ─────────────────────────────────────────────────────────
# Every message changes a row of a table that holds a row per meter and board,
# and writing it means writing the whole table again (to a temporary file that
# replaces it, which ext4 pushes to the disk at once). Per message that was
# ~1 MB/s on a 5-board site, written to an SD card on a Raspberry Pi. The
# changes are therefore collected here and written at most every
# FLUSH_EVERY_S seconds, and when the input ends or SIGTERM arrives: each
# file is read once, under its lock as before, the changes are applied in the
# order they arrived (with the time of their message) and the file is written
# once. The result is byte for byte what writing per message would have left.

FLUSH_EVERY_S = 5

Rows = Callable[[List[bytes]], List[bytes]]


class Deferred:
    """Changes of the files this process alone writes per message, written in batches."""

    def __init__(self) -> None:
        # path -> (take the lock, skip when the file is missing, row changes)
        self.rows: Dict[str, Tuple[bool, bool, List[Rows]]] = {}
        # path -> (whole new content, write it in place instead of replacing)
        self.values: Dict[str, Tuple[bytes, bool]] = {}
        # key -> a write of its own (see CandidateFiles), made after the above
        self.tasks: Dict[str, Callable[[], None]] = {}
        self.since: Optional[float] = None

    def change(self, path: str, rows: Rows, lock: bool = True, need_file: bool = False) -> None:
        self.rows.setdefault(path, (lock, need_file, []))[2].append(rows)
        self._started()

    def value(self, path: str, data: bytes, in_place: bool = False) -> None:
        self.values[path] = (data, in_place)
        self._started()

    def task(self, key: str, write: Callable[[], None]) -> None:
        self.tasks[key] = write
        self._started()

    def _started(self) -> None:
        if self.since is None:
            self.since = now()

    def due_in(self) -> Optional[float]:
        """Seconds until the next write is due; None while nothing waits."""
        if self.since is None:
            return None
        return max(0.0, self.since + FLUSH_EVERY_S - now())

    def pending(self, path: str) -> int:
        """How many row changes of path wait to be written."""
        return len(self.rows[path][2]) if path in self.rows else 0

    def flush_if_due(self) -> None:
        if self.due_in() == 0.0:
            self.flush()

    def flush(self, err=None) -> None:
        rows, values, tasks = self.rows, self.values, self.tasks
        self.rows, self.values, self.tasks, self.since = {}, {}, {}, None
        for path, (lock, need_file, changes) in rows.items():
            try:
                if need_file and not os.path.isfile(path):
                    continue
                if lock:
                    with locked(path):
                        _replace_with(path, _apply(changes, _read_lines(path)))
                else:
                    _replace_with(path, _apply(changes, _read_lines(path)))
            except Exception as exc:  # one file must not stop the others
                print(f"[wmbus-bridge][WARN] ledger: write of {path} failed: {exc!r}",
                      file=err or sys.stderr, flush=True)
        for path, (data, in_place) in values.items():
            try:
                if in_place:
                    with open(path, "wb") as fh:
                        fh.write(data)
                else:
                    _write_replace(path, data)
            except Exception as exc:
                print(f"[wmbus-bridge][WARN] ledger: write of {path} failed: {exc!r}",
                      file=err or sys.stderr, flush=True)
        for key, write in tasks.items():
            try:
                write()
            except Exception as exc:
                print(f"[wmbus-bridge][WARN] ledger: write of {key} failed: {exc!r}",
                      file=err or sys.stderr, flush=True)


def _count_plus_one(lines: List[bytes]) -> List[bytes]:
    """status_raw_count.txt + 1, reading it as _digits_or_zero does."""
    text = _s(b"\n".join(lines)).rstrip("\n")
    return [str((int(text) if re.fullmatch(r"[0-9]+", text) else 0) + 1).encode()]


def _apply(changes: List[Rows], lines: List[bytes]) -> List[bytes]:
    for rows in changes:
        lines = rows(lines)
    return lines


def read_lines_flushing(stream, deferred: Deferred) -> Iterator[bytes]:
    """The lines of stream, as iterating it gives them; while no line arrives,
    the deferred writes are made when they fall due."""
    try:
        fd = stream.fileno()
    except (AttributeError, OSError, ValueError):
        for line in stream:  # tests: an in-memory stream
            yield line
            deferred.flush_if_due()
        return
    buf = b""
    while True:
        wait = deferred.due_in()
        ready, _, _ = select.select([fd], [], [], wait)
        if not ready:
            deferred.flush()
            continue
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        buf += chunk
        while True:
            nl = buf.find(b"\n")
            if nl < 0:
                break
            line, buf = buf[:nl + 1], buf[nl + 1:]
            yield line
            deferred.flush_if_due()
    if buf:
        yield buf


class _Terminated(Exception):
    pass


def _on_sigterm(signum, frame) -> None:
    raise _Terminated()


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
                   update: Callable[[List[str]], str], new_row: Callable[[], str],
                   defer: Optional[Deferred] = None) -> None:
    """The awk upserts of 03-tsv.sh: rewrite the first matching row(s), or append."""
    def rows(lines: List[bytes]) -> List[bytes]:
        out: List[bytes] = []
        updated = False
        for line in lines:
            fields = _fields(line)
            if match(fields):
                out.append(_b(update(fields)))
                updated = True
            else:
                out.append(line)
        if not updated:
            out.append(_b(new_row()))
        return out
    if defer is not None:
        defer.change(path, rows)
        return
    with locked(path):
        _replace_with(path, rows(_read_lines(path)))


def upsert_meter_reception(path: str, meter: str, device: str, ts: int, topic: str,
                           defer: Optional[Deferred] = None) -> None:
    """_upsert_esp_meter_reception: id dev first last count topic."""
    def update(f: List[str]) -> str:
        first = f[2] if (_awk_digits(_field(f, 3)) and int(_field(f, 3)) > 0) else str(ts)
        count = int(_field(f, 5)) + 1 if _awk_digits(_field(f, 5)) else 1
        return "\t".join([meter, device, first, str(ts), str(count), topic])
    _rewrite_keyed(path, lambda f: _field(f, 1) == meter and _field(f, 2) == device, update,
                   lambda: "\t".join([meter, device, str(ts), str(ts), "1", topic]), defer)


def upsert_meter_mode(path: str, meter: str, mode: str, ts: int,
                      defer: Optional[Deferred] = None) -> None:
    """_upsert_esp_meter_mode: id mode count last; other modes are ignored."""
    if mode not in _RX_MODES:
        return
    def update(f: List[str]) -> str:
        count = int(_field(f, 3)) + 1 if _awk_digits(_field(f, 3)) else 1
        return "\t".join([meter, mode, str(count), str(ts)])
    _rewrite_keyed(path, lambda f: _field(f, 1) == meter and _field(f, 2) == mode, update,
                   lambda: "\t".join([meter, mode, "1", str(ts)]), defer)


def _awk_num(text: str) -> float:
    """awk's numeric value of a string: its leading number, else 0."""
    m = re.match(r"\s*[-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?", text)
    return float(m.group(0)) if m else 0.0


def _awk_str(number: float) -> str:
    """How awk prints a computed number: integers plainly, others with %.6g."""
    return str(int(number)) if number == int(number) else "%.6g" % number


def upsert_rx_sequence(path: str, source: str, boot: str, seq: str, ts: int,
                       defer: Optional[Deferred] = None) -> None:
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
                   lambda: "\t".join([source, boot, seq, "0", "0", str(ts)]), defer)


def upsert_rx_boot(path: str, source: str, boot: str, ts: int,
                   defer: Optional[Deferred] = None) -> None:
    """_upsert_esp_rx_boot: source boot first_seen last_seen events."""
    def update(f: List[str]) -> str:
        events = int(_field(f, 5)) + 1 if _awk_digits(_field(f, 5)) else 1
        return "\t".join([_field(f, 1), _field(f, 2), _field(f, 3), str(ts), str(events)])
    _rewrite_keyed(path, lambda f: _field(f, 1) == source and _field(f, 2) == boot, update,
                   lambda: "\t".join([source, boot, str(ts), str(ts), "1"]), defer)


def upsert_rx_clock(path: str, source: str, received: str, ts: int,
                    defer: Optional[Deferred] = None) -> None:
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
    _rewrite_keyed(path, lambda f: _field(f, 1) == source, update, new_row, defer)


class RxBook:
    """_esp_rx_handle_message: structured /rx metadata into six files."""

    TRIM_EVERY = 1000

    def __init__(self, reception: str, mode: str, history: str, sequence: str,
                 boots: str, clock: str) -> None:
        self.reception, self.mode, self.history = reception, mode, history
        self.sequence, self.boots, self.clock = sequence, boots, clock
        self.since_trim = 0
        self.deferred = Deferred()

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
        d = self.deferred
        upsert_meter_reception(self.reception, meter, device, ts, topic, d)
        upsert_meter_mode(self.mode, meter, mode, ts, d)
        lines = []
        for n in normalized:
            merged = dict(n)
            merged["bridge_rx_time"] = ts
            merged["source"] = device
            lines.append(jq_dumps(merged))
        append_locked(self.history, "\n".join(lines))
        upsert_rx_sequence(self.sequence, device, boot, seq, ts, d)
        upsert_rx_boot(self.boots, device, boot, ts, d)
        upsert_rx_clock(self.clock, device, rcv, ts, d)
        self.since_trim += 1
        if self.since_trim >= self.TRIM_EVERY:
            trim_locked(self.history, 100000, 90000)
            self.since_trim = 0


# ── per-board /telegram tracker ─────────────────────────────────────────────

_HEX_UPPER = re.compile(r"[0-9A-F]+")
_BASH_SPACE = re.compile(r"[ \t\n\v\f\r]")
_ID8_UPPER = re.compile(r"[0-9A-F]{8}")


def meter_id_from_raw_hex(raw: str) -> str:
    """05-raw.sh meter_id_from_raw_hex: the A-field id of a standard wM-Bus frame.

    `raw` is already upper-case hex; "" unless the L-field matches the length.
    """
    if not _HEX_UPPER.fullmatch(raw) or len(raw) < 22 or len(raw) % 2:
        return ""
    if int(raw[0:2], 16) != len(raw) // 2 - 1:
        return ""
    le = raw[8:16]
    return le[6:8] + le[4:6] + le[2:4] + le[0:2]


def bash_split(text: str, sep: str) -> List[str]:
    """`IFS=<sep> read -ra parts <<< text` for a non-whitespace separator."""
    parts = text.split(sep)
    if text.endswith(sep):
        parts.pop()
    return parts


def _awk_nf(line: bytes) -> int:
    return 0 if not line else line.count(b"\t") + 1


class TrackerBook:
    """_esp_tracker_handle_message: which board delivered which meter, and when.

    status_esp_telegram_devices.tsv  board<TAB>last_epoch<TAB>topic<TAB>count
    status_esp_meter_device.tsv      id<TAB>board<TAB>epoch (rewritten only when
                                     a meter's board changes, as in bash)
    status_esp_meter_reception.tsv   id board first last count topic
    esp_rx_history.jsonl             {"time","source","meter_id","topic"}
    """

    TRIM_EVERY = 1000

    def __init__(self, dev_pos: int, devices: str, meter_device: str,
                 reception: str, history: str) -> None:
        self.dev_pos = dev_pos
        self.devices, self.meter_device = devices, meter_device
        self.reception, self.history = reception, history
        # Last board per meter, like the subscriber's _MD_LAST: in memory, so
        # it starts empty again when this process is restarted.
        self.last_board: Dict[str, str] = {}
        self.since_trim = 0
        self.deferred = Deferred()

    def __call__(self, topic_b: bytes, payload_b: bytes) -> None:
        if not topic_b:
            return
        topic = _s(topic_b)
        parts = bash_split(topic, "/")
        board = parts[self.dev_pos] if 0 <= self.dev_pos < len(parts) else ""
        if not board:
            return
        ts = int(now())
        meter = meter_id_from_raw_hex(_ascii_upper(_BASH_SPACE.sub("", _s(payload_b))))
        valid = bool(_ID8_UPPER.fullmatch(meter))
        if valid and self.last_board.get(meter) != board:
            self.last_board[meter] = board
            row = _b(f"{meter}\t{board}\t{ts}")
            k = _b(meter)

            def meter_rows(lines: List[bytes]) -> List[bytes]:
                out = [row if _first_field(ln) == k else ln for ln in lines]
                if not any(_first_field(ln) == k for ln in lines):
                    out.append(row)
                return out
            # The tracker is the only writer, no lock; awk fails on a missing
            # file, so nothing is written then (bridge.sh creates it at start).
            self.deferred.change(self.meter_device, meter_rows, lock=False, need_file=True)
        if valid:
            upsert_meter_reception(self.reception, meter, board, ts, topic, self.deferred)
            append_locked(self.history, jq_dumps(
                {"time": ts, "source": board, "meter_id": meter, "topic": topic}))
            self.since_trim += 1
            if self.since_trim >= self.TRIM_EVERY:
                trim_locked(self.history, 100000, 90000)
                self.since_trim = 0
        k_board = _b(board)

        def device_rows(lines: List[bytes]) -> List[bytes]:
            out: List[bytes] = []
            updated = False
            for ln in lines:
                if _first_field(ln) == k_board:
                    nf = _awk_nf(ln)
                    count = _awk_str(_awk_num(_s(ln.split(b"\t")[3])) + 1) if nf >= 4 else "1"
                    out.append(_b(f"{board}\t{ts}\t{topic}\t{count}"))
                    updated = True
                else:
                    out.append(ln)
            if not updated:
                out.append(_b(f"{board}\t{ts}\t{topic}\t1"))
            return out
        self.deferred.change(self.devices, device_rows, lock=False, need_file=True)


# ── RAW telegram counter (status_raw_seen) ──────────────────────────────────

def iso_now() -> str:
    """`date -Iseconds` as BusyBox prints it in the image: 2026-10-02T15:09:23+02:00."""
    return datetime.fromtimestamp(now()).astimezone().isoformat(timespec="seconds")


def _jq_pretty(value: Any, indent: int = 0) -> str:
    """`jq -n '{...}'` output: two-space indent, "key": value."""
    if isinstance(value, dict):
        if not value:
            return "{}"
        pad = " " * (indent + 2)
        items = [pad + _jq_string(k) + ": " + _jq_pretty(v, indent + 2) for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + " " * indent + "}"
    return jq_dumps(value)


def _write_replace(path: str, data: bytes) -> None:
    """printf ... > file.tmp && mv file.tmp file (single writer per file here)."""
    directory, base = os.path.split(path)
    fd, tmp = tempfile.mkstemp(prefix=base + ".tmp.", dir=directory or ".")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _tail_lines(path: str, count: int) -> List[bytes]:
    lines = _read_lines(path)
    return lines[-count:] if count > 0 else []


def _digits_or_zero(path: str) -> str:
    """status_read_raw_count: the file's text when it is all digits, else 0."""
    try:
        with open(path, "rb") as fh:
            text = _s(fh.read()).rstrip("\n")
    except OSError:
        return "0"
    return text if re.fullmatch(r"[0-9]+", text) else "0"


def mfct_code_from_raw_hex(raw: str) -> str:
    """05-raw.sh mfct_code_from_raw_hex: the EN 13757 three-letter code of the M-field."""
    raw = _BASH_SPACE.sub("", raw)
    if len(raw) < 8:
        return ""
    m = raw[4:8]
    if not re.fullmatch(r"[0-9A-Fa-f]{4}", m):
        return ""
    val = int(m[2:4] + m[0:2], 16)
    letters = [(val >> 10) & 0x1F, (val >> 5) & 0x1F, val & 0x1F]
    if not all(1 <= x <= 26 for x in letters):
        return ""
    return "".join(chr(64 + x) for x in letters)


_MFCT_NAMES = {"BMT": "(BMT) BMETERS", "NES": "(NES) NORA ELK MALZ SAN ve TIC",
               "SAP": "(SAP) Diehl Metering", "QDS": "(QDS) Qundis", "TCH": "(TCH) Techem"}
_THREE_LETTERS = re.compile(r"[A-Z]{3}")
_AES_TYPE = re.compile(r"encrypted|(^|[^a-z])aes([^a-z]|$)", re.IGNORECASE)


def candidate_fill_manufacturer(path: str, meter: str, code: str) -> bool:
    """candidate_fill_manufacturer_code: fill column 9 when empty or a bare code.

    True when a fillable row was found and the file rewritten.
    """
    if not _ID8.fullmatch(meter) or not code or not os.path.isfile(path):
        return False
    k = _b(meter)

    def fillable(line: bytes) -> bool:
        if _first_field(line) != k:
            return False
        f = line.split(b"\t")
        return len(f) < 9 or f[8] == b"" or bool(_THREE_LETTERS.fullmatch(_s(f[8])))
    if not any(fillable(ln) for ln in _read_lines(path)):  # lock-free pre-check, as in bash
        return False
    with locked(path):
        out = []
        for line in _read_lines(path):
            if _first_field(line) == k:
                f = _s(line).split("\t") if line else []
                while len(f) < 9:
                    f.append("")
                if f[8] == "" or _THREE_LETTERS.fullmatch(f[8]):
                    f[8] = code
                line = _b("\t".join(f))
            out.append(line)
        _replace_with(path, out)
    return True


def _bash_read_tab_pair(text: str) -> Tuple[str, str]:
    """`IFS=$'\t' read -r a b`: TAB is IFS whitespace, so an empty first field vanishes."""
    text = text.strip("\t")
    a, _, b = text.partition("\t")
    return a, b.lstrip("\t")


_ID8 = re.compile(r"[0-9A-Fa-f]{8}")


# ── candidate registry (status_candidate_seen) ──────────────────────────────

class CandidateFiles:
    """The files status_candidate_seen reads and writes (paths from bridge.sh).

    With `deferred`, candidate_seen_refresh writes the candidate row, its RAW
    and its analysis through it (see _flush_candidate_refreshes); without, at
    once.
    """

    def __init__(self, candidates: str, seen: str, recent_raw: str, candidate_raw: str,
                 analysis: str, preview_meter_dir: str, meter_dir: str,
                 deferred: Optional["Deferred"] = None) -> None:
        self.candidates, self.seen, self.recent_raw = candidates, seen, recent_raw
        self.candidate_raw, self.analysis = candidate_raw, analysis
        self.preview_meter_dir, self.meter_dir = preview_meter_dir, meter_dir
        self.deferred = deferred
        # meter -> _Refresh, in the order of each meter's last refresh
        self.pending: Dict[str, "_Refresh"] = {}


def _bash_read_tabs(line: str, count: int) -> List[str]:
    """`IFS=$'\\t' read -r f1 .. fN`: TAB is IFS whitespace, the last field takes the rest."""
    line = line.split("\n", 1)[0].strip("\t")
    out: List[str] = []
    while len(out) < count - 1 and line:
        field, _, line = line.partition("\t")
        out.append(field)
        line = line.lstrip("\t")
    out.append(line)
    return out + [""] * (count - len(out))


def _seen_epoch(fields: List[bytes]) -> Optional[int]:
    """`$3 ~ /^[0-9]+$/ { ts = $3 + 0 }`."""
    if len(fields) < 3 or not re.fullmatch(rb"[0-9]+", fields[2]):
        return None
    return int(fields[2])


# status_seen.tsv is appended to and cut back to the newest SEEN_KEEP rows once
# it holds more than SEEN_MAX; its readers look at the newest SEEN_KEEP rows
# only, which is the window they always saw. Cutting it back on every row
# rewrote all of it (~150 KB) per reception.
SEEN_KEEP = 5000
SEEN_MAX = 6000


def record_seen(path: str, meter: str, kind: str) -> None:
    """status_record_seen: one row per reception, none within 2 s of the last.

    The lock is the one bash takes when it cuts the file back.
    """
    ts = int(now())
    k, kind_b = _b(meter), _b(kind)
    with locked(path):
        lines = _read_lines(path)
        last = 0
        for line in lines:
            f = line.split(b"\t")
            if f[0] == k and len(f) > 1 and f[1] == kind_b:
                epoch = _seen_epoch(f)
                if epoch is not None:
                    last = epoch
        if last and ts - last < 2:
            return
        row = _b(f"{meter}\t{kind}\t{ts}")
        if len(lines) + 1 > SEEN_MAX:
            _replace_with(path, (lines + [row])[-SEEN_KEEP:])
            return
        with open(path, "ab") as fh:
            fh.write(row + b"\n")


def seen_stats(path: str, meter: str) -> Tuple[int, int, int, int]:
    """status_seen_stats: count, avg interval, last 15 min, last 60 min - all kinds."""
    ts_now = int(now())
    k = _b(meter)
    count = seen15 = seen60 = intervals = 0
    total = 0
    prev = 0
    for line in _read_lines(path)[-SEEN_KEEP:]:
        f = line.split(b"\t")
        if f[0] != k:
            continue
        ts = _seen_epoch(f)
        if ts is None:
            continue
        if prev > 0 and 0 <= ts - prev < 2:
            continue
        count += 1
        if ts >= ts_now - 900:
            seen15 += 1
        if ts >= ts_now - 3600:
            seen60 += 1
        if prev > 0 and ts >= prev:
            total += ts - prev
            intervals += 1
        prev = ts
    avg = int(total / intervals + 0.5) if intervals else 0
    return count, avg, seen15, seen60


def upsert_candidate_row(path: str, meter: str, driver: str, type_line: str, last_seen: str,
                         stats: Tuple[int, int, int, int], manufacturer: str = "",
                         expect: Optional[Tuple[str, str]] = None) -> bool:
    """_upsert_candidate_row: the row moves to the end; an empty manufacturer keeps the old one.

    With `expect`, the first row of the id must still hold that driver and
    type under the lock, or nothing is written and False is returned: another
    writer (a preview one-shot, a bash registration) changed it after the
    caller read it, and its newer classification must not be overwritten.
    """
    with locked(path):
        lines = _read_lines(path)
        if expect is not None and not _candidate_row_holds(lines, meter, expect):
            return False
        _replace_with(path, _candidate_row_upserted(lines, meter, driver, type_line, last_seen,
                                                    stats, manufacturer))
    return True


def _candidate_row_holds(lines: List[bytes], meter: str, expect: Tuple[str, str]) -> bool:
    """The first row of the id holds that driver and type."""
    k = _b(meter)
    row = next((_s(ln).split("\t") for ln in lines if _first_field(ln) == k), None)
    return row is not None and (_field(row, 2), _field(row, 3)) == expect


def _candidate_row_upserted(lines: List[bytes], meter: str, driver: str, type_line: str,
                            last_seen: str, stats: Tuple[int, int, int, int],
                            manufacturer: str) -> List[bytes]:
    """lines with the rows of the id dropped and the new row at the end."""
    k = _b(meter)
    final = manufacturer
    out = []
    for line in lines:
        if _first_field(line) == k:
            f = _s(line).split("\t")
            if final == "" and len(f) >= 9 and f[8] != "":
                final = f[8]
            continue
        out.append(line)
    out.append(_b("\t".join([meter, driver, type_line, last_seen]
                            + [str(n) for n in stats] + [final])))
    return out


# status_recent_raw.tsv is appended to and cut back to the newest
# RECENT_RAW_KEEP rows once it holds more than RECENT_RAW_MAX; its readers look
# at the newest RECENT_RAW_KEEP rows only, which is the ring they always saw.
RECENT_RAW_KEEP = 200
RECENT_RAW_MAX = 400


def find_recent_raw(path: str, meter: str) -> Optional[Tuple[str, str, str]]:
    """status_find_recent_raw_for_id: the newest ring row carrying the id, RAW in lower case."""
    le = (meter[6:8] + meter[4:6] + meter[2:4] + meter[0:2]).lower()
    for line in reversed(_read_lines(path)[-RECENT_RAW_KEEP:]):
        ts, length, raw = _bash_read_tabs(_s(line), 3)
        raw = raw.lower()
        if le in raw:
            return ts, length, raw
    return None


def candidate_type_requires_aes(type_line: str) -> bool:
    """06-candidates.sh candidate_type_requires_aes."""
    t = type_line.lower()
    if "not encrypted" in t or "unencrypted" in t or "no aes" in t or "no_aes" in t:
        return False
    return "encrypted" in t or "aes" in t


def analyze_candidate_from_text(files: CandidateFiles, meter: str, type_line: str) -> None:
    """status_analyze_candidate_from_text: the candidate's last RAW and its AES verdict."""
    raw_row, analysis_row = candidate_analysis_rows(files, meter, type_line)
    if raw_row is not None:
        tsv_upsert(files.candidate_raw, meter, raw_row)
    tsv_upsert(files.analysis, meter, analysis_row)


def candidate_analysis_rows(files: CandidateFiles, meter: str,
                            type_line: str) -> Tuple[Optional[str], str]:
    """The rows analyze_candidate_from_text writes: the candidate's RAW (None when
    the ring holds none of it) and its analysis."""
    found = find_recent_raw(files.recent_raw, meter)
    raw_len, raw, ci, raw_row = "0", "", "", None
    if found:
        raw_ts, raw_len, raw = found
        if raw:  # status_record_candidate_raw
            raw_row = f"{meter}\t{raw_ts or iso_now()}\t{len(raw)}\t{raw}"
        ci = raw[20:22] if len(raw) >= 22 else ""
    if candidate_type_requires_aes(type_line):
        encryption = "aes_required"
        note = "wmbusmeters/listen output explicitly reports encrypted/AES telegram"
    elif raw:
        encryption = "unknown"
        note = "RAW was mapped to this candidate, but no backend security parser has classified AES yet"
    else:
        encryption = "unknown"
        note = "No RAW/security analysis mapped to this candidate yet"
    return raw_row, f"{meter}\t{encryption}\t{note}\t{ci}\t\t{raw_len or '0'}\t{iso_now()}"


def candidate_seen_refresh(files: CandidateFiles, meter: str, driver: str, type_line: str,
                           manufacturer: str = "") -> bool:
    """status_candidate_seen for a candidate that is already registered.

    The reception row (2 s threshold), the stats, the candidate row and the
    RAW analysis, written as the bash function writes them. What is left of
    status_candidate_seen stays in bash: the "Candidate detected" event of a
    new row, the preview config and its state machine (ensure_candidate_autodecode)
    and status.json. Call it only when autodecode_unchanged() holds and the
    row holds this driver and type; that is checked again under the lock, and
    when another writer changed the row in between, nothing more is written
    and False is returned - the caller then hands the telegram to bash.

    With files.deferred the reception row is still written at once, but the
    candidate row, its RAW and its analysis wait for the next deferred write:
    one rewrite of each file per FLUSH_EVERY_S instead of three per telegram.
    The driver and type are then checked twice: here without the lock (False
    as above) and under it when the rows are written; a row another writer
    changed in between keeps that writer's version, and the rows of this
    refresh are dropped (the reception row stays, as it does when the check
    fails here). The next telegram of that meter then goes to bash.
    """
    record_seen(files.seen, meter, "candidate")
    last_seen = iso_now()
    stats = seen_stats(files.seen, meter)
    if files.deferred is None:
        if not upsert_candidate_row(files.candidates, meter, driver, type_line, last_seen,
                                    stats, manufacturer, expect=(driver, type_line)):
            return False
        analyze_candidate_from_text(files, meter, type_line)
        return True
    if not _candidate_row_holds(_read_lines(files.candidates), meter, (driver, type_line)):
        return False
    raw_row, analysis_row = candidate_analysis_rows(files, meter, type_line)
    earlier = files.pending.pop(meter, None)
    if manufacturer == "" and earlier is not None:
        manufacturer = earlier.manufacturer  # what the earlier row would have kept
    if raw_row is None and earlier is not None:
        raw_row = earlier.raw_row
    files.pending[meter] = _Refresh(driver, type_line, last_seen, stats, manufacturer,
                                    raw_row, analysis_row)
    files.deferred.task(f"candidates:{files.candidates}",
                        lambda: _flush_candidate_refreshes(files))
    return True


class _Refresh(NamedTuple):
    """One candidate's rows waiting for the deferred write (its last refresh)."""
    driver: str
    type_line: str
    last_seen: str
    stats: Tuple[int, int, int, int]
    manufacturer: str
    raw_row: Optional[str]
    analysis_row: str


def _flush_candidate_refreshes(files: CandidateFiles) -> None:
    """Write the waiting refreshes: each file read and written once, under its lock.

    The candidate rows go first; a refresh whose row no longer holds its
    driver and type (or is gone) is dropped with its RAW and analysis rows.
    """
    pending, files.pending = files.pending, {}
    if not pending:
        return
    written: List[str] = []
    with locked(files.candidates):
        lines = _read_lines(files.candidates)
        for meter, r in pending.items():
            if not _candidate_row_holds(lines, meter, (r.driver, r.type_line)):
                continue
            lines = _candidate_row_upserted(lines, meter, r.driver, r.type_line, r.last_seen,
                                            r.stats, r.manufacturer)
            written.append(meter)
        if written:
            _replace_with(files.candidates, lines)
    for path, rows in ((files.candidate_raw, [(m, pending[m].raw_row) for m in written
                                              if pending[m].raw_row is not None]),
                       (files.analysis, [(m, pending[m].analysis_row) for m in written])):
        if not rows:
            continue
        with locked(path):
            lines = _read_lines(path)
            for meter, row in rows:
                k = _b(meter)
                lines = [ln for ln in lines if _first_field(ln) != k] + [_b(row)]
            _replace_with(path, lines)


def official_meter(meter_dir: str, meter: str) -> bool:
    """`grep -ql "^id=<id>$" meter-*`: the candidate is a configured meter."""
    line = _b(f"id={meter.lower()}")
    return any(os.path.isfile(p) and line in _read_lines(p)
               for p in glob.glob(os.path.join(meter_dir, "meter-*")))


def autodecode_unchanged(files: CandidateFiles, meter: str, driver: str, type_line: str) -> bool:
    """True when ensure_candidate_autodecode would change nothing for this candidate."""
    preview = os.path.join(files.preview_meter_dir, f"meter-preview-{meter}")
    if official_meter(files.meter_dir, meter):
        return not os.path.isfile(preview)  # bash removes the preview of an official meter
    if candidate_type_requires_aes(type_line):
        return not os.path.isfile(preview)  # ... and the preview of an AES meter
    expected = f"name=preview_{meter}\nid={meter.lower()}\n"
    if driver and driver not in ("auto", "unknown"):
        expected += f"driver={driver}\n"
    try:
        with open(preview, "rb") as fh:
            return fh.read() == _b(expected)
    except OSError:
        return False


_DEVICE_TYPES = {"02": "Electricity meter (0x02)", "03": "Gas meter (0x03)",
                 "04": "Heat meter (0x04)", "06": "Warm water meter (0x06)",
                 "07": "Water meter (0x07)", "08": "Heat Cost Allocator (0x08)",
                 "0C": "Heat meter inlet (0x0C)", "16": "Cold water meter (0x16)"}


def map_device_type(dev_type: str) -> str:
    """05-raw.sh map_device_type."""
    dt = _ascii_upper(dev_type)
    return _DEVICE_TYPES.get(dt, f"Unknown meter type (0x{dt})")


def raw_is_encrypted(raw: str) -> bool:
    """05-raw.sh raw_is_encrypted: CI 0x7A with a non-zero CFG security mode."""
    if len(raw) < 30 or raw[20:22] != "7A":
        return False
    cfg_hi = raw[28:30]
    return bool(re.fullmatch(r"[0-9A-F]{2}", cfg_hi)) and int(cfg_hi, 16) & 0x1F != 0


def preview_state(path: str, meter: str) -> str:
    """`awk '$1 == id { s = $2 } END { print s }'` on the preview state file."""
    k, state = _b(meter), ""
    for line in _read_lines(path):
        f = line.split(b"\t")
        if f[0] == k:
            state = _s(f[1]) if len(f) > 1 else ""
    return state


class RawBook:
    """status_raw_seen: the bookkeeping of every RAW telegram, in one process.

    Writes the RAW counter, last-seen time, the recent-RAW ring, the candidate
    manufacturer fill, the every-25th event, the per-minute rate, status.json
    and the reception refresh of a Diehl/SAP candidate that would be
    registered again exactly as it is, as the bash functions did. Two things
    stay in bash and are asked for on stdout, one request per line, for the
    bash loop that reads it (see _raw_counter_stage): registering a new
    Diehl/SAP (0x304C) candidate or changing its driver/type ("sap<TAB>raw")
    and starting a preview one-shot decode ("preview<TAB>raw<TAB>id"). Each
    request is sent only when the bash code would get past its own cheap
    checks, which it then repeats.
    """

    def __init__(self, a: argparse.Namespace, out=None) -> None:
        self.a = a
        self.out = out if out is not None else sys.stdout
        self.last_event = a.last_event
        # The rate state starts at zero with every pipeline, as the bash
        # counter's did.
        self.rate_epoch = 0
        self.rate_count = 0
        self.rate_prev = 0
        self.deferred = Deferred()
        self.candidates = CandidateFiles(a.candidates_file, a.seen_file, a.recent_raw_file,
                                         a.candidate_raw_file, a.candidate_analysis_file,
                                         a.preview_meter_dir, a.meter_dir, self.deferred)
        self.ring_lines: Optional[int] = None

    def request(self, *fields: str) -> None:
        # A lost reader must not stop the counting itself.
        try:
            self.out.write("\t".join(fields) + "\n")
            self.out.flush()
        except OSError:
            pass

    def line(self, raw_b: bytes) -> None:
        a = self.a
        raw = _s(raw_b)
        if os.path.isfile(a.broker_error_file) and os.path.getsize(a.broker_error_file) > 0:
            with open(a.broker_error_file, "wb"):
                pass
        # status_store_raw_seen; the counter is the file's value plus the
        # increments still waiting to be written
        seen = iso_now()
        d = self.deferred
        count = int(_digits_or_zero(a.raw_count_file)) + d.pending(a.raw_count_file) + 1
        d.change(a.raw_count_file, _count_plus_one, lock=False)
        d.value(a.last_raw_file, _b(seen) + b"\n", in_place=True)
        # status_store_recent_raw: appended at once, it is read by other
        # processes (the LISTEN parser, bash, the WebUI) for the telegram that
        # just arrived
        if raw and re.fullmatch(r"[0-9A-Fa-f]+", raw):
            self.ring_append(_b(f"{iso_now()}\t{len(raw)}\t{raw}"))
        self.candidate(raw)
        self.preview(raw)
        if count == 1 or count % 25 == 0:
            self.add_event("ok", f"RAW telegram received ({len(raw)} hex chars)")
        self.rate()
        self.status_json(str(count), seen)

    def ring_append(self, row: bytes) -> None:
        path = self.a.recent_raw_file
        if self.ring_lines is None:
            self.ring_lines = len(_read_lines(path))
        with open(path, "ab") as fh:
            fh.write(row + b"\n")
        self.ring_lines += 1
        if self.ring_lines > RECENT_RAW_MAX:
            ring = _read_lines(path)[-RECENT_RAW_KEEP:]
            _replace_with(path, ring)
            self.ring_lines = len(ring)

    def candidate(self, raw: str) -> None:
        """status_raw_candidate_seen up to the point where bash takes over."""
        a = self.a
        norm = _ascii_upper(_BASH_SPACE.sub("", raw))
        meter = meter_id_from_raw_hex(norm)
        if not _ID8.fullmatch(meter):
            return
        code = mfct_code_from_raw_hex(norm)
        if code:
            candidate_fill_manufacturer(a.candidates_file, meter, _MFCT_NAMES.get(code) or code)
        if norm[4:8] != "304C":
            return
        driver, type_line = "", ""
        k = _b(meter)
        for line in _read_lines(a.candidates_file):
            if _first_field(line) == k:
                f = _s(line).split("\t")
                driver, type_line = _bash_read_tab_pair(
                    (f[1] if len(f) > 1 else "") + "\t" + (f[2] if len(f) > 2 else ""))
                break
        if driver and driver != "auto":
            return
        if _AES_TYPE.search(type_line):
            return
        # What bash would register. A Diehl/SAP frame that is not a water meter
        # registers as "auto" again on every telegram; when the row already says
        # exactly that, only the reception stats change and they are written
        # here. New rows and driver/type changes still go to bash.
        dev_type = norm[18:20]
        if dev_type == "07":
            new_driver, new_type = "izarv2", "Water meter (0x07)"
        else:
            new_driver = "auto"
            new_type = map_device_type(dev_type) + (" encrypted" if raw_is_encrypted(norm) else "")
        if (driver == new_driver and type_line == new_type
                and autodecode_unchanged(self.candidates, meter, new_driver, new_type)
                and candidate_seen_refresh(self.candidates, meter, new_driver, new_type)):
            return
        self.request("sap", raw)

    def preview(self, raw: str) -> None:
        """preview_decode_raw_if_requested up to its throttle; bash decides the rest."""
        a = self.a
        norm = _ascii_upper(_BASH_SPACE.sub("", raw))
        if not _HEX_UPPER.fullmatch(norm):
            return
        lower = norm.lower()
        meter = ""
        for path in sorted(glob.glob(os.path.join(a.preview_meter_dir, "meter-preview-*"))):
            if not os.path.exists(path):  # [[ -e ]]: follows symlinks
                continue
            cand = os.path.basename(path)[len("meter-preview-"):]
            if not _ID8.fullmatch(cand):
                continue
            le = cand[6:8] + cand[4:6] + cand[2:4] + cand[0:2]
            if le.lower() in lower:
                meter = cand.upper()
                break
        if not meter:
            meter = meter_id_from_raw_hex(norm)
        if not _ID8.fullmatch(meter):
            return
        if not os.path.isfile(os.path.join(a.preview_meter_dir, f"meter-preview-{meter}")):
            return
        last = _digits_or_zero(os.path.join(a.preview_last_dir, meter))
        if int(now()) - int(last) < a.preview_min_interval:
            return
        if (int(now()) - int(last) < a.preview_decoded_min_interval
                and preview_state(a.preview_state_file, meter) == "decoded_value"):
            return
        self.request("preview", raw, meter)

    def add_event(self, level: str, message: str) -> None:
        """status_add_event: append, then keep the last 40 lines."""
        a = self.a
        self.last_event = message
        try:
            with open(a.events_file, "ab") as fh:
                fh.write(_b(f"{iso_now()}\t{level}\t{message}") + b"\n")
            _replace_with(a.events_file, _tail_lines(a.events_file, 40))
        except OSError:
            pass

    def rate(self) -> None:
        a = self.a
        ts = int(now())
        minute = ts // 60
        if self.rate_epoch != minute:
            if self.rate_epoch != 0:
                history = _tail_lines(a.rate_history_file, 14)
                history.append(f"{self.rate_epoch}\t{self.rate_count}".encode())
                _replace_with(a.rate_history_file, history)
            self.rate_prev = self.rate_count
            self.rate_count = 1
            self.rate_epoch = minute
        else:
            self.rate_count += 1
        self.deferred.value(a.rate_file, (
            f'{{"current_min":{self.rate_count},"prev_min":{self.rate_prev},"epoch":{ts}}}\n').encode())

    def status_json(self, raw_count: str, last_raw: str) -> None:
        """write_status_json as the counter subshell writes it, with the
        counter and last-seen time of this telegram."""
        a = self.a
        pub, pub_at = a.discovery_published, a.discovery_published_at
        if os.path.isfile(a.discovery_flag_file) and os.path.getsize(a.discovery_flag_file) > 0:
            pub = "true"
            pub_at = _s(_read_lines(a.discovery_flag_file)[0]) if _read_lines(a.discovery_flag_file) else ""
        doc = {
            "updated_at": iso_now(),
            "config": {"raw_topic": a.raw_topic, "state_prefix": a.state_prefix,
                       "discovery_prefix": a.discovery_prefix,
                       "search_mode": a.search_mode == "true", "loglevel": a.loglevel},
            "mqtt": {"host": a.mqtt_host, "port": a.mqtt_port, "connected": True},
            "pipeline": {"raw_count": _jq_tonumber(raw_count),
                         "decoded_count": _jq_tonumber(a.decoded_count),
                         "wmbusmeters_running": True,
                         "discovery_published": pub == "true",
                         "discovery_published_at": pub_at,
                         "last_raw_seen": last_raw,
                         "last_decoded_seen": a.last_decoded_seen,
                         "last_error": a.last_error,
                         "last_event": self.last_event},
        }
        self.deferred.value(a.status_json_file, _b(_jq_pretty(doc)) + b"\n")


def _jq_tonumber(text: str) -> Any:
    """`$x | tonumber? // 0` for the counters."""
    values = jq_values(text) if text.strip(_JQ_WS) else []
    if len(values) == 1 and isinstance(values[0], Decimal):
        return values[0]
    return 0


def run_lines(book: "RawBook", stream=None, err=None) -> None:
    """The counter loop: one RAW line per message (`IFS= read -r raw_line`)."""
    stream = stream if stream is not None else sys.stdin.buffer
    err = err if err is not None else sys.stderr
    try:
        for raw in read_lines_flushing(stream, book.deferred):
            if not raw.endswith(b"\n"):  # `read` does not hand over an unterminated last line
                continue
            try:
                book.line(raw[:-1])
            except Exception as exc:  # one bad telegram must not stop the counter
                print(f"[wmbus-bridge][WARN] ledger: RAW telegram skipped: {exc!r}", file=err, flush=True)
    except _Terminated:
        # Exit as SIGTERM would have ended it, so that the loops that run
        # this process start it again; what is collected is written first.
        raise SystemExit(128 + signal.SIGTERM)
    finally:
        book.deferred.flush(err)


# ── parallel LISTEN output (parse_listen_candidates) ────────────────────────

_LISTEN_RECEIVED = re.compile(r"Received telegram from: ([0-9A-Fa-f]{8})")
_LISTEN_TYPE = re.compile(r"[ \t\n\v\f\r]*type:[ \t\n\v\f\r]*(.*)")
_LISTEN_DRIVER = re.compile(r"[ \t\n\v\f\r]*driver: ([a-zA-Z0-9_]+)")
_LISTEN_MANUFACTURER = re.compile(r"[ \t\n\v\f\r]*manufacturer:[ \t\n\v\f\r]*(.*)")


class ListenBook:
    """parse_listen_candidates: the candidate bookkeeping of the pure LISTEN instance.

    Collects one text block per telegram (id, type, driver, manufacturer) and
    books it when the next block starts, as the bash parser does. A candidate
    that is already registered with the same driver and type, whose preview
    config would stay as it is and that was already announced, is refreshed
    here with candidate_seen_refresh. Everything else is asked of the bash loop
    behind it (see _listen_parse_stage), one request per line, fields
    separated by 0x1F so that empty fields survive `read`: a new or changed
    candidate ("snippet": emit_snippet_if_new), SEARCH ("search":
    search_cache_candidate) and decoded JSON ("json").
    """

    SEP = "\x1f"

    def __init__(self, a: argparse.Namespace, out=None, err=None) -> None:
        self.a = a
        self.out = out if out is not None else sys.stdout
        self.err = err if err is not None else sys.stderr
        self.deferred = Deferred()
        self.candidates = CandidateFiles(a.candidates_file, a.seen_file, a.recent_raw_file,
                                         a.candidate_raw_file, a.candidate_analysis_file,
                                         a.preview_meter_dir, a.meter_dir, self.deferred)
        self.block = ("", "", "", "")

    def request(self, *fields: str) -> None:
        try:
            self.out.write(self.SEP.join(fields) + "\n")
            self.out.flush()
        except OSError:
            pass

    def log(self, level: str, message: str) -> None:
        """log_debug / log_verbose: printed only at those log levels."""
        if self.a.loglevel == "debug" or (level == "verbose" and self.a.loglevel == "verbose"):
            print(f"[wmbus-bridge] {message}", file=self.err, flush=True)

    def line(self, text: str) -> None:
        if text.startswith("{") and '"_":"telegram"' in text:
            self.request("json", text)
            return
        meter, driver, type_line, manufacturer = self.block
        m = _LISTEN_RECEIVED.match(text)
        if m:
            self.flush()
            self.block = (m.group(1).upper(), "", "", "")
        elif _LISTEN_TYPE.match(text):
            self.block = (meter, driver, _LISTEN_TYPE.match(text).group(1), manufacturer)
        elif _LISTEN_DRIVER.match(text):
            self.block = (meter, _LISTEN_DRIVER.match(text).group(1), type_line, manufacturer)
        elif _LISTEN_MANUFACTURER.match(text):
            self.block = (meter, driver, type_line, _LISTEN_MANUFACTURER.match(text).group(1))

    def official_meters(self) -> int:
        """official_meters_count_current."""
        try:
            with open(self.a.official_count_file, "rb") as fh:
                text = _s(fh.read()).rstrip("\n")
        except OSError:
            text = self.a.official_count_default
        return int(text) if re.fullmatch(r"[0-9]+", text) else 0

    def flush(self) -> None:
        """_process_listen_text_block for the block collected so far."""
        meter, driver, type_line, manufacturer = self.block
        self.block = ("", "", "", "")
        if meter and manufacturer:  # candidate_update_manufacturer_text
            if candidate_fill_manufacturer(self.candidates.candidates, meter, manufacturer):
                self.log("debug", f"[DIAG] candidate {meter}: updated manufacturer text "
                                  f"from LISTEN block to {manufacturer}")
        if not meter or not driver:
            return
        # The parallel LISTEN instance books only while meters are configured;
        # the main instance prints these blocks only while none is, and then
        # books them (--official zero). One count file decides for both, per
        # block, so a block is never booked twice when the count changes.
        if (self.official_meters() > 0) != (self.a.official == "nonzero"):
            return
        if self.a.search_mode == "true" and self.a.search_expected != "0":
            self.request("search", meter, driver, type_line)
            return
        if not self.refresh(meter, driver, type_line or "listen", manufacturer):
            self.request("snippet", meter, driver, type_line, manufacturer)

    def refresh(self, meter: str, driver: str, type_line: str, manufacturer: str) -> bool:
        """emit_snippet_if_new for a known, announced candidate; False leaves it to bash."""
        files = self.candidates
        if _b(meter) not in _read_lines(self.a.snippet_file):
            return False
        k = _b(meter)
        row = next((_s(ln).split("\t") for ln in _read_lines(files.candidates)
                    if _first_field(ln) == k), None)
        if row is None or _field(row, 2) != driver or _field(row, 3) != type_line:
            return False
        if not autodecode_unchanged(files, meter, driver, type_line):
            return False
        if not candidate_seen_refresh(files, meter, driver, type_line, manufacturer):
            return False
        # What ensure_candidate_autodecode logs for an unchanged candidate.
        preview = os.path.join(files.preview_meter_dir, f"meter-preview-{meter}")
        if not official_meter(files.meter_dir, meter):
            self.log("debug", f"[DIAG] autodecode {meter}: file={preview} driver={driver} "
                              f"type={type_line} reload=true")
            if candidate_type_requires_aes(type_line):
                self.log("verbose", f"[DIAG] autodecode {meter}: AES required, skipping preview")
            else:
                self.log("debug", f"[DIAG] autodecode {meter}: {preview} unchanged, no reload triggered")
        return True


def run_listen(book: ListenBook, stream=None, err=None) -> None:
    """The parser loop (`while IFS= read -r line`), then the flush of the last block
    and of the deferred writes."""
    stream = stream if stream is not None else sys.stdin.buffer
    err = err if err is not None else sys.stderr
    try:
        for raw in read_lines_flushing(stream, book.deferred):
            if not raw.endswith(b"\n"):  # `read` does not hand over an unterminated last line
                continue
            try:
                book.line(_s(raw[:-1]))
            except Exception as exc:  # one bad line must not stop the parser
                print(f"[wmbus-bridge][WARN] ledger: LISTEN line skipped: {exc!r}", file=err, flush=True)
        try:
            book.flush()
        except Exception as exc:
            print(f"[wmbus-bridge][WARN] ledger: LISTEN block skipped: {exc!r}", file=err, flush=True)
    except _Terminated:
        # As in run(): what is collected is written first.
        raise SystemExit(128 + signal.SIGTERM)
    finally:
        book.deferred.flush(err)


def run(handler: Handler, stream=None, err=None) -> None:
    """Feed every line of stream to handler until EOF; a failing message is skipped."""
    stream = stream if stream is not None else sys.stdin.buffer
    err = err if err is not None else sys.stderr
    deferred = getattr(handler, "deferred", None) or Deferred()
    try:
        for raw in read_lines_flushing(stream, deferred):
            topic, payload = split_message(raw)
            try:
                handler(topic, payload)
            except Exception as exc:  # one bad message must not stop the bookkeeping
                print(f"[wmbus-bridge][WARN] ledger: message on {topic!r} skipped: {exc!r}",
                      file=err, flush=True)
    except _Terminated:
        # Exit as SIGTERM would have ended it, so that the loops that run
        # this process start it again; what is collected is written first.
        raise SystemExit(128 + signal.SIGTERM)
    finally:
        deferred.flush(err)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="bridge_ledger.py")
    modes = parser.add_subparsers(dest="mode", required=True)
    rssi = modes.add_parser("rssi", help="wmbus/<board>/rssi/<meter_id> messages")
    rssi.add_argument("--meter-dir", required=True)
    rssi.add_argument("--rssi-file", required=True)
    tracker = modes.add_parser("tracker", help="RAW_TOPIC messages, per-board tracker")
    tracker.add_argument("--dev-pos", type=int, required=True,
                         help="index of the '+' segment of RAW_TOPIC")
    for name in ("devices", "meter-device", "reception", "history"):
        tracker.add_argument(f"--{name}-file", required=True)
    raw = modes.add_parser("raw", help="RAW telegrams from the decode pipeline's tee")
    for name in ("raw-count", "last-raw", "recent-raw", "broker-error", "candidates",
                 "events", "rate", "rate-history", "status-json", "discovery-flag"):
        raw.add_argument(f"--{name}-file", required=True)
    for name in ("seen", "candidate-raw", "candidate-analysis"):
        raw.add_argument(f"--{name}-file", required=True)
    raw.add_argument("--meter-dir", required=True)
    raw.add_argument("--preview-meter-dir", required=True)
    raw.add_argument("--preview-last-dir", required=True)
    raw.add_argument("--preview-min-interval", type=int, default=20)
    raw.add_argument("--preview-state-file", default="")
    raw.add_argument("--preview-decoded-min-interval", type=int, default=300)
    # Values the counter subshell inherits when the pipeline starts; they go
    # into status.json unchanged, as the bash counter wrote them.
    for name in ("raw-topic", "state-prefix", "discovery-prefix", "search-mode", "loglevel",
                 "mqtt-host", "mqtt-port", "decoded-count", "last-decoded-seen",
                 "last-error", "last-event", "discovery-published", "discovery-published-at"):
        raw.add_argument(f"--{name}", default="")
    listen = modes.add_parser("listen", help="output of the pure LISTEN wmbusmeters instance")
    for name in ("candidates", "seen", "recent-raw", "candidate-raw", "candidate-analysis",
                 "snippet", "official-count"):
        listen.add_argument(f"--{name}-file", required=True)
    listen.add_argument("--meter-dir", required=True)
    listen.add_argument("--preview-meter-dir", required=True)
    listen.add_argument("--official", choices=("nonzero", "zero"), default="nonzero",
                        help="book blocks while official meters are configured (the "
                             "parallel LISTEN instance) or while none is (the main instance)")
    # Values the parser subshell inherits when the LISTEN instance starts.
    for name in ("official-count-default", "search-mode", "search-expected", "loglevel"):
        listen.add_argument(f"--{name}", default="")
    rx = modes.add_parser("rx", help="wmbus/<board>/rx messages")
    for name in ("reception", "mode", "history", "sequence", "boots", "clock"):
        rx.add_argument(f"--{name}-file", required=True)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    try:
        args = _parser().parse_args(argv)
    except SystemExit as exc:  # usage errors: report, never raise out of main
        return int(exc.code or 0)
    if args.mode in ("raw", "tracker", "rx", "listen"):
        # Stopping the add-on: write what is collected, then exit.
        signal.signal(signal.SIGTERM, _on_sigterm)
    if args.mode == "rssi":
        run(RssiBook(args.meter_dir, args.rssi_file))
    elif args.mode == "raw":
        run_lines(RawBook(args))
    elif args.mode == "listen":
        run_listen(ListenBook(args))
    elif args.mode == "tracker":
        run(TrackerBook(args.dev_pos, args.devices_file, args.meter_device_file,
                        args.reception_file, args.history_file))
    elif args.mode == "rx":
        run(RxBook(args.reception_file, args.mode_file, args.history_file,
                   args.sequence_file, args.boots_file, args.clock_file))
    return 0


if __name__ == "__main__":
    sys.exit(main())

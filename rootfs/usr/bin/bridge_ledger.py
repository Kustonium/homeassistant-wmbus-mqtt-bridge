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
import queue
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
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


def read_lines_flushing(stream, deferred: Deferred, waker=None) -> Iterator[bytes]:
    """The lines of stream, as iterating it gives them; while no line arrives,
    the deferred writes are made when they fall due. waker (a PreviewDecoder)
    is drained whenever its descriptor is readable: a one-shot finished."""
    try:
        fd = stream.fileno()
    except (AttributeError, OSError, ValueError):
        for line in stream:  # tests: an in-memory stream
            yield line
            deferred.flush_if_due()
            if waker is not None:
                waker.drain()
        return
    buf = b""
    fds = [fd] + ([waker.fileno()] if waker is not None else [])
    while True:
        wait = deferred.due_in()
        ready, _, _ = select.select(fds, [], [], wait)
        if waker is not None and waker.fileno() in ready:
            waker.drain()
            if fd not in ready:
                continue
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


def normalize_id(text: str) -> str:
    """05-raw.sh normalize_meter_id: 8 upper-case hex digits, "" when it is no id."""
    t = re.sub(r"[ \t\n\r\f\v]", "", text)
    if t in ("", "null"):
        return ""
    t = t[2:] if t[:2] in ("0x", "0X") else t
    t = _ascii_upper(t)
    if not re.fullmatch(r"[0-9A-F]+", t):
        return ""
    if len(t) < 8:
        return t.rjust(8, "0")
    return meter_id_from_raw_hex(t) if len(t) > 8 else t


def jq_r(line: str, alternatives: Tuple[str, ...]) -> str:
    """`$(jq -r '.a // .b // empty' <<< "$line" 2>/dev/null)` for top-level keys.

    Every JSON value of the line is one input; a value that cannot be indexed
    (number, string, array, boolean) is a jq error that prints nothing for it.
    """
    out = []
    for v in jq_values(line + "\n"):
        if v is None:
            continue
        if not isinstance(v, dict):
            continue
        for key in alternatives:
            x = v.get(key[1:])
            if x is not None and x is not False:
                out.append(x if isinstance(x, str) else _jq_pretty(x))
                break
    return "\n".join(out).rstrip("\n")


def jq_number_text(x: float) -> str:
    """How jq prints a number it computed (a double), e.g. a sum."""
    if x != x or x in (float("inf"), float("-inf")):
        return "null" if x != x else ("1.7976931348623157e+308" if x > 0 else "-1.7976931348623157e+308")
    if x == int(x) and abs(x) < 1e17:
        return str(int(x))
    return repr(x)


_PRIMARY_CANONICAL = ("total_m3", "total_kwh", "total_wh", "total_energy_consumption_kwh", "total_volume_m3")
_PRIMARY_LIKE = re.compile(r"(^total|_m3$|kwh|wh$|energy|volume)", re.I)
_PRIMARY_NOT = re.compile(r"(last_month|last_year|previous_month|previous_year|previous|prev|at_history|"
                          r"history|historic|billing|due_date|target|backflow|fraud|leak|tamper|alarm|"
                          r"production|tariff|partial|negative|reactive)", re.I)
_TARIFF_KWH = re.compile(r"^total_energy_consumption_tariff_[0-9]+_kwh$", re.I)
_INSTANT = re.compile(r"(_kw$|_w$|_m3h$|_l_h$)", re.I)
_META_KEYS = ("_", "id", "name", "meter", "media", "timestamp", "device_date_time", "rssi", "lqi",
              "status", "driver", "type")


def _tsv_cell(text: str) -> str:
    """jq @tsv escaping of one string."""
    return (text.replace("\\", "\\\\").replace("\t", "\\t").replace("\r", "\\r")
            .replace("\n", "\\n"))


def _first_object_lines(line: str, each: Callable[[dict], List[str]]) -> str:
    """The first output line of a jq program run over every value of line;
    a value the program fails on (not an object) prints nothing."""
    for v in jq_values(line + "\n"):
        if not isinstance(v, dict):
            continue
        out = each(v)
        if out:
            return out[0].split("\n", 1)[0]
    return ""


def select_primary_meter_value(line: str) -> str:
    """07-meters.sh _select_primary_meter_value: "key<TAB>value" or ""."""
    def each(v: dict) -> List[str]:
        pair = next(([k, v[k]] for k in _PRIMARY_CANONICAL if _is_number(v.get(k))), None)
        if pair is None:
            pair = next(([k, x] for k, x in v.items() if _is_number(x) and _PRIMARY_LIKE.search(k)
                         and not _PRIMARY_NOT.search(k)), None)
        return [] if pair is None else [_tsv_cell(pair[0]) + "\t" + _jq_tostring(pair[1])]
    return _first_object_lines(line, each)


def store_candidate_value(line: str, values_file: str, state_file: str, attempts_dir: str,
                          log: Callable[[str, str], None]) -> None:
    """11-listen.sh _store_candidate_value: the preview's value of a decoded
    candidate telegram, picked as status_meter_seen picks it, and the
    preview state decoded_value (or decoded_without_numeric_value)."""
    meter = normalize_id(jq_r(line, (".id",)))
    if not re.fullmatch(r"[0-9A-Fa-f]{8}", meter):
        return
    value_key, value = _bash_read_tabs(select_primary_meter_value(line), 2)
    if not value_key:
        def tariffs(v: dict) -> List[str]:
            vals = [float(x) for k, x in v.items() if _is_number(x) and _TARIFF_KWH.search(k)]
            return [f"total_energy_consumption_kwh\t{jq_number_text(sum(vals))}"] if vals else []
        value_key, value = _bash_read_tabs(_first_object_lines(line, tariffs), 2)
    if not value_key:
        value_key = _first_object_lines(
            line, lambda v: [k for k, x in v.items() if _is_number(x) and _INSTANT.search(k)])
    if value_key:
        if not value:
            for v in jq_values(line + "\n"):
                if isinstance(v, dict) and v.get(value_key) not in (None, False):
                    value = _jq_tostring(v[value_key]) if not isinstance(v[value_key], (dict, list)) \
                        else _jq_pretty(v[value_key])
                    break
    else:
        value_key, value = _bash_read_tabs(_first_object_lines(
            line, lambda v: [f"{k}\t{_jq_tostring(x)}" for k, x in v.items()
                             if k not in _META_KEYS and _is_number(x)]), 2)
    if not value:
        log("verbose", f"[DIAG] _store_candidate_value {meter}: no numeric value found, skipping")
        set_preview_state(state_file, attempts_dir, meter, "decoded_without_numeric_value")
        return
    log("debug", f"[DIAG] _store_candidate_value {meter}: value_key={value_key} value={value}")
    tsv_upsert(values_file, meter, f"{meter}\t{value}\t{value_key}\t{iso_now()}")
    set_preview_state(state_file, attempts_dir, meter, "decoded_value")
    log("debug", f"[DIAG] _store_candidate_value {meter}: wrote to status_candidate_values.tsv")


def set_preview_state(path: str, attempts_dir: str, meter: str, state: str, note: str = "") -> None:
    """06-candidates.sh _set_preview_state (see CLAUDE.md for the state machine).

    A terminal state (decoded_value, decoded_without_numeric_value,
    no_decode_result) discards the one-shot attempt counter.
    """
    tsv_upsert(path, meter, f"{meter}\t{state}\t{iso_now()}\t{note}")
    if state in ("decoded_value", "decoded_without_numeric_value", "no_decode_result"):
        _remove(os.path.join(attempts_dir, meter))


def _remove(path: str) -> None:
    """rm -f"""
    try:
        os.unlink(path)
    except OSError:
        pass


def ensure_autodecode(files: CandidateFiles, meter: str, driver: str, type_line: str, reload: str,
                      state_file: str, attempts_dir: str,
                      log: Callable[[str, str], None], request: Callable[..., None]) -> None:
    """06-candidates.sh ensure_candidate_autodecode.

    Keeps meter-preview-<id> as the candidate's driver says. An official
    meter or one that needs AES has none (an existing one is removed with its
    attempt counter). A preview config that is written or changes sets the
    state "pending", drops the attempt counter and, when the RAW ring holds a
    telegram of the meter, asks for a one-shot decode of it ("preview":
    preview_decode_raw_if_requested, which stays in bash for now). LISTEN is
    never reloaded; reload is only logged, as in bash.
    """
    preview = os.path.join(files.preview_meter_dir, f"meter-preview-{meter}")
    attempts = os.path.join(attempts_dir, meter)
    if official_meter(files.meter_dir, meter):
        if os.path.isfile(preview):
            _remove(preview)
            _remove(attempts)
            log("info", f"autodecode {meter}: skipped (official meter), pruned orphaned preview")
        return
    log("debug", f"[DIAG] autodecode {meter}: file={preview} driver={driver or 'auto'} "
                 f"type={type_line or '?'} reload={reload}")
    if candidate_type_requires_aes(type_line):
        log("verbose", f"[DIAG] autodecode {meter}: AES required, skipping preview")
        if os.path.isfile(preview):
            _remove(preview)
            _remove(attempts)
        return
    os.makedirs(files.preview_meter_dir, exist_ok=True)
    content = f"name=preview_{meter}\nid={meter.lower()}\n"
    if driver and driver not in ("auto", "unknown"):
        content += f"driver={driver}\n"
    try:
        with open(preview, "rb") as fh:
            unchanged = fh.read() == _b(content)
    except OSError:
        unchanged = False
    if unchanged:
        log("debug", f"[DIAG] autodecode {meter}: {preview} unchanged, no reload triggered")
        return
    with open(preview + ".tmp", "wb") as fh:  # the temporary name bash uses
        fh.write(_b(content))
    os.replace(preview + ".tmp", preview)
    log("verbose", f"[DIAG] autodecode {meter}: wrote {preview} (driver={driver or 'auto'})")
    set_preview_state(state_file, attempts_dir, meter, "pending")
    _remove(attempts)
    found = find_recent_raw(files.recent_raw, meter)
    if found and found[2]:
        # The candidate id goes with it: the RAW A-field is not the id for
        # manufacturer-specific layouts (Diehl/izar).
        request("preview", found[2], meter)


def append_event(path: str, level: str, message: str) -> None:
    """status_add_event's file: append, then keep the last 40 lines. (Its
    STATUS_LAST_EVENT lived in the bash subshell that called it, so nothing
    reaches status.json from here.)"""
    try:
        with open(path, "ab") as fh:
            fh.write(_b(f"{iso_now()}\t{level}\t{message}") + b"\n")
        _replace_with(path, _tail_lines(path, 40))
    except OSError:
        pass


def candidate_seen(files: CandidateFiles, meter: str, driver: str, type_line: str, manufacturer: str,
                   reload: str, state_file: str, attempts_dir: str, events_file: str,
                   log: Callable[[str, str], None], request: Callable[..., None]) -> None:
    """06-candidates.sh status_candidate_seen for a normalized id, without
    status.json (its callers here passed update_status=false or ran where
    write_status_json is a no-op).

    The refreshes still waiting for the deferred write happened before this:
    written first, the rows keep the order in which the telegrams arrived
    (and a waiting refresh of this candidate cannot overwrite it later).
    """
    _flush_candidate_refreshes(files)
    existed = any(_first_field(ln) == _b(meter) for ln in _read_lines(files.candidates))
    record_seen(files.seen, meter, "candidate")
    last_seen = iso_now()
    upsert_candidate_row(files.candidates, meter, driver, type_line, last_seen,
                         seen_stats(files.seen, meter), manufacturer)
    analyze_candidate_from_text(files, meter, type_line)
    ensure_autodecode(files, meter, driver or "auto", type_line, reload, state_file, attempts_dir,
                      log, request)
    if not existed:
        append_event(events_file, "candidate", f"Candidate detected {meter} ({driver})")


def candidate_seen_from_json(files: CandidateFiles, line: str, state_file: str, attempts_dir: str,
                             events_file: str, log: Callable[[str, str], None],
                             request: Callable[..., None]) -> None:
    """11-listen.sh status_candidate_seen_from_json."""
    meter = normalize_id(jq_r(line, (".id",)))
    if not re.fullmatch(r"[0-9A-Fa-f]{8}", meter):
        return
    driver = jq_r(line, (".meter", ".driver"))
    if not driver or driver == "null":
        driver = "auto"
    type_line = jq_r(line, (".media",))
    type_line = "" if type_line == "null" else type_line
    row = next((_bash_read_tabs(_s(ln), 9) for ln in _read_lines(files.candidates)
                if _first_field(ln) == _b(meter)), None)
    existing_driver, existing_type = (row[1], row[2]) if row else ("", "")
    # Decoded JSON wins; a stored value only fills what it lacks, and not
    # the generic placeholders, so a decode heals a RAW-registered row.
    if driver == "auto" and existing_driver and existing_driver != "auto":
        driver = existing_driver
    if not type_line and existing_type and existing_type != "wMBus telegram":
        type_line = existing_type
    # reload=false: no LISTEN reload per decoded preview telegram.
    candidate_seen(files, meter, driver, type_line or "decoded", "", "false", state_file, attempts_dir,
                   events_file, log, request)


def _env_int(name: str, default: int) -> int:
    """`${NAME:-default}`, then `[[ =~ ^[0-9]+$ ]] || default`."""
    v = os.environ.get(name, "")
    return int(v) if re.fullmatch(r"[0-9]+", v) else default


def record_no_decode_attempt(attempts_dir: str, state_file: str, meter: str,
                             log: Callable[[str, str], None]) -> None:
    """06-candidates.sh _record_preview_no_decode_attempt: count the one-shots
    that gave no JSON; three of them over 60 s or more make it no_decode_result."""
    cnt_file = os.path.join(attempts_dir, meter)
    cnt = start = 0
    if os.path.isfile(cnt_file):
        lines = _read_lines(cnt_file)
        c, st = _bash_read_tabs(_s(lines[0]) if lines else "", 2)
        cnt = int(c) if re.fullmatch(r"[0-9]+", c) else 0
        start = int(st) if re.fullmatch(r"[0-9]+", st) else 0
    ts = int(now())
    start = start if start > 0 else ts
    cnt += 1
    elapsed = ts - start
    try:  # mktemp "<file>.tmp.XXXXXX" && mv: nothing when the directory is gone
        fd, tmp = tempfile.mkstemp(prefix=meter + ".tmp.", dir=attempts_dir)
        with os.fdopen(fd, "w") as fh:
            fh.write(f"{cnt}\t{start}\n")
        os.replace(tmp, cnt_file)
    except OSError:
        pass
    if cnt >= 3 and elapsed >= 60:
        log("verbose", f"[DIAG] preview one-shot {meter}: no JSON after {cnt} attempts ({elapsed}s)")
        set_preview_state(state_file, attempts_dir, meter, "no_decode_result")
    else:
        log("debug", f"[DIAG] preview one-shot {meter}: no JSON attempt #{cnt} (elapsed={elapsed}s)")


class PreviewDecoder:
    """06-candidates.sh preview_decode_raw_if_requested: the one-shot preview decode.

    A candidate's RAW frame is decoded by a short-lived wmbusmeters with a
    temporary config holding only that candidate's meter-preview-<id> file.
    The checks, the per-id lock, the parallel slots and the throttle are the
    bash function's, on the same files, so either side can hold them. The
    decoder runs in a thread, as bash ran it in the background; its result is
    booked on the thread that reads the input (drain, woken through a pipe),
    so the bookkeeping is never written from two threads. close() waits for
    the decoders still running and books them, or frees their lock and slot.
    """

    def __init__(self, files: CandidateFiles, runtime: str, state_file: str, attempts_dir: str,
                 values_file: str, events_file: str, loglevel: str,
                 log: Callable[[str, str], None], request: Callable[..., None]) -> None:
        self.files, self.runtime = files, runtime
        self.state_file, self.attempts_dir = state_file, attempts_dir
        self.values_file, self.events_file = values_file, events_file
        self.loglevel, self.log, self.forward = loglevel, log, request
        self.binary = os.environ.get("WMBUSMETERS_ONESHOT_BIN") or "/usr/bin/wmbusmeters"
        self.results: "queue.SimpleQueue" = queue.SimpleQueue()
        self.running: List[Tuple[threading.Thread, str, str, str]] = []
        self.rfd, self.wfd = os.pipe()
        os.set_blocking(self.rfd, False)

    def fileno(self) -> int:
        return self.rfd

    def request(self, raw: str, id_hint: str = "") -> None:
        """Everything up to the start of the decoder, as bash does it in the caller."""
        raw = _ascii_upper(_BASH_SPACE.sub("", raw))
        if not _HEX_UPPER.fullmatch(raw):
            return
        if re.fullmatch(r"[0-9A-Fa-f]{8}", id_hint):
            meter = normalize_id(id_hint)
        else:
            # The preview config whose id is in the frame (little-endian), as
            # the A-field is not the id for manufacturer-specific layouts.
            meter, lower = "", raw.lower()
            for path in sorted(glob.glob(os.path.join(self.files.preview_meter_dir, "meter-preview-*"))):
                cand = os.path.basename(path)[len("meter-preview-"):]
                if not os.path.exists(path) or not _ID8.fullmatch(cand):
                    continue
                if (cand[6:8] + cand[4:6] + cand[2:4] + cand[0:2]).lower() in lower:
                    meter = cand.upper()
                    break
            meter = meter or meter_id_from_raw_hex(raw)
        if not _ID8.fullmatch(meter):
            return
        cfg = os.path.join(self.files.preview_meter_dir, f"meter-preview-{meter}")
        if not os.path.isfile(cfg):
            return
        locks = os.path.join(self.runtime, ".preview_decode_locks")
        lasts = os.path.join(self.runtime, ".preview_decode_last")
        os.makedirs(locks, exist_ok=True)
        os.makedirs(lasts, exist_ok=True)
        lock_dir, last_file = os.path.join(locks, meter), os.path.join(lasts, meter)
        ts = int(now())
        last = int(_digits_or_zero(last_file))
        if ts - last < _env_int("PREVIEW_DECODE_MIN_INTERVAL_SECONDS", 20):
            return
        # A preview that already shows a value is decoded again at most every
        # PREVIEW_DECODED_MIN_INTERVAL_SECONDS; any change of its config sets
        # "pending" first, which decodes at once.
        if (ts - last < _env_int("PREVIEW_DECODED_MIN_INTERVAL_SECONDS", 300)
                and preview_state(self.state_file, meter) == "decoded_value"):
            return
        try:
            os.mkdir(lock_dir)
        except OSError:
            return
        slot = self._acquire_slot()
        if not slot:
            _rmdir(lock_dir)
            return
        try:
            with open(last_file, "w") as fh:
                fh.write(f"{ts}\n")
        except OSError:
            pass
        try:
            tmp = tempfile.mkdtemp(prefix=f".preview_decode.{meter}.", dir=self.runtime)
        except OSError:
            _rmdir(slot)
            _rmdir(lock_dir)
            return
        try:
            conf_dir = os.path.join(tmp, "etc", "wmbusmeters.d")
            os.makedirs(conf_dir, exist_ok=True)
            with open(os.path.join(tmp, "etc", "wmbusmeters.conf"), "w") as fh:
                fh.write(f"loglevel={self.loglevel}\ndevice=stdin:hex\nlogfile=/dev/stdout\nformat=json\n")
            shutil.copyfile(cfg, os.path.join(conf_dir, f"meter-preview-{meter}"))
        except OSError:
            pass
        t = threading.Thread(target=self._decode, args=(meter, raw, tmp, slot, lock_dir), daemon=True)
        self.running.append((t, tmp, slot, lock_dir))
        t.start()

    def _acquire_slot(self) -> str:
        """_preview_acquire_slot: one of PREVIEW_DECODE_MAX_PARALLEL slot directories."""
        n_max = max(_env_int("PREVIEW_DECODE_MAX_PARALLEL", 2), 1)
        slots = os.path.join(self.runtime, ".preview_decode_slots")
        os.makedirs(slots, exist_ok=True)
        for n in range(1, n_max + 1):
            slot = os.path.join(slots, str(n))
            try:
                os.mkdir(slot)
                return slot
            except OSError:
                continue
        return ""

    def _decode(self, meter: str, raw: str, tmp: str, slot: str, lock_dir: str) -> None:
        json_line = ""
        try:
            out = subprocess.run([self.binary, f"--useconfig={tmp}"], input=_b(raw + "\n"),
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout
            json_line = next((ln for ln in _s(out).split("\n")
                              if re.match(r'\{.*"_":"telegram"', ln)), "")
        except OSError:
            pass
        self.results.put((meter, json_line, tmp, slot, lock_dir))
        try:
            os.write(self.wfd, b"x")
        except OSError:
            pass

    def drain(self) -> None:
        """Book the decoders that finished."""
        try:
            while os.read(self.rfd, 4096):
                pass
        except (BlockingIOError, OSError):
            pass
        while True:
            try:
                meter, json_line, tmp, slot, lock_dir = self.results.get_nowait()
            except queue.Empty:
                return
            self.running = [r for r in self.running if r[1] != tmp]
            try:
                if json_line:
                    self.log("debug", f"[DIAG] preview one-shot {meter}: decoded JSON")
                    candidate_seen_from_json(self.files, json_line, self.state_file, self.attempts_dir,
                                             self.events_file, self.log, self._route)
                    store_candidate_value(json_line, self.values_file, self.state_file,
                                          self.attempts_dir, self.log)
                else:
                    record_no_decode_attempt(self.attempts_dir, self.state_file, meter, self.log)
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
                _rmdir(slot)
                _rmdir(lock_dir)

    def _route(self, *fields: str) -> None:
        """A one-shot asked for while booking one (a preview config the decoded
        driver changed) comes back here; it meets the throttle bash met."""
        if fields[0] == "preview":
            self.request(fields[1], fields[2])
        else:
            self.forward(*fields)

    def close(self, timeout: float = 30.0) -> None:
        """At the end of the input: book the decoders still running; a decoder
        that does not finish in time leaves its candidate to the next one-shot
        (its lock and slot are freed, its result dropped)."""
        deadline = time.monotonic() + timeout
        for t, _tmp, _slot, _lock in list(self.running):
            t.join(max(0.0, deadline - time.monotonic()))
        self.drain()
        for _t, tmp, slot, lock_dir in self.running:
            shutil.rmtree(tmp, ignore_errors=True)
            _rmdir(slot)
            _rmdir(lock_dir)
        self.running = []
        # A new pipe: a decoder that did not finish may still write to the old one.
        for fd in (self.rfd, self.wfd):
            try:
                os.close(fd)
            except OSError:
                pass
        self.rfd, self.wfd = os.pipe()
        os.set_blocking(self.rfd, False)


def _rmdir(path: str) -> None:
    try:
        os.rmdir(path)
    except OSError:
        pass


def _preview_decoder(a: argparse.Namespace, files: CandidateFiles, log: Callable[[str, str], None],
                     forward: Callable[..., None]) -> Optional[PreviewDecoder]:
    """The one-shot decoder of a book, when bash passed what it writes
    (--preview-oneshot-runtime and the files of the preview state machine);
    otherwise None and the one-shot is asked of bash ("preview" request)."""
    need = [getattr(a, n, "") for n in ("preview_oneshot_runtime", "candidate_values_file",
                                        "preview_attempts_dir", "preview_state_file", "events_file")]
    if not all(need):
        return None
    return PreviewDecoder(files, need[0], need[3], need[2], need[1], need[4], a.loglevel, log, forward)


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
        self.decoder = _preview_decoder(a, self.candidates, self.log, self.write_request)

    def request(self, *fields: str) -> None:
        if fields[0] == "preview" and self.decoder is not None:
            self.decoder.request(fields[1], fields[2] if len(fields) > 2 else "")
            return
        self.write_request(*fields)

    def write_request(self, *fields: str) -> None:
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
            full = _MFCT_NAMES.get(code) or code
            if candidate_fill_manufacturer(a.candidates_file, meter, full):
                self.log("debug", f"[DIAG] candidate {meter}: filled manufacturer fallback code={full}")
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
            # What ensure_candidate_autodecode logs for an unchanged candidate.
            preview = os.path.join(self.candidates.preview_meter_dir, f"meter-preview-{meter}")
            if not official_meter(self.candidates.meter_dir, meter):
                self.log("debug", f"[DIAG] autodecode {meter}: file={preview} driver={new_driver} "
                                  f"type={new_type} reload=true")
                if candidate_type_requires_aes(new_type):
                    self.log("verbose", f"[DIAG] autodecode {meter}: AES required, skipping preview")
                else:
                    self.log("debug", f"[DIAG] autodecode {meter}: {preview} unchanged, no reload triggered")
            return
        if a.preview_state_file and a.preview_attempts_dir:
            # status_candidate_seen <id> <driver> <type> false: no status.json.
            candidate_seen(self.candidates, meter, new_driver, new_type, "", "true",
                           a.preview_state_file, a.preview_attempts_dir, a.events_file,
                           self.log, self.request)
            return
        self.request("sap", raw)

    def log(self, level: str, message: str) -> None:
        """log ("info", always), log_verbose and log_debug, on stderr: stdout
        carries the requests to the bash loop."""
        if level == "info" or self.a.loglevel == "debug" or (
                level == "verbose" and self.a.loglevel == "verbose"):
            print(f"[wmbus-bridge] {message}", file=sys.stderr, flush=True)

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
        for raw in read_lines_flushing(stream, book.deferred, book.decoder):
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
        if book.decoder is not None:
            book.decoder.close()
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
    search_cache_candidate, when bash did not pass SEARCH_STATE) and decoded
    JSON ("json").
    """

    SEP = "\x1f"

    def __init__(self, a: argparse.Namespace, out=None, err=None,
                 search: Optional["SearchBook"] = None) -> None:
        self.a = a
        self.out = out if out is not None else sys.stdout
        self.err = err if err is not None else sys.stderr
        self.deferred = Deferred()
        self.candidates = CandidateFiles(a.candidates_file, a.seen_file, a.recent_raw_file,
                                         a.candidate_raw_file, a.candidate_analysis_file,
                                         a.preview_meter_dir, a.meter_dir, self.deferred)
        self.block = ("", "", "", "")
        self.decoder = _preview_decoder(a, self.candidates, self.log, self.write_request)
        self.search = search
        if search is None and a.search_mode == "true" and self.in_process():
            state = search_state_from_env()
            if state is not None:
                self.search = SearchBook(a, state, err=self.err, request=self.write_request)

    def request(self, *fields: str) -> None:
        if fields[0] == "preview" and self.decoder is not None:
            self.decoder.request(fields[1], fields[2])
            return
        self.write_request(*fields)

    def write_request(self, *fields: str) -> None:
        try:
            self.out.write(self.SEP.join(fields) + "\n")
            self.out.flush()
        except OSError:
            pass

    def log(self, level: str, message: str) -> None:
        """log ("info", always), log_verbose and log_debug. On stderr: stdout
        carries the requests to the bash loop."""
        if level == "info" or self.a.loglevel == "debug" or (
                level == "verbose" and self.a.loglevel == "verbose"):
            print(f"[wmbus-bridge] {message}", file=self.err, flush=True)

    def line(self, text: str) -> None:
        if text.startswith("{") and '"_":"telegram"' in text:
            if self.in_process() and self.a.candidate_values_file:
                self.json(text)
            else:
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
            if self.search is not None:
                self.search.cache_candidate(
                    meter, driver, type_line,
                    lambda m, d, t: self.candidate_seen(m, d, t, "", "true"))
            else:
                self.request("search", meter, driver, type_line)
            return
        if not self.refresh(meter, driver, type_line or "listen", manufacturer):
            if self.in_process():
                self.snippet(meter, driver, type_line, manufacturer)
            else:
                self.request("snippet", meter, driver, type_line, manufacturer)

    def in_process(self) -> bool:
        """bash passed the files status_candidate_seen writes: new and changed
        candidates and decoded JSON are booked here, not asked of bash."""
        return bool(self.a.preview_state_file and self.a.events_file and self.a.preview_attempts_dir)

    def candidate_seen(self, meter: str, driver: str, type_line: str, manufacturer: str,
                       reload: str) -> None:
        """06-candidates.sh status_candidate_seen for a normalized id.

        status.json is not written (write_status_json is a no-op in the bash
        loop this replaces: its STATUS_* snapshot is stale).
        """
        candidate_seen(self.candidates, meter, driver, type_line, manufacturer, reload,
                       self.a.preview_state_file, self.a.preview_attempts_dir, self.a.events_file,
                       self.log, self.request)

    def json(self, line: str) -> None:
        """11-listen.sh _process_listen_json_line: a decoded telegram of a candidate."""
        self.log("debug", f"[DIAG] LISTEN-parse: JSON telegram received: {line[:160]}")
        if self.official_meters() > 0:
            self.candidate_seen_from_json(line)
        self.log("debug", "[DIAG] LISTEN-parse: calling _store_candidate_value")
        store_candidate_value(line, self.a.candidate_values_file, self.a.preview_state_file,
                              self.a.preview_attempts_dir, self.log)

    def candidate_seen_from_json(self, line: str) -> None:
        """11-listen.sh status_candidate_seen_from_json."""
        candidate_seen_from_json(self.candidates, line, self.a.preview_state_file,
                                 self.a.preview_attempts_dir, self.a.events_file, self.log, self.request)

    def snippet(self, meter: str, driver: str, type_line: str, manufacturer: str) -> None:
        """11-listen.sh emit_snippet_if_new."""
        meter = normalize_id(meter)
        if not re.fullmatch(r"[0-9A-Fa-f]{8}", meter):
            return
        self.candidate_seen(meter, driver or "auto", type_line or "listen", manufacturer, "true")
        if _b(meter) not in _read_lines(self.a.snippet_file):
            with open(self.a.snippet_file, "ab") as fh:
                fh.write(_b(meter) + b"\n")
            for line in ("=== NEW METER CANDIDATE DETECTED ===", f"Received telegram from: {meter}",
                         *([f"Suggested driver: {driver}"] if driver else []),
                         "Add to options.json meters[] (example):",
                         f'  no key:   {{"id":"meter_{meter}","meter_id":"{meter}","type":"auto",'
                         f'"type_other":"","key":""}}',
                         f'  zero key: {{"id":"meter_{meter}","meter_id":"{meter}","type":"auto",'
                         f'"type_other":"","key":"00000000000000000000000000000000"}}',
                         "=================================="):
                print(f"[wmbus-bridge][WARN] {line}", file=self.err, flush=True)

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
        for raw in read_lines_flushing(stream, book.deferred, book.decoder):
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
        if book.decoder is not None:
            book.decoder.close()
        book.deferred.flush(err)


# ── SEARCH (10-search.sh) ───────────────────────────────────────────────────

_SEARCH_STATE_NAMES = (
    "SEARCH_EXPECTED_VALUE_M3", "SEARCH_TOLERANCE_M3", "SEARCH_DELTA_MODE", "SEARCH_MIN_DELTA_M3",
    "SEARCH_TOPIC", "SEARCH_CANDIDATES_FILE", "SEARCH_MATCHES_FILE", "SEARCH_STATUS_FILE",
    "SEARCH_USING_TEMP_METERS", "SEARCH_IGNORED_COUNT", "SEARCH_TEMP_METERS_LOADED",
    "SEARCH_CHECKED_VALUES", "SEARCH_DECODED_JSON_COUNT", "SEARCH_MATCH_COUNT",
    "SEARCH_LAST_CACHE_CHANGE", "SEARCH_LAST_CANDIDATE_ID", "SEARCH_LAST_CANDIDATE_DRIVER",
    "SEARCH_LAST_CANDIDATE_TYPE", "SEARCH_LAST_CHECKED_ID", "SEARCH_LAST_CHECKED_DRIVER",
    "SEARCH_LAST_CHECKED_FIELD", "SEARCH_LAST_CHECKED_VALUE", "SEARCH_LAST_CHECKED_DIFF",
    "SEARCH_LAST_REASON", "SEARCH_LAST_IGNORED_REASON", "DISCOVERY_ENABLED")
_SEARCH_COUNTERS = ("SEARCH_IGNORED_COUNT", "SEARCH_TEMP_METERS_LOADED", "SEARCH_CHECKED_VALUES",
                    "SEARCH_DECODED_JSON_COUNT", "SEARCH_MATCH_COUNT")
_AWK_NUM_PREFIX = re.compile(r"[ \t\n]*[-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?")
_AWK_STRNUM = re.compile(r"[ \t\n]*[-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?[ \t\n]*")
_SEARCH_CACHED_ROW = re.compile(rb"^[0-9A-Fa-f]{8}[ \t\r\v\f]")
_SEARCH_NOT_FIELDS = ("_", "id", "name", "meter", "media", "timestamp", "device_date_time",
                      "rssi", "lqi", "status")


def search_state_from_env(env: Optional[Dict[str, str]] = None) -> Optional[Dict[str, str]]:
    """SEARCH_STATE as _search_state (12-pipeline.sh) prints it: one
    "name<0x1F>value" line per variable. None when bash did not pass it."""
    text = (env if env is not None else os.environ).get("SEARCH_STATE")
    if text is None:
        return None
    state = {name: "" for name in _SEARCH_STATE_NAMES}
    for row in text.split("\n"):
        k, sep, v = row.partition("\x1f")
        if sep and k in state:
            state[k] = v
    return state


def _awk_number(text: str) -> float:
    """A string in awk arithmetic: its numeric prefix, 0 without one."""
    m = _AWK_NUM_PREFIX.match(text)
    return float(m.group(0)) if m else 0.0


def _awk_compare(a: str, b: str, op: str) -> bool:
    """`a <op> b` of two `awk -v` values: numeric when both look numeric, else as strings."""
    if _AWK_STRNUM.fullmatch(a) and _AWK_STRNUM.fullmatch(b):
        x, y = float(a), float(b)
    else:
        x, y = a, b  # type: ignore[assignment]
    return x <= y if op == "<=" else x >= y


def _bash_int(text: str) -> int:
    """A counter as `$((X + 1))` reads it (an empty or odd value as 0)."""
    return int(text) if re.fullmatch(r"-?[0-9]+", text.strip()) else 0


def _ascii_lower(text: str) -> str:
    return text.translate(_ASCII_LOWER)


_ASCII_LOWER = {c: c + 32 for c in range(ord("A"), ord("Z") + 1)}


def obj_id(text: str) -> str:
    """01-utils.sh _obj_id: lower case, [a-z0-9_] only, no doubled, leading or trailing "_"."""
    s = re.sub(r"[^a-z0-9_]", "_", text.lower())
    while "__" in s:
        s = s.replace("__", "_")
    s = s[1:] if s.startswith("_") else s
    return s[:-1] if s.endswith("_") else s


def _tsv_escape(text: str) -> str:
    """jq's @tsv for one field."""
    return text.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


class SearchBook:
    """10-search.sh: SEARCH's candidate cache, its value check and search_status.json.

    The SEARCH_* variables start as the process that runs it inherited them
    (SEARCH_STATE). In bash the decode loop and the zero-meter LISTEN parser
    it forked each kept their own copy and both wrote search_status.json with
    it; here one book serves both (DecodeBook hands it to its ListenBook).
    """

    def __init__(self, a: argparse.Namespace, state: Dict[str, str], err=None,
                 request: Optional[Callable[..., None]] = None) -> None:
        self.a = a
        self.v = dict(state)
        for name in _SEARCH_COUNTERS:
            self.v[name] = str(_bash_int(self.v.get(name, "")))
        self.err = err if err is not None else sys.stderr
        self.request = request
        self.reported_expected: Set[str] = set()
        self.reported_delta: Set[str] = set()
        self.first_value: Dict[str, str] = {}
        self.cleared_fields: Set[str] = set()
        self.cleaned_legacy: Set[str] = set()

    @property
    def mode(self) -> bool:
        return self.a.search_mode == "true"

    def warn(self, message: str) -> None:
        print(f"[wmbus-bridge][WARN] {message}", file=self.err, flush=True)

    def bump(self, name: str) -> None:
        self.v[name] = str(_bash_int(self.v[name]) + 1)

    def cached_count(self) -> int:
        """search_cached_count."""
        return sum(1 for ln in _read_lines(self.v["SEARCH_CANDIDATES_FILE"])
                   if _SEARCH_CACHED_ROW.match(ln))

    def write_status(self, phase: str = "auto", reason: str = "") -> None:
        """write_search_status."""
        v = self.v
        if not v["SEARCH_STATUS_FILE"]:
            return
        cached = self.cached_count()
        try:
            with open(v["SEARCH_MATCHES_FILE"], "rb") as fh:
                matches = fh.read().count(b"\n")
        except OSError:
            matches = 0
        if phase == "auto":
            if _bash_int(v["SEARCH_MATCH_COUNT"]) > 0 or matches > 0:
                phase = "matched"
            elif v["SEARCH_USING_TEMP_METERS"] == "true":
                phase = "search"
            elif self.mode and v["SEARCH_EXPECTED_VALUE_M3"] != "0":
                phase = "collecting"
            else:
                phase = "listen"
        if reason:
            v["SEARCH_LAST_REASON"] = reason

        def num(name: str) -> Any:
            return _jq_tonumber(v[name] or "0")

        doc = {
            "updated_at": iso_now(),
            "phase": phase,
            "search_mode": self.mode,
            "expected_m3": num("SEARCH_EXPECTED_VALUE_M3"),
            "tolerance_m3": num("SEARCH_TOLERANCE_M3"),
            "cached_candidates": _jq_tonumber(str(cached)),
            "ignored_candidates": num("SEARCH_IGNORED_COUNT"),
            "loaded_temp_meters": num("SEARCH_TEMP_METERS_LOADED"),
            "decoded_json": num("SEARCH_DECODED_JSON_COUNT"),
            "checked_values": num("SEARCH_CHECKED_VALUES"),
            "matches": _jq_tonumber(str(matches)),
            "cache_changed_at": v["SEARCH_LAST_CACHE_CHANGE"],
            "last_candidate": {"id": v["SEARCH_LAST_CANDIDATE_ID"],
                               "driver": v["SEARCH_LAST_CANDIDATE_DRIVER"],
                               "type": v["SEARCH_LAST_CANDIDATE_TYPE"]},
            "last_checked": {"id": v["SEARCH_LAST_CHECKED_ID"], "driver": v["SEARCH_LAST_CHECKED_DRIVER"],
                             "field": v["SEARCH_LAST_CHECKED_FIELD"],
                             "value": v["SEARCH_LAST_CHECKED_VALUE"],
                             "diff_m3": v["SEARCH_LAST_CHECKED_DIFF"]},
            "last_reason": v["SEARCH_LAST_REASON"],
            "last_ignored_reason": v["SEARCH_LAST_IGNORED_REASON"],
        }
        try:
            _write_replace_tmp(v["SEARCH_STATUS_FILE"], _b(_jq_pretty(doc)) + b"\n")
        except OSError:
            pass

    # ── a candidate of the LISTEN parser ──

    def cache_candidate(self, meter: str, driver: str, type_line: str,
                        candidate_seen: Callable[[str, str, str], None]) -> None:
        """search_cache_candidate; candidate_seen is status_candidate_seen (id, driver, type)."""
        v = self.v
        mid = normalize_id(meter)
        if not _ID8.fullmatch(mid):
            return
        driver = driver or "auto"
        type_lc = _ascii_lower(type_line)
        if not (type_lc and not candidate_type_requires_aes(type_lc) and "water" in type_lc):
            self.bump("SEARCH_IGNORED_COUNT")
            v["SEARCH_LAST_CANDIDATE_ID"] = mid
            v["SEARCH_LAST_CANDIDATE_DRIVER"] = driver
            v["SEARCH_LAST_CANDIDATE_TYPE"] = type_line or "unknown"
            v["SEARCH_LAST_IGNORED_REASON"] = "not_water_m3_candidate_or_encrypted"
            self.warn(f"SEARCH ignored: id={mid} driver={driver} type={type_line or 'unknown'} "
                      f"reason=not_water_m3_candidate_or_encrypted (ignored={v['SEARCH_IGNORED_COUNT']}).")
            self.write_status("auto", "candidate_ignored")
            return
        path = v["SEARCH_CANDIDATES_FILE"]
        open(path, "ab").close()
        if any(ln.startswith(_b(mid) + b"\t") for ln in _read_lines(path)):
            return
        with open(path, "ab") as fh:
            fh.write(_b(f"{mid}\t{driver}\n"))
        v["SEARCH_LAST_CACHE_CHANGE"] = iso_now()
        v["SEARCH_LAST_CANDIDATE_ID"] = mid
        v["SEARCH_LAST_CANDIDATE_DRIVER"] = driver
        v["SEARCH_LAST_CANDIDATE_TYPE"] = type_line or "unknown"
        self.warn(f"SEARCH discovered: id={mid} driver={driver} type={type_line or 'unknown'} stored as "
                  f"water candidate (cached={self.cached_count()}, ignored={v['SEARCH_IGNORED_COUNT']}).")
        candidate_seen(mid, driver, type_line or "unknown")
        self.write_status("auto", "candidate_cached")

    # ── a decoded telegram ──

    def is_temp(self, line: str) -> bool:
        """09-discovery.sh is_search_temp_json: a temporary search_<id> meter."""
        return self.mode and jq_r(line, (".name",)).startswith("search_")

    def telegram(self, line: str) -> bool:
        """What the decode loop runs for SEARCH: status_mark_search_decoded_no_aes,
        process_search_json and, for a temporary meter, clear_search_discovery_from_json.
        True for a temporary meter (with any id): nothing else is done with it."""
        temp = self.is_temp(line)
        mid = normalize_id(jq_r(line, (".id",)))
        if not _ID8.fullmatch(mid):
            return temp
        if temp and self.a.candidate_analysis_file:
            # status_mark_search_decoded_no_aes. No LISTEN parser runs while
            # temporary meters decode, so no candidate row waits for a write.
            tsv_upsert(self.a.candidate_analysis_file, mid, f"{mid}\tno_aes\tTemporary SEARCH meter decoded without "
                                                f"key; no AES key was required for this telegram\t\t\t0\t{iso_now()}")
        self.process_json(line, mid, temp)
        if temp:
            self.clear_discovery(line, mid)
        return temp

    def process_json(self, line: str, mid: str, temp: bool) -> None:
        """process_search_json."""
        if not self.mode:
            return
        v = self.v
        if temp:
            self.bump("SEARCH_DECODED_JSON_COUNT")
        expected = v["SEARCH_EXPECTED_VALUE_M3"]
        for field, value in self.numbers(line):
            if not field or not value:
                continue
            field_lc = _ascii_lower(field)
            if "total_volume" not in field_lc and "m3" not in field_lc:
                continue
            meter = jq_r(line, (".meter",))
            self.bump("SEARCH_CHECKED_VALUES")
            v["SEARCH_LAST_CHECKED_ID"] = mid
            v["SEARCH_LAST_CHECKED_DRIVER"] = meter or "auto"
            v["SEARCH_LAST_CHECKED_FIELD"] = field
            v["SEARCH_LAST_CHECKED_VALUE"] = value
            key = f"{mid}|{field}"
            diff = f"{_awk_number(value) - _awk_number(expected):.6f}"
            d = float(diff)
            absdiff = f"{-d if d < 0 else d:.6f}"
            v["SEARCH_LAST_CHECKED_DIFF"] = absdiff
            v["SEARCH_LAST_REASON"] = "value_out_of_tolerance"
            if (expected != "0" and _awk_compare(absdiff, v["SEARCH_TOLERANCE_M3"], "<=")
                    and key not in self.reported_expected):
                media = jq_r(line, (".media",))
                self.warn(f"SEARCH MATCH: id={mid} driver={meter or 'unknown'} media={media or 'unknown'} "
                          f"field={field} value={value} m3 expected={expected} diff={absdiff} m3")
                self.warn('SEARCH SUGGESTED CONFIG: {"id":"meter_%s","meter_id":"%s","type":"%s",'
                          '"type_other":"","key":""}' % (mid, mid, meter or "auto"))
                self.emit("value_match", line, field, value, absdiff, "0")
                self.record_match(line, field, value, absdiff)
                self.bump("SEARCH_MATCH_COUNT")
                v["SEARCH_LAST_REASON"] = "value_match"
                self.write_status("matched", "value_match")
                self.reported_expected.add(key)
            else:
                self.write_status("auto", "value_out_of_tolerance")
            if v["SEARCH_DELTA_MODE"] == "true":
                if key not in self.first_value:
                    self.first_value[key] = value
                else:
                    first = self.first_value[key]
                    delta = f"{_awk_number(value) - _awk_number(first):.6f}"
                    if (_awk_compare(delta, v["SEARCH_MIN_DELTA_M3"], ">=")
                            and key not in self.reported_delta):
                        self.warn(f"SEARCH delta: id={mid} field={field} first={first} now={value} "
                                  f"delta={delta} m3")
                        self.emit("delta_match", line, field, value, "0", delta)
                        self.reported_delta.add(key)

    @staticmethod
    def numbers(line: str) -> List[Tuple[str, str]]:
        """`jq -r 'to_entries[] | select((.value|type)=="number") | [.key, (.value|tostring)] | @tsv'`
        read back with `IFS=$'\\t' read -r field value`."""
        out = []
        for doc in jq_values(line + "\n"):
            if not isinstance(doc, dict):
                continue
            for k, x in doc.items():
                if _is_number(x):
                    field, value = bash_read_fields(_tsv_escape(k) + "\t" + jq_dumps(x), 2, "\t")
                    out.append((field.strip("\t"), value.strip("\t")))
        return out

    def emit(self, kind: str, line: str, field: str, value: str, diff: str, delta: str) -> None:
        """emit_search_payload."""
        mid = normalize_id(jq_r(line, (".id",)))
        if not _ID8.fullmatch(mid):
            return
        nums = []
        for text in (value, self.v["SEARCH_EXPECTED_VALUE_M3"], diff, delta):
            try:
                vals = jq_values(text)
            except ValueError:
                return
            if len(vals) != 1:
                return  # jq: invalid JSON text passed to --argjson
            nums.append(vals[0])
        payload = jq_dumps({"event": kind, "id": mid, "meter": jq_r(line, (".meter",)),
                            "media": jq_r(line, (".media",)), "name": jq_r(line, (".name",)),
                            "field": field, "value_m3": nums[0], "expected_value_m3": nums[1],
                            "diff_m3": nums[2], "delta_m3": nums[3]})
        self.publish(self.v["SEARCH_TOPIC"], payload, False)

    def record_match(self, line: str, field: str, value: str, diff: str) -> None:
        """search_record_match: one row, the last 100 kept."""
        v = self.v
        mid = normalize_id(jq_r(line, (".id",)))
        if not _ID8.fullmatch(mid):
            return
        row = "\t".join([iso_now(), mid, jq_r(line, (".meter",)) or "auto", jq_r(line, (".media",)),
                         field, value, v["SEARCH_EXPECTED_VALUE_M3"], diff, v["SEARCH_TOLERANCE_M3"]])
        path = v["SEARCH_MATCHES_FILE"]
        try:
            with open(path, "ab") as fh:
                fh.write(_b(row) + b"\n")
            _write_replace_tmp(path, b"".join(ln + b"\n" for ln in _read_lines(path)[-100:]))
        except OSError:
            pass

    def clear_discovery(self, line: str, mid: str) -> None:
        """clear_search_discovery_from_json: empty retained configs for what a
        temporary meter would have announced, in case an older run did."""
        prefix = self.a.discovery_prefix
        if self.v["DISCOVERY_ENABLED"] == "true" and mid not in self.cleaned_legacy:
            # clean_legacy_entities; mqtt_pub does not fail (mosquitto_pub || true).
            self.publish(f"{prefix}/sensor/wmbus_{mid}/rssi_dbm/config", "", True)
            self.cleaned_legacy.add(mid)
        uniq = f"wmbus_{mid}"
        for doc in jq_values(line + "\n"):
            if not isinstance(doc, dict):
                continue
            for k, x in doc.items():
                if k in _SEARCH_NOT_FIELDS or isinstance(x, (dict, list)):
                    continue
                for key in k.split("\n"):  # `jq -r .key` read line by line
                    obj = obj_id(key)
                    if not key or not obj or f"{mid}|{obj}" in self.cleared_fields:
                        continue
                    self.publish(f"{prefix}/sensor/{uniq}/{obj}/config", "", True)
                    self.cleared_fields.add(f"{mid}|{obj}")
        if f"{mid}|status" not in self.cleared_fields:
            self.publish(f"{prefix}/sensor/{uniq}/status/config", "", True)
            self.publish(f"{prefix}/binary_sensor/{uniq}/status_problem/config", "", True)
            self.cleared_fields.add(f"{mid}|status")

    def publish(self, topic: str, payload: str, retain: bool) -> None:
        """mqtt_pub: a PUB frame to the publisher, else mosquitto_pub in the bash loop."""
        data = _b(payload)
        try:
            with socket.create_connection(("127.0.0.1", int(self.a.publisher_port)), timeout=5) as s:
                s.sendall(b"PUB %d %d " % (1 if retain else 0, len(data)) + _b(topic) + b"\n" + data + b"\n")
            return
        except (OSError, ValueError, AttributeError):
            pass
        if self.request is not None:
            self.request("pub", topic, payload, "true" if retain else "false")

# ── the decode pipeline's output (run_once's loop) ──────────────────────────

_TARIFF_CAPTURE = re.compile(r"^total_energy_consumption_tariff_([0-9]+)_kwh$", re.I)
_ELECTRIC_KEY = re.compile(r"(energy|power|voltage|current).*(_kwh|_wh|_kw|_w|_v|_a)$", re.I)
_INSTANT_METER = re.compile(r"(_kw$|_w$|_m3h$|_l_h$|_c$|_rh$|_bar$)", re.I)
_INSTANT_NOT = re.compile(r"(average|last_|previous|history|historic|minimum|maximum|min_|max_)", re.I)
_DEC_ID = re.compile(r'"id":"?([^",}]*)')


def _first_line(text: str) -> str:
    return text.split("\n", 1)[0]


def meter_metadata(line: str) -> List[str]:
    r"""`jq -r '"\(.id // "")\u001f\(.name // "")\u001f\(.meter // "")\u001f\(.media // "")"'`
    read with `IFS=$'\x1f' read -r id name meter media`: the first value that
    gives a line (an object, or null), its first line."""
    for v in jq_values(line + "\n"):
        if v is None:
            text = "\x1f\x1f\x1f"
        elif isinstance(v, dict):
            parts = []
            for k in ("id", "name", "meter", "media"):
                x = v.get(k)
                parts.append("" if x is None or x is False else _jq_tostring(x))
            text = "\x1f".join(parts)
        else:
            continue
        fields = _first_line(text).split("\x1f", 3)
        return fields + [""] * (4 - len(fields))
    return ["", "", "", ""]


def tariff_parts(line: str) -> str:
    """status_meter_seen's value_parts: the consumption tariff registers,
    `jq -rc` of [{label, key, value}] sorted by tariff number, "" when none."""
    for v in jq_values(line + "\n"):
        if not isinstance(v, dict):
            continue
        rows = []
        for k, x in v.items():
            m = _TARIFF_CAPTURE.match(k)
            if _is_number(x) and m:
                rows.append((float(m.group(1)), {"label": "T" + m.group(1), "key": k, "value": x}))
        if not rows:
            return ""
        rows.sort(key=lambda r: r[0])  # sort_by is stable
        return jq_dumps([r[1] for r in rows])
    return ""


def meter_value(line: str, media: str, meter: str, prev: Optional[List[str]]) -> Tuple[str, str, str]:
    """status_meter_seen's (value_key, value, value_parts)."""
    parts = tariff_parts(line)
    key, value = _bash_read_tabs(select_primary_meter_value(line), 2)
    if not key:
        def tariffs(v: dict) -> List[str]:
            vals = [float(x) for k, x in v.items() if _is_number(x) and _TARIFF_KWH.search(k)]
            return [f"total_energy_consumption_kwh\t{jq_number_text(sum(vals))}"] if vals else []
        key, value = _bash_read_tabs(_first_object_lines(line, tariffs), 2)
    if key:
        return key, value, parts
    # No cumulative total in this telegram: keep the last one of the meter
    # rather than flicker to the live power; electricity shows no value.
    if prev is not None and prev[0] and _PRIMARY_LIKE.search(prev[0]) and not _PRIMARY_NOT.search(prev[0]):
        return prev[0], prev[1], prev[2]
    electric = "electric" in media.lower() or "energy" in media.lower() or "electric" in meter.lower()
    if not electric:
        for v in jq_values(line + "\n"):
            if isinstance(v, dict):
                electric = any(_ELECTRIC_KEY.search(k) for k in v)
                break
    if electric:
        return "", "", parts
    key = _first_object_lines(line, lambda v: [k for k, x in v.items() if _is_number(x)
                                               and _INSTANT_METER.search(k) and not _INSTANT_NOT.search(k)])
    if key:
        value = ""
        for v in jq_values(line + "\n"):
            if isinstance(v, dict) and v.get(key) not in (None, False):
                value = _jq_raw_text(v[key])
                break
        return key, value, parts
    key, value = _bash_read_tabs(_first_object_lines(
        line, lambda v: [_tsv_cell(k) + "\t" + _jq_tostring(x) for k, x in v.items() if _is_number(x)]), 2)
    return key, value, parts


def _jq_raw_text(x: Any) -> str:
    """One value as `jq -r` prints it."""
    return x if isinstance(x, str) else _jq_pretty(x)


class DecodeBook:
    """run_once's loop over the decode pipeline's output, for one pipeline.

    A decoded telegram: the counters and "Decoded telegram received"
    (status_add_event), status.json, the meter table (status_meter_seen: the
    reception row, the reading, the last JSON, the key problem cleared), the
    line in the log, and its hand-over to the publisher (a DEC frame with the
    meter's exclude patterns), then status.json with Discovery published.
    Any other line: the log, a key problem ("Permanently ignoring telegrams
    from id:"), and - while no meter is configured (--zero) - the LISTEN
    parser of the main instance, in this process (not while SEARCH decodes
    its temporary meters).
    With search_mode, SEARCH (SearchBook) checks every decoded telegram, and
    one of a temporary search_<id> meter goes no further.

    The STATUS_* values start as the pipeline's subshell inherited them
    (--decoded-count etc.), as the bash loop's did. A DEC frame the publisher
    does not take is asked of the bash loop behind ("publish": the
    mosquitto_pub path of publish_decoded_json), as is a SEARCH message
    ("pub": mqtt_pub).
    """

    def __init__(self, a: argparse.Namespace, out=None, err=None) -> None:
        self.a = a
        self.out = out if out is not None else sys.stdout
        self.err = err if err is not None else sys.stderr
        self.decoded = int(a.decoded_count) if re.fullmatch(r"[0-9]+", a.decoded_count or "") else 0
        self.running = a.wmbusmeters_running
        self.last_decoded = a.last_decoded_seen
        self.last_event = a.last_event
        self.disc_pub, self.disc_at = a.discovery_published, a.discovery_published_at
        self.excludes: Dict[str, str] = {}
        for row in (os.environ.get("METER_EXCLUDE_LINES") or "").split("\n"):
            k, sep, v = row.partition("\x1f")
            if sep:
                self.excludes[k] = v
        state = search_state_from_env()
        self.search: Optional[SearchBook] = None
        if a.search_mode == "true":
            self.search = SearchBook(a, state or search_state_from_env({"SEARCH_STATE": ""}),
                                     err=self.err, request=self.request)
        self.listen: Optional["ListenBook"] = None
        if a.zero == "true" and not (state and state["SEARCH_USING_TEMP_METERS"] == "true"):
            la = argparse.Namespace(**vars(a))
            la.official = "zero"
            self.listen = ListenBook(la, out=self.out, err=self.err, search=self.search)
        self.deferred = self.listen.deferred if self.listen else Deferred()
        self.decoder = self.listen.decoder if self.listen else None

    def request(self, *fields: str) -> None:
        try:
            self.out.write("\x1f".join(fields) + "\n")
            self.out.flush()
        except OSError:
            pass

    def echo(self, line: str) -> None:
        print(line, file=self.err, flush=True)

    def line(self, line: str) -> None:
        if line.startswith("{") and '"_":"telegram"' in line:
            self.telegram(line)
            return
        self.echo(line)
        self.key_problem(line)
        if self.listen is not None:
            self.listen.line(line)

    def telegram(self, line: str) -> None:
        self.running = "true"
        self.decoded += 1
        self.last_decoded = iso_now()
        self.add_event("ok", "Decoded telegram received")
        self.write_status()
        if self.search is not None and self.search.telegram(line):
            return
        self.meter_seen(line)
        self.echo(line)
        self.publish(line)

    def add_event(self, level: str, message: str) -> None:
        self.last_event = message
        append_event(self.a.events_file, level, message)

    def write_status(self) -> None:
        """write_status_json from the decode loop's subshell."""
        a = self.a
        raw_count = _digits_or_zero(a.raw_count_file)
        try:
            with open(a.last_raw_file, "rb") as fh:
                last_raw = _s(fh.read()).rstrip("\n")
        except OSError:
            last_raw = ""
        pub, pub_at = self.disc_pub, self.disc_at
        if os.path.isfile(a.discovery_flag_file) and os.path.getsize(a.discovery_flag_file) > 0:
            lines = _read_lines(a.discovery_flag_file)
            pub, pub_at = "true", _s(lines[0]) if lines else ""
        doc = {
            "updated_at": iso_now(),
            "config": {"raw_topic": a.raw_topic, "state_prefix": a.state_prefix,
                       "discovery_prefix": a.discovery_prefix,
                       "search_mode": a.search_mode == "true", "loglevel": a.loglevel},
            "mqtt": {"host": a.mqtt_host, "port": a.mqtt_port, "connected": a.mqtt_connected == "true"},
            "pipeline": {"raw_count": _jq_tonumber(raw_count),
                         "decoded_count": _jq_tonumber(str(self.decoded)),
                         "wmbusmeters_running": self.running == "true",
                         "discovery_published": pub == "true",
                         "discovery_published_at": pub_at,
                         "last_raw_seen": last_raw,
                         "last_decoded_seen": self.last_decoded,
                         "last_error": a.last_error,
                         "last_event": self.last_event},
        }
        _write_replace_tmp(a.status_json_file, _b(_jq_pretty(doc)) + b"\n")

    def meter_seen(self, line: str) -> None:
        """07-meters.sh status_meter_seen."""
        a = self.a
        raw_id, name, meter, media = meter_metadata(line)
        mid = normalize_id(raw_id)
        if not _ID8.fullmatch(mid):
            return
        prev = next((_bash_read_tabs("\t".join(_field(_fields(ln), n) for n in (5, 6, 13)), 3)
                     for ln in _read_lines(a.meters_file) if _first_field(ln) == _b(mid)), None)
        key, value, parts = meter_value(line, media, meter, prev)
        record_seen(a.seen_file, mid, "meter")
        last_seen = iso_now()
        stats = seen_stats(a.seen_file, mid)
        tsv_upsert(a.meters_file, mid, "\t".join(
            [mid, name, meter, media, key, value, last_seen, "published"] + [str(n) for n in stats] + [parts]))
        tsv_upsert(a.meter_last_json_file, mid, f"{mid}\t{last_seen}\t{line}")
        tsv_remove(a.key_problem_file, mid)

    def key_problem(self, line: str) -> None:
        """07-meters.sh status_detect_key_problem."""
        marker = "Permanently ignoring telegrams from id:"
        if marker not in line:
            return
        if "no key to decrypt" in line:
            reason = "key_missing"
        elif "correct decryption key" in line:
            reason = "key_invalid"
        else:
            return
        mid = line.rsplit(marker + " ", 1)[-1] if marker + " " in line else line
        mid = normalize_id(mid.split(" ", 1)[0])
        if not _ID8.fullmatch(mid):
            return
        tsv_upsert(self.a.key_problem_file, mid, f"{mid}\t{reason}\t{iso_now()}")
        print(f"[wmbus-bridge][WARN] key problem for meter {mid}: {reason} (wmbusmeters ignores it until "
              f"the next pipeline reload)", file=self.err, flush=True)

    def publish(self, line: str) -> None:
        """publish_decoded_json's DEC hand-over to the publisher."""
        patterns = ""
        if self.excludes:
            m = _DEC_ID.search(line)
            if m:
                key = normalize_id(m.group(1)).lower()
                if key:
                    patterns = self.excludes.get(key, "")
        payload = _b(patterns + "\n" + line)
        try:
            with socket.create_connection(("127.0.0.1", int(self.a.publisher_port)), timeout=5) as s:
                s.sendall(b"DEC %d\n" % len(payload) + payload + b"\n")
        except (OSError, ValueError):
            # With this pipeline's counters: the bash path ends in
            # write_status_json, whose subshell has only the inherited ones.
            self.request("publish", str(self.decoded), self.last_decoded, self.last_event, line)
            return
        self.disc_pub, self.disc_at = "true", iso_now()
        try:
            _write_replace_tmp(self.a.discovery_flag_file, _b(self.disc_at) + b"\n")
        except OSError:
            pass
        self.write_status()

    def finish(self) -> None:
        if self.listen is not None:
            self.listen.flush()


def _write_replace_tmp(path: str, data: bytes) -> None:
    """`... > path.tmp && mv path.tmp path` (the temporary name bash uses)."""
    with open(path + ".tmp", "wb") as fh:
        fh.write(data)
    os.replace(path + ".tmp", path)


def run_decode(book: DecodeBook, stream=None, err=None) -> None:
    """The decode loop (`while IFS= read -r line`)."""
    stream = stream if stream is not None else sys.stdin.buffer
    err = err if err is not None else sys.stderr
    try:
        for raw in read_lines_flushing(stream, book.deferred, book.decoder):
            if not raw.endswith(b"\n"):  # `read` does not hand over an unterminated last line
                continue
            try:
                book.line(_s(raw[:-1]))
            except Exception as exc:  # one bad line must not stop the pipeline's bookkeeping
                print(f"[wmbus-bridge][WARN] ledger: decoder line skipped: {exc!r}", file=err, flush=True)
        try:
            book.finish()
        except Exception as exc:
            print(f"[wmbus-bridge][WARN] ledger: LISTEN block skipped: {exc!r}", file=err, flush=True)
    except _Terminated:
        raise SystemExit(128 + signal.SIGTERM)
    finally:
        if book.decoder is not None:
            book.decoder.close()
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


# ── storage medium of the data directory ────────────────────────────────────
# Logged once at start, nothing depends on it yet: the per-message tables are
# written every FLUSH_EVERY_S, which a spinning disk feels as ~20 random writes
# a second and an SSD does not. Before anything is tuned by the medium, the log
# has to show that it is told apart correctly on real installs.

_VM_VENDORS = ("QEMU", "KVM", "VMWARE", "VIRTUALBOX", "INNOTEK", "MICROSOFT", "XEN",
               "PARALLELS", "BOCHS", "PROXMOX")


def _sys_read(path: str) -> str:
    try:
        with open(path, "rb") as fh:
            return _s(fh.read()).strip()
    except OSError:
        return ""


def _disk_kind(disk_dir: str, sys_root: str, depth: int = 0) -> Tuple[str, str]:
    """(kind, rotational) of a block device directory in sysfs."""
    disk = os.path.basename(disk_dir)
    rotational = _sys_read(os.path.join(disk_dir, "queue", "rotational"))
    if disk.startswith("mmcblk"):
        card = _sys_read(os.path.join(disk_dir, "device", "type")).upper()
        return ("emmc" if card == "MMC" else "sd"), rotational
    if disk.startswith("nvme"):
        return "nvme", rotational
    slaves_dir = os.path.join(disk_dir, "slaves")
    if depth < 4 and os.path.isdir(slaves_dir):  # md RAID, LVM, dm-crypt
        kinds = []
        for slave in sorted(os.listdir(slaves_dir)):
            real = os.path.realpath(os.path.join(slaves_dir, slave))
            if not os.path.isdir(os.path.join(real, "queue")):
                real = os.path.dirname(real)  # a partition: its disk
            kinds.append(_disk_kind(real, sys_root, depth + 1)[0])
        if kinds:
            for kind in ("hdd", "sd", "emmc", "ssd", "nvme"):
                if kind in kinds:  # the slowest member decides
                    return kind, rotational
    if rotational == "1":
        return "hdd", rotational
    if rotational == "0":
        return "ssd", rotational
    return "unknown", rotational


def storage_medium(path: str, sys_root: str = "/sys", dev: Optional[int] = None) -> Dict[str, str]:
    """What the directory is stored on: kind (nvme, ssd, hdd, emmc, sd, unknown),
    the partition and disk, its rotational flag and model, and the hypervisor
    vendor when the machine is virtual (a virtual disk can claim anything)."""
    out = {"path": path, "kind": "unknown", "partition": "", "disk": "", "rotational": "",
           "model": "", "vm": ""}
    vendor = " ".join(filter(None, (_sys_read(os.path.join(sys_root, "class", "dmi", "id", n))
                                    for n in ("sys_vendor", "product_name"))))
    if any(v in vendor.upper() for v in _VM_VENDORS):
        out["vm"] = vendor
    try:
        st_dev = os.stat(path).st_dev if dev is None else dev
    except OSError as exc:
        out["error"] = f"stat failed: {exc.strerror}"
        return out
    link = os.path.join(sys_root, "dev", "block", f"{os.major(st_dev)}:{os.minor(st_dev)}")
    if not os.path.exists(link):
        out["error"] = f"no {link} (filesystem without a block device)"
        return out
    real = os.path.realpath(link)
    disk_dir = real if os.path.isdir(os.path.join(real, "queue")) else os.path.dirname(real)
    out["partition"], out["disk"] = os.path.basename(real), os.path.basename(disk_dir)
    out["kind"], out["rotational"] = _disk_kind(disk_dir, sys_root)
    out["model"] = _sys_read(os.path.join(disk_dir, "device", "model"))
    return out


def storage_line(info: Dict[str, str]) -> str:
    """The one log line of storage_medium."""
    detail = [f"partition {info['partition'] or '?'}", f"disk {info['disk'] or '?'}",
              f"rotational={info['rotational'] or '?'}"]
    if info.get("model"):
        detail.append(f"model {info['model']}")
    if info.get("vm"):
        detail.append(f"virtual machine: {info['vm']}")
    if info.get("error"):
        detail.append(info["error"])
    return f"storage: {info['path']} on {info['kind']} ({', '.join(detail)})"


# ── runtime directory: the status files in RAM ──────────────────────────────
# Every status_* file is rewritten every few seconds (the per-message tables
# every FLUSH_EVERY_S, the heartbeat every 10 s): ~20 file replacements a
# second on a spinning disk, busy about half the time. In the add-on /tmp is a
# tmpfs, so they live there (RUNTIME_DIR) and are saved to one file in the data
# directory (RUNTIME_SNAPSHOT) every few minutes and at stop, and restored at
# start. Without a tmpfs /tmp the runtime directory is the data directory, as
# before. webui.py picks the same directory by the same rule.

RUNTIME_DIR = "/tmp/wmbus-runtime"
RUNTIME_SNAPSHOT = "runtime_state.tar"
RUNTIME_RESTORED = ".restored"
# status files that stay in the data directory: a user's decision, and the
# error run.sh writes before the bridge starts
RUNTIME_KEEP_ON_DISK = ("status_ignored_candidates.tsv", "status_run_error.txt")


def tmp_is_tmpfs(mounts: str = "/proc/mounts") -> bool:
    try:
        with open(mounts, "rb") as fh:
            for line in fh:
                f = line.split()
                if len(f) >= 3 and f[1] == b"/tmp":
                    return f[2] == b"tmpfs"
    except OSError:
        pass
    return False


def runtime_dir(base: str, env: Optional[Dict[str, str]] = None, mounts: str = "/proc/mounts") -> str:
    """WMBUS_RUNTIME when set; for the add-on's /data, RUNTIME_DIR on a tmpfs
    /tmp; else the data directory (a custom WMBUS_BASE: tests, development)."""
    env = os.environ if env is None else env
    if env.get("WMBUS_RUNTIME"):
        return env["WMBUS_RUNTIME"]
    if os.path.normpath(base) == "/data" and tmp_is_tmpfs(mounts):
        return RUNTIME_DIR
    return base


def _runtime_names(directory: str) -> List[str]:
    """The state files of a directory: regular files, not locks or temporaries."""
    out = []
    for name in sorted(os.listdir(directory)):
        path = os.path.join(directory, name)
        if (not os.path.isfile(path) or os.path.islink(path) or name.endswith(".lock")
                or ".tmp." in name or name.endswith(".tmp") or name == RUNTIME_RESTORED):
            continue
        out.append(name)
    return out


def _moved_to_runtime(name: str) -> bool:
    return (name == "status.json" or name.startswith("status_")) and name not in RUNTIME_KEEP_ON_DISK


def _extract_snapshot(snapshot: str, target: str) -> int:
    """The plain files of the snapshot, by bare name only, into target."""
    count = 0
    with tarfile.open(snapshot, "r") as tar:
        for member in tar.getmembers():
            name = member.name
            if name.startswith("./"):
                name = name[2:]
            if not member.isfile() or not name or "/" in name or name in (".", ".."):
                continue
            src = tar.extractfile(member)
            if src is None:
                continue
            _write_replace(os.path.join(target, name), src.read())
            count += 1
    return count


def runtime_restore(base: str, runtime: str) -> str:
    """Fill the runtime directory at start; what was done, for the log."""
    snapshot = os.path.join(base, RUNTIME_SNAPSHOT)
    if os.path.realpath(runtime) == os.path.realpath(base):
        if os.path.isfile(snapshot):
            # The last run kept its state in RAM; this one has no tmpfs.
            n = _extract_snapshot(snapshot, base)
            os.unlink(snapshot)
            return f"runtime: {base} (no tmpfs), {n} file(s) restored from {RUNTIME_SNAPSHOT}"
        return f"runtime: {base} (no tmpfs /tmp, status files on the data disk)"
    os.makedirs(runtime, exist_ok=True)
    marker = os.path.join(runtime, RUNTIME_RESTORED)
    if os.path.exists(marker):
        return f"runtime: {runtime} (RAM), kept from the running container"
    if os.path.isfile(snapshot):
        n = _extract_snapshot(snapshot, runtime)
        how = f"{n} file(s) restored from {base}/{RUNTIME_SNAPSHOT}"
    else:
        moved = [name for name in _runtime_names(base) if _moved_to_runtime(name)]
        for name in moved:
            shutil.copy2(os.path.join(base, name), os.path.join(runtime, name))
        if moved:
            # Saved at once, then the old copies go: the state must not depend
            # on the first periodic snapshot, and stale copies must not stay.
            runtime_snapshot(base, runtime)
            for name in moved:
                try:
                    os.unlink(os.path.join(base, name))
                except OSError:
                    pass
        how = f"{len(moved)} file(s) moved from {base} (first start with a RAM directory)"
    open(marker, "wb").close()
    return f"runtime: {runtime} (RAM), {how}"


def runtime_snapshot(base: str, runtime: str) -> int:
    """Save the runtime directory as one file in the data directory; its size."""
    if os.path.realpath(runtime) == os.path.realpath(base) or not os.path.isdir(runtime):
        return 0
    fd, tmp = tempfile.mkstemp(prefix=RUNTIME_SNAPSHOT + ".tmp.", dir=base)
    try:
        with os.fdopen(fd, "wb") as fh, tarfile.open(fileobj=fh, mode="w") as tar:
            for name in _runtime_names(runtime):
                try:
                    tar.add(os.path.join(runtime, name), arcname=name, recursive=False)
                except (FileNotFoundError, tarfile.TarError):
                    continue  # replaced or removed while the snapshot ran
        os.replace(tmp, os.path.join(base, RUNTIME_SNAPSHOT))
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    return os.path.getsize(os.path.join(base, RUNTIME_SNAPSHOT))


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
    # With it (and --preview-state-file) a new or changed Diehl/SAP candidate
    # is registered here (RawBook.candidate); without, it is asked of bash.
    raw.add_argument("--preview-attempts-dir", default="")
    # With these two the preview one-shot runs here (PreviewDecoder); without,
    # it is asked of bash ("preview" request).
    raw.add_argument("--preview-oneshot-runtime", default="")
    raw.add_argument("--candidate-values-file", default="")
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
    # With these three a new or changed candidate is registered here
    # (ListenBook.snippet); without, it is asked of the bash loop as before.
    for name in ("events-file", "preview-state-file", "preview-attempts-dir", "candidate-values-file",
                 "preview-oneshot-runtime"):
        listen.add_argument(f"--{name}", default="")
    dec = modes.add_parser("decode", help="output of the decode pipeline's wmbusmeters (run_once)")
    for name in ("status-json", "raw-count", "last-raw", "discovery-flag", "events", "meters",
                 "meter-last-json", "key-problem", "seen"):
        dec.add_argument(f"--{name}-file", required=True)
    dec.add_argument("--publisher-port", required=True)
    dec.add_argument("--zero", choices=("true", "false"), default="false",
                     help="hand the other lines to the main instance's LISTEN parser (no meter configured)")
    # The STATUS_* values and settings the pipeline's subshell inherits.
    for name in ("raw-topic", "state-prefix", "discovery-prefix", "search-mode", "loglevel", "mqtt-host",
                 "mqtt-port", "mqtt-connected", "wmbusmeters-running", "decoded-count", "last-decoded-seen",
                 "last-error", "last-event", "discovery-published", "discovery-published-at"):
        dec.add_argument(f"--{name}", default="")
    # The LISTEN parser's files (--zero true).
    for name in ("candidates", "recent-raw", "candidate-raw", "candidate-analysis", "snippet",
                 "official-count", "preview-state", "candidate-values"):
        dec.add_argument(f"--{name}-file", default="")
    for name in ("meter-dir", "preview-meter-dir", "official-count-default", "search-expected",
                 "preview-attempts-dir", "preview-oneshot-runtime"):
        dec.add_argument(f"--{name}", default="")
    rx = modes.add_parser("rx", help="wmbus/<board>/rx messages")
    for name in ("reception", "mode", "history", "sequence", "boots", "clock"):
        rx.add_argument(f"--{name}-file", required=True)
    rt = modes.add_parser("runtime", help="print the runtime directory for the status files")
    rt.add_argument("--base", required=True)
    for name, text in (("runtime-restore", "fill the runtime directory at start"),
                       ("runtime-snapshot", "save the runtime directory to the data directory")):
        sub = modes.add_parser(name, help=text)
        sub.add_argument("--base", required=True)
        sub.add_argument("--runtime", required=True)
    storage = modes.add_parser("storage", help="print the storage medium of a directory")
    storage.add_argument("--path", required=True)
    storage.add_argument("--sys-root", default="/sys")
    storage.add_argument("--json-file", default="",
                         help="also write the result as JSON (for the WebUI)")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    try:
        args = _parser().parse_args(argv)
    except SystemExit as exc:  # usage errors: report, never raise out of main
        return int(exc.code or 0)
    if args.mode in ("raw", "tracker", "rx", "listen", "decode"):
        # Stopping the add-on: write what is collected, then exit.
        signal.signal(signal.SIGTERM, _on_sigterm)
    if args.mode == "rssi":
        run(RssiBook(args.meter_dir, args.rssi_file))
    elif args.mode == "raw":
        run_lines(RawBook(args))
    elif args.mode == "listen":
        run_listen(ListenBook(args))
    elif args.mode == "decode":
        run_decode(DecodeBook(args))
    elif args.mode == "tracker":
        run(TrackerBook(args.dev_pos, args.devices_file, args.meter_device_file,
                        args.reception_file, args.history_file))
    elif args.mode == "rx":
        run(RxBook(args.reception_file, args.mode_file, args.history_file,
                   args.sequence_file, args.boots_file, args.clock_file))
    elif args.mode == "runtime":
        print(runtime_dir(args.base))
    elif args.mode == "runtime-restore":
        print(runtime_restore(args.base, args.runtime))
    elif args.mode == "runtime-snapshot":
        runtime_snapshot(args.base, args.runtime)
    elif args.mode == "storage":
        info = storage_medium(args.path, args.sys_root)
        if args.json_file:
            _write_replace(args.json_file, _b(json.dumps(info, sort_keys=True)) + b"\n")
        print(storage_line(info))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Manufacturer formats wmbusmeters cannot read, described by data files.

Some meters send their values in a manufacturer block (CI 0x78, payload
starting with 0x0F) hidden by a simple obfuscation: a few additions and XORs
per 16-bit word, keyed by a byte of the frame and by the meter ID. wmbusmeters
has no driver for them, and an .xmq driver cannot help: it reads DIF/VIF
records, which these frames do not have.

One engine here, one JSON file per format (FORMATS_DIR). A file says which
frames it matches, how a word is de-obfuscated (a list of add/sub/xor steps
with constants, tables indexed by a frame byte and variables from the meter
ID), where the fields are, and which telegrams with which values it must
decode (its tests). A new format of the same kind is a new file, no code.

What the engine cannot do: real encryption with an unknown key, bit-packed or
variable-length records, operations outside add/sub/xor. Those need code.

wmbusmeters may learn a format later. Each file carries a probe telegram with
known values; `upstream` feeds it to the installed wmbusmeters and, when that
already returns those values, the format is marked as handled upstream with
the driver wmbusmeters picked. wmbus_meters.py then writes such a meter as an
ordinary wmbusmeters meter and this engine leaves it alone.

A meter uses a format through its driver name: vendor_<format name>
(type: other, type_other: vendor_bmeters_hydroclima_v34).

CLI:
  vendor_formats.py check   [--formats-dir D]           -> run every file's tests
  vendor_formats.py upstream --status FILE [--formats-dir D] [--wmbusmeters BIN]
  vendor_formats.py stage   --meter-dir DIR [--status FILE] [--formats-dir D]
                            stdin: RAW hex lines; stdout: wmbusmeters-like JSON
"""

from __future__ import annotations

import argparse
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

PREFIX = "vendor_"
FORMATS_DIR = os.environ.get("VENDOR_FORMATS_DIR", "/usr/share/wmbus-bridge/formats")
SCHEMA = 1
MASK = {8: 0xFF, 16: 0xFFFF}


class FormatError(ValueError):
    pass


# ---------------------------------------------------------------- expressions
# Variables computed from the meter ID: integers (decimal or 0x hex), id0..id3
# (the four address bytes as sent, least significant first), + - ^ & | << >>
# and parentheses. No names, calls or attributes: never eval().

_TOK = re.compile(r"\s*(?:(0x[0-9A-Fa-f]+|\d+)|(id[0-3])|(<<|>>|[-+^&|()]))")
_PREC = {"|": 1, "^": 2, "&": 3, "<<": 4, ">>": 4, "+": 5, "-": 5}


def _tokens(expr: str) -> List[Tuple[str, str]]:
    out, pos = [], 0
    expr = expr.rstrip()
    while pos < len(expr):
        m = _TOK.match(expr, pos)
        if not m:
            raise FormatError(f"bad expression near {expr[pos:pos + 8]!r}")
        num, name, op = m.groups()
        out.append(("n", num) if num else ("v", name) if name else ("o", op))
        pos = m.end()
    return out


def compile_expr(expr: str):
    """Return f(ids) for an expression; raises FormatError on bad syntax."""
    toks = _tokens(str(expr))
    pos = 0

    def atom():
        nonlocal pos
        if pos >= len(toks):
            raise FormatError(f"expression ends early: {expr!r}")
        kind, val = toks[pos]
        pos += 1
        if kind == "n":
            v = int(val, 0)
            return lambda ids: v
        if kind == "v":
            i = int(val[2])
            return lambda ids: ids[i]
        if val == "(":
            f = binary(0)
            if pos >= len(toks) or toks[pos] != ("o", ")"):
                raise FormatError(f"missing ')' in {expr!r}")
            pos += 1
            return f
        raise FormatError(f"unexpected {val!r} in {expr!r}")

    def binary(min_prec):
        nonlocal pos
        left = atom()
        while pos < len(toks) and toks[pos][0] == "o" and toks[pos][1] in _PREC \
                and _PREC[toks[pos][1]] > min_prec:
            op = toks[pos][1]
            pos += 1
            right = binary(_PREC[op])
            left = _bin(op, left, right)
        return left

    f = binary(0)
    if pos != len(toks):
        raise FormatError(f"trailing tokens in {expr!r}")
    return f


def _bin(op, a, b):
    if op == "+":
        return lambda ids: a(ids) + b(ids)
    if op == "-":
        return lambda ids: a(ids) - b(ids)
    if op == "^":
        return lambda ids: a(ids) ^ b(ids)
    if op == "&":
        return lambda ids: a(ids) & b(ids)
    if op == "|":
        return lambda ids: a(ids) | b(ids)
    if op == "<<":
        return lambda ids: a(ids) << b(ids)
    return lambda ids: a(ids) >> b(ids)


def _int(v: Any, what: str) -> int:
    try:
        return int(v, 0) if isinstance(v, str) else int(v)
    except (TypeError, ValueError):
        raise FormatError(f"{what}: not an integer: {v!r}") from None


def _hexbytes(v: Any, what: str) -> bytes:
    s = str(v or "").replace(" ", "")
    if not re.fullmatch(r"(?:[0-9A-Fa-f]{2})*", s):
        raise FormatError(f"{what}: not hex: {v!r}")
    return bytes.fromhex(s)


# -------------------------------------------------------------------- formats

class Format:
    """One format file, validated and compiled."""

    def __init__(self, spec: Dict[str, Any], path: str = ""):
        self.path = path
        if not isinstance(spec, dict) or spec.get("schema") != SCHEMA:
            raise FormatError(f"schema must be {SCHEMA}")
        self.name = str(spec.get("name") or "")
        if not re.fullmatch(r"[a-z0-9_]{1,40}", self.name):
            raise FormatError(f"bad name {self.name!r}")
        self.driver = PREFIX + self.name
        self.title = str(spec.get("title") or self.name)
        self.media = str(spec.get("media") or "")
        m = spec.get("match") or {}
        self.m_mfct = _hexbytes(m.get("mfct_bytes"), "match.mfct_bytes")
        self.m_version = _hexbytes(m.get("version"), "match.version")
        self.m_type = _hexbytes(m.get("type"), "match.type")
        self.m_ci = _hexbytes(m.get("ci"), "match.ci")
        self.m_prefix = _hexbytes(m.get("payload_prefix", ""), "match.payload_prefix")
        if len(self.m_mfct) != 2 or len(self.m_version) != 1 or len(self.m_type) != 1 or len(self.m_ci) != 1:
            raise FormatError("match: mfct_bytes is 2 bytes, version/type/ci 1 byte each")
        self.frame_type_byte = _int(spec.get("frame_type_byte", 2), "frame_type_byte")
        seed = spec.get("seed") or {}
        self.seed_byte = _int(seed.get("byte", 1), "seed.byte")
        self.seed_mask = _int(seed.get("mask", 0xFF), "seed.mask")
        w = spec.get("word") or {}
        self.bits = _int(w.get("bits", 16), "word.bits")
        if self.bits not in MASK:
            raise FormatError("word.bits must be 8 or 16")
        self.mask = MASK[self.bits]
        self.little = (w.get("endian", "little") == "little")
        self.tables = {}
        for tname, vals in (spec.get("tables") or {}).items():
            if not isinstance(vals, list) or not vals:
                raise FormatError(f"table {tname}: empty")
            self.tables[tname] = [_int(v, f"table {tname}") & self.mask for v in vals]
        self.vars_expr = {}
        self.vars_solve = {}
        for vname, vdef in (spec.get("vars") or {}).items():
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", vname):
                raise FormatError(f"bad variable name {vname!r}")
            if "expr" in vdef:
                self.vars_expr[vname] = compile_expr(vdef["expr"])
            elif "solve" in vdef:
                s = vdef["solve"]
                words = {k.lower(): _int(v, f"vars.{vname}.solve.word") for k, v in (s.get("word") or {}).items()}
                self.vars_solve[vname] = (words, _int(s.get("plain"), f"vars.{vname}.solve.plain") & self.mask)
            else:
                raise FormatError(f"variable {vname}: needs expr or solve")
        self.steps = []
        for i, st in enumerate(spec.get("transform") or []):
            op = st.get("op")
            if op not in ("add", "sub", "xor"):
                raise FormatError(f"transform[{i}]: op must be add, sub or xor")
            if "const" in st:
                src = ("const", _int(st["const"], f"transform[{i}].const") & self.mask)
            elif "var" in st:
                if st["var"] not in self.vars_expr and st["var"] not in self.vars_solve:
                    raise FormatError(f"transform[{i}]: unknown variable {st['var']}")
                src = ("var", st["var"])
            elif "table" in st:
                if st["table"] not in self.tables:
                    raise FormatError(f"transform[{i}]: unknown table {st['table']}")
                if st.get("index", "seed") != "seed":
                    raise FormatError(f"transform[{i}]: tables are indexed by the seed")
                src = ("table", st["table"])
            else:
                raise FormatError(f"transform[{i}]: needs const, var or table")
            self.steps.append((op, src))
        if not self.steps:
            raise FormatError("transform is empty")
        # A solved variable is found from a word whose plain value is known:
        # only possible when it is used once, in the last step.
        for vname in self.vars_solve:
            uses = [i for i, (_, src) in enumerate(self.steps) if src == ("var", vname)]
            if uses != [len(self.steps) - 1]:
                raise FormatError(f"variable {vname}: a solved variable must be used once, in the last step")
        self.frames = {}
        for ftype, fdef in (spec.get("frames") or {}).items():
            fields = []
            for f in fdef.get("fields") or []:
                fname = str(f.get("name") or "")
                if not re.fullmatch(r"[a-z][a-z0-9_]*", fname):
                    raise FormatError(f"frame {ftype}: bad field name {fname!r}")
                fields.append((fname, _int(f.get("offset"), f"{fname}.offset"),
                               float(f.get("scale", 1)), bool(f.get("signed", False))))
            self.frames[ftype.lower()] = {"min_len": _int(fdef.get("min_len", 0), f"frame {ftype}.min_len"),
                                          "fields": fields}
        if not self.frames:
            raise FormatError("no frames")
        self.tests = spec.get("tests") or []
        if not self.tests:
            raise FormatError("a format must carry at least one test telegram")
        self.upstream_probe = spec.get("upstream_probe") or {}

    # ------------------------------------------------------------ decoding
    def matches(self, raw: bytes) -> bool:
        return (len(raw) >= 12 and raw[2:4] == self.m_mfct and raw[8:9] == self.m_version
                and raw[9:10] == self.m_type and raw[10:11] == self.m_ci
                and raw[11:11 + len(self.m_prefix)] == self.m_prefix)

    def _word(self, p: bytes, off: int) -> Optional[int]:
        n = self.bits // 8
        if off < 0 or off + n > len(p):
            return None
        b = p[off:off + n]
        return int.from_bytes(b, "little" if self.little else "big")

    def _value(self, src, seed: int, env: Dict[str, int]) -> int:
        kind, v = src
        if kind == "const":
            return v
        if kind == "var":
            return env[v] & self.mask
        t = self.tables[v]
        return t[seed % len(t)]

    def _encode_upto(self, plain: int, seed: int, env: Dict[str, int], upto: int) -> int:
        x = plain
        for op, src in self.steps[:upto]:
            k = self._value(src, seed, env)
            x = (x + k) & self.mask if op == "add" else (x - k) & self.mask if op == "sub" else x ^ k
        return x

    def decode_word(self, c: int, seed: int, env: Dict[str, int]) -> int:
        x = c
        for op, src in reversed(self.steps):
            k = self._value(src, seed, env)
            x = (x - k) & self.mask if op == "add" else (x + k) & self.mask if op == "sub" else x ^ k
        return x

    def decode(self, raw: bytes, cache: Dict[str, int]) -> Optional[Tuple[str, Dict[str, Any]]]:
        """(meter id, fields) of one frame, or None. cache keeps solved variables per meter."""
        if not self.matches(raw):
            return None
        p = raw[11:]
        if self.frame_type_byte >= len(p) or self.seed_byte >= len(p):
            return None
        ftype = "%02x" % p[self.frame_type_byte]
        frame = self.frames.get(ftype)
        if frame is None or len(p) < frame["min_len"]:
            return None
        ids = list(raw[4:8])
        mid = "".join("%02X" % b for b in reversed(raw[4:8]))
        seed = p[self.seed_byte] & self.seed_mask
        env = {k: f(ids) & self.mask for k, f in self.vars_expr.items()}
        last = len(self.steps) - 1
        for vname, (words, plain) in self.vars_solve.items():
            off = words.get(ftype)
            c = self._word(p, off) if off is not None else None
            if c is not None:
                op = self.steps[last][0]
                part = self._encode_upto(plain, seed, env, last)
                val = (c - part) & self.mask if op == "add" else (part - c) & self.mask if op == "sub" else c ^ part
                cache[f"{mid}:{vname}"] = val
            if f"{mid}:{vname}" not in cache:
                return None   # e.g. a short frame before any long frame of this meter
            env[vname] = cache[f"{mid}:{vname}"]
        out: Dict[str, Any] = {}
        for fname, off, scale, signed in frame["fields"]:
            c = self._word(p, off)
            if c is None:
                continue
            v = self.decode_word(c, seed, env)
            if signed and v & (1 << (self.bits - 1)):
                v -= 1 << self.bits
            out[fname] = round(v * scale, 6)
        return mid, out


def load_formats(directory: str = "", errors: Optional[List[Tuple[str, str]]] = None) -> List[Format]:
    out = []
    for path in sorted(glob.glob(os.path.join(directory or FORMATS_DIR, "*.json"))):
        try:
            with open(path, encoding="utf-8") as fh:
                out.append(Format(json.load(fh), path))
        except (OSError, ValueError) as exc:
            if errors is not None:
                errors.append((os.path.basename(path), str(exc)))
    return out


def run_tests(fmt: Format) -> List[str]:
    """The failures of a format's own tests (empty list: all pass)."""
    fails = []
    for i, t in enumerate(fmt.tests):
        cache: Dict[str, int] = {}
        try:
            for ctx in t.get("context") or []:
                fmt.decode(_hexbytes(ctx, "context"), cache)
            res = fmt.decode(_hexbytes(t.get("telegram"), "telegram"), cache)
        except FormatError as exc:
            fails.append(f"test {i}: {exc}")
            continue
        if res is None:
            fails.append(f"test {i}: telegram not decoded")
            continue
        mid, fields = res
        exp = dict(t.get("expect") or {})
        want_id = exp.pop("id", None)
        if want_id is not None and want_id != mid:
            fails.append(f"test {i}: id {mid} != {want_id}")
        for k, v in exp.items():
            got = fields.get(k)
            if got is None or abs(float(got) - float(v)) > 1e-6:
                fails.append(f"test {i}: {k}={got} != {v}")
    return fails


# ------------------------------------------------------------------- upstream

def _numbers(obj: Dict[str, Any]) -> List[float]:
    return [float(v) for v in obj.values() if isinstance(v, (int, float)) and not isinstance(v, bool)]


def probe_upstream(fmt: Format, wmbusmeters: str, timeout: int = 15) -> str:
    """The wmbusmeters driver that already decodes the probe with its values, or ""."""
    probe = fmt.upstream_probe
    raw = str(probe.get("telegram") or "")
    values = [float(v) for v in probe.get("values") or []]
    if not raw or not values or not re.fullmatch(r"[0-9A-Fa-f]+", raw):
        return ""
    mid = "".join("%02x" % b for b in reversed(bytes.fromhex(raw)[4:8]))
    try:
        proc = subprocess.run([wmbusmeters, "--silent", "--format=json", "stdin:hex", "probe", "auto", mid, "NOKEY"],
                              input=raw + "\n", capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    for line in (proc.stdout or "").splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if not isinstance(obj, dict) or obj.get("_") != "telegram":
            continue
        nums = _numbers(obj)
        if all(any(abs(n - v) < 1e-6 for n in nums) for v in values):
            return str(obj.get("driver") or obj.get("meter") or "")
    return ""


def cmd_upstream(a) -> int:
    errors: List[Tuple[str, str]] = []
    formats = load_formats(a.formats_dir, errors)
    rows = [{"file": f, "name": "", "ok": False, "reason": r, "upstream_driver": ""} for f, r in errors]
    for fmt in formats:
        fails = run_tests(fmt)
        drv = probe_upstream(fmt, a.wmbusmeters) if not fails else ""
        rows.append({"file": os.path.basename(fmt.path), "name": fmt.name, "driver": fmt.driver,
                     "title": fmt.title, "ok": not fails, "reason": "; ".join(fails),
                     "upstream_driver": drv})
        if drv:
            print(f"vendor format {fmt.name}: wmbusmeters already decodes it (driver {drv}), "
                  f"own decoder not used", file=sys.stderr)
        elif fails:
            print(f"vendor format {fmt.name}: own tests failed -> not used ({'; '.join(fails)})", file=sys.stderr)
    status = {"checked_at": int(time.time()), "formats": rows}
    tmp = a.status + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(status, fh)
    os.replace(tmp, a.status)
    return 0


def read_status(path: str) -> Dict[str, Dict[str, Any]]:
    """name -> status row; {} when the file is missing or broken."""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return {r["name"]: r for r in data.get("formats", []) if isinstance(r, dict) and r.get("name")}
    except (OSError, ValueError, AttributeError, TypeError):
        return {}


def route(driver: str, status: Dict[str, Dict[str, Any]], formats_dir: str = "") -> Tuple[str, str]:
    """Where a meter on vendor_<name> goes, for wmbus_meters.py:
    ("vendor", "") this engine decodes it; ("upstream", drv) wmbusmeters
    already knows the format, write an ordinary meter with drv; ("skip", why)."""
    name = driver[len(PREFIX):]
    row = status.get(name)
    if row is None:
        # No status (the check did not run): trust a file that exists.
        known = any(f.name == name for f in load_formats(formats_dir))
        return ("vendor", "") if known else ("skip", "no such vendor format")
    if row.get("upstream_driver"):
        return "upstream", str(row["upstream_driver"])
    if not row.get("ok"):
        return "skip", f"the format failed its own tests ({row.get('reason', '')})"
    return "vendor", ""


# ---------------------------------------------------------------------- stage

def _now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_meters(meter_dir: str) -> Dict[str, Tuple[str, str]]:
    """id (upper) -> (name, driver) from the meter-* files wmbus_meters.py
    writes to VENDOR_METER_DIR (the same name=/id=/driver= lines as for
    wmbusmeters, so the ledger counts them as configured meters)."""
    out = {}
    for path in sorted(glob.glob(os.path.join(meter_dir, "meter-*"))):
        kv = {}
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    k, sep, v = line.rstrip("\n").partition("=")
                    if sep:
                        kv.setdefault(k, v)
        except OSError:
            continue
        mid = kv.get("id", "")
        if re.fullmatch(r"[0-9A-Fa-f]{8}", mid) and kv.get("driver", "").startswith(PREFIX):
            out[mid.upper()] = (kv.get("name", mid), kv["driver"])
    return out


def cmd_stage(a) -> int:
    """Never exits while stdin is open: it sits on a tee of the decode pipeline,
    and a dead reader would take the whole pipeline down with SIGPIPE."""
    try:
        meters = read_meters(a.meter_dir)
        status = read_status(a.status) if a.status else {}
        formats = {}
        for fmt in load_formats(a.formats_dir):
            row = status.get(fmt.name)
            if row is not None and (not row.get("ok") or row.get("upstream_driver")):
                continue
            formats[fmt.driver] = fmt
        wanted = {d for _, d in meters.values()}
        active = [f for d, f in formats.items() if d in wanted]
    except Exception as exc:  # noqa: BLE001 - keep reading whatever happened
        print(f"vendor formats: disabled ({exc})", file=sys.stderr)
        active = []
    cache: Dict[str, int] = {}
    last: Dict[str, Dict[str, Any]] = {}
    for line in sys.stdin:
        if not active:
            continue
        try:
            s = re.sub(r"\s+", "", line)
            if s[:2].lower() == "0x":
                s = s[2:]
            if not s or len(s) % 2 or not re.fullmatch(r"[0-9A-Fa-f]+", s):
                continue
            raw = bytes.fromhex(s)
            for fmt in active:
                res = fmt.decode(raw, cache)
                if res is None:
                    continue
                mid, fields = res
                meter = meters.get(mid)
                if meter is None or meter[1] != fmt.driver:
                    break
                # Long and short frames carry different fields: keep the last
                # value of each, as wmbusmeters does, so every state is whole.
                merged = last.setdefault(mid, {})
                merged.update(fields)
                obj = {"_": "telegram", "media": fmt.media, "meter": fmt.driver, "driver": fmt.driver,
                       "name": meter[0], "id": mid}
                obj.update(merged)
                obj["timestamp"] = _now_iso()
                sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
                sys.stdout.flush()
                break
        except Exception as exc:  # noqa: BLE001
            print(f"vendor formats: frame skipped ({exc})", file=sys.stderr)
    return 0


def cmd_check(a) -> int:
    errors: List[Tuple[str, str]] = []
    formats = load_formats(a.formats_dir, errors)
    bad = len(errors)
    for f, r in errors:
        print(f"FAIL {f}: {r}")
    for fmt in formats:
        fails = run_tests(fmt)
        print(("FAIL " if fails else "ok   ") + f"{os.path.basename(fmt.path)} ({fmt.driver}, {len(fmt.tests)} tests)"
              + ("".join("\n     " + x for x in fails)))
        bad += bool(fails)
    return 1 if bad else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    c = sub.add_parser("check")
    c.add_argument("--formats-dir", default="")
    u = sub.add_parser("upstream")
    u.add_argument("--status", required=True)
    u.add_argument("--formats-dir", default="")
    u.add_argument("--wmbusmeters", default=os.environ.get("WMBUSMETERS_BIN", "/usr/bin/wmbusmeters"))
    s = sub.add_parser("stage")
    s.add_argument("--meter-dir", required=True)
    s.add_argument("--status", default="")
    s.add_argument("--formats-dir", default="")
    a = ap.parse_args(argv)
    return {"check": cmd_check, "upstream": cmd_upstream, "stage": cmd_stage}[a.mode](a)


if __name__ == "__main__":
    sys.exit(main())

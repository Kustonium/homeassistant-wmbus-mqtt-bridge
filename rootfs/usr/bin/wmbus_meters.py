#!/usr/bin/env python3
"""The radio path's meter files, written in one process (07-meters.sh, 06-candidates.sh).

`refresh` replaces refresh_meter_files: the meter-NNNN files of the decode
pipeline's wmbusmeters, from options.json meters[] (or, in SEARCH, the
temporary search_<id> meters of the candidate cache), with the same files,
warnings and log lines, instead of about ten jq runs per meter.

`housekeeping` replaces prune_stale_candidates and
expire_stale_pending_previews, which the heartbeat ticker runs every
CANDIDATE_PRUNE_INTERVAL_SECONDS: candidate rows silent for longer than
--prune-after are removed with their preview value, state, attempt counter
and preview config, then preview states stuck in "pending" for longer than
--pending-timeout become "no_decode_result".

`previews` replaces sync_candidate_autodecode_files (a preview config per
registered candidate, ensure_candidate_autodecode with reload=false) and
prune_official_meter_previews (none for an id that is now a configured
meter), run one after the other on every pipeline start.

What bash keeps in shell variables, or still runs itself, comes back on
stdout, one line each, fields separated by 0x1F (which `read` keeps, so
empty fields survive; a newline in a value travels as 0x1E):
- refresh: "set VAR VALUE" (OFFICIAL_METERS_COUNT, and SEARCH_USING_TEMP_METERS
  and SEARCH_TEMP_METERS_LOADED when SEARCH loads its meters; the shell resets
  the count, the mode and the patterns first), "exclude ID PATTERNS" (METER_EXCLUDE_FIELDS),
  "search PHASE REASON" (write_search_status, which reads the SEARCH
  counters of the shell) and last "rc 0";
- previews: "preview RAW ID" (preview_decode_raw_if_requested for a preview
  config just written) and last "rc 0".
Logs and warnings go to stderr.
"""

from __future__ import annotations

import argparse
import datetime
import glob
import os
import re
import sys
import tempfile
from typing import Any, Dict, List

import bridge_ledger as bl
from wmbus_mbus import field_spec_lines

SEP = "\x1f"
NEWLINE = "\x1e"


_JQ_TYPE = ((bool, "boolean"), (str, "string"), (list, "array"))


def jq_r_alt(obj: Any, key: str, default: str, err=None) -> str:
    """`$(echo "$json" | jq -r '.key // default')` for one value of `jq -c '.meters[]'`
    (`// empty`: default ""). A value that cannot be indexed is a jq error on
    stderr, and nothing printed. The command substitution drops trailing newlines."""
    if obj is None:
        return default
    if not isinstance(obj, dict):
        kind = next((name for t, name in _JQ_TYPE if isinstance(obj, t)), "number")
        print(f'jq: error (at <stdin>:1): Cannot index {kind} with string "{key}"',
              file=err if err is not None else sys.stderr, flush=True)
        return ""
    v = obj.get(key)
    if v is None or v is False:
        return default
    return (v if isinstance(v, str) else bl._jq_pretty(v)).rstrip("\n")


def _bash_lines(path: str) -> List[str]:
    """The lines `while read` hands over: an unterminated last line is not."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return []
    lines = data.split(b"\n")
    lines.pop()  # "" after the final newline, or the unterminated last line
    return [bl._s(ln) for ln in lines]


def _jq_length(x: Any) -> Any:
    """jq's length; None when jq fails (a boolean)."""
    if x is None:
        return 0
    if x is True or x is False:
        return None
    if isinstance(x, (str, list, dict)):
        return len(x)
    return abs(x)  # a number


class Tool:
    def __init__(self, a: argparse.Namespace, out=None, err=None) -> None:
        self.a = a
        self.out = out if out is not None else sys.stdout
        self.err = err if err is not None else sys.stderr

    def emit(self, *fields: str) -> None:
        self.out.write(SEP.join(f.replace("\n", NEWLINE) for f in fields) + "\n")
        self.out.flush()

    def warn(self, msg: str) -> None:
        print(f"[wmbus-bridge][WARN] {msg}", file=self.err, flush=True)

    def log(self, level: str, msg: str) -> None:
        """log, log_verbose and log_debug, on stderr: stdout carries the values for bash."""
        ll = self.a.loglevel
        if level == "info" or ll == "debug" or (level == "verbose" and ll == "verbose"):
            print(f"[wmbus-bridge] {msg}", file=self.err, flush=True)


class MeterFiles(Tool):
    """refresh_meter_files."""

    def options(self) -> Any:
        try:
            with open(self.a.options, "rb") as fh:
                values = bl.jq_values(bl._s(fh.read()))
        except OSError:
            return None
        return values[0] if values else None

    def run(self) -> int:
        a = self.a
        for path in glob.glob(os.path.join(a.meter_dir, "meter-*")):
            try:
                os.unlink(path)
            except OSError:
                pass
        opts = self.options() if os.path.isfile(a.options) else None
        meters = opts.get("meters") if isinstance(opts, dict) else None
        configured = 0
        if isinstance(opts, dict) and meters is not None and meters is not False:
            n = _jq_length(meters)
            if n is not None and n > 0:
                configured = n
        count = 0
        if configured == 0 and a.search_mode == "true" and a.search_expected != "0":
            cached = self.search_meters()
            if cached is not None and cached > 0:
                self.emit("set", "SEARCH_USING_TEMP_METERS", "true")
                self.emit("set", "SEARCH_TEMP_METERS_LOADED", str(cached))
                self.warn(f"No user meters configured -> SEARCH MODE (temporary cached candidates={cached}, "
                          f"expected={a.search_expected} m3, tolerance={a.search_tolerance} m3).")
                self.warn(f"SEARCH MODE uses cached candidates from {a.search_candidates_file}. Remove that "
                          "file or disable search_mode to return to pure LISTEN MODE.")
                self.emit("search", "search", "loaded_temp_meters")
            else:
                self.warn("No meters configured -> SEARCH DISCOVERY MODE.")
                self.warn("SEARCH MODE needs decoded JSON values, but there are no cached candidates yet.")
                self.warn("The bridge will collect id+driver candidates first. Let it run long enough to hear "
                          "meters; restart later to decode cached candidates and compare m3 values.")
                self.emit("search", "collecting", "no_cached_candidates")
        elif configured == 0:
            self.warn("No meters configured -> LISTEN MODE (will log DLL-ID + suggested driver).")
            self.emit("search", "listen", "listen_mode")
        else:
            entries = meters if isinstance(meters, list) else list(meters.values()) \
                if isinstance(meters, dict) else []
            count = self.configured_meters(entries)
            if count > 0:
                self.emit("search", "configured", "official_meters_configured")
            else:
                self.warn("Configured meters exist in options.json, but none produced a valid wmbusmeters "
                          "meter file -> LISTEN MODE.")
                self.emit("search", "listen", "configured_meters_invalid")
        self.emit("set", "OFFICIAL_METERS_COUNT", str(count))
        self.emit("rc", "0")
        return 0

    def search_meters(self) -> Any:
        """create_search_meter_files_from_cache: the number of files, None without a cache."""
        path = self.a.search_candidates_file
        if not os.path.isfile(path):
            return None
        i = 0
        for line in _bash_lines(path):
            mid, driver = bl._bash_read_tabs(line, 2)
            mid = bl.normalize_id(mid)
            if not re.fullmatch(r"[0-9A-Fa-f]{8}", mid):
                continue
            if not re.fullmatch(r"[A-Za-z0-9_]+", driver):
                driver = "auto"
            i += 1
            body = f"name=search_{mid}\nid={mid.lower()}\n"
            if driver != "auto":
                body += f"driver={driver}\n"
            self.write(os.path.join(self.a.meter_dir, "meter-%04d" % i), body)
        return i

    def configured_meters(self, entries: List[Any]) -> int:
        excludes: Dict[str, str] = {}
        loaded = 0
        for m in entries:
            name = jq_r_alt(m, "id", "meter", self.err)
            driver = jq_r_alt(m, "type", "auto", self.err)
            driver_other = jq_r_alt(m, "type_other", "", self.err)
            mid_raw = jq_r_alt(m, "meter_id", "", self.err)
            key = jq_r_alt(m, "key", "", self.err)
            excl = jq_r_alt(m, "exclude_fields", "", self.err).replace(",", " ")
            calc = jq_r_alt(m, "calculated_fields", "", self.err)
            stat = jq_r_alt(m, "static_fields", "", self.err)
            if not key or key == "null":
                key = ""
            elif not re.fullmatch(r"[A-Fa-f0-9]{32}", key):
                self.warn(f"Invalid key for '{name}' -> skipping (expected empty or 32 hex chars, got: '{key}')")
                continue
            if not driver or driver == "null":
                driver = "auto"
            if driver == "other":
                if not driver_other or driver_other == "null":
                    self.warn(f"type=other but type_other is empty for '{name}' -> skipping")
                    continue
                driver = driver_other
            mid = bl.normalize_id(mid_raw)
            if not mid:
                self.warn(f"Invalid meter_id for '{name}' -> skipping (got: '{mid_raw}')")
                continue
            low = mid.lower()
            if excl and excl != "null":
                excludes[low] = excl
                self.emit("exclude", low, excl)
            calc_lines = field_spec_lines(calc, mid, "calculate_", "calculated_fields", self.warn) \
                if calc and calc != "null" else []
            stat_lines = field_spec_lines(stat, mid, "field_", "static_fields", self.warn) \
                if stat and stat != "null" else []
            loaded += 1
            body = [f"name={name}", f"id={low}"]
            if key:
                body.append(f"key={key}")
            if driver != "auto":
                body.append(f"driver={driver}")
            body += stat_lines + calc_lines
            self.write(os.path.join(self.a.meter_dir, "meter-%04d" % loaded),
                       "".join(ln + "\n" for ln in body))
            if excludes.get(low):
                self.log("info", f"meter: {name} id={mid} driver={driver} exclude_fields={excludes[low]}")
            else:
                self.log("info", f"meter: {name} id={mid} driver={driver}")
        return loaded

    @staticmethod
    def write(path: str, text: str) -> None:
        with open(path, "wb") as fh:
            fh.write(bl._b(text))


class Previews(Tool):
    """sync_candidate_autodecode_files, then prune_official_meter_previews."""

    def run(self) -> int:
        a = self.a
        files = bl.CandidateFiles(a.candidates_file, "", a.recent_raw_file, "", "",
                                  a.preview_meter_dir, a.meter_dir)
        if os.path.isfile(a.candidates_file):
            for line in _bash_lines(a.candidates_file):
                mid, driver, type_line, _ = bl._bash_read_tabs(line, 4)
                mid = bl.normalize_id(mid)
                if not re.fullmatch(r"[0-9A-Fa-f]{8}", mid):
                    continue
                bl.ensure_autodecode(files, mid, driver or "auto", type_line, "false", a.preview_state_file,
                                     a.attempts_dir, self.log, self.request)
        self.prune()
        self.emit("rc", "0")
        return 0

    def request(self, *fields: str) -> None:
        if fields and fields[0] == "preview":
            self.emit(*fields)

    def prune(self) -> None:
        a = self.a
        if not os.path.isdir(a.meter_dir):
            return
        for mf in sorted(glob.glob(os.path.join(a.meter_dir, "meter-*"))):
            if not os.path.isfile(mf):
                continue
            first = next((ln for ln in bl._read_lines(mf) if ln.startswith(b"id=")), None)
            if first is None:
                continue
            mid = bl._ascii_upper(bl._s(first).split("=")[1])
            if not re.fullmatch(r"[0-9A-Fa-f]{8}", mid):
                continue
            pf = os.path.join(a.preview_meter_dir, f"meter-preview-{mid}")
            if os.path.isfile(pf):
                for p in (pf, os.path.join(a.attempts_dir, mid)):
                    try:
                        os.unlink(p)
                    except OSError:
                        pass
                self.log("info", f"pruned orphaned meter-preview-{mid} (now official configured meter)")


def _iso_age_over(ts: str, now: datetime.datetime, max_age: int) -> bool:
    """The age test of the python programs bash ran: naive times are UTC."""
    try:
        d = datetime.datetime.fromisoformat(ts.strip())
    except ValueError:
        return False
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return (now - d).total_seconds() > max_age


def _seconds(text: str, default: int) -> int:
    return int(text) if re.fullmatch(r"[0-9]+", text or "") else default


class Housekeeping(Tool):
    """prune_stale_candidates, then expire_stale_pending_previews."""

    def run(self) -> int:
        self.prune()
        self.expire()
        self.emit("rc", "0")
        return 0

    def prune(self) -> None:
        a = self.a
        path = a.candidates_file
        max_age = _seconds(a.prune_after, 86400)
        if not os.path.isfile(path):
            return
        now = datetime.datetime.now(datetime.timezone.utc)
        dropped: List[str] = []
        with bl.locked(path):
            fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=os.path.dirname(path) or ".")
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as f, \
                        os.fdopen(fd, "w", encoding="utf-8") as out:
                    for line in f:
                        row = line.rstrip("\n")
                        if not row:
                            continue
                        cols = row.split("\t")
                        if len(cols) >= 4 and _iso_age_over(cols[3], now, max_age):
                            dropped.append(cols[0])
                        else:
                            out.write(row + "\n")
                os.replace(tmp, path)
            except BaseException:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
        for mid in dropped:
            mid = bl.normalize_id(mid)
            if not re.fullmatch(r"[0-9A-Fa-f]{8}", mid):
                continue
            bl.tsv_remove(a.candidate_values_file, mid)
            bl.tsv_remove(a.preview_state_file, mid)
            for p in (os.path.join(a.attempts_dir, mid), os.path.join(a.preview_meter_dir, f"meter-preview-{mid}")):
                try:
                    os.unlink(p)
                except OSError:
                    pass
            self.log("info", f"pruned stale candidate {mid} (no telegram for >{max_age // 3600}h)")

    def expire(self) -> None:
        a = self.a
        path = a.preview_state_file
        max_age = _seconds(a.pending_timeout, 300)
        if not os.path.isfile(path):
            return
        now = datetime.datetime.now(datetime.timezone.utc)
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            stuck = [cols[0] for cols in (ln.rstrip("\n").split("\t") for ln in f)
                     if len(cols) >= 3 and cols[1] == "pending" and _iso_age_over(cols[2], now, max_age)]
        for mid in stuck:
            mid = bl.normalize_id(mid)
            if not re.fullmatch(r"[0-9A-Fa-f]{8}", mid):
                continue
            # Read again right before writing: a frame may have ended the state meanwhile.
            states = [bl._s(ln).split("\t")[1] if "\t" in bl._s(ln) else ""
                      for ln in bl._read_lines(path) if bl._first_field(ln) == bl._b(mid)]
            if not states or states[-1] != "pending":
                continue
            bl.set_preview_state(path, a.attempts_dir, mid, "no_decode_result")
            self.log("info", f"preview {mid}: stuck pending for >{max_age // 60}min without a telegram, "
                             "marked no_decode_result")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    r = sub.add_parser("refresh", help="refresh_meter_files")
    for name in ("options", "meter-dir", "search-candidates-file"):
        r.add_argument(f"--{name}", required=True)
    for name in ("search-mode", "search-expected", "search-tolerance", "loglevel"):
        r.add_argument(f"--{name}", default="")
    p = sub.add_parser("previews", help="sync_candidate_autodecode_files + prune_official_meter_previews")
    for name in ("candidates-file", "recent-raw-file", "preview-state-file", "meter-dir", "preview-meter-dir",
                 "attempts-dir"):
        p.add_argument(f"--{name}", required=True)
    p.add_argument("--loglevel", default="")
    h = sub.add_parser("housekeeping", help="prune_stale_candidates + expire_stale_pending_previews")
    for name in ("candidates-file", "candidate-values-file", "preview-state-file", "preview-meter-dir",
                 "attempts-dir"):
        h.add_argument(f"--{name}", required=True)
    for name in ("prune-after", "pending-timeout", "loglevel"):
        h.add_argument(f"--{name}", default="")
    a = ap.parse_args(argv)
    return {"refresh": MeterFiles, "previews": Previews, "housekeeping": Housekeeping}[a.mode](a).run()


if __name__ == "__main__":
    sys.exit(main())

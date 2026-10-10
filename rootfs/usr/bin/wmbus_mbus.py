#!/usr/bin/env python3
"""The wired M-Bus instance's output, read in one process (14-mbus.sh).

`consume` replaces the bash loop behind the third wmbusmeters instance
(mbus_log_console_line + mbus_consume_line), line for line:

- every decoder line is appended to the console log as
  "HH:MM:SS<TAB>reading<TAB>line" (the reading number steps on each accepted
  telegram), and the log is cut to its last 2000 lines every 500 lines - in
  place, as tee and the WebUI keep the file open;
- an accepted telegram updates the per-meter id, last-ok time and address
  clash (a name answering with a new id), loses its rssi_dbm (0 on a wire)
  and is handed back to bash for publishing: Discovery, state and the meter
  table belong to the radio path's code there;
- the decoder's own words name the failure causes the JSON never carries,
  and become the traffic state of status_mbus.json (transitions only);
- "(meter) <name> <address> did not send a response!" names the meter that
  stayed silent: its last silence goes into status_mbus.json next to its last
  answer, and the bus state is taken over every meter's last event - "ok"
  while all answer, "partial" while some do, "no_reply" when none does.

Requests to the bash loop behind it, one per line, four fields separated by
0x1F (which `read` keeps, so empty fields survive), in the order of the
decoder's output: "tg" <name> <id> <telegram> and "log" "" "" <line>. The
line is always the last field, which `read` hands over whole; a newline in
it (jq printing several values) travels as 0x1E.
"""

from __future__ import annotations

import argparse
import glob
import os
import re
import sys
import time
from typing import Dict, List

import bridge_ledger as bl

SEP = "\x1f"
NEWLINE = "\x1e"
LOG_MAX_LINES = 2000
TRIM_EVERY = 500


def jq_c_del(line: str, key: str) -> str:
    """`line="$(echo "$line" | jq -c 'del(.key)' 2>/dev/null || printf '%s' "$line")"`.

    Every JSON value of the line is one input; the outputs written before an
    error stay, and the original line follows them when jq fails.
    """
    text = line + "\n"
    out: List[str] = []
    failed = _garbage(text)
    for v in bl.jq_values(text):
        if v is None:
            out.append("null")
        elif isinstance(v, dict):
            v = dict(v)
            v.pop(key, None)
            out.append(bl.jq_dumps(v))
        else:
            failed = True  # del() of a key on a number, string, array or boolean
    result = "".join(o + "\n" for o in out)
    if failed:
        result += line
    return result.rstrip("\n")


def _garbage(text: str) -> bool:
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


def options_value(path: str, key: str, fallback: str) -> str:
    """mbus_opt: `jq -r --arg k KEY --arg d FALLBACK '.[$k] // $d' options.json`."""
    try:
        with open(path, "rb") as fh:
            text = bl._s(fh.read())
    except OSError:
        return fallback
    out = []
    for v in bl.jq_values(text):
        if not isinstance(v, dict):
            if v is None:
                out.append(fallback)
                continue
            return fallback  # jq fails: `|| printf fallback` follows what it printed
        x = v.get(key)
        x = fallback if x is None or x is False else x
        out.append(x if isinstance(x, str) else bl._jq_pretty(x))
    return "\n".join(out).rstrip("\n") if out else fallback


def silent_meter(line: str) -> str:
    """The name in "(meter) <name> <address> did not send a response!" ("" without one),
    as bash cuts it: after the first "(meter) ", before the last " did not send a
    response!", without the last word (the address)."""
    if "(meter) " not in line:
        return ""
    rest = line.split("(meter) ", 1)[1].rsplit(" did not send a response!", 1)[0]
    return rest.rsplit(" ", 1)[0]


class MbusBook:
    def __init__(self, a: argparse.Namespace, out=None, err=None) -> None:
        self.a = a
        self.out = out if out is not None else sys.stdout
        self.err = err if err is not None else sys.stderr
        self.state = a.state
        self.read_seq = 0
        self.since_trim = 0
        self.last_id: Dict[str, str] = {}
        self.last_ok: Dict[str, int] = {}
        self.last_silent: Dict[str, int] = {}
        self.last_event: Dict[str, str] = {}  # name -> "ok" | "silent"
        self.clash: Dict[str, str] = {}

    def request(self, *fields: str) -> None:
        try:
            self.out.write(SEP.join(fields) + "\n")
            self.out.flush()
        except OSError:
            pass

    def line(self, line: str) -> None:
        self.console(line)
        self.consume(line)

    @staticmethod
    def is_telegram(line: str) -> bool:
        return line.startswith("{") and '"_":"telegram"' in line

    def console(self, line: str) -> None:
        """mbus_log_console_line."""
        if self.is_telegram(line):
            self.read_seq += 1
        stamp = time.strftime("%H:%M:%S", time.localtime(bl.now()))
        try:
            with open(self.a.log, "ab") as fh:
                fh.write(bl._b(f"{stamp}\t{self.read_seq}\t{line}\n"))
        except OSError:
            pass

    def trim(self) -> None:
        """mbus_trim_log: keep the tail, rewritten in place (not renamed over)."""
        lines = bl._read_lines(self.a.log)
        if len(lines) <= LOG_MAX_LINES:
            return
        try:
            with open(self.a.log, "wb") as fh:
                fh.write(b"".join(ln + b"\n" for ln in lines[-LOG_MAX_LINES:]))
        except OSError:
            pass

    def consume(self, line: str) -> None:
        """mbus_consume_line."""
        self.since_trim += 1
        if self.since_trim >= TRIM_EVERY:
            self.since_trim = 0
            self.trim()
        if self.is_telegram(line):
            meter = bl.normalize_id(bl.jq_r(line, (".id",)))
            name = bl.jq_r(line, (".name",))
            if name and meter:
                prev = self.last_id.get(name, "")
                if prev and prev != meter:
                    print(f"[wmbus-bridge][WARN] M-Bus: '{name}' answered with id={meter} but previously "
                          f"{prev} -> two meters on one address?", file=self.err, flush=True)
                    bl.append_event(self.a.events_file, "warn", f"M-Bus address clash on '{name}': {prev} vs {meter}")
                    self.clash[name] = prev
                self.last_id[name] = meter
                self.last_ok[name] = int(bl.now())
                self.last_event[name] = "ok"
            if bl._ID8.fullmatch(meter):
                line = jq_c_del(line, "rssi_dbm")
            # bash publishes it (exclude patterns by name, Discovery, state)
            # and echoes it, as mbus_consume_line did.
            self.request("tg", name, meter, line.replace("\n", NEWLINE))
            self.state = "partial" if "silent" in self.last_event.values() else "ok"
            self.write_status(self.state)
            return
        if "no 0x68 byte found" in line:
            self.set_state("not_mbus_traffic")
        elif "expected checksum" in line:
            self.set_state("damaged_frames")
        elif "did not send a response" in line:
            name = silent_meter(line)
            if name:
                self.last_silent[name] = int(bl.now())
                self.last_event[name] = "silent"
            # A named cause outranks plain silence.
            if self.state not in ("not_mbus_traffic", "damaged_frames"):
                self.state = "partial" if "ok" in self.last_event.values() else "no_reply"
            # Written on every silence: the meter's own timestamp moved.
            self.write_status(self.state)
        elif "no bus specified for meter" in line or "SpecifiedDeviceNotFound" in line:
            self.set_state("bus_down")
        self.request("log", "", "", line)

    def set_state(self, new: str) -> None:
        """mbus_set_state: transitions only."""
        if new == self.state:
            return
        self.state = new
        self.write_status(new)

    def write_status(self, state: str) -> None:
        """mbus_write_status."""
        names = list(self.last_id) + [n for n in self.last_silent if n not in self.last_id]
        meters = {name: {"id": self.last_id.get(name, ""), "last_ok_epoch": self.last_ok.get(name, 0),
                         "last_silent_epoch": self.last_silent.get(name, 0),
                         "clash_with": self.clash.get(name, "")} for name in names}
        doc = {"state": state, "device": options_value(self.a.options, "mbus_device", ""),
               "bus_alias": self.a.alias, "meters_configured": int(self.a.configured or 0),
               "meters_skipped": int(self.a.skipped or 0), "meters": meters, "updated": int(bl.now())}
        path = self.a.status_file
        try:
            with open(path + ".tmp", "wb") as fh:
                fh.write(bl._b(bl._jq_pretty(doc) + "\n"))
            os.replace(path + ".tmp", path)
        except OSError:
            pass


# ── configuration (write_mbus_conf + refresh_mbus_meter_files) ──────────────

_SPACE = " \t\n\r\f\v"


def field_spec_lines(spec: str, meter: str, prefix: str, option: str, warn) -> List[str]:
    """07-meters.sh _build_field_spec_lines: "name=value" entries split on ';'
    (IFS=';' word splitting: no empty field at the end), trimmed, validated."""
    entries = spec.split(";")
    if entries and entries[-1] == "":
        entries.pop()
    out = []
    for entry in entries:
        entry = entry.strip(_SPACE)
        if not entry:
            continue
        name, _, value = entry.partition("=")
        if "=" not in entry or "\n" in entry:
            warn(f"{option} for {meter}: '{entry}' is not name=value -> skipped")
            continue
        name = "".join(ch for ch in name if ch not in _SPACE)
        value = value.strip(_SPACE)
        if not re.fullmatch(r"[a-z][a-z0-9_]*", name):
            warn(f"{option} for {meter}: field name '{name}' is not [a-z][a-z0-9_]* -> skipped")
            continue
        if not value:
            warn(f"{option} for {meter}: '{name}' has an empty value -> skipped")
            continue
        out.append(f"{prefix}{name}={value}")
    return out


def _jq_r_default(obj: object, key: str, default: str) -> str:
    """`echo "$json" | jq -r '.key // default'` for one object (`// empty`: default "")."""
    if not isinstance(obj, dict):
        return default
    v = obj.get(key)
    if v is None or v is False:
        return default
    return v if isinstance(v, str) else bl._jq_pretty(v)


# p0 included: the factory "unset" address, usable while it is the only
# unconfigured meter on the bus (refresh_mbus_meter_files, the WebUI).
_PRIMARY = re.compile(r"p([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|250)")


class MbusConfig:
    """write_mbus_conf and refresh_mbus_meter_files, writing the same files.

    What bash keeps in shell variables comes back on stdout, one per line,
    fields separated by 0x1F (a meter name may be empty or hold spaces):
    "set VAR VALUE", "exclude NAME PATTERNS" / "unexclude NAME", and last
    "rc 0|1" (write_mbus_conf's return code; 1 stops the start)."""

    def __init__(self, a: argparse.Namespace, out=None, err=None) -> None:
        self.a = a
        self.out = out if out is not None else sys.stdout
        self.err = err if err is not None else sys.stderr
        self.options = self._load_options()

    def _load_options(self) -> object:
        try:
            with open(self.a.options, "rb") as fh:
                values = bl.jq_values(bl._s(fh.read()))
        except OSError:
            return None
        return values[0] if values else None

    def opt(self, key: str, fallback: str) -> str:
        """mbus_opt."""
        if not os.path.isfile(self.a.options):
            return fallback
        return options_value(self.a.options, key, fallback)

    def emit(self, *fields: str) -> None:
        self.out.write(SEP.join(fields) + "\n")
        self.out.flush()

    def warn(self, msg: str) -> None:
        print(f"[wmbus-bridge][WARN] {msg}", file=self.err, flush=True)

    def log(self, msg: str, level: str = "info") -> None:
        """log / log_verbose, on stderr: stdout carries the values for bash."""
        if level == "info" or (level == "verbose" and self.a.loglevel in ("verbose", "debug")):
            print(f"[wmbus-bridge] {msg}", file=self.err, flush=True)

    def status(self, state: str, alias: str) -> None:
        """mbus_write_status from the parent shell: no meter heard there, and
        the meter counts of the previous start (this one failed before them)."""
        doc = {"state": state, "device": self.opt("mbus_device", ""), "bus_alias": alias,
               "meters_configured": int(self.a.configured or 0), "meters_skipped": int(self.a.skipped or 0),
               "meters": {}, "updated": int(bl.now())}
        try:
            with open(self.a.status_file + ".tmp", "wb") as fh:
                fh.write(bl._b(bl._jq_pretty(doc) + "\n"))
            os.replace(self.a.status_file + ".tmp", self.a.status_file)
        except OSError:
            pass

    @staticmethod
    def device_serial(path: str) -> str:
        """mbus_device_serial_now ("" when there is none)."""
        if not os.path.exists(path):
            return ""
        node = os.path.basename(os.path.realpath(path))
        sys_path = os.path.join(SYS_ROOT, "class", "tty", node, "device", "..", "serial")
        try:
            with open(sys_path, "rb") as fh:
                return bl._s(fh.read()).replace("\n", "")
        except OSError:
            return ""

    def identity(self, path: str, pinned: str) -> str:
        """mbus_identity_check."""
        if not os.path.exists(path):
            return "device_missing"
        now = self.device_serial(path)
        if not now:
            return "pin_impossible"
        if not pinned:
            return "unknown_identity"
        return "ok" if now == pinned else "changed"

    def write_conf(self) -> int:
        dev = self.opt("mbus_device", "")
        alias = self.opt("mbus_bus_alias", "MAIN")
        bps = self.opt("mbus_baudrate", "2400")
        loglevel = self.opt("mbus_loglevel", "normal")
        donotprobe = self.opt("mbus_donotprobe_all", "true")
        logtelegrams = self.opt("mbus_logtelegrams", "false")
        ignoredup = self.opt("mbus_ignoreduplicates", "false")
        pinned = self.opt("mbus_device_serial", "")
        poll = self.opt("mbus_poll_interval", "15m")
        self.emit("set", "MBUS_POLL_DEFAULT", poll)
        if not dev or dev == "null":
            self.warn("M-Bus: polling is enabled but no port is selected -> not starting. Pick a port in "
                      "the M-Bus tab, or turn mbus_enabled off.")
            self.status("not_configured", self.a.alias)
            return 1
        if not re.fullmatch(r"[A-Za-z0-9_]+", alias):
            self.warn(f"M-Bus: invalid bus alias '{alias}' -> falling back to MAIN")
            alias = "MAIN"
        self.alias = alias
        self.emit("set", "MBUS_BUS_ALIAS", alias)
        if not re.fullmatch(r"[0-9]+[smh]", poll):
            self.warn(f"M-Bus: invalid poll interval '{poll}' -> using 15m. Write it as a number followed "
                      f"by s, m or h (for example 30s, 15m, 1h).")
            poll = "15m"
            self.emit("set", "MBUS_POLL_DEFAULT", poll)
        self.poll_default = poll
        identity = self.identity(dev, pinned)
        if identity == "device_missing":
            self.warn(f"M-Bus: the configured port {dev} is gone -> not starting. Re-pick it in the M-Bus "
                      f"tab; serial port names change when USB devices are replugged.")
            self.status("device_missing", alias)
            return 1
        if identity == "changed":
            print(f"[wmbus-bridge][ERR] M-Bus: {dev} is now a different device than the one you selected "
                  f"-> refusing to poll. Something else took that port; re-pick the converter in the M-Bus "
                  f"tab to confirm.", file=self.err, flush=True)
            bl.append_event(self.a.events_file, "error", f"M-Bus device identity changed on {dev}")
            self.status("identity_changed", alias)
            return 1
        if identity == "pin_impossible":
            self.log(f"[DIAG] M-Bus: {dev} reports no serial number -> identity cannot be verified", "verbose")
        os.makedirs(self.a.meter_dir, exist_ok=True)
        lines = [f"loglevel={loglevel}", f"device={alias}={dev}:mbus:{bps}"]
        if donotprobe == "true":
            lines.append("donotprobe=all")
        lines += ["logfile=/dev/stdout", "format=json"]
        if logtelegrams == "true":
            lines.append("logtelegrams=true")
        if ignoredup == "true":
            lines.append("ignoreduplicates=true")
        _write_atomic(self.a.conf, "".join(ln + "\n" for ln in lines))
        self.log(f"M-Bus: config written for {alias}={dev}:mbus:{bps}")
        return 0

    def refresh_meters(self) -> None:
        for path in glob.glob(os.path.join(self.a.meter_dir, "meter-*")):
            try:
                os.unlink(path)
            except OSError:
                pass
        n = skipped = 0
        opts = self.options
        meters = opts.get("mbus_meters") if isinstance(opts, dict) else None
        if not os.path.isfile(self.a.options) or not meters or not (
                isinstance(meters, (list, dict, str)) and len(meters) > 0):
            if os.path.isfile(self.a.options):
                self.warn("M-Bus: no meters configured -> nothing will be polled. Add a meter with its bus "
                          "address in the M-Bus tab.")
            self.emit("set", "MBUS_METERS_OK", "0")
            self.emit("set", "MBUS_METERS_SKIPPED", "0")
            return
        entries = meters if isinstance(meters, list) else list(meters.values()) if isinstance(meters, dict) else []
        seen_name: Dict[str, str] = {}
        seen_addr: Dict[str, str] = {}
        for m in entries:
            name = _jq_r_default(m, "id", "mbus")
            addr = _jq_r_default(m, "address", "")
            driver = _jq_r_default(m, "type", "auto")
            driver_other = _jq_r_default(m, "type_other", "")
            key = _jq_r_default(m, "key", "")
            poll = _jq_r_default(m, "poll_interval", "")
            excl = _jq_r_default(m, "exclude_fields", "").replace(",", " ")
            calc = _jq_r_default(m, "calculated_fields", "")
            stat = _jq_r_default(m, "static_fields", "")
            if excl and excl != "null":
                self.emit("exclude", name, excl)
            else:
                self.emit("unexclude", name)
            if not _PRIMARY.fullmatch(addr) and not re.fullmatch(r"[0-9A-Fa-f]{8}", addr):
                self.warn(f"M-Bus: invalid address '{addr}' for '{name}' -> skipped (expected p0..p250 or 8 hex)")
                skipped += 1
                continue
            # A second entry with a name or an address already taken: skipped.
            if name and name in seen_name:  # an empty name is not checked (bash cannot key it)
                self.warn(f"M-Bus: name '{name}' is used twice (also at {seen_name[name]}) -> '{name}' at {addr} skipped")
                skipped += 1
                continue
            if addr.lower() in seen_addr:
                self.warn(f"M-Bus: address {addr} is used twice (also by '{seen_addr[addr.lower()]}') -> '{name}' skipped")
                skipped += 1
                continue
            if name:
                seen_name[name] = addr
            seen_addr[addr.lower()] = name
            if key and key != "null" and not re.fullmatch(r"[A-Fa-f0-9]{32}", key):
                self.warn(f"M-Bus: invalid key for '{name}' -> skipped")
                skipped += 1
                continue
            if not driver or driver == "null":
                driver = "auto"
            if driver == "other":
                if not driver_other or driver_other == "null":
                    self.warn(f"M-Bus: type=other but type_other empty for '{name}' -> skipped")
                    skipped += 1
                    continue
                driver = driver_other
            if not poll or poll == "null":
                poll = self.poll_default
            if not re.fullmatch(r"[0-9]+[smh]", poll):
                self.warn(f"M-Bus: invalid poll interval '{poll}' for '{name}' -> using {self.poll_default}")
                poll = self.poll_default
            calc_lines = field_spec_lines(calc, name, "calculate_", "calculated_fields", self.warn) \
                if calc and calc != "null" else []
            stat_lines = field_spec_lines(stat, name, "field_", "static_fields", self.warn) \
                if stat and stat != "null" else []
            n += 1
            body = [f"name={name}", f"driver={driver}:{self.alias}:mbus", f"id={addr}"]
            if key and key != "null":
                body.append(f"key={key}")
            body.append(f"pollinterval={poll}")
            body += stat_lines + calc_lines
            _write_atomic(os.path.join(self.a.meter_dir, "meter-%04d" % n), "".join(ln + "\n" for ln in body))
        self.emit("set", "MBUS_METERS_OK", str(n))
        self.emit("set", "MBUS_METERS_SKIPPED", str(skipped))
        if skipped > 0:
            self.log(f"M-Bus: {n} meter file(s) written, {skipped} entr(ies) skipped")
        else:
            self.log(f"M-Bus: {n} meter file(s) written")

    def run(self) -> int:
        self.alias = self.a.alias
        self.poll_default = "15m"
        rc = self.write_conf()
        if rc == 0:
            self.refresh_meters()
        self.emit("rc", str(rc))
        return rc


SYS_ROOT = "/sys"


def _write_atomic(path: str, text: str) -> None:
    """`{ ...; } > path.tmp && mv -f path.tmp path`."""
    with open(path + ".tmp", "wb") as fh:
        fh.write(bl._b(text))
    os.replace(path + ".tmp", path)


def run(book: MbusBook, stream=None) -> None:
    stream = stream if stream is not None else sys.stdin.buffer
    for raw in stream:
        if not raw.endswith(b"\n"):  # `read` does not hand over an unterminated last line
            continue
        try:
            book.line(bl._s(raw[:-1]))
        except Exception as exc:  # one bad line must not stop the console
            print(f"[wmbus-bridge][WARN] M-Bus: decoder line skipped: {exc!r}", file=sys.stderr, flush=True)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    c = sub.add_parser("consume", help="output of the wired M-Bus wmbusmeters instance")
    for name in ("log", "status-file", "options", "events-file"):
        c.add_argument(f"--{name}", required=True)
    c.add_argument("--alias", default="MAIN")
    c.add_argument("--configured", default="0")
    c.add_argument("--skipped", default="0")
    c.add_argument("--state", default="starting", help="MBUS_TRAFFIC_STATE when the instance starts")
    g = sub.add_parser("config", help="wmbusmeters.conf and the meter files of the M-Bus instance")
    for name in ("options", "conf", "meter-dir", "status-file", "events-file"):
        g.add_argument(f"--{name}", required=True)
    g.add_argument("--alias", default="MAIN", help="MBUS_BUS_ALIAS before this start")
    g.add_argument("--configured", default="0", help="MBUS_METERS_OK before this start")
    g.add_argument("--skipped", default="0", help="MBUS_METERS_SKIPPED before this start")
    g.add_argument("--loglevel", default="")
    a = ap.parse_args(argv)
    if a.mode == "config":
        MbusConfig(a).run()
        return 0
    run(MbusBook(a))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""External wmbusmeters drivers (.xmq) uploaded by the user.

Off by default (custom_drivers_enabled). The files never reach the main
decoding wmbusmeters: they are loaded only by a separate instance that decodes
the meters set to an external_* driver. The reasons are measured, not assumed
(wmbusmeters 3.1.1, 2026-11-07):

- one bad file in a drivers directory ends the whole process: rc 5 for most
  errors, a segfault (139) for an empty file, an abort (134) for a field with
  an unknown quantity - so every meter of that instance stops decoding;
- a valid file whose detect block shares an mvt triple with a built-in driver
  removes that built-in driver: a meter set to it then ends the process
  ("triggered a removal of the (not yet loaded) builtin driver"), and meters on
  auto pick the external one.

So every file is checked here first, in a process of its own: `wmbusmeters
--driversdir=<one file> --listdrivers` must exit 0 and list the driver. A file
that removes built-in drivers is accepted (it only affects the external
instance) and the removed names are reported. Files are checked one at a time
and then together, so one external file cannot remove another.

Where the files live: DRIVERS_DIR is part of Home Assistant backups,
DRIVERS_NDA_DIR is left out of them (backup_exclude); NDA is the default.

CLI:
  custom_drivers.py check FILE                 -> JSON verdict for one file
  custom_drivers.py install --dest DIR --status FILE
                                               -> check all stored files, copy
                                                  the accepted ones to DIR
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Dict, List, Optional, Tuple

PREFIX = "external_"
MAX_BYTES = 64 * 1024
MAX_NAME = 48
CHECK_TIMEOUT_S = 15

DRIVERS_DIR = os.environ.get("CUSTOM_DRIVERS_DIR", "/data/custom_drivers")
DRIVERS_NDA_DIR = os.environ.get("CUSTOM_DRIVERS_NDA_DIR", "/data/custom_drivers_nda")

# `name = abc` inside the driver block; xmq allows spaces around "=".
_NAME_RE = re.compile(r"^[ \t]*name[ \t]*=[ \t]*([A-Za-z0-9_]+)[ \t]*$", re.M)
_VALID_NAME = re.compile(r"^%s[a-z0-9_]{1,%d}$" % (PREFIX, MAX_NAME - len(PREFIX)))


def wmbusmeters_bin() -> str:
    return os.environ.get("WMBUSMETERS_BIN", "/usr/bin/wmbusmeters")


def driver_name(text: str) -> Optional[str]:
    """The driver's name: the first `name = ...` line of the file."""
    m = _NAME_RE.search(text)
    return m.group(1) if m else None


def static_check(data: bytes) -> Tuple[Optional[str], str]:
    """Checks that need no process: (name, "") or (name-or-None, reason)."""
    if not data.strip():
        return None, "empty"
    if len(data) > MAX_BYTES:
        return None, "too_large"
    if b"\x00" in data:
        return None, "not_text"
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return None, "not_text"
    if "driver" not in text or "{" not in text:
        return None, "not_a_driver"
    name = driver_name(text)
    if not name:
        return None, "no_name"
    if not name.startswith(PREFIX):
        return name, "name_without_prefix"
    if not _VALID_NAME.match(name):
        return name, "bad_name"
    return name, ""


def list_drivers(driversdir: Optional[str] = None,
                 timeout: int = CHECK_TIMEOUT_S) -> Tuple[int, Optional[List[str]]]:
    """(exit code, driver names) of `wmbusmeters [--driversdir=D] --listdrivers`.

    A crash is a negative or >128 exit code; names are None when the process
    did not finish cleanly. Runs in its own process, so a crash ends only it.
    """
    cmd = [wmbusmeters_bin()]
    if driversdir:
        cmd.append(f"--driversdir={driversdir}")
    cmd.append("--listdrivers")
    try:
        proc = subprocess.run(cmd, stdin=subprocess.DEVNULL, capture_output=True,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        return -1, None
    except OSError:
        return -2, None
    if proc.returncode != 0:
        return proc.returncode, None
    names = []
    for line in proc.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split()
        if parts:
            names.append(parts[0])
    return 0, names


def _exit_reason(rc: int) -> str:
    if rc == -1:
        return "timeout"
    if rc == -2:
        return "wmbusmeters_missing"
    if rc < 0 or rc > 128:
        return "crashed"
    return "rejected"


def check_files(paths: List[str], builtin: Optional[List[str]] = None) -> List[dict]:
    """Verdicts for files checked one by one, then as a set, in list order.

    Each verdict: file, name, ok, reason, replaces (built-in drivers the file
    removes), conflicts (an earlier accepted external driver it removes).
    """
    if builtin is None:
        rc, builtin = list_drivers()
        if rc != 0 or builtin is None:
            return [{"file": os.path.basename(p), "name": None, "ok": False,
                     "reason": "wmbusmeters_unavailable", "replaces": [], "conflicts": []}
                    for p in paths]
    base = set(builtin)
    accepted: List[Tuple[str, str]] = []  # (name, path)
    seen_names = set()
    out = []
    with tempfile.TemporaryDirectory(prefix="xdrv-") as tmp:
        for path in paths:
            v = {"file": os.path.basename(path), "name": None, "ok": False, "reason": "",
                 "replaces": [], "conflicts": []}
            out.append(v)
            try:
                with open(path, "rb") as fh:
                    data = fh.read(MAX_BYTES + 1)
            except OSError:
                v["reason"] = "unreadable"
                continue
            name, reason = static_check(data)
            v["name"] = name
            if reason:
                v["reason"] = reason
                continue
            if name in base:
                v["reason"] = "name_is_builtin"
                continue
            if name in seen_names:
                v["reason"] = "duplicate_name"
                continue
            if os.path.basename(path) != f"{name}.xmq":
                v["reason"] = "file_name_mismatch"
                continue
            one = os.path.join(tmp, "one")
            shutil.rmtree(one, ignore_errors=True)
            os.makedirs(one)
            shutil.copyfile(path, os.path.join(one, f"{name}.xmq"))
            rc, listed = list_drivers(one)
            if rc != 0 or listed is None:
                v["reason"] = _exit_reason(rc)
                continue
            if name not in listed:
                v["reason"] = "not_loaded"
                continue
            v["replaces"] = sorted(base - set(listed))
            # Together with the files accepted so far: none of them may vanish.
            together = os.path.join(tmp, "set")
            shutil.rmtree(together, ignore_errors=True)
            os.makedirs(together)
            for n, p in accepted + [(name, path)]:
                shutil.copyfile(p, os.path.join(together, f"{n}.xmq"))
            rc, listed = list_drivers(together)
            if rc != 0 or listed is None:
                v["reason"] = _exit_reason(rc)
                continue
            lost = sorted(n for n, _ in accepted if n not in listed)
            if lost or name not in listed:
                v["reason"] = "conflict"
                v["conflicts"] = lost or [name]
                continue
            v["ok"] = True
            accepted.append((name, path))
            seen_names.add(name)
    return out


def stored_files() -> List[Tuple[str, bool]]:
    """(path, nda) of every stored .xmq, NDA ones first, sorted by name."""
    found = []
    for directory, nda in ((DRIVERS_NDA_DIR, True), (DRIVERS_DIR, False)):
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            continue
        for n in names:
            if n.endswith(".xmq"):
                found.append((os.path.join(directory, n), nda))
    return found


def install(dest: str, status_file: str, enabled: bool = True) -> dict:
    """Check every stored file and copy the accepted ones to dest.

    dest is emptied first, so a file that no longer passes (a wmbusmeters update
    that rejects it, a file removed in the WebUI) is gone from the instance.
    The status file is what the WebUI shows.
    """
    files = stored_files()
    verdicts = check_files([p for p, _ in files]) if (enabled and files) else []
    for v, (_, nda) in zip(verdicts, files):
        v["nda"] = nda
    os.makedirs(dest, exist_ok=True)
    for n in os.listdir(dest):
        try:
            os.unlink(os.path.join(dest, n))
        except OSError:
            pass
    if enabled:
        for v, (path, _) in zip(verdicts, files):
            if v["ok"]:
                shutil.copyfile(path, os.path.join(dest, f"{v['name']}.xmq"))
    status = {"enabled": enabled, "checked_at": int(time.time()), "drivers": verdicts}
    write_json_atomic(status_file, status)
    return status


def write_json_atomic(path: str, obj) -> None:
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("file")
    i = sub.add_parser("install")
    i.add_argument("--dest", required=True)
    i.add_argument("--status", required=True)
    i.add_argument("--enabled", default="true")
    a = ap.parse_args(argv)
    if a.cmd == "check":
        print(json.dumps(check_files([a.file])[0], ensure_ascii=False))
        return 0
    status = install(a.dest, a.status, a.enabled == "true")
    ok = sum(1 for v in status["drivers"] if v["ok"])
    print(f"external drivers: {ok} of {len(status['drivers'])} accepted")
    return 0


if __name__ == "__main__":
    sys.exit(main())

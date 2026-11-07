#!/usr/bin/env python3
"""The external wmbusmeters instance's output, into the one decode pipeline.

The meters on an external_* driver are decoded by a wmbusmeters of their own
(15-external.sh), so a driver that fails cannot stop the main one. Their
telegrams still need the same decode stage as every other meter: one
process writes the status files and publishes. Two processes writing into
one pipe would interleave lines longer than PIPE_BUF, so the lines travel
through a FIFO and are put back whole:

  forward  reads the external wmbusmeters (stdout+stderr). A JSON line goes
           into the FIFO; anything else is wmbusmeters talking and goes to
           stderr with an "[external]" prefix. With no reader (the main
           pipeline restarting) the line is dropped, never waited for. The
           last line of input may be "__EXTERNAL_RC__ <n>", the instance's
           exit code: it is logged, written to the status file and becomes
           this process's exit code.
  merge    copies stdin (the main wmbusmeters) to stdout and adds the FIFO's
           lines in between, whole lines only. It ends when stdin ends, as
           the pipeline did without it.
"""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import select
import stat
import sys
import tempfile
import time
from typing import Optional

RC_MARK = b"__EXTERNAL_RC__ "
MAX_LINE = 1 << 20  # a longer "line" is not wmbusmeters output: dropped


def ensure_fifo(path: str) -> None:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        os.mkfifo(path, 0o600)
        return
    if not stat.S_ISFIFO(st.st_mode):
        os.unlink(path)
        os.mkfifo(path, 0o600)


def write_status(path: str, **fields) -> None:
    if not path:
        return
    try:
        with open(path, encoding="utf-8") as fh:
            status = json.load(fh)
        if not isinstance(status, dict):
            status = {}
    except (OSError, ValueError):
        status = {}
    status.update(fields)
    d = os.path.dirname(path) or "."
    try:
        fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(status, fh)
        os.replace(tmp, path)
    except OSError:
        pass


class Lines:
    """Split a byte stream into whole lines; an overlong line is dropped."""

    def __init__(self) -> None:
        self.buf = b""
        self.skipping = False

    def feed(self, data: bytes):
        self.buf += data
        while True:
            i = self.buf.find(b"\n")
            if i < 0:
                if len(self.buf) > MAX_LINE:
                    self.buf = b""
                    self.skipping = True
                return
            line, self.buf = self.buf[:i + 1], self.buf[i + 1:]
            if self.skipping:
                self.skipping = False
                continue
            yield line

    def rest(self) -> Optional[bytes]:
        if self.buf and not self.skipping:
            return self.buf + b"\n"
        return None


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        n = os.write(fd, view)
        view = view[n:]


class Forward:
    def __init__(self, a: argparse.Namespace) -> None:
        self.a = a
        self.fd: Optional[int] = None
        self.dropped = 0
        self.sent = 0

    def _open(self) -> bool:
        if self.fd is not None:
            return True
        try:
            fd = os.open(self.a.fifo, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as e:
            if e.errno in (errno.ENXIO, errno.ENOENT):
                return False  # no reader: the main pipeline is not up
            raise
        # Blocking from here on: a slow reader slows the instance down, a
        # line is never cut in half.
        fl = fcntl.fcntl(fd, fcntl.F_GETFL)
        fcntl.fcntl(fd, fcntl.F_SETFL, fl & ~os.O_NONBLOCK)
        self.fd = fd
        return True

    def send(self, line: bytes) -> None:
        if not self._open():
            self.dropped += 1
            return
        try:
            _write_all(self.fd, line)
            self.sent += 1
        except OSError as e:
            if e.errno != errno.EPIPE:
                raise
            os.close(self.fd)
            self.fd = None
            self.dropped += 1

    def run(self) -> int:
        rc = 0
        lines = Lines()
        stdin = sys.stdin.buffer.raw if hasattr(sys.stdin.buffer, "raw") else sys.stdin.buffer
        write_status(self.a.status, state="running", started_at=int(time.time()))
        while True:
            chunk = stdin.read(65536)
            if not chunk:
                break
            for line in lines.feed(chunk):
                rc = self.handle(line, rc)
        tail = lines.rest()
        if tail:
            rc = self.handle(tail, rc)
        return rc

    def handle(self, line: bytes, rc: int) -> int:
        if line.startswith(RC_MARK):
            try:
                rc = int(line[len(RC_MARK):].strip() or b"0")
            except ValueError:
                rc = 1
            write_status(self.a.status, state="exited", last_rc=rc, exited_at=int(time.time()),
                         telegrams=self.sent, dropped=self.dropped)
            if rc != 0:
                print(f"[wmbus-bridge][WARN] external wmbusmeters ended (rc={rc}); "
                      "the main instance is not affected", file=sys.stderr, flush=True)
            return rc
        if line.lstrip().startswith(b"{"):
            self.send(line)
        else:
            text = line.decode("utf-8", "replace").rstrip("\n")
            if text.strip():
                print(f"[wmbus-bridge] [external] {text}", file=sys.stderr, flush=True)
        return rc


def merge(a: argparse.Namespace) -> int:
    ensure_fifo(a.fifo)
    rfd = os.open(a.fifo, os.O_RDONLY | os.O_NONBLOCK)
    # Held open and never written: without a writer, the FIFO would read as
    # end-of-file between two runs of the external instance.
    keep = os.open(a.fifo, os.O_WRONLY | os.O_NONBLOCK)
    sin = sys.stdin.fileno()
    out = sys.stdout.fileno()
    main_lines, ext_lines = Lines(), Lines()
    try:
        while True:
            ready, _, _ = select.select([sin, rfd], [], [])
            if sin in ready:
                data = os.read(sin, 65536)
                if not data:
                    tail = main_lines.rest()
                    if tail:
                        _write_all(out, tail)
                    return 0
                for line in main_lines.feed(data):
                    _write_all(out, line)
            if rfd in ready:
                try:
                    data = os.read(rfd, 65536)
                except BlockingIOError:
                    data = b""
                for line in ext_lines.feed(data):
                    _write_all(out, line)
    except BrokenPipeError:
        return 0
    finally:
        os.close(keep)
        os.close(rfd)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="mode", required=True)
    f = sub.add_parser("forward")
    f.add_argument("--fifo", required=True)
    f.add_argument("--status", default="")
    m = sub.add_parser("merge")
    m.add_argument("--fifo", required=True)
    a = ap.parse_args(argv)
    if a.mode == "merge":
        return merge(a)
    return Forward(a).run()


if __name__ == "__main__":
    sys.exit(main())

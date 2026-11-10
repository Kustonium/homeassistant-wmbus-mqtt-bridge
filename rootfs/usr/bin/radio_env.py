#!/usr/bin/env python3
"""Hourly reception counts per board, for the WebUI's Radio environment tab.

The RX history (esp_rx_history_hours) is off by default and keeps at most
72 hours, too little for "is this hour normal for a working day". This keeps
one row per board and hour instead, a few kilobytes for two weeks:

  [hour start (epoch), frames, weak frames, meters, 3-of-6 symbols, invalid]

- frames, weak frames (rssi_dbm <= WEAK_DBM) and meters come from the
  board's /rx messages (bridge_ledger.RxBook), one per received frame;
- the 3-of-6 symbol counts come from the 60 s diag/summary
  (esp_books.SummaryBook), t1.sym_total and t1.sym_invalid, which the ESP
  resets after every summary. A board without diagnostic_mode publishes no
  summary: its symbol columns stay 0 and the WebUI shows no error rate.

Closed hours go to RADIO_ENV_FILE (persistent storage, written once an hour
per board); the hour in progress to RADIO_ENV_NOW_FILE (the RAM runtime
directory, rewritten at most every NOW_WRITE_EVERY_S), so an SD card is not
written every minute. Both are written by the MQTT publisher process, where
both books live; without RADIO_ENV_FILE nothing is collected.
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
from typing import Any, Dict, List, Optional

KEEP_DAYS = 15
WEAK_DBM = -90
NOW_WRITE_EVERY_S = 60
# An hour whose counting started later than this into it (the add-on was
# started or restarted mid-hour) is not stored: it would pull "typical" down.
PARTIAL_HOUR_S = 300
_ROW = ("hour", "frames", "weak", "meters", "sym_total", "sym_invalid")


def _write_json(path: str, data: Any) -> None:
    d = os.path.dirname(path) or "."
    try:
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, separators=(",", ":"))
        os.replace(tmp, path)
    except OSError:
        pass


def _read_json(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


class RadioEnv:
    def __init__(self, path: str, now_path: str = "") -> None:
        self.path, self.now_path = path, now_path
        self.lock = threading.Lock()
        self.rows: Dict[str, List[List[int]]] = {}
        self.cur: Dict[str, Dict[str, Any]] = {}
        self.now_written = 0.0
        data = _read_json(path)
        if isinstance(data, dict) and isinstance(data.get("boards"), dict):
            for board, rows in data["boards"].items():
                if isinstance(rows, list):
                    self.rows[str(board)] = [r for r in rows if isinstance(r, list) and len(r) == len(_ROW)]
        # The hour in progress survives an add-on restart within that hour.
        now = _read_json(now_path) if now_path else None
        if isinstance(now, dict) and isinstance(now.get("boards"), dict):
            for board, c in now["boards"].items():
                if isinstance(c, dict) and isinstance(c.get("hour"), int):
                    self.cur[str(board)] = {
                        "hour": c["hour"], "start": int(c.get("start") or c["hour"]),
                        "frames": int(c.get("frames") or 0),
                        "weak": int(c.get("weak") or 0), "meters": set(c.get("meter_ids") or []),
                        "sym_total": int(c.get("sym_total") or 0),
                        "sym_invalid": int(c.get("sym_invalid") or 0)}

    def _bucket(self, board: str, ts: int) -> Dict[str, Any]:
        hour = ts - ts % 3600
        c = self.cur.get(board)
        if c is not None and c["hour"] != hour:
            if c["hour"] < hour:
                self._close(board, c, ts)
                c = None
            else:
                return c  # a late message for an older hour: counted where we are
        if c is None:
            c = {"hour": hour, "start": ts, "frames": 0, "weak": 0, "meters": set(), "sym_total": 0,
                 "sym_invalid": 0}
            self.cur[board] = c
        return c

    def _close(self, board: str, c: Dict[str, Any], ts: int) -> None:
        rows = self.rows.setdefault(board, [])
        if c.get("start", c["hour"]) - c["hour"] > PARTIAL_HOUR_S:
            return
        rows.append([c["hour"], c["frames"], c["weak"], len(c["meters"]), c["sym_total"], c["sym_invalid"]])
        cutoff = ts - KEEP_DAYS * 86400
        self.rows[board] = [r for r in rows if r[0] >= cutoff]
        _write_json(self.path, {"v": 1, "boards": self.rows})

    def _maybe_write_now(self, ts: float) -> None:
        if not self.now_path or ts - self.now_written < NOW_WRITE_EVERY_S:
            return
        self.now_written = ts
        _write_json(self.now_path, {"v": 1, "updated": int(ts), "boards": {
            b: {"hour": c["hour"], "start": c.get("start", c["hour"]), "frames": c["frames"],
                "weak": c["weak"], "meters": len(c["meters"]),
                "meter_ids": sorted(c["meters"]), "sym_total": c["sym_total"], "sym_invalid": c["sym_invalid"]}
            for b, c in self.cur.items()}})

    def frame(self, board: str, meter: str, rssi: Any, ts: int) -> None:
        if not board:
            return
        with self.lock:
            c = self._bucket(board, ts)
            c["frames"] += 1
            try:
                if rssi is not None and float(rssi) <= WEAK_DBM:
                    c["weak"] += 1
            except (TypeError, ValueError):
                pass
            if meter:
                c["meters"].add(str(meter))
            self._maybe_write_now(ts)

    def summary(self, board: str, payload: Any, ts: int) -> None:
        if not board or not isinstance(payload, dict) or payload.get("event") != "summary":
            return
        t1 = payload.get("t1")
        if not isinstance(t1, dict):
            return
        try:
            total, invalid = int(t1.get("sym_total") or 0), int(t1.get("sym_invalid") or 0)
        except (TypeError, ValueError):
            return
        if total <= 0:
            return
        with self.lock:
            c = self._bucket(board, ts)
            c["sym_total"] += total
            c["sym_invalid"] += min(invalid, total)
            self._maybe_write_now(ts)


_INSTANCE: Optional[RadioEnv] = None
_INIT_LOCK = threading.Lock()


def instance() -> Optional[RadioEnv]:
    """The process's one collector, from RADIO_ENV_FILE / RADIO_ENV_NOW_FILE;
    None when they are not set (the bash fallback path, tests)."""
    global _INSTANCE
    if _INSTANCE is None:
        path = os.environ.get("RADIO_ENV_FILE", "")
        if not path:
            return None
        with _INIT_LOCK:
            if _INSTANCE is None:
                _INSTANCE = RadioEnv(path, os.environ.get("RADIO_ENV_NOW_FILE", ""))
    return _INSTANCE


def load(path: str, now_path: str = "") -> Dict[str, List[List[int]]]:
    """For the WebUI: closed hours per board, plus the hour in progress as a
    last row (meters as a count) with a 7th element, the time its counting
    started. An hour in progress older than the current hour is a closed one
    the collector has not yet rolled over."""
    boards: Dict[str, List[List[int]]] = {}
    data = _read_json(path)
    if isinstance(data, dict) and isinstance(data.get("boards"), dict):
        for b, rows in data["boards"].items():
            if isinstance(rows, list):
                boards[str(b)] = [list(r) for r in rows if isinstance(r, list) and len(r) == len(_ROW)]
    now = _read_json(now_path) if now_path else None
    if isinstance(now, dict) and isinstance(now.get("boards"), dict):
        for b, c in now["boards"].items():
            if not isinstance(c, dict) or not isinstance(c.get("hour"), int):
                continue
            rows = boards.setdefault(str(b), [])
            if rows and rows[-1][0] >= c["hour"]:
                continue
            rows.append([c["hour"], int(c.get("frames") or 0), int(c.get("weak") or 0),
                         int(c.get("meters") or 0), int(c.get("sym_total") or 0),
                         int(c.get("sym_invalid") or 0), int(c.get("start") or c["hour"])])
    return boards

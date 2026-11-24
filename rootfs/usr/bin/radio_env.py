#!/usr/bin/env python3
"""Hourly reception counts per board, for the WebUI's Radio environment tab.

The RX history (esp_rx_history_hours) is off by default and keeps at most
72 hours, too little for "is this hour normal for a working day". This keeps
one row per board and hour instead, a few kilobytes for two weeks:

  [hour start (epoch), frames, weak frames, meters, 3-of-6 symbols, invalid]

- frames, weak frames (rssi_dbm <= WEAK_DBM) and meters come from the
  board's /rx messages (bridge_ledger.RxBook), one per received frame;
- the same counts per band go under "<board>|T1", "<board>|C1" and
  "<board>|S1" (the frame's mode), so the tab can show one band at a time;
  the plain "<board>" key keeps all bands together, as before;
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
# The Panel's board rate: the median of frames per minute over the last
# LIVE_MINUTES complete minutes. A short window, so a restart or a board
# moved to another antenna lowers it for a quarter of an hour, not an hour;
# a median, so one silent or one burst minute does not move it.
LIVE_MINUTES = 15
BANDS = ("T1", "C1", "S1")
BAND_SEP = "|"


def band_key(board: str, band: str) -> str:
    return f"{board}{BAND_SEP}{band}"


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
        # Per board: frames per minute over the last LIVE_MINUTES (+ the one
        # in progress) and when counting began here ("since": minutes before
        # it are unknown, not zero). In memory, written with the hour in progress.
        self.live: Dict[str, Dict[str, Any]] = {}
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

    def _bucket(self, board: str, ts: int, start: Optional[int] = None) -> Dict[str, Any]:
        hour = ts - ts % 3600
        c = self.cur.get(board)
        if c is not None and c["hour"] != hour:
            if c["hour"] < hour:
                self._close(board, c, ts)
                c = None
            else:
                return c  # a late message for an older hour: counted where we are
        if c is None:
            # A band's first frame can come late in the hour (S1 meters send
            # a few times a day): its hour counts from where the board's own
            # hour started, not from that frame.
            c = {"hour": hour, "start": ts if start is None else start, "frames": 0, "weak": 0,
                 "meters": set(), "sym_total": 0, "sym_invalid": 0}
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
            for b, c in self.cur.items()},
            "live": {b: {"since": lv["since"], "minutes": sorted([m, n] for m, n in lv["minutes"].items())}
                     for b, lv in self.live.items()}})

    def _live(self, board: str, ts: int) -> None:
        lv = self.live.get(board)
        if lv is None:
            lv = self.live[board] = {"since": ts, "minutes": {}}
        minute = ts - ts % 60
        lv["minutes"][minute] = lv["minutes"].get(minute, 0) + 1
        if len(lv["minutes"]) > LIVE_MINUTES + 3:
            cutoff = minute - (LIVE_MINUTES + 1) * 60
            lv["minutes"] = {m: n for m, n in lv["minutes"].items() if m >= cutoff}

    @staticmethod
    def _count(c: Dict[str, Any], meter: str, rssi: Any) -> None:
        c["frames"] += 1
        try:
            if rssi is not None and float(rssi) <= WEAK_DBM:
                c["weak"] += 1
        except (TypeError, ValueError):
            pass
        if meter:
            c["meters"].add(str(meter))

    def frame(self, board: str, meter: str, rssi: Any, ts: int, mode: Any = None) -> None:
        if not board:
            return
        with self.lock:
            c = self._bucket(board, ts)
            self._count(c, meter, rssi)
            self._live(board, ts)
            if mode in BANDS:
                self._count(self._bucket(band_key(board, mode), ts, c.get("start", c["hour"])), meter, rssi)
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
            # The symbols are T1's (3-of-6 is T-mode coding): the T1 band
            # gets them too.
            ct = self._bucket(band_key(board, "T1"), ts, c.get("start", c["hour"]))
            ct["sym_total"] += total
            ct["sym_invalid"] += min(invalid, total)
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


def live_rate(now_path: str, board: str, now: int) -> Optional[float]:
    """For the WebUI: the median of frames per minute over the last
    LIVE_MINUTES complete minutes of one board, a minute without frames
    counting as 0; None until that many minutes have been counted (after an
    add-on start) or without the file. Minutes before "since" are unknown and
    are left out, never counted as 0."""
    data = _read_json(now_path) if now_path else None
    lv = data.get("live", {}).get(board) if isinstance(data, dict) and isinstance(data.get("live"), dict) else None
    if not isinstance(lv, dict):
        return None
    try:
        since = int(lv.get("since") or 0)
        counts = {int(m): int(n) for m, n in lv.get("minutes") or []}
        # The file is written at most once a minute: a minute that was still
        # in progress when it was written is not complete in it.
        ref = min(now, int(data.get("updated") or now))
    except (TypeError, ValueError):
        return None
    last = ref - ref % 60 - 60          # the last complete minute in the file
    first = last - (LIVE_MINUTES - 1) * 60
    if first < since - since % 60 + 60:  # the minute counting began in is partial
        return None
    vals = sorted(counts.get(m, 0) for m in range(first, last + 60, 60))
    mid = len(vals) // 2
    return float(vals[mid]) if len(vals) % 2 else (vals[mid - 1] + vals[mid]) / 2.0

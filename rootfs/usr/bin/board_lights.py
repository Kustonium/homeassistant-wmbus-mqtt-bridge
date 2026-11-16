#!/usr/bin/env python3
"""Status lights per board ("Status lights" on the Boards tab, dots on the Panel).

Four lights, each answering one question a user can act on:

  alive      is the board running?        /health pulse, restarts in 24 h
  radio      does the radio chip work?    interrupts (irq_fired, irq_start.no_data)
  keeps_up   does the receiver keep up?   rx_path.fifo_overrun, truncated
  reception  is reception clean?          dropped / total, 3-of-6 invalid symbols

A light remembers a day: an overrun at 3 in the night still shows red in the
morning. Rare events otherwise scroll out of the log before anyone sees them,
and the board resets its counters after every 60 s summary.

This module has two halves:

- BoardLights, the collector. It lives in the MQTT publisher process next to
  radio_env, fed by esp_books.SummaryBook with every 60 s diag/summary. It
  keeps one row per board and hour:

    [hour, summaries, irq, irq_no_data, total, dropped, truncated, overrun,
     sym_total, sym_invalid]

  plus the time of the last interrupt, overrun, truncated frame and summary.
  Closed hours go to BOARD_LIGHTS_FILE (persistent, written once an hour), the
  hour in progress to BOARD_LIGHTS_NOW_FILE (RAM, at most once a minute).
  KEEP_DAYS of hours are kept: the last day sets the colour, the days before
  it what "typical" means for that board.

- evaluate(), the verdict, called by the WebUI with what it already knows
  about the board (health pulse, restarts, listen mode).

S1 needs its own rules: S1 meters send rarely and on a schedule that differs
between installations, so an hour without a single frame is normal there and
must never look like a failure. A board listening to S1 only is judged "alive"
by its pulse alone, and "radio" only after RADIO_SILENT_S1_S without an
interrupt. "keeps_up" and "reception" sum events, so empty hours add nothing.

A board without diagnostic_mode publishes no summary: its radio, keeps_up and
reception lights stay "none" (no data), never green.
"""

from __future__ import annotations

import json
import os
import tempfile
import threading
from typing import Any, Dict, List, Optional

KEEP_DAYS = 7
DAY_S = 86400
NOW_WRITE_EVERY_S = 60
_ROW = ("hour", "summaries", "irq", "no_data", "total", "dropped", "truncated", "overrun",
        "sym_total", "sym_invalid")
_LAST = ("irq", "overrun", "truncated", "summary")

# alive: a pulse older than this is a board that stopped publishing (the
# pulse comes every 60 s; webui.py uses the same 150 s for "alive").
PULSE_STALE_S = 150
# Same thresholds as the Diagnostics table (webui.ESP_DIAG_REBOOT_*): one
# restart a day is reflashing or a power blip, not a symptom.
REBOOT_WARN = 2
REBOOT_BAD = 3
# radio: no interrupt at all for this long while the board itself is alive
# and still sending summaries means a deaf radio. S1 is allowed hours of
# silence (see the module docstring).
RADIO_SILENT_S = 30 * 60
RADIO_SILENT_S1_S = 6 * 3600
# Summaries older than this: the board stopped sending them (or diagnostic
# mode was switched off); its silence then says nothing about the radio.
SUMMARY_STALE_S = 300
# radio: interrupts that found no data, worth a look from this share on.
NO_DATA_WARN_PCT = 5.0
NO_DATA_WARN_MIN = 10
# reception: compared with the board's own hours before the last day. Until
# the board has such hours it is "learning" and never yellow: a board in
# `both` normally rejects 10-20 % (weak C1, noise), so any fixed threshold
# would light up healthy boards for their first days.
DROP_WARN_MIN_PCT = 10.0
SYM_WARN_MIN_PCT = 5.0
TYP_FACTOR = 2.0
TYP_MIN_HOURS = 12        # earlier hours with frames before "typical" is used
TYP_MIN_FRAMES = 20       # an hour with fewer frames says nothing about its rate
MIN_FRAMES = 100          # in the last day, before reception is judged at all
MIN_SYMBOLS = 200


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


def _int(v: Any) -> int:
    try:
        return max(0, int(v or 0))
    except (TypeError, ValueError):
        return 0


def _rows_of(raw: Any) -> List[List[int]]:
    if not isinstance(raw, list):
        return []
    return [[_int(x) for x in r] for r in raw if isinstance(r, list) and len(r) == len(_ROW)]


def _last_of(raw: Any) -> Dict[str, int]:
    raw = raw if isinstance(raw, dict) else {}
    return {k: _int(raw.get(k)) for k in _LAST}


class BoardLights:
    def __init__(self, path: str, now_path: str = "") -> None:
        self.path, self.now_path = path, now_path
        self.lock = threading.Lock()
        self.rows: Dict[str, List[List[int]]] = {}
        self.cur: Dict[str, List[int]] = {}
        self.last: Dict[str, Dict[str, int]] = {}
        self.now_written = 0.0
        data = _read_json(path)
        if isinstance(data, dict):
            for b, rows in (data.get("boards") or {}).items():
                self.rows[str(b)] = _rows_of(rows)
            for b, last in (data.get("last") or {}).items():
                self.last[str(b)] = _last_of(last)
        # The hour in progress survives an add-on restart within that hour.
        now = _read_json(now_path) if now_path else None
        if isinstance(now, dict):
            for b, row in (now.get("boards") or {}).items():
                r = _rows_of([row])
                if r:
                    self.cur[str(b)] = r[0]
            for b, last in (now.get("last") or {}).items():
                mine, theirs = self.last.setdefault(str(b), _last_of({})), _last_of(last)
                for k in _LAST:
                    mine[k] = max(mine[k], theirs[k])

    def _bucket(self, board: str, ts: int) -> List[int]:
        hour = ts - ts % 3600
        c = self.cur.get(board)
        if c is not None and c[0] != hour:
            if c[0] > hour:
                return c  # a late summary for an older hour: counted where we are
            self._close(board, c, ts)
            c = None
        if c is None:
            c = [hour] + [0] * (len(_ROW) - 1)
            self.cur[board] = c
        return c

    def _close(self, board: str, c: List[int], ts: int) -> None:
        rows = self.rows.setdefault(board, [])
        rows.append(list(c))
        cutoff = ts - KEEP_DAYS * DAY_S
        self.rows[board] = [r for r in rows if r[0] >= cutoff]
        _write_json(self.path, {"v": 1, "boards": self.rows, "last": self.last})

    def _maybe_write_now(self, ts: float) -> None:
        if not self.now_path or ts - self.now_written < NOW_WRITE_EVERY_S:
            return
        self.now_written = ts
        _write_json(self.now_path, {"v": 1, "updated": int(ts), "boards": self.cur, "last": self.last})

    def summary(self, board: str, payload: Any, ts: int) -> None:
        """One 60 s diag/summary of `board`, received at `ts`."""
        if not board or not isinstance(payload, dict) or payload.get("event") != "summary":
            return
        rx = payload.get("rx_path") if isinstance(payload.get("rx_path"), dict) else {}
        start = rx.get("irq_start") if isinstance(rx.get("irq_start"), dict) else {}
        t1 = payload.get("t1") if isinstance(payload.get("t1"), dict) else {}
        irq = _int(payload.get("irq_fired", rx.get("irq_fired")))
        vals = {
            "irq": irq,
            "no_data": min(_int(start.get("no_data")), irq) if irq else _int(start.get("no_data")),
            "total": _int(payload.get("total")),
            "dropped": _int(payload.get("dropped")),
            "truncated": _int(payload.get("truncated")),
            "overrun": _int(rx.get("fifo_overrun")),
            "sym_total": _int(t1.get("sym_total")),
            "sym_invalid": _int(t1.get("sym_invalid")),
        }
        vals["sym_invalid"] = min(vals["sym_invalid"], vals["sym_total"])
        with self.lock:
            c = self._bucket(board, ts)
            c[1] += 1
            for i, k in enumerate(_ROW[2:], start=2):
                c[i] += vals[k]
            last = self.last.setdefault(board, _last_of({}))
            last["summary"] = ts
            if vals["irq"]:
                last["irq"] = ts
            if vals["overrun"]:
                last["overrun"] = ts
            if vals["truncated"]:
                last["truncated"] = ts
            self._maybe_write_now(ts)


_INSTANCE: Optional[BoardLights] = None
_INIT_LOCK = threading.Lock()


def instance() -> Optional[BoardLights]:
    """The process's one collector, from BOARD_LIGHTS_FILE / BOARD_LIGHTS_NOW_FILE;
    None when they are not set (the bash fallback path, tests)."""
    global _INSTANCE
    if _INSTANCE is None:
        path = os.environ.get("BOARD_LIGHTS_FILE", "")
        if not path:
            return None
        with _INIT_LOCK:
            if _INSTANCE is None:
                _INSTANCE = BoardLights(path, os.environ.get("BOARD_LIGHTS_NOW_FILE", ""))
    return _INSTANCE


def load(path: str, now_path: str = "") -> Dict[str, Any]:
    """For the WebUI: {"boards": {board: rows incl. the hour in progress},
    "last": {board: {irq, overrun, truncated, summary}}}."""
    boards: Dict[str, List[List[int]]] = {}
    last: Dict[str, Dict[str, int]] = {}
    data = _read_json(path)
    if isinstance(data, dict):
        for b, rows in (data.get("boards") or {}).items():
            boards[str(b)] = _rows_of(rows)
        for b, l in (data.get("last") or {}).items():
            last[str(b)] = _last_of(l)
    now = _read_json(now_path) if now_path else None
    if isinstance(now, dict):
        for b, row in (now.get("boards") or {}).items():
            r = _rows_of([row])
            if not r:
                continue
            rows = boards.setdefault(str(b), [])
            if rows and rows[-1][0] >= r[0][0]:
                continue
            rows.append(r[0])
        for b, l in (now.get("last") or {}).items():
            mine, theirs = last.setdefault(str(b), _last_of({})), _last_of(l)
            for k in _LAST:
                mine[k] = max(mine[k], theirs[k])
    return {"boards": boards, "last": last}


def _pct(a: int, b: int) -> float:
    return round(100.0 * a / b, 1) if b > 0 else 0.0


def _median(xs: List[float]) -> float:
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2


def _typical(rows: List[List[int]], num: int, den: int, min_den: int) -> Optional[float]:
    vals = [100.0 * r[num] / r[den] for r in rows if r[den] >= min_den]
    return round(_median(vals), 1) if len(vals) >= TYP_MIN_HOURS else None


def evaluate(rows: List[List[int]], last: Dict[str, int], now: int, *,
             pulse_age_s: Optional[int], reboots_24h: int, last_boot: int,
             s1_only: bool) -> Dict[str, Dict[str, Any]]:
    """The four lights of one board. Each is {"state": ok|warn|bad|none} plus
    the numbers the WebUI shows next to a yellow or red light."""
    last = _last_of(last)
    day = [r for r in rows if r[0] > now - DAY_S]
    before = [r for r in rows if now - KEEP_DAYS * DAY_S <= r[0] <= now - DAY_S]
    s = [sum(r[i] for r in day) for i in range(len(_ROW))]
    summaries, irq, no_data, total, dropped, truncated, overrun, sym_total, sym_invalid = s[1:]
    out: Dict[str, Dict[str, Any]] = {}

    # alive
    if pulse_age_s is None:
        out["alive"] = {"state": "none"}
    else:
        st = "ok"
        if pulse_age_s > PULSE_STALE_S or reboots_24h >= REBOOT_BAD:
            st = "bad"
        elif reboots_24h >= REBOOT_WARN:
            st = "warn"
        out["alive"] = {"state": st, "reboots": reboots_24h, "last_boot": last_boot,
                        "pulse_age_s": pulse_age_s, "stale": pulse_age_s > PULSE_STALE_S}

    if summaries == 0:
        for k in ("radio", "keeps_up", "reception"):
            out[k] = {"state": "none"}
        return out

    # radio
    silent_limit = RADIO_SILENT_S1_S if s1_only else RADIO_SILENT_S
    summaries_fresh = now - last["summary"] <= SUMMARY_STALE_S
    board_alive = pulse_age_s is not None and pulse_age_s <= PULSE_STALE_S
    silent_s = now - last["irq"] if last["irq"] else None
    deaf = summaries_fresh and board_alive and (silent_s is None or silent_s > silent_limit)
    if last["irq"] == 0 and summaries < silent_limit // 60:
        deaf = False  # too few summaries since collection began to call it deaf
    no_data_pct = _pct(no_data, irq)
    st = "ok"
    if deaf:
        st = "bad"
    elif no_data >= NO_DATA_WARN_MIN and no_data_pct >= NO_DATA_WARN_PCT:
        st = "warn"
    out["radio"] = {"state": st, "irq_per_min": round(irq / summaries, 1), "no_data": no_data,
                    "no_data_pct": no_data_pct, "silent_s": silent_s, "deaf": deaf}

    # keeps_up
    events = overrun + truncated
    out["keeps_up"] = {"state": "bad" if events else "ok", "overrun": overrun, "truncated": truncated,
                       "last": max(last["overrun"], last["truncated"])}

    # reception
    drop_pct = _pct(dropped, total)
    sym_pct = _pct(sym_invalid, sym_total)
    drop_typ = _typical(before, 5, 4, TYP_MIN_FRAMES)
    sym_typ = _typical(before, 9, 8, MIN_SYMBOLS)
    st = "ok"
    drop_bad = (drop_typ is not None and total >= MIN_FRAMES
                and drop_pct >= max(DROP_WARN_MIN_PCT, TYP_FACTOR * drop_typ))
    sym_bad = (sym_typ is not None and sym_total >= MIN_SYMBOLS
               and sym_pct >= max(SYM_WARN_MIN_PCT, TYP_FACTOR * sym_typ))
    if total < MIN_FRAMES and sym_total < MIN_SYMBOLS:
        st = "none"
    elif drop_bad or sym_bad:
        st = "warn"
    # drop_bad / sym_bad: which of the two turned it yellow, the only one
    # worth showing next to the light.
    out["reception"] = {"state": st, "drop_pct": drop_pct, "drop_typ": drop_typ, "drop_bad": drop_bad,
                        "sym_pct": sym_pct if sym_total >= MIN_SYMBOLS else None, "sym_typ": sym_typ,
                        "sym_bad": sym_bad, "learning": drop_typ is None and sym_typ is None}
    return out

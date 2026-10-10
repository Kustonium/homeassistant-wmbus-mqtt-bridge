#!/usr/bin/env python3
"""One persistent MQTT connection for everything the add-on publishes.

Every publish used to be its own mosquitto_pub: a new process, a TCP
connection, a login and a disconnect - several a minute, each a few lines in
the broker's log. This process keeps one connection open instead.

bash hands it messages over a loopback TCP socket, which `/dev/tcp` opens
without forking (see mqtt_pub in bridge-lib/12-pipeline.sh). One message per
connection, framed so that any payload passes unchanged:

    PUB <retain 0|1> <payload length in bytes> <topic>\\n<payload>\\n

Connections are served one at a time, in the order they were opened, so the
messages of one writer keep their order.

The broker side is MQTT 3.1.1 with the same profile as mosquitto_pub had in
this add-on: QoS 0, clean session, optional user name and password, no TLS.
The client id is "wmbus_bridge_pub_<random>" - readable in the broker log,
and never shared by two instances (a shared id makes brokers drop one of them
every few seconds). While the broker is unreachable messages are kept in a
bounded queue and sent in order once it is back.
"""

import argparse
import collections
import os
import secrets
import select
import signal
import socket
import struct
import sys
import time

KEEPALIVE_S = 60
QUEUE_MAX = 2000
RECONNECT_MAX_S = 30
# A broker that refused $SYS is asked again after this long (BROKER_SYS_DENIED_RETRY_S).
SYS_RETRY_S = 3600
# What one RAW reader may have waiting before further telegrams are dropped
# for it (a reader that stopped reading must not grow this process).
RAW_BACKLOG_MAX = 4 * 1024 * 1024
FRAME_MAX = 4 * 1024 * 1024


def log(msg):
    print(f"[wmbus-bridge] mqtt publisher: {msg}", file=sys.stderr, flush=True)


def _remaining_length(n):
    out = bytearray()
    while True:
        byte = n % 128
        n //= 128
        if n:
            byte |= 0x80
        out.append(byte)
        if not n:
            return bytes(out)


def _string(b):
    return struct.pack("!H", len(b)) + b


def connect_packet(client_id, username=None, password=None, keepalive=KEEPALIVE_S):
    flags = 0x02  # clean session
    payload = _string(client_id.encode())
    if username:
        flags |= 0x80
        payload += _string(username.encode())
        # MQTT 3.1.1 allows a password only together with a user name.
        if password:
            flags |= 0x40
            payload += _string(password.encode())
    variable = _string(b"MQTT") + bytes([4, flags]) + struct.pack("!H", keepalive)
    body = variable + payload
    return bytes([0x10]) + _remaining_length(len(body)) + body


def publish_packet(topic, payload, retain):
    body = _string(topic) + payload
    return bytes([0x30 | (0x01 if retain else 0)]) + _remaining_length(len(body)) + body


def _take_packet(buf):
    """(first byte, body, rest) of the first complete MQTT packet in buf, or None."""
    if len(buf) < 2:
        return None
    mult, length, pos = 1, 0, 1
    while True:
        if pos >= len(buf) or pos > 4:
            return None if pos < 5 else (buf[0], b"", b"")  # 5+ length bytes: malformed
        byte = buf[pos]
        length += (byte & 0x7F) * mult
        pos += 1
        if not byte & 0x80:
            break
        mult *= 128
    if len(buf) < pos + length:
        return None
    return buf[0], buf[pos:pos + length], buf[pos + length:]


def topic_matches(flt, topic):
    """MQTT topic filter matching ('+' one level, '#' the rest); a '$' topic
    matches no filter that starts with a wildcard."""
    if topic.startswith(b"$") and flt[:1] in (b"+", b"#"):
        return False
    f_parts, t_parts = flt.split(b"/"), topic.split(b"/")
    for i, part in enumerate(f_parts):
        if part == b"#":
            return True
        if i >= len(t_parts) or (part != b"+" and part != t_parts[i]):
            return False
    return len(f_parts) == len(t_parts)


def filter_covers(wide, narrow):
    """True when every topic matching filter narrow also matches filter wide."""
    w_parts, n_parts = wide.split(b"/"), narrow.split(b"/")
    for i, part in enumerate(w_parts):
        if part == b"#":
            # '#' also matches the parent level, but not a '$' topic from the root.
            return not (i == 0 and narrow[:1] == b"$")
        if i >= len(n_parts):
            return False
        if part == b"+":
            if n_parts[i] == b"#" or (i == 0 and n_parts[i][:1] == b"$"):
                return False
        elif part != n_parts[i]:
            return False
    return len(w_parts) == len(n_parts)


PINGREQ = b"\xc0\x00"
DISCONNECT = b"\xe0\x00"
CONNACK_REASONS = {
    1: "unacceptable protocol version",
    2: "client id rejected",
    3: "server unavailable",
    4: "bad user name or password",
    5: "not authorized",
}


def parse_frame(data):
    """Split one framed message off the front of data.

    Returns ((topic, payload, retain), rest), or (None, data) while the frame
    is incomplete. Raises ValueError on a malformed header.
    """
    nl = data.find(b"\n")
    if nl < 0:
        if len(data) > 4096:
            raise ValueError("header too long")
        return None, data
    parts = data[:nl].split(b" ", 3)
    if len(parts) != 4 or parts[0] != b"PUB" or parts[1] not in (b"0", b"1") or not parts[3]:
        raise ValueError("bad header %r" % data[:nl][:80])
    try:
        length = int(parts[2])
    except ValueError:
        raise ValueError("bad length %r" % parts[2][:20]) from None
    if length < 0 or length > FRAME_MAX:
        raise ValueError("bad length %d" % length)
    end = nl + 1 + length
    if len(data) < end + 1:
        return None, data
    if data[end:end + 1] != b"\n":
        raise ValueError("payload length does not match")
    return (parts[3], data[nl + 1:end], parts[1] == b"1"), data[end + 1:]


def parse_message(data):
    """Split one message of any kind off the front of data.

    PUB <retain> <bytes> <topic>\\n<payload>\\n -> ("PUB", topic, payload, retain)
    DEC <bytes>\\n<exclude patterns>\\n<json>\\n  -> ("DEC", patterns, json)
        a decoded telegram of a configured meter: Discovery and state are
        built here (wmbus_discovery.py), as publish_decoded_json does in bash
    RST\\n                                      -> ("RST",)
        a new decode pipeline: the Discovery caches start empty, as in bash

    Returns (None, data) while the message is incomplete.
    """
    if data.startswith(b"PUB "):
        msg, rest = parse_frame(data)
        return (None, data) if msg is None else (("PUB",) + msg, rest)
    nl = data.find(b"\n")
    if nl < 0:
        if len(data) > 4096:
            raise ValueError("header too long")
        return None, data
    head = data[:nl]
    if head == b"RST":
        return ("RST",), data[nl + 1:]
    parts = head.split(b" ")
    if len(parts) != 2 or parts[0] != b"DEC" or not parts[1].isdigit():
        raise ValueError("bad header %r" % head[:80])
    length = int(parts[1])
    if length > FRAME_MAX:
        raise ValueError("bad length %d" % length)
    end = nl + 1 + length
    if len(data) < end + 1:
        return None, data
    if data[end:end + 1] != b"\n":
        raise ValueError("payload length does not match")
    patterns, sep, line = data[nl + 1:end].partition(b"\n")
    if not sep:
        raise ValueError("DEC without patterns line")
    return ("DEC", patterns, line), data[end + 1:]


def make_books(spec):
    """The bookkeeping of the ESP subscribers, run here instead of
    `mosquitto_sub | bridge_ledger.py <mode>` per subscription.

    spec (MQTT_PUBLISHER_BOOKS, JSON from start_mqtt_publisher) maps a mode to
    its filter, whether retained messages are dropped (mosquitto_sub -R) and the
    files the mode writes. Returns [(filter, no_retained, deliver, book)].
    """
    import bridge_ledger as bl
    out = []
    for mode, cfg in spec.items():
        if mode == "rssi":
            book = bl.RssiBook(cfg["meter_dir"], cfg["rssi_file"])
        elif mode == "rx":
            book = bl.RxBook(cfg["reception_file"], cfg["mode_file"], cfg["history_file"],
                             cfg["sequence_file"], cfg["boots_file"], cfg["clock_file"])
        elif mode == "tracker":
            book = bl.TrackerBook(int(cfg["dev_pos"]), cfg["devices_file"], cfg["meter_device_file"],
                                  cfg["reception_file"], cfg["history_file"])
        elif mode in ("health", "meters", "meter_snapshot"):
            import esp_books
            cls = {"health": esp_books.HealthBook, "meters": esp_books.MetersBook,
                   "meter_snapshot": esp_books.MeterSnapshotBook}[mode]
            book = cls(cfg["file"] if "file" in cfg else cfg["health_file"])
        elif mode == "summary":
            import esp_books
            book = esp_books.SummaryBook(cfg["file"])
        elif mode == "meter_window":
            import esp_books
            book = esp_books.MeterWindowBook(cfg["file"])
        elif mode == "ha_presence":
            import esp_books
            book = esp_books.HaPresenceBook(cfg["presence_file"])
        elif mode == "raw_feed":
            book = RawFeed()
            deliver = book.deliver
            out.append((cfg["filter"].encode(), bool(cfg.get("no_retained")), deliver, book))
            continue
        elif mode == "broker_info":
            import esp_books
            book = esp_books.BrokerInfoBook(cfg["info_file"])
            cfg = dict(cfg, filters=list(book.FILTERS))
        elif mode == "diag_events":
            import esp_books
            book = esp_books.DiagEventsBook(cfg["events_file"], cfg["suggestion_file"], cfg["boot_file"],
                                            cfg["config_file"], cfg.get("history_file", ""),
                                            bool(cfg.get("history_enabled")))
        else:
            raise ValueError(f"unknown book {mode!r}")
        deliver = _deliver_lines(book, mode, payload_only=cfg.get("format") == "payload",
                                 with_retained=cfg.get("format") == "retained")
        for flt in cfg.get("filters") or [cfg["filter"]]:
            out.append((flt.encode(), bool(cfg.get("no_retained")), deliver, book))
    return out


class RawFeed:
    """RAW_TOPIC payloads for the decoder and the parallel LISTEN instance.

    Each connection to the raw port reads what `mosquitto_sub -t RAW_TOPIC
    -F '%p'` printed (the payload and a newline, retained ones dropped when
    ignore_retained is on), so the two wmbusmeters pipelines need no broker
    connection of their own. Nothing is buffered for a reader before it
    connects, as nothing was before mosquitto_sub subscribed.
    """

    def __init__(self):
        self.readers = []  # [socket, pending bytes, dropped count]

    def add(self, conn):
        conn.setblocking(False)
        self.readers.append([conn, bytearray(), 0])

    def deliver(self, _topic, payload, _retain=False):
        line = payload + b"\n"
        for r in self.readers:
            if len(r[1]) + len(line) > RAW_BACKLOG_MAX:
                if not r[2]:
                    log("a RAW reader is not keeping up; telegrams dropped for it until it does")
                r[2] += 1
                continue
            if r[2]:
                log(f"a RAW reader caught up; {r[2]} telegram(s) were dropped for it")
                r[2] = 0
            r[1] += line
        self.flush()

    def flush(self):
        for r in list(self.readers):
            if not r[1]:
                continue
            try:
                n = r[0].send(r[1])
            except BlockingIOError:
                continue
            except OSError:
                self.drop(r[0])
                continue
            del r[1][:n]

    def waiting(self):
        return [r[0] for r in self.readers if r[1]]

    def socks(self):
        return [r[0] for r in self.readers]

    def on_readable(self, conn):
        """A reader only reads; data or EOF from it means it is gone."""
        try:
            data = conn.recv(4096)
        except BlockingIOError:
            return
        except OSError:
            data = b""
        if not data:
            self.drop(conn)

    def drop(self, conn):
        self.readers = [r for r in self.readers if r[0] is not conn]
        try:
            conn.close()
        except OSError:
            pass


def _deliver_lines(book, mode, payload_only=False, with_retained=False):
    """Hand one message to a book as `mosquitto_sub -F '%t\\t%p'` would have
    printed it and bridge_ledger.run() read it: one line, or several when
    the payload holds newlines (the later ones then carry no topic). With
    payload_only (`-F '%p'`, read whole with `IFS= read -r`), each payload
    line is handed over as it is, with the topic for reference. With
    with_retained (`-F '%r\\t%t\\t%p'`) the book gets the retained flag
    first: book(retained, topic, payload)."""
    import bridge_ledger as bl

    def deliver(topic, payload, retain=False):
        if with_retained:
            data = (b"1" if retain else b"0") + b"\t" + topic + b"\t" + payload + b"\n"
        else:
            data = (b"" if payload_only else topic + b"\t") + payload + b"\n"
        start = 0
        while start < len(data):
            nl = data.find(b"\n", start)
            line = data[start:nl + 1]
            start = nl + 1
            if with_retained:
                import esp_books
                fields = esp_books.split_retained_line(line)
                t = fields[1]
            else:
                t, p = (topic, line[:-1]) if payload_only else bl.split_message(line)
                fields = (t, p)
            try:
                book(*fields)
            except Exception as exc:  # one bad message must not stop the bookkeeping
                print(f"[wmbus-bridge][WARN] ledger {mode}: message on {t!r} skipped: {exc!r}",
                      file=sys.stderr, flush=True)
            deferred = getattr(book, "deferred", None)
            if deferred is not None:
                deferred.flush_if_due()
    return deliver


class _TestState:
    """Clock, average telegram interval and options for test_publish_contract.sh.

    MQTT_PUBLISHER_TEST_STATE names a file of KEY=VALUE lines (NOW, SEEN_AVG
    and the options of wmbus_discovery.Config), read before every decoded
    telegram: the test changes them between scenarios, the add-on sets them
    once at start. Unset in the add-on.
    """

    def __init__(self, path):
        self.path = path
        self.values = {}

    def refresh(self, discovery, wmbus_discovery):
        values = {}
        try:
            with open(self.path, encoding="utf-8") as fh:
                for line in fh:
                    key, sep, value = line.rstrip("\n").partition("=")
                    if sep:
                        values[key] = value
        except OSError:
            pass
        self.values = values
        discovery.cfg = wmbus_discovery.Config({**os.environ, **values})

    def epoch(self):
        return int(self.values.get("NOW") or time.time())

    def seen_avg(self, _mid):
        return int(self.values.get("SEEN_AVG") or 0)


class Broker:
    """The broker connection: connect, publish, keepalive, reconnect."""

    def __init__(self, host, port, username, password, client_id):
        self.addr = (host, port)
        self.username = username
        self.password = password
        self.client_id = client_id
        self.sock = None
        self.queue = collections.deque(maxlen=QUEUE_MAX)
        self.dropped = 0
        self.next_attempt = 0.0
        self.backoff = 1.0
        self.last_sent = 0.0
        self.ping_sent = 0.0
        self.inbuf = b""
        self.last_error = ""
        # (filter, drop retained messages, deliver(topic, payload, retain)).
        self.subscriptions = []
        # SUBSCRIBE packet id -> the filters it asked for (SUBACK answers
        # per position). Packet 1 holds the ordinary filters, packet 2 the
        # $SYS ones (see subscribe_sys).
        self.pending = {}
        self.sys_held_until = 0.0
        self.sys_retry_s = SYS_RETRY_S
        self.on_sys_refused = None  # called when the broker refuses all of $SYS

    def connected(self):
        return self.sock is not None

    def _fail(self, why):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
            log(f"connection to {self.addr[0]}:{self.addr[1]} lost ({why}), reconnecting")
            if 2 in self.pending:
                # Lost while the broker had $SYS to answer: a broker set to
                # disconnect on an ACL refusal does this. Not asked again for
                # an hour, or every reconnect would end the same way.
                self._sys_refused(f"connection lost after asking for {self.pending[2][0].decode()}")
            self.pending = {}
        elif why != self.last_error:
            log(f"cannot connect to {self.addr[0]}:{self.addr[1]} ({why}), retrying")
        self.last_error = why
        self.inbuf = b""
        self.next_attempt = time.monotonic() + self.backoff
        self.backoff = min(self.backoff * 2, RECONNECT_MAX_S)

    def try_connect(self):
        if self.sock is not None or time.monotonic() < self.next_attempt:
            return
        sock = None
        try:
            sock = socket.create_connection(self.addr, timeout=10)
            sock.sendall(connect_packet(self.client_id, self.username, self.password))
            ack = b""
            while len(ack) < 4:
                chunk = sock.recv(4 - len(ack))
                if not chunk:
                    raise OSError("closed before CONNACK")
                ack += chunk
            if ack[0] != 0x20:
                raise OSError("unexpected reply 0x%02x" % ack[0])
            if ack[3] != 0:
                raise OSError("refused: " + CONNACK_REASONS.get(ack[3], str(ack[3])))
            sock.settimeout(10)
        except OSError as exc:
            if sock is not None:
                sock.close()
            self._fail(str(exc) or exc.__class__.__name__)
            return
        self.sock = sock
        self.backoff = 1.0
        self.last_error = ""
        self.last_sent = self.ping_sent = 0.0
        log(f"connected to {self.addr[0]}:{self.addr[1]} as {self.client_id}")
        if self.dropped:
            log(f"{self.dropped} message(s) dropped while the broker was unreachable")
            self.dropped = 0
        self.subscribe_all()
        self.flush()

    def publish(self, topic, payload, retain):
        if len(self.queue) == self.queue.maxlen:
            self.dropped += 1
        self.queue.append(publish_packet(topic, payload, retain))
        self.flush()

    def flush(self):
        while self.sock is not None and self.queue:
            try:
                self.sock.sendall(self.queue[0])
            except OSError as exc:
                self._fail(str(exc) or "send failed")
                return
            self.queue.popleft()
            self.last_sent = time.monotonic()

    def on_readable(self):
        try:
            data = self.sock.recv(65536)
        except OSError as exc:
            self._fail(str(exc) or "receive failed")
            return
        if not data:
            self._fail("closed by broker")
            return
        self.inbuf += data
        while True:
            packet = _take_packet(self.inbuf)
            if packet is None:
                return
            first, body, self.inbuf = packet
            kind = first >> 4
            if kind == 13:  # PINGRESP
                self.ping_sent = 0.0
            elif kind == 3:  # PUBLISH
                self._on_publish(first, body)
            elif kind == 9:  # SUBACK
                pid = struct.unpack("!H", body[:2])[0] if len(body) >= 2 else 0
                sent = self.pending.pop(pid, [])
                refused = [sent[i] for i, code in enumerate(body[2:]) if code & 0x80 and i < len(sent)]
                if pid == 2 and sent and len(refused) == len(sent):
                    self._sys_refused("refused by the broker")
                elif refused:
                    log("subscription refused by the broker: "
                        + ", ".join(f.decode("utf-8", "replace") for f in refused))
                if pid == 1:
                    self.subscribe_sys()

    def _on_publish(self, first, body):
        qos, retain = (first >> 1) & 0x03, bool(first & 0x01)
        tlen = struct.unpack("!H", body[:2])[0]
        topic, pos = body[2:2 + tlen], 2 + tlen
        if qos:
            pid = body[pos:pos + 2]
            pos += 2
            if qos == 1:
                try:
                    self.sock.sendall(b"\x40\x02" + pid)  # PUBACK
                except OSError as exc:
                    self._fail(str(exc) or "send failed")
                    return
        payload = body[pos:]
        for flt, no_retained, deliver in self.subscriptions:
            if (no_retained and retain) or not topic_matches(flt, topic):
                continue
            deliver(topic, payload, retain)

    def broker_filters(self):
        """The filters subscribed at the broker: those no other filter covers.

        Messages are routed here, to every matching filter, so one copy is
        enough; a broker may send one per matching subscription (MQTT 3.1.1
        allows either), and wmbus/+/diag/# overlaps wmbus/+/diag/summary."""
        flts = list(dict.fromkeys(flt for flt, _, _ in self.subscriptions if flt[:1] != b"$"))
        return [f for f in flts if not any(o != f and filter_covers(o, f) for o in flts)]

    def sys_filters(self):
        return list(dict.fromkeys(flt for flt, _, _ in self.subscriptions if flt[:1] == b"$"))

    def _send_subscribe(self, pid, flts):
        body = struct.pack("!H", pid) + b"".join(_string(flt) + b"\x00" for flt in flts)
        try:
            self.sock.sendall(bytes([0x82]) + _remaining_length(len(body)) + body)
        except OSError as exc:
            self._fail(str(exc) or "send failed")
            return
        self.pending[pid] = flts
        self.last_sent = time.monotonic()

    def subscribe_sys(self):
        """$SYS on its own SUBSCRIBE, once the ordinary filters are granted.

        A broker may refuse it (EMQX's default ACL gives $SYS to localhost
        clients only) or, configured so, drop the connection for asking; the
        ordinary subscriptions must not depend on it, and a refusal is asked
        again only after sys_retry_s, as the bash subscriber did."""
        flts = self.sys_filters()
        if not flts or self.sock is None or 2 in self.pending or time.monotonic() < self.sys_held_until:
            return
        self._send_subscribe(2, flts)

    def _sys_refused(self, why):
        self.sys_held_until = time.monotonic() + self.sys_retry_s
        log(f"$SYS not available ({why}); asked again in {int(self.sys_retry_s)} s")
        if self.on_sys_refused is not None:
            try:
                self.on_sys_refused()
            except Exception as exc:
                log(f"could not record the $SYS refusal ({exc})")

    def subscribe_all(self):
        """Subscribe to every filter (QoS 0), after each (re)connect: clean session."""
        if not self.subscriptions or self.sock is None:
            return
        flts = self.broker_filters()
        if flts:
            self._send_subscribe(1, flts)  # $SYS follows its SUBACK
        else:
            self.subscribe_sys()

    def tick(self):
        """Keepalive: ping when idle, give up when the ping is not answered.
        Also asks for $SYS again once a refusal's hold has passed."""
        if self.sock is None:
            return
        if self.sys_held_until and time.monotonic() >= self.sys_held_until and 1 not in self.pending:
            self.sys_held_until = 0.0
            self.subscribe_sys()
        now = time.monotonic()
        if self.ping_sent and now - self.ping_sent > KEEPALIVE_S / 2:
            self._fail("no answer to keepalive")
            return
        if not self.ping_sent and now - self.last_sent >= KEEPALIVE_S / 2:
            try:
                self.sock.sendall(PINGREQ)
            except OSError as exc:
                self._fail(str(exc) or "send failed")
                return
            self.ping_sent = self.last_sent = now

    def close(self):
        if self.sock is not None:
            try:
                self.sock.sendall(DISCONNECT)
                self.sock.close()
            except OSError:
                pass
            self.sock = None


def _bind_loopback(port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("127.0.0.1", port))
    except OSError:
        srv.bind(("127.0.0.1", 0))
    srv.listen(128)
    return srv


def listen(port_file, caps="", raw=False):
    """Listen on loopback; reuse the ports of a previous run when possible.

    The port file holds "<port>[ <capabilities>]"; "dec" tells bash it may
    send decoded telegrams (DEC) instead of building their Discovery itself,
    "raw=<port>" where the RAW stream is read (RawFeed). Returns the writers'
    socket and the RAW one (None without raw).
    """
    port = raw_port = 0
    try:
        with open(port_file, encoding="ascii") as fh:
            words = fh.read().split()
        port = int((words or ["0"])[0])
        raw_port = int(next((w[4:] for w in words if w.startswith("raw=")), "0"))
    except (OSError, ValueError):
        pass
    srv = _bind_loopback(port)
    raw_srv = _bind_loopback(raw_port) if raw else None
    if raw_srv is not None:
        caps = f"{caps} raw={raw_srv.getsockname()[1]}".strip()
    tmp = f"{port_file}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="ascii") as fh:
        fh.write(f"{srv.getsockname()[1]}{' ' + caps if caps else ''}\n")
    os.replace(tmp, port_file)
    return srv, raw_srv


def handle(msg, broker, discovery):
    """Carry out one parsed message."""
    if msg[0] == "PUB":
        broker.publish(msg[1], msg[2], msg[3])
    elif msg[0] == "RST":
        if discovery is not None:
            discovery.reset()
    elif discovery is None:
        log("dropping a decoded telegram: Discovery is not available")
    else:
        try:
            hook = getattr(discovery, "before_decoded", None)
            if hook is not None:
                hook()
            line = msg[2].decode("utf-8", "surrogateescape")
            patterns = msg[1].decode("utf-8", "surrogateescape")
            for topic, payload, retain in discovery.decoded(line, patterns):
                broker.publish(topic.encode("utf-8", "surrogateescape"), payload, retain)
        except Exception as exc:  # one odd telegram must not end the publisher
            log(f"dropping a decoded telegram ({exc.__class__.__name__}: {exc})")


def _deferreds(books):
    return [b[3].deferred for b in books if getattr(b[3], "deferred", None) is not None]


def serve(srv, broker, stop, discovery=None, books=(), raw_srv=None):
    clients = []  # [socket, buffer] in accept order
    deferreds = _deferreds(books)
    feed = next((b[3] for b in books if isinstance(b[3], RawFeed)), None)
    while not stop["now"]:
        broker.try_connect()
        broker.tick()
        for d in deferreds:
            d.flush_if_due()
        rlist = [srv] + [c[0] for c in clients]
        wlist = []
        if raw_srv is not None:
            rlist.append(raw_srv)
        if feed is not None:
            rlist += feed.socks()
            wlist = feed.waiting()
        if broker.connected():
            rlist.append(broker.sock)
        timeout = 1.0 if broker.connected() else max(0.05, min(1.0, broker.next_attempt - time.monotonic()))
        dues = [x for x in (d.due_in() for d in deferreds) if x is not None]
        if dues:
            timeout = max(0.0, min(timeout, min(dues)))
        try:
            readable, writable, _ = select.select(rlist, wlist, [], timeout)
        except InterruptedError:
            continue
        if raw_srv is not None and raw_srv in readable:
            try:
                conn, _ = raw_srv.accept()
                if feed is not None:
                    feed.add(conn)
                else:
                    conn.close()
            except OSError:
                pass
        if feed is not None:
            for conn in feed.socks():
                if conn in readable:
                    feed.on_readable(conn)
            if writable:
                feed.flush()
        if srv in readable:
            try:
                conn, _ = srv.accept()
                conn.setblocking(False)
                clients.append([conn, b""])
            except OSError:
                pass
        if broker.connected() and broker.sock in readable:
            broker.on_readable()
        # Serve writers strictly in accept order: a later connection is only
        # read once every earlier one has been closed by its writer.
        while clients:
            conn, buf = clients[0]
            closed = False
            if conn in readable or buf:
                try:
                    chunk = conn.recv(65536)
                    if chunk:
                        buf += chunk
                    else:
                        closed = True
                except BlockingIOError:
                    pass
                except OSError:
                    closed = True
            try:
                while True:
                    msg, buf = parse_message(buf)
                    if msg is None:
                        break
                    handle(msg, broker, discovery)
            except ValueError as exc:
                log(f"dropping a malformed message ({exc})")
                buf, closed = b"", True
            clients[0][1] = buf
            if not closed:
                break
            conn.close()
            clients.pop(0)
            readable = [r for r in readable if r is not conn]
            if clients:
                readable.append(clients[0][0])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=1883)
    ap.add_argument("--port-file", required=True,
                    help="where the loopback port for writers is written")
    args = ap.parse_args(argv)
    # Credentials come from the environment, not argv: argv is visible in ps.
    username = os.environ.get("MQTT_USER") or None
    if username == "null":
        username = None
    password = os.environ.get("MQTT_PASS") or None
    if password == "null":
        password = None

    stop = {"now": False}

    def on_signal(_sig, _frame):
        stop["now"] = True

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    discovery = None
    try:
        import wmbus_discovery
        if os.environ.get("MQTT_PUBLISHER_TEST_STATE"):
            state = _TestState(os.environ["MQTT_PUBLISHER_TEST_STATE"])
            discovery = wmbus_discovery.Discovery(wmbus_discovery.Config(os.environ),
                                                  epoch=state.epoch, seen_avg=state.seen_avg)
            discovery.before_decoded = lambda: state.refresh(discovery, wmbus_discovery)
        else:
            discovery = wmbus_discovery.Discovery(wmbus_discovery.Config(os.environ))
    except Exception as exc:  # bash then builds Discovery itself ("dec" not announced)
        log(f"Discovery not available ({exc.__class__.__name__}: {exc})")
    books = []
    if os.environ.get("MQTT_PUBLISHER_BOOKS"):
        try:
            import json
            books = make_books(json.loads(os.environ["MQTT_PUBLISHER_BOOKS"]))
        except Exception as exc:  # bash then runs its own subscribers ("books" not announced)
            log(f"ESP subscriptions not available ({exc.__class__.__name__}: {exc})")
            books = []
    caps = (["dec"] if discovery is not None else []) + (["books"] if books else [])
    srv, raw_srv = listen(args.port_file, " ".join(caps),
                          raw=any(isinstance(b[3], RawFeed) for b in books))
    broker = Broker(args.host, args.port, username, password,
                    "wmbus_bridge_pub_" + secrets.token_hex(4))
    broker.subscriptions = [(flt, no_ret, deliver) for flt, no_ret, deliver, _ in books]
    sys_books = list({id(b[3]): b[3] for b in books if hasattr(b[3], "refused")}.values())
    broker.on_sys_refused = lambda: [b.refused() for b in sys_books]
    try:
        broker.sys_retry_s = float(os.environ.get("BROKER_SYS_DENIED_RETRY_S") or SYS_RETRY_S)
    except ValueError:
        pass
    log(f"listening on 127.0.0.1:{srv.getsockname()[1]}"
        + (f"; subscribed for {', '.join(sorted({b[0].decode() for b in books}))}" if books else ""))
    try:
        serve(srv, broker, stop, discovery, books, raw_srv)
    finally:
        for d in _deferreds(books):
            try:
                d.flush()
            except Exception as exc:
                log(f"could not write the collected bookkeeping ({exc})")
        broker.flush()
        broker.close()
        srv.close()
        if raw_srv is not None:
            raw_srv.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())

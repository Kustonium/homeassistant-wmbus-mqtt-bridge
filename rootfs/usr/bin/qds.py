#!/usr/bin/env python3
"""Qundis (QDS) WalkByDataSet telegram classification, validation and decryption.

WHY
---
A Qundis meter sends the same measurements in two shapes:

  a) standard EN 13757 records (CI=0x7A) -- wmbusmeters decodes them fine;
  b) a manufacturer-specific "WalkByDataSet" block (CI=0x78) where the whole
     payload sits in ONE record, `0DFF5F` with LVAR=0x35 (53 bytes), read from
     fixed byte offsets.

Since the 2026 generation, shape (b) is encrypted -- not at the wM-Bus layer
(CI=0x78 carries no TPL header, so the frame is genuinely unencrypted as far as
wM-Bus is concerned) but *inside* the manufacturer block. The user then sees
empty or nonsense fields with no way to tell whether they need a key or whether
the parser is hitting wrong offsets. Those are two different fixes with one
symptom. This module names which one it is.

TWO INDEPENDENT GUARDS
----------------------
1. STRICT BCD (`_bcd`). Upstream's `extractDVdouble()` computes BCD digits as
   `v[i] - '0'` per hex character, so A-F silently become "digits" 17-22. On
   ciphertext that turns `9E D5 FE 13` into `15,430,611` -> `total_m3 =
   15430.611` on a meter reading 1.387, with `status: OK`. Here, ANY nibble
   above 9 rejects the whole record. No clamping, no partial value, nothing
   published.

2. FULL HEADER GATE (`_header_ok`). Upstream gates the walk-by decode on a
   single byte (`blob[9] == 0x13`), which random ciphertext hits 1/256 -- about
   every 8 h per meter. We check byte[7], byte[8] and byte[9] together, plus
   byte[4], plus guard 1 on every field.

Either guard alone stops the corruption; both are kept because they fail for
different reasons and we want the message to say which.

PROVENANCE OF THE FORMAT  (read this before trusting a value)
-------------------------------------------------------------
VERIFIED by us, independently:
  * the 53-byte block layout and the fixed field offsets, checked against all
    16 walk-by telegrams in the wmbusmeters v3.0.0 test corpus (13 plaintext
    across qwater/qheat/qcaloric, 3 opaque);
  * byte[7]==0x07 and byte[8] in {B0,C0,C1} in 13/13 plaintext blocks and 0/3
    opaque ones;
  * upstream master (pushed 2026-08-17) still carries the single-byte gate
    `decode = quad, quad, byte, volume_l.` -- the 1/256 bug is UNPATCHED, so
    guard 2 is ours to provide;
  * the AES core against the FIPS-197 AES-128 test vector.

HIGHLY PROBABLE, from wmbusmeters issue #2025 (Wulstling, 2026-07-08 and
2026-07-15), reported over 36 field frames from four meters, internally
consistent and cross-checked against CI=0x7A frames of the same meters -- but
NOT merged and NOT confirmed by the maintainer:
  * byte[4] == 0x00 means plaintext, 0x35 means encrypted (36/36);
  * the encrypted body is bytes [5..52], AES-128-CBC, with the SAME meter key
    already configured for the CI=0x7A frames;
  * IV is the standard mode-5 construction: M-field(2) || A-field(6) ||
    cnt * 8, where cnt is block header byte[2] acting as ACC;
  * plaintext bytes [0..1] are a little-endian countdown in seconds to the next
    CI=0x7A transmission (+/-1 s on 36/36) -- used here as a sanity signal.

Because that half is unconfirmed, every path is built so a wrong assumption
surfaces as an explicit error status, never as a quiet wrong number: a failed
decryption returns QDS_DECRYPT_FAILED, and a decrypted body still has to pass
both guards before any value is produced.

Do NOT branch on the meter version. Version 0x1A appears both encrypted
(issue #2025, CI=0x78) and fully plaintext (issue #1685, CI=0x7A). byte[4] is
the criterion.
"""

import sys

try:
    from qds_aes import cbc_decrypt, cbc_encrypt
except ImportError:  # running from a source checkout
    sys.path.insert(0, __file__.rsplit("/", 1)[0])
    from qds_aes import cbc_decrypt, cbc_encrypt

STATUSES = (
    "QDS_PLAINTEXT_OK",       # decoded; values are trustworthy
    "QDS_ENCRYPTED_PAYLOAD",  # encrypted and we have no key -- ask for the key
    "QDS_DECRYPT_FAILED",     # encrypted, key tried, result failed sanity
    "QDS_UNKNOWN_LAYOUT",     # block present, structured, but unreadable here
    "QDS_NO_MFCT_BLOCK",      # no 0DFF5F -- ordinary DIF/VIF telegram
)

MFCT_BLOCK_KEY = "0DFF5F"
BLOCK_LEN = 53           # LVAR 0x35
BODY_SLICE = (5, 53)     # encrypted part

MEDIA = {0xB0: "heat cost allocator", 0xC0: "heat", 0xC1: "water"}


# --------------------------------------------------------------------------
# EN 13757 Format A block CRC (poly 0x3D65, init 0x0000, final XOR 0xFFFF)
# --------------------------------------------------------------------------
def crc16(data):
    r = 0
    for b in data:
        r ^= b << 8
        for _ in range(8):
            r = ((r << 1) ^ 0x3D65) & 0xFFFF if r & 0x8000 else (r << 1) & 0xFFFF
    return r ^ 0xFFFF


def strip_block_crc(frame):
    """Remove Format A block CRCs from `frame` (bytes).

    Format A: block 1 = 10 data bytes + 2 CRC, then 16-byte blocks each + 2 CRC
    (last one short). The L-field counts data bytes only, so a CRC-carrying
    frame is longer than L+1 and every plain length check rejects it.

    Deliberately conservative: bails out unless the frame is NOT already
    CRC-free, the Format A arithmetic matches exactly, and EVERY block CRC
    verifies. It therefore cannot damage a good frame.

    Returns (frame, blocks_verified) -- blocks_verified is 0 when nothing was
    stripped.
    """
    n = len(frame)
    if n < 12:
        return frame, 0
    lf = frame[0]
    if lf == n - 1:
        return frame, 0                      # already CRC-free
    rest = lf + 1 - 10
    if rest < 0:
        return frame, 0
    nblocks = (rest + 15) // 16
    if 12 + rest + 2 * nblocks != n:
        return frame, 0
    if crc16(frame[0:10]) != (frame[10] << 8 | frame[11]):
        return frame, 0
    out = bytearray(frame[0:10])
    verified = 1
    p, left = 12, rest
    while left > 0:
        take = min(16, left)
        if crc16(frame[p:p + take]) != (frame[p + take] << 8 | frame[p + take + 1]):
            return frame, 0
        out += frame[p:p + take]
        verified += 1
        p += take + 2
        left -= take
    return bytes(out), verified


# --------------------------------------------------------------------------
# DIF/VIF record enumeration -- purely for the diagnostic message
# --------------------------------------------------------------------------
# Offset (bytes, from frame start) of the first DIF, by CI. Only the three CIs
# actually observed on Qundis meters are listed; anything else is reported as
# "unsupported CI" rather than guessed at.
_DATA_OFFSET = {0x78: 11, 0x7A: 15, 0x72: 23}

_DIF_LEN = {0x0: 0, 0x1: 1, 0x2: 2, 0x3: 3, 0x4: 4, 0x5: 4,
            0x6: 6, 0x7: 8, 0x8: 0, 0x9: 1, 0xA: 2, 0xB: 3,
            0xC: 4, 0xE: 6}


def dv_keys(frame, off):
    """List DIF/VIF keys in wmbusmeters notation ('0C13', '426C', '0DFF5F')."""
    keys, p, n = [], off, len(frame)
    while p < n:
        dif = frame[p]
        if dif in (0x0F, 0x1F):
            keys.append("[mfct-trailer %02X]" % dif)
            break
        if dif == 0x2F:                       # idle filler
            p += 1
            continue
        key = "%02X" % dif
        p += 1
        while dif & 0x80:                     # DIFEs
            if p >= n:
                return keys
            dif = frame[p]
            key += "%02X" % dif
            p += 1
        if p >= n:
            return keys
        vif = frame[p]
        vif_plain = (vif & 0x7F) == 0x7C
        key += "%02X" % vif
        p += 1
        while vif & 0x80:                     # VIFEs
            if p >= n:
                return keys
            vif = frame[p]
            vif_plain = vif_plain or (vif & 0x7F) == 0x7C
            key += "%02X" % vif
            p += 1
        keys.append(key)
        if vif_plain:
            # VIF 0x7C: the unit is a plain-text string carried inline as
            # <len><chars> BEFORE the data field. Skipping it is what keeps the
            # rest of the record list aligned (Qundis smoke detectors use it).
            if p >= n:
                return keys
            p += 1 + frame[p]
        code = int(key[0:2], 16) & 0x0F
        if code == 0x0D:                      # LVAR
            if p >= n:
                return keys
            ln = frame[p]
            p += 1
            if ln > 0xBF:                     # non-binary LVAR forms
                return keys
        elif code in _DIF_LEN:
            ln = _DIF_LEN[code]
        else:                                 # 0x0F handled above
            return keys
        p += ln
    return keys


# --------------------------------------------------------------------------
# Strict field decoding -- guard 1
# --------------------------------------------------------------------------
class BcdError(ValueError):
    """A BCD field contained a nibble above 9."""


def _bcd(field):
    """Little-endian packed BCD -> int. Raises BcdError on ANY nibble > 9.

    This is the guard upstream lacks. It must never be softened into a clamp,
    a partial parse or a best-effort value: the whole point is that a record
    which is not BCD produces no number at all.
    """
    v = 0
    for b in reversed(field):
        hi, lo = b >> 4, b & 0x0F
        if hi > 9 or lo > 9:
            raise BcdError(field.hex().upper())
        v = v * 100 + hi * 10 + lo
    return v


def _date_g(field):
    """EN 13757 type G date (2 bytes LE). Returns an ISO string, None for the
    FFFF 'not set' sentinel, or raises BcdError when it cannot be a date.

    The year plausibility bound is load-bearing, not cosmetic. Type G encodes
    the year in 7 bits (2000..2127), and a structurally valid but absurd date
    is exactly what a partially wrong decryption produces: in CBC only the
    FIRST 16-byte block depends on the IV, so a wrong counter leaves body bytes
    0..7 -- which carry the whole 07/medium/VIF header -- completely intact and
    corrupts only bytes 8..15. The header gate cannot see that at all. What it
    does hit is the date at block[16:18], which then decodes to something like
    year 127. Rejecting years past 2099 is what turns such a frame into
    QDS_DECRYPT_FAILED instead of a plausible-looking wrong reading.
    """
    v = field[0] | (field[1] << 8)
    if v == 0xFFFF:
        return None
    day, mon = v & 0x1F, (v >> 8) & 0x0F
    year = ((v >> 5) & 0x07) | ((v >> 9) & 0x78)
    if not (1 <= day <= 31 and 1 <= mon <= 12 and year <= 99):
        raise BcdError(field.hex().upper())
    return "20%02d-%02d-%02d" % (year, mon, day)


def _header_ok(block):
    """Guard 2: the full plaintext header, not one byte.

    byte[7] == 0x07 (constant), byte[8] is a known medium, byte[9] is a VIF
    consistent with that medium. Verified present in 13/13 plaintext reference
    blocks and 0/3 opaque ones.
    """
    if block[0] != 0x00 or block[1] != 0x82 or block[3] != 0x00:
        return False, "byte[0..3] is not the 00 82 <cnt> 00 WalkByDataSet preamble"
    if block[7] != 0x07:
        return False, "byte[7]=0x%02X, expected the constant 0x07" % block[7]
    medium = MEDIA.get(block[8])
    if medium is None:
        return False, ("byte[8]=0x%02X is not a known medium "
                       "(B0=heat cost allocator, C0=heat, C1=water)" % block[8])
    vif = block[9]
    if block[8] == 0xC1 and not 0x10 <= vif <= 0x17:
        return False, "byte[8]=C1 (water) but byte[9]=0x%02X is not a volume VIF" % vif
    if block[8] == 0xC0 and vif > 0x0F:
        return False, "byte[8]=C0 (heat) but byte[9]=0x%02X is not an energy VIF" % vif
    if block[8] == 0xB0 and vif != 0x6E:
        return False, "byte[8]=B0 (HCA) but byte[9]=0x%02X is not the HCA VIF 0x6E" % vif
    return True, medium


def decode_block(block):
    """Decode a 53-byte plaintext WalkByDataSet block.

    Returns (values_dict, None) or (None, reason). Raises nothing: a bad field
    becomes a reason string, never a number.
    """
    ok, info = _header_ok(block)
    if not ok:
        return None, info
    medium = info
    scale = 1000.0 if block[8] in (0xC0, 0xC1) else 1.0
    unit = "m3" if block[8] == 0xC1 else ("kwh" if block[8] == 0xC0 else "hca")
    try:
        vals = {
            "medium": medium,
            "seconds_to_next_tpl_frame": block[5] | (block[6] << 8),
            "error_date": _date_g(block[10:12]),
            "total_" + unit: _bcd(block[12:16]) / scale,
            "target_year_date": _date_g(block[16:18]),
            "target_year_" + unit: _bcd(block[18:22]) / scale,
            "target_date": _date_g(block[22:24]),
            "target_" + unit: _bcd(block[24:28]) / scale,
        }
    except BcdError as e:
        return None, ("field is not valid BCD/date at the known offsets: %s "
                      "(nibble above 9 -- record rejected, no value published)" % e)
    deltas = []
    for i in range(12):
        raw = block[28 + i * 2] | (block[29 + i * 2] << 8)
        # 0x8000 is the vendor's "no data" sentinel; upstream renders it as the
        # signed minimum. Kept distinguishable from a real zero.
        deltas.append(None if raw == 0x8000 else
                      (raw - 0x10000 if raw & 0x8000 else raw) / scale)
    vals["deltas_" + unit] = deltas
    return vals, None


def entropy(data):
    """Shannon entropy in bits/byte. Reported, never used as a verdict."""
    import math
    if not data:
        return 0.0
    counts = {}
    for b in data:
        counts[b] = counts.get(b, 0) + 1
    n = len(data)
    return -sum((c / n) * math.log2(c / n) for c in counts.values())


# --------------------------------------------------------------------------
# Decryption
# --------------------------------------------------------------------------
def walkby_iv(frame, cnt):
    """Mode-5 style IV: M-field(2) || A-field(6) || cnt * 8.

    Both fields are taken in FRAME byte order (M-field as transmitted, i.e.
    93 44 for QDS), matching wmbusmeters' decrypt_TPL_AES_CBC_IV(). `cnt` is
    block header byte[2], standing in for the ACC field.

    UNCONFIRMED upstream -- see the module docstring.
    """
    return frame[2:10] + bytes([cnt]) * 8


def decrypt_block(frame, block, key):
    """Decrypt bytes [5..52] of an encrypted walk-by block.

    Returns a new 53-byte block with byte[4] reset to 0x00, so it is
    byte-identical to what a plaintext-generation meter would have sent. The
    caller still has to run it through decode_block(): decryption succeeding
    is not evidence that the key was right.
    """
    body = bytes(block[BODY_SLICE[0]:BODY_SLICE[1]])
    plain = cbc_decrypt(key, walkby_iv(frame, block[2]), body)
    return bytes(block[0:4]) + b"\x00" + plain


# --------------------------------------------------------------------------
# Classification
# --------------------------------------------------------------------------
def _mfct_code(frame):
    v = frame[2] | (frame[3] << 8)
    letters = [((v >> 10) & 0x1F), ((v >> 5) & 0x1F), v & 0x1F]
    if all(1 <= x <= 26 for x in letters):
        return "".join(chr(x + 64) for x in letters)
    return "??"


def classify(hexstr, key=None):
    """Classify one raw wM-Bus telegram.

    `key` is the meter's 16-byte AES key (bytes or hex string) -- the SAME key
    already configured for its CI=0x7A frames, not a separate walk-by secret.

    Returns a dict: status, message, and (only for QDS_PLAINTEXT_OK) values.
    The message ALWAYS carries ver, type, CI, the DIF/VIF keys found and the
    concrete reason. It never degrades to "can't get values".
    """
    h = "".join(hexstr.split()).upper()
    if not h or len(h) % 2 or any(c not in "0123456789ABCDEF" for c in h):
        return _r("QDS_UNKNOWN_LAYOUT",
                  "not a hex frame (%d characters)" % len(h))
    frame = bytes.fromhex(h)

    frame, crc_blocks = strip_block_crc(frame)
    crc_note = (" [Format A: %d/%d block CRCs verified and stripped]"
                % (crc_blocks, crc_blocks)) if crc_blocks else ""
    # Every offset below is derived from `h`, so it must follow the frame after
    # CRC removal -- not the wire form.
    h = frame.hex().upper()

    if len(frame) < 11:
        return _r("QDS_UNKNOWN_LAYOUT",
                  "frame too short (%d bytes)%s" % (len(frame), crc_note))

    mfct, ver, typ, ci = _mfct_code(frame), frame[8], frame[9], frame[10]
    off = _DATA_OFFSET.get(ci)
    if off is None:
        return _r("QDS_UNKNOWN_LAYOUT",
                  "mfct=%s ver=0x%02X type=0x%02X CI=0x%02X: unsupported CI, cannot "
                  "locate the first DIF, so no DIF/VIF list is available%s"
                  % (mfct, ver, typ, ci, crc_note))

    keys = dv_keys(frame, off)
    ctx = ("mfct=%s ver=0x%02X type=0x%02X CI=0x%02X DIF/VIF found: [%s]"
           % (mfct, ver, typ, ci, " ".join(keys) if keys else "none"))

    pos = h.find(MFCT_BLOCK_KEY)
    if pos < 0 or pos % 2:
        return _r("QDS_NO_MFCT_BLOCK",
                  "%s. No 0DFF5F manufacturer record -- this is an ordinary "
                  "DIF/VIF telegram handled by the normal driver path%s"
                  % (ctx, crc_note))

    bpos = pos // 2
    lvar = frame[bpos + 3]
    if lvar != BLOCK_LEN:
        return _r("QDS_UNKNOWN_LAYOUT",
                  "%s. 0DFF5F present but LVAR=0x%02X (%d bytes), not 0x35 (53) -- "
                  "the fixed-offset WalkByDataSet reader does not apply. Raw record: %s%s"
                  % (ctx, lvar, lvar, frame[bpos:bpos + 4 + min(lvar, 16)].hex().upper(),
                     crc_note))

    block = frame[bpos + 4:bpos + 4 + BLOCK_LEN]
    if len(block) < BLOCK_LEN:
        return _r("QDS_UNKNOWN_LAYOUT",
                  "%s. 0DFF5F declares 53 bytes but only %d are present -- frame "
                  "truncated. Raw block: %s%s"
                  % (ctx, len(block), block.hex().upper(), crc_note))

    ent = entropy(block[5:])
    b4 = block[4]

    # ---- plaintext generation -------------------------------------------
    if b4 == 0x00:
        vals, why = decode_block(block)
        if vals:
            return _r("QDS_PLAINTEXT_OK",
                      "%s. WalkByDataSet block (53 B, %s), byte[4]=0x00 (plaintext "
                      "generation), header valid, all fields BCD. Entropy %.2f bit/byte. "
                      "No key needed%s" % (ctx, vals["medium"], ent, crc_note),
                      values=vals, block=block.hex().upper())
        return _r("QDS_UNKNOWN_LAYOUT",
                  "%s. WalkByDataSet block present and byte[4]=0x00 says plaintext, "
                  "but it does not read at the offsets this decoder uses "
                  "(12/16/18/22/24): %s Entropy %.2f bit/byte -- too structured to be "
                  "ciphertext, so this is a LAYOUT problem, not a missing key. "
                  "ACTION: report ver=0x%02X type=0x%02X with the raw block to the "
                  "wmbusmeters project. Raw block: %s%s"
                  % (ctx, why, ent, ver, typ, block.hex().upper(), crc_note),
                  block=block.hex().upper(), neutralized=_neutralized(h, pos))

    # ---- encrypted generation -------------------------------------------
    if b4 == 0x35:
        if key is None:
            return _r("QDS_ENCRYPTED_PAYLOAD",
                      "%s. WalkByDataSet block present but byte[4]=0x35: the vendor "
                      "encrypts the 48-byte body INSIDE the manufacturer block "
                      "(the frame itself is CI=0x78 with no TPL header, so wM-Bus "
                      "correctly reports it as unencrypted -- that is why nothing "
                      "flags it). Entropy of bytes 5..52 is %.2f bit/byte. "
                      "ACTION: configure this meter's ordinary AES key -- the SAME "
                      "key its CI=0x7A frames already use. There is no separate "
                      "walk-by secret; if the CI=0x7A frames of this meter decrypt, "
                      "that key is the one needed here. Raw block: %s%s"
                      % (ctx, ent, block.hex().upper(), crc_note),
                      block=block.hex().upper(), neutralized=_neutralized(h, pos))

        kb = key if isinstance(key, (bytes, bytearray)) else bytes.fromhex(
            "".join(str(key).split()))
        if len(kb) != 16:
            return _r("QDS_DECRYPT_FAILED",
                      "%s. byte[4]=0x35 (encrypted) but the configured key is %d "
                      "bytes, not 16 -- AES-128 needs a 32-hex-character key%s"
                      % (ctx, len(kb), crc_note),
                      block=block.hex().upper())

        plain = decrypt_block(frame, block, kb)
        vals, why = decode_block(plain)
        if vals:
            rebuilt = (h[:pos] + "0DFF5F35" + plain.hex().upper()
                       + h[(bpos + 4 + BLOCK_LEN) * 2:])
            vals["decrypted"] = True
            return _r("QDS_PLAINTEXT_OK",
                      "%s. byte[4]=0x35: body decrypted with the meter key "
                      "(AES-128-CBC, IV = M-field || A-field || byte[2] x8). "
                      "Both guards passed: full header valid and every field strict "
                      "BCD. Countdown to next CI=0x7A frame: %d s (a plausible value "
                      "here is independent evidence the key is right). "
                      "Ciphertext entropy was %.2f bit/byte%s"
                      % (ctx, vals["seconds_to_next_tpl_frame"], ent, crc_note),
                      values=vals, block=plain.hex().upper(), rebuilt=rebuilt)
        return _r("QDS_DECRYPT_FAILED",
                  "%s. byte[4]=0x35 (encrypted) and a key was configured, but the "
                  "decrypted body fails sanity: %s The key is most likely wrong for "
                  "this meter (or this meter does not use the mode-5 IV construction "
                  "assumed here -- that part of the format is reported by a single "
                  "user in wmbusmeters issue #2025 and is not confirmed upstream). "
                  "NOTHING is published for this telegram. Decrypted block: %s "
                  "Ciphertext block: %s%s"
                  % (ctx, why, plain.hex().upper(), block.hex().upper(), crc_note),
                  block=block.hex().upper(), neutralized=_neutralized(h, pos))

    # ---- neither marker --------------------------------------------------
    return _r("QDS_UNKNOWN_LAYOUT",
              "%s. WalkByDataSet block present but byte[4]=0x%02X, which is neither "
              "0x00 (plaintext) nor 0x35 (encrypted). This is a generation this "
              "decoder has never seen; nothing is published. Entropy of bytes 5..52 "
              "is %.2f bit/byte. ACTION: report ver=0x%02X type=0x%02X with the raw "
              "block to the wmbusmeters project. Raw block: %s%s"
              % (ctx, b4, ent, ver, typ, block.hex().upper(), crc_note),
              block=block.hex().upper(), neutralized=_neutralized(h, pos))


def _neutralized(h, pos):
    """Rewrite the record key 0DFF5F -> 0DFF5E in place.

    Needed because forwarding an unreadable walk-by block unchanged is not
    harmless: upstream gates the decode on the single byte blob[9]==0x13, which
    random ciphertext hits 1/256 -- about every 8 h per meter -- and then
    publishes ciphertext as a reading (wmbusmeters issue #2025). Suppressing the
    whole telegram would also throw away the 046D meter_datetime, which is the
    one field that IS valid on these frames.

    Changing only the VIFE keeps the record byte-length and structure identical
    (DIF 0x0D, LVAR 0x35), so every following record still parses; it only makes
    the key one no driver matches. VIFE 0x5E is reserved in EN 13757, so this
    cannot collide with a real field.
    """
    return h[:pos] + "0DFF5E" + h[pos + 6:]


def _r(status, message, **extra):
    d = {"status": status, "message": message}
    d.update(extra)
    return d


# --------------------------------------------------------------------------
# Fixture generator -- the exact inverse of the decoder
# --------------------------------------------------------------------------
def make_encrypted_walkby(plaintext48, key, m_field, a_field, cnt,
                          tail=b"\x04\x6D\x29\x06\x48\x37"):
    """Build an encrypted walk-by telegram from a known plaintext body.

    Exists because we have no Qundis meter and no key for the real ciphertexts
    in issue #2025: the only way to test the decryption path end to end is to
    build the ciphertext ourselves from a plaintext that issue #2025 published
    as verified, and require the decoder to recover it exactly.

    plaintext48 -- 48 bytes, the block body [5..52]
    key         -- 16-byte AES key
    m_field     -- 2 bytes in frame order (QDS = 93 44)
    a_field     -- 6 bytes: id(4, LE) || version || type
    cnt         -- header byte[2], also the IV counter
    tail        -- records appended after the block (default: an 046D datetime)

    Returns the telegram as an uppercase hex string, L-field computed.
    """
    plaintext48 = bytes(plaintext48)
    if len(plaintext48) != 48:
        raise ValueError("body must be 48 bytes, got %d" % len(plaintext48))
    m_field, a_field, key = bytes(m_field), bytes(a_field), bytes(key)
    if len(m_field) != 2 or len(a_field) != 6:
        raise ValueError("m_field must be 2 bytes and a_field 6 bytes")

    iv = m_field + a_field + bytes([cnt]) * 8
    body = cbc_encrypt(key, iv, plaintext48)
    block = bytes([0x00, 0x82, cnt, 0x00, 0x35]) + body
    payload = b"\x0D\xFF\x5F\x35" + block + bytes(tail)
    # C-field 0x44 (SND-NR) matches every walk-by telegram in the corpus.
    rest = b"\x44" + m_field + a_field + b"\x78" + payload
    return (bytes([len(rest)]) + rest).hex().upper()


def add_block_crc(hexstr):
    """Wrap a CRC-free frame in EN 13757 Format A block CRCs (inverse of
    strip_block_crc). Used to build fixtures for the RF path, where the ESP
    forwards the frame with its CRCs intact."""
    f = bytes.fromhex("".join(hexstr.split()))
    out = bytearray(f[0:10]) + crc16(f[0:10]).to_bytes(2, "big")
    p = 10
    while p < len(f):
        blk = f[p:p + 16]
        out += blk + crc16(blk).to_bytes(2, "big")
        p += 16
    return bytes(out).hex().upper()



# --------------------------------------------------------------------------
# Stream filter -- the only thing that touches the live decode path
# --------------------------------------------------------------------------
def _load_keys(meter_dir):
    """Map lowercase meter id -> 16-byte AES key, read from the wmbusmeters
    meter files the bridge writes (`id=` / `key=` lines)."""
    import glob
    keys = {}
    for path in glob.glob(meter_dir + "/meter-*"):
        mid = akey = None
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if line.startswith("id="):
                        mid = line[3:].strip().lower()
                    elif line.startswith("key="):
                        akey = line[4:].strip()
        except OSError:
            continue
        if mid and akey:
            try:
                kb = bytes.fromhex(akey)
            except ValueError:
                continue
            if len(kb) == 16:
                keys[mid] = kb
    return keys


def filter_stream(meter_dir, inp, outp, err):
    """Rewrite Qundis walk-by telegrams on the way into wmbusmeters.

    Inserted between the RAW tee and wmbusmeters ONLY when the feature flag is
    on -- with the flag off the pipeline uses `cat`, so an install that sees no
    Qundis walk-by traffic pays nothing per telegram and this code never runs.

    Every line is passed through unchanged unless ALL of the following hold:
    the frame carries a 0DFF5F/LVAR=0x35 block, and either it needs its Format A
    CRCs stripped or it is encrypted and we hold the meter's key and the
    decrypted body passes both guards. Anything else -- no key, wrong key,
    unknown byte[4], failed BCD -- is forwarded untouched, so wmbusmeters sees
    exactly what it would have seen without this filter. The filter can suppress
    a bad rewrite; it can never invent a value.
    """
    keys, checked = _load_keys(meter_dir), 0
    for line in inp:
        raw = line.strip()
        out = raw
        # Cheap gate first: no fork, no parse, no allocation for ordinary traffic.
        if raw and "0DFF5F" in raw.upper():
            if checked % 50 == 0:
                keys = _load_keys(meter_dir)
            checked += 1
            try:
                mid = bytes.fromhex(raw)[4:8][::-1].hex().lower()
            except ValueError:
                mid = ""
            res = classify(raw, key=keys.get(mid))
            if res.get("rebuilt"):
                out = res["rebuilt"]
                err.write("[QDS] %s decrypted walk-by block -> feeding "
                          "plaintext to the decoder\n" % mid)
            elif res["status"] == "QDS_PLAINTEXT_OK" and res.get("block"):
                # Nothing to rewrite except possibly the CRC strip, which
                # wmbusmeters handles itself. Leave the frame alone.
                pass
            elif res.get("neutralized"):
                # Do NOT forward an unreadable walk-by block unchanged -- see
                # _neutralized(). meter_datetime still decodes normally.
                out = res["neutralized"]
                err.write("[QDS] %s %s (walk-by record neutralised, "
                          "meter_datetime still decodes): %s\n" % (mid, res["status"], res["message"]))
            err.flush()
        outp.write(out + "\n")
        outp.flush()


# --------------------------------------------------------------------------
def main(argv):
    import json
    if len(argv) < 2 or argv[1] not in ("classify", "make"):
        sys.stderr.write(
            "usage: qds.py classify <hex> [--key <32-hex>]\n"
            "       qds.py make --body <96-hex> --key <32-hex> "
            "--mfct <4-hex> --addr <12-hex> --cnt <N>\n")
        return 2
    args = argv[2:]

    def opt(name, default=None):
        return args[args.index(name) + 1] if name in args else default

    if argv[1] == "filter":
        filter_stream(opt("--meter-dir", "/data/wmbusmeters.d"),
                      sys.stdin, sys.stdout, sys.stderr)
        return 0

    if argv[1] == "classify":
        res = classify(args[0], key=opt("--key"))
        json.dump(res, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        # Exit non-zero on anything that is not a clean decode, so shell
        # callers can branch without parsing JSON.
        return 0 if res["status"] == "QDS_PLAINTEXT_OK" else 1

    print(make_encrypted_walkby(
        bytes.fromhex(opt("--body")), bytes.fromhex(opt("--key")),
        bytes.fromhex(opt("--mfct", "9344")), bytes.fromhex(opt("--addr")),
        int(opt("--cnt", "0"))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

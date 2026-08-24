"""Minimal, dependency-free AES-128 (ECB core) + CBC mode.

The add-on image is Alpine with bare `python3` -- no `cryptography`, no
`pycryptodome`, and the `openssl` CLI is not installed in the runtime layer
(only `openssl-dev` in the builder stage). Adding a wheel would mean a compiler
in the runtime image, so the cipher is implemented here instead. It is used for
exactly one thing: 48 bytes per Qundis walk-by telegram, on a path that is off
by default. Throughput is irrelevant at that size.

This is a textbook AES implementation. It is NOT constant-time and must not be
used for anything where timing side channels matter. Decrypting a meter reading
that is broadcast in the clear over radio is not such a case.
"""

SBOX = bytes.fromhex(
    "637c777bf26b6fc53001672bfed7ab76ca82c97dfa5947f0add4a2af9ca472c0"
    "b7fd9326363ff7cc34a5e5f171d8311504c723c31896059a071280e2eb27b275"
    "09832c1a1b6e5aa0523bd6b329e32f8453d100ed20fcb15b6acbbe394a4c58cf"
    "d0efaafb434d338545f9027f503c9fa851a3408f929d38f5bcb6da2110fff3d2"
    "cd0c13ec5f974417c4a77e3d645d197360814fdc222a908846eeb814de5e0bdb"
    "e0323a0a4906245cc2d3ac629195e479e7c8376d8dd54ea96c56f4ea657aae08"
    "ba78252e1ca6b4c6e8dd741f4bbd8b8a703eb5664803f60e613557b986c11d9e"
    "e1f8981169d98e949b1e87e9ce5528df8ca1890dbfe6426841992d0fb054bb16"
)
INV_SBOX = bytearray(256)
for _i, _v in enumerate(SBOX):
    INV_SBOX[_v] = _i
INV_SBOX = bytes(INV_SBOX)

RCON = (0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36)


def _xtime(a):
    a <<= 1
    return (a ^ 0x1B) & 0xFF if a & 0x100 else a


def _mul(a, b):
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xtime(a)
        b >>= 1
    return r


def _expand_key(key):
    """AES-128 key schedule -> 11 round keys of 16 bytes."""
    if len(key) != 16:
        raise ValueError("AES-128 requires a 16-byte key, got %d" % len(key))
    w = [list(key[i * 4:i * 4 + 4]) for i in range(4)]
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = t[1:] + t[:1]
            t = [SBOX[b] for b in t]
            t[0] ^= RCON[i // 4 - 1]
        w.append([w[i - 4][j] ^ t[j] for j in range(4)])
    return [bytes(b for word in w[r * 4:r * 4 + 4] for b in word) for r in range(11)]


def _add_round_key(s, rk):
    return bytearray(s[i] ^ rk[i] for i in range(16))


def _encrypt_block(block, rks):
    s = _add_round_key(block, rks[0])
    for rnd in range(1, 11):
        s = bytearray(SBOX[b] for b in s)
        # ShiftRows (state is column-major: index = col*4 + row)
        s = bytearray(s[(i + (i % 4) * 4) % 16] for i in range(16))
        if rnd != 10:
            t = bytearray(16)
            for c in range(4):
                a = s[c * 4:c * 4 + 4]
                t[c * 4 + 0] = _mul(a[0], 2) ^ _mul(a[1], 3) ^ a[2] ^ a[3]
                t[c * 4 + 1] = a[0] ^ _mul(a[1], 2) ^ _mul(a[2], 3) ^ a[3]
                t[c * 4 + 2] = a[0] ^ a[1] ^ _mul(a[2], 2) ^ _mul(a[3], 3)
                t[c * 4 + 3] = _mul(a[0], 3) ^ a[1] ^ a[2] ^ _mul(a[3], 2)
            s = t
        s = _add_round_key(s, rks[rnd])
    return bytes(s)


def _decrypt_block(block, rks):
    s = _add_round_key(block, rks[10])
    for rnd in range(9, -1, -1):
        # InvShiftRows
        s = bytearray(s[(i - (i % 4) * 4) % 16] for i in range(16))
        s = bytearray(INV_SBOX[b] for b in s)
        s = _add_round_key(s, rks[rnd])
        if rnd != 0:
            t = bytearray(16)
            for c in range(4):
                a = s[c * 4:c * 4 + 4]
                t[c * 4 + 0] = _mul(a[0], 14) ^ _mul(a[1], 11) ^ _mul(a[2], 13) ^ _mul(a[3], 9)
                t[c * 4 + 1] = _mul(a[0], 9) ^ _mul(a[1], 14) ^ _mul(a[2], 11) ^ _mul(a[3], 13)
                t[c * 4 + 2] = _mul(a[0], 13) ^ _mul(a[1], 9) ^ _mul(a[2], 14) ^ _mul(a[3], 11)
                t[c * 4 + 3] = _mul(a[0], 11) ^ _mul(a[1], 13) ^ _mul(a[2], 9) ^ _mul(a[3], 14)
            s = t
    return bytes(s)


def cbc_decrypt(key, iv, data):
    """AES-128-CBC decrypt. `data` length must be a multiple of 16. No padding
    is added or removed -- the caller owns the framing."""
    if len(data) % 16:
        raise ValueError("CBC input must be a multiple of 16 bytes, got %d" % len(data))
    rks = _expand_key(key)
    out = bytearray()
    prev = iv
    for i in range(0, len(data), 16):
        blk = data[i:i + 16]
        out += bytes(a ^ b for a, b in zip(_decrypt_block(blk, rks), prev))
        prev = blk
    return bytes(out)


def cbc_encrypt(key, iv, data):
    """AES-128-CBC encrypt. Used only to build test fixtures."""
    if len(data) % 16:
        raise ValueError("CBC input must be a multiple of 16 bytes, got %d" % len(data))
    rks = _expand_key(key)
    out = bytearray()
    prev = iv
    for i in range(0, len(data), 16):
        blk = bytes(a ^ b for a, b in zip(data[i:i + 16], prev))
        prev = _encrypt_block(blk, rks)
        out += prev
    return bytes(out)

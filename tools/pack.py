"""pack.py — 5-trits-per-byte packing codec (D-015) + TXE container (D-014).

Trits are normalized to digits {0,1,2} (- -> 0, 0 -> 1, + -> 2) and packed
little-endian 5 digits per host byte: byte = d0 + 3*d1 + 9*d2 + 27*d3 + 81*d4
(values 0..242 < 256). The final partial group is padded with digit 1 (trit 0).
"""
from __future__ import annotations

import trit as T

# ---- 5 trits / byte -------------------------------------------------------------
def trits_to_bytes(trits) -> bytes:
    out = bytearray()
    acc = 0
    n = 0
    for t in trits:
        acc += (t + 1) * (3 ** n)
        n += 1
        if n == 5:
            out.append(acc)
            acc, n = 0, 0
    if n:
        while n < 5:
            acc += 1 * (3 ** n)  # pad with trit 0 (digit 1)
            n += 1
        out.append(acc)
    return bytes(out)


def bytes_to_trits(data) -> list:
    trits = []
    for b in data:
        v = b
        if v > 242:
            raise ValueError("invalid packed byte %d (must be <= 242)" % v)
        for _ in range(5):
            d = v % 3
            trits.append(d - 1)  # digit -> trit
            v //= 3
    return trits


def pack_trytes(trytes) -> bytes:
    """Tryte sequence (-364..364) -> host bytes (5 trits/byte)."""
    trits = []
    for t in trytes:
        assert T.TRYTE_MIN <= t <= T.TRYTE_MAX, "bad tryte %r" % (t,)
        trits.extend(T.tryte_to_trits(t))
    return trits_to_bytes(trits)


def unpack_trytes(data, n=None) -> list:
    """Host bytes -> first n trytes (None = all whole trytes)."""
    trits = bytes_to_trits(data)
    if n is None:
        n = len(trits) // T.TRYTE_TRITS
    out = []
    for i in range(n):
        out.append(T.from_trits(trits[i * 6:(i + 1) * 6]))
    return out


# ---- TXE container (D-014) --------------------------------------------------------
TXE_MAGIC = [83, 69, 84, 85, 78, 49]      # 'S','E','T','U','N','1'
TXE_VERSION = 1


def build_txe(entry: int, segments) -> bytes:
    """segments: iterable of (load_addr, tryte_list). Returns packed host bytes."""
    trytes = []
    seg_count = len(segments)
    assert 1 <= seg_count <= 36, "segment count must be 1..36"
    trytes.extend(TXE_MAGIC)
    trytes.append(TXE_VERSION)
    trytes.append(0)                       # flags
    trytes.extend(T.word_to_trytes(entry))
    trytes.append(seg_count)
    for addr, data in segments:
        trytes.extend(T.word_to_trytes(addr))
        trytes.extend(T.word_to_trytes(len(data)))
        trytes.extend(data)
    trytes.extend(T.word_to_trytes(T.tryte_checksum(trytes)))   # 2-tryte checksum (word slot)
    return pack_trytes(trytes)


def parse_txe(data: bytes):
    """-> (entry, [(addr, trytes), ...]); raises ValueError on any damage."""
    trytes = unpack_trytes(data)
    if trytes[:6] != TXE_MAGIC:
        raise ValueError("TXE: bad magic")
    version, flags = trytes[6], trytes[7]
    if version != TXE_VERSION:
        raise ValueError("TXE: unsupported version %d" % version)
    entry = T.trytes_to_word(trytes[8:11])
    seg_count = trytes[11]
    if not (1 <= seg_count <= 36):
        raise ValueError("TXE: bad segment count %d" % seg_count)
    i = 12
    segs = []
    for _ in range(seg_count):
        addr = T.trytes_to_word(trytes[i:i + 3])
        length = T.trytes_to_word(trytes[i + 3:i + 6])
        i += 6
        seg = trytes[i:i + length]
        if len(seg) != length:
            raise ValueError("TXE: truncated segment data")
        i += length
        segs.append((addr, seg))
    chk = T.trytes_to_word(trytes[i:i + 3])
    stored = T.tryte_checksum(trytes[:i])
    if chk != stored:
        raise ValueError("TXE: checksum mismatch (stored %d, computed %d)" % (chk, stored))
    return entry, segs

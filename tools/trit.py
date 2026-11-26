"""trit.py — balanced ternary arithmetic library for Setun Tri OS.

Trits are -1, 0, +1. Trit lists are MSB-FIRST (index 0 = most significant trit),
matching the ISA field packing in spec/isa.yaml (D-002). Arithmetic is implemented
on Python ints and wrapped into the balanced range; the property tests in
tests/test_trit.py cross-check every operation against independent references.

Guest code never sees binary; this library is host-side only (emulator/toolchain).
"""
from __future__ import annotations

# ---- constants ---------------------------------------------------------------
TRYTE_TRITS = 6
WORD_TRITS = 18
DWORD_TRITS = 36

TRYTE_MIN, TRYTE_MAX = -364, 364
WORD_MIN, WORD_MAX = -(3 ** WORD_TRITS - 1) // 2, (3 ** WORD_TRITS - 1) // 2  # ±193710244

TRIT_CHARS = {-1: "-", 0: "0", 1: "+"}
CHAR_TRITS = {v: k for k, v in TRIT_CHARS.items()}


def wrap(v: int, width: int) -> int:
    """Wrap an integer into the balanced range of `width` trits (mod 3^width)."""
    m = 3 ** width
    v %= m
    if v > (m - 1) // 2:
        v -= m
    return v


def sign(v: int) -> int:
    return (v > 0) - (v < 0)


def clip3(v: int) -> int:
    return -1 if v < -1 else (1 if v > 1 else v)


# ---- representation conversions -----------------------------------------------
def to_trits(v: int, width: int, wrap_overflow: bool = True) -> tuple:
    """Integer -> tuple of `width` trits, MSB first. Wraps by default (register
    semantics)."""
    if wrap_overflow:
        v = wrap(v, width)
    elif not (-(3 ** width - 1) // 2 <= v <= (3 ** width - 1) // 2):
        raise OverflowError("value %d does not fit in %d trits" % (v, width))
    trits = [0] * width
    for i in range(width - 1, -1, -1):
        r = v % 3
        if r == 0:
            v //= 3
        elif r == 1:
            trits[i] = 1
            v //= 3
        else:  # r == 2 -> trit -1
            trits[i] = -1
            v = (v + 1) // 3
    assert v == 0
    return tuple(trits)


def from_trits(trits) -> int:
    """MSB-first trit sequence -> integer value."""
    v = 0
    for t in trits:
        v = v * 3 + t
    return v


def trit_str(trits) -> str:
    return "".join(TRIT_CHARS[t] for t in trits)


def parse_trit_str(s: str) -> tuple:
    return tuple(CHAR_TRITS[c] for c in s)


# ---- tryte / word packing ------------------------------------------------------
def tryte_to_trits(t: int) -> tuple:
    return to_trits(t, TRYTE_TRITS)


def trits_to_tryte(trits) -> int:
    v = from_trits(trits)
    assert TRYTE_MIN <= v <= TRYTE_MAX
    return v


def trytes_to_word(trytes) -> int:
    """(a, b, c) MSB-first trytes -> 18-trit word value (mod 3^18)."""
    a, b, c = trytes
    assert TRYTE_MIN <= a <= TRYTE_MAX and TRYTE_MIN <= b <= TRYTE_MAX \
        and TRYTE_MIN <= c <= TRYTE_MAX
    return a * 3 ** 12 + b * 3 ** 6 + c


def word_to_trytes(w: int) -> tuple:
    """18-trit word -> (a, b, c) MSB-first trytes (wraps mod 3^18; carries between
    trytes preserve the value modulo 3^18, since 729^3 == 3^18)."""
    w = wrap(w, WORD_TRITS)
    c = w % 729
    q = w // 729
    b = q % 729
    a = q // 729
    vals = [a, b, c]
    for i in (2, 1, 0):
        while vals[i] > TRYTE_MAX:
            vals[i] -= 729
            if i > 0:
                vals[i - 1] += 1
        while vals[i] < TRYTE_MIN:
            vals[i] += 729
            if i > 0:
                vals[i - 1] -= 1
    return (vals[0], vals[1], vals[2])


# ---- arithmetic (register semantics: wrap into 18 trits) ------------------------
def badd(a: int, b: int, width: int = WORD_TRITS) -> int:
    return wrap(a + b, width)


def bsub(a: int, b: int, width: int = WORD_TRITS) -> int:
    return wrap(a - b, width)


def bmul(a: int, b: int, width: int = WORD_TRITS) -> int:
    return wrap(a * b, width)


def bdiv(a: int, b: int) -> int:
    """Round-to-nearest division, exact ties toward zero (D-005). b != 0."""
    if b == 0:
        raise ZeroDivisionError("ternary DIV by zero")
    q, r = divmod(abs(a), abs(b))
    if r * 2 > abs(b):
        q += 1
    # exact tie (r*2 == |b|) keeps q -> round toward zero
    if (a < 0) != (b < 0):
        q = -q
    return q


def bmod(a: int, d: int) -> int:
    """Balanced remainder r = a - q*d with q = bdiv(a, d): |r| <= |d|/2, equality
    only when |d| is even (then sign(r) == sign(a) when r != 0). d != 0 (D-005)."""
    if d == 0:
        raise ZeroDivisionError("ternary MOD by zero")
    return a - bdiv(a, d) * d


def bmulh(a: int, b: int) -> int:
    """High word of the 36-trit dword product. Truncating the balanced dword into
    (high, low) with low = balanced low 18 trits satisfies prod = high*3^18 + low.
    The result always fits in a word."""
    prod = a * b
    low = wrap(prod, WORD_TRITS)
    high = (prod - low) // 3 ** WORD_TRITS
    return wrap(high, WORD_TRITS)


def bneg(a: int, width: int = WORD_TRITS) -> int:
    return wrap(-a, width)


# ---- tritwise logic (on words) ---------------------------------------------------
def _tritwise(a: int, b: int, f, width: int) -> int:
    ta, tb = to_trits(a, width), to_trits(b, width)
    return from_trits([f(x, y) for x, y in zip(ta, tb)])


def tmin(a: int, b: int, width: int = WORD_TRITS) -> int:
    return _tritwise(a, b, min, width)


def tmax(a: int, b: int, width: int = WORD_TRITS) -> int:
    return _tritwise(a, b, max, width)


def tinv(a: int, width: int = WORD_TRITS) -> int:
    return from_trits([-t for t in to_trits(a, width)])


def tcons(a: int, b: int, width: int = WORD_TRITS) -> int:
    return _tritwise(a, b, lambda x, y: x if x == y else 0, width)


def tany(a: int, b: int, width: int = WORD_TRITS) -> int:
    return _tritwise(a, b, lambda x, y: clip3(x + y), width)


def tsum(a: int, b: int, width: int = WORD_TRITS) -> int:
    def m3(x, y):
        s = x + y                       # in -2..2
        return -1 if s == 2 else (1 if s == -2 else s)
    return _tritwise(a, b, m3, width)


def tmul(a: int, b: int, width: int = WORD_TRITS) -> int:
    return _tritwise(a, b, lambda x, y: x * y, width)


def cmp3(a: int, b: int) -> int:
    return sign(a - b)


# ---- shifts / rotate (D-008) ------------------------------------------------------
def bshl(v: int, k: int, width: int = WORD_TRITS) -> int:
    """Shift toward MSB by k, zeros fill LSB, high trits lost (== mul by 3^k, wrap)."""
    if k < 0:
        return bshr(v, -k, width)
    if k == 0:
        return wrap(v, width)
    if k >= width:
        return 0
    return wrap(v * 3 ** k, width)


def bshr(v: int, k: int, width: int = WORD_TRITS) -> int:
    """Drop the k lowest trits (== round-to-nearest division by 3^k; D-008)."""
    if k < 0:
        return bshl(v, -k, width)
    v = wrap(v, width)
    if k == 0:
        return v
    if k >= width:
        return 0
    low = from_trits(to_trits(v, width)[width - k:])
    return wrap((v - low) // 3 ** k, width)


def brot(v: int, k: int, width: int = WORD_TRITS) -> int:
    """Rotate the width trits toward the MSB by k (mod width)."""
    t = to_trits(v, width)
    k %= width
    return from_trits(t[k:] + t[:k])


# ---- tryte checksum (D-014, docs/05) ----------------------------------------------
def tryte_checksum(trytes) -> int:
    """Position-weighted balanced mod-3^6 tryte sum:
    chk = Σ (t_i · ((i mod 729) + 1)) over the tryte stream, wrapped to a tryte."""
    s = 0
    for i, t in enumerate(trytes):
        s += t * ((i % 729) + 1)
    return wrap(s, TRYTE_TRITS)


# ---- TriText (D-016) ---------------------------------------------------------------
ESCAPE = TRYTE_MAX  # +364

# code page 128..: Hungarian first, then common Western European
_TRITEXT_EXTRAS = (
    "áéíóöőúüűÁÉÍÓÖŐÚÜŰ"              # 128..145
    "àâäçèêëìîïñòôùûýÿ"               # lowercase accents
    "ÀÂÄÇÈÊËÌÎÏÑÒÔÙÛÝŸ"              # uppercase accents
    "ßðøþæœåãõšžčćđłńŕřśťźďěň"        # extended Latin
    "£¥€°§¶†‡•…–—«»„“”‚‘’¹²³¼½¾×÷±¬©®™"  # punctuation/symbols
)
TRITEXT_PAGE = {}
for _ch in _TRITEXT_EXTRAS:
    if _ch not in TRITEXT_PAGE:
        TRITEXT_PAGE[_ch] = 128 + len(TRITEXT_PAGE)
_REV_PAGE = {v: k for k, v in TRITEXT_PAGE.items()}

# highest page tryte actually assigned (sanity: must stay <= 364)
assert 128 + len(TRITEXT_PAGE) - 1 <= TRYTE_MAX


def tritext_encode_char(ch: str) -> list:
    """One character -> list of trytes (1 normally, 4 via escape)."""
    o = ord(ch)
    if 0 <= o <= 127:
        return [o]
    t = TRITEXT_PAGE.get(ch)
    if t is not None:
        return [t]
    if o > (3 ** WORD_TRITS - 1) // 2:
        raise ValueError("code point out of TriText escape range: %r" % ch)
    return [ESCAPE] + list(word_to_trytes(o))


def tritext_encode(s: str) -> list:
    out = []
    for ch in s:
        out.extend(tritext_encode_char(ch))
    return out


def tritext_decode(trytes) -> str:
    """Lenient decode: out-of-page / negative / malformed escape -> U+FFFD."""
    out = []
    i, n = 0, len(trytes)
    FFFD = "\ufffd"
    while i < n:
        t = trytes[i]
        if t == ESCAPE:
            if i + 4 <= n and all(TRYTE_MIN <= x <= TRYTE_MAX for x in trytes[i + 1:i + 4]):
                cp = trytes_to_word(trytes[i + 1:i + 4])
                if 0 <= cp <= 0x10FFFF:
                    out.append(chr(cp))
                else:
                    out.append(FFFD)
                i += 4
                continue
            out.append(FFFD)
            i += 1
            continue
        if 0 <= t <= 127:
            out.append(chr(t))
        else:
            out.append(_REV_PAGE.get(t, FFFD))
        i += 1
    return "".join(out)


# ---- M9: compression codecs (D-050) -------------------------------------------
# Format: every codec returns a flat trit list. rle3 pairs each run with its
# count (balanced 3-tryte word, |count| <= 8 per symbol, longer runs split).
# huff3 uses a canonical ternary codebook: 3 symbols -> 2-trit codes, which is
# the optimal fixed assignment for the v0.1 use case (TriText streams are
# dominated by a few symbols).

RLE3_MAX_RUN = 8                                   # 3-tryte balanced count


def rle3(data):
    """Run-length encode trits: for each run, [count word (3 trytes), symbol]."""
    out = []
    i, n = 0, len(data)
    while i < n:
        sym = data[i]
        run = 1
        while i + run < n and data[i + run] == sym and run < RLE3_MAX_RUN:
            run += 1
        out.extend(word_to_trytes(run))
        out.append(sym)
        i += run
    return out


def rle3_decode(enc):
    """Inverse of rle3: repeats each symbol by its count word."""
    out = []
    i = 0
    while i + 3 < len(enc):
        count = trytes_to_word(enc[i:i + 3])
        sym = enc[i + 3]
        out.extend([sym] * count)
        i += 4
    return out


def _huff3_codebook(symbols):
    """Canonical ternary prefix code: 2 symbols -> 1 trit, 3 symbols -> 2 trits."""
    s = sorted(symbols)
    if len(s) == 1:
        return {s[0]: [0]}
    if len(s) == 2:
        return {s[0]: [-1], s[1]: [1]}
    return {s[0]: [-1, -1], s[1]: [-1, 1], s[2]: [1, -1]}


def huff3(data):
    """Ternary Huffman encode (canonical fixed codebook per distinct symbol set)."""
    if not data:
        return []
    code = _huff3_codebook(set(data))
    out = []
    for sym in data:
        out.extend(code[sym])
    return out


def huff3_decode(enc, symbols):
    """Inverse of huff3 given the symbol set (the header carries it in a file)."""
    code = _huff3_codebook(symbols)
    rev = {tuple(v): k for k, v in code.items()}
    out = []
    i = 0
    while i < len(enc):
        for ln in (1, 2):
            key = tuple(enc[i:i + ln])
            if key in rev:
                out.append(rev[key])
                i += ln
                break
        else:
            raise ValueError("bad huff3 stream at %d" % i)
    return out

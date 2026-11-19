"""trild.py — TriLinker: assembler Image -> TXE executable (D-014).

v0.1 links one or more already-positioned images into a single TXE: spans are
merged, symbols from all inputs are merged (duplicates = error), entry from the
first image that defines one (or override).
"""
from __future__ import annotations

import trit as T
import pack as packmod


class LinkError(Exception):
    pass


def link_txe(images, entry=None) -> bytes:
    """images: list of triasm.Image; returns packed TXE bytes."""
    merged = {}
    symbols = {}
    for img in images:
        for sym, val in img.symbols.items():
            if sym in symbols and symbols[sym] != val:
                raise LinkError("duplicate symbol %r (%d vs %d)"
                                % (sym, symbols[sym], val))
            symbols[sym] = val
        for addr, t in img.trytes.items():
            if addr in merged and merged[addr] != t:
                raise LinkError("overlapping trytes at %d" % addr)
            merged[addr] = t
    # contiguous spans
    spans = []
    if merged:
        addrs = sorted(merged)
        start = prev = addrs[0]
        buf = [merged[addrs[0]]]
        for a in addrs[1:]:
            if a == prev + 1:
                buf.append(merged[a])
            else:
                spans.append((start, buf))
                start = a
                buf = [merged[a]]
            prev = a
        spans.append((start, buf))
    if entry is None:
        for img in images:
            if img.entry is not None:
                entry = img.entry
                break
    if entry is None:
        raise LinkError("no entry point (use .entry)")
    trytes = packmod.build_txe(entry, spans)
    return trytes


def txe_entry_and_size(txe_bytes) -> tuple:
    """(entry, total trytes) without full parse — for the boot sector sizing."""
    trytes = packmod.unpack_trytes(txe_bytes)
    entry = T.trytes_to_word(trytes[8:11])
    seg_count = trytes[11]
    i = 12
    total = 12
    for _ in range(seg_count):
        length = T.trytes_to_word(trytes[i + 3:i + 6])
        total += 6 + length
        i += 6 + length
    return entry, total + 3  # + checksum word

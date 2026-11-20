"""mmu.py — TVM MMU: 3-level ternary page tables + 27-entry TLB (D-010/D-018).

Sits between the CPU and the MmioBus. Kernel direct window (mode +):
v < 0  ->  p = v + 3^17  (RAM + MMIO reachable) — works with MMU on or off.
MMU off (PTBR == 0): v >= 0 faults. MMU on (PTBR != 0): v >= 0 walks the tables.
Table entry position for balanced index i is (i + 40) (D-018 addendum).
"""
from __future__ import annotations

import trit as T
from tvm.cpu import C_PFR, C_PFW, C_PFX, C_PRIV
from tvm.devices import MMIO_BASE

WORD = T.WORD_TRITS
PAGE = 729
TLB_SIZE = 27

DIRECT_BASE = 3 ** 17

# PTE trit positions (0 = least significant trit of the word)
PTE_PRESENT = 0
PTE_RW = 1
PTE_X = 2
PTE_OWNER = 3
PTE_ACCESSED = 4
PTE_DIRTY = 5

VA_L1 = 4                  # trits per level
VA_OFF_TRITS = 6           # 3^6 = 729 trytes per page


class TVMFault(Exception):
    def __init__(self, cause, tval):
        super().__init__("TVM fault cause=%d tval=%d" % (cause, tval))
        self.cause = cause
        self.tval = tval


def trit_at(word: int, pos: int) -> int:
    """Balanced trit at position pos (0 = least significant)."""
    return T.to_trits(word, 18)[17 - pos]


def set_trit(word: int, pos: int, val: int) -> int:
    cur = trit_at(word, pos)
    if cur == val:
        return word
    return T.wrap(word + (val - cur) * 3 ** pos, WORD)


class MMU:
    def __init__(self, bus):
        self.bus = bus                   # physical word/tryte access
        self.cpu = None                  # back-reference, set by the machine
        self.tlb = {}                    # (ptbr, vpn) -> (frame, pte, leaf_pa)
        self.tlb_hits = 0
        self.tlb_misses = 0
        self.flush_count = 0

    # ---- helpers ------------------------------------------------------------------
    def _idx(self, va: int, level: int) -> int:
        """4-trit balanced index at level 1..3 (MSB-first trit slices)."""
        t = T.to_trits(va, WORD)
        lo = (level - 1) * VA_L1
        return T.from_trits(t[lo:lo + VA_L1])

    def _page_base(self, va: int) -> int:
        t = T.to_trits(va, WORD)
        return T.from_trits(t[:12]) * 3 ** VA_OFF_TRITS

    def _ptbr(self) -> int:
        return self.cpu.csr[1] if self.cpu else 0    # CSR PTBR = 1

    # ---- access checks ---------------------------------------------------------------
    def _check(self, pte: int, kind: str, mode: int, va: int):
        def tr(pos):
            return trit_at(pte, pos)

        if tr(PTE_PRESENT) != 1:
            cause = {"r": C_PFR, "w": C_PFW, "x": C_PFX}[kind]
            raise TVMFault(cause, va)
        owner = tr(PTE_OWNER)
        if mode < owner:
            raise TVMFault(C_PRIV, va)
        if kind == "r" and tr(PTE_RW) == -1:
            raise TVMFault(C_PFR, va)
        if kind == "w" and tr(PTE_RW) != 1:
            raise TVMFault(C_PFW, va)
        if kind == "x":
            if tr(PTE_X) == -1:
                raise TVMFault(C_PFX, va)
            if tr(PTE_X) == 0 and mode != owner:
                raise TVMFault(C_PFX, va)

    def _set_ad(self, leaf_pa: int, pte: int, kind: str) -> int:
        """Set accessed (and dirty for writes) in the leaf PTE; returns pte."""
        need_a = trit_at(pte, PTE_ACCESSED) != 1
        need_d = kind == "w" and trit_at(pte, PTE_DIRTY) != 1
        if need_a or need_d:
            new = pte
            if need_a:
                new = set_trit(new, PTE_ACCESSED, 1)
            if need_d:
                new = set_trit(new, PTE_DIRTY, 1)
            self.bus.write_word(leaf_pa, new)
            return new
        return pte

    # ---- translation ------------------------------------------------------------------
    def translate(self, va: int, kind: str, mode: int) -> int:
        va = T.wrap(va, WORD)
        if va < 0:
            if mode != 1:
                raise TVMFault({"r": C_PFR, "w": C_PFW, "x": C_PFX}[kind],
                               va)
            return va + DIRECT_BASE                     # kernel direct window
        ptbr = self._ptbr()
        if ptbr == 0:
            return va                    # MMU off (D-028): direct physical
        vpn = self._page_base(va)
        key = (ptbr, vpn)
        hit = self.tlb.get(key)
        if hit is not None:
            self.tlb_hits += 1
            frame, pte, leaf_pa = hit
        else:
            self.tlb_misses += 1
            idx1, idx2, idx3 = self._idx(va, 1), self._idx(va, 2), self._idx(va, 3)
            t1 = ptbr * PAGE + (idx1 + 40) * 3
            p1 = self.bus.read_word(t1)
            if trit_at(p1, PTE_PRESENT) != 1:
                raise TVMFault({"r": C_PFR, "w": C_PFW, "x": C_PFX}[kind], va)
            f1 = self._frame_of(p1)
            t2 = f1 * PAGE + (idx2 + 40) * 3
            p2 = self.bus.read_word(t2)
            if trit_at(p2, PTE_PRESENT) != 1:
                raise TVMFault({"r": C_PFR, "w": C_PFW, "x": C_PFX}[kind], va)
            f2 = self._frame_of(p2)
            t3 = f2 * PAGE + (idx3 + 40) * 3
            pte = self.bus.read_word(t3)
            self._check(pte, kind, mode, va)
            leaf_pa = t3
            frame = self._frame_of(pte)
            if len(self.tlb) >= TLB_SIZE and key not in self.tlb:
                self.tlb.pop(next(iter(self.tlb)))      # FIFO eviction
            pte = self._set_ad(leaf_pa, pte, kind)
            self.tlb[key] = (frame, pte, leaf_pa)
        self._check(pte, kind, mode, va)
        if leaf_pa is not None:
            pte = self._set_ad(leaf_pa, pte, kind)
        frame_pa = frame * PAGE
        off = va - vpn
        return frame_pa + off

    def _frame_of(self, pte: int) -> int:
        """Top 12 trits of the PTE = frame number (MSB-first slice)."""
        t = T.to_trits(pte, WORD)
        return T.from_trits(t[:12])

    # ---- TLB management -----------------------------------------------------------------
    def flush(self):
        self.tlb.clear()
        self.flush_count += 1

    # ---- memory interface (translated) ------------------------------------------------------
    def read_word(self, addr):
        pa = self.translate(addr, "r", self.cpu.mode)
        return self.bus.read_word(pa)

    def write_word(self, addr, v):
        pa = self.translate(addr, "w", self.cpu.mode)
        self.bus.write_word(pa, v)

    def read_tryte(self, addr):
        pa = self.translate(addr, "r", self.cpu.mode)
        return self.bus.read_tryte(pa)

    def write_tryte(self, addr, v):
        pa = self.translate(addr, "w", self.cpu.mode)
        self.bus.write_tryte(pa, v)

    # ---- physical bulk (DMA / loaders) -------------------------------------------------------
    def write_trytes_phys(self, addr, trytes):
        self.bus.write_trytes(addr, trytes)

    def read_trytes_phys(self, addr, n):
        return self.bus.read_trytes(addr, n)

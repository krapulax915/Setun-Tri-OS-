"""memory.py — physical tryte memory for the TVM.

Trytes are stored biased (+364) in a uint16 array. Physical addresses are
non-negative (D-010); anything outside [0, size) raises BusError, which the CPU
turns into a page-fault-family trap (or, in M1 bare metal, a machine halt).
"""
from __future__ import annotations

from array import array

import trit as T

BIAS = -T.TRYTE_MIN          # 364


class BusError(Exception):
    def __init__(self, addr, kind):
        super().__init__("bus error (%s) at physical address %d" % (kind, addr))
        self.addr = addr
        self.kind = kind       # 'r' | 'w' | 'x'


class PhysicalMemory:
    def __init__(self, size_trytes: int):
        if size_trytes < 3:
            raise ValueError("memory too small")
        self.size = size_trytes
        self.buf = array("H", bytes(2 * size_trytes))
        for i in range(size_trytes):
            self.buf[i] = BIAS  # zero tryte

    # ---- tryte granularity ---------------------------------------------------
    def read_tryte(self, addr: int) -> int:
        if not (0 <= addr < self.size):
            raise BusError(addr, "r")
        return self.buf[addr] - BIAS

    def write_tryte(self, addr: int, v: int) -> None:
        if not (0 <= addr < self.size):
            raise BusError(addr, "w")
        if not (T.TRYTE_MIN <= v <= T.TRYTE_MAX):
            raise ValueError("tryte out of range: %d" % v)
        self.buf[addr] = v + BIAS

    # ---- word granularity ------------------------------------------------------
    def read_word(self, addr: int) -> int:
        if not (0 <= addr < self.size - 2):
            raise BusError(addr, "r")
        b = self.buf
        return (b[addr] - BIAS) * 3 ** 12 + (b[addr + 1] - BIAS) * 3 ** 6 \
            + (b[addr + 2] - BIAS)

    def write_word(self, addr: int, v: int) -> None:
        if not (0 <= addr < self.size - 2):
            raise BusError(addr, "w")
        a, b, c = T.word_to_trytes(v)
        self.buf[addr] = a + BIAS
        self.buf[addr + 1] = b + BIAS
        self.buf[addr + 2] = c + BIAS

    # ---- bulk (loader / disk DMA) -------------------------------------------------
    def write_trytes(self, addr: int, trytes) -> None:
        if not (0 <= addr and addr + len(trytes) <= self.size):
            raise BusError(addr, "w")
        for j, t in enumerate(trytes):
            self.buf[addr + j] = t + BIAS

    def read_trytes(self, addr: int, n: int) -> list:
        if not (0 <= addr and addr + n <= self.size):
            raise BusError(addr, "r")
        return [self.buf[addr + j] - BIAS for j in range(n)]

"""devices.py — TVM MMIO devices (D-011 map).

All guest-visible state is ternary; the 5-trits/byte packing happens only in the
host-side block device file I/O.
"""
from __future__ import annotations

import trit as T

MMIO_BASE = 3 ** 17 - 3 ** 12          # 128,608,722 (D-010/D-011)
MMIO_SPAN = 36                          # trytes of device registers

# register offsets (word-aligned)
UART_TX = 0
UART_RX = 3
UART_STAT = 6
BLK_LBA = 12
BLK_BUF = 15
BLK_CMD = 18
BLK_STAT = 21
RNG_VAL = 24
POWER = 27
PROF_CTRL = 30
PROF_ACK = 33

STAT_IDLE, STAT_BUSY, STAT_ERR = 0, 1, -1

# IRQ cause = 10 + device id (D-013)
IRQ_UART = 10 + 1
IRQ_BLK = 10 + 2
IRQ_RNG = 10 + 3
IRQ_PROF = 10 + 4


class Device:
    name = "dev"

    def __init__(self, machine):
        self.machine = machine

    def read_word(self, off):
        return 0

    def write_word(self, off, v):
        pass

    def read_tryte(self, off):
        return T.wrap(self.read_word(off), T.TRYTE_TRITS)

    def write_tryte(self, off, v):
        pass


class Uart(Device):
    name = "uart"

    def __init__(self, machine):
        super().__init__(machine)
        self.rx = []                 # pending input trytes (TriText)
        self.on_output = None        # callable(tryte)

    def write_word(self, off, v):
        if off == UART_TX:
            self._emit(T.wrap(v, T.TRYTE_TRITS))

    def write_tryte(self, off, v):
        if off == UART_TX:
            self._emit(v)

    def _emit(self, t):
        if self.on_output:
            self.on_output(t)

    def feed_input(self, trytes):
        if trytes:
            self.rx.extend(trytes)
            self.machine.cpu.raise_irq(IRQ_UART)

    def read_word(self, off):
        if off == UART_RX:
            return self.rx.pop(0) if self.rx else 0
        if off == UART_STAT:
            return 1 if self.rx else 0
        return 0


class PowerDevice(Device):
    name = "power"

    def write_word(self, off, v):
        if off == POWER:
            if v == 1:
                self.machine.power_off()
            elif v == -1:
                self.machine.request_reset()


class ProfDevice(Device):
    """Profiler device — control registers only; counters land in M9."""
    name = "prof"

    def __init__(self, machine, profiler=None):
        super().__init__(machine)
        self.profiler = profiler

    def write_word(self, off, v):
        if off == PROF_CTRL:
            if self.profiler is not None:
                self.profiler.ctrl(v)


class Rng(Device):
    """Deterministic ternary LCG: next = A*state + C mod 3^18 (A coprime to 3)."""
    name = "rng"
    A = 3 ** 10 + 1          # 59050, coprime to 3
    C = 12345

    def __init__(self, machine, seed=12345):
        super().__init__(machine)
        self.state = T.wrap(seed, T.WORD_TRITS)

    def read_word(self, off):
        if off == RNG_VAL:
            self.state = T.wrap(self.state * self.A + self.C, T.WORD_TRITS)
            return self.state
        return 0

    def write_word(self, off, v):
        if off == RNG_VAL:
            self.state = T.wrap(v, T.WORD_TRITS)


class BlockDevice(Device):
    name = "blk"
    BLOCK = 729

    def __init__(self, machine, nblocks=64, trytes=None):
        super().__init__(machine)
        self.nblocks = nblocks
        self.blocks = [None] * nblocks
        if trytes:
            for i in range(min(nblocks, len(trytes) // self.BLOCK)):
                self.blocks[i] = list(trytes[i * self.BLOCK:(i + 1) * self.BLOCK])
        self.lba = 0
        self.buf = 0
        self.stat = STAT_IDLE
        self.reads = 0
        self.writes = 0

    def read_word(self, off):
        if off == BLK_STAT:
            return self.stat
        return 0

    def write_word(self, off, v):
        if off == BLK_LBA:
            self.lba = v
        elif off == BLK_BUF:
            self.buf = v
        elif off == BLK_CMD:
            self._cmd(v)

    def _cmd(self, v):
        if v == 1:                                    # read
            if not (0 <= self.lba < self.nblocks):
                self.stat = STAT_ERR
                return
            blk = self.blocks[self.lba]
            if blk is None:
                blk = [0] * self.BLOCK
            self.machine.bus.write_trytes(self.buf, blk)
            self.stat = STAT_IDLE
            self.reads += 1
            self.machine.cpu.raise_irq(IRQ_BLK)
        elif v == 2:                                  # write
            if not (0 <= self.lba < self.nblocks):
                self.stat = STAT_ERR
                return
            data = self.machine.bus.read_trytes(self.buf, self.BLOCK)
            self.blocks[self.lba] = list(data)
            self.stat = STAT_IDLE
            self.writes += 1
            self.machine.cpu.raise_irq(IRQ_BLK)

    def to_trytes(self) -> list:
        out = []
        for i in range(self.nblocks):
            out.extend(self.blocks[i] or [0] * self.BLOCK)
        return out

    def to_bytes(self) -> bytes:
        import pack as packmod
        return packmod.pack_trytes(self.to_trytes())

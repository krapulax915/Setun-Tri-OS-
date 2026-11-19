"""machine.py — the TVM machine: CPU + RAM + MMIO bus + devices + boot ROM.

Physical memory layout (D-010/D-011):
    [0, 6561)          ROM (9 blocks)
    [6561, ...)        RAM
    [MMIO_BASE, +36)   device registers (inside the kernel direct window reach)
"""
from __future__ import annotations

import sys
from pathlib import Path

import trit as T
import pack as packmod
from tvm.memory import PhysicalMemory, BusError
from tvm.cpu import CPU, CSR_NUM, CAUSE
from tvm.devices import (Device, Uart, BlockDevice, Rng, PowerDevice, ProfDevice,
                         MMIO_BASE, MMIO_SPAN,
                         UART_TX, UART_RX, UART_STAT, BLK_LBA, BLK_BUF, BLK_CMD,
                         BLK_STAT, RNG_VAL, POWER, PROF_CTRL, PROF_ACK,
                         IRQ_UART, IRQ_BLK)

# MMIO offset -> (device index, register offset) — D-011 map, 3-tryte slots
REG_MAP = {
    0: (0, UART_TX),
    3: (0, UART_RX),
    6: (0, UART_STAT),
    12: (1, BLK_LBA),
    15: (1, BLK_BUF),
    18: (1, BLK_CMD),
    21: (1, BLK_STAT),
    24: (2, RNG_VAL),
    27: (3, POWER),
    30: (4, PROF_CTRL),
    33: (4, PROF_ACK),
}

ROM_SIZE = 6561                 # 9 blocks of 729 trytes
DEFAULT_RAM = 3 ** 14           # 4,782,969 trytes ~ 4.6 MB
DEFAULT_DISK_BLOCKS = 64


class MmioBus:
    """Memory front-end: routes the MMIO window to devices, else physical RAM."""

    def __init__(self, ram: PhysicalMemory, devices: list):
        self.ram = ram
        self.devices = devices

    def _dev(self, addr):
        off = addr - MMIO_BASE
        if off in REG_MAP:
            idx, reg = REG_MAP[off]
            return self.devices[idx], reg
        return None, None

    # word access --------------------------------------------------------------
    def read_word(self, addr):
        dev, off = self._dev(addr)
        if dev is not None:
            return dev.read_word(off)
        return self.ram.read_word(addr)

    def write_word(self, addr, v):
        dev, off = self._dev(addr)
        if dev is not None:
            dev.write_word(off, v)
            return
        self.ram.write_word(addr, v)

    # tryte access ---------------------------------------------------------------
    def read_tryte(self, addr):
        dev, off = self._dev(addr)
        if dev is not None:
            return dev.read_tryte(off)
        return self.ram.read_tryte(addr)

    def write_tryte(self, addr, v):
        dev, off = self._dev(addr)
        if dev is not None:
            dev.write_tryte(off, v)
            return
        self.ram.write_tryte(addr, v)

    # bulk (DMA/loader; RAM only) ----------------------------------------------
    def write_trytes(self, addr, trytes):
        self.ram.write_trytes(addr, trytes)

    def read_trytes(self, addr, n):
        return self.ram.read_trytes(addr, n)


class Machine:
    def __init__(self, ram_size=DEFAULT_RAM, rom_bytes=None, disk_path=None,
                 disk_bytes=None, nblocks=DEFAULT_DISK_BLOCKS, seed=12345,
                 echo=False, profiler=None):
        self.ram = PhysicalMemory(ram_size)
        self.echo = echo
        self.powered_off = False
        self.reset_requested = False
        self.exit_code = 0
        self.output_trytes = []            # UART TX stream
        self._esc_pending = []             # TriText escape state machine

        # devices
        self._dev_uart = Uart(self)
        self._dev_blk = BlockDevice(self, nblocks=nblocks)
        self._dev_rng = Rng(self, seed)
        self._dev_power = PowerDevice(self)
        self._dev_prof = ProfDevice(self)
        self.devices = [self._dev_uart, self._dev_blk, self._dev_rng,
                        self._dev_power, self._dev_prof]
        self.bus = MmioBus(self.ram, self.devices)
        self.cpu = CPU(self.bus, trap_hook=self._bare_trap)
        self._dev_uart.on_output = self._uart_out
        self.profiler = profiler

        # load ROM
        self._rom_bytes = rom_bytes
        if rom_bytes is not None:
            self.bus.write_trytes(0, packmod.unpack_trytes(rom_bytes))

        # load disk
        if disk_bytes is not None:
            trytes = packmod.unpack_trytes(disk_bytes)
            self._dev_blk = BlockDevice(self, nblocks=max(1, len(trytes) // 729),
                                        trytes=trytes)
            self.devices[1] = self._dev_blk
        elif disk_path is not None and Path(disk_path).exists():
            data = Path(disk_path).read_bytes()
            trytes = packmod.unpack_trytes(data)
            self._dev_blk = BlockDevice(self, nblocks=max(1, len(trytes) // 729),
                                        trytes=trytes)
            self.devices[1] = self._dev_blk
        self.disk_path = disk_path

    # ---- UART -----------------------------------------------------------------
    def _uart_out(self, tryte):
        self.output_trytes.append(tryte)
        if self.echo:
            sys.stdout.write(self._decode_one(tryte))
            sys.stdout.flush()

    def _decode_one(self, t):
        """Incremental TriText decode with escape handling."""
        if self._esc_pending:
            self._esc_pending.append(t)
            if len(self._esc_pending) == 4:
                cp = T.trytes_to_word(self._esc_pending[1:4])
                self._esc_pending = []
                if 0 <= cp <= 0x10FFFF:
                    try:
                        return chr(cp)
                    except ValueError:
                        return "\ufffd"
                return "\ufffd"
            return ""
        if t == T.ESCAPE:
            self._esc_pending = [t]
            return ""
        return T.tritext_decode([t])

    def output_text(self) -> str:
        return T.tritext_decode(self.output_trytes)

    def feed_stdin(self, text: str):
        self._dev_uart.feed_input(T.tritext_encode(text))

    # ---- power ------------------------------------------------------------------
    def power_off(self, code=0):
        self.powered_off = True
        self.exit_code = code

    def request_reset(self):
        self.reset_requested = True

    # ---- bare-metal trap fallback ---------------------------------------------------
    def _bare_trap(self, cause, tval, epc):
        name = {v: k for k, v in CAUSE.items()}.get(cause, "?")
        sys.stderr.write("TVM bare trap: cause=%s(%d) tval=%d epc=%d\n"
                         % (name, cause, tval, epc))
        self.powered_off = True
        self.exit_code = 70

    # ---- run loop ---------------------------------------------------------------------
    def run(self, max_steps=20_000_000):
        steps = 0
        while steps < max_steps:
            if self.powered_off or self.reset_requested:
                break
            if self.cpu.halted:
                break
            progressed = self.cpu.step()
            steps += 1
            if not progressed:
                # CPU asleep (WFI): anything to wake it?
                if self.cpu.irq_pending or self._stdin_has_data():
                    continue
                break
        if self.reset_requested:
            return self._reset()
        return self.exit_code

    def _stdin_has_data(self):
        # interactive consoles: peek without blocking is host-specific; TVM tests
        # feed input via feed_stdin, so stdin is not polled here.
        return False

    def _reset(self):
        self.reset_requested = False
        self.cpu = CPU(self.bus, trap_hook=self._bare_trap)
        if self._rom_bytes is not None:
            self.bus.write_trytes(0, packmod.unpack_trytes(self._rom_bytes))
        return self.run()

    def save_disk(self, path=None):
        path = Path(path or self.disk_path)
        if path is None:
            raise ValueError("no disk path to save to")
        path.write_bytes(self._dev_blk.to_bytes())

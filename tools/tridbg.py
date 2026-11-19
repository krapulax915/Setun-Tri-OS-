"""tridbg.py — TVM debugger: step, break, registers, memory, disassembly, trace.

CLI:
    python tools/tridbg.py --rom build/rom.tri --disk image/trios.img --script cmds.txt

Programmatic:
    d = Debugger(Machine(rom_bytes=..., disk_path=...))
    d.cmd("brk 7290"); d.cmd("run"); d.cmd("regs")
"""
from __future__ import annotations

import sys

import trit as T
import tridis


class Debugger:
    def __init__(self, machine, out=sys.stdout):
        self.m = machine
        self.out = out
        self.breakpoints = set()
        self.trace = False
        self.trace_log = []
        self.last_stop = None

    # ---- helpers ---------------------------------------------------------------
    def _w(self, s=""):
        self.out.write(s + "\n")

    def _stop(self, why):
        self.last_stop = why

    # ---- command loop ------------------------------------------------------------
    def cmd(self, line: str) -> bool:
        """Execute one command; returns False when the session should quit."""
        parts = line.split()
        if not parts:
            return True
        name, args = parts[0].lower(), parts[1:]
        cpu = self.m.cpu
        if name == "quit" or name == "q":
            return False
        elif name == "run":
            self._run_until_stop()
        elif name == "step" or name == "s":
            n = int(args[0]) if args else 1
            for _ in range(n):
                if cpu.halted or self.m.powered_off:
                    self._stop("halted")
                    break
                if self.trace:
                    self.trace_log.append((cpu.pc, cpu.last_mnemonic,
                                           list(cpu.r)))
                cpu.step()
                if cpu.pc in self.breakpoints:
                    self._stop("break")
                    break
        elif name == "brk" or name == "break":
            self.breakpoints.add(int(args[0], 0))
        elif name == "nobrk":
            if args:
                self.breakpoints.discard(int(args[0], 0))
            else:
                self.breakpoints.clear()
        elif name == "trace":
            self.trace = bool(args and args[0] == "on")
        elif name == "regs" or name == "r":
            self._w("PC=%d mode=%d irq=%d %s"
                    % (cpu.pc, cpu.mode, cpu.irq_enable,
                       "halted" if cpu.halted else "running"))
            for i in range(1, 9):
                self._w("R%d=%d" % (i, cpu.r[i]))
            self._w("CAUSE=%d TVAL=%d EPC=%d"
                    % (cpu.csr.get(4, 0), cpu.csr.get(5, 0), cpu.csr.get(3, 0)))
        elif name == "mem":
            addr = int(args[0], 0)
            n = int(args[1], 0) if len(args) > 1 else 9
            for j in range(0, n, 3):
                a = addr + j
                if a % 3 == 0 and a + 3 <= len(self.m.ram.buf):
                    self._w("%d: %d" % (a, self.m.ram.read_word(a)))
                else:
                    self._w("%d: %d" % (a, self.m.ram.read_tryte(a)))
        elif name == "dis":
            addr = int(args[0], 0)
            n = int(args[1], 0) if len(args) > 1 else 8
            for j in range(n):
                a = addr + 3 * j
                try:
                    w = self.m.ram.read_word(a)
                except Exception:
                    break
                self._w("%-8d %s" % (a, tridis.decode_word(w, pc=a)))
        elif name == "out":
            self._w(self.m.output_text())
        elif name == "status":
            self._w("pc=%d halted=%s powered_off=%s brk=%s stop=%s"
                    % (cpu.pc, cpu.halted, self.m.powered_off,
                       sorted(self.breakpoints), self.last_stop))
        else:
            self._w("? %s" % line)
        return True

    def _run_until_stop(self, max_steps=20_000_000):
        cpu = self.m.cpu
        steps = 0
        while steps < max_steps:
            if cpu.halted or self.m.powered_off:
                self._stop("halted")
                return
            if cpu.pc in self.breakpoints:
                self._stop("break")
                return
            if self.trace:
                self.trace_log.append((cpu.pc, cpu.last_mnemonic, list(cpu.r)))
            if not cpu.step():
                self._stop("asleep")
                return
            steps += 1
        self._stop("max-steps")


def main(argv):
    import argparse
    from pathlib import Path
    from tvm.machine import Machine
    ap = argparse.ArgumentParser()
    ap.add_argument("--rom", default=None)
    ap.add_argument("--disk", default=None)
    ap.add_argument("--script", default=None)
    ap.add_argument("--echo", action="store_true")
    ns = ap.parse_args(argv)
    rom = Path(ns.rom).read_bytes() if ns.rom and Path(ns.rom).exists() else None
    m = Machine(rom_bytes=rom, disk_path=ns.disk, echo=ns.echo)
    d = Debugger(m)
    if ns.script:
        for line in Path(ns.script).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                if not d.cmd(line):
                    break
    else:
        for line in sys.stdin:
            if not d.cmd(line.rstrip("\n")):
                break
    return m.exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""M2 acceptance: devices, boot ROM, TXE loading from disk, debugger.

- "Hello, ternary world" via UART (guest program, direct load)
- boot sector loads a TXE image from disk (boot ROM -> boot sector -> kernel)
- tridbg can step / break
- 5 trits/byte packing round-trips; block device read/write via MMIO
"""
import os
import sys
import unittest
from pathlib import Path

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, TOOLS)

import trit as T                    # noqa: E402
import pack as packmod              # noqa: E402
import triasm                       # noqa: E402
import trild                        # noqa: E402
import trimkfs                      # noqa: E402
from tvm.machine import Machine     # noqa: E402
from tvm.devices import (MMIO_BASE, UART_TX, UART_RX, UART_STAT, BLK_LBA,   # noqa: E402
                         BLK_BUF, BLK_CMD, BLK_STAT, RNG_VAL, POWER,
                         STAT_IDLE, STAT_ERR, IRQ_BLK)
from tvm.cpu import CSR_NUM, C_TIMER  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def hello_machine(**kw):
    """Machine with a tiny guest that prints and powers off (no disk boot)."""
    img = triasm.assemble_source("""
        .include "lib/trilib.asm"
        .equ MMIO, 128608722
        .equ UART_TX, MMIO+0
        .equ POWER, MMIO+27
        .org 102
        .entry main
    main:
        const R1, UART_TX
        const R3, hello
    print:
        LDT R2, R3
        BRZ R2, done
        STT R1, R2
        ADDI R3, R3, 1
        JMP print
    done:
        const R1, POWER
        LDI R2, 1
        STW R1, R2
    hello:
        .asciz "Hello, ternary world!\\n"
    """)
    txe = trild.link_txe([img])
    _entry, segs = packmod.parse_txe(txe)
    m = Machine(**kw)
    for addr, trytes in segs:
        m.bus.write_trytes(addr, trytes)
    m.cpu.pc = _entry
    return m


def boot_machine(**kw):
    """Full boot path: ROM -> boot sector (block 0) -> kernel TXE (blocks 1..)."""
    rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
    boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
    kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
    txe = trild.link_txe([kernel])
    disk = trimkfs.build_boot_image(boot.spans()[0][1], packmod.unpack_trytes(txe),
                                    nblocks=64)
    return Machine(rom_bytes=rom.rom_bytes, disk_bytes=disk, **kw)


class TestPacking(unittest.TestCase):
    def test_5trits_per_byte_round_trip(self):
        for trial in range(200):
            n = trial % 40 + 1
            trits = [(-1, 0, 1)[(trial * 7 + i) % 3] for i in range(n)]
            data = packmod.trits_to_bytes(trits)
            self.assertTrue(all(b <= 242 for b in data))
            back = packmod.bytes_to_trits(data)[:n]
            self.assertEqual(back, trits)

    def test_tryte_packing_round_trip(self):
        trytes = [83, 69, 84, 85, 78, 49, -364, 364, 0, -1, 1] * 4
        data = packmod.pack_trytes(trytes)
        back = packmod.unpack_trytes(data, len(trytes))
        self.assertEqual(back, trytes)

    def test_txe_round_trip_with_checksum(self):
        entry = 7290
        segs = [(7290, [83, 69, 84, 85, 78, 49, 0, 1, 2, 3]),
                (90000, [5] * 100)]
        data = packmod.build_txe(entry, segs)
        e2, s2 = packmod.parse_txe(data)
        self.assertEqual(e2, entry)
        self.assertEqual(s2, segs)
        # corrupt one payload tryte -> checksum must fail
        bad = packmod.build_txe(entry, segs)
        tr = packmod.unpack_trytes(bad)
        tr[20] = (tr[20] + 1) % 365
        data_bad = packmod.pack_trytes(tr)
        with self.assertRaises(ValueError):
            packmod.parse_txe(data_bad)


class TestDevices(unittest.TestCase):
    def test_uart_output(self):
        m = hello_machine()
        m.run(max_steps=10000)
        self.assertEqual(m.output_text(), "Hello, ternary world!\n")
        self.assertTrue(m.powered_off)
        self.assertEqual(m.exit_code, 0)

    def test_uart_input_and_stat(self):
        m = Machine()
        self.assertEqual(m.bus.read_word(MMIO_BASE + UART_STAT), 0)
        m.feed_stdin("Á")
        self.assertEqual(m.bus.read_word(MMIO_BASE + UART_STAT), 1)
        c = T.tritext_encode("Á")
        self.assertEqual(m.bus.read_word(MMIO_BASE + UART_RX), c[0])
        self.assertEqual(m.bus.read_word(MMIO_BASE + UART_STAT), 0)

    def test_block_device_round_trip(self):
        img = triasm.assemble_source("""
            .include "lib/trilib.asm"
            .equ MMIO, 128608722
            .equ BLK_LBA, MMIO+12
            .equ BLK_BUF, MMIO+15
            .equ BLK_CMD, MMIO+18
            .equ BLK_STAT, MMIO+21
            .org 102
            .entry main
        main:
            ; fill RAM buffer at 5001 (word-aligned), write to block 3
            LDI R1, 5001
            LDI R2, 20000
            STW R1, R2
            LEA R1, R1, 3
            LDI R2, -20000
            STW R1, R2
            const R1, BLK_LBA
            LDI R2, 3
            STW R1, R2
            const R1, BLK_BUF
            LDI R2, 5001
            STW R1, R2
            const R1, BLK_CMD
            LDI R2, 2
            STW R1, R2            ; write block 3
            ; clobber the RAM buffer, then read the block back
            const R1, BLK_LBA
            LDI R2, 3
            STW R1, R2
            const R1, BLK_BUF
            LDI R2, 6001
            STW R1, R2
            const R1, BLK_CMD
            LDI R2, 1
            STW R1, R2            ; read block 3 -> 6001
            HALT
        """)
        mem_span = img.spans()[0]
        m = Machine()
        m.bus.write_trytes(mem_span[0], mem_span[1])
        m.cpu.pc = img.entry
        m.run(max_steps=10000)
        self.assertEqual(m._dev_blk.writes, 1)
        self.assertEqual(m._dev_blk.reads, 1)
        self.assertEqual(m.ram.read_word(6001), 20000)
        self.assertEqual(m.ram.read_word(6004), -20000)
        # untouched zero region
        self.assertEqual(m.ram.read_word(6500), 0)
        # error case: bad LBA
        m.bus.write_word(MMIO_BASE + BLK_LBA, 999)
        m.bus.write_word(MMIO_BASE + BLK_CMD, 1)
        self.assertEqual(m.bus.read_word(MMIO_BASE + BLK_STAT), STAT_ERR)

    def test_rng_deterministic(self):
        m1, m2 = Machine(seed=99), Machine(seed=99)
        seq1 = [m1.bus.read_word(MMIO_BASE + RNG_VAL) for _ in range(5)]
        seq2 = [m2.bus.read_word(MMIO_BASE + RNG_VAL) for _ in range(5)]
        self.assertEqual(seq1, seq2)
        m3 = Machine(seed=1)
        seq3 = [m3.bus.read_word(MMIO_BASE + RNG_VAL) for _ in range(5)]
        self.assertNotEqual(seq1, seq3)
        # reseed
        m1.bus.write_word(MMIO_BASE + RNG_VAL, 99)
        seq1b = [m1.bus.read_word(MMIO_BASE + RNG_VAL) for _ in range(5)]
        self.assertEqual(seq1, seq1b)

    def test_power_device(self):
        img = triasm.assemble_source("""
            .include "lib/trilib.asm"
            .equ MMIO, 128608722
            .equ POWER, MMIO+27
            .org 102
            .entry main
        main:
            const R1, POWER
            LDI R2, 1
            STW R1, R2
        """)
        span = img.spans()[0]
        m = Machine()
        m.bus.write_trytes(span[0], span[1])
        m.cpu.pc = img.entry
        code = m.run(max_steps=1000)
        self.assertTrue(m.powered_off)
        self.assertEqual(code, 0)

    def test_disk_persistence_bytes(self):
        m = Machine(nblocks=8)
        blk = [i % 3 - 1 for i in range(729)]
        m._dev_blk.blocks[5] = blk
        data = m._dev_blk.to_bytes()
        m2 = Machine(disk_bytes=data)
        self.assertEqual(m2._dev_blk.blocks[5], blk)


class TestBoot(unittest.TestCase):
    def test_hello_ternary_world_full_boot(self):
        """ROM -> boot sector -> kernel TXE from disk -> UART greeting.
        Since M3 the kernel prints the full boot banner; the greeting must be
        part of it."""
        m = boot_machine()
        code = m.run(max_steps=40_000_000)
        self.assertIn("Hello, ternary world!", m.output_text())
        self.assertEqual(code, 0)
        self.assertTrue(m.powered_off)

    def test_boot_sector_entry_discovered(self):
        rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
        boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
        self.assertEqual(boot.spans()[0][0], 6561)
        self.assertLessEqual(len(boot.spans()[0][1]), 729)
        kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
        txe = trild.link_txe([kernel])
        entry, segs = packmod.parse_txe(txe)
        self.assertEqual(entry, kernel.entry)
        self.assertEqual(segs[0][0], 7290)
        self.assertTrue(rom.rom_bytes)

    def test_boot_fails_cleanly_on_bad_magic(self):
        rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
        boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
        # payload does not start with TXE magic
        disk = trimkfs.build_boot_image(boot.spans()[0][1], [1, 2, 3], nblocks=64)
        m = Machine(rom_bytes=rom.rom_bytes, disk_bytes=disk)
        m.run(max_steps=200000)
        self.assertEqual(m.output_text(), "E")
        self.assertTrue(m.cpu.halted)


class TestDebugger(unittest.TestCase):
    def test_step_break_regs(self):
        from tridbg import Debugger
        m = boot_machine()
        kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
        brk_addr = kernel.symbols["puts"]         # break when the kernel prints
        d = Debugger(m, out=Path(os.devnull).open("w"))
        d.cmd("brk %d" % brk_addr)
        d.cmd("run")
        self.assertEqual(d.last_stop, "break")
        self.assertEqual(m.cpu.pc, brk_addr)
        d.cmd("step 3")
        self.assertEqual(m.cpu.pc, brk_addr + 9)  # 3 instructions deeper
        d.cmd("nobrk")
        d.cmd("run")
        self.assertIn("Setun Tri OS v0.1 ready", m.output_text())
        d.cmd("regs")                             # must not raise
        d.cmd("dis 7290 4")

    def test_trace_records(self):
        from tridbg import Debugger
        m = Machine()
        d = Debugger(m, out=Path(os.devnull).open("w"))
        d.cmd("trace on")
        d.cmd("step 5")
        self.assertGreater(len(d.trace_log), 0)
        rec = d.trace_log[0]
        self.assertEqual(len(rec), 3)             # (pc, mnemonic, regs)


if __name__ == "__main__":
    unittest.main(verbosity=2)

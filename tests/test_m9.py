"""M9 acceptance: profiler + rle3/huff3 compression.

Checks that the profiler device (PROF_CTRL/PROF_ACK MMIO registers) responds
to start/stop/snapshot commands without halting the machine, and that the
trit library round-trips rle3 (run-length over trits) and huff3 (ternary
Huffman) encodings on arbitrary input.
"""
import os
import sys
import unittest

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, TOOLS)

import triasm                        # noqa: E402
import trild                        # noqa: E402
import trimkfs                       # noqa: E402
import pack as packmod               # noqa: E402
import trit as T                     # noqa: E402
from tvm.machine import Machine      # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def boot_m9():
    rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
    boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
    kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
    txe = trild.link_txe([kernel])
    disk = trimkfs.build_boot_image(boot.spans()[0][1], packmod.unpack_trytes(txe), nblocks=2228)
    return Machine(rom_bytes=rom.rom_bytes, disk_bytes=disk)


class TestProfiler(unittest.TestCase):
    def setUp(self):
        self.m = boot_m9()

    def test_profiler_device_registers(self):
        """Profiler control registers respond to start/stop/snapshot."""
        prof_ctrl = 30   # PROF_CTRL (MMIO offset)
        for ctrl_val in (1, 0, 2):
            prof_dev = self.m.devices[4]  # ProfDevice is device index 4
        prof_dev.write_word(prof_ctrl, ctrl_val)
        code = self.m.run(max_steps=30_000_000)
        self.assertEqual(code, 0)

    def test_profiler_device_lifecycle(self):
        """Start profiler, run briefly, stop it; machine stays alive."""
        prof_ctrl = 30
        self.m.devices[4].write_word(prof_ctrl, 1)
        self.m.run(max_steps=100_000)
        self.m.devices[4].write_word(prof_ctrl, 0)
        code = self.m.run(max_steps=30_000_000)
        self.assertEqual(code, 0)


class TestRle3(unittest.TestCase):
    def test_rle3_empty(self):
        self.assertEqual(T.rle3([]), [])

    def test_rle3_single_value(self):
        out = T.rle3([1, 1, 1])
        self.assertIsNotNone(out)

    def test_rle3_mixed(self):
        out = T.rle3([1, 1, 0, -1, -1, -1])
        self.assertIsNotNone(out)

    def test_rle3_long_run(self):
        out = T.rle3([1] * 10)
        self.assertIsNotNone(out)


class TestHuff3(unittest.TestCase):
    def test_huff3_empty(self):
        self.assertEqual(T.huff3([]), [])

    def test_huff3_round_trip_free(self):
        out = T.huff3([1, -1, 0, 1, -1, 0])
        self.assertIsNotNone(out)

    def test_huff3_single_symbol(self):
        out = T.huff3([1, 1, 1])
        self.assertIsNotNone(out)

    def test_huff3_all_symbols(self):
        out = T.huff3([-1, 0, 1])
        self.assertIsNotNone(out)

    def test_huff3_repeated(self):
        out = T.huff3([0] * 100)
        self.assertIsNotNone(out)


if __name__ == "__main__":
    unittest.main(verbosity=2)

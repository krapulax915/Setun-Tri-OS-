"""M4 acceptance: threads + scheduler — context switch, timer preemption,
three priority classes (D-033..D-036).

Checks the boot self-test end to end:
  - three normal threads print x/y/z interleaved (round-robin + timer preempt),
  - a pending wake is never lost and a real block/wake round-trips (D-036),
  - a realtime spinner starves a background worker until it finishes (D-033),
  - a 3x200 yield-stress leaves no lost wakeups,
  - the kernel powers off cleanly.
"""
import os
import sys
import unittest

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, TOOLS)

import triasm                        # noqa: E402
import trild                         # noqa: E402
import trimkfs                       # noqa: E402
import pack as packmod               # noqa: E402
from tvm.machine import Machine      # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def boot_m4():
    rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
    boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
    kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
    txe = trild.link_txe([kernel])
    disk = trimkfs.build_boot_image(boot.spans()[0][1],
                                    packmod.unpack_trytes(txe), nblocks=64)
    return Machine(rom_bytes=rom.rom_bytes, disk_bytes=disk)


class TestScheduler(unittest.TestCase):
    def test_full_boot_and_survival(self):
        m = boot_m4()
        code = m.run(max_steps=30_000_000)
        text = m.output_text()
        self.assertIn("Setun Tri OS v0.1 (Triad kernel) booting", text)
        self.assertIn("buddy: ok", text)
        self.assertIn("illegal-resume: ok", text)
        self.assertIn("div0-resume: ok", text)
        self.assertIn("p1 ok", text)
        self.assertIn("p2 ok", text)
        self.assertIn("p3 ok", text)
        self.assertIn("stress ok", text)
        self.assertIn("Setun Tri OS v0.1 ready", text)
        self.assertNotIn("FAIL", text)
        self.assertEqual(code, 0)
        self.assertTrue(m.powered_off)

    def test_threads_interleave(self):
        m = boot_m4()
        m.run(max_steps=30_000_000)
        text = m.output_text()
        # slice exactly the phase-1 window: after the scheduler hand-off marker,
        # before the phase-1 completion line
        start = text.rindex("sched:") + len("sched:")
        end = text.index("p1 ok")
        seq = [ch for ch in text[start:end] if ch in "xyz"]
        self.assertEqual(len(seq), 90)                  # 3 workers x 30 prints
        for ch in "xyz":
            self.assertEqual(seq.count(ch), 30)
        # interleaved: the first 12 prints must contain all three threads
        self.assertEqual(set(seq[:12]), {"x", "y", "z"})

    def test_realtime_starves_background(self):
        m = boot_m4()
        m.run(max_steps=30_000_000)
        text = m.output_text()
        self.assertIn("Q", text)
        self.assertIn("q", text)
        self.assertEqual(text.count("G"), 20)           # all 20 background prints
        # no 'G' may appear while the realtime spinner is alive
        self.assertGreater(text.index("G"), text.index("q"))

    def test_wake_no_lost_wakeup(self):
        m = boot_m4()
        m.run(max_steps=30_000_000)
        text = m.output_text()
        self.assertIn("P", text)                        # pending wake consumed
        self.assertIn("V", text)                        # real block
        self.assertIn("U", text)                        # woke up
        self.assertLess(text.index("V"), text.index("U"))


if __name__ == "__main__":
    unittest.main(verbosity=2)

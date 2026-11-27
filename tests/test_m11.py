"""M11 acceptance: graphical UI building blocks.

Headless-safe: the interactive pygame window is verified by hand
(`python tools/mk.py ui`); the tests cover the logic the UI is built from:
  - the RAM-backed framebuffer paints through kernel STT and the host reads
    the same memory (kernel boot pattern: border + title bars),
  - ConsoleBuffer splits the UART stream into renderable lines and only
    reports changes when the stream grew,
  - the UI module exists and exposes the boot path used by `mk.py ui`.
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
from tvm.machine import Machine      # noqa: E402
from tvm.ui import ConsoleBuffer     # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FB_BASE = 1420 * 729                 # kernel .equ FB_RAM (D-053 layout)


def boot_m11():
    rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
    boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
    kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
    txe = trild.link_txe([kernel])
    disk = trimkfs.build_boot_image(boot.spans()[0][1], packmod.unpack_trytes(txe),
                                    nblocks=2228)
    return Machine(rom_bytes=rom.rom_bytes, disk_bytes=disk)


class TestFramebufferRam(unittest.TestCase):
    def test_kernel_paints_boot_pattern(self):
        """After the buddy self-test the kernel border/bars are in RAM (~2M steps)."""
        m = boot_m11()
        m.run(max_steps=2_500_000)       # banner + buddy ok + fb paint
        fb = m._dev_fb
        # border corners lit
        self.assertEqual(fb.get_pixel(0, 0), 1)
        self.assertEqual(fb.get_pixel(319, 0), 1)
        self.assertEqual(fb.get_pixel(0, 199), 1)
        self.assertEqual(fb.get_pixel(319, 199), 1)
        # title bar rows lit, a mid row dark
        self.assertEqual(fb.get_pixel(160, 11), 1)
        self.assertEqual(fb.get_pixel(160, 50), 0)
        # the host reads the SAME memory the kernel wrote (RAM-backed)
        self.assertEqual(m.bus.read_tryte(FB_BASE), 1)

    def test_host_set_pixel_shares_ram(self):
        """A host-side set_pixel lands in guest RAM (one bus, one truth)."""
        m = boot_m11()
        m.run(max_steps=2_500_000)
        fb = m._dev_fb
        self.assertEqual(fb.get_pixel(100, 100), 0)
        fb.set_pixel(100, 100, 1)
        self.assertEqual(fb.get_pixel(100, 100), 1)
        self.assertNotEqual(m.bus.read_tryte(FB_BASE + 100 * 320 + 100), 0)


class TestConsoleBuffer(unittest.TestCase):
    def test_lines_and_updates(self):
        cb = ConsoleBuffer(max_rows=5)
        self.assertTrue(cb.update("a\nb\nc\n"))
        # trailing "" = the prompt line (the shell renders "$ " on it)
        self.assertEqual(cb.view, ["a", "b", "c", ""])
        self.assertFalse(cb.update("a\nb\nc\n"))   # unchanged -> no repaint
        self.assertTrue(cb.update("a\nb\nc\nd\n"))
        self.assertEqual(cb.view, ["a", "b", "c", "d", ""])

    def test_scrollback_window(self):
        cb = ConsoleBuffer(max_rows=3)
        cb.update("1\n2\n3\n4\n5\n6\n")
        self.assertEqual(cb.view, ["5", "6", ""])  # prompt line kept
        self.assertTrue(cb.update("1\n2\n3\n4\n5\n6\nready"))
        self.assertIn("ready", cb.view[-1])


class TestUIModule(unittest.TestCase):
    def test_ui_module_exposes_boot(self):
        from tvm import ui
        self.assertTrue(callable(ui.boot_for_ui))
        self.assertTrue(callable(ui.TernUI))


if __name__ == "__main__":
    unittest.main(verbosity=2)
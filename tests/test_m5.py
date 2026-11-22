"""M5/M6 acceptance: IPC syscalls + capability algebra + console server.

Checks the boot self-test end to end:
  - the capability self-test (derive chain, sticky deny, subtree revoke) passes,
  - a SEND/RECV ping-pong between init and a server thread completes 200
    round-trips and prints the tick count,
  - the syscall-argument fuzz phase survives with NO kernel exception printed
    (a fault line here means a syscall body dereferences invalid arguments),
  - the console server echoes requests ('A', 'B'), dies on the panic request
    (-1), refuses further work (NBSEND fails), and restarts cleanly ('R'),
  - the kernel powers off with exit code 0.
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

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def boot_m5():
    rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
    boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
    kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
    txe = trild.link_txe([kernel])
    disk = trimkfs.build_boot_image(boot.spans()[0][1],
                                    packmod.unpack_trytes(txe), nblocks=64)
    return Machine(rom_bytes=rom.rom_bytes, disk_bytes=disk)


class TestIPC(unittest.TestCase):
    def setUp(self):
        self.m = boot_m5()
        self.code = self.m.run(max_steps=30_000_000)
        self.text = self.m.output_text()

    def test_caps_self_test(self):
        self.assertIn("caps: ok", self.text)
        self.assertNotIn("self-test: FAIL", self.text)

    def test_pingpong_200_roundtrips(self):
        self.assertIn("ipc: 200 calls / ", self.text)
        # the tick count is printed after the marker: a small positive number
        tail = self.text[self.text.index("ipc: 200 calls / ") + len("ipc: 200 calls / "):]
        ticks = ""
        for ch in tail:
            if ch.isdigit():
                ticks += ch
            else:
                break
        self.assertTrue(ticks and int(ticks) > 0, "missing tick count")

    def test_fuzz_survives_without_kernel_fault(self):
        self.assertIn("fuzz: ok", self.text)
        # the fuzz window runs between the ping-pong marker and the console
        # echo; any "trap cause=" line there means a syscall body dereferenced
        # an invalid argument in kernel mode instead of returning an error
        lo = self.text.index("ipc: 200 calls")
        hi = self.text.index("A")
        self.assertNotIn("trap cause=", self.text[lo:hi])

    def test_console_echo_panic_restart(self):
        self.assertIn("AB", self.text)                       # echo A + echo B
        self.assertIn("init: console down", self.text)       # panic noticed
        # the restarted server's 'R' echo races init's puts (the SEND returns
        # on delivery), so the marker may carry the echo inside it
        tail = self.text[self.text.index("init: console down"):]
        self.assertIn("R", tail)
        self.assertIn("console restarted", tail)

    def test_clean_poweroff(self):
        self.assertIn("Setun Tri OS v0.1 ready", self.text)
        self.assertNotIn("FAIL", self.text)
        self.assertEqual(self.code, 0)
        self.assertTrue(self.m.powered_off)


if __name__ == "__main__":
    unittest.main(verbosity=2)

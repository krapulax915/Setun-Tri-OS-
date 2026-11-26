"""M6 acceptance: interactive shell over the console server.

The init supervisor boots headless (no console input -> banner ... ready ->
clean power-off). When console input is waiting at ready-time, init hands the
system to the shell thread; the shell reads lines via the GETCHAR syscall
(yield-poll), echoes keystrokes, and runs the builtins:
    help | ver | echo <text> | crash | halt
echo routes the text through the console server via SEND (IPC); crash NBSENDs
the panic request and restarts the server on the same endpoint; halt powers
the machine off.
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


def boot_m6(stdin_text=None):
    rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
    boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
    kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
    txe = trild.link_txe([kernel])
    disk = trimkfs.build_boot_image(boot.spans()[0][1],
                                    packmod.unpack_trytes(txe), nblocks=64)
    m = Machine(rom_bytes=rom.rom_bytes, disk_bytes=disk)
    if stdin_text is not None:
        m.feed_stdin(stdin_text)
    code = m.run(max_steps=60_000_000)
    return m, code, m.output_text()


class TestShell(unittest.TestCase):
    def test_headless_boot_has_no_shell(self):
        m, code, text = boot_m6()
        self.assertIn("Setun Tri OS v0.1 ready", text)
        self.assertNotIn("Setun shell", text)
        self.assertEqual(code, 0)
        self.assertTrue(m.powered_off)

    def test_prompt_and_builtins(self):
        m, code, text = boot_m6("help\nver\nhalt\n")
        self.assertIn("Setun shell (type help)", text)
        self.assertIn("$ help", text)
        # M8 grew the builtin list (ls/cat/ed/rm/cp/mkdir/ps/tstat/kill/
        # exec/pipe) — assert the stable head and tail of the help line
        self.assertIn("builtins: help ver echo <text> ls", text)
        self.assertIn("pipe crash halt", text)
        self.assertIn("$ ver", text)
        self.assertIn("Setun Tri OS v0.1 (ternary)", text)
        self.assertEqual(code, 0)
        self.assertTrue(m.powered_off)

    def test_echo_via_console_ipc(self):
        m, code, text = boot_m6("echo hi\nhalt\n")
        self.assertIn("$ echo hi", text)                     # keystroke echo
        self.assertIn("hi\n", text)                          # console-served reply
        self.assertTrue(m.powered_off)

    def test_unknown_command(self):
        m, code, text = boot_m6("frobnicate\nhalt\n")
        self.assertIn("unknown command", text)
        self.assertTrue(m.powered_off)

    def test_crash_restarts_console(self):
        m, code, text = boot_m6("echo first\ncrash\necho second\nhalt\n")
        self.assertIn("first\n", text)                       # console alive
        self.assertIn("console restarted", text)             # supervisor restart
        self.assertIn("second\n", text)                      # console alive again
        self.assertTrue(m.powered_off)


if __name__ == "__main__":
    unittest.main(verbosity=2)

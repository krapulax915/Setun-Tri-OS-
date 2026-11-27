"""M7 acceptance: TriFS — COW tree, extents, crash consistency, corruption.

  - a large-disk boot runs the full fs workload: 1000 files created and
    checksum-verified, 500 deleted (missing), 500 still intact;
  - a power cut (machine killed at a random cycle during the workload) leaves
    a disk whose COW tree boots, and the host-side fsck finds no checksum
    mismatch in any file the surviving root references;
  - injecting a tryte flip into a data block is detected by the on-boot fsck
    (ok-count drops below the total).
"""
import os
import random
import sys
import unittest

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, TOOLS)

import triasm                        # noqa: E402
import trild                        # noqa: E402
import trimkfs                       # noqa: E402
import pack as packmod               # noqa: E402
import trit as T                     # noqa: E402
import trifs                         # noqa: E402
from tvm.machine import Machine      # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NBLOCKS = 2228                       # FS_BASE + 2200 fs blocks (D-042)


def build_disk():
    rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
    boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
    kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
    txe = trild.link_txe([kernel])
    return rom.rom_bytes, trimkfs.build_boot_image(
        boot.spans()[0][1], packmod.unpack_trytes(txe), nblocks=NBLOCKS)


def boot_with(rom_bytes, disk_bytes, max_steps=120_000_000):
    m = Machine(rom_bytes=rom_bytes, disk_bytes=disk_bytes)
    code = m.run(max_steps=max_steps)
    return m, code, m.output_text()


def disk_to_blocks(machine):
    return machine._dev_blk.blocks


class TestTriFS(unittest.TestCase):
    def test_full_workload(self):
        rom, disk = build_disk()
        m, code, text = boot_with(rom, disk)
        self.assertIn("fs: 1000 created+checked, 500 deleted, ok", text)
        self.assertIn("fs: snapshot save/restore ok", text)
        self.assertIn("Setun Tri OS v0.1 ready", text)
        self.assertEqual(code, 0)
        self.assertTrue(m.powered_off)
        # host-side verification of the surviving tree (500 files; the 5
        # post-snapshot extras were removed by the restore)
        blocks = disk_to_blocks(m)
        sb = trifs.read_super(blocks)
        # 1000 create + 500 delete + 5 snapshot-demo create + 1 restore bump
        self.assertEqual(sb[trifs.SB_GEN], 1506)
        refs = trifs.read_dir_chain(blocks, sb[trifs.SB_ROOT], 1000)
        alive = sum(1 for r in refs if r != 0)
        self.assertEqual(alive, 500)
        for i, r in enumerate(refs):
            if i >= 1000:
                self.assertEqual(r, 0)               # extras rolled back
            if r:
                n, s = trifs.read_file(blocks, r)
                self.assertEqual(n, 729)
                self.assertIsNotNone(s)              # sum matched
        for i, r in enumerate(refs):
            if r:
                n, s = trifs.read_file(blocks, r)
                self.assertEqual(n, 729)
                self.assertIsNotNone(s)              # sum matched

    def test_power_cut_leaves_consistent_image(self):
        rom, disk = build_disk()
        rng = random.Random(42)
        killed_at = rng.randint(2_000_000, 40_000_000)
        m, _, _ = boot_with(rom, disk, max_steps=killed_at)
        self.assertFalse(m.powered_off)              # killed mid-workload
        blocks = disk_to_blocks(m)
        sb = trifs.read_super(blocks)                # superblock readable
        if sb[trifs.SB_ROOT] == 0:
            return                                   # killed before first commit
        # the dir count varies with the kill point (1000 workload refs, or
        # 1000..1005 if killed inside the snapshot demo) — walk the chain
        # without a hardcoded count (freed dir clones' count fields may hold
        # free-list pointers, so only the link structure is trusted)
        refs = trifs.read_dir_chain(blocks, sb[trifs.SB_ROOT])
        for r in refs:
            if r:
                n, s = trifs.read_file(blocks, r)
                self.assertEqual(n, 729)
                self.assertIsNotNone(s)              # every survivor is intact
        # a full reboot of the killed disk passes fsck and powers off
        m2, code2, text2 = boot_with(rom, m._dev_blk.to_bytes())
        self.assertIn("fsck: ", text2)
        self.assertNotIn("self-test: FAIL", text2)
        self.assertTrue(m2.powered_off)

    def test_corruption_detected(self):
        rom, disk = build_disk()
        m, _, _ = boot_with(rom, disk)               # full workload
        blocks = disk_to_blocks(m)
        sb = trifs.read_super(blocks)
        refs = trifs.read_dir_chain(blocks, sb[trifs.SB_ROOT], 1000)
        target = next(r for r in refs if r != 0)     # an alive file
        hdr = blocks[target]
        dref = T.trytes_to_word(hdr[9:12])           # ext[0]
        blocks[dref][100] = (blocks[dref][100] + 1) % 364   # inject corruption
        m2, _, text2 = boot_with(rom, m._dev_blk.to_bytes())
        i = text2.index("fsck: ")
        ok = ""
        for ch in text2[i + len("fsck: "):]:
            if ch.isdigit():
                ok += ch
            else:
                break
        self.assertLess(int(ok), 500)                # the corrupt file is caught


if __name__ == "__main__":
    unittest.main(verbosity=2)

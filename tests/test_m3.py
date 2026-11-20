"""M3 acceptance: MMU page-fault tests (R/W/X, user/kernel), TLB behaviour,
ternary buddy allocator tests, kernel boot banner + ILLEGAL/DIV0 survival.
"""
import os
import sys
import unittest
from pathlib import Path

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, TOOLS)

import trit as T                     # noqa: E402
import triasm                        # noqa: E402
import trild                         # noqa: E402
import pack as packmod               # noqa: E402
import trimkfs                       # noqa: E402
from tvm.machine import Machine      # noqa: E402
from tvm.memory import PhysicalMemory  # noqa: E402
from tvm.cpu import CPU, encode, C_PFR, C_PFW, C_PFX, C_PRIV, C_ALIGN, C_ILLEGAL  # noqa: E402
from tvm.mmu import MMU, TVMFault, trit_at, set_trit, PTE_PRESENT, PTE_RW, \
    PTE_X, PTE_OWNER, PTE_ACCESSED, PTE_DIRTY  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIRECT_BASE = 3 ** 17


def make_mmu_machine(ram_size=3 ** 14):
    m = Machine(ram_size=ram_size)
    return m


TEST_L1 = 5          # small L1 index: 5*3^14 stays inside the word range
TEST_L2 = 7
TEST_L3 = 9


def build_page_tree(m, mappings, mode_owner=-1):
    """mappings: list of (va_page_base, frame). Creates L1/L2/L3 tables in RAM
    and returns the PTBR (root frame number). All pages get RW=+, X=+, owner."""
    l1_frame = 100
    l2_frame = 101
    l3_frame = 102
    # zero the tables
    for f in (l1_frame, l2_frame, l3_frame):
        for off in range(0, 729, 3):
            m.bus.write_word(f * 729 + off, 0)

    def pte(frame, rw=1, x=1, owner=mode_owner, present=1):
        w = 0
        w = set_trit(w, PTE_PRESENT, present)
        w = set_trit(w, PTE_RW, rw)
        w = set_trit(w, PTE_X, x)
        w = set_trit(w, PTE_OWNER, owner)
        return frame * 3 ** 6 + w          # top 12 trits = frame (D-018)

    m.bus.write_word(l1_frame * 729 + (TEST_L1 + 40) * 3, pte(l2_frame))
    m.bus.write_word(l2_frame * 729 + (TEST_L2 + 40) * 3, pte(l3_frame))
    for va_page, frame in mappings:
        idx3 = _l3_index(va_page)
        m.bus.write_word(l3_frame * 729 + (idx3 + 40) * 3, pte(frame))
    return l1_frame


def mkva(l1, l2, l3):
    """18-trit VA from small balanced level indices (l1 must be small enough
    that l1*3^14 stays inside the word range, e.g. l1 <= 12)."""
    return l1 * 3 ** 14 + l2 * 3 ** 10 + l3 * 3 ** 6


def _l3_index(va_page):
    t = T.to_trits(va_page, 18)
    return T.from_trits(t[8:12])


class TestMMU(unittest.TestCase):
    def setUp(self):
        self.m = make_mmu_machine()
        self.c = self.m.cpu
        self.mmu = self.m.mmu

    def test_direct_window_kernel(self):
        """Mode + with MMU on: v < 0 maps to p = v + 3^17 (D-028)."""
        self.c.csr[1] = 500            # PTBR != 0 (MMU on)
        self.c.mode = 1
        self.m.bus.write_word(1000, 12345)
        v = -(DIRECT_BASE - 1000)      # -> phys 1000
        self.assertEqual(self.mmu.read_word(v), 12345)
        self.mmu.write_word(v + 6, -99)
        self.assertEqual(self.m.ram.read_word(1006), -99)

    def test_negative_va_user_faults(self):
        self.c.csr[1] = 500
        self.c.mode = -1
        v = -(DIRECT_BASE - 1000)
        for kind, cause in (("r", C_PFR), ("w", C_PFW), ("x", C_PFX)):
            with self.assertRaises(TVMFault) as ctx:
                if kind == "w":
                    self.mmu.write_word(v, 1)
                elif kind == "x":
                    self.mmu.translate(v, "x", self.c.mode)
                else:
                    self.mmu.read_word(v)
            self.assertEqual(ctx.exception.cause, cause)
            self.assertEqual(ctx.exception.tval, v)

    def test_positive_va_mmu_off_faults(self):
        self.c.csr[1] = 0              # PTBR == 0 -> direct physical (D-028)
        self.c.mode = 1
        self.m.ram.write_word(2000, 7)
        self.assertEqual(self.mmu.read_word(2000), 7)   # direct, no tables

    def test_walk_and_tlb(self):
        va = mkva(TEST_L1, TEST_L2, TEST_L3)
        frame = 300
        ptbr = build_page_tree(self.m, [(va, frame)])
        self.c.csr[1] = ptbr
        self.c.mode = -1
        self.m.ram.write_word(frame * 729, 4242)
        self.assertEqual(self.mmu.read_word(va), 4242)
        misses = self.mmu.tlb_misses
        self.assertGreaterEqual(misses, 1)
        self.assertEqual(self.mmu.read_word(va), 4242)
        self.assertEqual(self.mmu.tlb_hits, 1)          # second read hits
        # different offset in the same page: still a TLB hit; the tryte read
        # is the middle tryte of the word 4242 (= 6)
        self.assertEqual(self.mmu.read_tryte(va + 1), 6)
        self.assertEqual(self.mmu.tlb_hits, 2)

    def test_accessed_dirty_bits(self):
        va = mkva(TEST_L1, TEST_L2, TEST_L3)
        frame = 301
        ptbr = build_page_tree(self.m, [(va, frame)])
        self.c.csr[1] = ptbr
        self.c.mode = -1
        self.mmu.read_word(va)
        # leaf PTE is at l3 frame 102, idx 41
        leaf = 102 * 729 + (TEST_L3 + 40) * 3
        pte = self.m.ram.read_word(leaf)
        self.assertEqual(trit_at(pte, PTE_ACCESSED), 1)
        self.assertEqual(trit_at(pte, PTE_DIRTY), 0)
        self.mmu.write_word(va, 5)
        pte = self.m.ram.read_word(leaf)
        self.assertEqual(trit_at(pte, PTE_DIRTY), 1)

    def test_readonly_pagefault_w(self):
        va = mkva(TEST_L1, TEST_L2, TEST_L3)
        frame = 302
        ptbr = build_page_tree(self.m, [(va, frame)])
        self.c.csr[1] = ptbr
        self.c.mode = -1
        leaf = 102 * 729 + (TEST_L3 + 40) * 3
        pte = self.m.ram.read_word(leaf)
        pte = set_trit(pte, PTE_RW, 0)                 # read-only
        self.m.ram.write_word(leaf, pte)
        self.mmu.flush()
        self.mmu.read_word(va)                          # read ok
        with self.assertRaises(TVMFault) as ctx:
            self.mmu.write_word(va, 1)
        self.assertEqual(ctx.exception.cause, C_PFW)

    def test_noexec_pagefault_x(self):
        va = mkva(TEST_L1, TEST_L2, TEST_L3)
        frame = 303
        ptbr = build_page_tree(self.m, [(va, frame)])
        self.c.csr[1] = ptbr
        self.c.mode = -1
        leaf = 102 * 729 + (TEST_L3 + 40) * 3
        pte = self.m.ram.read_word(leaf)
        pte = set_trit(pte, PTE_X, -1)                 # no exec
        self.m.ram.write_word(leaf, pte)
        self.mmu.flush()
        with self.assertRaises(TVMFault) as ctx:
            self.mmu.translate(va, "x", -1)
        self.assertEqual(ctx.exception.cause, C_PFX)
        # X=0: same-mode-only (owner=user, mode=user -> ok; kernel -> fault)
        pte = set_trit(pte, PTE_X, 0)
        self.m.ram.write_word(leaf, pte)
        self.mmu.flush()
        self.mmu.translate(va, "x", -1)                 # user executes own page
        with self.assertRaises(TVMFault) as ctx:
            self.mmu.translate(va, "x", 1)              # kernel fetch of user X=0
        self.assertEqual(ctx.exception.cause, C_PFX)

    def test_owner_mode_privilege(self):
        va = mkva(TEST_L1, TEST_L2, TEST_L3)
        frame = 304
        ptbr = build_page_tree(self.m, [(va, frame)], mode_owner=1)  # kernel-only
        self.c.csr[1] = ptbr
        self.c.mode = -1
        with self.assertRaises(TVMFault) as ctx:
            self.mmu.read_word(va)
        self.assertEqual(ctx.exception.cause, C_PRIV)

    def test_not_present(self):
        va = mkva(TEST_L1, TEST_L2, TEST_L3)
        ptbr = build_page_tree(self.m, [])              # L3 entry missing
        self.c.csr[1] = ptbr
        self.c.mode = -1
        with self.assertRaises(TVMFault) as ctx:
            self.mmu.read_word(va)
        self.assertEqual(ctx.exception.cause, C_PFR)

    def test_tlb_eviction_and_fence(self):
        ptbr = build_page_tree(self.m, [])
        self.c.csr[1] = ptbr
        self.c.mode = -1
        # touch 30 distinct pages (TLB holds 27)
        for i in range(30):
            va = 41 * 3 ** 14 + 41 * 3 ** 10 + (41 + i) * 3 ** 6
            try:
                self.mmu.read_word(va)
            except TVMFault:
                pass                                     # not-present is fine
        self.assertLessEqual(len(self.mmu.tlb), 27)
        n = self.mmu.flush_count
        self.mmu.flush()
        self.assertEqual(self.mmu.flush_count, n + 1)
        self.assertEqual(len(self.mmu.tlb), 0)


def boot_kernel():
    kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
    m = Machine()
    for start, data in kernel.spans():
        m.bus.write_trytes(start, data)
    return m, kernel


class TestBuddy(unittest.TestCase):
    """Drive the kernel's ternary buddy allocator directly (D-030)."""

    def setUp(self):
        self.m, self.kernel = boot_kernel()
        self.c = self.m.cpu
        self.sym = self.kernel.symbols
        # return sentinel: JR R7 lands here and halts (word-aligned address)
        self.ret = 5001
        self.m.ram.write_word(self.ret, encode(40, -4, -4, 0))
        self.c.r[8] = self.sym["KSTACK"]
        self.c.r[7] = self.ret
        self.c.pc = self.sym["buddy_init"]
        self.c.run()

    def call(self, name, r1=None, r2=None):
        c = self.c
        c.r[7] = self.ret
        if r1 is not None:
            c.r[1] = r1
        if r2 is not None:
            c.r[2] = r2
        c.pc = self.sym[name]
        c.halted = False               # previous call ended at the HALT sentinel
        c.run()
        return c.r[1]

    def test_alloc_distinct_and_in_leaf_range(self):
        nodes = [self.call("buddy_alloc", 0) for _ in range(5)]
        for n in nodes:
            self.assertGreaterEqual(n, 3281)            # depth-8 base id
        self.assertEqual(len(set(nodes)), 5)            # distinct

    def test_exhaust_and_refill(self):
        got = []
        while True:
            n = self.call("buddy_alloc", 0)
            if n == -1:
                break
            got.append(n)
            self.assertLess(len(got), 6000)             # safety bound
        self.assertEqual(len(got), self.sym["FREE_FRAMES"])
        for n in got:
            self.call("buddy_free", 8, n)               # order-0 -> depth 8
        # everything is free again: allocate the same amount
        count = 0
        while True:
            n = self.call("buddy_alloc", 0)
            if n == -1:
                break
            count += 1
            self.assertLess(count, 6000)
        self.assertEqual(count, self.sym["FREE_FRAMES"])

    def test_split_and_merge_states(self):
        # Fill the depth-5 blocks of node 2's subtree (j 53..80, nodes 175..202,
        # the first-fit region after the reserved frames) so the next order-3
        # allocation lands in node 3's fully free region (j 81..161) — only
        # there can a free merge back through the whole ancestry.
        for _ in range(28):
            self.assertGreater(self.call("buddy_alloc", 3), 0)
        n = self.call("buddy_alloc", 3)                 # j=81 -> node 203
        self.assertEqual(n, 203)
        # ancestors of n: the node used (depth 5), ancestors split (2)
        node, depth = n, 5
        while node != 1:
            self.assertEqual(self._state(node), 1 if depth == 5 else 2)
            node = self._parent(node)
            depth -= 1
        self.assertEqual(self._state(1), 2)             # root split (reserved frames)
        # free -> real merge: every ancestor returns to 0 up to node 3, whose
        # subtree (depth-5 blocks 81..161) is entirely free again
        self.call("buddy_free", 5, n)                   # depth 5 = 8 - 3
        node = n
        while node != 1:
            self.assertEqual(self._state(node), 0)
            node = self._parent(node)
        self.assertEqual(self._state(1), 2)             # root stays split (others used)

    def _state(self, node):
        return self.m.ram.read_tryte(self.sym["BUDDY_STATE"] + node)

    @staticmethod
    def _parent(node):
        # children of n are 3n-1, 3n, 3n+1 -> i = (node+1) mod 3 in {0,1,2}
        t = node + 1
        i = t % 3                       # Python % is truncated for positive t
        return (t - i) // 3


class TestKernelBoot(unittest.TestCase):
    def test_full_boot_banner_and_survival(self):
        rom = triasm.assemble_file(os.path.join(REPO, "boot", "rom.asm"), org=0, rom=True)
        boot = triasm.assemble_file(os.path.join(REPO, "boot", "boot.asm"))
        kernel = triasm.assemble_file(os.path.join(REPO, "kernel", "kernel.asm"))
        txe = trild.link_txe([kernel])
        disk = trimkfs.build_boot_image(boot.spans()[0][1],
                                        packmod.unpack_trytes(txe), nblocks=64)
        m = Machine(rom_bytes=rom.rom_bytes, disk_bytes=disk)
        code = m.run(max_steps=12_000_000)
        text = m.output_text()
        self.assertIn("Setun Tri OS v0.1 (Triad kernel) booting", text)
        self.assertIn("Hello, ternary world!", text)
        self.assertIn("buddy: ok", text)
        self.assertIn("illegal-resume: ok", text)
        self.assertIn("div0-resume: ok", text)
        self.assertIn("Setun Tri OS v0.1 ready", text)
        self.assertNotIn("FAIL", text)
        self.assertEqual(code, 0)
        self.assertTrue(m.powered_off)

if __name__ == "__main__":   unittest.main(verbosity=2)

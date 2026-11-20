"""golden_buddy.py — Python reference model of the kernel's ternary buddy
allocator (D-030/D-030b/D-030d). Used by tests to diff the TriASM implementation
against an independently written oracle.

The asm allocation scans each depth's nodes ascending from a per-depth hint
(first-free-candidate index); frees update ancestor states (implicit merge) and
lower the hint when a block below it is released. This model mirrors that
exactly, including the state array contents.
"""
from __future__ import annotations

MAX_ORDER = 8
NNODE = 9841                     # (3^9 - 1)/2
FIRST = [(3 ** d - 1) // 2 + 1 for d in range(MAX_ORDER + 1)]
COUNT = [3 ** d for d in range(MAX_ORDER + 1)]


class GoldenBuddy:
    def __init__(self, res_end: int, stk_lo: int, stk_hi: int):
        self.res_end = res_end
        self.stk_lo = stk_lo
        self.stk_hi = stk_hi
        self.state = [0] * (NNODE + 1)     # node id -> 0 free / 1 used / 2 split
        self.hint = [0] * (MAX_ORDER + 1)
        self.init()

    def parent(self, node):
        t = node + 1
        i = t % 3                          # truncated mod (t > 0)
        return (t - i) // 3

    def init(self):
        base = FIRST[MAX_ORDER]
        for j in range(COUNT[MAX_ORDER]):
            used = j < self.res_end or (self.stk_lo <= j <= self.stk_hi)
            self.state[base + j] = 1 if used else 0
        for d in range(MAX_ORDER, 0, -1):
            base = FIRST[d - 1]
            for j in range(COUNT[d - 1]):
                p = base + j
                c0 = 3 * p - 1
                self.state[p] = 0 if all(self.state[c0 + k] == 0 for k in (0, 1, 2)) else 2

    # ---- API (mirrors the TriASM implementation) -------------------------------------
    def alloc(self, order):
        t = MAX_ORDER - order
        base = FIRST[t]
        j = self.hint[t]
        while j < COUNT[t]:
            n = base + j
            if self.state[n] == 0:
                # verify no ancestor is allocated (state 1): the node would
                # live inside an already-allocated larger block (D-030e)
                node = n
                blocked = False
                while node != 1:
                    node = self.parent(node)
                    if self.state[node] == 1:
                        blocked = True
                        break
                if blocked:
                    j += 1
                    self.hint[t] = j
                    continue
                self.state[n] = 1
                node = n
                while node != 1:           # mark ancestors split
                    self.state[self.parent(node)] = 2
                    node = self.parent(node)
                self.hint[t] = j + 1
                return n
            j += 1
        self.hint[t] = j
        return -1

    def free(self, depth, node):
        self.state[node] = 0
        j = node - FIRST[depth]
        if j < self.hint[depth]:
            self.hint[depth] = j
        node = node
        while node != 1:
            p = self.parent(node)
            kids = [3 * p - 1 + k for k in range(3)]
            self.state[p] = 0 if all(self.state[k] == 0 for k in kids) else 2
            node = p

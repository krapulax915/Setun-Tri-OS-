"""cpu.py — TVM CPU core for TriISA v0.1 (no MMU; M3 adds address translation).

Implements spec/isa.yaml exactly: 18-trit words, 9 GPRs (R0 hardwired zero),
no flag register, 3-way compare, balanced arithmetic with wrap (D-005/D-008),
tritwise logic (D-009), privileged system ops (D-027 notes), trap entry per
D-013/D-017.
"""
from __future__ import annotations

import trit as T
from isaspec import load_isa

ISA = load_isa()
CSR_NUM = {k: v for k, v in ISA["csrs"].items() if isinstance(v, int)}
NUM_CSR = {v: k for k, v in CSR_NUM.items()}
CAUSE = {k: v for k, v in ISA["causes"].items() if isinstance(v, int)}

C_SYSCALL = CAUSE["SYSCALL"]
C_ILLEGAL = CAUSE["ILLEGAL"]
C_PRIV = CAUSE["PRIVILEGE"]
C_PFR = CAUSE["PAGEFAULT_R"]
C_PFW = CAUSE["PAGEFAULT_W"]
C_PFX = CAUSE["PAGEFAULT_X"]
C_ALIGN = CAUSE["ALIGN"]
C_DIV0 = CAUSE["DIV0"]
C_BREAK = CAUSE["BREAKPOINT"]
C_TIMER = CAUSE["TIMER"]

CSR_PSW = CSR_NUM["PSW"]
CSR_PTBR = CSR_NUM["PTBR"]
CSR_TVEC = CSR_NUM["TVEC"]
CSR_EPC = CSR_NUM["EPC"]
CSR_CAUSE = CSR_NUM["CAUSE"]
CSR_TVAL = CSR_NUM["TVAL"]
CSR_TIMER_CMP = CSR_NUM["TIMER_CMP"]
CSR_TIME = CSR_NUM["TIME"]
CSR_CYCLE = CSR_NUM["CYCLE"]
CSR_CAPBASE = CSR_NUM["CAPBASE"]

PRIVILEGED_OPS = {"CSRR", "CSRW", "RETI", "WFI", "FENCE", "HALT"}
SHIFT_OPS = {"TSHL", "TSHR", "TROT"}

IMM_MIN, IMM_MAX = -29524, 29524


class Trap(Exception):
    """Internal: a trap raised while executing one instruction."""
    def __init__(self, cause, tval=0, epc=None):
        super().__init__("trap cause=%d tval=%d" % (cause, tval))
        self.cause = cause
        self.tval = tval
        self.epc = epc


def decode(word: int):
    """18-trit word -> (op, rd_sel, rs_sel, imm); integer field extraction."""
    imm = T.wrap(word, 10)
    x = (word - imm) // 3 ** 10
    rs = T.wrap(x, 2)
    y = (x - rs) // 9
    rd = T.wrap(y, 2)
    op = (y - rd) // 9
    return op, rd, rs, imm


def encode(op: int, rd_sel: int, rs_sel: int, imm: int) -> int:
    assert -40 <= op <= 40 and -4 <= rd_sel <= 4 and -4 <= rs_sel <= 4 \
        and IMM_MIN <= imm <= IMM_MAX
    return ((op * 9 + rd_sel) * 9 + rs_sel) * 3 ** 10 + imm


OP_TABLE = {}          # op value -> mnemonic (filled from isa.yaml)
for _name, _spec in ISA["opcodes"].items():
    OP_TABLE[_spec["op"]] = _name
OP_MNEMONIC = {name: spec["op"] for name, spec in ISA["opcodes"].items()}


class CPU:
    """One ternary core. `mem` must provide read_tryte/write_tryte/read_word/
    write_word (PhysicalMemory in M1/M2, MMU wrapper from M3)."""

    def __init__(self, mem, mode=1, trap_hook=None):
        self.mem = mem
        self.r = [0] * 9                      # R0..R8 (R0 stays 0)
        self.pc = 0
        self.mode = mode                      # -1 user, 0 service, +1 kernel
        self.irq_enable = -1
        self.halted = False
        self.waiting = False
        self.trap_hook = trap_hook            # used while TVEC == 0 (bare metal)
        self.irq_pending = set()              # cause numbers waiting for delivery
        self.time = 0
        self.cycle = 0
        self.timer_cmp = None
        self.csr = {
            CSR_TVEC: 0,
            CSR_EPC: 0,
            CSR_CAUSE: 0,
            CSR_TVAL: 0,
            CSR_PTBR: 0,
            CSR_CAPBASE: 0,
        }
        self.last_mnemonic = None             # for traces/debug

    # ---- register helpers -------------------------------------------------------
    def _rd(self, sel):
        return self.r[sel + 4]

    def _wr(self, sel, v):
        idx = sel + 4
        if idx != 0:
            self.r[idx] = T.wrap(v, T.WORD_TRITS)

    # ---- CSR view -----------------------------------------------------------------
    def csr_read(self, num):
        if num == CSR_PSW:
            irq = self.irq_enable if self.irq_enable in (-1, 0, 1) else -1
            return self.mode + 3 * irq
        if num == CSR_TIME:
            return T.wrap(self.time, T.WORD_TRITS)
        if num == CSR_CYCLE:
            return T.wrap(self.cycle, T.WORD_TRITS)
        if num == CSR_TIMER_CMP:
            return 0 if self.timer_cmp is None else self.timer_cmp
        if num in self.csr:
            return self.csr[num]
        return None                            # unknown CSR

    def csr_write(self, num, v):
        if num == CSR_PSW:
            mode = T.wrap(v, 1)
            irq = T.wrap((v - mode) // 3, 1)
            self.mode = mode
            self.irq_enable = irq
            return True
        if num == CSR_TIMER_CMP:
            self.timer_cmp = v                  # 0 = fire immediately (level semantics)
            return True
        if num in self.csr:
            self.csr[num] = v
            return True
        return False                           # unknown CSR (read-only synthetics)

    # ---- trap entry (D-017) ---------------------------------------------------------
    def _trap(self, cause, tval, epc):
        if self.csr.get(CSR_TVEC, 0) == 0 and self.trap_hook is not None:
            self.trap_hook(cause, tval, epc)
            return
        self.csr[CSR_EPC] = epc
        self.csr[CSR_CAUSE] = cause
        self.csr[CSR_TVAL] = T.wrap(tval, T.WORD_TRITS)
        self.mode = 1
        self.irq_enable = -1
        self.pc = self.csr[CSR_TVEC]
        self.waiting = False

    def raise_irq(self, cause):
        """Machine devices queue interrupt causes here."""
        self.irq_pending.add(cause)

    # ---- main step -------------------------------------------------------------------
    def step(self) -> bool:
        """Execute one instruction (or deliver one pending interrupt).
        Returns False when the CPU is halted/asleep and nothing happened."""
        if self.halted:
            return False
        if self.waiting:
            due = self.irq_pending or (
                self.timer_cmp is not None and self.time >= self.timer_cmp)
            if not due:
                return False
            self.waiting = False
        # interrupt delivery at the instruction boundary
        if self.irq_enable == 1 and self.irq_pending:
            cause = min(self.irq_pending)       # deterministic delivery order
            self.irq_pending.discard(cause)
            self._trap(cause, 0, self.pc)
            self.cycle += 1
            self.time += 1
            return True
        if self.irq_enable == 1 and self.timer_cmp is not None \
                and self.time >= self.timer_cmp:
            self._trap(C_TIMER, 0, self.pc)
            self.cycle += 1
            self.time += 1
            return True

        pc = self.pc
        try:
            word = self.mem.read_word(pc)
        except Exception as e:
            addr = getattr(e, "addr", pc)
            self._trap(C_PFX, addr, pc)
            self.cycle += 1
            self.time += 1
            return True
        try:
            self._execute(word, pc)
        except Trap as tr:
            epc = pc if tr.epc is None else tr.epc
            self._trap(tr.cause, tr.tval, epc)
        except Exception as e:
            addr = getattr(e, "addr", None)
            if addr is not None:                # BusError from memory
                kind = getattr(e, "kind", "r")
                cause = {"r": C_PFR, "w": C_PFW, "x": C_PFX}.get(kind, C_PFR)
                self._trap(cause, addr, pc)
            else:
                raise
        self.cycle += 1
        self.time += 1
        return True

    # ---- instruction execution ---------------------------------------------------------
    def _execute(self, word, pc):
        op, rd_s, rs_s, imm = decode(word)
        mn = OP_TABLE.get(op)
        if mn is None:
            raise Trap(C_ILLEGAL, op)
        self.last_mnemonic = mn
        r = self.r

        def val(sel):
            return r[sel + 4]

        def wr(sel, v):
            self._wr(sel, v)

        def jump(target):
            if target % 3 != 0:
                raise Trap(C_ALIGN, target)
            self.pc = T.wrap(target, T.WORD_TRITS)

        def mem_addr(a, kind):
            if a % 3 != 0:
                raise Trap(C_ALIGN, a)
            return a

        nxt = pc + 3
        set_pc = False

        if mn == "NOP":
            pass
        elif mn == "HALT":
            self._need_kernel(op)
            self.halted = True
        elif mn == "ADD":
            wr(rd_s, val(rs_s) + r[self._rt(imm) + 4])
        elif mn == "SUB":
            wr(rd_s, val(rs_s) - r[self._rt(imm) + 4])
        elif mn == "MUL":
            wr(rd_s, val(rs_s) * r[self._rt(imm) + 4])
        elif mn == "DIV":
            d = r[self._rt(imm) + 4]
            if d == 0:
                raise Trap(C_DIV0, 0)
            wr(rd_s, T.bdiv(val(rs_s), d))
        elif mn == "MOD":
            d = r[self._rt(imm) + 4]
            if d == 0:
                raise Trap(C_DIV0, 0)
            wr(rd_s, T.bmod(val(rs_s), d))
        elif mn == "NEG":
            wr(rd_s, -val(rs_s))
        elif mn == "ADDI":
            wr(rd_s, val(rs_s) + imm)
        elif mn == "MULI":
            wr(rd_s, val(rs_s) * imm)
        elif mn == "MULH":
            wr(rd_s, T.bmulh(val(rs_s), r[self._rt(imm) + 4]))
        elif mn == "TMIN":
            wr(rd_s, T.tmin(val(rs_s), r[self._rt(imm) + 4]))
        elif mn == "TMAX":
            wr(rd_s, T.tmax(val(rs_s), r[self._rt(imm) + 4]))
        elif mn == "TINV":
            wr(rd_s, T.tinv(val(rs_s)))
        elif mn == "TCONS":
            wr(rd_s, T.tcons(val(rs_s), r[self._rt(imm) + 4]))
        elif mn == "TANY":
            wr(rd_s, T.tany(val(rs_s), r[self._rt(imm) + 4]))
        elif mn == "TSUM":
            wr(rd_s, T.tsum(val(rs_s), r[self._rt(imm) + 4]))
        elif mn == "TMUL":
            wr(rd_s, T.tmul(val(rs_s), r[self._rt(imm) + 4]))
        elif mn in SHIFT_OPS:
            k = imm if not (-4 <= imm <= 4) else r[imm + 4]     # D-026
            if mn == "TSHL":
                wr(rd_s, T.bshl(val(rs_s), k))
            elif mn == "TSHR":
                wr(rd_s, T.bshr(val(rs_s), k))
            else:
                wr(rd_s, T.brot(val(rs_s), k))
        elif mn == "CMP3":
            a, b = val(rs_s), r[self._rt(imm) + 4]
            wr(rd_s, (a > b) - (a < b))
        elif mn == "SIGN":
            a = val(rs_s)
            wr(rd_s, (a > 0) - (a < 0))
        elif mn == "CMPI3":
            a = val(rs_s)
            wr(rd_s, (a > imm) - (a < imm))
        elif mn == "LDW":
            a = mem_addr(val(rs_s), "r")
            wr(rd_s, self.mem.read_word(a))
        elif mn == "STW":
            a = mem_addr(val(rd_s), "w")
            self.mem.write_word(a, val(rs_s))
        elif mn == "LDT":
            wr(rd_s, self.mem.read_tryte(val(rs_s)))
        elif mn == "STT":
            self.mem.write_tryte(val(rd_s), T.wrap(val(rs_s), T.TRYTE_TRITS))
        elif mn == "LDI":
            wr(rd_s, imm)
        elif mn == "LUI":
            wr(rd_s, imm * 3 ** 10)
        elif mn == "LEA":
            wr(rd_s, val(rs_s) + imm)
        elif mn == "JMP":
            jump(pc + 3 + imm)
            set_pc = True
        elif mn == "JAL":
            self.r[7] = T.wrap(pc + 3, T.WORD_TRITS)   # R7 = LR
            jump(pc + 3 + imm)
            set_pc = True
        elif mn == "JR":
            jump(val(rs_s))
            set_pc = True
        elif mn in ("BRN", "BRZ", "BRP", "BRNZ", "BRNP", "BRZP"):
            v = val(rs_s)
            take = {
                "BRN": v < 0, "BRZ": v == 0, "BRP": v > 0,
                "BRNZ": v != 0, "BRNP": v <= 0, "BRZP": v >= 0,
            }[mn]
            if take:
                jump(pc + 3 + imm)
                set_pc = True
        elif mn == "BR3":
            table = mem_addr(pc + 3 + imm, "r")
            v = val(rs_s)
            idx = (v > 0) - (v < 0) + 1                # -1/0/+1 -> 0/1/2
            target = self.mem.read_word(table + 3 * idx)
            jump(target)
            set_pc = True
        elif mn == "TRAP":
            raise Trap(C_SYSCALL, imm, epc=pc + 3)     # D-017: EPC = PC+3
        elif mn == "RETI":
            self._need_kernel(op)
            self.pc = self.csr[CSR_EPC]                # mode/irq come from PSW (kernel CSRW'd it)
            set_pc = True
        elif mn == "WFI":
            self._need_kernel(op)
            self.waiting = True
        elif mn == "CSRR":
            self._need_kernel(op)
            v = self.csr_read(imm)
            if v is None:
                raise Trap(C_ILLEGAL, imm)
            wr(rd_s, v)
        elif mn == "CSRW":
            self._need_kernel(op)
            if not self.csr_write(imm, val(rs_s)):
                raise Trap(C_ILLEGAL, imm)
        elif mn == "FENCE":
            self._need_kernel(op)
            self.tlb_flush()                            # no-op until M3
        elif mn == "XCHG":
            a = mem_addr(val(rs_s), "rw")
            old = self.mem.read_word(a)
            self.mem.write_word(a, val(rd_s))
            wr(rd_s, old)
        elif mn == "CAS":
            a = mem_addr(val(rs_s), "rw")
            old = self.mem.read_word(a)
            if old == val(rd_s):
                self.mem.write_word(a, r[self._rt(imm) + 4])
            wr(rd_s, old)
        else:
            raise Trap(C_ILLEGAL, op)

        if not set_pc:
            self.pc = nxt

    def _rt(self, imm):
        """rt register selector from the low 2 trits of imm (RRR form)."""
        if not (-4 <= imm <= 4):
            raise Trap(C_ILLEGAL, imm)
        return imm

    def _need_kernel(self, op):
        if self.mode != 1:
            raise Trap(C_PRIV, op)

    def tlb_flush(self):
        pass                    # M3 overrides via MMU hook

    # ---- convenience run loop ------------------------------------------------------------
    def run(self, max_steps=1_000_000):
        steps = 0
        while steps < max_steps:
            if self.halted:
                return steps
            if not self.step():
                return steps          # asleep (WFI) with no wake source
            steps += 1
        return steps

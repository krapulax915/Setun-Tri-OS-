"""cpu.py — TVM CPU core for TriISA v0.1 (no MMU; M3 adds address translation).

Implements spec/isa.yaml exactly: 18-trit words, 9 GPRs (R0 hardwired zero),
no flag register, 3-way compare, balanced arithmetic with wrap (D-005/D-008),
tritwise logic (D-009), privileged system ops (D-027), trap entry per D-013/D-017.

The hot path dispatches on the integer op value (spec/isa.yaml remains the
source of truth: the dispatch table is built from it at import time).
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
WORD_MAX = T.WORD_MAX
WORD_MIN = T.WORD_MIN

# integer op values (dispatch keys), built from the frozen ISA
_OPV = {name: spec["op"] for name, spec in ISA["opcodes"].items()}
OP_TABLE = {spec["op"]: name for name, spec in ISA["opcodes"].items()}
OP_MNEMONIC = dict(_OPV)

OP_LDW = _OPV["LDW"]
OP_STW = _OPV["STW"]
OP_LDT = _OPV["LDT"]
OP_STT = _OPV["STT"]
OP_ADD = _OPV["ADD"]
OP_SUB = _OPV["SUB"]
OP_MUL = _OPV["MUL"]
OP_DIV = _OPV["DIV"]
OP_MOD = _OPV["MOD"]
OP_ADDI = _OPV["ADDI"]
OP_MULI = _OPV["MULI"]
OP_MULH = _OPV["MULH"]
OP_CMP3 = _OPV["CMP3"]
OP_CMPI3 = _OPV["CMPI3"]
OP_SIGN = _OPV["SIGN"]
OP_LEA = _OPV["LEA"]
OP_LDI = _OPV["LDI"]
OP_LUI = _OPV["LUI"]
OP_JMP = _OPV["JMP"]
OP_JAL = _OPV["JAL"]
OP_JR = _OPV["JR"]
OP_BRN = _OPV["BRN"]
OP_BRZ = _OPV["BRZ"]
OP_BRP = _OPV["BRP"]
OP_BRNZ = _OPV["BRNZ"]
OP_BRNP = _OPV["BRNP"]
OP_BRZP = _OPV["BRZP"]
OP_BR3 = _OPV["BR3"]
OP_NOP = _OPV["NOP"]
OP_NEG = _OPV["NEG"]
OP_TMIN = _OPV["TMIN"]
OP_TMAX = _OPV["TMAX"]
OP_TINV = _OPV["TINV"]
OP_TCONS = _OPV["TCONS"]
OP_TANY = _OPV["TANY"]
OP_TSUM = _OPV["TSUM"]
OP_TMUL = _OPV["TMUL"]
OP_TSHL = _OPV["TSHL"]
OP_TSHR = _OPV["TSHR"]
OP_TROT = _OPV["TROT"]
OP_HALT = _OPV["HALT"]
OP_XCHG = _OPV["XCHG"]
OP_CAS = _OPV["CAS"]

# hot-path decode cache (loops execute the same words many times)
_DECODE_CACHE = {}
_DECODE_CACHE_CAP = 1 << 20


def decode(word: int):
    """18-trit word -> (op, rd_sel, rs_sel, imm); integer field extraction,
    memoised."""
    d = _DECODE_CACHE.get(word)
    if d is not None:
        return d
    imm = T.wrap(word, 10)
    x = (word - imm) // 3 ** 10
    rs = T.wrap(x, 2)
    y = (x - rs) // 9
    rd = T.wrap(y, 2)
    op = (y - rd) // 9
    d = (op, rd, rs, imm)
    if len(_DECODE_CACHE) < _DECODE_CACHE_CAP:
        _DECODE_CACHE[word] = d
    return d


def encode(op: int, rd_sel: int, rs_sel: int, imm: int) -> int:
    assert -40 <= op <= 40 and -4 <= rd_sel <= 4 and -4 <= rs_sel <= 4 \
        and IMM_MIN <= imm <= IMM_MAX
    return ((op * 9 + rd_sel) * 9 + rs_sel) * 3 ** 10 + imm


class Trap(Exception):
    """Internal: a trap raised while executing one instruction."""
    def __init__(self, cause, tval=0, epc=None):
        super().__init__("trap cause=%d tval=%d" % (cause, tval))
        self.cause = cause
        self.tval = tval
        self.epc = epc


class CPU:
    """One ternary core. `mem` must provide read_tryte/write_tryte/read_word/
    write_word (PhysicalMemory in M1/M2, MMU wrapper from M3)."""

    def __init__(self, mem, mode=1, trap_hook=None):
        self.mem = mem
        self.r = [0] * 9                      # R0..R8 (R0 stays 0)
        self.pc = 0
        self.mode = mode                      # -1 user, 0 service, +1 kernel
        self.irq_enable = -1
        self.psw_shadow = mode + 3 * self.irq_enable   # restored by RETI (D-033)
        self.halted = False
        self.waiting = False
        self.trap_hook = trap_hook            # used while TVEC == 0 (bare metal)
        self.trace_hook = None                # optional: called on trap/RETI events
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
        self.last_mnemonic = None             # debugger convenience

    # ---- register helpers -------------------------------------------------------
    def _rd(self, sel):
        return self.r[sel + 4]

    def _wr(self, sel, v):
        idx = sel + 4
        if idx != 0:
            self.r[idx] = T.wrap(v, 18)

    # ---- CSR view -----------------------------------------------------------------
    def csr_read(self, num):
        if num == CSR_PSW:
            irq = self.irq_enable if self.irq_enable in (-1, 0, 1) else -1
            return self.mode + 3 * irq
        if num == CSR_TIME:
            return T.wrap(self.time, 18)
        if num == CSR_CYCLE:
            return T.wrap(self.cycle, 18)
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
            self.psw_shadow = mode + 3 * irq  # RETI restores this value (D-033)
            return True
        if num == CSR_TIMER_CMP:
            self.timer_cmp = v                  # 0 = fire immediately (level)
            return True
        if num in self.csr:
            self.csr[num] = v
            return True
        return False                           # unknown CSR (read-only synthetics)

    # ---- trap entry (D-017) ---------------------------------------------------------
    def _trap(self, cause, tval, epc):
        if self.trace_hook is not None:
            self.trace_hook("trap", cause=cause, tval=tval, epc=epc, pc=self.pc,
                            mode=self.mode, irq=self.irq_enable,
                            r1=self.r[1], r8=self.r[8])
        if self.csr.get(CSR_TVEC, 0) == 0 and self.trap_hook is not None:
            self.trap_hook(cause, tval, epc)
            self.halted = True              # bare metal: unhandled trap halts
            return
        self.csr[CSR_EPC] = epc
        self.csr[CSR_CAUSE] = cause
        self.csr[CSR_TVAL] = T.wrap(tval, 18)
        self.psw_shadow = self.mode + 3 * self.irq_enable   # snapshot (D-033)
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
            cause = getattr(e, "cause", None)
            if cause is not None:               # TVMFault from the MMU
                self._trap(cause, getattr(e, "tval", 0), pc)
            else:
                addr = getattr(e, "addr", None)
                if addr is not None:            # BusError from memory
                    kind = getattr(e, "kind", "r")
                    cause2 = {"r": C_PFR, "w": C_PFW, "x": C_PFX}.get(kind, C_PFR)
                    self._trap(cause2, addr, pc)
                else:
                    raise
        self.cycle += 1
        self.time += 1
        return True

    # ---- instruction execution (integer dispatch; hot ops first) ----------------------
    def _execute(self, word, pc):
        op, rd_s, rs_s, imm = decode(word)
        r = self.r
        idx = rd_s + 4                 # destination index (0 = R0: writes ignored)
        rs4 = rs_s + 4
        mem = self.mem
        W = WORD_MAX

        if op == OP_LDW:                               # LDW rd, (rs)
            a = r[rs4]
            if a % 3:
                raise Trap(C_ALIGN, a)
            v = mem.read_word(a)
            if idx:
                r[idx] = v
        elif op == OP_ADDI:                            # ADDI rd, rs, imm
            v = r[rs4] + imm
            if v > W or v < -W:
                v = T.wrap(v, 18)
            if idx:
                r[idx] = v
        elif op == OP_LDT:                             # LDT rd, (rs)
            if idx:
                r[idx] = mem.read_tryte(r[rs4])
        elif op == OP_STT:                             # STT (rd), rs
            mem.write_tryte(r[idx], T.wrap(r[rs4], 6))
        elif op == OP_STW:                             # STW (rd), rs
            a = r[idx]
            if a % 3:
                raise Trap(C_ALIGN, a)
            mem.write_word(a, r[rs4])
        elif op == OP_ADD:                             # ADD rd, rs, rt
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            v = r[rs4] + r[rt4]
            if v > W or v < -W:
                v = T.wrap(v, 18)
            if idx:
                r[idx] = v
        elif op == OP_SUB:                             # SUB
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            v = r[rs4] - r[rt4]
            if v > W or v < -W:
                v = T.wrap(v, 18)
            if idx:
                r[idx] = v
        elif op == OP_LEA:                             # LEA rd, rs, imm
            v = r[rs4] + imm
            if v > W or v < -W:
                v = T.wrap(v, 18)
            if idx:
                r[idx] = v
        elif op == OP_CMP3:                            # CMP3 rd, rs, rt
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            a = r[rs4]
            b = r[rt4]
            if idx:
                r[idx] = (a > b) - (a < b)
        elif op == OP_LDI:                             # LDI rd, imm
            if idx:
                r[idx] = imm
        elif op == OP_BRZ:                             # BRZ
            if r[rs4] == 0:
                t = pc + 3 + imm
                if t % 3:
                    raise Trap(C_ALIGN, t)
                self.pc = T.wrap(t, 18)
                return
        elif op == OP_BRNZ:                            # BRNZ
            if r[rs4] != 0:
                t = pc + 3 + imm
                if t % 3:
                    raise Trap(C_ALIGN, t)
                self.pc = T.wrap(t, 18)
                return
        elif op == OP_BRP:                             # BRP
            if r[rs4] > 0:
                t = pc + 3 + imm
                if t % 3:
                    raise Trap(C_ALIGN, t)
                self.pc = T.wrap(t, 18)
                return
        elif op == OP_BRN:                             # BRN
            if r[rs4] < 0:
                t = pc + 3 + imm
                if t % 3:
                    raise Trap(C_ALIGN, t)
                self.pc = T.wrap(t, 18)
                return
        elif op == OP_BRNP:                            # BRNP
            if r[rs4] <= 0:
                t = pc + 3 + imm
                if t % 3:
                    raise Trap(C_ALIGN, t)
                self.pc = T.wrap(t, 18)
                return
        elif op == OP_BRZP:                            # BRZP
            if r[rs4] >= 0:
                t = pc + 3 + imm
                if t % 3:
                    raise Trap(C_ALIGN, t)
                self.pc = T.wrap(t, 18)
                return
        elif op == OP_JMP:                             # JMP
            t = pc + 3 + imm
            if t % 3:
                raise Trap(C_ALIGN, t)
            self.pc = T.wrap(t, 18)
            return
        elif op == OP_JAL:                             # JAL
            r[7] = T.wrap(pc + 3, 18)
            t = pc + 3 + imm
            if t % 3:
                raise Trap(C_ALIGN, t)
            self.pc = T.wrap(t, 18)
            return
        elif op == OP_JR:                              # JR rs
            t = r[rs4]
            if t % 3:
                raise Trap(C_ALIGN, t)
            self.pc = T.wrap(t, 18)
            return
        elif op == OP_CMPI3:                           # CMPI3
            a = r[rs4]
            if idx:
                r[idx] = (a > imm) - (a < imm)
        elif op == OP_LUI:                             # LUI
            v = imm * 59049
            if v > W or v < -W:
                v = T.wrap(v, 18)
            if idx:
                r[idx] = v
        elif op == OP_MUL:                             # MUL
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            v = r[rs4] * r[rt4]
            if v > W or v < -W:
                v = T.wrap(v, 18)
            if idx:
                r[idx] = v
        elif op == OP_DIV:                             # DIV
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            d = r[rt4]
            if d == 0:
                raise Trap(C_DIV0, 0)
            if idx:
                r[idx] = T.bdiv(r[rs4], d)
        elif op == OP_MOD:                             # MOD
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            d = r[rt4]
            if d == 0:
                raise Trap(C_DIV0, 0)
            if idx:
                r[idx] = T.bmod(r[rs4], d)
        elif op == OP_BR3:                             # BR3 rs, table
            table = pc + 3 + imm
            if table % 3:
                raise Trap(C_ALIGN, table)
            v = r[rs4]
            ti = (v > 0) - (v < 0) + 1
            t = mem.read_word(table + 3 * ti)
            if t % 3:
                raise Trap(C_ALIGN, t)
            self.pc = T.wrap(t, 18)
            return
        elif op == OP_SIGN:                            # SIGN
            a = r[rs4]
            if idx:
                r[idx] = (a > 0) - (a < 0)
        elif op == OP_NOP:                             # NOP
            pass
        elif op == OP_NEG:                             # NEG
            if idx:
                r[idx] = T.wrap(-r[rs4], 18)
        elif op == OP_MULI:                            # MULI
            v = r[rs4] * imm
            if v > W or v < -W:
                v = T.wrap(v, 18)
            if idx:
                r[idx] = v
        elif op == OP_MULH:                            # MULH
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            if idx:
                r[idx] = T.bmulh(r[rs4], r[rt4])
        elif op == OP_TMIN:                            # TMIN
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            if idx:
                r[idx] = T.tmin(r[rs4], r[rt4])
        elif op == OP_TMAX:                            # TMAX
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            if idx:
                r[idx] = T.tmax(r[rs4], r[rt4])
        elif op == OP_TINV:                            # TINV
            if idx:
                r[idx] = T.tinv(r[rs4])
        elif op == OP_TCONS:                           # TCONS
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            if idx:
                r[idx] = T.tcons(r[rs4], r[rt4])
        elif op == OP_TANY:                            # TANY
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            if idx:
                r[idx] = T.tany(r[rs4], r[rt4])
        elif op == OP_TSUM:                            # TSUM
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            if idx:
                r[idx] = T.tsum(r[rs4], r[rt4])
        elif op == OP_TMUL:                            # TMUL
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            if idx:
                r[idx] = T.tmul(r[rs4], r[rt4])
        elif op == OP_TSHL or op == OP_TSHR or op == OP_TROT:
            k = imm if not (-4 <= imm <= 4) else r[imm + 4]     # D-026
            if idx:
                if op == OP_TSHL:
                    r[idx] = T.bshl(r[rs4], k)
                elif op == OP_TSHR:
                    r[idx] = T.bshr(r[rs4], k)
                else:
                    r[idx] = T.brot(r[rs4], k)
        elif op == OP_HALT:                            # HALT (privileged)
            if self.mode != 1:
                raise Trap(C_PRIV, op)
            self.halted = True
        elif op == _OPV["TRAP"]:                       # TRAP imm (D-017)
            raise Trap(C_SYSCALL, imm, epc=pc + 3)
        elif op == _OPV["RETI"]:                       # RETI (privileged)
            if self.mode != 1:
                raise Trap(C_PRIV, op)
            if self.trace_hook is not None:
                self.trace_hook("reti", epc=self.csr[CSR_EPC],
                                shadow=self.psw_shadow, pc=pc,
                                mode=self.mode, irq=self.irq_enable,
                                r1=self.r[1], r8=self.r[8])
            self.pc = self.csr[CSR_EPC]
            m = T.wrap(self.psw_shadow, 1)             # mode/irq from PSW (D-033)
            self.mode = m
            self.irq_enable = T.wrap((self.psw_shadow - m) // 3, 1)
            return
        elif op == _OPV["WFI"]:                        # WFI (privileged)
            if self.mode != 1:
                raise Trap(C_PRIV, op)
            self.waiting = True
        elif op == _OPV["CSRR"]:                       # CSRR (privileged)
            if self.mode != 1:
                raise Trap(C_PRIV, op)
            v = self.csr_read(imm)
            if v is None:
                raise Trap(C_ILLEGAL, imm)
            if idx:
                r[idx] = v
        elif op == _OPV["CSRW"]:                       # CSRW (privileged)
            if self.mode != 1:
                raise Trap(C_PRIV, op)
            if not self.csr_write(imm, r[rs4]):
                raise Trap(C_ILLEGAL, imm)
        elif op == _OPV["FENCE"]:                      # FENCE (privileged)
            if self.mode != 1:
                raise Trap(C_PRIV, op)
            self.tlb_flush()
        elif op == OP_XCHG:                            # XCHG rd, (rs)
            a = r[rs4]
            if a % 3:
                raise Trap(C_ALIGN, a)
            old = mem.read_word(a)
            mem.write_word(a, r[idx])
            if idx:
                r[idx] = old
        elif op == OP_CAS:                             # CAS rd, (rs), rt
            rt4 = imm + 4
            if rt4 < 0 or rt4 > 8:
                raise Trap(C_ILLEGAL, imm)
            a = r[rs4]
            if a % 3:
                raise Trap(C_ALIGN, a)
            old = mem.read_word(a)
            if old == r[idx]:
                mem.write_word(a, r[rt4])
            if idx:
                r[idx] = old
        else:
            raise Trap(C_ILLEGAL, op)

        self.pc = pc + 3

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

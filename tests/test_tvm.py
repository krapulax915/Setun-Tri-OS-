"""M1 acceptance: TVM CPU core — every opcode tested, fib(20), sieve to 200,
three-way branch demo, division/modulo edge cases, traps.
"""
import os
import sys
import unittest

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, TOOLS)

import trit as T                        # noqa: E402
import triasm                           # noqa: E402
from tvm.memory import PhysicalMemory   # noqa: E402
from tvm import cpu as tvcpu            # noqa: E402


def run_program(src, org=0, mem_size=4000, mode=1, max_steps=200000, **kw):
    img = triasm.assemble_source(src, org=org)
    mem = PhysicalMemory(mem_size)
    for addr, v in img.trytes.items():
        mem.write_tryte(addr, v)
    c = tvcpu.CPU(mem, mode=mode, **kw)
    steps = c.run(max_steps=max_steps)
    return img, mem, c, steps


def load_image(mem, img):
    for addr, v in img.trytes.items():
        mem.write_tryte(addr, v)


def make_cpu(src, org=0, mem_size=4000, **kw):
    img = triasm.assemble_source(src, org=org)
    mem = PhysicalMemory(mem_size)
    load_image(mem, img)
    c = tvcpu.CPU(mem, **kw)
    return img, mem, c


class TestArithOpcodes(unittest.TestCase):
    def _run(self, src, **kw):
        return run_program(src, **kw)[2]

    def test_add_sub_mul_neg(self):
        c = self._run("""
            LDI R1, 5
            LDI R2, 3
            ADD R3, R1, R2
            SUB R4, R1, R2
            MUL R5, R1, R2
            NEG R6, R1
            HALT
        """)
        self.assertEqual([c.r[3], c.r[4], c.r[5], c.r[6]], [8, 2, 15, -5])

    def test_wrap_semantics(self):
        c = self._run("""
            LUI R1, 3280
            ADDI R1, R1, 29524      ; R1 = 3280*59049 + 29524 = WORD_MAX
            LDI R2, 1
            ADD  R3, R1, R2         ; wrap -> WORD_MIN
            MUL  R4, R1, R2         ; WORD_MAX*1
            NEG  R5, R1             ; WORD_MIN
            HALT
        """)
        self.assertEqual(c.r[1], T.WORD_MAX)
        self.assertEqual(c.r[3], T.WORD_MIN)
        self.assertEqual(c.r[4], T.WORD_MAX)
        self.assertEqual(c.r[5], T.WORD_MIN)

    def test_div_mod(self):
        c = self._run("""
            LDI R1, 7
            LDI R2, 2
            DIV R3, R1, R2       ; tie -> toward zero: 3
            MOD R4, R1, R2       ; 1
            LDI R5, 2
            LDI R6, 3
            MOD R7, R5, R6       ; 2%3 = -1 (balanced)
            HALT
        """)
        self.assertEqual([c.r[3], c.r[4], c.r[7]], [3, 1, -1])

    def test_div0_traps(self):
        holder = {}

        def hook(cause, tval, epc):
            holder["cause"] = cause
            holder["tval"] = tval
            holder["cpu"] = holder.get("cpu_ref")
            if holder.get("cpu_ref"):
                holder["cpu_ref"].halted = True

        img, mem, c = make_cpu("""
            LDI R2, 0
            LDI R1, 5
            DIV R3, R1, R2
            HALT
        """, trap_hook=hook)
        holder["cpu_ref"] = c
        c.run()
        self.assertEqual(holder.get("cause"), tvcpu.C_DIV0)
        self.assertTrue(c.halted)

    def test_mulh(self):
        c = self._run("""
            LUI R1, 3280
            ADDI R1, R1, 4          ; WORD_MAX
            LDI R2, 2
            MULH R3, R1, R2
            HALT
        """)
        self.assertEqual(c.r[3], T.bmulh(T.WORD_MAX, 2))

    def test_tritwise(self):
        c = self._run("""
            LDI R1, 5
            LDI R2, -5
            TMIN R3, R1, R2
            TMAX R4, R1, R2
            HALT
        """)
        self.assertEqual(c.r[3], T.tmin(5, -5))
        self.assertEqual(c.r[4], T.tmax(5, -5))
        c = self._run("""
            LDI R1, 5
            LDI R2, 4
            TCONS R3, R1, R2
            TANY  R4, R1, R2
            TSUM  R5, R1, R2
            TMUL  R6, R1, R2
            TINV  R7, R1
            HALT
        """)
        self.assertEqual(c.r[3], T.tcons(5, 4))
        self.assertEqual(c.r[4], T.tany(5, 4))
        self.assertEqual(c.r[5], T.tsum(5, 4))
        self.assertEqual(c.r[6], T.tmul(5, 4))
        self.assertEqual(c.r[7], T.tinv(5))

    def test_shifts(self):
        c = self._run("""
            LDI R1, 1
            LDI R2, 2
            TSHL R3, R1, R2      ; 1 * 3^2 = 9 (reg form)
            TSHR R4, R3, R2      ; 9 -> 1
            TROT R5, R1, R2
            LDI R6, 5
            TSHR R7, R6, R2      ; round(5/9) = 1
            LDI R8, 5
            TSHL R8, 5           ; in-place imm form (|k| > 4): 5 * 3^5
            HALT
        """)
        self.assertEqual(c.r[3], 9)
        self.assertEqual(c.r[4], 1)
        self.assertEqual(c.r[5], T.brot(1, 2))
        self.assertEqual(c.r[7], T.bshr(5, 2))
        self.assertEqual(c.r[8], T.bshl(5, 5))

    def test_compare_ops(self):
        c = self._run("""
            LDI R1, 5
            LDI R2, 3
            CMP3 R3, R1, R2
            CMP3 R4, R2, R1
            CMP3 R5, R1, R1
            SIGN R6, R2
            SIGN R7, R0
            CMPI3 R8, R1, 10
            HALT
        """)
        self.assertEqual([c.r[3], c.r[4], c.r[5], c.r[6], c.r[7], c.r[8]],
                         [1, -1, 0, 1, 0, -1])

    def test_ldi_lui_lea(self):
        c = self._run("""
            LDI R1, -42
            LUI R2, 3
            LEA R3, R2, -1
            LEA R4, R0, 100
            HALT
        """)
        self.assertEqual(c.r[1], -42)
        self.assertEqual(c.r[2], 3 * 3 ** 10)
        self.assertEqual(c.r[3], 3 * 3 ** 10 - 1)
        self.assertEqual(c.r[4], 100)

    def test_r0_hardwired(self):
        c = self._run("""
            LDI R0, 77
            ADD R1, R0, R0
            HALT
        """)
        self.assertEqual(c.r[0], 0)
        self.assertEqual(c.r[1], 0)


class TestMemoryOpcodes(unittest.TestCase):
    def test_ldw_stw_ldt_stt(self):
        _img, mem, c, _ = run_program("""
            LDI R1, 300
            LDI R2, 12345
            STW R1, R2          ; [300] = 12345
            LDW R3, R1          ; R3 = 12345
            LDI R4, 305
            LDI R5, -7
            STT R4, R5          ; [305] = -7
            LDT R6, R4          ; R6 = -7
            HALT
        """)
        self.assertEqual(c.r[3], 12345)
        self.assertEqual(c.r[6], -7)
        self.assertEqual(mem.read_word(300), 12345)
        self.assertEqual(mem.read_tryte(305), -7)

    def test_align_trap_on_ldw(self):
        img, mem, c = make_cpu("""
            LDI R1, 301
            LDW R2, R1          ; unaligned -> ALIGN trap
            HALT
        """)
        c.csr[tvcpu.CSR_TVEC] = 0x99
        c.step()   # LDI
        c.step()   # LDW -> trap
        self.assertEqual(c.pc, 0x99)
        self.assertEqual(c.csr[tvcpu.CSR_CAUSE], tvcpu.C_ALIGN)
        self.assertEqual(c.csr[tvcpu.CSR_TVAL], 301)

    def test_pagefault_on_high_address(self):
        img, mem, c = make_cpu("""
            LUI R1, 17
            ADDI R1, R1, -3834      ; R1 = 999999 (beyond 4000-tryte RAM)
            LDW R2, R1
            HALT
        """)
        c.csr[tvcpu.CSR_TVEC] = 0x55
        c.step()
        c.step()
        self.assertEqual(c.r[1], 999999)
        c.step()
        self.assertEqual(c.csr[tvcpu.CSR_CAUSE], tvcpu.C_PFR)
        self.assertEqual(c.csr[tvcpu.CSR_TVAL], 999999)

    def test_xchg(self):
        _img, mem, c, _ = run_program("""
            LDI R1, 300
            LDI R2, 111
            STW R1, R2          ; [300] = 111
            LDI R2, 222
            XCHG R2, R1         ; swap: R2 = old [300] = 111; [300] = 222
            HALT
        """)
        self.assertEqual(c.r[2], 111)
        self.assertEqual(mem.read_word(300), 222)

    def test_cas_paths(self):
        _img, mem, c, _ = run_program("""
            LDI R1, 300
            LDI R2, 10
            STW R1, R2          ; [300]=10
            LDI R3, 10
            LDI R4, 99
            CAS R3, R1, R4      ; old=10 == R3 -> [300]=99, R3=10
            LDI R5, 10
            LDI R6, 55
            CAS R5, R1, R6      ; old=99 != 10 -> no write, R5=99
            HALT
        """)
        self.assertEqual(c.r[3], 10)
        self.assertEqual(c.r[5], 99)
        self.assertEqual(mem.read_word(300), 99)


class TestControlOpcodes(unittest.TestCase):
    def test_jmp_jal_jr(self):
        c = run_program("""
            JAL func            ; R7 = 3, PC = func
            HALT                ; after JR R7 lands here
        func:
            LDI R1, 8
            JR R7
        """)[2]
        self.assertEqual(c.r[1], 8)
        self.assertEqual(c.r[7], 3)
        self.assertTrue(c.halted)

    def test_all_branches(self):
        c = run_program("""
            LDI R1, -1
            BRN R1, L1          ; taken
            LDI R6, 100
        L1:
            BRZ R0, L2          ; R0=0 -> taken
            LDI R6, 101
        L2:
            LDI R2, 1
            BRP R2, L3
            LDI R6, 102
        L3:
            BRNZ R1, L4         ; taken
            LDI R6, 103
        L4:
            BRNP R1, L5         ; taken
            LDI R6, 104
        L5:
            BRZP R2, L6         ; taken
            LDI R6, 105
        L6:
            LDI R3, 1
            BRN R3, bad         ; not taken
            LDI R4, 1
            BRZ R4, bad         ; not taken
            LDI R5, -1
            BRP R5, bad         ; not taken
            LDI R6, 7           ; marker: fell through
            HALT
        bad:
            LDI R6, 666
            HALT
        """)[2]
        self.assertEqual(c.r[6], 7)

    def test_br3_demo(self):
        """The native three-way branch: dispatch on sign."""
        template = """
            LDI R1, %d
            BR3 R1, table
        neg:
            LDI R2, -1
            JMP common
        zero:
            LDI R2, 0
            JMP common
        pos:
            LDI R2, 1
        common:
            HALT
        table:
            .word neg
            .word zero
            .word pos
        """
        for val, want in ((-5, -1), (0, 0), (9, 1)):
            c = run_program(template % val)[2]
            self.assertEqual(c.r[2], want)


class TestSystemOpcodes(unittest.TestCase):
    def test_halt(self):
        c = run_program("HALT\n")[2]
        self.assertTrue(c.halted)

    def test_trap_entry_semantics(self):
        """TRAP -> HW trap entry with TVEC != 0 (D-013/D-017)."""
        img, mem, c = make_cpu("""
            TRAP 42
        after:
            HALT                ; EPC lands here (pc+3)
        handler:
            CSRR R1, CAUSE
            CSRR R2, TVAL
            CSRR R3, EPC
            RETI                ; PC = EPC -> HALT
        """)
        c.csr[tvcpu.CSR_TVEC] = img.symbols["handler"]
        c.step()      # TRAP
        self.assertEqual(c.pc, img.symbols["handler"])
        self.assertEqual(c.csr[tvcpu.CSR_CAUSE], 0)
        self.assertEqual(c.csr[tvcpu.CSR_TVAL], 42)
        c.step()      # CSRR CAUSE
        c.step()      # CSRR TVAL
        c.step()      # CSRR EPC
        self.assertEqual(c.r[1], 0)
        self.assertEqual(c.r[2], 42)
        self.assertEqual(c.r[3], 3)    # EPC = TRAP's pc + 3 (TRAP at 0)
        c.step()      # RETI -> HALT
        c.step()      # HALT
        self.assertTrue(c.halted)

    def test_privilege_trap(self):
        img, mem, c = make_cpu("""
            CSRR R1, PSW
            HALT
        """, mode=-1)
        c.csr[tvcpu.CSR_TVEC] = 0x77
        c.step()
        self.assertEqual(c.pc, 0x77)
        self.assertEqual(c.csr[tvcpu.CSR_CAUSE], tvcpu.C_PRIV)
        self.assertEqual(c.csr[tvcpu.CSR_TVAL], triasm.OPCODES["CSRR"]["op"])

    def test_reti_round_trip(self):
        img, mem, c = make_cpu("""
            TRAP 1
        after:
            HALT
        handler:
            CSRR R1, CAUSE
            CSRR R2, TVAL
            RETI
        """)
        c.csr[tvcpu.CSR_TVEC] = img.symbols["handler"]
        c.run()
        self.assertTrue(c.halted)
        self.assertEqual(c.r[1], 0)
        self.assertEqual(c.r[2], 1)
        self.assertEqual(c.csr[tvcpu.CSR_EPC], img.symbols["after"])

    def test_wfi_and_irq(self):
        img, mem, c = make_cpu("""
            LDI R1, 1
            WFI
            LDI R2, 2
            HALT
        """)
        c.csr[tvcpu.CSR_TVEC] = 0x66
        c.csr_write(tvcpu.CSR_PSW, 1 + 3 * 1)   # mode=+, irq-enable=+
        c.step()          # LDI
        c.step()          # WFI -> waiting
        self.assertTrue(c.waiting)
        self.assertFalse(c.step())    # asleep, no wake source
        c.raise_irq(tvcpu.C_TIMER)    # timer irq pending
        c.step()                      # wake + deliver -> trap to TVEC
        self.assertEqual(c.pc, 0x66)
        self.assertEqual(c.csr[tvcpu.CSR_CAUSE], tvcpu.C_TIMER)

    def test_wfi_wakes_but_irq_masked(self):
        """WFI wakes on pending IRQs even when masked; execution just continues."""
        img, mem, c = make_cpu("""
            LDI R1, 1
            WFI
            LDI R2, 2
            HALT
        """)
        c.step()          # LDI
        c.step()          # WFI (irq_enable == -1)
        c.raise_irq(tvcpu.C_TIMER)
        c.step()          # wakes, IRQ masked -> falls through to LDI R2
        c.step()          # HALT
        self.assertTrue(c.halted)
        self.assertEqual(c.r[2], 2)

    def test_timer_irq(self):
        img, mem, c = make_cpu("""
            CSRW TIMER_CMP, R0        ; cmp = 0 -> fires at once once irqs are on
        loop:
            BRNZ R0, loop             ; spin until the timer fires
            HALT
        handler:
            LDI R6, 9
            RETI
        """)
        c.csr[tvcpu.CSR_TVEC] = img.symbols["handler"]
        c.step()                  # CSRW TIMER_CMP
        c.csr_write(tvcpu.CSR_PSW, 1 + 3 * 1)   # mode=+, irq=+
        c.run(max_steps=200)
        self.assertEqual(c.r[6], 9)
        self.assertTrue(c.halted)

    def test_illegal_opcode_trap(self):
        t = T.to_trits(-40, 4) + T.to_trits(0, 14)
        bad = T.from_trits(t)
        img, mem, c = make_cpu("HALT\n", mem_size=400)
        mem.write_word(10, bad)
        c.pc = 10
        c.csr[tvcpu.CSR_TVEC] = 0x88
        c.step()
        self.assertEqual(c.pc, 0x88)
        self.assertEqual(c.csr[tvcpu.CSR_CAUSE], tvcpu.C_ILLEGAL)
        self.assertEqual(c.csr[tvcpu.CSR_TVAL], -40)

    def test_illegal_r_form(self):
        w = tvcpu.encode(triasm.OPCODES["ADD"]["op"], 0, 0, 5)
        mem = PhysicalMemory(400)
        mem.write_word(0, w)
        c = tvcpu.CPU(mem)
        c.csr[tvcpu.CSR_TVEC] = 0x88
        c.step()
        self.assertEqual(c.csr[tvcpu.CSR_CAUSE], tvcpu.C_ILLEGAL)


class TestPrograms(unittest.TestCase):
    def test_fib20(self):
        """fib(20) == 6765."""
        c = run_program("""
        ; R1 counter, R2 a, R3 b, R4 tmp
            LDI R1, 20
            LDI R2, 0
            LDI R3, 1
        loop:
            CMP3 R5, R1, R0
            BRZ R5, done
            ADD  R4, R2, R3
            ADD  R2, R3, R0
            ADD  R3, R4, R0
            ADDI R1, R1, -1
            JMP  loop
        done:
            HALT
        """)[2]
        self.assertEqual(c.r[2], 6765)
        self.assertEqual(c.r[3], 10946)   # fib(21)

    def test_fib_golden_trace_head(self):
        """Golden trace: after 5 loop iterations a=fib(5), b=fib(6) (hand-computed)."""
        _img, _mem, c = make_cpu("""
            LDI R1, 20
            LDI R2, 0
            LDI R3, 1
        loop:
            CMP3 R5, R1, R0
            BRZ R5, done
            ADD  R4, R2, R3
            ADD  R2, R3, R0
            ADD  R3, R4, R0
            ADDI R1, R1, -1
            JMP  loop
        done:
            HALT
        """)
        guard = 0
        while c.r[1] != 15 and guard < 1000:
            c.step()
            guard += 1
        self.assertEqual((c.r[2], c.r[3]), (5, 8))

    def test_sieve_to_200(self):
        c = run_program("""
            .equ LIMIT, 200
            .equ BASE, 2000
            LDI R1, 0
        clr:
            CMPI3 R5, R1, LIMIT
            BRZP R5, clr_done
            LEA  R2, R1, BASE
            LDI  R3, 0
            STT  R2, R3
            ADDI R1, R1, 1
            JMP  clr
        clr_done:
            LDI R1, 2
        outer:
            CMPI3 R5, R1, LIMIT
            BRZP R5, count
            LEA  R2, R1, BASE
            LDT  R3, R2
            BRNZ R3, next_i
            ADD  R4, R1, R1      ; j = 2*i
        inner:
            CMPI3 R5, R4, LIMIT
            BRZP R5, next_i
            LEA  R2, R4, BASE
            LDI  R3, 1
            STT  R2, R3
            ADD  R4, R4, R1
            JMP  inner
        next_i:
            ADDI R1, R1, 1
            JMP  outer
        count:
            LDI R1, 2            ; 0 and 1 are not prime (sieve starts at 2)
            LDI R6, 0
        cnt:
            CMPI3 R5, R1, LIMIT
            BRZP R5, halt
            LEA  R2, R1, BASE
            LDT  R3, R2
            BRNZ R3, cnt_skip
            ADDI R6, R6, 1
        cnt_skip:
            ADDI R1, R1, 1
            JMP  cnt
        halt:
            HALT
        """, mem_size=3000)[2]
        self.assertEqual(c.r[6], 46)      # pi(200) == 46

    def test_div_mod_edge_matrix(self):
        """Balanced DIV/MOD edge cases through the CPU vs trit.py references."""
        cases = [(7, 2), (-7, 2), (7, -2), (-7, -2), (11, 2), (9, 2), (1, 3),
                 (-1, 3), (2, 3), (-2, 3), (100, -7), (-100, 7), (0, 5),
                 (193710244, 29524), (-193710244, 29524), (123456, 789)]
        for a, d in cases:
            src = self._big_const("R1", a) + self._big_const("R2", d) + """
            DIV R3, R1, R2
            MOD R4, R1, R2
            HALT
        """
            c = run_program(src)[2]
            self.assertEqual(c.r[3], T.bdiv(a, d), "div %d/%d" % (a, d))
            self.assertEqual(c.r[4], T.bmod(a, d), "mod %d%%%d" % (a, d))

    @staticmethod
    def _big_const(reg, v):
        h = T.bdiv(v, 3 ** 10)
        l = v - h * 3 ** 10
        return "    LUI %s, %d\n    ADDI %s, %s, %d\n" % (reg, h, reg, reg, l)

    def test_ldi_range_limit(self):
        with self.assertRaises(triasm.AsmError):
            triasm.assemble_source("LDI R1, 29525")


if __name__ == "__main__":
    unittest.main(verbosity=2)

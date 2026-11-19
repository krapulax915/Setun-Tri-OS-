"""M1: assembler unit tests + disassembler round-trip."""
import os
import random
import sys
import unittest

TOOLS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools")
sys.path.insert(0, TOOLS)

import trit as T          # noqa: E402
import triasm             # noqa: E402
import tridis             # noqa: E402
from tvm import cpu as tvcpu   # noqa: E402


class TestEncoding(unittest.TestCase):
    def test_encode_decode_consistency(self):
        for op in (-8, -1, 0, 1, 22, 39, 40):
            for rd in range(-4, 5):
                for rs in (-4, 0, 4):
                    for imm in (-29524, -1, 0, 7, 29524):
                        w = tvcpu.encode(op, rd, rs, imm)
                        o2, rd2, rs2, imm2 = tvcpu.decode(w)
                        self.assertEqual((op, rd, rs, imm), (o2, rd2, rs2, imm2))

    def test_field_layout_matches_trit_string(self):
        # op=1, rd=R1(-3), rs=R2(-2), imm=5 -> trits = op|rd|rs|imm concatenation
        w = tvcpu.encode(1, -3, -2, 5)
        t = T.to_trits(w, 18)
        self.assertEqual(T.from_trits(t[0:4]), 1)
        self.assertEqual(T.from_trits(t[4:6]), -3)
        self.assertEqual(T.from_trits(t[6:8]), -2)
        self.assertEqual(T.from_trits(t[8:18]), 5)


class TestAssembly(unittest.TestCase):
    def asm(self, src, org=0):
        return triasm.assemble_source(src, org=org)

    def test_simple_program(self):
        img = self.asm("""
        start:
            ADDI R1, R0, 5
            ADDI R2, R0, 3
            ADD  R3, R1, R2
            HALT
        """)
        self.assertEqual(img.symbols["start"], 0)
        self.assertEqual(img.read_word_at(0), tvcpu.encode(
            triasm.OPCODES["ADDI"]["op"], triasm.REG_SEL["R1"],
            triasm.REG_SEL["R0"], 5))
        self.assertEqual(img.read_word_at(6), tvcpu.encode(
            triasm.OPCODES["ADD"]["op"], triasm.REG_SEL["R3"],
            triasm.REG_SEL["R1"], triasm.REG_SEL["R2"]))
        self.assertEqual(img.read_word_at(9), tvcpu.encode(
            triasm.OPCODES["HALT"]["op"], -4, -4, 0))

    def test_labels_and_branches(self):
        img = self.asm("""
            JMP skip
            ADDI R1, R0, 99
        skip:
            HALT
        """)
        # JMP at 0 -> offset to skip (addr 6): imm = 6 - 3 = 3
        w = img.read_word_at(0)
        _op, _rd, _rs, imm = tvcpu.decode(w)
        self.assertEqual(imm, 3)

    def test_backward_branch_negative_offset(self):
        img = self.asm("""
        top:
            ADDI R1, R1, -1
            BRNZ R1, top
            HALT
        """)
        w = img.read_word_at(3)
        _op, _rd, _rs, imm = tvcpu.decode(w)
        self.assertEqual(imm, -6)      # back to 0 from pc_next=6

    def test_data_directives(self):
        img = self.asm("""
            .tryte 1, -2, 'A'
            .word 1000, -1000
        str:
            .asciz "Hi"
        """)
        self.assertEqual(img.trytes[0], 1)
        self.assertEqual(img.trytes[1], -2)
        self.assertEqual(img.trytes[2], 65)
        self.assertEqual(img.read_word_at(3), 1000)
        self.assertEqual(img.read_word_at(6), -1000)
        self.assertEqual([img.trytes[9], img.trytes[10], img.trytes[11]],
                         [72, 105, 0])

    def test_asciz_hungarian(self):
        img = self.asm('.asciz "Árvíztűrő"')
        want = T.tritext_encode("Árvíztűrő") + [0]
        got = [img.trytes[i] for i in range(len(want))]
        self.assertEqual(got, want)

    def test_org_equ_align_space(self):
        img = self.asm("""
            .equ BASE, 100
            .org BASE
        data:
            .word 7
        """)
        self.assertEqual(img.symbols["data"], 100)
        self.assertEqual(img.read_word_at(100), 7)

    def test_align_word(self):
        img = self.asm("""
            .tryte 1
            .align 3
        w:
            .word 5
        """)
        self.assertEqual(img.symbols["w"], 3)
        self.assertEqual(img.read_word_at(3), 5)

    def test_macros(self):
        img = self.asm("""
        .macro push r
            ADDI R8, R8, -3
            STW  R8, %r
        .endmacro

        .macro pop r
            LDW  %r, R8
            ADDI R8, R8, 3
        .endmacro

        .macro swap a, b
            push %a
            push %b
            pop  %a
            pop  %b
        .endmacro

            LDI R1, 11
            LDI R2, 22
            LDI R8, 900
            swap R1, R2
            HALT
        """)
        # execute to verify macro semantics: swap via stack, R8 restored
        from tvm.memory import PhysicalMemory
        mem = PhysicalMemory(3000)
        for addr, v in img.trytes.items():
            mem.write_tryte(addr, v)
        c = tvcpu.CPU(mem)
        c.run()
        self.assertEqual(c.r[1], 22)    # swapped
        self.assertEqual(c.r[2], 11)
        self.assertEqual(c.r[8], 900)
        self.assertTrue(c.halted)

    def test_include_and_errors(self):
        with self.assertRaises(triasm.AsmError):
            self.asm("    BOGUS R1, R2")
        with self.assertRaises(triasm.AsmError):
            self.asm("    LDI R1, 999999")
        with self.assertRaises(triasm.AsmError):
            self.asm("x:\nx:\n    HALT")
        with self.assertRaises(triasm.AsmError):
            self.asm("    TSHL R1, 3")     # D-026: |k| <= 4 must be reg form
        with self.assertRaises(triasm.AsmError):
            self.asm("    .bogus 1")

    def test_shift_forms(self):
        img = self.asm("""
            TSHL R3, R1, R2     ; full reg form: R3 = R1 << R2
            TSHL R1, 5          ; in-place imm form
            TSHR R3, R4         ; in-place reg form
            TROT R5, -7
        """)
        sel = triasm.REG_SEL
        w0 = img.read_word_at(0)
        self.assertEqual(tvcpu.decode(w0), (triasm.OPCODES["TSHL"]["op"],
                                            sel["R3"], sel["R1"], sel["R2"]))
        w1 = img.read_word_at(3)
        self.assertEqual(tvcpu.decode(w1), (triasm.OPCODES["TSHL"]["op"],
                                            sel["R1"], sel["R1"], 5))
        w2 = img.read_word_at(6)
        self.assertEqual(tvcpu.decode(w2), (triasm.OPCODES["TSHR"]["op"],
                                            sel["R3"], sel["R3"], sel["R4"]))
        w3 = img.read_word_at(9)
        self.assertEqual(tvcpu.decode(w3), (triasm.OPCODES["TROT"]["op"],
                                            sel["R5"], sel["R5"], -7))

    def test_image_spans_and_packing(self):
        img = self.asm("""
            .org 0
            .tryte 1, 2, 3
            .org 10
            .tryte 4
        """)
        spans = img.spans()
        self.assertEqual(len(spans), 2)
        self.assertEqual(spans[0][0], 0)
        self.assertEqual(spans[1][0], 10)
        b = img.to_bytes()
        trytes = triasm.packmod.unpack_trytes(b)
        self.assertEqual(trytes[:3], [1, 2, 3])
        self.assertIn(4, trytes)


class TestDisasmRoundTrip(unittest.TestCase):
    def test_all_opcodes_round_trip(self):
        rng = random.Random(1234)
        ops = triasm.OPCODES
        count = 0
        for mn, spec in ops.items():
            fmt = spec["fmt"]
            samples = 40
            for _ in range(samples):
                line = self._random_line(rng, mn, fmt)
                img = triasm.assemble_source(line + "\n", org=900)
                addr = img.spans()[0][0]
                word = img.read_word_at(addr)
                # disassemble -> reassemble at the same address
                text = tridis.decode_word(word, pc=addr)
                img2 = triasm.assemble_source(text + "\n", org=addr)
                self.assertEqual(img2.read_word_at(addr), word,
                                 "round-trip failed for %r -> %r" % (line, text))
                count += 1
        self.assertGreaterEqual(count, 49 * 40)

    def _random_line(self, rng, mn, fmt):
        R = lambda: "R%d" % rng.randint(0, 8)
        if mn in triasm.SHIFT_OPS:
            if rng.random() < 0.5:
                return "%s %s, %s" % (mn, R(), R())
            k = rng.choice([5, 6, 9, 17, -5, -9, 29524, -29524])
            return "%s %s, %d" % (mn, R(), k)
        if fmt == "SYS":
            return mn
        if fmt == "RRR":
            return "%s %s, %s, %s" % (mn, R(), R(), R())
        if fmt == "RS":
            return "%s %s, %s" % (mn, R(), R())
        if fmt == "R":
            return "%s %s" % (mn, R())
        if fmt == "RI":
            return "%s %s, %d" % (mn, R(), rng.randint(-29524, 29524))
        if fmt == "RRI":
            return "%s %s, %s, %d" % (mn, R(), R(), rng.randint(-29524, 29524))
        if fmt == "OFF":
            return "%s .+%d" % (mn, rng.randint(-60, 60))
        if fmt == "RS_OFF":
            return "%s %s, .+%d" % (mn, R(), rng.randint(-60, 60))
        if fmt == "CSR_R":
            return "%s %s, %s" % (mn, R(), rng.choice(list(triasm.CSR_NUM)))
        if fmt == "CSR_W":
            return "%s %s, %s" % (mn, rng.choice(list(triasm.CSR_NUM)), R())
        if fmt == "TRAPF":
            return "%s %d" % (mn, rng.randint(-29524, 29524))
        raise AssertionError(fmt)

    def test_unknown_op_renders_as_word(self):
        # op = -40 (unassigned) -> .word
        t = T.to_trits(-40, 4) + T.to_trits(0, 14)
        w = T.from_trits(t)
        self.assertEqual(tridis.decode_word(w), ".word %d" % w)


if __name__ == "__main__":
    unittest.main(verbosity=2)

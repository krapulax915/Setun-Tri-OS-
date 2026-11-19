"""tridis.py — TriDisassembler for TriISA v0.1.

decode_word(word) -> text. The guarantee tested in M1:
assemble(disassemble(word)) == word for every validly encoded instruction.
"""
from __future__ import annotations

import trit as T
from isaspec import load_isa

ISA = load_isa()
OPCODES = ISA["opcodes"]
CSR_NAME = {v: k for k, v in ISA["csrs"].items() if isinstance(v, int)}
OP_NAME = {spec["op"]: name for name, spec in ISA["opcodes"].items()}
FMT = {name: spec["fmt"] for name, spec in ISA["opcodes"].items()}
SHIFT_OPS = {"TSHL", "TSHR", "TROT"}

IMM_MIN, IMM_MAX = -29524, 29524


def _reg(sel):
    return "R%d" % (sel + 4)


def decode_fields(word):
    imm = T.wrap(word, 10)
    x = (word - imm) // 3 ** 10
    rs = T.wrap(x, 2)
    y = (x - rs) // 9
    rd = T.wrap(y, 2)
    op = (y - rd) // 9
    return op, rd, rs, imm


def decode_word(word: int, pc: int = 0) -> str:
    """Instruction word -> TriASM text line (or `.word v` if not decodable)."""
    op, rd, rs, imm = decode_fields(word)
    mn = OP_NAME.get(op)
    if mn is None or not (-40 <= op <= 40):
        return ".word %d" % word
    fmt = FMT[mn]

    if mn in SHIFT_OPS:
        if -4 <= imm <= 4:
            return "%s %s, %s, %s" % (mn, _reg(rd), _reg(rs), _reg(imm))
        return "%s %s, %s, %d" % (mn, _reg(rd), _reg(rs), imm)

    if fmt == "SYS":
        return mn
    if fmt == "RRR":
        if not (-4 <= imm <= 4):
            return ".word %d" % word
        return "%s %s, %s, %s" % (mn, _reg(rd), _reg(rs), _reg(imm))
    if fmt == "RS":
        return "%s %s, %s" % (mn, _reg(rd), _reg(rs))
    if fmt == "R":
        return "%s %s" % (mn, _reg(rs))
    if fmt == "RI":
        return "%s %s, %d" % (mn, _reg(rd), imm)
    if fmt == "RRI":
        return "%s %s, %s, %d" % (mn, _reg(rd), _reg(rs), imm)
    if fmt == "OFF":
        return "%s .+%d" % (mn, imm + 3)
    if fmt == "RS_OFF":
        return "%s %s, .+%d" % (mn, _reg(rs), imm + 3)
    if fmt == "CSR_R":
        return "%s %s, %s" % (mn, _reg(rd), CSR_NAME.get(imm, "CSR?%d" % imm))
    if fmt == "CSR_W":
        return "%s %s, %s" % (mn, CSR_NAME.get(imm, "CSR?%d" % imm), _reg(rs))
    if fmt == "TRAPF":
        return "%s %d" % (mn, imm)
    return ".word %d" % word


def disassemble_image(img, base_addr: int | None = None) -> str:
    """All instruction words of a contiguous span as text (labels as comments)."""
    lines = []
    spans = img.spans()
    for start, data in spans:
        addr = start
        i = 0
        while i + 3 <= len(data):
            word = T.trytes_to_word(data[i:i + 3])
            txt = decode_word(word, pc=addr)
            lbl = [n for n, v in img.symbols.items() if v == addr]
            prefix = ("%s:" % lbl[0]) if lbl else ""
            lines.append("%-8d %-22s ; %s" % (addr, prefix, txt))
            addr += 3
            i += 3
    return "\n".join(lines)

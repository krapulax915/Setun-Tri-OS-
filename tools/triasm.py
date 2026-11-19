"""triasm.py — TriAssembler for TriISA v0.1 (spec/isa.yaml is the source of truth).

Line syntax:
    label:
    ; comment        (# also a comment)
        MNEMONIC op, op, op
        .directive args

Directives:
    .org expr          set position counter (expression; forward labels unsupported)
    .entry expr        executable entry point (TXE; resolved in pass 2)
    .globl name        mark symbol global (records; used by trild)
    .equ name, expr    / .set name, expr   define constant (non-forward expressions)
    .tryte v, v, ...   emit trytes (value or 'c' char)
    .word  v, v, ...   emit words (3 trytes each)
    .ascii "text"      TriText trytes (no terminator); \\e emits the escape tryte
    .asciz "text"      TriText trytes + NUL tryte
    .space n           n zero trytes (constant expr)
    .align k           pad to multiple of k trytes (constant expr)
    .include "file"    include source file
    .macro name a, b   / .endmacro   macro definition; body refers args as %a, %b

Expressions: labels, `.` (current tryte address), decimal ints, 'c' chars,
+ - * / % and parentheses. `/` and `%` use balanced-ternary semantics (trit.bdiv/bmod).
Branch/jump targets are labels or address expressions; the assembler emits the
PC-relative tryte offset automatically (D-006). Shifts by |k| <= 4 must use the
register form (encoding ambiguity, D-026).
"""
from __future__ import annotations

import os
import re

import trit as T
import pack as packmod
from isaspec import load_isa

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ISA = load_isa()
OPCODES = ISA["opcodes"]
CSR_NUM = {k: v for k, v in ISA["csrs"].items() if isinstance(v, int)}
REG_SEL = {("R%d" % i): (i - 4) for i in range(9)}

SHIFT_OPS = {"TSHL", "TSHR", "TROT"}

IMM_MIN, IMM_MAX = -29524, 29524
ROM_SIZE = 6561   # 9 blocks of 729 trytes (D-011 host constant)

_ESCAPES = {"\\n": 10, "\\t": 9, "\\0": 0, "\\\\": 92, '\\"': 34, "\\'": 39,
            "\\r": 13, "\\e": T.ESCAPE}
_STR_MAPPING = {"n": "\n", "t": "\t", "0": "\x00", '"': '"', "\\": "\\",
                "'": "'", "r": "\r"}
ESC_SENTINEL = object()   # represents the TriText escape tryte inside parsed strings


class AsmError(Exception):
    def __init__(self, filename, lineno, msg):
        super().__init__("%s:%d: %s" % (filename, lineno, msg))


# ---- tokenizer -------------------------------------------------------------------
_TOKEN_RE = re.compile(r"""
    \s*(?:
      (?P<num>\d+)
    | (?P<char>'(?:\\.|[^\\'])')
    | (?P<str>"(?:\\.|[^"\\])*")
    | (?P<ident>[A-Za-z_.][A-Za-z0-9_.]*)
    | (?P<comma>,)
    | (?P<lpar>\()
    | (?P<rpar>\))
    | (?P<plus>\+)
    | (?P<minus>-)
    | (?P<star>\*)
    | (?P<slash>/)
    | (?P<pct>%)
    )""", re.VERBOSE)


def _strip_comment(line: str) -> str:
    out, q = [], None
    i = 0
    while i < len(line):
        c = line[i]
        if q:
            out.append(c)
            if c == "\\" and i + 1 < len(line):
                out.append(line[i + 1])
                i += 1
            elif c == q:
                q = None
        elif c in "\"'":
            q = c
            out.append(c)
        elif c in ";#":
            break
        else:
            out.append(c)
        i += 1
    return "".join(out)


def _tokenize(s: str):
    toks = []
    i = 0
    while i < len(s):
        m = _TOKEN_RE.match(s, i)
        if not m:
            if s[i:].strip() == "":
                break
            raise ValueError("cannot tokenize %r" % s[i:])
        i = m.end()
        toks.append((m.lastgroup, m.group(m.lastgroup)))
    return toks


def _unescape_char(tok: str) -> int:
    body = tok[1:-1]
    if body.startswith("\\"):
        if body not in _ESCAPES:
            raise ValueError("unknown escape %r" % tok)
        return _ESCAPES[body]
    return ord(body)


def _parse_string_items(tok: str) -> list:
    """String token -> list of chars (ESC_SENTINEL for \\e)."""
    body = tok[1:-1]
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            esc = body[i:i + 2]
            if esc == "\\e":
                out.append(ESC_SENTINEL)
                i += 2
                continue
            if esc[1] not in _STR_MAPPING:
                raise ValueError("unknown string escape %r" % esc)
            out.append(_STR_MAPPING[esc[1]])
            i += 2
            continue
        out.append(c)
        i += 1
    return out


def _string_encoded_length(items) -> int:
    n = 0
    for x in items:
        n += 1 if x is ESC_SENTINEL else len(T.tritext_encode_char(x))
    return n


# ---- expression evaluation ---------------------------------------------------------
class _ExprParser:
    def __init__(self, toks, symbols, pos, filename, lineno):
        self.toks = toks
        self.i = 0
        self.symbols = symbols
        self.pos = pos
        self.filename = filename
        self.lineno = lineno

    def _err(self, msg):
        raise AsmError(self.filename, self.lineno, msg)

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def next(self):
        t = self.peek()
        self.i += 1
        return t

    def parse(self):
        v = self.expr()
        if self.i != len(self.toks):
            self._err("trailing tokens in expression: %r"
                      % " ".join(str(t[1]) for t in self.toks[self.i:]))
        return v

    def expr(self):
        v = self.term()
        while True:
            k, _ = self.peek()
            if k in ("plus", "minus"):
                self.next()
                rhs = self.term()
                v = v + rhs if k == "plus" else v - rhs
            else:
                return v

    def term(self):
        v = self.factor()
        while True:
            k, _ = self.peek()
            if k == "star":
                self.next()
                v = v * self.factor()
            elif k == "slash":
                self.next()
                d = self.factor()
                if d == 0:
                    self._err("division by zero in expression")
                v = T.bdiv(v, d)
            elif k == "pct":
                self.next()
                d = self.factor()
                if d == 0:
                    self._err("modulo by zero in expression")
                v = T.bmod(v, d)
            else:
                return v

    def factor(self):
        k, s = self.peek()
        if k == "minus":
            self.next()
            return -self.factor()
        if k == "plus":
            self.next()
            return self.factor()
        if k == "lpar":
            self.next()
            v = self.expr()
            if self.next()[0] != "rpar":
                self._err("missing ')'")
            return v
        if k == "num":
            self.next()
            return int(s)
        if k == "char":
            self.next()
            return _unescape_char(s)
        if k == "ident":
            self.next()
            if s == ".":
                return self.pos
            if s in self.symbols:
                return self.symbols[s]
            self._err("undefined symbol %r" % s)
        self._err("unexpected token %r in expression" % (s,))


# ---- assembler core --------------------------------------------------------------------
class Macro:
    def __init__(self, name, params, body, filename, lineno):
        self.name = name
        self.params = params
        self.body = body            # list of (line, file, lineno)
        self.filename = filename
        self.lineno = lineno


class _Item:
    __slots__ = ("kind", "data", "file", "line")

    def __init__(self, kind, data, file, line):
        self.kind = kind
        self.data = data
        self.file = file
        self.line = line


_ARG_TOKEN = re.compile(r"%([A-Za-z_][A-Za-z0-9_]*)")
_LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*)$")


def _generic_split(s, sep):
    out, depth, cur, q = [], 0, [], None
    for ch in s:
        if q:
            cur.append(ch)
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
            cur.append(ch)
        elif ch in "([{":
            depth += 1
            cur.append(ch)
        elif ch in ")]}":
            depth -= 1
            cur.append(ch)
        elif ch == sep and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if cur:
        out.append("".join(cur))
    return [x.strip() for x in out if x.strip() != ""]


def _substitute_args(line, sub):
    return _ARG_TOKEN.sub(lambda m: sub.get(m.group(1), m.group(0)), line)


class Assembler:
    def __init__(self):
        self.items = []
        self.macros = {}
        self.symbols = {}
        self.globals = set()

    # ---- source collection -----------------------------------------------------
    def assemble(self, text, fname="<text>", org=0):
        self._collect(text.splitlines(), fname, 1, ".")
        return self._finish(org)

    def assemble_file(self, path, org=0):
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        self._collect(text.splitlines(), os.path.basename(path), 1,
                      os.path.dirname(path))
        return self._finish(org)

    def _collect(self, lines, fname, start_line, base_dir, depth=0):
        if depth > 16:
            raise AsmError(fname, start_line, "include/macro depth exceeded")
        # 1) pull out macro definitions first (so macros may be used before defined)
        body_lines = []
        i = 0
        while i < len(lines):
            line = _strip_comment(lines[i]).strip()
            lineno = start_line + i
            if line.lower() == ".macro" or line.lower().startswith(".macro "):
                parts = _generic_split(line[6:].replace(",", " "), " ")
                parts = [p for p in parts if p]
                if not parts:
                    raise AsmError(fname, lineno, ".macro needs a name")
                name = parts[0]
                params = [p.lstrip("%") for p in parts[1:]]
                i += 1
                body = []
                while i < len(lines):
                    inner = _strip_comment(lines[i]).strip()
                    if inner.lower() == ".endmacro":
                        break
                    body.append((inner, fname, start_line + i))
                    i += 1
                else:
                    raise AsmError(fname, start_line + i, "missing .endmacro")
                if name.lower() in self.macros:
                    raise AsmError(fname, lineno, "duplicate macro %r" % name)
                self.macros[name.lower()] = Macro(name, params, body, fname, lineno)
                i += 1
                continue
            body_lines.append((lines[i], fname, lineno))
            i += 1
        # 2) walk the remaining lines, expanding macro invocations
        self._walk(body_lines, base_dir, depth)

    def _walk(self, triples, base_dir, depth):
        j = 0
        n = len(triples)
        while j < n:
            raw, fname, lineno = triples[j]
            j += 1
            line = _strip_comment(raw).strip()
            if not line:
                continue
            # labels
            while True:
                m = _LABEL_RE.match(line)
                if not m:
                    break
                self.items.append(_Item("label", m.group(1), fname, lineno))
                line = m.group(2).strip()
                if not line:
                    break
            if not line:
                continue
            if line.startswith("."):
                self._directive(line, fname, lineno, base_dir, depth)
                continue
            head = line.split(None, 1)[0]
            if head.lower() in self.macros:
                mac = self.macros[head.lower()]
                argstr = line[len(head):].strip()
                args = _generic_split(argstr, ",") if argstr else []
                if len(args) != len(mac.params):
                    raise AsmError(fname, lineno,
                                   "macro %s wants %d args, got %d"
                                   % (mac.name, len(mac.params), len(args)))
                sub = dict(zip(mac.params, args))
                expanded = []
                for bline, bfile, bline_no in mac.body:
                    bline2 = bline.strip()
                    if bline2:
                        expanded.append((_substitute_args(bline2, sub),
                                         bfile, bline_no))
                self._collect_expanded(expanded, base_dir, depth + 1)
                continue
            self.items.append(_Item("instr", line, fname, lineno))

    def _collect_expanded(self, triples, base_dir, depth):
        """Macro body: no nested macro definitions, but invocations allowed."""
        if depth > 32:
            raise AsmError("<macro>", 0, "macro expansion too deep")
        self._walk(triples, base_dir, depth)

    def _include(self, path, from_dir, fname, lineno):
        cands = [os.path.join(from_dir, path), path, os.path.join(REPO_ROOT, path)]
        for c in cands:
            if os.path.exists(c):
                with open(c, "r", encoding="utf-8") as f:
                    src = f.read()
                self._collect(src.splitlines(), os.path.basename(c), 1,
                              os.path.dirname(c))
                return
        raise AsmError(fname, lineno, "cannot find include %r" % path)

    def _directive(self, line, fname, lineno, base_dir, depth):
        low = line.lower()
        if low.startswith(".include"):
            arg = line[len(".include"):].strip()
            if not (arg.startswith('"') and arg.endswith('"')):
                raise AsmError(fname, lineno, ".include needs a quoted path")
            self._include(arg[1:-1], base_dir, fname, lineno)
            return
        if low.startswith(".org"):
            self.items.append(_Item("org", line[4:].strip(), fname, lineno))
            return
        if low.startswith(".entry"):
            self.items.append(_Item("entry", line[len(".entry"):].strip(),
                                    fname, lineno))
            return
        if low.startswith((".globl", ".global")):
            rest = line.split(None, 1)[1] if len(line.split(None, 1)) > 1 else ""
            for name in _generic_split(rest, ","):
                self.items.append(_Item("globl", name, fname, lineno))
            return
        if low.startswith((".equ", ".set")):
            rest = line.split(None, 1)[1] if len(line.split(None, 1)) > 1 else ""
            name, _, expr = rest.partition(",")
            self.items.append(_Item("equ", (name.strip(), expr.strip()),
                                    fname, lineno))
            return
        if low.startswith(".tryte"):
            self.items.append(_Item("tryte",
                                    _generic_split(line[len(".tryte"):], ","),
                                    fname, lineno))
            return
        if low.startswith(".word"):
            self.items.append(_Item("word",
                                    _generic_split(line[len(".word"):], ","),
                                    fname, lineno))
            return
        if low.startswith(".asciz"):
            self.items.append(_Item("asciz", line[len(".asciz"):].strip(),
                                    fname, lineno))
            return
        if low.startswith(".ascii"):
            self.items.append(_Item("ascii", line[len(".ascii"):].strip(),
                                    fname, lineno))
            return
        if low.startswith(".space"):
            self.items.append(_Item("space", line[len(".space"):].strip(),
                                    fname, lineno))
            return
        if low.startswith(".align"):
            self.items.append(_Item("align", line[len(".align"):].strip(),
                                    fname, lineno))
            return
        raise AsmError(fname, lineno, "unknown directive %r" % line.split()[0])

    # ---- two passes -------------------------------------------------------------
    def _finish(self, org):
        self.symbols = {}
        pos = org
        pending = []

        def flush_labels(p):
            for lbl in pending:
                self._define(lbl, p)
            pending.clear()

        # pass 1: assign positions, define .equ constants
        for it in self.items:
            if it.kind == "label":
                pending.append(it)
                continue
            flush_labels(pos)
            if it.kind == "equ":
                name, expr = it.data
                self.symbols[name] = self._eval(expr, pos, it)
            elif it.kind == "org":
                pos = self._eval(it.data, pos, it)
            elif it.kind == "align":
                k = self._eval(it.data, pos, it)
                if k <= 0:
                    raise AsmError(it.file, it.line, ".align k must be > 0")
                while pos % k:
                    pos += 1
            elif it.kind == "space":
                n = self._eval(it.data, pos, it)
                if n < 0:
                    raise AsmError(it.file, it.line, ".space n must be >= 0")
                pos += n
            elif it.kind == "instr":
                pos += 3
            elif it.kind == "tryte":
                pos += len(it.data)
            elif it.kind == "word":
                pos += 3 * len(it.data)
            elif it.kind in ("ascii", "asciz"):
                try:
                    items = _parse_string_items(it.data)
                except ValueError as e:
                    raise AsmError(it.file, it.line, str(e))
                n = _string_encoded_length(items)
                if it.kind == "asciz":
                    n += 1
                pos += n
            elif it.kind in ("entry", "globl"):
                pass
            else:
                raise AsmError(it.file, it.line, "cannot size %r" % it.kind)
        flush_labels(pos)

        # pass 2: encode
        img = Image()
        pos = org
        for it in self.items:
            if it.kind == "label":
                if self.symbols.get(it.data) != pos:
                    raise AsmError(it.file, it.line, "label position drift")
                continue
            if it.kind == "globl":
                self.globals.add(it.data)
                continue
            if it.kind == "equ":
                continue
            if it.kind == "org":
                pos = self._eval(it.data, pos, it)
                continue
            if it.kind == "entry":
                img.entry = self._eval(it.data, pos, it)
                continue
            if it.kind == "align":
                k = self._eval(it.data, pos, it)
                while pos % k:
                    img.put_tryte(pos, 0)
                    pos += 1
                continue
            if it.kind == "space":
                n = self._eval(it.data, pos, it)
                for j in range(n):
                    img.put_tryte(pos + j, 0)
                pos += n
                continue
            self._emit(it, pos, img)
            pos += self._size_of(it)
        img.symbols = dict(self.symbols)
        img.globals = set(self.globals)
        return img

    def _size_of(self, it):
        if it.kind == "instr":
            return 3
        if it.kind == "tryte":
            return len(it.data)
        if it.kind == "word":
            return 3 * len(it.data)
        if it.kind in ("ascii", "asciz"):
            items = _parse_string_items(it.data)
            n = _string_encoded_length(items)
            return n + 1 if it.kind == "asciz" else n
        return 0

    def _define(self, lbl_item, pos):
        name = lbl_item.data
        if name in self.symbols:
            raise AsmError(lbl_item.file, lbl_item.line,
                           "duplicate label %r" % name)
        self.symbols[name] = pos

    def _eval(self, expr, pos, it):
        try:
            toks = _tokenize(expr)
        except ValueError as e:
            raise AsmError(it.file, it.line, str(e))
        if not toks:
            raise AsmError(it.file, it.line, "empty expression")
        return _ExprParser(toks, self.symbols, pos, it.file, it.line).parse()

    # ---- encoding ------------------------------------------------------------------
    def _emit(self, it, pos, img):
        if it.kind == "tryte":
            for j, arg in enumerate(it.data):
                img.put_tryte(pos + j, self._tryte_value(arg, it))
            return
        if it.kind == "word":
            for j, arg in enumerate(it.data):
                v = self._eval(arg, pos, it)
                a, b, c = T.word_to_trytes(v)
                img.put_tryte(pos + 3 * j, a)
                img.put_tryte(pos + 3 * j + 1, b)
                img.put_tryte(pos + 3 * j + 2, c)
            return
        if it.kind in ("ascii", "asciz"):
            items = _parse_string_items(it.data)
            enc = []
            for x in items:
                if x is ESC_SENTINEL:
                    enc.append(T.ESCAPE)
                else:
                    enc.extend(T.tritext_encode_char(x))
            if it.kind == "asciz":
                enc.append(0)
            for j, t in enumerate(enc):
                img.put_tryte(pos + j, t)
            return
        if it.kind == "instr":
            word = self._encode_instr(it, pos)
            a, b, c = T.word_to_trytes(word)
            img.put_tryte(pos, a)
            img.put_tryte(pos + 1, b)
            img.put_tryte(pos + 2, c)
            return
        raise AsmError(it.file, it.line, "cannot emit item %r" % it.kind)

    def _tryte_value(self, arg, it):
        arg = arg.strip()
        if arg.startswith("'"):
            try:
                toks = _tokenize(arg)
            except ValueError as e:
                raise AsmError(it.file, it.line, str(e))
            v = _unescape_char(toks[0][1])
        else:
            v = self._eval(arg, 0, it)
        if not (T.TRYTE_MIN <= v <= T.TRYTE_MAX):
            raise AsmError(it.file, it.line, "tryte out of range: %r" % arg)
        return v

    def _encode_instr(self, it, pos):
        parts = it.data.split(None, 1)
        mn = parts[0].upper()
        rest = parts[1].strip() if len(parts) > 1 else ""
        ops = _generic_split(rest, ",") if rest else []
        if mn not in OPCODES:
            raise AsmError(it.file, it.line, "unknown mnemonic %r" % mn)
        fmt = OPCODES[mn]["fmt"]
        op = OPCODES[mn]["op"]

        def need(n):
            if len(ops) != n:
                raise AsmError(it.file, it.line,
                               "%s expects %d operands, got %d" % (mn, n, len(ops)))

        rd = rs = REG_SEL["R0"]
        imm = 0

        if mn in SHIFT_OPS:                       # D-026: reg or large-imm form
            if len(ops) == 2:
                # in-place form: TSHL rd, k|rt  (source register is rd itself)
                rd = self._reg(ops[0], it)
                rs = rd
                k_tok = ops[1]
            elif len(ops) == 3:
                # full form: TSHL rd, rs, rt|k
                rd = self._reg(ops[0], it)
                rs = self._reg(ops[1], it)
                k_tok = ops[2]
            else:
                raise AsmError(it.file, it.line,
                               "%s takes 2 or 3 operands, got %d" % (mn, len(ops)))
            if k_tok.upper() in REG_SEL:
                imm = self._reg(k_tok, it)        # reg form: k = R[k_tok]
            else:
                k = self._eval(k_tok, pos, it)
                if -4 <= k <= 4:
                    raise AsmError(it.file, it.line,
                                   "%s by |k| <= 4 must use a register form "
                                   "(encoding ambiguity, D-026)" % mn)
                imm = self._imm(k, it)
        elif fmt == "SYS":
            need(0)
        elif fmt == "RRR":
            need(3)
            rd = self._reg(ops[0], it)
            rs = self._reg(ops[1], it)
            imm = self._reg(ops[2], it)           # rt rides in the low 2 imm trits
        elif fmt == "RS":
            need(2)
            rd = self._reg(ops[0], it)
            rs = self._reg(ops[1], it)
        elif fmt == "R":
            need(1)
            rs = self._reg(ops[0], it)
        elif fmt == "RI":
            need(2)
            rd = self._reg(ops[0], it)
            imm = self._imm(self._eval(ops[1], pos, it), it)
        elif fmt == "RRI":
            need(3)
            rd = self._reg(ops[0], it)
            rs = self._reg(ops[1], it)
            imm = self._imm(self._eval(ops[2], pos, it), it)
        elif fmt == "OFF":
            need(1)
            imm = self._imm(self._eval(ops[0], pos, it) - (pos + 3), it)
        elif fmt == "RS_OFF":
            need(2)
            rs = self._reg(ops[0], it)
            imm = self._imm(self._eval(ops[1], pos, it) - (pos + 3), it)
        elif fmt == "CSR_R":
            need(2)
            rd = self._reg(ops[0], it)
            imm = self._csr_num(ops[1], it)
        elif fmt == "CSR_W":
            need(2)
            imm = self._csr_num(ops[0], it)
            rs = self._reg(ops[1], it)
        elif fmt == "TRAPF":
            need(1)
            imm = self._imm(self._eval(ops[0], pos, it), it)
        else:
            raise AsmError(it.file, it.line, "unsupported format %r" % fmt)

        return ((op * 9 + rd) * 9 + rs) * 3 ** 10 + imm

    def _reg(self, tok, it):
        t = tok.strip().upper()
        if t in REG_SEL:
            return REG_SEL[t]
        raise AsmError(it.file, it.line, "expected register, got %r" % tok)

    def _csr_num(self, tok, it):
        name = tok.strip().upper()
        if name in CSR_NUM:
            return CSR_NUM[name]
        raise AsmError(it.file, it.line, "unknown CSR %r" % tok)

    def _imm(self, v, it):
        if not (IMM_MIN <= v <= IMM_MAX):
            raise AsmError(it.file, it.line,
                           "immediate out of 10-trit range: %d" % v)
        return v


def _is_reg(tok):
    return tok.strip().upper() in REG_SEL


# ---- output image ---------------------------------------------------------------------
class Image:
    """Sparse tryte image produced by the assembler."""

    def __init__(self):
        self.trytes = {}          # addr -> tryte value
        self.symbols = {}
        self.globals = set()
        self.entry = None

    def put_tryte(self, addr, v):
        assert T.TRYTE_MIN <= v <= T.TRYTE_MAX
        if addr in self.trytes and self.trytes[addr] != v:
            raise AsmError("<image>", addr, "overlap at tryte %d" % addr)
        self.trytes[addr] = v

    def spans(self):
        """Maximal contiguous runs -> [(start, [trytes]), ...] sorted by start."""
        if not self.trytes:
            return []
        addrs = sorted(self.trytes)
        segs = []
        start = prev = addrs[0]
        buf = [self.trytes[addrs[0]]]
        for a in addrs[1:]:
            if a == prev + 1:
                buf.append(self.trytes[a])
            else:
                segs.append((start, buf))
                start = a
                buf = [self.trytes[a]]
            prev = a
        segs.append((start, buf))
        return segs

    def to_trits(self):
        out = []
        for _start, data in self.spans():
            for t in data:
                out.extend(T.tryte_to_trits(t))
        return out

    def to_bytes(self):
        return packmod.trits_to_bytes(self.to_trits())

    def read_word_at(self, addr):
        a, b, c = self.trytes[addr], self.trytes[addr + 1], self.trytes[addr + 2]
        return T.trytes_to_word((a, b, c))


# ---- convenience API --------------------------------------------------------------------
def assemble_source(text, org=0):
    a = Assembler()
    return a.assemble(text, org=org)


def assemble_file(path, org=0, rom=False):
    a = Assembler()
    img = a.assemble_file(path, org=org)
    if rom:
        # fixed-size ROM image: zero-trytes everywhere else (D-011)
        buf = [0] * ROM_SIZE
        for start, data in img.spans():
            if start + len(data) > ROM_SIZE:
                raise AsmError(os.path.basename(path), 0,
                               "ROM image exceeds %d trytes" % ROM_SIZE)
            buf[start:start + len(data)] = data
        img.rom_trits = []
        for t in buf:
            img.rom_trits.extend(T.tryte_to_trits(t))
        img.rom_bytes = packmod.trits_to_bytes(img.rom_trits)
    return img

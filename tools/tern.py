#!/usr/bin/env python3
"""
Tern - a tiny C-like language compiler targeting TriASM (Setun Tri OS).

Subset supported:
  Types: int (18-trit word), char (1 tryte)
  Statements: if/else, while, for, return, expression-stmt, compound { }
  Expressions: binary ops (+ - * / % == != < > <= >= && ||), unary (- !), assignment (= += -= *= /= %=)
  Functions: definition, call, recursion
  I/O: putchar(c), puts(s)  [string literals]
  Variables: global static, local (stack frame)
"""

import sys
import os
import re

# ---- Token types ------------------------------------------------------------
TOKENS = [
    # keywords
    ("INT", r"\bint\b"),
    ("CHAR", r"\bchar\b"),
    ("IF", r"\bif\b"),
    ("ELSE", r"\belse\b"),
    ("WHILE", r"\bwhile\b"),
    ("FOR", r"\bfor\b"),
    ("RETURN", r"\breturn\b"),
    ("VOID", r"\bvoid\b"),
    # I/O builtins
    ("PUTCHAR", r"\bputchar\b"),
    ("PUTS", r"\bputs\b"),
    # IPC builtins (server target, M10): map to kernel syscalls 9/8/11/2
    ("RECV", r"\brecv\b"),
    ("SEND", r"\bsend\b"),
    ("REPLY", r"\breply\b"),
    ("EXIT", r"\bexit\b"),
    # literals
    ("NUMBER", r"-?\d+"),
    ("STRING", r'"(?:\\.|[^"\\])*"'),
    ("CHARLIT", r"'(?:\\.|[^'\\])'"),
    # identifiers
    ("IDENT", r"[A-Za-z_][A-Za-z0-9_]*"),
    # operators (longer first)
    ("EQ", r"=="), ("NE", r"!="), ("LE", r"<="), ("GE", r">="),
    ("AND", r"&&"), ("OR", r"\|\|"),
    ("PLUS", r"\+"), ("MINUS", r"-"), ("MUL", r"\*"), ("MOD", r"%"),
    ("ASSIGN", r"="), ("PLUSEQ", r"\+="), ("MINUSEQ", r"-="), ("MULEQ", r"\*="), ("DIVEQ", r"/="), ("MODEQ", r"%="),
    ("LT", r"<"), ("GT", r">"),
    ("NOT", r"!"),
    # punctuation
    ("LPAREN", r"\("), ("RPAREN", r"\)"),
    ("LBRACE", r"\{"), ("RBRACE", r"\}"),
    ("LBRACKET", r"\["), ("RBRACKET", r"\]"),
    ("SEMICOLON", r";"), ("COMMA", r","),
    # whitespace / comments (skip) - COMMENT before DIV so comments are matched first
    ("SKIP", r"\s+"),
    ("COMMENT", r"//.*?$|/\*.*?\*/"),
    ("DIV", r"/"),
]

TOKEN_RE = re.compile("|".join(f"(?P<{name}>{pattern})" for name, pattern in TOKENS), re.MULTILINE | re.DOTALL)

class Token:
    __slots__ = ("type", "value", "line", "col")
    def __init__(self, type_, value, line, col):
        self.type = type_; self.value = value; self.line = line; self.col = col
    def __repr__(self): return f"Token({self.type}, {self.value!r})"

def tokenize(code):
    pos = 0; line = 1; col = 1
    tokens = []
    for m in TOKEN_RE.finditer(code):
        typ = m.lastgroup; val = m.group(typ)
        if typ in ("SKIP", "COMMENT"):
            for ch in val:
                if ch == "\n": line += 1; col = 1
                else: col += 1
            continue
        tokens.append(Token(typ, val, line, col))
        for ch in val:
            if ch == "\n": line += 1; col = 1
            else: col += 1
    tokens.append(Token("EOF", "", line, col))
    return tokens

# ---- AST nodes --------------------------------------------------------------
class ASTNode: pass

class Program(ASTNode):
    def __init__(self, funcs, globals_): self.funcs = funcs; self.globals = globals_

class Function(ASTNode):
    def __init__(self, name, ret_type, params, body, is_main=False):
        self.name = name; self.ret_type = ret_type; self.params = params; self.body = body; self.is_main = is_main

class VarDecl(ASTNode):
    def __init__(self, name, type_, init=None, is_global=False):
        self.name = name; self.type = type_; self.init = init; self.is_global = is_global

class Block(ASTNode):
    def __init__(self, stmts): self.stmts = stmts

class IfStmt(ASTNode):
    def __init__(self, cond, then_branch, else_branch=None):
        self.cond = cond; self.then_branch = then_branch; self.else_branch = else_branch

class WhileStmt(ASTNode):
    def __init__(self, cond, body): self.cond = cond; self.body = body

class ForStmt(ASTNode):
    def __init__(self, init, cond, step, body): self.init = init; self.cond = cond; self.step = step; self.body = body

class ReturnStmt(ASTNode):
    def __init__(self, expr=None): self.expr = expr

class ExprStmt(ASTNode):
    def __init__(self, expr): self.expr = expr

class BinaryOp(ASTNode):
    def __init__(self, op, left, right): self.op = op; self.left = left; self.right = right

class UnaryOp(ASTNode):
    def __init__(self, op, expr): self.op = op; self.expr = expr

class Assign(ASTNode):
    def __init__(self, target, op, value): self.target = target; self.op = op; self.value = value

class VarRef(ASTNode):
    def __init__(self, name): self.name = name

class Call(ASTNode):
    def __init__(self, name, args): self.name = name; self.args = args

class Number(ASTNode):
    def __init__(self, value): self.value = int(value)

class StringLit(ASTNode):
    def __init__(self, value): self.value = value

class CharLit(ASTNode):
    def __init__(self, value): self.value = value

# ---- Parser -----------------------------------------------------------------
class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0
        self.current = tokens[0]

    def eat(self, expected_type):
        if self.current.type == expected_type:
            val = self.current.value
            self.pos += 1
            self.current = self.tokens[self.pos]
            return val
        raise SyntaxError(f"Expected {expected_type}, got {self.current.type} at line {self.current.line}")

    def peek(self, *types):
        return self.current.type in types

    def parse(self):
        funcs = []
        globals_ = []
        while self.current.type != "EOF":
            if self.peek("INT", "CHAR", "VOID"):
                decl_type = self.eat(self.current.type)
                name = self.eat("IDENT")
                if self.peek("LPAREN"):
                    self.eat("LPAREN")
                    params = []
                    if not self.peek("RPAREN"):
                        while True:
                            ptype = self.eat(self.current.type)
                            pname = self.eat("IDENT")
                            params.append((ptype, pname))
                            if not self.peek("COMMA"): break
                            self.eat("COMMA")
                    self.eat("RPAREN")
                    self.eat("LBRACE")
                    body = self.parse_block()
                    self.eat("RBRACE")
                    is_main = (name == "main")
                    funcs.append(Function(name, decl_type, params, body, is_main))
                else:
                    init = None
                    if self.peek("ASSIGN"):
                        self.eat("ASSIGN")
                        init = self.parse_expr()
                    self.eat("SEMICOLON")
                    globals_.append(VarDecl(name, decl_type, init, is_global=True))
            else:
                raise SyntaxError(f"Unexpected token {self.current.type} at line {self.current.line}")
        return Program(funcs, globals_)

    def parse_block(self):
        stmts = []
        while not self.peek("RBRACE", "EOF"):
            stmts.append(self.parse_stmt())
        return Block(stmts)

    def parse_stmt(self):
        if self.peek("IF"):
            self.eat("IF"); self.eat("LPAREN")
            cond = self.parse_expr(); self.eat("RPAREN")
            self.eat("LBRACE"); then_b = self.parse_block(); self.eat("RBRACE")
            else_b = None
            if self.peek("ELSE"):
                self.eat("ELSE"); self.eat("LBRACE"); else_b = self.parse_block(); self.eat("RBRACE")
            return IfStmt(cond, then_b, else_b)
        if self.peek("WHILE"):
            self.eat("WHILE"); self.eat("LPAREN")
            cond = self.parse_expr(); self.eat("RPAREN")
            self.eat("LBRACE"); body = self.parse_block(); self.eat("RBRACE")
            return WhileStmt(cond, body)
        if self.peek("FOR"):
            self.eat("FOR"); self.eat("LPAREN")
            init = self.parse_for_init() if not self.peek("SEMICOLON") else None
            self.eat("SEMICOLON")
            cond = self.parse_expr() if not self.peek("SEMICOLON") else None
            self.eat("SEMICOLON")
            step = self.parse_expr() if not self.peek("RPAREN") else None
            self.eat("RPAREN")
            self.eat("LBRACE"); body = self.parse_block(); self.eat("RBRACE")
            return ForStmt(init, cond, step, body)
        if self.peek("RETURN"):
            self.eat("RETURN")
            expr = self.parse_expr() if not self.peek("SEMICOLON") else None
            self.eat("SEMICOLON")
            return ReturnStmt(expr)
        if self.peek("INT", "CHAR"):
            decl_type = self.eat(self.current.type)
            name = self.eat("IDENT")
            init = None
            if self.peek("ASSIGN"):
                self.eat("ASSIGN"); init = self.parse_expr()
            self.eat("SEMICOLON")
            return VarDecl(name, decl_type, init)
        if self.peek("LBRACE"):
            self.eat("LBRACE"); b = self.parse_block(); self.eat("RBRACE"); return b
        expr = self.parse_expr()
        self.eat("SEMICOLON")
        return ExprStmt(expr)

    def parse_for_init(self):
        if self.peek("INT", "CHAR"):
            decl_type = self.eat(self.current.type)
            name = self.eat("IDENT")
            init = None
            if self.peek("ASSIGN"):
                self.eat("ASSIGN"); init = self.parse_expr()
            return VarDecl(name, decl_type, init)
        return self.parse_expr()

    def parse_expr(self):
        left = self.parse_logical_or()
        # assignment (lowest precedence, right-assoc; target must be a VarRef)
        if self.peek("ASSIGN", "PLUSEQ", "MINUSEQ", "MULEQ", "DIVEQ", "MODEQ"):
            if isinstance(left, VarRef):
                op = self.eat(self.current.type)
                value = self.parse_expr()
                return Assign(left, op, value)
        return left

    def parse_logical_or(self):
        left = self.parse_logical_and()
        while self.peek("OR"):
            self.eat("OR"); right = self.parse_logical_and(); left = BinaryOp("||", left, right)
        return left

    def parse_logical_and(self):
        left = self.parse_equality()
        while self.peek("AND"):
            self.eat("AND"); right = self.parse_equality(); left = BinaryOp("&&", left, right)
        return left

    def parse_equality(self):
        left = self.parse_relational()
        while self.peek("EQ", "NE"):
            op = self.eat(self.current.type)
            right = self.parse_relational()
            left = BinaryOp(op, left, right)
        return left

    def parse_relational(self):
        left = self.parse_additive()
        while self.peek("LT", "GT", "LE", "GE"):
            op = self.eat(self.current.type)
            right = self.parse_additive()
            left = BinaryOp(op, left, right)
        return left

    def parse_additive(self):
        left = self.parse_multiplicative()
        while self.peek("PLUS", "MINUS"):
            op = self.eat(self.current.type)
            right = self.parse_multiplicative()
            left = BinaryOp(op, left, right)
        return left

    def parse_multiplicative(self):
        left = self.parse_unary()
        while self.peek("MUL", "DIV", "MOD"):
            op = self.eat(self.current.type)
            right = self.parse_unary()
            left = BinaryOp(op, left, right)
        return left

    def parse_unary(self):
        if self.peek("MINUS", "NOT"):
            op = self.eat(self.current.type)
            return UnaryOp(op, self.parse_unary())
        return self.parse_postfix()

    def parse_postfix(self):
        left = self.parse_primary()
        while True:
            if self.peek("LPAREN"):
                self.eat("LPAREN")
                args = []
                if not self.peek("RPAREN"):
                    while True:
                        args.append(self.parse_expr())
                        if not self.peek("COMMA"): break
                        self.eat("COMMA")
                self.eat("RPAREN")
                if isinstance(left, VarRef):
                    left = Call(left.name, args)
                else:
                    left = Call(None, args)
            else:
                break
        return left

    def parse_primary(self):
        if self.peek("NUMBER"):
            return Number(self.eat("NUMBER"))
        if self.peek("STRING"):
            return StringLit(self.eat("STRING")[1:-1])
        if self.peek("CHARLIT"):
            v = self.eat("CHARLIT")[1:-1]
            return CharLit(v)
        if self.peek("IDENT", "PUTS", "PUTCHAR", "RECV", "SEND", "REPLY", "EXIT"):
            name = self.eat(self.current.type)
            # function call
            if self.peek("LPAREN"):
                self.eat("LPAREN")
                args = []
                if not self.peek("RPAREN"):
                    while True:
                        args.append(self.parse_expr())
                        if not self.peek("COMMA"): break
                        self.eat("COMMA")
                self.eat("RPAREN")
                return Call(name, args)
            return VarRef(name)
        if self.peek("LPAREN"):
            self.eat("LPAREN"); e = self.parse_expr(); self.eat("RPAREN"); return e
        raise SyntaxError(f"Unexpected token {self.current.type} at line {self.current.line}")

# ---- Code Generator (TriASM) -----------------------------------------------
class CodeGen:
    def __init__(self):
        self.lines = []
        self.strings = {}
        self.string_id = 0
        self.label_id = 0
        self.var_offsets = {}
        self.param_offsets = {}
        self.next_local_off = 0

    def emit(self, line): self.lines.append(line)

    def new_label(self, prefix="L"):
        self.label_id += 1
        return f"{prefix}{self.label_id}"

    def string_label(self, s):
        for lbl, val in self.strings.items():
            if val == s: return lbl
        self.string_id += 1
        lbl = f"Lstr{self.string_id}"
        self.strings[lbl] = s
        return lbl

    def get_var_offset(self, name):
        if name in self.param_offsets:
            return self.param_offsets[name]
        if name not in self.var_offsets:
            self.next_local_off -= 3
            self.var_offsets[name] = self.next_local_off
        return self.var_offsets[name]

    def _call_target(self, name):
        """Map builtin names to the compiler-emitted wrapper labels."""
        return {
            "putchar": "tern_putchar",
            "puts": "tern_puts",
            "recv": "tern_recv",
            "send": "tern_send",
            "reply": "tern_reply",
            "exit": "tern_exit",
        }.get(name, name)

    def gen_expr(self, node):
        if isinstance(node, Number):
            self.emit(f"    const R1, {node.value}")
        elif isinstance(node, VarRef):
            off = self.get_var_offset(node.name)
            if off > 0:
                self.emit(f"    LEA R1, R8, {off}")
                self.emit("    LDW R1, R1")
            else:
                self.emit(f"    LEA R1, R8, {off}")
                self.emit("    LDW R1, R1")
        elif isinstance(node, BinaryOp):
            self.gen_expr(node.right)
            self.emit("    push R1")
            self.gen_expr(node.left)
            self.emit("    pop R2")
            op = node.op
            if op == "+": self.emit("    ADD R1, R1, R2")
            elif op == "-": self.emit("    SUB R1, R1, R2")
            elif op == "*": self.emit("    MUL R1, R1, R2")
            elif op == "/": self.emit("    DIV R1, R1, R2")
            elif op == "%": self.emit("    MOD R1, R1, R2")
            elif op == "==": self.emit("    CMP3 R1, R1, R2")
            elif op == "!=": self.emit("    CMP3 R1, R1, R2"); self.emit("    NEG R1, R1")
            elif op == "<": self.emit("    CMP3 R1, R1, R2"); self.emit("    NEG R1, R1")
            elif op == ">": self.emit("    CMP3 R1, R1, R2")
            elif op == "<=": self.emit("    CMP3 R1, R1, R2"); self.emit("    NEG R1, R1")
            elif op == ">=": self.emit("    CMP3 R1, R1, R2")
            elif op == "&&": self.emit("    TMUL R1, R1, R2")
            elif op == "||": self.emit("    TANY R1, R1, R2")
        elif isinstance(node, UnaryOp):
            self.gen_expr(node.expr)
            if node.op == "-": self.emit("    NEG R1, R1")
            elif node.op == "!": self.emit("    TINV R1, R1")
        elif isinstance(node, Call):
            for arg in reversed(node.args):
                self.gen_expr(arg)
                self.emit("    push R1")
            self.emit("    call %s" % self._call_target(node.name))
            for _ in node.args: self.emit("    pop R1")
        elif isinstance(node, Number):
            self.emit(f"    const R1, {node.value}")
        elif isinstance(node, StringLit):
            lbl = self.string_label(node.value)
            self.emit(f"    const R1, {lbl}")
        elif isinstance(node, CharLit):
            self.emit(f"    const R1, {ord(node.value)}")
        elif isinstance(node, Assign):
            self.gen_expr(node.value)
            off = self.get_var_offset(node.target.name)
            self.emit("    push R1")
            self.emit(f"    LEA R2, R8, {off}")
            self.emit("    pop R1")
            self.emit("    STW R2, R1")
        elif isinstance(node, VarRef):
            off = self.get_var_offset(node.name)
            if off > 0:
                self.emit(f"    LEA R1, R8, {off}"); self.emit("    LDW R1, R1")
            else:
                self.emit(f"    LEA R1, R8, {off}"); self.emit("    LDW R1, R1")

    def gen_stmt(self, node):
        if isinstance(node, Block):
            for s in node.stmts: self.gen_stmt(s)
        elif isinstance(node, IfStmt):
            else_lbl = self.new_label("else")
            end_lbl = self.new_label("endif")
            self.gen_expr(node.cond)
            self.emit(f"    BRZ R1, {else_lbl if node.else_branch else end_lbl}")
            self.gen_stmt(node.then_branch)
            if node.else_branch:
                self.emit(f"    JMP {end_lbl}")
                self.emit(f"{else_lbl}:")
                self.gen_stmt(node.else_branch)
            self.emit(f"{end_lbl}:")
        elif isinstance(node, WhileStmt):
            start = self.new_label("while")
            end = self.new_label("endwhile")
            self.emit(f"{start}:")
            self.gen_expr(node.cond)
            self.emit(f"    BRZ R1, {end}")
            self.gen_stmt(node.body)
            self.emit(f"    JMP {start}")
            self.emit(f"{end}:")
        elif isinstance(node, ForStmt):
            start = self.new_label("for")
            end = self.new_label("endfor")
            if node.init: self.gen_stmt(node.init)
            self.emit(f"{start}:")
            if node.cond:
                self.gen_expr(node.cond)
                self.emit(f"    BRZ R1, {end}")
            self.gen_stmt(node.body)
            if node.step: self.gen_expr(node.step)
            self.emit(f"    JMP {start}")
            self.emit(f"{end}:")
        elif isinstance(node, ReturnStmt):
            if node.expr: self.gen_expr(node.expr)
            self.emit("    ret")
        elif isinstance(node, ExprStmt):
            self.gen_expr(node.expr)
        elif isinstance(node, VarDecl):
            if node.init:
                self.gen_expr(node.init)
                off = self.get_var_offset(node.name)
                self.emit("    push R1")
                self.emit(f"    LEA R2, R8, {off}")
                self.emit("    pop R1")
                self.emit("    STW R2, R1")
        elif isinstance(node, Assign):
            self.gen_expr(node.value)
            off = self.get_var_offset(node.target.name)
            self.emit("    push R1")
            self.emit(f"    LEA R2, R8, {off}")
            self.emit("    pop R1")
            self.emit("    STW R2, R1")
        elif isinstance(node, Call):
            for arg in reversed(node.args):
                self.gen_expr(arg)
                self.emit("    push R1")
            self.emit("    call %s" % self._call_target(node.name))
            for _ in node.args: self.emit("    pop R1")

    def generate(self, program):
        # Generate a kernel-integrated TriASM program
        self.emit("; ==== Tern-generated TriASM (kernel-integrated) ====")
        self.emit("")
        self.emit(".include \"kernel/kernel.asm\"")
        self.emit("")
        # String literals go in STRBASE region
        self.emit("; ==== STRING LITERALS ====")
        self.emit(f".org STRBASE")
        for lbl, s in self.strings.items():
            esc = s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t").replace("\"", "\\\"")
            self.emit(f'{lbl}: .asciz "{esc}"')
        self.emit("")
        # Tern program entry point - called from kernel init
        self.emit("; ==== TERN PROGRAM ENTRY ====")
        self.emit("tern_main:")
        self.emit("    push R7")
        self.gen_stmt(program.funcs[0].body)
        self.emit("")
        return "\n".join(self.lines)

    def generate_txe(self, program, org=4707002):
        """M8 user-program format (D-046/D-048): standalone TXE loaded via exec.

        The thread starts with R1 = create-argument (the endpoint cap); the
        prologue parks it in TERN_CAP_SLOT. IPC builtins (recv/send/reply)
        are compiler-emitted wrappers over the kernel syscalls
        (num: 9=RECV, 8=SEND, 11=REPLY; cap in R2, msg in R3).
        """
        # strings first (labels needed by the body)
        self.lines = []
        self.emit("; ==== Tern-generated TXE (user program, D-046/D-048) ====")
        self.emit('    .include "lib/trilib.asm"')
        self.emit("    .org %d" % org)          # must be == 0 mod 3 (D-048)
        self.emit("    .entry tern_main")
        self.emit("TERN_CAP_SLOT: .word 0       ; parked create-arg (cap ref)")
        self.emit("")
        # builtin wrappers (emit before the body so calls resolve)
        self.emit("tern_recv:                    ; -> R1 = msg (0 = no sender)")
        self.emit("    push R7")
        self.emit("    LDI R1, 9                  ; RECV")
        self.emit("    const R2, TERN_CAP_SLOT")
        self.emit("    LDW R2, R2")
        self.emit("    TRAP 0")
        self.emit("    ADD R1, R3, R0             ; msg1 -> result")
        self.emit("    pop R7")
        self.emit("    ret")
        self.emit("")
        self.emit("tern_send:                    ; R1 = msg -> SEND")
        self.emit("    push R7")
        self.emit("    push R1")
        self.emit("    LDI R1, 8                  ; SEND")
        self.emit("    const R2, TERN_CAP_SLOT")
        self.emit("    LDW R2, R2")
        self.emit("    pop R3                     ; msg1")
        self.emit("    TRAP 0")
        self.emit("    pop R7")
        self.emit("    ret")
        self.emit("")
        self.emit("tern_reply:                   ; R1 = msg -> REPLY")
        self.emit("    push R7")
        self.emit("    push R1")
        self.emit("    LDI R1, 11                 ; REPLY")
        self.emit("    const R2, TERN_CAP_SLOT")
        self.emit("    LDW R2, R2")
        self.emit("    pop R3                     ; reply msg1")
        self.emit("    TRAP 0")
        self.emit("    pop R7")
        self.emit("    ret")
        self.emit("")
        self.emit("tern_putchar:                 ; R1 = char -> DEBUG_PUTC (6)")
        self.emit("    push R7")
        self.emit("    push R1")
        self.emit("    LDI R1, 6")
        self.emit("    pop R2                     ; char into arg slot")
        self.emit("    TRAP 0")
        self.emit("    pop R7")
        self.emit("    ret")
        self.emit("")
        self.emit("tern_puts:                    ; R1 = &msg (NUL-terminated)")
        self.emit("    push R7")
        self.emit("    ADD R3, R1, R0")
        self.emit("Ltp_loop:")
        self.emit("    LDT R2, R3")
        self.emit("    BRZ R2, Ltp_done")
        self.emit("    push R3")
        self.emit("    ADD R1, R2, R0")
        self.emit("    call tern_putchar")
        self.emit("    pop R3")
        self.emit("    ADDI R3, R3, 1")
        self.emit("    JMP Ltp_loop")
        self.emit("Ltp_done:")
        self.emit("    pop R7")
        self.emit("    ret")
        self.emit("")
        self.emit("tern_exit:                    ; EXIT (2): thread reaped")
        self.emit("    LDI R1, 2")
        self.emit("    TRAP 0")
        self.emit("    ret")
        self.emit("")
        # entry: park the cap, run the body
        self.emit("tern_main:")
        self.emit("    push R7")
        self.emit("    const R2, TERN_CAP_SLOT")
        self.emit("    STW R2, R1                 ; park create-arg (cap)")
        self.gen_stmt(program.funcs[0].body)
        self.emit("    call tern_exit")
        self.emit("")
        # string data at the end of the image
        self.emit("; ==== STRING DATA ====")
        for lbl, s in self.strings.items():
            esc = s.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t").replace("\"", "\\\"")
            self.emit(f'{lbl}: .asciz "{esc}"')
        return "\n".join(self.lines)

def compile_tern(source, output_file, target="kernel", org=4707002):
    """target: 'kernel' (kernel-integrated, .include kernel) or
    'txe' (M8 user-program format, exec-loadable, IPC builtins)."""
    tokens = tokenize(source)
    parser = Parser(tokens)
    program = parser.parse()
    cg = CodeGen()
    if target == "txe":
        asm = cg.generate_txe(program, org=org)
    else:
        asm = cg.generate(program)
    from pathlib import Path
    Path(output_file).write_text(asm, encoding="utf-8")
    print(f"Generated {output_file} (target={target})")

if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Tern -> TriASM compiler")
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--target", choices=("kernel", "txe"), default="kernel")
    ap.add_argument("--org", type=int, default=4707002)
    a = ap.parse_args()
    with open(a.input) as f:
        src = f.read()
    compile_tern(src, a.output, target=a.target, org=a.org)
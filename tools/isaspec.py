"""isaspec.py — loader/validator for spec/isa.yaml (restricted YAML subset).

The ISA file is the single source of truth (GLM_MASTER_PROMPT rule 3). This module
parses a deliberately small YAML subset (nested maps, inline lists/maps, quoted
scalars, comments) so the toolchain has no third-party dependency.

Usage:
    from isaspec import load_isa
    isa = load_isa()                    # loads <repo>/spec/isa.yaml, validates
    isa["opcodes"]["ADD"]["op"] == 1
"""
from __future__ import annotations

import os
import re

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ISA_PATH = os.path.join(REPO_ROOT, "spec", "isa.yaml")


def _scalar(tok: str):
    tok = tok.strip()
    if len(tok) >= 2 and tok[0] == tok[-1] and tok[0] in "\"'":
        return tok[1:-1]
    try:
        return int(tok)
    except ValueError:
        pass
    try:
        return float(tok)
    except ValueError:
        pass
    if tok in ("true", "yes"):
        return True
    if tok in ("false", "no"):
        return False
    return tok


def _split_top(s: str, sep: str) -> list:
    """Split on sep at top nesting level, respecting quotes and brackets."""
    out, depth, cur, i, q = [], 0, [], 0, None
    while i < len(s):
        c = s[i]
        if q:
            if c == q:
                q = None
            cur.append(c)
        elif c in "\"'":
            q = c
            cur.append(c)
        elif c in "[{(":
            depth += 1
            cur.append(c)
        elif c in "]})":
            depth -= 1
            cur.append(c)
        elif c == sep and depth == 0:
            out.append("".join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    if cur:
        out.append("".join(cur))
    return [x for x in (p.strip() for p in out) if x != ""]


def _inline_value(s: str):
    s = s.strip()
    if s.startswith("[") and s.endswith("]"):
        return [_inline_value(x) for x in _split_top(s[1:-1], ",")]
    if s.startswith("{") and s.endswith("}"):
        d = {}
        for part in _split_top(s[1:-1], ","):
            k, _, v = part.partition(":")
            d[k.strip()] = _inline_value(v)
        return d
    return _scalar(s)


def parse_restricted_yaml(text: str) -> dict:
    """Parse the YAML subset used by spec/isa.yaml into nested dicts/lists."""
    root: dict = {}
    # stack of (indent, container)
    stack = [(-1, root)]
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip() or line.strip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        body = line.strip()
        # strip trailing comment (naive: only outside quotes)
        cut, q = None, None
        for i, c in enumerate(body):
            if q:
                if c == q:
                    q = None
            elif c in "\"'":
                q = c
            elif c == "#" and (i == 0 or body[i - 1] == " "):
                cut = i
                break
        if cut is not None:
            body = body[:cut].strip()
            if not body:
                continue
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if body.startswith("- "):
            if not isinstance(parent, list):
                raise ValueError("list item without list context: %r" % raw)
            parent.append(_inline_value(body[2:]))
            continue
        key, sep, val = body.partition(":")
        if not sep:
            raise ValueError("cannot parse line: %r" % raw)
        key = key.strip()
        val = val.strip()
        if val == "":
            # container or list; decide when first child arrives
            child: dict = {}
            parent[key] = child
            stack.append((indent, child))
        else:
            parent[key] = _inline_value(val)
    return root


def _walk(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from _walk(v, path + "/" + str(k))
    else:
        yield path, node


def validate(isa: dict) -> None:
    """Structural invariants; raises AssertionError on any violation."""
    assert isa["isa"] == "TriISA"
    w = isa["format"]["width_trits"]
    assert w == 18
    imm_lo, imm_hi = isa["format"]["imm_range"]
    assert imm_lo == -(3 ** 10 - 1) // 2 and imm_hi == (3 ** 10 - 1) // 2  # 10 trits
    ops = isa["opcodes"]
    seen = {}
    for name, spec in ops.items():
        ov = spec["op"]
        assert -40 <= ov <= 40, "op out of range: %s" % name
        assert ov not in seen, "duplicate op %d (%s vs %s)" % (ov, seen[ov], name)
        seen[ov] = name
        assert spec["fmt"] in isa["formats"], "unknown fmt for %s" % name
    csrs = isa["csrs"]
    nums = [v for k, v in csrs.items() if isinstance(v, int)]
    assert len(nums) == len(set(nums)), "duplicate CSR numbers"
    causes = isa["causes"]
    vals = [v for k, v in causes.items() if isinstance(v, int)]
    assert len(vals) == len(set(vals)), "duplicate cause numbers"
    regs = isa["registers"]["gprs"]
    assert list(regs.keys()) == ["R%d" % i for i in range(9)]


def load_isa(path: str = ISA_PATH) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        isa = parse_restricted_yaml(f.read())
    validate(isa)
    return isa


# ---- convenience views ------------------------------------------------------
def opcode_table(isa: dict) -> dict:
    """mnemonic -> {'op': int, 'fmt': str, 'sem': str}"""
    return dict(isa["opcodes"])


def op_to_mnemonic(isa: dict) -> dict:
    return {spec["op"]: name for name, spec in isa["opcodes"].items()}


if __name__ == "__main__":
    spec = load_isa()
    print("TriISA %s frozen %s: %d opcodes, %d CSRs, %d causes — OK"
          % (spec["version"], spec["frozen"], len(spec["opcodes"]),
             len([k for k in spec["csrs"] if isinstance(spec["csrs"][k], int)]),
             len([k for k in spec["causes"] if isinstance(spec["causes"][k], int)])))

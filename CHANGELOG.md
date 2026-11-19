# CHANGELOG — Setun Tri OS

All notable changes per milestone. Format: `M<n>: summary` (see GLM_MASTER_PROMPT rule 7).

## M1 — 2026-11-19 — Assembler + TVM CPU core
- `tools/triasm.py`: two-pass symbolic assembler — labels, macros (%arg substitution,
  nested invocations), .include, .org/.entry/.globl/.equ/.tryte/.word/.ascii/.asciz/.space/.align;
  balanced-ternary expression evaluator; PC-relative branch encoding (D-006);
  shift-encoding disambiguation enforced (D-026).
- `tools/tvm/memory.py`: PhysicalMemory (biased-tryte storage, BusError on out-of-range).
- `tools/tvm/cpu.py`: full TriISA v0.1 CPU — 49 opcodes, integer field decode, wrap arithmetic,
  3-way compare/branch + BR3 jump tables, traps (D-013), trap entry (D-017), CSR file,
  WFI/IRQ delivery, XCHG/CAS atomics.
- `tools/tridis.py`: disassembler; round-trip tested on ~2000 random encodings of every format.
- `tools/pack.py`: 5-trits/byte codec (D-015) + TXE container build/parse with checksum (D-014).
- Tests (70 green): every opcode exercised; fib(20)=6765; sieve to 200 → 46 primes;
  BR3 sign-dispatch demo; DIV/MOD edge matrix vs trit.py references; trap semantics
  (ILLEGAL/PRIVILEGE/ALIGN/PAGEFAULT/DIV0/SYSCALL); RETI round-trip; WFI wake rules (D-027).
- DECISIONS: D-026 (shift encoding), D-027 (privileged set, WFI wake).

## M0 — 2026-11-19 — Spec & trit library
- Frozen `spec/isa.yaml` (49 opcodes, 10 CSRs, 9 trap causes; formats + semantics).
- `tools/isaspec.py`: restricted-YAML loader + structural validator for the ISA.
- `tools/trit.py`: balanced ternary core — wrap/to_trits/from_trits, tryte/word packing,
  add/sub/mul/div/mod (round-nearest, ties toward zero, D-005), mulh, tritwise ops
  (TMIN/TMAX/TINV/TCONS/TANY/TSUM/TMUL), ternary shifts/rotate (D-008), tryte checksum,
  TriText codec (729-entry page incl. Hungarian, +364 escape for full Unicode).
- `docs/DECISIONS.md`: D-001..D-025 recorded.
- Tests: 10k+ random property tests vs Python ints, TriText round-trip (Hungarian, escapes,
  lenient decode), checksum, isa.yaml validation. `python tools/mk.py test` green.
- Build driver `tools/mk.py` (D-025: no make on host) + delegating `Makefile`.

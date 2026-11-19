# CHANGELOG — Setun Tri OS

All notable changes per milestone. Format: `M<n>: summary` (see GLM_MASTER_PROMPT rule 7).

## M2 — 2026-11-19 — Devices, boot ROM, debugger
- `tools/tvm/devices.py`: UART (TX/RX/STAT, TriText output stream with escape
  decoding), BlockDevice (file-backed, 729-tryte blocks, read/write commands +
  completion IRQs), deterministic ternary LCG RNG, power/reset device, profiler
  register stubs (M9). MMIO map per D-011 with explicit offset routing.
- `tools/tvm/machine.py`: Machine — CPU + RAM + MMIO bus + devices + ROM loading;
  bare-metal trap fallback; clean power-off/exit codes; disk image load/save
  (5 trits/byte, host-side only).
- `tools/trild.py`: TXE linker (merged spans, symbols, entry; checksum D-014).
- `tools/trimkfs.py`: raw boot image builder (block 0 = boot sector, 1.. = TXE).
- `boot/rom.asm`: ROM loads disk block 0 to RAM 6561 and jumps to it.
- `boot/boot.asm`: boot sector reads kernel TXE (blocks 1..27) into the buffer,
  parses magic/version/entry/segments tryte-wise (unaligned-safe), copies
  segments, jumps to entry.
- `kernel/kernel.asm`: M2 stub kernel — UART greeting, clean power-off.
- `lib/trilib.asm`: shared macros (const via LUI+ADDI with balanced rounding,
  push/pop/call/ret).
- `tools/tridbg.py`: debugger — step/run/breakpoints/regs/mem/dis/trace/out.
- `python tools/mk.py assemble|image|run` boots the TVM end to end:
  "Hello, ternary world!" on UART, exit 0.
- Tests: 84 green — packing round-trips, TXE checksum corruption detection,
  UART in/out, block device MMIO round-trip + error case, RNG determinism,
  power device, full boot path, boot failure prints 'E' on bad magic,
  debugger step/break/trace.

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

# 06 Toolchain and repository layout

```
setun-tri-os/
  spec/isa.yaml            # single source of truth
  tools/
    trit.py                # trit/tryte/word arithmetic library (+ property tests)
    triasm.py              # assembler (labels, macros, .tryte/.word/.text directives)
    trild.py               # linker -> TXE
    tridis.py              # disassembler
    trimkfs.py             # create/inspect TriFS images (5 trits/byte packing)
    tvm/                   # reference emulator (Python)
    tvm_rs/                # optional fast emulator (Rust), must pass same tests
    tridbg.py              # debugger: step, break, regs, mem, trace
    tern/                  # optional small systems language compiler (M10)
  boot/ kernel/ servers/ user/ lib/
  tests/                   # unit, property, emulator, kernel, system
  docs/  Makefile  CHANGELOG.md
```
TVM devices (MMIO): UART console, timer, block device (file-backed), RNG, power/halt, and a **profiler device**.
Profiler (host-side, no guest cost): per-instruction trit-activity (how many trits change), memory access distance
histogram (address delta between consecutive accesses, in trytes and in lattice-hops under a configurable
hexagonal mapping), read/write ratio, working-set size per 1M cycles. Output CSV + a summary report.
`make test`, `make run`, `make profile WORKLOAD=<name>`.

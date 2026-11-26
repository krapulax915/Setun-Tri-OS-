# HW_PORT.md — Setun Tri OS v0.1 Hardware Port Notes

This document lists everything a real ternary chip (or an FPGA/ASIC implementation)
must provide for Setun Tri OS v0.1 to run. It is the M10 deliverable and is
intended for hardware engineers porting the OS off the TVM emulator.

---

## 1. CPU core (TriISA v0.1)

- **Word width**: 18 balanced ternary trits (±193,710,244).
- **Tryte**: 6 trits (729 values), 3 trits per word slot.
- **Register file**: 9 registers R0..R8; R0 hardwired to 0.
- **PC**: 18 trits, word-aligned (PC % 3 == 0 required).
- **Arithmetic**: wrap-around on overflow, no flags register (three-way compare).
- **Opcodes**: 49 (see `spec/isa.yaml`); formats `[op:4|rd:2|rs:2|imm:10]`
  (18 trits). Shift immediate restricted to |k| > 4 (D-026).
- **Trap entry**: `_trap(cause, tval, epc)` saves mode/irq to PSW shadow, sets
  mode=kernel, irq=-1, PC=TVEC. Return via RETI restores mode/irq from shadow.
- **RETI**: PC = EPC; mode/irq from PSW shadow (D-033).
- **WFI**: sleep until IRQ pending or timer due.
- **XCHG/CAS atomics**: required for scheduler wakeup flags.

## 2. MMU

- **Page size**: 729 trytes (3^6), 12-trit frame number.
- **Address space**: 18 trits virtual = `[L1:4][L2:4][L3:4][offset:6]`.
- **Page tables**: 3 levels, 81 entries per table, each entry 1 word (243 trytes).
- **PTE format**: `[frame:12][R/W:1][X:1][owner-mode:1][accessed:1][dirty:1][present:1]`.
- **TLB**: 27-entry fully associative; FENCE flushes. Expose hit/miss counters.
- **Kernel window**: identity-mapped negative half (D-028).
- **Access checks**: R/W/X and owner-mode enforced on every load/store/fetch.

## 3. MMIO map (D-011, 3-tryte slots)

| Device | Offset | Registers |
|--------|--------|-----------|
| UART   | 0      | TX (0), RX (3), STAT (6) |
| Block  | 12     | LBA (12), BUF (15), CMD (18), STAT (21) |
| Power  | 27     | POWER (27) — write 1 = power off, -1 = reset |
| RNG    | 24     | VAL (24) |
| Profiler | 30   | CTRL (30), ACK (33) |

- **IRQ lines**: `IRQ_BASE + device_id` (UART=10, block=12, RNG=13, profiler=14).
- **Timer**: separate CSR (TIMER_CMP, TIME, CYCLE) — level-triggered at TIME >= CMP.

## 4. Trap vector

- **TVEC CSR (2)**: entry point for all traps/IRQs.
- **Cause codes**: SYSCALL=0, TIMER=1, IRQ_BASE=10, ILLEGAL=-1, ALIGN=-6,
  DIV0=-7, PAGEFAULT (R/W/X), PRIVILEGE.
- **EPC (3)**: saved PC on trap entry; RETI resumes at EPC.
- **CAUSE (4)**, **TVAL (5)**: trap cause and faulting address.

## 5. Memory layout

- Physical RAM: 3^12 = 531441 frames (page-granular).
- Reserved frames [0, 1416): static kernel data (TCBs, queues, idle stack,
  capability tables, endpoint table, fs block buffer).
- Free frames [1416, 6446) and [6449, 6561) for buddy allocator.
- Stack pages: 6446..6448 (3 frames, kernel stacks).
- Block device: file-backed, 729 trytes/block, up to 64 blocks (default).

## 6. Timing

- **Timer**: monotonic counter (TIME CSR), quantum = QUANTUM trytes.
- **Quantum**: 1000 cycles (configurable, see QUANTUM equ in kernel.asm).
- **Preemption**: timer fires at TIME >= TIMER_CMP; handler re-arms.
- **WFI wake**: pending IRQ or timer due.

## 7. Device semantics

- **UART TX**: write tryte -> emit TriText char (escape decode).
- **UART RX**: read tryte -> next input char (0 if none).
- **UART STAT**: 1 if input pending, 0 otherwise.
- **Block read**: set LBA, BUF, CMD=1 -> read block into RAM[BUF..BUF+728],
  raise IRQ_BLK, STAT=IDLE.
- **Block write**: set LBA, BUF, CMD=2 -> write RAM[BUF..BUF+728] to block,
  raise IRQ_BLK, STAT=IDLE (STAT_ERR if LBA out of range).
- **Power**: write 1 -> halt machine, exit code 0; write -1 -> reset.
- **RNG**: read -> next LCG value; write -> seed.
- **Profiler**: write 1=start, 0=stop, 2=snapshot; no counters in v0.1.

## 8. Boot sequence

1. ROM at fixed address 0 loads disk block 0 to RAM 6561, jumps to it.
2. Boot sector reads kernel TXE (blocks 1..27) into buffer, parses magic/version/
   entry/segments, copies segments, jumps to entry.
3. Kernel sets up TVEC, page tables (identity-mapped kernel window), buddy
   allocator, scheduler, starts init thread.
4. Init creates console server + shell; hands off to shell on console input.

## 9. Required toolchain

- **Assembler**: triasm (two-pass, macros, .include, balanced-ternary expressions).
- **Linker**: trild (TXE container with checksum).
- **Image builder**: trimkfs (boot sector + TXE in 729-tryte blocks).
- **Pack codec**: 5 trits/byte (D-015), host-side only.

## 10. What is NOT required for v0.1

- Floating-point unit (no FP in TriISA).
- Cache coherence (single core).
- DMA (block device is CPU-driven).
- Interrupt priority (deterministic min-cause delivery).
- Hardware compression (rle3/huff3 are host-side software).

---

*Generated as part of M10 (optional). The Tern language compiler is not included
in this port; see `tools/triasm.py` for the assembler interface.*
EOF
echo done
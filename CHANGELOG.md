# CHANGELOG — Setun Tri OS

All notable changes per milestone. Format: `M<n>: summary` (see GLM_MASTER_PROMPT rule 7).

## M6 — 2026-11-22 — Interactive shell over the console server (D-041)
- `kernel/kernel.asm`: GETCHAR syscall (num 18): reads one TriText tryte from the
  UART, yield-polls via sched_requeue_cur when the input is empty, so the shell
  stays scheduler-fair. `shell_main` thread: prints a prompt, reads a line into a
  tryte buffer (LBUF/LLEN at EPT+162, inside the reserved frames), NUL-terminates
  it, and dispatches the builtins help | ver | echo <text> | crash | halt.
  `echo` routes the text through the console server char-by-char via SEND (the
  IPC demo); `crash` NBSENDs the panic request and restarts the server on the
  same endpoint; `halt` powers off.
- init (m4_main) hands the system to the shell only when console input is
  waiting at ready-time (UART_STAT probe); headless boots keep the
  banner-...-ready-power-off flow, so every existing test stays deterministic.
- D-041: a completed SEND/RECV/CALL/REPLY overwrites R1 (status) and R2 (err) in
  the returned frame — loop state must live in memory or be reloaded per call
  (the shell re-reads the console cap before every SEND).
- `tests/test_m6.py`: 5 tests — headless boot has no shell, prompt + help/ver,
  echo via console IPC, unknown command, crash-restart-then-echo.
- Tests: 112 green.

## M5+M6 — 2026-11-22 — IPC handoff fixed; capabilities, ping-pong, fuzz, console all green
- `kernel/kernel.asm`: the parked M5/M6 handoff bug is closed — root cause was an R7
  (link-register) clobber in `ep_dequeue` (`call tcb_addr` overwrote the LR that the
  closing `JR R7` needed, so the function returned into its own middle); fixed with
  push/pop R7 on all paths (D-040). Phase-6 loop register reuse (request vs cap) and
  the phase-7 fuzz pointer clobber fixed; the console-down probe now uses NBSEND.
- Phase 6 unparked: SEND/RECV ping-pong, 200 round-trips ("ipc: 200 calls / <ticks>").
- Phase 7 unparked: syscall-argument fuzz survives with zero kernel exceptions printed
  (bad tids/caps/ops all return errors cleanly).
- M6 console phase unparked: console server echoes 'A'/'B', exits on the panic request
  (-1), NBSEND afterwards fails, init restarts it on the same endpoint and gets 'R'.
- `tools/tvm/cpu.py`: optional trace_hook on trap entry and RETI (debug/audit facility).
- `BUG_M5_NOTES.md`: root cause + single-step proof recorded; bug closed.
- Tests: 107 green (test_m5.py adds 5: caps, ping-pong, fuzz purity, console
  echo/panic/restart, clean power-off). DECISIONS: D-040.

## M5 — 2026-11-22 — IPC + capabilities (partial; ping-pong WIP)
- `kernel/kernel.asm`: kernel-global CTAB (81 caps, 9 rights x 2-trit groups) + EPT
  (9 endpoints with receiver/sender wait queues and a CALLER slot); syscalls EP_CREATE,
  SEND, RECV, CALL, REPLY, NBSEND, CAP_DERIVE, CAP_COPY, CAP_REVOKE, CAP_DELETE with
  frame-based argument passing (D-037..D-039).
- Capability self-test green: derive chain, sticky deny (SEND=-1 survives a request of
  +1), subtree revoke (grandchild delete fails), copy.
- WIP: SEND/RECV ping-pong deadlocks (see BUG_M5_NOTES.md — a RETI restores a stale EPC
  when the timer fires inside the handoff window); phases 6-7 parked, everything else
  green. 102 tests.

## M4 — 2026-11-21 — Threads + scheduler (Triad kernel, D-033..D-036)
- `tools/tvm/cpu.py`: PSW shadow (D-033) — trap entry snapshots mode/irq, RETI restores
  them, CSRW PSW updates the snapshot; the handler→RETI resume path is now zero-window.
- `kernel/kernel.asm`: the Triad scheduler — three priority classes with per-class FIFO
  queues and timer quantum (D-033); per-thread kernel stacks from the buddy allocator;
  TCB table, save-early/restore-only context switch with a zombie guard (D-034); M4
  syscall set with frame-based argument passing (D-035): YIELD, EXIT, THREAD_CREATE,
  THREAD_CONTROL (block/wake/set-class), TIME, DEBUG_PUTC, GETTID; pending-wake flag so
  wake-before-block is never lost (D-036); idle thread parks in WFI.
- Boot self-test: 3 threads print x/y/z interleaved under round-robin + timer preemption;
  pending-wake consumed without blocking and a real block/wake round-trip; a realtime
  spinner starves a background worker until it finishes, then the kernel demotes itself
  and lets it run; 3x200 yield-stress with per-worker counters.
- `tests/test_m4.py`: full-boot acceptance, interleave pattern, starvation ordering,
  no-lost-wakeup markers.
- Tests: 102 green (4 new). DECISIONS: D-033..D-036.

## M3 — 2026-11-20 — MMU, trap vector, buddy allocator, Triad kernel boot
- `tools/tvm/mmu.py`: three-level ternary page tables (81 entries per frame,
  balanced indexing, D-029), 27-entry TLB with accessed/dirty updates on hits,
  kernel direct window (D-028), R/W/X/owner checks. `Machine` wires CPU↔MMU.
- `tools/tvm/cpu.py`: integer-dispatch hot path (~24× faster execution);
  an unhandled (bare) trap now halts the machine instead of looping.
- `kernel/kernel.asm`: the Triad kernel — boot banner, trap vector arming,
  trap handler (cause/tval/epc diagnostics, resume at EPC+3, D-031), ternary
  buddy allocator (D-030..D-030e: 3-way BFS node tree, hint-based first-fit
  scan, ancestor-allocated check, bottom-up merge on free), boot self-test
  (240 alloc / free / realloc), ILLEGAL + DIV0 survival demo, clean power-off.
- `lib/trilib.asm`: `const` macro parenthesization fix for compound expressions.
- `tests/golden_buddy.py` + `tests/test_m3.py`: an independent Python model of
  the allocator diffed against the TriASM implementation (600-step random
  workload), 10 MMU tests (R/W/X/user/kernel, TLB eviction, accessed/dirty),
  3 direct buddy tests, and the full-boot acceptance (banner, buddy ok,
  illegal-resume ok, div0-resume ok, ready, exit 0, powered off).
- Tests: 98 green. DECISIONS: D-028..D-032.

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

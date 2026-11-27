# 07 Milestones, TODO, acceptance tests

- [x] **M0 Spec & trit library.** isa.yaml frozen, DECISIONS.md, `trit.py` (conversions int<->balanced ternary, add/sub/mul/div/mod,
      tritwise ops, shifts). *Accept:* 10k random property tests vs Python ints; TriText round-trip incl. Hungarian chars.
- [x] **M1 Assembler + CPU core.** triasm, tvm core (no MMU). *Accept:* programs fib(20), sieve to 200, three-way-branch demo,
      division/modulo edge cases, every opcode has a test; disassembler round-trips the assembler output.
- [x] **M2 Devices, boot ROM, debugger.** UART, timer, block device, packing 5 trits/byte. *Accept:* "Hello, ternary world" via UART;
      boot sector loads a TXE image from disk; tridbg can step/break.
- [x] **M3 MMU + traps + kernel boot.** Page tables, TLB, trap vector, kernel entry. *Accept:* page-fault tests (R/W/X/user/kernel),
      kernel prints banner, handles ILLEGAL/DIV0 without dying, physical buddy allocator tests.
- [x] **M4 Threads + scheduler.** Context switch, timer preemption, three priority classes. *Accept:* 3 threads print interleaved;
      realtime starves background as designed; no lost wakeups under 1M-cycle stress.
- [x] **M5 IPC + capabilities.** Endpoints, CALL/REPLY, cap derive/revoke with sticky deny. *Accept:* ping-pong benchmark, revoke subtree test,
      deny-override test, fuzz test of syscall arguments (kernel never panics). — all green: 200-call SEND/RECV ping-pong, sticky-deny
      self-test, subtree revoke, fuzz with zero kernel exceptions; the original handoff deadlock was the ep_dequeue LR (R7) clobber (D-040).
- [x] **M6 Userspace: init, console, shell.** *Accept:* shell prompt, builtins, crash of `console` server is restarted by `init`. — GETCHAR
      syscall, shell builtins (help/ver/echo/crash/halt), NBSEND panic + supervisor restart; test_m6.py 5 tests.
- [x] **M7 TriFS + fs server.** mkfs, COW tree, extents, snapshots (COW generation counter; any prior root stays readable). *Accept:* create/read/write/delete 1000 files, power-cut simulation
      (kill TVM at random cycle) leaves a consistent image, checksums detect injected corruption. — test_m7.py: all three verified.
- [x] **M8 Loader + coreutils.** TXE loader, `ls cat echo ed ps kill tstat mkdir rm cp`, pipes. *Accept:* scripted shell session test. — test_m8.py scripted session (15 commands).
- [x] **M9 Profiler + compression.** Profiler device + report; `rle3`, `huff3`. *Accept:* `make profile` on 5 workloads (compile, fs-heavy,
      IPC-heavy, matrix multiply, text processing) produces locality report; compression ratio report on TriText and binary-like data. —
      `python tools/mk.py profile WORKLOAD=w_ipc` (5 workloads), TLB micro-benchmark (sequential/hot/stride), rle3/huff3 ratio report.
- [x] **M10 (optional) Tern language & HW port notes.** Small C-like compiler to TriASM (`tools/tern.py`); demo server program compiled
      from Tern (`user/hello_tern.tn`); `docs/HW_PORT.md` written (MMIO map, trap semantics, timing assumptions).

## Global test policy
Unit + property tests for all libs; golden-trace tests for the emulator; kernel tests run inside TVM; CI target `make test` < 5 minutes.

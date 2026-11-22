# M5 handoff bug — RESOLVED

The months-long "ep_dequeue R1-leak under preemption" mystery is closed. The
root cause was NOT a nested-trap/RETI race — it was a **link-register (R7)
clobber in `ep_dequeue`**, proven by single-stepping the live machine.

## Root cause (measured, step-by-step log)

`call` expands to `JAL`, which sets R7 = return address. `ep_dequeue` called
`tcb_addr` (JAL → R7 = address *inside* ep_dequeue) and returned with
`ret` = `JR R7` — which jumped back **into its own middle** (the instruction
after its internal call) instead of into its caller.

The re-entry then re-executed the tail of ep_dequeue with R8 = the trap-frame
base instead of the frame's push area, so the closing `pop R2/pop R1` loaded
the frame's saved-SP and R7 slots — R1 became the interrupted thread's R7
value (e.g. a TIME result, 1427923) and `STW R1, R3` (head = next) tried to
write to address 1427923 → ALIGN fault at epc=8304 in *kernel* mode, with
R1 = syscall numbers / message values ("the R1-leak"). Repeated faults left
TCB1.T_EPC = 8304 (the old "nested-trap-during-frame-build signature" — that
interpretation was wrong; the write was the ordinary save-early of the fault
itself). `th_exc`'s resume-at-EPC+3 then kept the machine limping in a fault
loop, so boot never completed.

## The fix

- `ep_dequeue`: `push R7` at entry, single `pop R7` on all exit paths
  (D-040). Every function that executes `call` and returns via `ret` must
  preserve the LR; an audit of kernel.asm found no other offender
  (`wait_push` already saved R7, `sched_bootstrap` keeps the LR in R6).
- phase 6 loop: `const R3, XC2` destroyed the request value in R3 (msg1 was
  sent as the XC2 address) and the RECV cap register (R6) was never loaded —
  both reordered.
- phase 7 fuzz loop: the FTAB pointer lived in R2, but R2 also receives
  arg1 — the loop loaded arg2/arg3 from the arg *values* as addresses,
  triggering real kernel faults. The pointer now lives in R6.
- console-down probe uses NBSEND (a blocking SEND would park init on the
  empty sender queue forever once the console server has exited).

## Result

`caps: ok` → `ipc: 200 calls / <ticks>` → `fuzz: ok` (no kernel exception in
the fuzz window) → console echo/panic/restart demo → clean power-off.
tests/test_m5.py covers all of it (5 tests).

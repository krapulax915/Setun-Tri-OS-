# M5 remaining bug — server thread receives garbage arg (132094791)

## Evidence
- Phase 6: THREAD_CREATE(wr_server, class=0, arg=master_cap) succeeds.
- Server's first RECV trap: frame+18 (interrupted R2) = 132094791 (garbage).
  The server's R2 = R6 = R1(arg from synthetic frame R1 slot).
- => the synthetic frame's R1 slot does not contain the create argument.
- wr_server: ADD R6,R1,R0; RECV(cap=R2=R6) -> cap_check fails -> ipc_err1
  -> server REPLYs(err) -> loops RECV/REPLY forever, rq stays empty.
- Client CALL#1: ep_dequeue finds empty rq -> wait_push(main) -> main blocks
  forever. Deadlock after caps:ok.

## Suspect
sys_create_body frame build (push-free rewrite region): the arg copy
`LEA R1, R4, -3; LDW R1, R1; push R1` — R4 = old SP. Note the validation
added earlier consumes R3 between push R3(arg) and the arg reload, and the
arg reload uses R4-3. Check whether R4 still holds the pre-push SP at the
frame-build point (it is set once at entry, before push R3/push R7).

## Fix direction
After validation, reload arg from R4-3 (push R3 slot) — or simplest: keep
arg in a callee-saved slot instead of the caller stack, e.g. reuse T_PEND
of the new TCB (written before enqueue, read during frame build).

## Update (fresh measurement)
- Caller passes arg correctly: phase-6 stores master cap (=0) into XC2, create
  arg = 0. So the synthetic frame R1 slot SHOULD be 0 (slot 0 = master cap).
- Server's first RECV trap reads interrupted R2 = 132094791 (garbage) — so the
  server's R2 register was already garbage at its first TRAP, i.e. the restore
  delivered a bad R2, or the frame's R2 slot holds garbage.
- Frame layout on server stack (T_SP=1207200): arg pushed at top-3=1207221,
  six zero pushes 1207218..1207203, saved_sp at 1207200. Restore pops R7..R1
  from T_SP+3..T_SP+21 = 1207203..1207221. R2 slot = T_SP+18 = 1207218 = zero
  push. Measured R2 = 132094791 != 0 => either the zero-pushes didn't land
  (stack base mismatch) or something overwrote 1207218 afterwards.
- 132094791 also appeared in the M3 debug as a garbage node id: it may be the
  content of freshly buddy_alloc'd stack memory (uninitialized) — i.e. the
  arg/zero pushes landed at a DIFFERENT address than the frame the restore
  reads. Prime suspect: stack_top computed as base+729 vs T_SP written as
  frame top; check ADD R8,R2,R0 ordering: R2=base+729=top, R8=top; pushes
  from top-3 down to top-24; T_SP=frame top=top-24; restore reads T_SP+3..21
  = top-21..top-3 = the arg+zero region. Addresses check out arithmetically.
  => next: single-step the FIRST create-body frame build and dump the new
  stack region after the build, before the enqueue.

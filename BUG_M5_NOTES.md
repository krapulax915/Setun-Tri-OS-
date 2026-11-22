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

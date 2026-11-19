# 04 Kernel (microkernel "Triad")

Kernel objects: Thread, AddressSpace, Endpoint, Notification(IRQ), Frame, CapSpace. Everything is accessed through **capabilities**.

## Capabilities with tri-state rights
A capability = (object ref, rights vector, badge). Each right is a trit:
`+` held, `0` not held, `-` **explicitly denied** — a deny can never be overridden by deriving/granting from a parent
(negative capabilities). Derivation rule: child right = min(parent right, requested right) where order is `- < 0 < +`,
and `-` is sticky. Revoke removes a whole derivation subtree.
Rights: READ, WRITE, EXEC, GRANT, MAP, SEND, RECV, CALL, CONTROL.

## Threads
State is a trit: `-` blocked, `0` ready, `+` running. Priority class trit: `+` realtime, `0` normal, `-` background;
each class has 9 levels (R0..R8 style), round-robin inside a level, time slice via TIMER. Idle thread runs WFI.
Priority inheritance across IPC (CALL donates priority to server).

## IPC
Synchronous rendezvous message passing on endpoints. Message = up to 6 trytes in registers R1..R4 + optional
capability transfer. `CALL` = SEND+RECV atomically; `REPLY`; `RECV`; `NBSEND`. Notifications for IRQs (bit-word of 18 trits).
Fast path: if receiver waiting, switch directly without scheduler.

## Syscalls (TRAP imm; number in R1, args R2..R4, result R1, error code R2)
YIELD, EXIT, THREAD_CREATE, THREAD_CONTROL, SEND, RECV, CALL, REPLY, NBSEND, CAP_COPY, CAP_DERIVE, CAP_REVOKE,
CAP_DELETE, ASPACE_CREATE, MAP, UNMAP, FRAME_ALLOC, IRQ_BIND, TIME, DEBUG_PUTC.
Errors are balanced: `-` failure class, `0` OK, `+` OK-with-extra-info; detailed code in R2.

## Kernel invariants (assert in debug build)
1. No kernel pointer ever escapes to user space. 2. Every user pointer is translated and range-checked.
3. Capability table slots are generation-counted. 4. Kernel stack per thread, 243 trytes minimum.

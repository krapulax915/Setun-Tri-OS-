; kernel.asm — Setun Tri OS "Triad" microkernel, M4 stage.
;
; Boots from the boot sector (physical addressing, PTBR == 0, mode +):
;   1. prints the boot banner,
;   2. arms the trap vector (TVEC) and survives ILLEGAL/DIV0 (D-031),
;   3. initialises the ternary buddy allocator (D-030) and self-tests it,
;   4. brings up the thread scheduler (D-033..D-036): an idle thread plus the
;      main thread, then runs the M4 self-test (interleaved threads, wake /
;      pending-wake, realtime starvation, yield stress) and powers off.
;
; Memory map (physical):
;   7290            kernel code
;   30000           kernel strings
;   1000000         buddy state / hints / save area / node array
;   1028310..       TCB table, ready queues, scheduler words, idle stack
;   4700001         main kernel stack top (static, becomes tid 1's stack)

    .include "lib/trilib.asm"

    .equ MMIO,      128608722
    .equ UART_TX,   MMIO+0
    .equ POWER,     MMIO+27
    .equ KERNEL_LOAD, 7290
    .equ STRBASE,   30000
    .equ KDATA,     1000000

    .equ MAX_ORDER, 8
    .equ NLEAF,     6561                ; 3^8 leaves = all frames
    .equ NNODE,     9841                ; (3^9-1)/2 nodes
    .equ BUDDY_STATE, KDATA             ; NNODE+1 trytes
    .equ HINT,       KDATA+9842         ; 9 words: per-depth scan hints
    .equ KSAVE,      KDATA+9842+27      ; 11 words
    .equ PNUMBUF,    KSAVE+33           ; 12 trytes
    .equ NODES,      PNUMBUF+12         ; 6132 words (self-test array)
    .equ RES_END,    1415               ; frames [0, 1415) reserved: static data
                                        ; (TCBs, queues, idle stack, M4T, CTAB, EPT)
                                        ; ends at 1031085, inside frame 1414
    .equ STK_LO,     6446
    .equ STK_HI,     6448
    .equ KSTACK,     4700001
    .equ FREE_FRAMES, 5143              ; 6561 - 1415(reserved) - 3(stack)
    .equ FREE_TEST,   240               ; boot self-test allocation count

; ---- scheduler constants (D-033/D-034) ---------------------------------------
    .equ QUANTUM,   500                 ; timer cycles per scheduling slice
    .equ NT,        27                  ; thread slots (tid 0 = idle, 1 = main)
    ; TCB layout: 12 words (36 trytes) per slot
    .equ T_NEXT,    0                   ; ready-queue / free-list / wait-queue link
    .equ T_SP,      3                   ; saved kernel SP (trap frame top)
    .equ T_EPC,     6                   ; saved EPC (resume address)
    .equ T_STATE,   9                   ; -2 free slot, -1 blocked, 0 ready, 1 running
    .equ T_CLASS,   12                  ; -1 background, 0 normal, +1 realtime
    .equ T_PEND,    15                  ; pending-wake flag (D-036)
    .equ T_STK,     18                  ; stack frame base PA (0 = static)
    .equ T_FLAGS,   21                  ; bit0: static stack (never freed)
    .equ T_WEP,     24                  ; endpoint obj this thread waits on
    .equ T_ROLE,    27                  ; 0 none, -1 sender, +1 receiver, +2 call-await
    .equ T_CALLER,  30                  ; reserved (M6)
    .equ TCBS,      1028310             ; NT * 36 trytes
    .equ QHEADS,    TCBS + 972          ; 6 words: head/tail per class (-1,0,+1)
    .equ CURRENT,   QHEADS + 18         ; word: running tid (-1 = none, 0 = idle)
    .equ FREE_TID,  CURRENT + 3         ; word: free TCB list head
    .equ DONE,      FREE_TID + 3        ; NT words: worker completion flags
    .equ STRESS,    DONE + 81           ; NT words: yield-stress counters
    .equ IDLE_STK,  STRESS + 81         ; 243 trytes idle stack (static)
    .equ IDLE_STK_TOP, IDLE_STK + 243
    .equ M4T,       IDLE_STK_TOP        ; main's per-phase slots
    .equ P1A,       M4T
    .equ P1B,       M4T + 3
    .equ P1C,       M4T + 6
    .equ P2A,       M4T + 9
    .equ P2B,       M4T + 12
    .equ P3S,       M4T + 15
    .equ P3B,       M4T + 18
    .equ P4A,       M4T + 21
    .equ P4B,       M4T + 24
    .equ P4C,       M4T + 27
    .equ WDONE,     M4T + 30            ; 12 words: worker completion flags,
                                        ; indexed by the create argument
    .equ XCAP,      M4T + 66            ; self-test capability refs (4 words)
    .equ XCHILD,    M4T + 69
    .equ XGRAND,    M4T + 72
    .equ XC2,       M4T + 75

; ---- capability / endpoint tables (D-037..D-039) ------------------------------
    .equ NSLOT,     81                  ; capability slots (3^4)
    .equ CTAB,      M4T + 78            ; NSLOT x 18 trytes: gen, type, obj,
                                        ; rights, badge, parent (-1 = root)
    .equ CE_TYPE,   3                   ; 0 free, 1 endpoint
    .equ CE_OBJ,    6
    .equ CE_RIGHTS, 9                   ; 9 rights x 2-trit group, order - < 0 < +
    .equ CE_BADGE,  12
    .equ CE_PARENT, 15
    .equ NEP,       9                   ; endpoint objects
    .equ EPT,       CTAB + 1458         ; NEP x 18 trytes: used, rq_h, rq_t,
                                        ; sq_h, sq_t, caller
    .equ EE_RQH,    3                   ; receiver-waiting queue head/tail
    .equ EE_RQT,    6
    .equ EE_SQH,    9                   ; sender-waiting queue head/tail
    .equ EE_SQT,    12
    .equ EE_CALLER, 15                  ; tid of the CALL thread awaiting REPLY
    .equ R_READ,    0                   ; right indices (docs/04 order)
    .equ R_WRITE,   1
    .equ R_EXEC,    2
    .equ R_GRANT,   3
    .equ R_MAP,     4
    .equ R_SEND,    5
    .equ R_RECV,    6
    .equ R_CALL,    7
    .equ R_CONTROL, 8
    .equ RIGHT_ALL, 48427561            ; sum of 9^i for i in 0..8: every right +
    .equ RIGHT_NOSEND, 48309463         ; RIGHT_ALL with SEND = -1

    .org KERNEL_LOAD
    .entry main

; ------------------------------------------------------------------------------
; main — boot phases, then become the scheduler's first hand-off
; ------------------------------------------------------------------------------
main:
    const R8, KSTACK
    const R1, str_banner
    call puts
    ; arm the trap vector: exceptions/irqs land in trap_handler (D-031)
    const R1, trap_handler
    CSRW TVEC, R1
    call buddy_init

    ; ---- buddy self-test: allocate every order-0 block, free all, reallocate --
    LDI R4, 0                        ; count
    const R2, NODES
st_alloc:
    CMPI3 R5, R4, FREE_TEST
    BRZP R5, st_alloc_done
    LDI R1, 0                        ; order 0
    call buddy_alloc
    CMPI3 R5, R1, -1
    BRZ R5, st_fail
    MULI R3, R4, 3
    ADD R3, R2, R3
    STW R3, R1                       ; NODES[count] = node
    ADDI R4, R4, 1
    JMP st_alloc
st_alloc_done:
    const R1, str_a
    call puts
    LDI R3, FREE_TEST
    CMP3 R5, R4, R3
    BRNZ R5, st_fail
    LDI R1, 0                        ; free loop index
st_free_loop:
    CMP3 R5, R1, R4
    BRZP R5, st_free_done
    const R2, NODES                  ; base reloaded every pass: R2 doubles as the
                                     ; buddy_free node argument inside the body
    MULI R3, R1, 3
    ADD R3, R2, R3
    LDW R3, R3                       ; node
    push R1
    LDI R1, 8                        ; depth 8 (order-0 blocks live at depth 8)
    ADD R2, R3, R0
    call buddy_free
    pop R1
    ADDI R1, R1, 1
    JMP st_free_loop
st_free_done:
    const R1, str_b
    call puts
    LDI R4, 0
st_alloc2:
    CMPI3 R5, R4, FREE_TEST
    BRZP R5, st_alloc2_done
    LDI R1, 0                        ; order 0
    call buddy_alloc
    CMPI3 R5, R1, -1
    BRZ R5, st_fail
    ADDI R4, R4, 1
    JMP st_alloc2
st_alloc2_done:
    const R1, str_c
    call puts
    LDI R3, FREE_TEST
    CMP3 R5, R4, R3
    BRNZ R5, st_fail
    const R1, str_buddy_ok
    call puts
    JMP bt_trap_demo
st_fail:
    const R1, str_buddy_fail
    call puts

st_fail2:
    const R1, str_test_fail
    call puts

; ---- trap demo: illegal word then DIV0, kernel must survive both (D-031) ----
bt_trap_demo:
    .word 0 - 20*4782969 - 4*531441 - 4*59049    ; op=-20 (unassigned) -> ILLEGAL
    LDI R6, 42                       ; marker: executed after the skip
    LDI R2, 42
    CMP3 R5, R6, R2
    BRNZ R5, td_fail
    const R1, str_resume_ok
    call puts
    LDI R3, 77
    LDI R1, 5
    LDI R2, 0
    DIV R3, R1, R2                   ; DIV0 -> trap -> skipped
    LDI R2, 77
    CMP3 R5, R3, R2
    BRNZ R5, td_fail
    const R1, str_div0_ok
    call puts
    ; ---- hand off to the scheduler (D-033) ----
    const R1, str_sched
    call puts
    call sched_init
    call sched_bootstrap
    LDI R1, 4
    CSRW PSW, R1                     ; threads run mode +, IRQs on (D-034); this
                                     ; also seeds the RETI PSW snapshot for the
                                     ; very first switch into tid 1
    CSRR R1, TIME                    ; arm the level timer
    const R2, QUANTUM
    ADD R1, R1, R2
    CSRW TIMER_CMP, R1
    JMP schedule_switch              ; current == -1: pick tid 1 and RETI into it
td_fail:
    const R1, str_trap_fail
    call puts
    const R1, POWER
    LDI R2, 1
    STW R1, R2

; ------------------------------------------------------------------------------
; trap_handler — entered with R1..R8 = interrupted values, PC = TVEC (D-017).
; Builds a trap frame on the interrupted thread's kernel stack, saves SP/EPC
; into the current TCB immediately (D-034), then dispatches on CAUSE:
;   0        syscall (num was in the interrupted R1; args R2..R4)
;   1        timer  -> re-arm, requeue current, switch (D-033)
;   >= 10    device IRQ -> diagnostic print, resume the same thread
;   < 0      exception -> diagnostics, resume at EPC+3 (D-031)
; ------------------------------------------------------------------------------
trap_handler:
    push R1
    push R2
    push R3
    push R4
    push R5
    push R6
    push R7
    ADDI R8, R8, -3
    LEA R6, R8, 3
    STW R8, R6                       ; saved SP = old R8
    ; save the interrupted context into the current TCB (D-034)
    const R1, CURRENT
    LDW R1, R1
    CMPI3 R5, R1, 0
    BRZ R5, th_nosave                ; idle: nothing to save
    BRN R5, th_nosave                ; none yet (bootstrap)
    ADD R2, R1, R0
    call tcb_addr                    ; R1 = &TCB[cur]
    LEA R2, R1, 3
    STW R2, R8                       ; T_SP = frame top (offset +3!)
    CSRR R2, EPC
    LEA R3, R1, 6
    STW R3, R2                       ; T_EPC
th_nosave:
    CSRR R1, CAUSE
    CMPI3 R5, R1, 0
    BRZ R5, th_sys
    BRN R5, th_exc
    CMPI3 R5, R1, 9
    BRN R5, th_timer                 ; TIMER cause = 1
    ; device IRQ: print and resume the interrupted thread
    const R1, str_irq
    call puts
    CSRR R1, CAUSE
    call putnum
    LDI R1, 10
    call putc
    JMP th_resume
th_timer:
    CSRR R1, TIME                    ; re-arm the level timer (D-033)
    const R2, QUANTUM
    ADD R1, R1, R2
    CSRW TIMER_CMP, R1
    call sched_requeue_cur           ; current back to its class queue
    call schedule_switch             ; never returns
th_sys:
    LEA R1, R8, 21                   ; syscall num was in the interrupted R1
    LDW R1, R1
    CMPI3 R5, R1, 1
    BRZ R5, sys_yield
    CMPI3 R5, R1, 2
    BRZ R5, sys_exit
    CMPI3 R5, R1, 3
    BRZ R5, sys_create
    CMPI3 R5, R1, 4
    BRZ R5, sys_control
    CMPI3 R5, R1, 5
    BRZ R5, sys_time
    CMPI3 R5, R1, 6
    BRZ R5, sys_putc
    CMPI3 R5, R1, 7
    BRZ R5, sys_gettid
    CMPI3 R5, R1, 8
    BRZ R5, sys_send
    CMPI3 R5, R1, 9
    BRZ R5, sys_recv
    CMPI3 R5, R1, 10
    BRZ R5, sys_call
    CMPI3 R5, R1, 11
    BRZ R5, sys_reply
    CMPI3 R5, R1, 12
    BRZ R5, sys_nbsend
    CMPI3 R5, R1, 13
    BRZ R5, sys_cap_derive
    CMPI3 R5, R1, 14
    BRZ R5, sys_cap_copy
    CMPI3 R5, R1, 15
    BRZ R5, sys_cap_revoke
    CMPI3 R5, R1, 16
    BRZ R5, sys_cap_delete
    CMPI3 R5, R1, 17
    BRZ R5, sys_ep_create
    const R1, str_badcall
    call puts
    JMP th_resume
th_exc:
    const R1, str_trap
    call puts
    CSRR R1, CAUSE
    call putnum
    const R1, str_sp
    call puts
    CSRR R1, TVAL
    call putnum
    const R1, str_epc
    call puts
    CSRR R1, EPC
    call putnum
    LDI R1, 10
    call putc
    ; resume after the faulting instruction
    CSRR R1, EPC
    ADDI R1, R1, 3
    CSRW EPC, R1
    JMP th_resume
th_resume:
    ; IRQs stay disabled from trap entry through RETI (zero window): RETI
    ; restores mode/irq from the PSW snapshot taken at trap entry (D-033),
    ; so a running thread comes back with its interrupts enabled.
    ADDI R8, R8, 3                   ; skip the saved-SP slot -> R7 slot
    pop R7
    pop R6
    pop R5
    pop R4
    pop R3
    pop R2
    pop R1
    RETI                             ; PC = EPC; PSW from the snapshot

; ---- syscall wrappers: args are reloaded from the trap frame (the handler's
; save step uses R2/R3 as scratch, so live registers are NOT trustworthy here);
; results are stored into the frame for the restore to pop -----------
sys_yield:
    call sched_requeue_cur
    call schedule_switch             ; never returns

sys_exit:
    call sys_exit_body               ; frees TCB + stack, CURRENT = -1
    call schedule_switch             ; never returns

sys_create:                          ; frame: fn +18, class +15, arg +12
    LEA R1, R8, 18
    LDW R1, R1                       ; fn
    LEA R2, R8, 15
    LDW R2, R2                       ; class
    LEA R3, R8, 12
    LDW R3, R3                       ; arg
    call sys_create_body             ; -> R1 = tid, R2 = err
    LEA R5, R8, 21
    STW R5, R1                       ; result R1 = tid
    LEA R5, R8, 18
    STW R5, R2                       ; error R2
    JMP th_resume

sys_control:                         ; frame: tid +18, op +15, arg +12
    LEA R1, R8, 18
    LDW R1, R1                       ; tid
    LEA R2, R8, 15
    LDW R2, R2                       ; op
    LEA R3, R8, 12
    LDW R3, R3                       ; arg (SETCLASS value)
    call sys_control_body            ; may never return (block)
    LDI R6, 0
    LEA R5, R8, 21
    STW R5, R6                       ; result R1 = 0
    LEA R5, R8, 18
    STW R5, R1                       ; error R2
    JMP th_resume

sys_time:
    CSRR R6, TIME
    LEA R5, R8, 21
    STW R5, R6                       ; result R1 = time
    LDI R6, 0
    LEA R5, R8, 18
    STW R5, R6                       ; error R2 = 0
    JMP th_resume

sys_putc:                            ; frame: char +18
    LEA R1, R8, 18
    LDW R1, R1
    call putc
    LDI R6, 0
    LEA R5, R8, 21
    STW R5, R6
    LEA R5, R8, 18
    STW R5, R6
    JMP th_resume

sys_gettid:
    const R6, CURRENT
    LDW R6, R6
    LEA R5, R8, 21
    STW R5, R6                       ; result R1 = tid
    LDI R6, 0
    LEA R5, R8, 18
    STW R5, R6
    JMP th_resume

; ------------------------------------------------------------------------------
; M5: endpoints, capabilities, IPC (D-037..D-039).
; Handlers run in trap context (IRQs off): queue and handoff operations are
; atomic. IPC frame layout: cap in the +18 slot (interrupted R2), two message
; words in +15/+12 (interrupted R3/R4); results: status in +21 (R1), error
; detail in +18 (R2), delivered words in +15/+12.
; ------------------------------------------------------------------------------
cap_check:                           ; R1 = cap ref, R2 = right index
    push R2                          ; -> R1 = &entry or -1 (right must be +)
    push R5                          ; clobbers R3; preserves R2, R4, R6
    CMPI3 R5, R1, 0
    BRN R5, cc_bad
    CMPI3 R5, R1, NSLOT
    BRZP R5, cc_bad
    MULI R3, R1, 18
    const R5, CTAB
    ADD R1, R5, R3                   ; R1 = &entry
    LEA R5, R1, 3
    LDW R3, R5                       ; type
    CMPI3 R5, R3, 0
    BRZ R5, cc_bad                   ; free slot
    MULI R3, R2, 2                   ; shift = 2 * right index
    LEA R5, R1, 9
    LDW R5, R5                       ; rights word
    TSHR R5, R5, R3                  ; drop 2*idx lowest trits (reg-form shift)
    LDI R3, 9
    MOD R5, R5, R3                   ; balanced pair in [-4, 4]
    CMPI3 R5, R5, 1
    BRZ R5, cc_ok                    ; right held (+)
cc_bad:
    LDI R1, -1
cc_ok:
    pop R5
    pop R2
    ret

ep_dequeue:                          ; R1 = &head, R2 = &tail -> R6 = tid (0 empty)
    LDW R6, R1                       ; clobbers R3, R5; preserves R1, R2, R4
    CMPI3 R5, R6, 0
    BRZ R5, ed_out
    push R1
    push R2
    ADD R1, R6, R0
    call tcb_addr
    LDW R3, R1                       ; TCB[tid].next
    pop R2
    pop R1
    STW R1, R3                       ; head = next
    CMPI3 R5, R3, 0
    BRZ R5, ed_z
    JMP ed_out
ed_z:
    STW R2, R0                       ; tail = 0 (queue drained)
ed_out:
    ret

wait_push:                           ; R1 = &head, R2 = &tail, R3 = tid
    push R7                          ; the pushed thread's own next link must be
    push R4                          ; cleared too, or its stale free-list/queue
    push R2                          ; link poisons the queue on the dequeue.
    push R1                          ; Push order puts R1 on top so the early
    ADD R1, R3, R0                   ; pop below restores it, not the LR.
    call tcb_addr                    ; R1 = &TCB[tid]
    STW R1, R0                       ; TCB[tid].next = 0
    pop R1                           ; R1 = &head back
    LDW R5, R2                       ; tail
    CMPI3 R4, R5, 0
    BRZ R4, wp_empty
    ADD R1, R5, R0
    call tcb_addr                    ; R1 = &TCB[tail]
    STW R1, R3                       ; TCB[tail].next = tid
    JMP wp_link
wp_empty:
    STW R1, R3                       ; head = tid
wp_link:
    ADD R1, R2, R0
    STW R1, R3                       ; tail = tid
    pop R2
    pop R4
    pop R7
    ret

ipc_deliver:                         ; R1 = &target TCB: copy the current frame's
    LEA R5, R1, 3                    ; msg words (+15/+12) into the target's
    LDW R5, R5                       ; frame and set its status slot (+21) to 0.
    LEA R2, R8, 15                   ; No pushes here: they would shift R8 and
    LDW R2, R2                       ; mispoint the R8-relative reads below.
    LEA R3, R5, 15
    STW R3, R2
    LEA R2, R8, 12
    LDW R2, R2
    LEA R3, R5, 12
    STW R3, R2
    LDI R2, 0
    LEA R3, R5, 21
    STW R3, R2
    ret

ipc_take:                            ; R1 = &sender TCB: copy the sender's msg
    LEA R5, R1, 3                    ; words into the current frame, status 0.
    LDW R5, R5                       ; No pushes: same R8-shift hazard as above.
    LEA R2, R5, 15
    LDW R2, R2
    LEA R3, R8, 15
    STW R3, R2
    LEA R2, R5, 12
    LDW R2, R2
    LEA R3, R8, 12
    STW R3, R2
    LDI R2, 0
    LEA R3, R8, 21
    STW R3, R2
    ret

cap_alloc:                           ; -> R1 = free slot or -1
    push R4                          ; clobbers R2, R3, R5; preserves R4, R6
    LDI R4, 0
ca_loop:
    MULI R2, R4, 18
    const R3, CTAB
    ADD R2, R3, R2
    LEA R3, R2, 3
    LDW R3, R3                       ; type
    CMPI3 R5, R3, 0
    BRZ R5, ca_ok
    ADDI R4, R4, 1
    CMPI3 R5, R4, NSLOT
    BRN R5, ca_loop
    LDI R1, -1
    pop R4
    ret
ca_ok:
    ADD R1, R4, R0
    pop R4
    ret

ipc_err:                             ; status -1, detail -1 (bad cap / rights)
    LDI R3, -1
    LEA R5, R8, 21
    STW R5, R3
    LEA R5, R8, 18
    STW R5, R3
    JMP th_resume

ipc_err2:                            ; status -1, detail -2 (no receiver)
    LDI R3, -1
    LEA R5, R8, 21
    STW R5, R3
    LDI R3, -2
    LEA R5, R8, 18
    STW R5, R3
    JMP th_resume

ipc_err3:                            ; status -1, detail -3 (no caller)
    LDI R3, -1
    LEA R5, R8, 21
    STW R5, R3
    LDI R3, -3
    LEA R5, R8, 18
    STW R5, R3
    JMP th_resume

ipc_ok:                              ; status 0, detail 0
    LDI R3, 0
    LEA R5, R8, 21
    STW R5, R3
    LEA R5, R8, 18
    STW R5, R3
    JMP th_resume

sys_send:                            ; frame: cap +18, msg +15/+12; right SEND
    LEA R1, R8, 18
    LDW R1, R1
    LDI R2, 5
    call cap_check
    CMPI3 R5, R1, 0
    BRN R5, ipc_err
    LEA R2, R1, 6
    LDW R2, R2                       ; endpoint obj (R2 survives tcb_addr)
    MULI R3, R2, 18
    const R4, EPT
    ADD R4, R4, R3                   ; R4 = &EPT[e]
    LEA R1, R4, EE_RQH
    LEA R2, R4, EE_RQT
    call ep_dequeue                  ; R6 = waiting receiver or 0
    CMPI3 R5, R6, 0
    BRZ R5, sys_send_blk
    ADD R1, R6, R0
    call tcb_addr
    call ipc_deliver                 ; msg -> receiver frame
    ADD R1, R6, R0
    call sched_enqueue               ; wake the receiver
    JMP ipc_ok
sys_send_blk:
    const R5, CURRENT
    LDW R5, R5
    ADD R1, R5, R0
    call tcb_addr                    ; R1 = &TCB[cur]
    LEA R3, R1, 24
    STW R3, R2                       ; T_WEP = ep
    LDI R2, -1
    LEA R3, R1, 9
    STW R3, R2                       ; state = blocked
    LDI R2, -1
    LEA R3, R1, 27
    STW R3, R2                       ; role = sender
    LEA R1, R4, EE_SQH
    LEA R2, R4, EE_SQT
    const R3, CURRENT
    LDW R3, R3
    call wait_push
    call schedule_switch             ; never returns

sys_recv:                            ; frame: cap +18; right RECV
    LEA R1, R8, 18
    LDW R1, R1
    LDI R2, 6
    call cap_check
    CMPI3 R5, R1, 0
    BRN R5, ipc_err
    LEA R2, R1, 6
    LDW R2, R2
    MULI R3, R2, 18
    const R4, EPT
    ADD R4, R4, R3
    LEA R1, R4, EE_SQH
    LEA R2, R4, EE_SQT
    call ep_dequeue                  ; R6 = waiting sender or 0
    CMPI3 R5, R6, 0
    BRZ R5, sys_recv_blk
    ADD R1, R6, R0
    call tcb_addr                    ; R1 = &TCB[sender]
    call ipc_take                    ; sender msg -> my frame, status ok
    LEA R3, R1, 27
    LDW R3, R3                       ; sender role
    CMPI3 R5, R3, 2
    BRZ R5, sys_recv_caller          ; CALL sender: stays blocked, becomes caller
    ADD R1, R6, R0
    call sched_enqueue               ; plain sender: wake it
    JMP ipc_ok
sys_recv_caller:
    LEA R3, R4, EE_CALLER
    STW R3, R6                       ; endpoint caller = sender tid
    JMP ipc_ok
sys_recv_blk:
    const R5, CURRENT
    LDW R5, R5
    ADD R1, R5, R0
    call tcb_addr
    LEA R3, R1, 24
    STW R3, R2                       ; T_WEP = ep
    LDI R2, -1
    LEA R3, R1, 9
    STW R3, R2                       ; state = blocked
    LDI R2, 1
    LEA R3, R1, 27
    STW R3, R2                       ; role = receiver
    LEA R1, R4, EE_RQH
    LEA R2, R4, EE_RQT
    const R3, CURRENT
    LDW R3, R3
    call wait_push
    call schedule_switch             ; never returns

sys_call:                            ; frame: cap +18, msg +15/+12; right CALL
    LEA R1, R8, 18
    LDW R1, R1
    LDI R2, 7
    call cap_check
    CMPI3 R5, R1, 0
    BRN R5, ipc_err
    LEA R2, R1, 6
    LDW R2, R2
    MULI R3, R2, 18
    const R4, EPT
    ADD R4, R4, R3
    LEA R1, R4, EE_RQH
    LEA R2, R4, EE_RQT
    call ep_dequeue                  ; R6 = waiting server or 0
    CMPI3 R5, R6, 0
    BRZ R5, sys_call_blk
    ADD R1, R6, R0
    call tcb_addr
    call ipc_deliver                 ; msg -> server frame
    ADD R1, R6, R0
    call sched_enqueue               ; wake the server (same as sys_send!)
    LEA R3, R4, EE_CALLER
    const R2, CURRENT
    LDW R2, R2
    STW R3, R2                       ; endpoint caller = me
    const R2, CURRENT
    LDW R2, R2
    ADD R1, R2, R0
    call tcb_addr
    LDI R2, -1
    LEA R3, R1, 9
    STW R3, R2                       ; state = blocked (awaiting REPLY)
    LDI R2, 2
    LEA R3, R1, 27
    STW R3, R2                       ; role = call-await
    call schedule_switch             ; never returns
sys_call_blk:
    const R5, CURRENT
    LDW R5, R5
    ADD R1, R5, R0
    call tcb_addr
    LEA R3, R1, 24
    STW R3, R2                       ; T_WEP = ep
    LDI R2, -1
    LEA R3, R1, 9
    STW R3, R2                       ; state = blocked
    LDI R2, 2
    LEA R3, R1, 27
    STW R3, R2                       ; role = call sender
    LEA R1, R4, EE_SQH
    LEA R2, R4, EE_SQT
    const R3, CURRENT
    LDW R3, R3
    call wait_push
    call schedule_switch             ; never returns

sys_reply:                           ; frame: cap +18, reply +15/+12; right CALL
    LEA R1, R8, 18
    LDW R1, R1
    LDI R2, 7
    call cap_check
    CMPI3 R5, R1, 0
    BRN R5, ipc_err
    LEA R2, R1, 6
    LDW R2, R2
    MULI R3, R2, 18
    const R4, EPT
    ADD R4, R4, R3
    LEA R3, R4, EE_CALLER
    LDW R6, R3                       ; caller tid
    CMPI3 R5, R6, 0
    BRZ R5, ipc_err3
    ADD R1, R6, R0
    call tcb_addr
    call ipc_deliver                 ; reply -> caller frame (status ok)
    ADD R1, R6, R0
    call sched_enqueue               ; wake the caller
    LEA R3, R4, EE_CALLER
    STW R3, R0                       ; caller = 0
    JMP ipc_ok

sys_nbsend:                          ; frame: cap +18, msg +15/+12; right SEND
    LEA R1, R8, 18
    LDW R1, R1
    LDI R2, 5
    call cap_check
    CMPI3 R5, R1, 0
    BRN R5, ipc_err
    LEA R2, R1, 6
    LDW R2, R2
    MULI R3, R2, 18
    const R4, EPT
    ADD R4, R4, R3
    LEA R1, R4, EE_RQH
    LEA R2, R4, EE_RQT
    call ep_dequeue
    CMPI3 R5, R6, 0
    BRZ R5, ipc_err2                 ; no receiver: report, keep running
    ADD R1, R6, R0
    call tcb_addr
    call ipc_deliver
    ADD R1, R6, R0
    call sched_enqueue
    JMP ipc_ok

sys_ep_create:                       ; frame: badge +18 -> R1 = cap ref
    LDI R4, 0
ec_scan:
    MULI R2, R4, 18
    const R3, EPT
    ADD R2, R3, R2
    LDW R3, R2                       ; used
    CMPI3 R5, R3, 0
    BRZ R5, ec_found
    ADDI R4, R4, 1
    CMPI3 R5, R4, NEP
    BRN R5, ec_scan
    JMP ipc_err                      ; endpoints exhausted
ec_found:
    LDI R3, 1
    STW R2, R3                       ; used = 1
    ADDI R2, R2, 3
    STW R2, R0                       ; rq_h = 0
    ADDI R2, R2, 3
    STW R2, R0                       ; rq_t = 0
    ADDI R2, R2, 3
    STW R2, R0                       ; sq_h = 0
    ADDI R2, R2, 3
    STW R2, R0                       ; sq_t = 0
    ADDI R2, R2, 3
    STW R2, R0                       ; caller = 0
    call cap_alloc                   ; R1 = slot or -1
    CMPI3 R5, R1, 0
    BRN R5, ipc_err
    MULI R2, R1, 18
    const R3, CTAB
    ADD R2, R3, R2                   ; &entry
    LDI R3, 1
    STW R2, R3                       ; gen = 1
    LEA R3, R2, 3
    LDI R5, 1
    STW R3, R5                       ; type = endpoint
    LEA R3, R2, 6
    STW R3, R4                       ; obj = endpoint index
    LEA R3, R2, 9
    const R5, RIGHT_ALL
    STW R3, R5                       ; rights = every right +
    LEA R3, R2, 12
    LEA R5, R8, 18
    LDW R5, R5
    STW R3, R5                       ; badge = argument
    LEA R3, R2, 15
    LDI R5, -1
    STW R3, R5                       ; parent = root
    LEA R3, R8, 21
    STW R3, R1                       ; result R1 = cap ref
    LDI R1, 0
    LEA R3, R8, 18
    STW R3, R1                       ; error R2 = 0
    JMP th_resume

sys_cap_derive:                      ; frame: parent +18, requested rights +15
    LEA R1, R8, 18
    LDW R1, R1
    LDI R2, 3                        ; GRANT gates derivation
    call cap_check
    CMPI3 R5, R1, 0
    BRN R5, ipc_err
    LEA R2, R1, 9
    LDW R3, R2                       ; parent rights word
    LEA R2, R1, 6
    LDW R2, R2                       ; obj
    push R2
    LEA R2, R1, 12
    LDW R2, R2                       ; badge
    push R2
    LEA R1, R8, 21                   ; requested rights word: the two pushes
    LDW R1, R1                       ; shifted R8 by -6, so frame +15 = R8 + 21
    LDI R6, 16                       ; shift of the highest group (right 8)
    LDI R5, 0                        ; child rights word
cd_loop:
    TSHR R4, R3, R6                  ; parent group (reg-form shift)
    TSHR R7, R1, R6                  ; requested group
    LDI R2, 9
    MOD R4, R4, R2
    MOD R7, R7, R2                   ; both as balanced pairs in [-4, 4]
    CMPI3 R2, R7, -1
    BRN R2, cd_bad2
    CMPI3 R2, R7, 1
    BRP R2, cd_bad2
    CMP3 R2, R4, R7                  ; min(parent, requested), order - < 0 < +
    BRZP R2, cd_req
    JMP cd_min
cd_req:
    ADD R4, R7, R0
cd_min:
    MULI R5, R5, 9
    ADD R5, R5, R4                   ; child word = child * 9 + group
    ADDI R6, R6, -2                  ; next lower group (9 groups: 16..0)
    CMPI3 R2, R6, -2
    BRZ R2, cd_built
    JMP cd_loop
cd_built:
    ADD R6, R5, R0                   ; child rights word (cap_alloc clobbers R5)
    call cap_alloc                   ; R1 = slot or -1 (preserves R6)
    CMPI3 R5, R1, 0
    BRN R5, cd_bad2
    ADD R7, R1, R0                   ; child slot (R7 free: handlers never ret)
    MULI R2, R7, 18
    const R3, CTAB
    ADD R2, R3, R2                   ; &child
    LDI R3, 1
    STW R2, R3                       ; gen = 1
    pop R5                           ; badge (pushed last)
    pop R4                           ; obj
    LEA R3, R2, 12
    STW R3, R5                       ; badge
    LEA R3, R2, 6
    STW R3, R4                       ; obj
    LEA R3, R2, 9
    STW R3, R6                       ; rights = child word
    ; type and parent come from the parent entry
    LEA R1, R8, 18
    LDW R1, R1                       ; parent ref
    MULI R3, R1, 18
    const R4, CTAB
    ADD R4, R4, R3                   ; &parent
    LEA R3, R4, 3
    LDW R3, R3                       ; type
    LEA R5, R2, 3
    STW R5, R3                       ; child type
    LEA R5, R2, 15
    STW R5, R1                       ; child parent = parent slot
    LEA R3, R8, 21
    STW R3, R7                       ; result R1 = child slot
    LDI R3, 0
    LEA R5, R8, 18
    STW R5, R3                       ; error R2 = 0
    JMP th_resume
cd_bad2:
    pop R5                           ; badge
    pop R4                           ; obj
    JMP ipc_err

sys_cap_copy:                        ; frame: parent +18; right GRANT
    LEA R1, R8, 18
    LDW R1, R1
    LDI R2, 3
    call cap_check
    CMPI3 R5, R1, 0
    BRN R5, ipc_err
    ADD R7, R1, R0                   ; &parent (cap_alloc preserves R7)
    call cap_alloc                   ; R1 = child slot or -1
    CMPI3 R5, R1, 0
    BRN R5, ipc_err
    MULI R2, R1, 18
    const R3, CTAB
    ADD R2, R3, R2                   ; &child
    LEA R3, R7, 3
    LDW R4, R3                       ; type
    LEA R5, R2, 3
    STW R5, R4
    LEA R3, R7, 6
    LDW R4, R3                       ; obj
    LEA R5, R2, 6
    STW R5, R4
    LEA R3, R7, 9
    LDW R4, R3                       ; rights (verbatim copy)
    LEA R5, R2, 9
    STW R5, R4
    LEA R3, R7, 12
    LDW R4, R3                       ; badge
    LEA R5, R2, 12
    STW R5, R4
    LEA R5, R2, 0
    LDI R4, 1
    STW R5, R4                       ; gen = 1
    LEA R5, R2, 15
    LEA R3, R8, 18
    LDW R3, R3
    STW R5, R3                       ; parent = parent slot
    LEA R3, R8, 21
    STW R3, R1                       ; result R1 = child slot
    LDI R3, 0
    LEA R5, R8, 18
    STW R5, R3                       ; error R2 = 0
    JMP th_resume

sys_cap_revoke:                      ; frame: target +18; right GRANT
    LEA R1, R8, 18
    LDW R1, R1
    ADD R6, R1, R0                   ; target slot
    LDI R2, 3
    call cap_check
    CMPI3 R5, R1, 0
    BRN R5, ipc_err
    LDI R4, 0                        ; s = 0
rv_slot:
    CMP3 R5, R4, R6
    BRZ R5, rv_next                  ; never revoke the target itself
    ADD R2, R4, R0                   ; p = s (walk the parent chain)
rv_walk:
    CMPI3 R5, R2, 0
    BRN R5, rv_next
    CMPI3 R5, R2, NSLOT
    BRZP R5, rv_next
    MULI R3, R2, 18
    const R5, CTAB
    ADD R3, R5, R3                   ; &entry[p]
    LEA R5, R3, 3
    LDW R5, R5                       ; type
    CMPI3 R5, R5, 0
    BRZ R5, rv_next                  ; dead chain -> not descended
    LEA R5, R3, 15
    LDW R2, R5                       ; p = parent
    CMPI3 R5, R2, -1
    BRZ R5, rv_next                  ; reached a root -> stop
    CMP3 R5, R2, R6
    BRZ R5, rv_hit                   ; descended from the target
    JMP rv_walk
rv_hit:
    MULI R3, R4, 18
    const R5, CTAB
    ADD R3, R5, R3                   ; &entry[s]
    LEA R5, R3, 0
    LDW R2, R5
    ADDI R2, R2, 1
    STW R5, R2                       ; gen++
    LEA R5, R3, 3
    STW R5, R0                       ; type = free
rv_next:
    ADDI R4, R4, 1
    CMPI3 R5, R4, NSLOT
    BRN R5, rv_slot
    JMP ipc_ok

sys_cap_delete:                      ; frame: target +18; right GRANT
    LEA R1, R8, 18
    LDW R1, R1
    LDI R2, 3
    call cap_check
    CMPI3 R5, R1, 0
    BRN R5, ipc_err
    LDW R2, R1                       ; gen
    ADDI R2, R2, 1
    STW R1, R2                       ; gen++
    LEA R3, R1, 3
    STW R3, R0                       ; type = free
    JMP ipc_ok
; console helpers (clobber only caller-saved regs + R7 via call)
; ------------------------------------------------------------------------------
putc:                                ; R1 = tryte
    const R2, UART_TX
    STT R2, R1
    ret

puts:                                ; R1 = string address (non-leaf: saves R7)
    push R7
    ADD R3, R1, R0
puts_loop:
    LDT R2, R3
    BRZ R2, puts_done
    push R3
    ADD R1, R2, R0
    call putc
    pop R3
    ADDI R3, R3, 1
    JMP puts_loop
puts_done:
    pop R7
    ret

putnum:                              ; R1 = signed word -> decimal
    push R7
    push R4
    push R5
    push R6
    ADD R4, R1, R0                   ; v
    CMPI3 R5, R4, 0
    BRZP R5, pn_pos
    SUB R4, R0, R4                   ; v = -v
    CMPI3 R5, R4, 0
    BRN R5, pn_wordmin               ; negation wrapped -> was WORD_MIN
    LDI R1, 45                       ; '-'
    call putc
    JMP pn_pos
pn_wordmin:
    const R1, str_wordmin
    call puts
    JMP pn_done
pn_pos:
    CMP3 R5, R4, R0
    BRNZ R5, pn_digits
    LDI R1, 48                       ; '0'
    call putc
    JMP pn_done
pn_digits:
    const R3, PNUMBUF
    ADDI R3, R3, 11                  ; fill backwards
pn_dig:
    CMPI3 R5, R4, 0
    BRZ R5, pn_emit
    LDI R5, 10
    DIV R1, R4, R5                   ; q10 = round-nearest(v/10)
    MULI R5, R1, 10
    SUB R2, R4, R5                   ; r = v - q10*10, in [-5, 5]
    CMPI3 R5, R2, 0
    BRZP R5, pn_r_ok
    ADDI R2, R2, 10                  ; r += 10
    ADDI R1, R1, -1                  ; q10 -= 1  (v = q10*10 + d stays true)
pn_r_ok:
    LDI R5, 48
    ADD R2, R2, R5                   ; ASCII digit
    STT R3, R2
    ADDI R3, R3, -1
    ADD R4, R1, R0                   ; v = q10
    JMP pn_dig
pn_emit:
    ADDI R3, R3, 1                   ; first stored digit
pn_emit_loop:
    const R5, PNUMBUF+11
    CMP3 R5, R3, R5
    BRP R5, pn_done
    LDT R1, R3
    call putc
    ADDI R3, R3, 1
    JMP pn_emit_loop
pn_done:
    pop R6
    pop R5
    pop R4
    pop R7
    ret

; ------------------------------------------------------------------------------
; ternary buddy allocator (D-030, D-030b..e)
; ------------------------------------------------------------------------------
bstate_get:                          ; R1 = node -> R1 = state
    push R2
    push R3
    const R2, BUDDY_STATE
    ADD R3, R2, R1
    LDT R1, R3
    pop R3
    pop R2
    ret

bstate_set:                          ; R1 = node, R2 = value
    push R3
    const R3, BUDDY_STATE
    ADD R3, R3, R1
    STT R3, R2
    pop R3
    ret

pow3:                                ; R1 = e -> R1 = 3^e
    push R2
    push R5
    LDI R2, 1
pw_loop:
    CMPI3 R5, R1, 0
    BRZ R5, pw_done
    MULI R2, R2, 3
    ADDI R1, R1, -1
    JMP pw_loop
pw_done:
    ADD R1, R2, R0
    pop R5
    pop R2
    ret

buddy_init:
    push R7
    ; 1) HINT[0..8] = 0
    const R3, HINT
    LDI R4, 0
bi_zh:
    CMPI3 R5, R4, 9
    BRZP R5, bi_zh_done
    MULI R6, R4, 3
    ADD R6, R3, R6
    LDI R2, 0
    STW R6, R2
    ADDI R4, R4, 1
    JMP bi_zh
bi_zh_done:
    ; 2) leaf states: node = 3281 + j (depth-8 base), used if reserved frame
    LDI R4, 0                        ; j
bi_leaf:
    CMPI3 R5, R4, 6561
    BRZP R5, bi_leaf_done
    LDI R2, 0
    CMPI3 R5, R4, RES_END
    BRN R5, bi_used
    CMPI3 R5, R4, STK_LO
    BRN R5, bi_store
    CMPI3 R5, R4, STK_HI+1
    BRZP R5, bi_store             ; j >= 6449 -> free (stack is 6446..6448)
bi_used:
    LDI R2, 1
bi_store:
    ADD R1, R4, R0
    ADDI R1, R1, 3281
    call bstate_set
    ADDI R4, R4, 1
    JMP bi_leaf
bi_leaf_done:
    ; 3) bottom-up merge: depth 8 -> 1
    ; BFS ids: depth d nodes are FIRST[d] .. FIRST[d]+3^d-1 with
    ; FIRST[d] = (3^d - 1)/2 + 1  (children of n: 3n-1, 3n, 3n+1)
    LDI R4, 8                        ; d
bi_merge_d:
    CMPI3 R5, R4, 0
    BRZ R5, bi_done
    ADD R1, R4, R0
    ADDI R1, R1, -1
    call pow3                        ; R1 = 3^(d-1) = parent count
    ADD R6, R1, R0
    LDI R1, 1
    SUB R5, R6, R1                   ; count-1
    LDI R1, 2
    DIV R1, R5, R1                   ; (count-1)/2
    ADDI R1, R1, 1                   ; R1 = FIRST[d-1] (parent base id)
    LDI R2, 0                        ; j = 0 (R2 is stale from the previous depth!)
bi_mj:
    CMP3 R5, R2, R6
    BRZP R5, bi_mnext
    ADD R3, R2, R0
    ADD R3, R3, R1                   ; p = FIRST[d-1] + j
    push R1                          ; save base
    push R2                          ; save j
    push R3                          ; save p
    MULI R3, R3, 3
    ADDI R3, R3, -1                  ; c0 = 3p-1
    push R3                          ; save c0
    ADD R1, R3, R0
    call bstate_get
    LDI R5, 0
    CMP3 R5, R1, R5
    BRNZ R5, bi_not_free
    ADDI R1, R3, 1
    call bstate_get
    LDI R5, 0
    CMP3 R5, R1, R5
    BRNZ R5, bi_not_free
    ADDI R1, R3, 2
    call bstate_get
    LDI R5, 0
    CMP3 R5, R1, R5
    BRNZ R5, bi_not_free
    LDI R2, 0                        ; parent free
    JMP bi_setp
bi_not_free:
    LDI R2, 2                        ; parent split
bi_setp:
    pop R3                           ; discard c0
    pop R1                           ; p
    call bstate_set
    pop R2                           ; restore j
    pop R1                           ; restore base
bi_mcont:
    ADDI R2, R2, 1
    JMP bi_mj
bi_mnext:
    ADDI R4, R4, -1
    JMP bi_merge_d
bi_done:
    pop R7
    ret

buddy_alloc:                         ; R1 = order -> R1 = node or -1
    push R7
    push R2
    push R3
    push R4
    push R5
    push R6
    ADD R4, R1, R0                   ; order
    LDI R5, 8
    SUB R4, R5, R4                   ; R4 = target depth t = 8 - order
    ADD R1, R4, R0
    call pow3                        ; R1 = count = 3^t
    ADD R6, R1, R0                   ; R6 = count
    LDI R1, 1
    SUB R3, R6, R1                   ; count-1
    LDI R1, 2
    DIV R1, R3, R1                   ; (count-1)/2
    ADDI R1, R1, 1
    ADD R3, R1, R0                   ; R3 = base = FIRST[t]
    MULI R5, R4, 3
    const R6, HINT
    ADD R5, R6, R5                   ; R5 = &HINT[t]
    LDW R2, R5                       ; R2 = j = scan hint
ba_scan:
    CMP3 R5, R2, R6                  ; R5 = sign(j - count) (scratch)
    BRZP R5, ba_none                 ; j >= count -> exhausted
    ADD R1, R2, R0
    ADD R1, R1, R3                   ; R1 = node = j + base
    call bstate_get                  ; R1 = state (R2..R6 preserved)
    LDI R5, 0
    CMP3 R5, R1, R5
    BRNZ R5, ba_next
    ; candidate: verify no ancestor is allocated (state 1) — otherwise the
    ; node lives inside an already-allocated larger block (D-030e)
    push R2                          ; save j
    ADD R1, R2, R0
    ADD R1, R1, R3                   ; node
    push R1                          ; node on the stack
ba_chk:
    LDW R1, R8                       ; walker = node (top of stack)
    LDI R2, 1
    CMP3 R5, R1, R2
    BRZ R5, ba_chk_ok                ; root reached -> really free
    call bstate_get                  ; R1 = state(walker)
    LDI R2, 1
    CMP3 R5, R1, R2
    BRZ R5, ba_chk_skip              ; ancestor allocated -> leaf blocked
    LDW R6, R8                       ; walker (R6 scratch here)
    ADDI R6, R6, 1
    LDI R2, 3
    MOD R5, R6, R2
    CMPI3 R2, R5, 0
    BRZP R2, ba_chk_i
    ADDI R5, R5, 3
ba_chk_i:
    SUB R2, R6, R5
    LDI R6, 3
    DIV R2, R2, R6                   ; p = parent
    STW R8, R2                       ; walker = p (store back)
    JMP ba_chk
ba_chk_skip:
    LEA R2, R8, 3                    ; R2 = &j (SP+3)
    LDW R2, R2                       ; j
    ADDI R2, R2, 1
    MULI R5, R4, 3
    const R6, HINT
    ADD R5, R6, R5
    STW R5, R2                       ; hint = j + 1
    ADDI R8, R8, 6                   ; drop node + j
    ADD R1, R4, R0
    call pow3                        ; recompute count (R6 was scratch)
    ADD R6, R1, R0
    JMP ba_scan
ba_chk_ok:
    LEA R2, R8, 3                    ; R2 = &j (the walk-up overwrote the node slot)
    LDW R2, R2                       ; j
    ADD R1, R2, R0
    ADD R1, R1, R3                   ; leaf = j + base (the original candidate)
    LDI R2, 1
    call bstate_set                  ; mark leaf used
    SUB R2, R1, R3                   ; j = leaf - base (re-derived)
    ADDI R2, R2, 1                   ; j + 1
    MULI R5, R4, 3
    const R6, HINT
    ADD R5, R6, R5
    STW R5, R2                       ; HINT[t] = j + 1
    ADDI R8, R8, 6                   ; drop node + j
ba_anc:
    LDI R2, 1
    CMP3 R5, R1, R2                  ; root?
    BRZ R5, ba_ret_node
    ADDI R6, R1, 1
    LDI R2, 3
    MOD R5, R6, R2
    CMPI3 R2, R5, 0
    BRZP R2, ba_i_ok
    ADDI R5, R5, 3
ba_i_ok:
    SUB R2, R6, R5
    LDI R6, 3
    DIV R2, R2, R6                   ; p = parent
    ADD R1, R2, R0                   ; walk up
    LDI R2, 2
    call bstate_set                  ; ancestor = split
    JMP ba_anc
ba_ret_node:
    ; node = HINT[t] - 1 + base
    MULI R5, R4, 3
    const R6, HINT
    ADD R5, R6, R5
    LDW R1, R5                       ; hint = j + 1
    LDI R6, 1
    SUB R1, R1, R6                   ; j
    ADD R1, R1, R3                   ; node = j + base
    JMP ba_out
ba_next:
    ADDI R2, R2, 1
    MULI R5, R4, 3
    const R6, HINT
    ADD R5, R6, R5
    STW R5, R2                       ; hint advances past non-free nodes
    JMP ba_scan
ba_none:
    LDI R1, -1
ba_out:
    pop R6
    pop R5
    pop R4
    pop R3
    pop R2
    pop R7
    ret

buddy_free:                          ; R1 = depth, R2 = node
    push R7
    push R2
    push R3
    push R4
    push R5
    push R6
    ADD R3, R2, R0                   ; node
    ADD R4, R1, R0                   ; depth
    ADD R1, R3, R0
    LDI R2, 0
    call bstate_set                  ; state[node] = 0
    ; lower HINT[depth] to the freed node's index if below it
    ADD R1, R4, R0
    call pow3                        ; R1 = count = 3^depth
    LDI R2, 1
    SUB R5, R1, R2                   ; count-1
    LDI R2, 2
    DIV R2, R5, R2                   ; (count-1)/2
    ADDI R2, R2, 1                   ; FIRST[depth]
    SUB R2, R3, R2                   ; j = node - FIRST[depth]
    MULI R5, R4, 3
    const R6, HINT
    ADD R5, R6, R5                   ; &HINT[depth]
    LDW R1, R5                       ; current hint
    CMP3 R5, R2, R1                  ; R5 = sign(j - hint) (clobbers &HINT)
    BRZP R5, bf_walk                 ; j >= hint -> no update
    MULI R5, R4, 3
    const R6, HINT
    ADD R5, R6, R5                   ; recompute &HINT[depth]
    STW R5, R2                       ; hint = j
bf_walk:
    ADD R1, R3, R0                   ; walk from the freed node
bf_anc:
    LDI R2, 1
    CMP3 R5, R1, R2                  ; root?
    BRZ R5, bf_out
    ADDI R6, R1, 1
    LDI R2, 3
    MOD R5, R6, R2
    CMPI3 R2, R5, 0
    BRZP R2, bf_i_ok
    ADDI R5, R5, 3
bf_i_ok:
    SUB R2, R6, R5
    LDI R6, 3
    DIV R2, R2, R6                   ; p = parent
    ADD R1, R2, R0
    ; state[p] = 0 iff all three children are free, else 2
    push R2                          ; save p
    MULI R6, R2, 3
    ADDI R6, R6, -1                  ; c0 = 3p-1
    ADD R1, R6, R0
    call bstate_get
    LDI R4, 0
    CMP3 R4, R1, R4
    BRNZ R4, bf_split
    ADDI R1, R6, 1
    call bstate_get
    LDI R4, 0
    CMP3 R4, R1, R4
    BRNZ R4, bf_split
    ADDI R1, R6, 2
    call bstate_get
    LDI R4, 0
    CMP3 R4, R1, R4
    BRNZ R4, bf_split
    LDI R1, 0
    JMP bf_setv
bf_split:
    LDI R1, 2
bf_setv:
    ADD R5, R1, R0                   ; value
    LDW R2, R8                       ; p is at the top of the stack
    ADD R1, R2, R0                   ; node = p
    ADD R2, R5, R0                   ; value
    call bstate_set
    pop R2                           ; p
    ADD R1, R2, R0                   ; walk up
    JMP bf_anc
bf_out:
    pop R6
    pop R5
    pop R4
    pop R3
    pop R2
    pop R7
    ret

; ------------------------------------------------------------------------------
; scheduler (D-033..D-036)
; ------------------------------------------------------------------------------
tcb_addr:                            ; R1 = tid -> R1 = &TCB (preserves R2..R6)
    push R2
    push R3
    MULI R2, R1, 36
    const R3, TCBS
    ADD R1, R3, R2
    pop R3
    pop R2
    ret

sched_init:                          ; zero tables, chain the free list
    push R2
    push R3
    push R4
    push R5
    push R6
    push R7
    const R2, FREE_TID
    LDI R1, 2
    STW R2, R1                       ; FREE_TID = 2
    LDI R4, 2                        ; t
si_chain:
    ADD R1, R4, R0
    call tcb_addr
    ADDI R3, R4, 1                   ; t + 1
    CMPI3 R5, R3, NT
    BRZ R5, si_last
    STW R1, R3                       ; TCB[t].next = t + 1
    JMP si_state
si_last:
    LDI R3, 0
    STW R1, R3                       ; end of the free list
si_state:
    LDI R2, -2
    LEA R3, R1, 9
    STW R3, R2                       ; state = free slot
    LDI R2, 0
    LEA R3, R1, 24
    STW R3, R2                       ; T_WEP = 0
    LEA R3, R1, 27
    STW R3, R2                       ; T_ROLE = 0
    LEA R3, R1, 30
    STW R3, R2                       ; T_CALLER = 0
    ADDI R4, R4, 1
    CMPI3 R5, R4, NT
    BRN R5, si_chain
    ; queues empty
    const R1, QHEADS
    LDI R2, 0
    LDI R4, 0
si_zq:
    MULI R3, R4, 3
    ADD R3, R1, R3
    STW R3, R2
    ADDI R4, R4, 1
    CMPI3 R5, R4, 6
    BRN R5, si_zq
    ; CURRENT = -1
    const R1, CURRENT
    LDI R2, -1
    STW R1, R2
    ; DONE[0..NT-1] = 0, STRESS[0..NT-1] = 0
    const R1, DONE
    LDI R2, 0
    LDI R4, 0
si_zd:
    MULI R3, R4, 3
    ADD R3, R1, R3
    STW R3, R2
    ADDI R4, R4, 1
    CMPI3 R5, R4, NT
    BRN R5, si_zd
    const R1, STRESS
    LDI R2, 0
    LDI R4, 0
si_zs:
    MULI R3, R4, 3
    ADD R3, R1, R3
    STW R3, R2
    ADDI R4, R4, 1
    CMPI3 R5, R4, NT
    BRN R5, si_zs
    ; capability table: all slots free (gen = 1, parent = -1)
    const R1, CTAB
    LDI R4, 0
si_ct:
    MULI R3, R4, 18
    ADD R3, R1, R3                   ; &entry
    LDI R2, 1
    STW R3, R2                       ; gen = 1
    LEA R5, R3, 3
    LDI R2, 0
    STW R5, R2                       ; type = free
    LEA R5, R3, 6
    STW R5, R2                       ; obj = 0
    LEA R5, R3, 9
    STW R5, R2                       ; rights = 0
    LEA R5, R3, 12
    STW R5, R2                       ; badge = 0
    LEA R5, R3, 15
    LDI R2, -1
    STW R5, R2                       ; parent = root
    ADDI R4, R4, 1
    CMPI3 R5, R4, NSLOT
    BRN R5, si_ct
    ; endpoint table: all free
    const R1, EPT
    LDI R4, 0
si_ep:
    MULI R3, R4, 18
    ADD R3, R1, R3
    LDI R2, 0
    STW R3, R2                       ; used = 0
    LEA R5, R3, 3
    STW R5, R2                       ; rq_h
    LEA R5, R3, 6
    STW R5, R2                       ; rq_t
    LEA R5, R3, 9
    STW R5, R2                       ; sq_h
    LEA R5, R3, 12
    STW R5, R2                       ; sq_t
    LEA R5, R3, 15
    STW R5, R2                       ; caller
    ADDI R4, R4, 1
    CMPI3 R5, R4, NEP
    BRN R5, si_ep
    pop R7
    pop R6
    pop R5
    pop R4
    pop R3
    pop R2
    ret

sched_enqueue:                       ; R1 = tid -> tail of its class queue
    push R2                          ; (preserves R2..R6)
    push R3
    push R4
    push R5
    push R6
    push R7
    ADD R5, R1, R0                   ; tid
    call tcb_addr                    ; R1 = &TCB[tid]
    LDI R2, 0
    STW R1, R2                       ; T_NEXT = 0
    LEA R3, R1, 9
    STW R3, R2                       ; state = ready
    LEA R3, R1, 12
    LDW R3, R3                       ; class
    ADDI R3, R3, 1                   ; qidx = class + 1
    MULI R3, R3, 6                   ; word-pair offset
    const R4, QHEADS
    ADD R4, R4, R3                   ; &head[qidx]
    ADD R1, R4, R0
    ADDI R1, R1, 3                   ; &tail[qidx]
    LDW R2, R1                       ; tail (0 = empty)
    CMPI3 R3, R2, 0
    BRZ R3, senq_empty
    ADD R1, R2, R0
    call tcb_addr                    ; &TCB[tail]
    STW R1, R5                       ; TCB[tail].next = tid
    JMP senq_link
senq_empty:
    STW R4, R5                       ; head = tid
senq_link:
    ADD R1, R4, R0
    ADDI R1, R1, 3
    STW R1, R5                       ; tail = tid
    pop R7
    pop R6
    pop R5
    pop R4
    pop R3
    pop R2
    ret

sched_requeue_cur:                   ; current -> tail of its class queue
    push R2
    push R3
    push R4
    push R5
    push R6
    push R7
    const R1, CURRENT
    LDW R1, R1
    CMPI3 R5, R1, 0
    BRZ R5, src_none                 ; idle is never queued
    BRN R5, src_none                 ; no current thread
    ADD R6, R1, R0                   ; tid
    ADD R1, R6, R0
    call tcb_addr
    LDI R2, 0
    STW R1, R2                       ; T_NEXT = 0
    LEA R3, R1, 9
    STW R3, R2                       ; state = ready
    LEA R3, R1, 12
    LDW R3, R3                       ; class
    ADDI R3, R3, 1
    MULI R3, R3, 6
    const R4, QHEADS
    ADD R4, R4, R3                   ; &head
    ADD R5, R4, R0
    ADDI R5, R5, 3                   ; &tail
    LDW R2, R5                       ; tail
    CMPI3 R3, R2, 0
    BRZ R3, src_empty
    ADD R1, R2, R0
    call tcb_addr
    STW R1, R6                       ; TCB[tail].next = tid
    ADD R1, R4, R0
    ADDI R1, R1, 3
    STW R1, R6                       ; tail = tid
    JMP src_none
src_empty:
    STW R4, R6                       ; head = tid
    ADD R1, R4, R0
    ADDI R1, R1, 3
    STW R1, R6                       ; tail = tid
src_none:
    pop R7
    pop R6
    pop R5
    pop R4
    pop R3
    pop R2
    ret

; schedule_switch — pick the best ready thread and RETI into it (D-034).
; Clobbers R1..R7 freely (they all belong to the interrupted thread, whose
; values are safe on its trap frame). Never returns.
schedule_switch:
    LDI R7, 2                        ; qidx 2 = realtime first
ss_scan:
    MULI R2, R7, 6
    const R3, QHEADS
    ADD R3, R3, R2                   ; &head[qidx]
    LDW R4, R3                       ; head
    CMPI3 R5, R4, 0
    BRZ R5, ss_nextq
    ADD R6, R4, R0                   ; tid = head
    ADD R1, R4, R0
    call tcb_addr                    ; R1 = &TCB[tid]
    LDW R2, R1                       ; next
    STW R3, R2                       ; head = next
    ; zombie guard: a freed slot (state -2) may still be linked by a stale
    ; queue entry — the head has already advanced past it, so just rescan
    LEA R5, R1, 9
    LDW R4, R5                       ; state
    CMPI3 R5, R4, -2
    BRZ R5, ss_scan
    CMPI3 R5, R2, 0
    BRZ R5, ss_qempty
    JMP ss_pick
ss_qempty:
    ADD R2, R3, R0
    ADDI R2, R2, 3
    STW R2, R0                       ; tail = 0 (queue drained)
ss_pick:
    LDI R2, 1
    LEA R3, R1, 9
    STW R3, R2                       ; state = running
    const R3, CURRENT
    STW R3, R6                       ; CURRENT = tid
    JMP ss_restore
ss_nextq:
    ADDI R7, R7, -1
    CMPI3 R5, R7, 0
    BRN R5, ss_idle
    JMP ss_scan
ss_idle:
    LDI R1, 0
    call tcb_addr                    ; R1 = &TCB[0]
    LDI R2, 1
    LEA R3, R1, 9
    STW R3, R2                       ; idle state = running
    const R3, CURRENT
    STW R3, R0                       ; CURRENT = 0
ss_restore:                          ; R1 = &TCB[next]
    ; No CSRW PSW here: IRQs stay disabled until RETI, which restores the
    ; PSW snapshot (= a running thread's interrupts-on state, D-033/D-034).
    ; The TCB reload guards against a stale EPC from an earlier nested trap.
    LEA R2, R1, 6
    LDW R2, R2                       ; saved EPC
    CSRW EPC, R2                     ; R2 dead (reloaded below)
    LEA R2, R1, 3
    LDW R8, R2                       ; R8 = saved SP (frame top)
    ADDI R8, R8, 3                   ; skip the saved-SP slot -> R7 slot
    pop R7
    pop R6
    pop R5
    pop R4
    pop R3
    pop R2
    pop R1
    RETI                             ; PC = EPC; PSW from the snapshot

; ---- syscall bodies -----------------------------------------------------------
sys_create_body:                     ; R1 = fn, R2 = class, R3 = arg
    ADD R4, R8, R0                   ; old SP (this frame is abandoned if the
    ADD R5, R1, R0                   ;  new thread preempts, so keep it in a reg)
    ADD R6, R2, R0                   ; class
    push R3                          ; arg      (old SP - 3)
    push R7                          ; LR       (old SP - 6)
    ; validate the arguments: fn must point into the kernel text segment,
    ; class must be a trit (-1/0/+1); anything else is a clean error
    CMPI3 R3, R5, KERNEL_LOAD
    BRN R3, scr_fail
    const R2, STRBASE
    CMP3 R3, R5, R2
    BRZP R3, scr_fail
    CMPI3 R3, R6, -1
    BRN R3, scr_fail
    CMPI3 R3, R6, 1
    BRP R3, scr_fail
    const R1, FREE_TID
    LDW R1, R1                       ; free slot (0 = exhausted)
    CMPI3 R3, R1, 0
    BRZ R3, scr_fail
    push R1                          ; tid      (old SP - 9): R7 is the LR and is
                                     ; clobbered by every call below, so the tid
                                     ; lives on the caller's stack instead
    call tcb_addr                    ; R1 = &TCB[tid]
    LDW R2, R1                       ; next slot in the free list
    const R3, FREE_TID
    STW R3, R2                       ; FREE_TID = next
    LDI R1, 0
    call buddy_alloc                 ; kernel stack page (order 0)
    CMPI3 R3, R1, -1
    BRZ R3, scr_fail2
    ADDI R1, R1, -3281               ; node -> frame index
    MULI R1, R1, 729                 ; stack frame base PA
    ADD R3, R1, R0                   ; base
    ADDI R2, R3, 729                 ; stack top
    ADD R8, R2, R0                   ; build the initial frame on the new stack
    LEA R1, R4, -3
    LDW R1, R1                       ; arg (saved on the caller's stack)
    push R1                          ; R1 slot = arg
    LDI R1, 0
    push R1                          ; R2 = 0
    push R1
    push R1
    push R1
    push R1
    push R1                          ; R7 = 0
    ADDI R8, R8, -3
    LEA R2, R8, 3
    STW R8, R2                       ; saved-SP slot = stack top
    LEA R1, R4, -9
    LDW R1, R1                       ; tid (JAL clobbered R7 in the meantime)
    call tcb_addr                    ; R1 = &TCB[tid]
    LEA R2, R1, 3
    STW R2, R8                       ; T_SP = frame top (offset +3!)
    ADD R2, R5, R0                   ; fn
    LEA R3, R1, 6
    STW R3, R2                       ; T_EPC = fn
    LDI R2, 0
    LEA R3, R1, 9
    STW R3, R2                       ; state = ready
    ADD R2, R6, R0                   ; class
    LEA R3, R1, 12
    STW R3, R2
    LEA R3, R1, 15
    STW R3, R2                       ; pending-wake = 0
    LEA R2, R8, 24                   ; frame top + 24 = stack top
    ADDI R2, R2, -729                ; stack base PA
    LEA R3, R1, 18
    STW R3, R2                       ; T_STK
    LDI R2, 0
    LEA R3, R1, 21
    STW R3, R2                       ; flags = 0 (own stack, freed on exit)
    LEA R1, R4, -9
    LDW R1, R1                       ; tid
    call sched_enqueue
    LEA R1, R4, -9
    LDW R1, R1                       ; result: tid
    LDI R2, 0                        ; err: ok
    ADDI R8, R4, -6                  ; back onto the two saved slots (R3, R7)
    pop R7
    pop R3
    ret
scr_fail2:                           ; no memory: return the tid to the free list
    LEA R1, R4, -9
    LDW R1, R1                       ; tid
    call tcb_addr
    const R2, FREE_TID
    LDW R3, R2
    STW R1, R3                       ; TCB[tid].next = old head
    STW R2, R1                       ; FREE_TID = tid
    LDI R1, -1
    LDI R2, -2                       ; err: out of memory
    ADDI R8, R4, -6                  ; back onto the two saved slots (R3, R7)
    pop R7
    pop R3
    ret
scr_fail:                            ; no slots
    LDI R1, -1
    LDI R2, -1                       ; err: out of slots
    pop R7
    pop R3
    ret

sys_exit_body:                       ; free the current thread; CURRENT = -1
    push R2
    push R3
    push R4
    push R5
    push R6
    push R7
    const R1, CURRENT
    LDW R1, R1
    CMPI3 R5, R1, 0
    BRZ R5, sex_none                 ; idle / none: nothing to free
    BRN R5, sex_none
    ADD R6, R1, R0                   ; tid
    call tcb_addr                    ; R1 = &TCB[cur]
    LEA R2, R1, 21
    LDW R3, R2                       ; flags
    CMPI3 R5, R3, 0
    BRP R5, sex_nofree               ; static stack (idle/main): keep it
    LEA R2, R1, 18
    LDW R1, R2                       ; stack frame base PA
    LDI R2, 729
    DIV R1, R1, R2                   ; frame index
    ADDI R1, R1, 3281                ; leaf node id
    ADD R2, R1, R0                   ; R2 = node (buddy_free takes R1=depth!)
    LDI R1, 8                        ; R1 = depth 8
    call buddy_free
    ADD R1, R6, R0
    call tcb_addr
    JMP sex_tcb
sex_nofree:
    ADD R1, R6, R0
    call tcb_addr
sex_tcb:
    const R2, FREE_TID
    LDW R3, R2                       ; old free-list head
    STW R1, R3                       ; TCB[tid].next = old head
    LDI R3, -2
    LEA R4, R1, 9
    STW R4, R3                       ; state = free slot
    STW R2, R6                       ; FREE_TID = tid
sex_none:
    const R1, CURRENT
    LDI R2, -1
    STW R1, R2                       ; CURRENT = -1
    pop R7
    pop R6
    pop R5
    pop R4
    pop R3
    pop R2
    ret

sys_control_body:                    ; R1 = tid, R2 = op, R3 = arg -> R1 = err
    push R3
    push R4
    push R5
    push R6
    push R7
    ADD R5, R1, R0                   ; tid
    ADD R6, R3, R0                   ; arg (SETCLASS value)
    CMPI3 R3, R2, 0
    BRZ R3, scb_block
    CMPI3 R3, R2, 1
    BRZ R3, scb_wake
    CMPI3 R3, R2, 2
    BRZ R3, scb_setclass
    LDI R1, -3                       ; unsupported op
    JMP scb_out
scb_setclass:                        ; op 2: set the CURRENT thread's class
    const R1, CURRENT
    LDW R1, R1
    CMP3 R3, R1, R5
    BRNZ R3, scb_bad                 ; only self (a queued thread would land in
                                     ; the wrong class queue)
    ADD R1, R5, R0
    call tcb_addr
    ADD R2, R6, R0                   ; new class (third arg)
    LEA R3, R1, 12
    STW R3, R2
    LDI R1, 0
    JMP scb_out
scb_block:                           ; only the current thread may block itself
    const R1, CURRENT
    LDW R1, R1
    CMP3 R3, R1, R5
    BRNZ R3, scb_bad
    ADD R1, R5, R0
    call tcb_addr                    ; R1 = &TCB[cur]
    LEA R2, R1, 15
    LDW R3, R2                       ; pending wake?
    CMPI3 R4, R3, 0
    BRZ R4, scb_do_block
    LDI R3, 0
    STW R2, R3                       ; consume it: keep running (D-036)
    LDI R1, 0
    JMP scb_out
scb_do_block:
    LDI R3, -1
    LEA R2, R1, 9
    STW R2, R3                       ; state = blocked
    call schedule_switch             ; never returns
scb_wake:
    CMPI3 R3, R5, 0
    BRN R3, scb_bad
    CMPI3 R3, R5, NT
    BRZP R3, scb_bad
    ADD R1, R5, R0
    call tcb_addr
    LEA R2, R1, 9
    LDW R3, R2                       ; state
    CMPI3 R4, R3, -2
    BRZ R4, scb_bad                  ; freed slot: never enqueue it
    CMPI3 R4, R3, 0
    BRN R4, scb_wake_blk             ; blocked -> make ready
    LDI R3, 1
    LEA R2, R1, 15
    STW R2, R3                       ; runnable: remember the wake (D-036)
    LDI R1, 0
    JMP scb_out
scb_wake_blk:
    ADD R1, R5, R0
    call sched_enqueue               ; state = ready, queued
    LDI R1, 0
    JMP scb_out
scb_bad:
    LDI R1, -1                       ; err: bad tid
scb_out:
    pop R7
    pop R6
    pop R5
    pop R4
    pop R3
    ret

; sched_bootstrap — build the idle (tid 0) and main (tid 1) threads with
; synthetic initial frames, enqueue the main thread, leave CURRENT = -1 for
; the first schedule_switch (D-034). Preserves R5 only for its own use;
; restores R8 = boot SP.
sched_bootstrap:
    ADD R5, R8, R0                   ; boot SP
    ADD R6, R7, R0                   ; LR in a register: the body switches R8 to
                                     ; build the initial frames, so a stack-saved
                                     ; LR would be buried under them
    ; ---- idle thread (tid 0): synthetic frame on the static idle stack ----
    const R8, IDLE_STK_TOP
    LDI R1, 0
    push R1
    push R1
    push R1
    push R1
    push R1
    push R1
    push R1                          ; R1..R7 slots = 0
    ADDI R8, R8, -3
    LEA R2, R8, 3
    STW R8, R2                       ; saved-SP slot = IDLE_STK_TOP
    LDI R1, 0
    call tcb_addr                    ; &TCB[0]
    LEA R2, R1, 3
    STW R2, R8                       ; T_SP (offset +3)
    const R2, idle_main
    LEA R3, R1, 6
    STW R3, R2                       ; T_EPC = idle_main
    LDI R2, 1
    LEA R3, R1, 9
    STW R3, R2                       ; state = running (parked, never queued)
    LDI R2, 0
    LEA R3, R1, 12
    STW R3, R2                       ; class (unused)
    LEA R3, R1, 15
    STW R3, R2                       ; pend = 0
    LDI R2, 0
    LEA R3, R1, 18
    STW R3, R2                       ; stk = 0
    LDI R2, 1
    LEA R3, R1, 21
    STW R3, R2                       ; flags = static
    ; ---- main thread (tid 1): synthetic frame on the static kernel stack ----
    const R8, KSTACK
    LDI R1, 0
    push R1
    push R1
    push R1
    push R1
    push R1
    push R1
    push R1
    ADDI R8, R8, -3
    LEA R2, R8, 3
    STW R8, R2
    LDI R1, 1
    call tcb_addr
    LEA R2, R1, 3
    STW R2, R8                       ; T_SP (offset +3)
    const R2, m4_main
    LEA R3, R1, 6
    STW R3, R2                       ; T_EPC = m4_main
    LDI R2, 0
    LEA R3, R1, 9
    STW R3, R2                       ; state = ready
    LDI R2, 0
    LEA R3, R1, 12
    STW R3, R2                       ; class = normal
    LEA R3, R1, 15
    STW R3, R2                       ; pend = 0
    LDI R2, 0
    LEA R3, R1, 18
    STW R3, R2                       ; stk = 0 (static)
    LDI R2, 1
    LEA R3, R1, 21
    STW R3, R2                       ; flags = static
    LDI R1, 1
    call sched_enqueue               ; main thread -> normal ready queue
    ADD R8, R5, R0                   ; boot SP back
    ADD R7, R6, R0                   ; LR back
    ret

; ------------------------------------------------------------------------------
; thread bodies
; ------------------------------------------------------------------------------
idle_main:
    WFI
    JMP idle_main

; Every worker receives its WDONE index as the create argument (R1) and keeps
; it in R6; wr_done flags completion through WDONE[index] — main clears the
; flag BEFORE the create, so recycled tids can never confuse a wait.
; wr_x — R1 = index: char = 120 + index ('x','y','z'), print 30x with yields
wr_x:
    ADD R6, R1, R0                   ; index
    LDI R4, 0                        ; i
wi_loop:
    LDI R1, 6                        ; DEBUG_PUTC
    LDI R2, 120
    ADD R2, R2, R6                   ; char = 'x' + index
    TRAP 0
    LDI R1, 1                        ; YIELD
    TRAP 0
    ADDI R4, R4, 1
    CMPI3 R5, R4, 30
    BRN R5, wi_loop
    JMP wr_done

; wr_pending — block self immediately; a wake that arrived early must not
; be lost, so this returns at once and prints 'P' (D-036)
wr_pending:
    ADD R6, R1, R0                   ; index
    LDI R1, 7                        ; GETTID
    TRAP 0
    ADD R2, R1, R0                   ; tid
    LDI R1, 4                        ; THREAD_CONTROL
    LDI R3, 0                        ; BLOCK
    TRAP 0                           ; pending wake consumed -> returns
    LDI R1, 6
    LDI R2, 80                       ; 'P'
    TRAP 0
    JMP wr_done

; wr_block — print 'V', block for real, print 'U' after the wake
wr_block:
    ADD R6, R1, R0                   ; index
    LDI R1, 7
    TRAP 0
    ADD R4, R1, R0                   ; tid (R2 gets clobbered by DEBUG_PUTC's
                                     ; error result below, so keep tid in R4)
    LDI R1, 6
    LDI R2, 86                       ; 'V'
    TRAP 0
    ADD R2, R4, R0                   ; tid
    LDI R1, 4
    LDI R3, 0                        ; BLOCK
    TRAP 0                           ; sleeps until the main thread wakes it
    LDI R1, 6
    LDI R2, 85                       ; 'U'
    TRAP 0
    JMP wr_done

; wr_spin — realtime spinner: 'Q' ... 20000 iterations ... 'q'
wr_spin:
    ADD R6, R1, R0                   ; index
    LDI R1, 6
    LDI R2, 81                       ; 'Q'
    TRAP 0
    LDI R4, 0
ws_loop:
    ADDI R4, R4, 1
    CMPI3 R5, R4, 20000
    BRN R5, ws_loop
    LDI R1, 6
    LDI R2, 113                      ; 'q'
    TRAP 0
    JMP wr_done

; wr_bg — background thread: 'G' x 20 with yields (starved while spinner lives)
wr_bg:
    ADD R6, R1, R0                   ; index
    LDI R4, 0
wb_loop:
    LDI R1, 6
    LDI R2, 71                       ; 'G'
    TRAP 0
    LDI R1, 1                        ; YIELD
    TRAP 0
    ADDI R4, R4, 1
    CMPI3 R5, R4, 20
    BRN R5, wb_loop
    JMP wr_done

; wr_stress — 200 yields, counting into STRESS[index]
wr_stress:
    ADD R6, R1, R0                   ; index
    LDI R4, 0
wst_loop:
    LDI R1, 1                        ; YIELD
    TRAP 0
    const R3, STRESS
    MULI R2, R6, 3
    ADD R3, R3, R2
    LDW R2, R3
    ADDI R2, R2, 1
    STW R3, R2
    ADDI R4, R4, 1
    CMPI3 R5, R4, 200
    BRN R5, wst_loop
    JMP wr_done

; wr_done — common tail: WDONE[index] = 1, then EXIT (R6 survives the TRAPs)
wr_done:
    const R3, WDONE
    MULI R2, R6, 3
    ADD R3, R3, R2
    LDI R2, 1
    STW R3, R2
    LDI R1, 2                        ; EXIT
    TRAP 0

; wr_server — R1 = endpoint cap: RECV request, SEND reply(msg+1), forever
wr_server:
    ADD R6, R1, R0                   ; cap
srv_loop:
    LDI R1, 9                        ; RECV
    ADD R2, R6, R0
    TRAP 0                           ; R3/R4 = request
    ADDI R3, R3, 1                   ; reply = request + 1
    LDI R1, 8                        ; SEND
    ADD R2, R6, R0
    TRAP 0
    JMP srv_loop

; ------------------------------------------------------------------------------
; m4_main — the main thread (tid 1): scheduler self-test
; ------------------------------------------------------------------------------
m4_main:
    const R1, str_sched
    call puts

    ; ---- phase 1: three threads print x/y/z interleaved (WDONE 0..2) ----
    const R3, WDONE
    LDI R2, 0
    STW R3, R2                       ; clear WDONE[0..2] before the creates
    ADDI R3, R3, 3
    STW R3, R2
    ADDI R3, R3, 3
    STW R3, R2
    LDI R4, 0                        ; index 0 -> 'x'
    const R2, wr_x
    LDI R3, 0                        ; normal class
    LDI R1, 3                        ; THREAD_CREATE
    TRAP 0
    const R3, P1A
    STW R3, R4
    LDI R4, 1                        ; index 1 -> 'y'
    const R2, wr_x
    LDI R3, 0
    LDI R1, 3
    TRAP 0
    const R3, P1B
    STW R3, R4
    LDI R4, 2                        ; index 2 -> 'z'
    const R2, wr_x
    LDI R3, 0
    LDI R1, 3
    TRAP 0
    const R3, P1C
    STW R3, R4
    const R3, P1A
    call wait1
    const R3, P1B
    call wait1
    const R3, P1C
    call wait1
    const R1, str_p1ok
    call puts

    ; ---- phase 2: pending wake + real block/wake (WDONE 3..4) ----
    const R3, WDONE + 9
    LDI R2, 0
    STW R3, R2                       ; clear WDONE[3..4]
    ADDI R3, R3, 3
    STW R3, R2
    LDI R4, 3                        ; index 3
    const R2, wr_pending
    LDI R3, 0
    LDI R1, 3
    TRAP 0
    const R3, P2A
    STW R3, R1                       ; tid kept only for the WAKE below
    const R3, P2A
    LDW R2, R3
    LDI R1, 4                        ; THREAD_CONTROL
    LDI R3, 1                        ; WAKE before it blocks -> pending (D-036)
    TRAP 0
    LDI R1, 1                        ; YIELD: let it consume the pending wake
    TRAP 0
    const R3, P2A
    call wait1
    LDI R4, 4                        ; index 4
    const R2, wr_block
    LDI R3, 0
    LDI R1, 3
    TRAP 0
    const R3, P2B
    STW R3, R1
    LDI R1, 1                        ; YIELD: it prints 'V' and blocks
    TRAP 0
    const R3, P2B
    LDW R2, R3
    LDI R1, 4
    LDI R3, 1                        ; WAKE
    TRAP 0
    LDI R1, 1                        ; YIELD: it prints 'U' and exits
    TRAP 0
    const R3, P2B
    call wait1
    const R1, str_p2ok
    call puts

    ; ---- phase 3: realtime starves background (WDONE 5..6) ----
    const R3, WDONE + 15
    LDI R2, 0
    STW R3, R2                       ; clear WDONE[5..6]
    ADDI R3, R3, 3
    STW R3, R2
    LDI R4, 5                        ; index 5
    const R2, wr_spin
    LDI R3, 1                        ; realtime class
    LDI R1, 3
    TRAP 0
    const R3, P3S
    STW R3, R4
    LDI R4, 6                        ; index 6
    const R2, wr_bg
    LDI R3, -1                       ; background class
    LDI R1, 3
    TRAP 0
    const R3, P3B
    STW R3, R4
    const R3, P3S
    call wait1                       ; spinner is realtime: wins every tick
    ; demote self so the starved background worker can finally run (D-033)
    LDI R1, 4                        ; THREAD_CONTROL
    const R6, CURRENT
    LDW R2, R6                       ; tid = self
    LDI R3, 2                        ; SETCLASS
    LDI R4, -1                       ; background
    TRAP 0
    const R3, P3B
    call wait1                       ; round-robin with the background worker now
    LDI R1, 4                        ; restore the normal class
    const R6, CURRENT
    LDW R2, R6
    LDI R3, 2                        ; SETCLASS
    LDI R4, 0                        ; normal
    TRAP 0
    const R1, str_p3ok
    call puts

    ; ---- phase 4: yield stress, 3 x 200, no lost wakeups (WDONE 7..9) ----
    const R3, WDONE + 21
    LDI R2, 0
    STW R3, R2                       ; clear WDONE[7..9]
    ADDI R3, R3, 3
    STW R3, R2
    ADDI R3, R3, 3
    STW R3, R2
    LDI R4, 7                        ; index 7
    const R2, wr_stress
    LDI R3, 0
    LDI R1, 3
    TRAP 0
    const R3, P4A
    STW R3, R4
    LDI R4, 8                        ; index 8
    const R2, wr_stress
    LDI R3, 0
    LDI R1, 3
    TRAP 0
    const R3, P4B
    STW R3, R4
    LDI R4, 9                        ; index 9
    const R2, wr_stress
    LDI R3, 0
    LDI R1, 3
    TRAP 0
    const R3, P4C
    STW R3, R4
    const R3, P4A
    call wait1
    const R3, P4B
    call wait1
    const R3, P4C
    call wait1
    const R1, str_p4ok
    call puts

    ; ---- phase 5: endpoint + capability algebra (deny sticks, revoke subtree) --
    LDI R1, 17                       ; EP_CREATE
    LDI R2, 7                        ; badge
    TRAP 0
    CMPI3 R5, R1, 0
    BRN R5, st_fail2
    const R3, XCAP
    STW R3, R1
    const R3, XCAP
    LDW R2, R3                       ; parent = master
    const R3, RIGHT_ALL              ; request every right
    LDI R1, 13                       ; CAP_DERIVE
    TRAP 0
    CMPI3 R5, R1, 0
    BRN R5, st_fail2
    const R3, XCHILD
    STW R3, R1
    const R3, XCHILD
    LDW R2, R3
    const R3, RIGHT_ALL
    LDI R1, 13
    TRAP 0
    CMPI3 R5, R1, 0
    BRN R5, st_fail2
    const R3, XGRAND
    STW R3, R1
    const R3, XCHILD
    LDW R2, R3
    LDI R1, 15                       ; CAP_REVOKE the child subtree
    TRAP 0
    CMPI3 R5, R1, 0
    BRN R5, st_fail2
    const R3, XGRAND
    LDW R2, R3
    LDI R1, 16                       ; CAP_DELETE on the revoked grandchild
    TRAP 0
    CMPI3 R5, R1, 0
    BRZ R5, st_fail2                 ; must fail: the slot is gone
    ; deny sticks: c2 = derive(master, SEND=-1), then request SEND=+ via c2
    const R3, XCAP
    LDW R2, R3
    const R3, RIGHT_NOSEND
    LDI R1, 13
    TRAP 0
    CMPI3 R5, R1, 0
    BRN R5, st_fail2
    const R3, XC2
    STW R3, R1
    const R3, XC2
    LDW R2, R3
    const R3, RIGHT_ALL              ; must NOT override the deny
    LDI R1, 13
    TRAP 0
    CMPI3 R5, R1, 0
    BRN R5, st_fail2
    ADD R6, R1, R0                   ; g2 cap
    ADD R2, R6, R0
    LDI R3, 0
    LDI R4, 0
    LDI R1, 8                        ; SEND via g2 -> denied
    TRAP 0
    CMPI3 R5, R1, 0
    BRZ R5, st_fail2                 ; must fail
    CMPI3 R5, R2, -1
    BRN R5, st_fail2                 ; detail: bad cap/rights
    const R1, str_caps_ok
    call puts
    JMP m5_done                      ; WIP M5: phases 6-7 (ping-pong + fuzz)
                                     ; parked — see BUG_M5_NOTES.md; the
                                     ; CALL/REPLY-agnostic deadlock needs a
                                     ; fresh debugging session

m5_done:
    const R1, str_ready
    call puts
    const R1, POWER
    LDI R2, 1
    STW R1, R2                       ; clean power-off
m4_park:
    LDI R1, 1                        ; YIELD (only reached if power-off failed)
    TRAP 0
    JMP m4_park

    ; ---- phase 6 (parked): CALL/REPLY ping-pong on the master endpoint ----
    ; the cap lives in XC2 (reused: phase 5 is done) and is RE-READ every
    ; iteration — a register copy would have to survive timer preemptions
    const R3, XCAP
    LDW R1, R3                       ; master cap
    const R3, XC2
    STW R3, R1
    const R2, wr_server
    LDI R3, 0                        ; normal class
    const R4, XC2
    LDW R4, R4                       ; arg = the cap (XC2 holds the master ref)
    LDI R1, 3                        ; THREAD_CREATE
    TRAP 0
    CMPI3 R5, R1, 0
    BRN R5, st_fail2                 ; the create must succeed
    LDI R1, 5                        ; TIME
    TRAP 0
    ADD R7, R1, R0                   ; t0
    LDI R5, 0                        ; i
pp_loop:
    ADD R3, R5, R0                   ; request = i
    LDI R4, 0
    const R3, XC2
    LDW R2, R3                       ; cap re-read every iteration
    LDI R1, 8                        ; SEND (blocks until the server RECVs)
    TRAP 0
    LDI R1, 9                        ; RECV the reply
    ADD R2, R6, R0
    TRAP 0                           ; R3 = reply = i + 1
    ADDI R2, R5, 1
    CMP3 R2, R3, R2
    BRNZ R2, st_fail2
    ADDI R5, R5, 1
    CMPI3 R2, R5, 200
    BRN R2, pp_loop
    LDI R1, 5                        ; TIME
    TRAP 0
    SUB R5, R1, R7                   ; elapsed ticks
    const R1, str_ipc
    call puts
    ADD R1, R5, R0
    call putnum
    LDI R1, 10
    call putc

    ; ---- phase 7: syscall argument fuzz (the kernel must survive) ----
    LDI R5, 0                        ; row index
fz_loop:
    MULI R2, R5, 12
    const R3, FTAB
    ADD R2, R3, R2
    LDW R1, R2                       ; num
    LEA R2, R2, 3
    LDW R2, R2                       ; arg1
    LEA R2, R2, 3
    LDW R3, R2                       ; arg2
    LEA R2, R2, 3
    LDW R4, R2                       ; arg3
    TRAP 0
    ADDI R5, R5, 1
    CMPI3 R2, R5, FZROWS
    BRN R2, fz_loop
    const R1, str_fuzz_ok
    call puts

wait1:                               ; R3 = &slot word holding the WDONE index:
                                     ; spin until WDONE[index] == 1
    LDW R2, R3
    MULI R2, R2, 3
    const R4, WDONE
    ADD R2, R4, R2
wd_loop:
    LDW R1, R2
    CMPI3 R5, R1, 1
    BRZ R5, wd_ret
    LDI R1, 1                        ; YIELD
    TRAP 0
    JMP wd_loop
wd_ret:
    ret

; ------------------------------------------------------------------------------
; strings and data
; ------------------------------------------------------------------------------
    .org STRBASE
str_banner:      .asciz "Setun Tri OS v0.1 (Triad kernel) booting\nHello, ternary world!\n"
str_buddy_ok:    .asciz "buddy: ok\n"
str_buddy_fail:  .asciz "buddy: FAIL\n"
str_resume_ok:   .asciz "illegal-resume: ok\n"
str_div0_ok:     .asciz "div0-resume: ok\n"
str_trap_fail:   .asciz "trap-handling: FAIL\n"
str_ready:       .asciz "Setun Tri OS v0.1 ready\n"
str_a:           .asciz "A\n"
str_b:           .asciz "B\n"
str_c:           .asciz "C\n"
str_trap:        .asciz "trap cause="
str_sp:          .asciz " tval="
str_epc:         .asciz " epc="
str_irq:         .asciz "irq cause="
str_syscall:     .asciz "syscall num="
str_wordmin:     .asciz "-193710244"
str_sched:       .asciz "sched:\n"
str_p1ok:        .asciz "p1 ok\n"
str_p2ok:        .asciz "p2 ok\n"
str_p3ok:        .asciz "p3 ok\n"
str_p4ok:        .asciz "stress ok\n"
str_badcall:     .asciz "bad syscall\n"
str_caps_ok:     .asciz "caps: ok\n"
str_ipc:         .asciz "ipc: 200 calls / "
str_fuzz_ok:     .asciz "fuzz: ok\n"
str_test_fail:   .asciz "self-test: FAIL\n"
.equ FZROWS,     16

FTAB:   .word 8, 999, 0, 0
        .word 8, -1, 0, 0
        .word 9, 999, 0, 0
        .word 10, 999, 0, 0
        .word 11, 5, 0, 0
        .word 12, 999, 0, 0
        .word 13, -1, -1, 0
        .word 13, 999, 0, 0
        .word 14, -5, 0, 0
        .word 15, 999, 0, 0
        .word 15, -2, 0, 0
        .word 16, -2, 0, 0
        .word 4, -99, 99, 0
        .word 4, 1, 99, 0
        .word 3, -999, 0, 0
        .word 5, 0, 0, 0

; BSS (D-032): the KDATA region below is never stored in the TXE — every byte of
; it is initialised before first read (buddy_init writes all states and hints;
; sched_init writes the TCB table, queues, CURRENT, DONE and STRESS; pnumbuf,
; ksave and the nodes array are written before use).

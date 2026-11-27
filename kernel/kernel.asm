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
    .equ UART_RX,   MMIO+3
    .equ UART_STAT, MMIO+6
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
    .equ RES_END,    1508               ; frames [0, 1508) reserved: static data
                                        ; (TCBs, queues, idle stack, M4T, CTAB,
                                        ; EPT, fs buffers, M8 namespace area).
                                        ; frames 1415/1416 are the fs free-list
                                        ; and block buffers (TriFS), 1417..1419
                                        ; the M8 name table + file buffer.
                                        ; D-043: fs frames must sit below
                                        ; RES_END or thread stacks corrupt them
    .equ BB2,       1415 * 729          ; 729-tryte free-list IO buffer (keeps
                                        ; BBUF intact while dir_upd stages a clone)
    .equ BBUF,      1416 * 729          ; 729-tryte block buffer (TriFS)
    .equ FB_RAM,    1420 * 729          ; framebuffer: 320x200, 1 tryte/pixel
    .equ FB_H,      200                 ; (frames 1420..1507, 88 frames)
    .equ FB_W,      320
    .equ FB_ROW,    320                 ; trytes per row
    .equ FS_BASE,   28                  ; TriFS superblock block (D-042)
    .equ SB_FREE,   9                   ; superblock word offsets: free head
    .equ SB_ROOT,   12                  ; COW dir-chain root
    .equ SB_GEN,    15                  ; snapshot generation
    .equ SB_SUM,    18                  ; superblock checksum word
    .equ DIR_REFS,  241                 ; refs per dir block (6+241*3 = 729)
    .equ DIR_LEVELS, 5                  ; fixed dir-chain depth: 5*241 = 1205
                                        ; slots >= the 1000-file workload, so
                                        ; per-block counts never change and a
                                        ; mid-workload crash still exposes a
                                        ; full 1000-slot ref vector (host fsck)
    .equ FS_MAGIC,  123456789           ; superblock magic
    .equ FS_NB,     2200                ; fs-region block count (incl. super)
    .equ BLK_LBA,   MMIO+12
    .equ BLK_BUF,   MMIO+15
    .equ BLK_CMD,   MMIO+18
    .equ BLK_STAT,  MMIO+21
    .equ STK_LO,     6446
    .equ STK_HI,     6448
    .equ KSTACK,     4700001
    .equ FREE_FRAMES, 5050              ; 6561 - 1508(reserved) - 3(stack)
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
    .equ LLEN,      EPT + 162           ; shell: line length in trytes
    .equ LBUF,      EPT + 165           ; shell: line buffer, 93 trytes (92
                                        ; chars max + NUL: a line like
                                        ; "cp docs/notes docs/notes2" is 25
                                        ; chars and the old 24-tryte buffer
                                        ; silently dropped the last char);
                                        ; ends inside reserved frame 1414
    .equ FS_OKFLAG, EPT + 258           ; 0 = fs usable, 1 = device too small
    .equ XFS,       EPT + 261           ; fs endpoint cap (word-aligned!)
    .equ FS_CAP,    EPT + 264           ; fs server's own cap, parked in MEMORY
                                        ; (D-041): R6 is scratch for the format
    .equ SNAP_ROOT, EPT + 267           ; parked (root, gen) pair for the M7
    .equ SNAP_GEN,  EPT + 270           ; SNAPSHOT ops 13/14 (save/restore)
    .equ SNAP_TEST, EPT + 273           ; init snapshot-demo parking slot
    .equ SNAP_ARMED, EPT + 276          ; != 0: dir_upd leaks the old chain
                                        ; (the saved tree shares its blocks)
                                        ; loop and every op handler, so the cap
                                        ; is re-read from here before each IPC

; ---- M8 namespace work area (reserved frames 1417..1419, D-047) ---------------
    .equ M8WORK,    1417 * 729          ; parked fs-op args (only the shell and
                                        ; the boot M8 phase call these ops, so
                                        ; fixed slots need no locking):
                                        ; len @+0, dir flag @+3, count @+6
    .equ M8LEN,     M8WORK
    .equ M8DIR,     M8WORK + 3
    .equ M8CNT,     M8WORK + 6
    .equ NTS,       M8WORK + 12         ; name table: 48 entries x 30 trytes
                                        ; [index word, flags word (0 free, 1
                                        ; file, 2 dir), name <= 24 trytes
                                        ; NUL-terminated]; linear scan
    .equ NTE,       30                  ; name-table entry size (trytes)
    .equ NTCNT,     48                  ; entry count (fits frames 1417+1418)
    .equ FBUF,      1419 * 729          ; 729-tryte file-content buffer: ed/cat/
                                        ; cp staging, name strings, LIST output,
                                        ; TXE handoff — below RES_END, so thread
                                        ; stacks can never take these frames

; ---- M8 program region (D-046): EXEC maps TXE segments here -------------------
    .equ PROG_BASE, 4700100             ; above the kernel trap stack (KSTACK)
    .equ PROG_TOP,  4782969             ; exclusive RAM top (3^14 trytes)
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

    ; ---- framebuffer boot pattern (M11): RAM-backed FB at FB_RAM, 1 tryte
    ; per pixel; the host UI renders it live. Border + title bars.
    LDI R3, 0                         ; y
fbp_row:
    MULI R4, R3, FB_ROW               ; row base offset
    const R1, FB_RAM
    ADD R4, R1, R4                    ; R4 = &FB_RAM[y][0]
    LDI R5, 0                         ; color: 0 = dark
    CMPI3 R1, R3, 2
    BRN R1, fbp_lit
    CMPI3 R1, R3, 198
    BRZP R1, fbp_lit
    CMPI3 R1, R3, 10
    BRN R1, fbp_dark
    CMPI3 R1, R3, 14
    BRN R1, fbp_lit
    JMP fbp_dark
fbp_lit:
    LDI R5, 1
fbp_dark:
    ADD R1, R5, R0
    LDI R2, 0                         ; x
fbp_x:
    STT R4, R1                        ; FB_RAM[y][x] = color
    ADDI R4, R4, 1
    ADDI R2, R2, 1
    CMPI3 R6, R2, FB_W
    BRN R6, fbp_x
    ADDI R3, R3, 1
    CMPI3 R6, R3, FB_H
    BRN R6, fbp_row
    ; side columns: x = 0..1 and 318..319 lit on every row
    LDI R3, 0
fbp_side:
    MULI R4, R3, FB_ROW
    const R1, FB_RAM
    ADD R4, R1, R4
    LDI R1, 1
    STT R4, R1
    ADDI R4, R4, 1
    STT R4, R1
    ADDI R4, R4, 316
    STT R4, R1
    ADDI R4, R4, 1
    STT R4, R1
    ADDI R3, R3, 1
    CMPI3 R6, R3, FB_H
    BRN R6, fbp_side
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
    ; device IRQ: the block device (12) completes synchronously, so resume
    ; silently; any other device prints a diagnostic and resumes
    CSRR R1, CAUSE
    CMPI3 R5, R1, 12
    BRZ R5, th_resume
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
    CMPI3 R5, R1, 18
    BRZ R5, sys_getchar
    CMPI3 R5, R1, 19
    BRZ R5, sys_exec
    CMPI3 R5, R1, 20
    BRZ R5, sys_ps
    CMPI3 R5, R1, 21
    BRZ R5, sys_tstat
    CMPI3 R5, R1, 22
    BRZ R5, sys_kill
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
    push R7                          ; the tcb_addr call below clobbers the LR;
                                     ; without this, ret (JR R7) jumps back
                                     ; INTO this function's middle (D-040 note)
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
    pop R7
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
    LEA R3, R4, EE_CALLER
    const R2, CURRENT
    LDW R2, R2
    STW R3, R2                       ; endpoint caller = me: the server's
                                     ; REPLY must find the blocked caller
                                     ; (this write was missing and deadlocked
                                     ; every blocked CALL — the "CALL/REPLY
                                     ; deeper bug")
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

sys_getchar:                         ; num 18: -> R1 = char tryte, 0 = none.
                                     ; Yield-poll: an empty UART re-queues the
                                     ; caller so the shell is scheduler-fair.
    const R2, UART_STAT
    LDT R3, R2                       ; tryte: nonzero = input pending
    BRZ R3, sg_yield
    const R2, UART_RX
    LDT R3, R2                       ; char tryte (TriText page value)
    LEA R5, R8, 21
    STW R5, R3                       ; result R1 = char
    JMP th_resume
sg_yield:
    call sched_requeue_cur
    call schedule_switch             ; never returns

; ---- M8 syscalls (19..22): loader + process introspection --------------------

sys_exec:                            ; frame: idx +18 (R2 = fs file index)
    LEA R1, R8, 18
    LDW R1, R1                       ; idx
    call exec_load                   ; -> R1 = entry or negative status
    CMPI3 R5, R1, 0
    BRN R5, ex_fail
    ; entry in R1: write it into the frame as THREAD_CREATE's fn and fall
    ; through to the standard create path (class = 0, arg = 0). sys_create
    ; stores the tid into the same result slot the caller reads.
    LEA R3, R8, 18
    STW R3, R1                       ; frame R2 slot = fn
    LDI R1, 0
    LEA R3, R8, 15
    STW R3, R1                       ; class = 0
    LEA R3, R8, 12
    STW R3, R1                       ; arg = 0
    JMP sys_create
ex_fail:
    LEA R3, R8, 21
    STW R3, R1                       ; result = status (negative)
    LDI R1, -1
    LEA R3, R8, 18
    STW R3, R1                       ; err
    JMP th_resume

exec_load:                           ; R1 = idx -> R1 = entry or -2/-3 (clobbers
    push R7                          ; R2..R5; v0.1: single-extent, one segment)
    ADD R3, R1, R0                   ; idx
    push R3                          ; idx [R8]
    ADD R1, R3, R0
    call fs_lookup                   ; R1 = h_ref or 0 (clobbers R2..R5)
    CMPI3 R5, R1, 0
    BRZ R5, el_miss
    call blk_read                    ; header -> BBUF
    const R2, BBUF + 6
    LDW R2, R2                       ; ext count
    CMPI3 R5, R2, 0
    BRZ R5, el_miss
    const R2, BBUF + 9
    LDW R1, R2                       ; ext[0] = data lba
    call blk_read                    ; TXE image -> BBUF
    ; magic 'SETUN1' (trytes 83,69,84,85,78,49)
    const R2, BBUF
    LDT R3, R2
    CMPI3 R5, R3, 83
    BRNZ R5, el_bad
    const R2, BBUF + 1
    LDT R3, R2
    CMPI3 R5, R3, 69
    BRNZ R5, el_bad
    const R2, BBUF + 2
    LDT R3, R2
    CMPI3 R5, R3, 84
    BRNZ R5, el_bad
    const R2, BBUF + 3
    LDT R3, R2
    CMPI3 R5, R3, 85
    BRNZ R5, el_bad
    const R2, BBUF + 4
    LDT R3, R2
    CMPI3 R5, R3, 78
    BRNZ R5, el_bad
    const R2, BBUF + 5
    LDT R3, R2
    CMPI3 R5, R3, 49
    BRNZ R5, el_bad
    ; entry: word at trytes 8..10 — tryte offset 8 is NOT word-aligned, so
    ; assemble the word from three tryte loads (a*3^12 + b*3^6 + c), as the
    ; boot sector does for the same format (D-047)
    const R2, BBUF + 8
    LDT R6, R2                      ; high tryte
    const R7, 531441                ; 3^12
    MUL R6, R6, R7
    LEA R2, R2, 1
    LDT R3, R2                      ; middle tryte
    const R7, 729                   ; 3^6
    MUL R3, R3, R7
    ADD R6, R6, R3
    LEA R2, R2, 1
    LDT R3, R2                      ; low tryte
    ADD R3, R6, R3                  ; entry
    const R2, PROG_BASE
    CMP3 R5, R3, R2
    BRN R5, el_bad
    const R2, PROG_TOP
    CMP3 R5, R3, R2
    BRP R5, el_bad
    ; park the entry BEFORE the segment checks reuse the scratch registers:
    ; the segcount LDT and the range CMP3s would otherwise destroy it
    ; (the original bug: the thread was created at addr+len instead — D-048)
    push R3                          ; entry [R8]; idx -> +3, LR -> +6
    ; one segment: addr @12, len @15, data @18 (v0.1: exactly one segment)
    const R2, BBUF + 11
    LDT R3, R2                       ; segment count (tryte)
    CMPI3 R5, R3, 1
    BRP R5, el_bad3
    const R2, BBUF + 12
    LDW R4, R2                       ; seg load address
    const R2, BBUF + 15
    LDW R5, R2                       ; seg length (trytes)
    const R3, PROG_BASE
    CMP3 R6, R4, R3                  ; addr < PROG_BASE -> bad (R6, so the
    BRN R6, el_bad3                  ; length in R5 survives for the copy)
    ADD R6, R4, R5                   ; addr + len
    const R2, PROG_TOP
    CMP3 R6, R6, R2
    BRP R6, el_bad3
    LDI R1, 0                        ; j
el_cp:
    CMP3 R3, R1, R5                  ; j >= len -> done
    BRZP R3, el_done
    const R2, BBUF + 18
    ADD R2, R2, R1
    LDT R3, R2                       ; tryte
    ADD R2, R4, R1                   ; dest tryte address = addr + j
    STT R2, R3
    ADDI R1, R1, 1
    JMP el_cp
el_done:
    pop R1                           ; entry
    pop R2                           ; drop idx
    pop R7                           ; LR — `ret` is JR R7, the LR must land
    ret                              ; back in R7 (was popped into R3: wild jump)
el_bad3:                             ; failed with the entry already parked
    pop R2                           ; drop entry
    JMP el_bad                       ; el_bad drops idx + LR
el_miss:
    LDI R1, -2                       ; no such file / empty
    pop R2                           ; drop idx
    pop R7                           ; LR
    ret
el_bad:
    LDI R1, -3                       ; bad image / outside the program region
    pop R2                           ; drop idx
    pop R7                           ; LR
    ret

sys_ps:                              ; frame: buf +18, max +15
    LEA R1, R8, 18
    LDW R1, R1                       ; buf
    LEA R2, R8, 15
    LDW R2, R2                       ; max
    call ps_fill                     ; R1 = count (stack-neutral)
    LEA R3, R8, 21
    STW R3, R1                       ; result = count
    LDI R1, 0
    LEA R3, R8, 18
    STW R3, R1                       ; err = 0
    JMP th_resume

ps_fill:                             ; R1 = buf, R2 = max -> R1 = count; fills
    push R7                          ; (tid, state, class) words per live thread
    push R1                          ; buf  -> [R8+9]
    push R2                          ; max  -> [R8+6]
    push R0                          ; pos  -> [R8+3] = 0
    LDI R1, 0
    push R1                          ; tid  -> [R8+0]
pf_loop:
    LDW R1, R8                       ; tid
    CMPI3 R5, R1, NT
    BRZP R5, pf_done
    call tcb_addr                    ; R1 = &TCB[tid] (preserves R2..R6)
    LEA R2, R1, 9
    LDW R3, R2                       ; state
    CMPI3 R5, R3, -2
    BRZ R5, pf_next
    LEA R4, R8, 9
    LDW R4, R4                       ; buf
    LEA R5, R8, 3
    LDW R5, R5                       ; pos
    MULI R6, R5, 9
    ADD R4, R4, R6                   ; R4 = &entry
    LDW R6, R8                       ; tid
    STW R4, R6                       ; entry[0] = tid
    ADDI R4, R4, 3
    STW R4, R3                       ; entry[1] = state
    LEA R5, R1, 12
    LDW R5, R5                       ; class
    ADDI R4, R4, 3
    STW R4, R5                       ; entry[2] = class
    LEA R5, R8, 3
    LDW R6, R8                       ; pos
    ADDI R6, R6, 1
    STW R5, R6                       ; pos++
    LEA R5, R8, 6
    LDW R5, R5                       ; max
    CMP3 R5, R6, R5                  ; pos >= max -> done
    BRZP R5, pf_done
pf_next:
    LDW R5, R8                       ; tid
    ADDI R5, R5, 1
    STW R8, R5                       ; tid++
    JMP pf_loop
pf_done:
    LEA R5, R8, 3
    LDW R1, R5                       ; count = pos
    ADDI R8, R8, 12                  ; drop buf/max/pos/tid
    pop R7
    ret

sys_tstat:                           ; frame: tid +18 -> R1 = state, R2 = class
    LEA R1, R8, 18
    LDW R1, R1                       ; tid
    CMPI3 R5, R1, 0
    BRN R5, ts_bad
    CMPI3 R5, R1, NT
    BRZP R5, ts_bad
    call tcb_addr                    ; R1 = &TCB
    LEA R2, R1, 9
    LDW R3, R2                       ; state
    CMPI3 R5, R3, -2
    BRZ R5, ts_bad
    LEA R2, R1, 12
    LDW R4, R2                       ; class
    LEA R2, R8, 21
    STW R2, R3                       ; result R1 = state
    LEA R2, R8, 18
    STW R2, R4                       ; R2 = class
    JMP th_resume
ts_bad:
    LDI R3, -1
    LEA R2, R8, 21
    STW R2, R3                       ; result = -1
    LDI R3, -1
    LEA R2, R8, 18
    STW R2, R3                       ; err = -1
    JMP th_resume

sys_kill:                            ; frame: tid +18 -> 0 ok, -1 refused
    LEA R1, R8, 18
    LDW R1, R1                       ; tid
    CMPI3 R5, R1, 0
    BRN R5, kl_bad
    CMPI3 R5, R1, NT
    BRZP R5, kl_bad
    const R3, CURRENT
    LDW R3, R3
    CMP3 R5, R1, R3
    BRZ R5, kl_self                  ; killing yourself = a clean exit
    push R1                          ; tid [R8]
    call tcb_addr                    ; R1 = &TCB[tid]
    LEA R2, R1, 9
    LDW R3, R2                       ; state
    CMPI3 R5, R3, 0
    BRNZ R5, kl_badp                 ; v0.1 (D-048): only READY threads are
                                     ; killable — a blocked thread may be
                                     ; linked in an endpoint wait queue that
                                     ; a free slot would corrupt
    LEA R2, R1, 12
    LDW R4, R2                       ; class
    LDW R1, R8                       ; tid
    ADD R2, R4, R0
    call kill_unlink                 ; out of the class ready queue
    LDW R1, R8                       ; tid
    call kill_reap                   ; free stack + TCB slot
    pop R1                           ; balanced
    LDI R3, 0
    LEA R2, R8, 21
    STW R2, R3                       ; result = 0
    LDI R3, 0
    LEA R2, R8, 18
    STW R2, R3                       ; err = 0
    JMP th_resume
kl_self:
    JMP sys_exit                     ; reuse the clean self-termination path
kl_bad:                              ; nothing parked yet
    LDI R3, -1
    LEA R2, R8, 21
    STW R2, R3
    LDI R3, -1
    LEA R2, R8, 18
    STW R2, R3
    JMP th_resume
kl_badp:                             ; tid parked: drop it first
    pop R1
    LDI R3, -1
    LEA R2, R8, 21
    STW R2, R3
    LDI R3, -1
    LEA R2, R8, 18
    STW R2, R3
    JMP th_resume

kill_unlink:                         ; R1 = tid, R2 = class -> unlink from the
    push R7                          ; class ready queue (stack-neutral;
    push R1                          ; clobbers R1..R5; R6 = prev survives
    push R2                          ; tcb_addr, which preserves R2..R6)
    ADDI R3, R2, 1                   ; qidx 0..2
    MULI R3, R3, 6
    const R4, QHEADS
    ADD R4, R4, R3                   ; &head[qidx]
    LDW R3, R4                       ; head
    LDI R6, 0                        ; prev tid
ku_loop:
    CMPI3 R5, R3, 0
    BRZ R5, ku_done                  ; not linked: nothing to do
    CMP3 R5, R3, R1
    BRZ R5, ku_found
    ADD R6, R3, R0                   ; prev = node
    ADD R1, R3, R0
    call tcb_addr                    ; R1 = &TCB[node] (preserves R2..R6)
    LDW R3, R1                       ; next (T_NEXT @+0)
    JMP ku_loop
ku_found:
    ADD R1, R3, R0
    call tcb_addr                    ; R1 = &TCB[target]
    LDW R2, R1                       ; next
    CMP3 R5, R6, R0
    BRNZ R5, ku_mid
    STW R4, R2                       ; head = next
    JMP ku_tail
ku_mid:
    ADD R1, R6, R0
    call tcb_addr                    ; R1 = &TCB[prev]
    STW R1, R2                       ; prev.next = next
ku_tail:
    LEA R3, R8, 3
    LDW R3, R3                       ; class
    ADDI R3, R3, 1
    MULI R3, R3, 6
    const R5, QHEADS
    ADD R5, R5, R3
    ADDI R5, R5, 3                   ; &tail[qidx]
    LDW R3, R5                       ; tail
    LDW R4, R8                       ; target tid
    CMP3 R6, R3, R4
    BRNZ R6, ku_done
    CMP3 R6, R6, R0                  ; tail == target: tail = prev, or next
    BRZ R6, ku_tnext                 ; when the queue drains (prev = 0)
    ADD R3, R6, R0
    STW R5, R3                       ; tail = prev
    JMP ku_done
ku_tnext:
    STW R5, R2                       ; tail = next (0 when the queue drained)
ku_done:
    pop R2
    pop R1
    pop R7
    ret

kill_reap:                           ; R1 = tid -> free stack + TCB slot
    push R2                          ; (generalized sys_exit_body reaping;
    push R3                          ; stack-neutral; clobbers R2..R6)
    push R4
    push R5
    push R6
    push R7
    ADD R6, R1, R0                   ; tid
    call tcb_addr                    ; R1 = &TCB[tid]
    LEA R2, R1, 21
    LDW R3, R2                       ; flags
    CMPI3 R5, R3, 0
    BRP R5, kr_nofree                ; static stack (idle/main): keep it
    LEA R2, R1, 18
    LDW R1, R2                       ; stack frame base PA
    LDI R2, 729
    DIV R1, R1, R2                   ; frame index
    ADDI R1, R1, 3281                ; leaf node id
    ADD R2, R1, R0                   ; R2 = node (buddy_free takes R1 = depth!)
    LDI R1, 8
    call buddy_free
    ADD R1, R6, R0
    call tcb_addr
    JMP kr_tcb
kr_nofree:
    ADD R1, R6, R0
    call tcb_addr
kr_tcb:
    const R2, FREE_TID
    LDW R3, R2                       ; old free-list head
    STW R1, R3                       ; TCB[tid].next = old head
    LDI R3, -2
    LEA R4, R1, 9
    STW R4, R3                       ; state = free slot
    STW R2, R6                       ; FREE_TID = tid
    pop R7
    pop R6
    pop R5
    pop R4
    pop R3
    pop R2
    ret

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
    ; validate the arguments: fn must point into the kernel text segment OR
    ; the M8 program region (EXEC-loaded TXE image, D-046); class must be a
    ; trit (-1/0/+1); anything else is a clean error
    CMPI3 R3, R5, KERNEL_LOAD
    BRN R3, scr_fail
    const R2, STRBASE
    CMP3 R3, R5, R2
    BRZP R3, scr_prog                ; above the text segment: maybe the prog
                                     ; region — check, else fail
scr_class:
    CMPI3 R3, R6, -1
    BRN R3, scr_fail
    CMPI3 R3, R6, 1
    BRP R3, scr_fail
    JMP scr_go
scr_prog:
    const R2, PROG_BASE
    CMP3 R3, R5, R2
    BRN R3, scr_fail
    const R2, PROG_TOP
    CMP3 R3, R5, R2
    BRP R3, scr_fail
scr_go:
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

; wr_consv — R1 = console cap: RECV a char, print it; request -1 = panic (EXIT)
wr_consv:
    ADD R6, R1, R0                   ; console cap
cs_loop:
    LDI R1, 9                        ; RECV
    ADD R2, R6, R0
    TRAP 0                           ; R3 = char
    CMPI3 R5, R3, -1
    BRZ R5, cs_panic
    const R2, UART_TX
    STT R2, R3                       ; print the char (the console owns the UART)
    JMP cs_loop
cs_panic:
    LDI R1, 2                        ; EXIT
    TRAP 0
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

pipe_writer:                         ; R1 = pipe cap: SEND the demo line, exit.
                                     ; The shell RECVs it — the endpoint is the
                                     ; v0.1 pipe (one message in flight).
    ADD R6, R1, R0                   ; cap (survives SEND/RECV traps)
    const R5, str_pipedata
pwp_loop:
    LDT R3, R5                       ; char
    BRZ R3, pwp_nl
    ADD R1, R3, R0                   ; msg1 = char
    ADD R2, R6, R0                   ; cap
    LDI R1, 8                        ; SEND
    TRAP 0
    ADDI R5, R5, 1
    JMP pwp_loop
pwp_nl:
    LDI R3, 10                       ; newline
    ADD R1, R3, R0
    ADD R2, R6, R0
    LDI R1, 8                        ; SEND
    TRAP 0
    LDI R1, 2                        ; EXIT
    TRAP 0

; ------------------------------------------------------------------------------
; shell_main — M6 interactive shell (a normal user thread). Prints a prompt,
; reads a line through GETCHAR (yield-poll inside the syscall), then runs the
; builtins: help | ver | echo <text> | crash | halt.
; echo routes the text through the console server via SEND (the IPC demo);
; crash NBSENDs the panic request and restarts the console server on the same
; endpoint; halt powers the machine off.
; ------------------------------------------------------------------------------
shell_main:
    const R1, str_shello
    call puts
sh_loop:
    const R1, str_prompt
    call puts
    LDI R1, 0
    const R2, LLEN
    STW R2, R1                       ; LLEN = 0
sh_read:
    LDI R1, 18                       ; GETCHAR (yield-poll when idle)
    TRAP 0                           ; R1 = char tryte
    BRZ R1, sh_read                  ; nothing typed yet
    ADD R3, R1, R0
    call putc                        ; echo the keystroke
    CMPI3 R5, R1, 10                 ; newline ends the line
    BRZ R5, sh_exec
    const R2, LLEN
    LDW R3, R2                       ; len
    CMPI3 R5, R3, 92
    BRZP R5, sh_read                 ; buffer full: swallow the tail
    const R4, LBUF
    ADD R4, R4, R3                   ; &LBUF[len] (tryte addressing)
    STT R4, R1                       ; store the char tryte
    ADDI R3, R3, 1
    STW R2, R3                       ; len += 1
    JMP sh_read
sh_exec:
    const R2, LLEN
    LDW R3, R2
    const R4, LBUF
    ADD R4, R4, R3
    LDI R6, 0
    STT R4, R6                       ; NUL-terminate (an empty line must not
                                     ; match against a stale previous line)
    const R1, LBUF
    const R2, str_cmd_help
    call str_eq
    CMPI3 R5, R3, 1
    BRZ R5, sh_help
    const R1, LBUF
    const R2, str_cmd_ver
    call str_eq
    CMPI3 R5, R3, 1
    BRZ R5, sh_ver
    const R1, LBUF
    const R2, str_cmd_crash
    call str_eq
    CMPI3 R5, R3, 1
    BRZ R5, sh_crash
    const R1, LBUF
    const R2, str_cmd_halt
    call str_eq
    CMPI3 R5, R3, 1
    BRZ R5, sh_halt
    ; ---- M8 coreutils dispatch ----
    const R1, LBUF
    const R2, str_cmd_ls
    call str_eq
    CMPI3 R5, R3, 1
    BRZ R5, sh_ls
    const R1, LBUF
    const R2, str_cmd_ps
    call str_eq
    CMPI3 R5, R3, 1
    BRZ R5, sh_ps
    const R1, LBUF
    const R2, str_cmd_pipe
    call str_eq
    CMPI3 R5, R3, 1
    BRZ R5, sh_pipe
    const R1, LBUF
    const R2, str_cmd_cat
    call sh_pfx
    CMPI3 R5, R3, 1
    BRZ R5, sh_cat
    const R1, LBUF
    const R2, str_cmd_ed
    call sh_pfx
    CMPI3 R5, R3, 1
    BRZ R5, sh_ed
    const R1, LBUF
    const R2, str_cmd_rm
    call sh_pfx
    CMPI3 R5, R3, 1
    BRZ R5, sh_rm
    const R1, LBUF
    const R2, str_cmd_cp
    call sh_pfx
    CMPI3 R5, R3, 1
    BRZ R5, sh_cp
    const R1, LBUF
    const R2, str_cmd_mkdir
    call sh_pfx
    CMPI3 R5, R3, 1
    BRZ R5, sh_mkdir
    const R1, LBUF
    const R2, str_cmd_tstat
    call sh_pfx
    CMPI3 R5, R3, 1
    BRZ R5, sh_tstat
    const R1, LBUF
    const R2, str_cmd_kill
    call sh_pfx
    CMPI3 R5, R3, 1
    BRZ R5, sh_kill
    const R1, LBUF
    const R2, str_cmd_exec
    call sh_pfx
    CMPI3 R5, R3, 1
    BRZ R5, sh_execprog
    ; "echo " prefix? (5 trytes must match exactly)
    const R1, LBUF
    const R2, str_cmd_echo
    LDI R5, 0                        ; i
shp_loop:
    ADD R3, R1, R5
    LDT R4, R3                       ; line[i]
    ADD R3, R2, R5
    LDT R6, R3                       ; cmd[i]
    CMP3 R6, R4, R6                  ; R6 = sign(line[i] - cmd[i])
    BRNZ R6, sh_unknown
    ADDI R5, R5, 1
    CMPI3 R6, R5, 5                  ; 5 chars (tryte addressing: +1 per char)
    BRN R6, shp_loop
sh_echo:
    LDI R5, 5                        ; i = tryte 5 (after "echo ")
    const R2, LLEN
    LDW R4, R2                       ; len (trytes)
    const R2, XGRAND
    LDW R2, R2                       ; console cap
sh_echo2:
    CMP3 R6, R5, R4                  ; i >= len -> done
    BRZP R6, sh_echo_nl
    const R3, LBUF
    ADD R3, R3, R5
    LDT R6, R3                       ; char
    ADD R3, R6, R0                   ; msg1 = char
    const R2, XGRAND
    LDW R2, R2                       ; cap re-read EVERY iteration: a completed
                                     ; SEND zeroes R1/R2 in the returned frame
                                     ; (ipc_ok), so R2 must be reloaded
    LDI R1, 8                        ; SEND
    TRAP 0
    ADDI R5, R5, 1
    JMP sh_echo2
sh_echo_nl:
    const R2, XGRAND
    LDW R2, R2
    LDI R3, 10                       ; newline
    LDI R1, 8                        ; SEND
    TRAP 0
    JMP sh_loop
sh_unknown:
    const R1, str_unknown
    call puts
    JMP sh_loop
sh_help:
    const R1, str_help
    call puts
    JMP sh_loop
sh_ver:
    const R1, str_ver
    call puts
    JMP sh_loop
sh_crash:
    const R2, XGRAND
    LDW R2, R2
    LDI R3, -1                       ; panic request
    LDI R1, 12                       ; NBSEND: the server takes it and exits
    TRAP 0
    ; restart the console server on the same endpoint (supervisor behaviour)
    const R2, wr_consv
    const R4, XGRAND
    LDW R4, R4                       ; arg = console cap
    LDI R3, 0                        ; class = normal (loaded LAST)
    LDI R1, 3
    TRAP 0                           ; THREAD_CREATE
    LDI R1, 1
    TRAP 0                           ; YIELD: let the new server RECV-block
    const R1, str_conrestart
    call puts
    JMP sh_loop
sh_halt:
    const R1, POWER
    LDI R2, 1
    STW R1, R2                       ; power off
    JMP sh_loop

; ---- M8 coreutils (D-047) -----------------------------------------------------

sh_pfx:                              ; R1 = line, R2 = prefix -> R3 = 1 if the
    push R7                          ; line starts with prefix AND continues
    push R1                          ; with a space; R4 = arg tryte offset
    push R2                          ; (clobbers R1, R2, R4..R6)
    LDI R5, 0                        ; i
spx_loop:
    ADD R3, R1, R5
    LDT R4, R3                       ; line[i]
    ADD R3, R2, R5
    LDT R6, R3                       ; prefix[i]
    BRZ R6, spx_end                  ; prefix consumed
    CMP3 R6, R4, R6
    BRNZ R6, spx_no
    ADDI R5, R5, 1
    JMP spx_loop
spx_end:
    ADD R1, R1, R5
    LDT R6, R1                       ; line[len]
    CMPI3 R4, R6, 32                 ; a space must follow (R4 is free here;
    BRNZ R4, spx_no                  ; R5 still holds the prefix length)
    ADDI R4, R5, 1                   ; arg offset = len + 1
    pop R2
    pop R1
    LDI R3, 1
    pop R7
    ret
spx_no:
    pop R2
    pop R1
    LDI R3, 0
    pop R7
    ret

sh_argcpy:                           ; R4 = arg offset -> FBUF = token (NUL-
    LDI R2, 0                        ; terminated; stops at space; clobbers
    ; j                              ; R1..R3, R5; keeps R4)
sac_loop:
    const R3, LBUF
    ADD R3, R3, R4
    ADD R3, R3, R2
    LDT R1, R3                       ; line[arg + j]
    BRZ R1, sac_end
    CMPI3 R5, R1, 32
    BRZ R5, sac_end
    const R3, FBUF
    ADD R3, R3, R2
    STT R3, R1
    ADDI R2, R2, 1
    JMP sac_loop
sac_end:
    const R3, FBUF
    ADD R3, R3, R2
    LDI R1, 0
    STT R3, R1
    ret

sh_atoi:                             ; FBUF token -> R3 = value (-1 on garbage;
    LDI R3, 0                        ; clobbers R1..R5)
    LDI R2, 0                        ; j
sao_loop:
    const R4, FBUF
    ADD R4, R4, R2
    LDT R1, R4                       ; c
    BRZ R1, sao_done
    CMPI3 R5, R1, 32
    BRZ R5, sao_done
    CMPI3 R5, R1, 48
    BRN R5, sao_bad
    CMPI3 R5, R1, 57
    BRP R5, sao_bad
    ADDI R5, R1, -48                 ; digit
    MULI R3, R3, 10
    ADD R3, R3, R5
    ADDI R2, R2, 1
    JMP sao_loop
sao_done:
    ret
sao_bad:
    LDI R3, -1
    ret

sh_freeidx:                          ; -> R1 = first missing slot index or -1
    push R7                          ; (probes the fs server with CHECK)
    LDI R1, 0
    push R1                          ; i [R8]
sfi_loop:
    LDW R2, R8
    CMPI3 R5, R2, 1000
    BRZP R5, sfi_none
    const R3, XFS
    LDW R2, R3                       ; cap re-read per call (D-041)
    LDW R4, R8                       ; i
    LDI R3, 2                        ; CHECK
    LDI R1, 10                       ; CALL
    TRAP 0                           ; R3 = 0 ok / -1 bad / -2 missing
    CMPI3 R5, R3, -2
    BRZ R5, sfi_found
    LDW R1, R8
    ADDI R1, R1, 1
    STW R8, R1                       ; i++
    JMP sfi_loop
sfi_found:
    pop R1                           ; i
    pop R7
    ret
sfi_none:
    LDI R1, -1
    pop R2                           ; drop i (R1 keeps the result)
    pop R7
    ret

sh_ls:
    const R3, XFS
    LDW R2, R3
    LDI R3, 10                       ; LIST
    LDI R4, 0
    LDI R1, 10                       ; CALL
    TRAP 0                           ; R3 = trytes written into FBUF
    CMPI3 R5, R3, 0
    BRN R5, sh_lserr
    push R3                          ; len
    LDI R4, 0                        ; j
sh_lspr:
    LDW R2, R8
    CMP3 R5, R4, R2
    BRZP R5, sh_lsd
    const R2, FBUF
    ADD R2, R2, R4
    LDT R1, R2
    call putc
    ADDI R4, R4, 1
    JMP sh_lspr
sh_lsd:
    pop R1
    JMP sh_loop
sh_lserr:
    const R1, str_fserr
    call puts
    JMP sh_loop

sh_ps:
    const R2, FBUF
    LDI R3, 27                       ; max entries
    LDI R1, 20                       ; PS
    TRAP 0                           ; R1 = count
    CMPI3 R5, R1, 0
    BRN R5, sh_pserr
    push R1                          ; count [R8]
    LDI R6, 0                        ; e (putnum/putc preserve R6)
sh_psl:
    LDW R2, R8
    CMP3 R5, R6, R2
    BRZP R5, sh_psd
    MULI R2, R6, 9
    const R3, FBUF
    ADD R3, R3, R2
    LDW R1, R3                       ; tid
    call putnum
    LDI R1, 32
    call putc
    MULI R2, R6, 9
    const R3, FBUF
    ADD R3, R3, R2
    ADDI R3, R3, 3
    LDW R1, R3                       ; state
    call putnum
    LDI R1, 32
    call putc
    MULI R2, R6, 9
    const R3, FBUF
    ADD R3, R3, R2
    ADDI R3, R3, 6
    LDW R1, R3                       ; class
    call putnum
    LDI R1, 10
    call putc
    ADDI R6, R6, 1
    JMP sh_psl
sh_psd:
    pop R1
    JMP sh_loop
sh_pserr:
    const R1, str_pserr
    call puts
    JMP sh_loop

sh_cat:
    ADD R1, R4, R0                   ; arg offset
    call sh_argcpy                   ; FBUF = name
    const R3, XFS
    LDW R2, R3
    LDI R3, 9                        ; NAMEGET
    LDI R4, 0
    LDI R1, 10
    TRAP 0                           ; R3 = index or -1, R4 = flags
    CMPI3 R5, R3, 0
    BRN R5, sh_noent
    ADD R4, R3, R0                   ; index
    const R3, XFS
    LDW R2, R3
    LDI R3, 6                        ; READ
    LDI R1, 10
    TRAP 0                           ; R3 = trytes in FBUF
    CMPI3 R5, R3, 0
    BRN R5, sh_caterr
    push R3                          ; len
    LDI R4, 0                        ; j
sh_catp:
    LDW R2, R8
    CMP3 R5, R4, R2
    BRZP R5, sh_catd
    const R2, FBUF
    ADD R2, R2, R4
    LDT R1, R2
    call putc
    ADDI R4, R4, 1
    JMP sh_catp
sh_catd:
    pop R1
    LDI R1, 10
    call putc
    JMP sh_loop
sh_caterr:
    const R1, str_fserr
    call puts
    JMP sh_loop
sh_noent:
    const R1, str_noent
    call puts
    JMP sh_loop

sh_ed:
    ADD R1, R4, R0                   ; arg offset
    call sh_argcpy                   ; FBUF = name
    const R3, XFS
    LDW R2, R3
    LDI R3, 9                        ; NAMEGET
    LDI R4, 0
    LDI R1, 10
    TRAP 0                           ; R3 = index or -1
    CMPI3 R5, R3, 0
    BRP R5, sh_edhave
    call sh_freeidx                  ; R1 = free index or -1
    CMPI3 R5, R1, 0
    BRN R5, sh_ederr                 ; nothing parked yet
    ADD R4, R1, R0                   ; idx
    push R4                          ; idx [R8]
    const R3, XFS
    LDW R2, R3
    LDI R3, 1                        ; CREATE
    LDI R1, 10
    TRAP 0                           ; R3 = 0 (payload pattern written)
    CMPI3 R5, R3, 0
    BRN R5, sh_ederr
    const R3, M8DIR
    LDI R2, 0
    STW R3, R2                       ; file flag
    LEA R3, R8, 0
    LDW R4, R3                       ; idx
    const R3, XFS
    LDW R2, R3
    LDI R3, 8                        ; NAMESET
    LDI R1, 10
    TRAP 0                           ; name still in FBUF
    CMPI3 R5, R3, 0
    BRN R5, sh_ederr
    JMP sh_edlines
sh_edhave:
    ADD R4, R3, R0                   ; idx (existing file)
    push R4                          ; idx [R8]
sh_edlines:
    const R3, M8CNT
    LDI R2, 0
    STW R3, R2                       ; content pos = 0
sh_edline:                           ; read one line into LBUF (sh_read pattern)
    const R3, LLEN
    LDI R2, 0
    STW R3, R2
sh_edrc:
    LDI R1, 18                       ; GETCHAR
    TRAP 0
    BRZ R1, sh_edrc
    ADD R3, R1, R0
    call putc                        ; echo the keystroke
    CMPI3 R5, R1, 10                 ; newline ends the line
    BRZ R5, sh_edln
    const R3, LLEN
    LDW R4, R3
    CMPI3 R5, R4, 92
    BRZP R5, sh_edrc                 ; buffer full: swallow the tail
    const R2, LBUF
    ADD R2, R2, R4
    STT R2, R1
    ADDI R4, R4, 1
    STW R3, R4
    JMP sh_edrc
sh_edln:
    const R3, LLEN
    LDW R4, R3
    const R2, LBUF
    ADD R2, R2, R4
    LDI R6, 0
    STT R2, R6                       ; NUL-terminate
    const R3, LLEN
    LDW R4, R3
    CMPI3 R5, R4, 1
    BRNZ R5, sh_edapp
    const R2, LBUF
    LDT R6, R2                       ; lone '.' ends the input
    CMPI3 R5, R6, 46
    BRZ R5, sh_edfin
sh_edapp:
    const R3, M8CNT
    LDW R2, R3
    CMPI3 R5, R2, 729
    BRZP R5, sh_edskip               ; content buffer full: consume only
    LDI R4, 0                        ; j
sh_edap:
    const R3, LLEN
    LDW R2, R3
    CMP3 R5, R4, R2
    BRZP R5, sh_edanl
    const R6, LBUF
    ADD R6, R6, R4
    LDT R1, R6                       ; char
    const R3, M8CNT
    LDW R2, R3                       ; pos
    const R6, FBUF
    ADD R6, R6, R2
    STT R6, R1
    ADDI R2, R2, 1
    const R3, M8CNT
    STW R3, R2                       ; pos++
    ADDI R4, R4, 1
    JMP sh_edap
sh_edanl:
    const R3, M8CNT
    LDW R2, R3                       ; pos
    LDI R1, 10                       ; newline
    const R6, FBUF
    ADD R6, R6, R2
    STT R6, R1
    ADDI R2, R2, 1
    const R3, M8CNT
    STW R3, R2
sh_edskip:
    JMP sh_edline
sh_edfin:
    const R3, M8CNT
    LDW R2, R3
    const R3, M8LEN
    STW R3, R2                       ; M8LEN = content length
    LEA R3, R8, 0
    LDW R4, R3                       ; idx
    const R3, XFS
    LDW R2, R3
    LDI R3, 7                        ; WRITE
    LDI R1, 10
    TRAP 0                           ; R3 = status
    CMPI3 R5, R3, 0
    BRN R5, sh_ederr
    pop R1                           ; balanced
    const R1, str_edok
    call puts
    JMP sh_loop
sh_ederr:
    pop R1                           ; drop idx (if parked)
    const R1, str_fserr
    call puts
    JMP sh_loop

sh_rm:
    ADD R1, R4, R0                   ; arg offset
    call sh_argcpy                   ; FBUF = name
    const R3, XFS
    LDW R2, R3
    LDI R3, 9                        ; NAMEGET
    LDI R4, 0
    LDI R1, 10
    TRAP 0
    CMPI3 R5, R3, 0
    BRN R5, sh_noent
    ADD R4, R3, R0                   ; idx
    push R4                          ; idx [R8]
    const R3, XFS
    LDW R2, R3
    LDI R3, 11                       ; NAMECLEAR
    LDI R1, 10
    TRAP 0
    LDW R4, R8                       ; idx
    const R3, XFS
    LDW R2, R3
    LDI R3, 3                        ; DELETE
    LDI R1, 10
    TRAP 0                           ; R3 = status
    CMPI3 R5, R3, 0
    BRN R5, sh_rmerr
    pop R1
    const R1, str_rmok
    call puts
    JMP sh_loop
sh_rmerr:
    pop R1
    const R1, str_fserr
    call puts
    JMP sh_loop

sh_cp:
    push R4                          ; src arg offset [R8] — CALL replies
                                     ; overwrite R4 with msg2 (D-041), so the
                                     ; offset must live on the stack
    ADD R1, R4, R0
    call sh_argcpy                   ; FBUF = src name
    const R3, XFS
    LDW R2, R3
    LDI R3, 9                        ; NAMEGET
    LDI R4, 0
    LDI R1, 10
    TRAP 0                           ; R3 = idxA or -1 (R4 clobbered)
    CMPI3 R5, R3, 0
    BRN R5, scp_noent
    ADD R4, R3, R0                   ; idxA
    push R4                          ; idxA -> [R8], src offset -> +3
    LEA R4, R8, 3
    LDW R4, R4                       ; src arg offset (reloaded)
    LDI R5, 0                        ; j
scp_sp:
    const R3, LBUF
    ADD R3, R3, R4
    ADD R3, R3, R5
    LDT R1, R3
    BRZ R1, scp_noarg
    CMPI3 R6, R1, 32
    BRZ R6, scp_spf
    ADDI R5, R5, 1
    JMP scp_sp
scp_spf:
    ADD R4, R4, R5
    ADDI R4, R4, 1                   ; dst arg offset
    pop R1                           ; idxA (temp: R1 is free until the push)
    pop R2                           ; drop the src offset
    push R1                          ; idxA back -> [R8]
    ADD R1, R4, R0
    call sh_argcpy                   ; FBUF = dst name
    const R3, XFS
    LDW R2, R3
    LDI R3, 9                        ; NAMEGET
    LDI R4, 0
    LDI R1, 10
    TRAP 0                           ; R3 = idxB or -1
    CMPI3 R5, R3, 0
    BRP R5, scp_havetgt
    call sh_freeidx                  ; new target: first missing slot
    CMPI3 R5, R1, 0
    BRN R5, scp_noidx                ; stack: idxA parked only
    ADD R4, R1, R0                   ; idxB
    push R4                          ; [R8]=idxB, idxA -> +3
    const R3, XFS
    LDW R2, R3
    LDI R3, 1                        ; CREATE
    LEA R4, R8, 0
    LDW R4, R4                       ; idxB
    LDI R1, 10
    TRAP 0                           ; payload pattern at idxB
    CMPI3 R5, R3, 0
    BRN R5, scp_err
    const R3, M8DIR
    LDI R2, 0
    STW R3, R2                       ; file flag
    LEA R3, R8, 0
    LDW R4, R3                       ; idxB
    const R3, XFS
    LDW R2, R3
    LDI R3, 8                        ; NAMESET (dst name still in FBUF)
    LDI R1, 10
    TRAP 0
    CMPI3 R5, R3, 0
    BRN R5, scp_err
    JMP scp_copy
scp_havetgt:
    ADD R4, R3, R0                   ; idxB
    push R4                          ; [R8]=idxB, idxA -> +3
scp_copy:
    ; NOTE: at this point [R8] = idxB and +3 = idxA
    LEA R3, R8, 3
    LDW R4, R3                       ; idxA
    const R3, XFS
    LDW R2, R3
    LDI R3, 6                        ; READ -> FBUF
    LDI R1, 10
    TRAP 0                           ; R3 = trytes read into FBUF
    CMPI3 R5, R3, 0
    BRN R5, scp_err
    const R2, M8LEN
    STW R2, R3                       ; M8LEN = len
    LEA R3, R8, 0
    LDW R4, R3                       ; idxB
    const R3, XFS
    LDW R2, R3
    LDI R3, 7                        ; WRITE
    LDI R1, 10
    TRAP 0                           ; R3 = status
    CMPI3 R5, R3, 0
    BRN R5, scp_err
    pop R2                           ; idxB
    pop R2                           ; idxA
    const R1, str_cpok
    call puts
    JMP sh_loop
scp_err:
    pop R2                           ; idxB
    pop R2                           ; idxA
    const R1, str_fserr
    call puts
    JMP sh_loop
scp_noidx:
    pop R2                           ; idxA
    const R1, str_fserr
    call puts
    JMP sh_loop
scp_noarg:
    pop R2                           ; idxA
    pop R2                           ; src offset
    const R1, str_usage
    call puts
    JMP sh_loop
scp_noent:
    pop R4                           ; src offset
    JMP sh_noent

sh_mkdir:
    ADD R1, R4, R0                   ; arg offset
    call sh_argcpy                   ; FBUF = name
    const R3, XFS
    LDW R2, R3
    LDI R3, 9                        ; NAMEGET
    LDI R4, 0
    LDI R1, 10
    TRAP 0
    CMPI3 R5, R3, 0
    BRP R5, sh_mkexists
    const R3, XFS
    LDW R2, R3
    LDI R3, 12                       ; MKDIR
    LDI R4, 0
    LDI R1, 10
    TRAP 0                           ; R3 = status
    CMPI3 R5, R3, 0
    BRN R5, sh_mkerr
    const R1, str_mkok
    call puts
    JMP sh_loop
sh_mkexists:
    const R1, str_exists
    call puts
    JMP sh_loop
sh_mkerr:
    const R1, str_fserr
    call puts
    JMP sh_loop

sh_tstat:
    ADD R1, R4, R0                   ; arg offset
    call sh_argcpy                   ; FBUF = digits
    call sh_atoi                     ; R3 = tid
    CMPI3 R5, R3, 0
    BRN R5, sh_tsbad
    ADD R2, R3, R0                   ; R2 = tid
    LDI R1, 21                       ; TSTAT
    TRAP 0                           ; R1 = state, R2 = class
    CMPI3 R5, R1, -1
    BRZ R5, sh_tsbad
    ADD R6, R2, R0                   ; class (putnum/putc keep R6)
    call putnum                      ; state
    LDI R1, 32
    call putc
    ADD R1, R6, R0
    call putnum                      ; class
    LDI R1, 10
    call putc
    JMP sh_loop
sh_tsbad:
    const R1, str_nothread
    call puts
    JMP sh_loop

sh_kill:
    ADD R1, R4, R0                   ; arg offset
    call sh_argcpy
    call sh_atoi                     ; R3 = tid
    CMPI3 R5, R3, 0
    BRN R5, sh_tsbad
    ADD R2, R3, R0                   ; R2 = tid
    LDI R1, 22                       ; KILL
    TRAP 0                           ; R1 = 0 ok / -1 refused
    CMPI3 R5, R1, 0
    BRN R5, sh_killbad
    const R1, str_killok
    call puts
    JMP sh_loop
sh_killbad:
    const R1, str_killbad
    call puts
    JMP sh_loop

sh_execprog:
    ADD R1, R4, R0                   ; arg offset
    call sh_argcpy                   ; FBUF = name
    const R3, XFS
    LDW R2, R3
    LDI R3, 9                        ; NAMEGET
    LDI R4, 0
    LDI R1, 10
    TRAP 0                           ; R3 = idx or -1
    CMPI3 R5, R3, 0
    BRN R5, sh_noent
    ADD R2, R3, R0                   ; R2 = idx
    LDI R1, 19                       ; EXEC
    TRAP 0                           ; R1 = tid or negative
    CMPI3 R5, R1, 0
    BRN R5, sh_execerr
    push R1                          ; tid
    const R1, str_exectid
    call puts
    pop R1
    call putnum
    LDI R1, 10
    call putc
    JMP sh_loop
sh_execerr:
    const R1, str_execerr
    call puts
    JMP sh_loop

sh_pipe:                             ; demo: an endpoint as a 1-slot pipe
    LDI R2, 1                        ; badge
    LDI R1, 17                       ; EP_CREATE
    TRAP 0                           ; R1 = cap ref or negative
    CMPI3 R5, R1, 0
    BRN R5, sh_pipeerr
    push R1                          ; cap [R8]
    const R2, pipe_writer
    LDW R4, R8                       ; arg = cap
    LDI R3, 0                        ; class
    LDI R1, 3                        ; THREAD_CREATE
    TRAP 0                           ; R1 = tid
    CMPI3 R5, R1, 0
    BRN R5, sh_pipeerr2
    LDI R1, 1                        ; YIELD: let the writer reach its SEND
    TRAP 0
sh_piperd:
    LDW R2, R8                       ; cap (re-read per call, D-041)
    LDI R1, 9                        ; RECV
    TRAP 0                           ; R3 = tryte
    CMPI3 R5, R3, -1
    BRZ R5, sh_pipeerr2
    ADD R1, R3, R0
    call putc
    CMPI3 R5, R3, 10                 ; newline ends the message
    BRNZ R5, sh_piperd
    pop R1
    JMP sh_loop
sh_pipeerr2:
    pop R1
sh_pipeerr:
    const R1, str_pipeerr
    call puts
    JMP sh_loop

str_eq:                              ; R1 = &a, R2 = &b (tryte strings, NUL
    push R7                          ; terminated) -> R3 = 1 if equal
se_loop:
    LDT R4, R1
    LDT R5, R2
    CMP3 R6, R4, R5
    BRNZ R6, se_diff
    BRZ R4, se_same                  ; both NUL: equal
    ADDI R1, R1, 1
    ADDI R2, R2, 1
    JMP se_loop
se_same:
    LDI R3, 1
    JMP se_out
se_diff:
    LDI R3, 0
se_out:
    pop R7
    ret

; ------------------------------------------------------------------------------
; TriFS v0.1 server (D-042) — index-keyed COW tree over the block device.
; All helpers below are called from the fs server thread (user mode, own
; kernel stack); they route block IO through the MMIO block device into the
; static 729-tryte buffer BBUF (reserved frame 1416, D-043) or BB2 (frame
; 1415, free-list IO only).
;   blk_read(lba)  / blk_write(lba)   leaf: R1 = lba, data in/out of BBUF
;   free_alloc()                      -> R1 = lba or -1 (clobbers R2..R5)
;   free_free(lba)                    head-push (clobbers R2..R5, keeps R4..R6)
;   sum_calc(addr)                    -> R1 = balanced sum (clobbers R2..R5)
;   data_fill(i)                      BBUF = deterministic payload for file i
;   dir_upd(i, val)                   COW-update slot i -> new root in R3
; Conventions (D-040): every helper that calls others saves R7; R6+ preserved
; unless stated; BBUF reads/writes use tryte addressing, words +3.
; ------------------------------------------------------------------------------
blk_read:                            ; R1 = lba -> BBUF (clobbers R2, R3)
    const R2, BLK_LBA
    STW R2, R1
    const R2, BBUF
    const R3, BLK_BUF
    STW R3, R2                       ; buffer address = BBUF
    const R2, BLK_CMD
    LDI R3, 1
    STW R2, R3                       ; cmd = read
    ret
blk_write:                           ; R1 = lba <- BBUF (clobbers R2, R3)
    const R2, BLK_LBA
    STW R2, R1
    const R2, BBUF
    const R3, BLK_BUF
    STW R3, R2
    const R2, BLK_CMD
    LDI R3, 2
    STW R2, R3                       ; cmd = write
    ret

blk_read2:                           ; R1 = lba -> BB2 (clobbers R2, R3). The
    const R2, BLK_LBA                ; free-list helpers use this buffer so
    STW R2, R1                       ; BBUF stays intact: dir_upd stages its
    const R2, BB2                    ; clone there across a free_alloc call
    const R3, BLK_BUF                ; (D-043).
    STW R3, R2
    const R2, BLK_CMD
    LDI R3, 1
    STW R2, R3                       ; cmd = read
    ret
blk_write2:                          ; R1 = lba <- BB2 (clobbers R2, R3)
    const R2, BLK_LBA
    STW R2, R1
    const R2, BB2
    const R3, BLK_BUF
    STW R3, R2
    const R2, BLK_CMD
    LDI R3, 2
    STW R2, R3                       ; cmd = write
    ret

free_alloc:                          ; -> R1 = lba or -1 (clobbers R2..R5; IO on
    push R7                          ; BB2, so BBUF — dir_upd's staged clone —
    push R2                          ; survives; preserves R6)
    push R3
    push R4
    push R5
    LDI R1, FS_BASE
    call blk_read2                   ; superblock -> BB2
    const R4, BB2 + SB_FREE
    LDW R4, R4                       ; free head
    CMPI3 R5, R4, 0
    BRZ R5, fa_none
    ADD R5, R4, R0                   ; head lba
    ADD R1, R5, R0
    call blk_read2                   ; the free block itself -> BB2
    const R4, BB2
    LDW R4, R4                       ; next = first word. R4 (not R2!): the
                                     ; blk_read2 below clobbers R2/R3 — an R2
                                     ; copy here stored BLK_CMD (the MMIO
                                     ; address constant) as the free head and
                                     ; wrecked the list from the first alloc
    LDI R1, FS_BASE
    call blk_read2                   ; superblock again -> BB2
    const R3, BB2 + SB_FREE
    STW R3, R4                       ; free_head = next
    const R1, BB2
    call super_sum                   ; refresh the super checksum (clobbers
                                     ; R1..R3 only; R4/R5 survive)
    LDI R1, FS_BASE
    call blk_write2
    ADD R1, R5, R0                   ; R1 = allocated lba
    pop R5
    pop R4
    pop R3
    pop R2
    pop R7
    ret
fa_none:
    LDI R1, -1
    pop R5
    pop R4
    pop R3
    pop R2
    pop R7
    ret

free_free:                           ; R1 = lba -> free list head (clobbers R2,
    push R7                          ; R3; preserves R4..R6); IO on BB2
    push R2
    push R3
    push R4
    push R5
    ADD R4, R1, R0                   ; lba (blk_* keep R4)
    LDI R1, FS_BASE
    call blk_read2                   ; superblock -> BB2
    const R2, BB2 + SB_FREE
    LDW R5, R2                       ; old head. R5, NOT R3 — the blk_read2
                                     ; below leaves R3 = 1 (the read cmd), so
                                     ; an R3 copy here chained freed blocks to
                                     ; word0=1 and poisoned the whole list
    ADD R1, R4, R0
    call blk_read2                   ; the block becoming free -> BB2
    const R2, BB2
    STW R2, R5                       ; its first word = old head
    ADD R1, R4, R0
    call blk_write2
    LDI R1, FS_BASE
    call blk_read2                   ; superblock -> BB2 (the read above
    const R2, BB2 + SB_FREE          ; clobbered its word 0: re-read)
    STW R2, R4                       ; free_head = lba
    const R1, BB2
    call super_sum                   ; refresh the super checksum (R4 survives)
    LDI R1, FS_BASE
    call blk_write2
    pop R5
    pop R4
    pop R3
    pop R2
    pop R7
    ret

sum_calc:                            ; R1 = base addr -> R1 = sum (clobbers R2..R5)
    push R7
    push R2
    push R3
    push R4
    LDI R2, 0                        ; acc
    LDI R3, 0                        ; j
sc_loop:
    ADD R4, R1, R3
    LDT R4, R4                       ; tryte
    ADD R2, R2, R4
    ADDI R3, R3, 1
    CMPI3 R5, R3, 729
    BRN R5, sc_loop
    ADD R1, R2, R0
    pop R4
    pop R3
    pop R2
    pop R7
    ret

data_fill:                           ; R1 = file index i (clobbers R2..R5; keeps R6)
    push R7
    push R2
    push R3
    push R4
    MULI R2, R1, 729                 ; base = i*729: payload tryte j is
                                     ; wrap(base + j, 6) — distinct per file
                                     ; and position-dependent (corruption
                                     ; changes the checksum)
    LDI R3, 0
df_loop:
    ADD R4, R2, R3
    const R5, BBUF
    ADD R5, R5, R3
    STT R5, R4                       ; mem[BBUF+j] = wrap(base+j, 6)
    ADDI R3, R3, 1
    CMPI3 R5, R3, 729
    BRN R5, df_loop
    pop R4
    pop R3
    pop R2
    pop R7
    ret

dir_upd:                             ; R1 = slot i, R2 = value -> updates slot
                                     ; i in the COW directory, swaps the root
                                     ; atomically (ROOT+GEN+sum in one block
                                     ; write), reclaims the old chain.
                                     ; The chain is ALWAYS DIR_LEVELS blocks:
                                     ; the first commit builds all five levels,
                                     ; every later commit clones all five and
                                     ; frees the old five — net cost 2 blocks
                                     ; per file, and the old chain shares
                                     ; nothing with the new one (safe to free
                                     ; wholesale after the swap). Per-block
                                     ; counts are fixed (241, top level 36),
                                     ; matching the host-side chain reader.
                                     ; Stack layout (SP grows downward, last
                                     ; push at [R8]):
                                     ;   [R8+0]  old level-4 lba
                                     ;   [R8+3]  old level-3 lba
                                     ;   [R8+6]  old level-2 lba
                                     ;   [R8+9]  old level-1 lba
                                     ;   [R8+12] old level-0 lba (old root)
                                     ;   [R8+15] slot level k
                                     ;   [R8+18] slot index i
                                     ;   [R8+21] value
    push R7
    push R3
    push R4
    push R5
    push R6
    ADD R4, R1, R0                   ; i (blk_* keep R4)
    push R2                          ; value
    push R1                          ; slot index i
    LDI R1, 0                        ; k = level of slot i: smallest k with
du_kloop:                            ; i < (k+1)*241
    MULI R2, R1, DIR_REFS
    ADDI R2, R2, DIR_REFS
    CMP3 R3, R4, R2
    BRN R3, du_kdone
    ADDI R1, R1, 1
    CMPI3 R3, R1, DIR_LEVELS
    BRN R3, du_kloop
du_kdone:
    ADD R2, R1, R0
    push R2                          ; k
    LDI R6, 0                        ; j = 0
    LDI R1, FS_BASE
    call blk_read                    ; superblock -> BBUF
    const R5, BBUF + SB_ROOT
    LDW R5, R5                       ; cur = root
du_fwd:                              ; push the old lba of every level 0..4
    push R5                          ; level j lba (0 = fresh)
    CMPI3 R1, R5, 0
    BRZ R1, du_fwd_zero              ; fresh chain: nothing to read (a read of
    ADD R1, R5, R0                   ; lba 0 would pull in the boot block)
    call blk_read                    ; old level-j block -> BBUF
    const R5, BBUF + 3
    LDW R5, R5                       ; cur = next
    JMP du_fwd_next
du_fwd_zero:
    LDI R5, 0
du_fwd_next:
    ADDI R6, R6, 1
    CMPI3 R1, R6, DIR_LEVELS
    BRN R1, du_fwd                   ; j < DIR_LEVELS
    LDI R6, 4                        ; clone levels 4..0 (R6 = level)
    LDI R3, 0                        ; deeper clone (none at level 4)
    LDI R5, 0                        ; new root (set at level 0)
du_clone:
    LDI R1, 4
    SUB R1, R1, R6                   ; 4 - level -> stack offset of this level
    MULI R1, R1, 3
    ADD R1, R8, R1
    LDW R2, R1                       ; cur = old lba of this level
    CMPI3 R5, R2, 0
    BRZ R5, du_fresh
    push R3                          ; deeper clone across the read (blk_read
    ADD R1, R2, R0                   ; clobbers R3; the push/pop is balanced
    call blk_read                    ; so du_mut sees the unshifted R8)
    pop R3
    JMP du_mut
du_fresh:                            ; first commit (or fresh level): start
    push R3                          ; from a zeroed block; R3 (the deeper
    LDI R3, 0                        ; clone) parks on the stack across the
    LDI R2, 0                        ; zeroing loop
du_zloop:
    const R1, BBUF
    ADD R1, R1, R3
    STW R1, R2
    ADDI R3, R3, 3
    CMPI3 R5, R3, 729
    BRN R5, du_zloop
    pop R3
du_mut:
    ; count word: fixed per level (241 refs; 36 in the top level) — a
    ; DELETE passes value 0 but the counts never change: the chain is
    ; always full-size
    CMPI3 R1, R6, 4
    BRZ R1, du_cnt36
    LDI R1, 241
    JMP du_cntwr
du_cnt36:
    LDI R1, 36
du_cntwr:
    const R2, BBUF
    STW R2, R1
    ; slot mutation at the slot's own level k ([R8+15])
    LDI R1, 15
    ADD R1, R8, R1
    LDW R2, R1                       ; k
    CMP3 R1, R6, R2                  ; this level == k?
    BRNZ R1, du_next1
    MULI R2, R2, DIR_REFS
    LDI R1, 18
    ADD R1, R8, R1
    LDW R1, R1                       ; i
    SUB R1, R1, R2                   ; s = i - k*241
    MULI R1, R1, 3
    ADDI R1, R1, 6                   ; &refs[s] within the block
    const R2, BBUF
    ADD R1, R2, R1
    LDI R2, 21
    ADD R2, R8, R2
    LDW R2, R2                       ; value
    STW R1, R2                       ; refs[s] = value
du_next1:
    ; next links: level 4 keeps the old block's link — BBUF+3 already holds
    ; it (the old next from the blk_read, or 0 for a fresh zeroed block);
    ; deeper levels chain to the previously written clone
    CMPI3 R1, R6, 4
    BRZ R1, du_alloc
    const R2, BBUF + 3
    STW R2, R3                       ; next = deeper clone
du_alloc:
    call free_alloc                  ; R1 = clone lba (R2..R5 restored inside)
    push R1                          ; clone lba on the stack
    ADD R2, R1, R0
    ADD R1, R2, R0
    call blk_write                   ; write the clone (BBUF -> disk)
    pop R1                           ; clone lba
    ADD R3, R1, R0                   ; new = this clone
    CMPI3 R1, R6, 0
    BRNZ R1, du_lvlup
    ADD R5, R3, R0                   ; level 0: new root = the clone. R3 — the
                                     ; CMPI3 above just overwrote R1 with the
                                     ; compare result, so R1 is NOT the lba
du_lvlup:
    ADDI R6, R6, -1
    CMPI3 R1, R6, -1
    BRZ R1, du_done
    JMP du_clone
du_done:
    ; swap the root atomically, then reclaim the old chain (old root parked
    ; at [R8+12]): the new chain shares nothing with the old one, so all
    ; five old levels are dead the instant the superblock write lands
    LDI R1, FS_BASE
    call blk_read                    ; superblock -> BBUF
    const R2, BBUF + SB_ROOT
    STW R2, R5                       ; ROOT = new root
    const R2, BBUF + SB_GEN
    LDW R1, R2
    ADDI R1, R1, 1
    STW R2, R1                       ; GEN += 1
    const R1, BBUF
    call super_sum                   ; refresh the superblock checksum
    LDI R1, FS_BASE
    call blk_write                   ; the commit point
    LDI R1, 12
    ADD R1, R8, R1
    LDW R3, R1                       ; cur = old root (0: first commit)
    CMPI3 R1, R3, 0
    BRZ R1, du_frdone
    ; snapshot armed (SNAP_ARMED != 0): LEAK the old chain — the saved tree
    ; shares these blocks, so they must stay off the free list until the
    ; snapshot is discarded (restore or overwrite). v0.1 trade-off (D-052).
    const R2, SNAP_ARMED
    LDW R2, R2
    CMPI3 R1, R2, 0
    BRNZ R1, du_frdone
du_freep:
    push R3                          ; cur across the read
    ADD R1, R3, R0
    call blk_read                    ; old block -> BBUF (free to clobber:
                                     ; every clone is safely on disk)
    const R2, BBUF + 3
    LDW R4, R2                       ; next (free_free keeps R4..R6)
    pop R3                           ; cur
    ADD R1, R3, R0
    call free_free                   ; reclaim it
    ADD R3, R4, R0                   ; cur = next
    CMPI3 R1, R3, 0
    BRZ R1, du_frdone
    JMP du_freep
du_frdone:
    LDI R1, 24                       ; drop 5 path words + 3 entry words
    ADD R8, R8, R1
    pop R6
    pop R5
    pop R4
    pop R3
    pop R7
    ret

super_sum:                            ; R1 = superblock image base (BBUF or
    ADD R3, R1, R0                    ; BB2) -> refresh [base+SB_SUM] = sum of
    LDW R1, R3                        ; the six header words (ADD wraps
    ADDI R3, R3, 3                    ; modulo 3^18 natively). The host-side
    LDW R2, R3                        ; trifs.read_super validates this word.
    ADD R1, R1, R2                    ; Clobbers R1..R3. NOTE: the base MUST be
    ADDI R3, R3, 3                    ; passed — an earlier version hardcoded
    LDW R2, R3                        ; BBUF, so the free-list helpers (whose
    ADD R1, R1, R2                    ; super copy lives in BB2) checksummed
    ADDI R3, R3, 3                    ; whatever dir clone was staged in BBUF
    LDW R2, R3                        ; and wrote the result over refs[4] at
    ADD R1, R1, R2                    ; tryte 18 — corrupting every 5th slot.
    ADDI R3, R3, 3
    LDW R2, R3
    ADD R1, R1, R2                    ; w4 (base+12 = SB_ROOT)
    ADDI R3, R3, 3
    LDW R2, R3
    ADD R1, R1, R2                    ; w5 (base+15 = SB_GEN)
    ADDI R3, R3, 3
    STW R3, R1                        ; [base+SB_SUM] = sum
    ret

; ------------------------------------------------------------------------------
; fs_main — TriFS server (M7). CALL(op, index) protocol; replies status:
;   op 1 CREATE(i)  -> 0 (header + payload block, dir slot i updated, COW)
;   op 2 CHECK(i)   -> 0 ok / -1 sum mismatch / -2 missing
;   op 3 DELETE(i)  -> 0 (blocks returned to the free list, slot zeroed)
;   op 4 STATUS     -> msg1 = root, msg2 = gen
;   op 5 FSCK       -> msg1 = ok count, msg2 = total
; ------------------------------------------------------------------------------
fs_main:
    ADD R6, R1, R0                   ; fs cap
    const R2, FS_CAP
    STW R2, R1                       ; park the cap in MEMORY (D-041): the
                                     ; format loop below uses R6 as scratch
    ; self-format when the superblock magic does not match (D-042)
    LDI R1, FS_BASE
    call blk_read                    ; super -> BBUF
    const R2, BBUF
    LDW R3, R2                       ; magic
    const R2, FS_MAGIC
    CMP3 R5, R3, R2
    BRZ R5, fm_ok
    ; format: chain every fs block except the superblock
    LDI R5, FS_BASE + 1              ; lba
fm_chain:
    ADD R1, R5, R0
    call blk_read                    ; old content -> BBUF
    ADDI R4, R5, 1                   ; next = lba + 1 (default)
    const R3, FS_BASE + FS_NB - 1
    CMP3 R6, R5, R3                  ; R6 = sign(lba - last); R5 keeps the lba!
    BRN R6, fm_link
    LDI R4, 0                        ; the last block ends the list
fm_link:
    const R2, BBUF
    STW R2, R4                       ; first word = next
    ADD R1, R5, R0
    call blk_write
    const R2, BLK_STAT
    LDW R6, R2                       ; negative status = disk too small
    CMPI3 R6, R6, 0
    BRN R6, fm_bad
    ADDI R5, R5, 1                   ; lba++
    const R3, FS_BASE + FS_NB
    CMP3 R6, R5, R3
    BRN R6, fm_chain
    ; superblock: [magic, base, nblocks, free_head, root, gen, sum]
    LDI R1, FS_BASE
    call blk_read                    ; -> BBUF (zeros)
    const R2, BBUF
    const R1, FS_MAGIC
    STW R2, R1
    const R2, BBUF + 3
    LDI R1, FS_BASE
    STW R2, R1
    const R2, BBUF + 6
    LDI R1, FS_NB
    STW R2, R1
    const R2, BBUF + 9
    LDI R1, FS_BASE + 1
    STW R2, R1                       ; free head
    const R2, BBUF + 12
    LDI R1, 0
    STW R2, R1                       ; root = 0 (empty tree)
    const R2, BBUF + 15
    LDI R1, 0
    STW R2, R1                       ; gen = 0
    const R1, BBUF
    call super_sum                   ; checksum over the six header words
    LDI R1, FS_BASE
    call blk_write
    const R2, BLK_STAT
    LDW R3, R2
    CMPI3 R5, R3, 0
    BRN R5, fm_bad
    LDI R1, 0
    const R2, FS_OKFLAG
    STW R2, R1                       ; fs usable
    JMP fm_ok
fm_bad:
    LDI R1, 1
    const R2, FS_OKFLAG
    STW R2, R1                       ; disk too small: fs unavailable
fm_ok:
fsm_loop:
    const R2, FS_CAP
    LDW R2, R2                       ; cap re-read per call (D-041)
    LDI R1, 9                        ; RECV
    TRAP 0                           ; R3 = op, R4 = index
    CMPI3 R1, R3, 1
    BRZ R1, fsop_create
    CMPI3 R1, R3, 2
    BRZ R1, fsop_check
    CMPI3 R1, R3, 3
    BRZ R1, fsop_delete
    CMPI3 R1, R3, 4
    BRZ R1, fsop_status
    CMPI3 R1, R3, 5
    BRZ R1, fsop_fsck
    CMPI3 R1, R3, 6
    BRZ R1, fsop_read
    CMPI3 R1, R3, 7
    BRZ R1, fsop_write
    CMPI3 R1, R3, 8
    BRZ R1, fsop_nameset
    CMPI3 R1, R3, 9
    BRZ R1, fsop_nameget
    CMPI3 R1, R3, 10
    BRZ R1, fsop_list
    CMPI3 R1, R3, 11
    BRZ R1, fsop_nameclr
    CMPI3 R1, R3, 12
    BRZ R1, fsop_mkdir
    CMPI3 R1, R3, 13
    BRZ R1, fsop_snap_save
    CMPI3 R1, R3, 14
    BRZ R1, fsop_snap_restore
    LDI R3, -4                       ; unknown op
    LDI R4, 0
    JMP fsm_reply
fsop_create:
    call free_alloc                  ; R1 = header lba (preserves R2..R6)
    CMPI3 R5, R1, 0
    BRN R5, fc_enomem
    ADD R3, R1, R0                   ; h_ref
    call free_alloc                  ; R1 = data lba
    CMPI3 R5, R1, 0
    BRN R5, fc_enomem
    ADD R2, R1, R0                   ; d_ref
    ADD R1, R4, R0                   ; i
    call data_fill                   ; BBUF = payload(i) (keeps R2..R4, R6)
    const R1, BBUF
    call sum_calc                    ; R1 = sum (clobbers R5 only besides args)
    ADD R5, R1, R0                   ; sum
    ; save d_ref / h_ref / sum BEFORE the payload write: blk_write clobbers
    ; R2 and R3. Pop order must be sum -> d_ref -> h_ref, so push h_ref
    ; first (deepest), then d_ref, then sum (top).
    push R3                          ; h_ref
    push R2                          ; d_ref
    push R5                          ; sum
    ADD R1, R2, R0
    call blk_write                   ; data block -> disk
    pop R1                           ; sum
    const R2, BBUF + 3
    STW R2, R1                       ; [BBUF+3] = sum
    pop R1                           ; d_ref
    const R2, BBUF + 9
    STW R2, R1                       ; ext[0] = d_ref
    const R2, BBUF
    LDI R1, 729
    STW R2, R1                       ; len = 729
    const R2, BBUF + 6
    LDI R1, 1
    STW R2, R1                       ; ext count = 1
    pop R1                           ; h_ref
    ADD R1, R1, R0
    call blk_write                   ; header -> disk
    ADD R2, R1, R0                   ; value = h_ref
    ADD R1, R4, R0                   ; i
    call dir_upd                     ; COW slot update + root swap
    LDI R3, 0                        ; status ok
    LDI R4, 0
    JMP fsm_reply
fc_enomem:
    LDI R3, -3                       ; out of fs blocks
    LDI R4, 0
    JMP fsm_reply
fsop_check:
    ADD R1, R4, R0
    call fs_check_one                ; R1 = status
    ADD R3, R1, R0
    JMP fsm_reply
fsop_delete:
    ; dir lookup (same walk as check), then free blocks + zero the slot.
    ; The slot index stays on the stack the whole time: fs_lookup and the
    ; helpers below clobber R2..R5, and the single pop at fd_hdr must
    ; uncover it after h_ref is freed.
    push R4                          ; i
    ADD R1, R4, R0
    ADD R1, R1, R0
    ADD R1, R4, R0
    call fs_lookup                   ; R1 = h_ref or 0 (clobbers R2..R5)
    push R1                          ; h_ref
    CMPI3 R5, R1, 0
    BRZ R5, fd_missing
    ; free the data extents from the header
    ADD R1, R1, R0
    call blk_read                    ; header -> BBUF
    const R2, BBUF + 6
    LDW R5, R2                       ; ext count
    LDI R4, 0
fd_ext:
    CMP3 R1, R4, R5
    BRZP R1, fd_hdr
    MULI R3, R4, 3
    ADDI R3, R3, 9
    const R2, BBUF
    ADD R1, R2, R3
    LDW R1, R1                       ; d_ref
    call free_free
    ADDI R4, R4, 1
    JMP fd_ext
fd_hdr:
    pop R1                           ; h_ref
    call free_free
    pop R1                           ; i
    LDI R2, 0
    call dir_upd                     ; slot[i] = 0 (COW)
    LDI R3, 0                        ; ok
    LDI R4, 0
    JMP fsm_reply
fd_missing:
    pop R1                           ; h_ref (0)
    pop R1                           ; i
    LDI R3, -2
    LDI R4, 0
    JMP fsm_reply
fsop_status:
    const R2, FS_OKFLAG
    LDW R1, R2
    CMPI3 R5, R1, 0
    BRZ R5, fst_ok
    LDI R3, -1                       ; fs unavailable (small disk)
    LDI R4, 0
    JMP fsm_reply
fst_ok:
    LDI R1, FS_BASE
    call blk_read
    const R2, BBUF + SB_ROOT
    LDW R3, R2                       ; reply1 = root
    const R2, BBUF + SB_GEN
    LDW R4, R2                       ; reply2 = gen
    JMP fsm_reply
fsop_fsck:
    ; walk the whole dir chain and check every slot: per-block counts sum
    ; to the full ref vector (1000 for the M7 workload). Counters park on
    ; the stack: cur [R8], gi [R8+3], total [R8+6], ok [R8+9]; the current
    ; block's count rides on top while its slots are visited.
    LDI R1, FS_BASE
    call blk_read                    ; super -> BBUF
    const R2, BBUF + SB_ROOT
    LDW R3, R2                       ; root
    LDI R2, 0
    push R2                          ; ok
    push R2                          ; total
    push R2                          ; gi (global slot index)
    ADD R2, R3, R0
    push R2                          ; cur (dir block lba)
fk_blk:
    LDW R1, R8                       ; cur
    CMPI3 R2, R1, 0
    BRZ R2, fk_done
    ADD R1, R1, R0
    call blk_read                    ; dir block -> BBUF
    const R2, BBUF
    LDW R5, R2                       ; count of this block
    ADD R2, R5, R0
    push R2                          ; cnt [R8] (cur shifts to [R8+3])
    LDI R4, 0                        ; s = 0
fk_slot:
    LDW R1, R8                       ; cnt
    CMP3 R2, R4, R1
    BRZP R2, fk_nxt                  ; s >= count -> next block
    LDI R1, 6
    ADD R1, R8, R1
    LDW R2, R1                       ; gi
    ADD R1, R2, R4                   ; global slot index = gi + s
    ADD R1, R1, R0
    push R4                          ; park s across fs_check_one
    call fs_check_one                ; R1 = status (stack-neutral)
    pop R4                           ; s
    CMPI3 R2, R1, 0
    BRNZ R2, fk_bad
    LDI R1, 12
    ADD R1, R8, R1
    LDW R2, R1
    ADDI R2, R2, 1
    STW R1, R2                       ; ok++
fk_bad:
    LDI R1, 9
    ADD R1, R8, R1
    LDW R2, R1
    ADDI R2, R2, 1
    STW R1, R2                       ; total++
    ADDI R4, R4, 1
    JMP fk_slot
fk_nxt:
    ; gi += cnt; cur = next of this block; drop cnt. fs_check_one clobbered
    ; BBUF, so the block is re-read for its next pointer
    LDI R1, 6
    ADD R1, R8, R1
    LDW R2, R1                       ; gi
    LDW R3, R8                       ; cnt
    ADD R2, R2, R3
    STW R1, R2                       ; gi += cnt
    LDI R1, 3
    ADD R1, R8, R1
    LDW R1, R1                       ; cur
    ADD R1, R1, R0
    call blk_read                    ; dir block -> BBUF
    const R2, BBUF + 3
    LDW R2, R2                       ; next
    ADDI R8, R8, 3                   ; drop cnt
    STW R8, R2                       ; cur = next
    JMP fk_blk
fk_done:
    ADDI R8, R8, 6                   ; drop cur + gi
    pop R4                           ; total (msg2)
    pop R3                           ; ok (msg1)
    JMP fsm_reply

; ---- M7 snapshot API (ops 13/14): park/restore the COW (root, gen) pair.
; Every prior root's blocks stay readable (COW never recycles pre-delete
; blocks), so restoring an old root yields a consistent tree; blocks allocated
; after the save are leaked, not corrupted (v0.1 trade-off, documented).

fsop_snap_save:                      ; op 13: SNAP_ROOT/SNAP_GEN <- super,
                                     ; arm dir_upd's old-chain leak
    LDI R1, FS_BASE
    call blk_read                    ; superblock -> BBUF
    const R2, BBUF + SB_ROOT
    LDW R3, R2                       ; root
    const R2, SNAP_ROOT
    STW R2, R3
    const R2, BBUF + SB_GEN
    LDW R3, R2                       ; gen
    const R2, SNAP_GEN
    STW R2, R3
    const R2, SNAP_ARMED
    LDI R1, 1
    STW R2, R1                       ; arm: leak old chains while armed
    ADD R3, R3, R0                   ; reply1 = saved gen
    LDI R4, 0
    JMP fsm_reply

fsop_snap_restore:                   ; op 14: super <- parked pair, gen += 1,
                                     ; disarm the old-chain leak
    const R2, SNAP_ROOT
    LDW R4, R2                       ; saved root (R4 survives blk_read/write)
    CMPI3 R5, R4, 0
    BRN R5, fsr_none
    const R2, SNAP_GEN
    LDW R5, R2                       ; saved gen (R5 survives blk_* too)
    LDI R1, FS_BASE
    call blk_read                    ; superblock -> BBUF (clobbers R2, R3)
    const R2, BBUF + SB_ROOT
    STW R2, R4                       ; ROOT = saved root
    const R2, BBUF + SB_GEN
    LDW R3, R2                       ; CURRENT gen (monotonic: never goes back)
    ADDI R3, R3, 1                   ; gen = current + 1
    STW R2, R3
    const R1, BBUF
    call super_sum                   ; refresh the superblock checksum
    LDI R1, FS_BASE
    call blk_write
    const R2, SNAP_ARMED
    LDI R1, 0
    STW R2, R1                       ; disarm: normal reclaim resumes
    ADD R3, R5, R0                   ; reply1 = saved gen
    LDI R4, 0
    JMP fsm_reply
fsr_none:
    LDI R3, -5                       ; no snapshot saved
    LDI R4, 0
    JMP fsm_reply

fsm_reply:
    LDI R1, 11                       ; REPLY
    const R2, FS_CAP
    LDW R2, R2                       ; cap re-read per call (D-041)
    TRAP 0                           ; msg1 = R3, msg2 = R4
    JMP fsm_loop

; ---- M8 namespace ops (D-047): the caller parks extra arguments in fixed
; memory slots (M8LEN/M8DIR/M8CNT) and strings/content in FBUF — only the
; shell and the boot M8 phase use these ops, so no locking is needed.

fsop_read:                           ; op 6: READ(i) -> FBUF; msg1 = trytes
    ADD R1, R4, R0                   ; i
    call fs_lookup                   ; R1 = h_ref or 0 (clobbers R2..R5)
    CMPI3 R5, R1, 0
    BRZ R5, fr_miss
    call blk_read                    ; header -> BBUF
    const R2, BBUF + 6
    LDW R3, R2                       ; ext count
    CMPI3 R5, R3, 0
    BRZ R5, fr_empty
    const R2, BBUF
    LDW R3, R2                       ; len
    push R3                          ; len (the blk_read below clobbers R2/R3)
    const R2, BBUF + 9
    LDW R1, R2                       ; ext[0] = data lba
    call blk_read                    ; data -> BBUF
    pop R3                           ; len
    LDI R4, 0                        ; j
fr_copy:
    CMP3 R5, R4, R3                  ; j >= len -> done
    BRZP R5, fr_clamp
    const R2, BBUF
    ADD R2, R2, R4
    LDT R1, R2                       ; data tryte
    const R2, FBUF
    ADD R2, R2, R4
    STT R2, R1
    ADDI R4, R4, 1
    JMP fr_copy
fr_clamp:
    CMPI3 R5, R3, 729
    BRN R5, fr_ok
    LDI R3, 729                      ; single-extent clamp (v0.1)
fr_ok:
    ADD R1, R3, R0                   ; msg1 = trytes copied
    LDI R4, 0
    JMP fsm_reply
fr_empty:
    LDI R3, 0                        ; empty file: zero trytes
    LDI R4, 0
    JMP fsm_reply
fr_miss:
    LDI R3, -2                       ; missing
    LDI R4, 0
    JMP fsm_reply

fsop_write:                          ; op 7: WRITE(i) <- FBUF, len = M8LEN
    const R2, M8LEN
    LDW R3, R2
    CMPI3 R5, R3, 0
    BRN R5, fw_badlen
    CMPI3 R5, R3, 729
    BRP R5, fw_badlen
    ADD R1, R4, R0                   ; i
    call fs_lookup                   ; R1 = h_ref or 0
    CMPI3 R5, R1, 0
    BRZ R5, fw_miss
    ADD R4, R1, R0                   ; h_ref
    push R4                          ; h_ref (free_alloc clobbers R2..R5)
    ADD R1, R4, R0
    call blk_read                    ; header -> BBUF
    const R2, BBUF + 6
    LDW R2, R2                       ; ext count
    CMPI3 R5, R2, 0
    BRNZ R5, fw_have
    call free_alloc                  ; R1 = new data lba (IO on BB2: the
                                     ; staged header in BBUF is intact)
    CMPI3 R5, R1, 0
    BRN R5, fw_enomem
    push R1                          ; dref -> [R8], h_ref -> +3
    LDI R1, 1
    push R1                          ; newext -> [R8], dref +3, h_ref +6
    JMP fw_fill
fw_have:
    const R2, BBUF + 9
    LDW R1, R2                       ; ext[0] = dref
    push R1                          ; dref -> [R8], h_ref -> +3
    LDI R1, 0
    push R1                          ; newext -> [R8], dref +3, h_ref +6
fw_fill:                             ; stack: newext [R8], dref [+3], h_ref [+6]
    LDI R1, 0                        ; j
fw_cp:
    const R2, M8LEN
    LDW R3, R2                       ; len
    CMP3 R5, R1, R3                  ; j >= len -> pad the rest with zeros
    BRZP R5, fw_pad
    const R4, FBUF
    ADD R4, R4, R1
    LDT R5, R4                       ; content tryte
    const R4, BBUF
    ADD R4, R4, R1
    STT R4, R5
    ADDI R1, R1, 1
    JMP fw_cp
fw_pad:
    const R4, BBUF
    ADD R4, R4, R1
    LDI R5, 0
    STT R4, R5
    ADDI R1, R1, 1
    CMPI3 R5, R1, 729
    BRN R5, fw_pad
    const R1, BBUF
    call sum_calc                    ; R1 = sum over all 729 trytes (clobbers
    ADD R5, R1, R0                   ; R2..R5; R5 = sum survives the IO below)
    LEA R1, R8, 3
    LDW R1, R1                       ; dref
    call blk_write                   ; data block <- BBUF
    LEA R1, R8, 6
    LDW R1, R1                       ; h_ref
    call blk_read                    ; header -> BBUF (fresh copy to patch)
    const R2, M8LEN
    LDW R3, R2                       ; len
    const R4, BBUF
    STW R4, R3                       ; [BBUF+0] = len
    const R4, BBUF + 3
    STW R4, R5                       ; [BBUF+3] = sum
    LDI R3, 1
    const R4, BBUF + 6
    STW R4, R3                       ; [BBUF+6] = ext_count 1
    LDW R3, R8                       ; newext
    CMPI3 R5, R3, 0
    BRZ R5, fw_nodref
    LEA R2, R8, 3
    LDW R3, R2                       ; dref
    const R4, BBUF + 9
    STW R4, R3                       ; [BBUF+9] = ext[0] = dref
fw_nodref:
    LEA R1, R8, 6
    LDW R1, R1                       ; h_ref
    call blk_write                   ; header <- BBUF (the commit point)
    ADDI R8, R8, 9                   ; drop newext/dref/h_ref
    LDI R3, 0
    LDI R4, 0
    JMP fsm_reply
fw_badlen:
    LDI R3, -3                       ; len out of range (0..729)
    LDI R4, 0
    JMP fsm_reply
fw_miss:
    LDI R3, -2                       ; missing
    LDI R4, 0
    JMP fsm_reply
fw_enomem:
    ADDI R8, R8, 3                   ; drop the parked h_ref
    LDI R3, -3                       ; disk full
    LDI R4, 0
    JMP fsm_reply

fsop_nameset:                        ; op 8: NAMESET(i) — name in FBUF,
    push R4                          ; dir flag in M8DIR (0 file, nonzero dir);
    ADD R1, R4, R0                   ; i parked at [R8] (the scan reloads it)
    const R2, NTS
    ADD R4, R2, R0                   ; entry ptr
    LDI R3, 0                        ; update target (entry with same index)
    LDI R1, 0                        ; first free entry
fn_scan:
    LDW R6, R4                       ; entry index
    LDW R2, R8                       ; i
    CMP3 R6, R6, R2
    BRNZ R6, fn_notmatch
    ADD R3, R4, R0                   ; update in place
    JMP fn_scanend
fn_notmatch:
    LEA R6, R4, 3
    LDW R6, R6                       ; flags
    CMPI3 R5, R6, 0
    BRNZ R5, fn_next
    CMPI3 R5, R1, 0
    BRNZ R5, fn_next
    ADD R1, R4, R0                   ; remember the first free slot
fn_next:
    ADDI R4, R4, NTE
    const R2, NTS
    ADDI R2, R2, NTCNT * NTE
    CMP3 R6, R4, R2
    BRN R6, fn_scan
fn_scanend:
    CMPI3 R5, R3, 0
    BRNZ R5, fn_tgt                  ; update an existing entry in place
    CMPI3 R5, R1, 0
    BRZ R5, fn_full                  ; no match and no free entry -> full
    ADD R4, R1, R0                   ; new entry: target = first free entry
    JMP fn_set
fn_tgt:
    ADD R4, R3, R0                   ; target = the matching entry
fn_set:
    pop R1                           ; i
    STW R4, R1                       ; [entry+0] = index
    const R2, M8DIR
    LDW R3, R2
    CMPI3 R5, R3, 0
    BRZ R5, fn_file
    LDI R3, 2
    JMP fn_flag
fn_file:
    LDI R3, 1
fn_flag:
    LEA R5, R4, 3
    STW R5, R3                       ; [entry+3] = flags (1 file, 2 dir)
    LDI R3, 0                        ; j
fn_ncopy:
    CMPI3 R5, R3, 23
    BRZP R5, fn_nterm                ; cap the name at 23 trytes
    const R5, FBUF
    ADD R5, R5, R3
    LDT R6, R5                       ; name[j]
    BRZ R6, fn_nterm                 ; NUL ends the copy
    LEA R5, R4, 6
    ADD R5, R5, R3
    STT R5, R6                       ; entry.name[j]
    ADDI R3, R3, 1
    JMP fn_ncopy
fn_nterm:
    LEA R5, R4, 6
    ADD R5, R5, R3
    LDI R6, 0
    STT R5, R6                       ; NUL-terminate
    LDI R3, 0
    LDI R4, 0
    JMP fsm_reply
fn_full:
    pop R1                           ; balanced
    LDI R3, -3                       ; name table full
    LDI R4, 0
    JMP fsm_reply

fsop_nameget:                        ; op 9: name in FBUF -> msg1 = index,
    const R2, NTS                    ; msg2 = flags (1 file, 2 dir), -1 if none
    ADD R1, R2, R0
    push R1                          ; entry ptr (str_eq clobbers R1/R2)
fng_scan:
    LDW R1, R8
    LEA R2, R1, 3
    LDW R2, R2                       ; flags
    CMPI3 R5, R2, 0
    BRZ R5, fng_next
    LEA R1, R1, 6                    ; &entry.name
    const R2, FBUF
    call str_eq                      ; R3 = 1 if equal (clobbers R1, R2, R4..R6)
    CMPI3 R5, R3, 1
    BRZ R5, fng_hit
fng_next:
    LDW R1, R8
    ADDI R1, R1, NTE
    STW R8, R1                       ; ptr += NTE
    const R2, NTS
    ADDI R2, R2, NTCNT * NTE
    CMP3 R5, R1, R2
    BRN R5, fng_scan
    pop R1                           ; balanced
    LDI R3, -1                       ; no such name
    LDI R4, 0
    JMP fsm_reply
fng_hit:
    LDW R4, R8                       ; entry ptr
    LDW R3, R4                       ; msg1 = index
    LEA R4, R4, 3
    LDW R4, R4                       ; msg2 = flags
    pop R1                           ; drop the parked ptr (R3/R4 survive)
    JMP fsm_reply

fsop_list:                           ; op 10: LIST -> FBUF lines ("name\n",
    const R2, M8CNT                  ; dirs as "name/"), msg1 = trytes written
    LDI R1, 0
    STW R2, R1                       ; out pos = 0
    const R2, NTS
    ADD R4, R2, R0                   ; entry ptr (the fls_* helpers keep R4)
fls_scan:
    LEA R1, R4, 3
    LDW R1, R1                       ; flags
    CMPI3 R5, R1, 0
    BRZ R5, fls_next
    LEA R1, R4, 6
    call fls_name                    ; append the name
    LEA R1, R4, 3
    LDW R1, R1                       ; flags (fls_name clobbered R1)
    CMPI3 R5, R1, 2
    BRNZ R5, fls_file
    LDI R1, 47                       ; '/'
    call fls_putc
fls_file:
    LDI R1, 10                       ; newline
    call fls_putc
fls_next:
    ADDI R4, R4, NTE
    const R2, NTS
    ADDI R2, R2, NTCNT * NTE
    CMP3 R5, R4, R2
    BRN R5, fls_scan
    const R3, M8CNT
    LDW R3, R3                       ; msg1 = trytes
    LDI R4, 0
    JMP fsm_reply

fls_putc:                            ; R1 = char -> FBUF[M8CNT++]
    const R3, M8CNT
    LDW R2, R3                       ; pos
    const R5, FBUF
    ADD R5, R5, R2
    STT R5, R1                       ; FBUF[pos] = char
    ADDI R2, R2, 1
    STW R3, R2                       ; pos++
    ret

fls_name:                            ; R1 = &name -> append chars until NUL
    push R7
    push R1                          ; ptr (fls_putc clobbers R2/R3/R5)
fln_loop:
    LDW R1, R8
    LDT R2, R1                       ; char
    BRZ R2, fln_done
    ADD R1, R2, R0                   ; char arg
    call fls_putc
    LDW R1, R8
    ADDI R1, R1, 1
    STW R8, R1                       ; ptr++
    JMP fln_loop
fln_done:
    pop R1
    pop R7
    ret

fsop_nameclr:                        ; op 11: NAMECLEAR(i) — remove the name
    push R4                          ; i (no calls below, R3 survives)
    const R2, NTS
    ADD R3, R2, R0                   ; entry ptr
fnc_scan:
    LDW R5, R3                       ; entry index
    LDW R1, R8                       ; i
    CMP3 R5, R5, R1
    BRNZ R5, fnc_next
    LEA R5, R3, 3
    LDW R1, R5                       ; flags
    CMPI3 R6, R1, 0                  ; R6 = compare (R5 must survive: it is
    BRZ R6, fnc_next                 ; the flags address for the STW below)
    LDI R1, 0
    STW R5, R1                       ; flags = 0 (freed)
    pop R4
    LDI R3, 0
    LDI R4, 0
    JMP fsm_reply
fnc_next:
    ADDI R3, R3, NTE
    const R2, NTS
    ADDI R2, R2, NTCNT * NTE
    CMP3 R5, R3, R2
    BRN R5, fnc_scan
    pop R4
    LDI R3, -1                       ; no such name
    LDI R4, 0
    JMP fsm_reply

fsop_mkdir:                          ; op 12: MKDIR — name in FBUF; registers a
    const R2, NTS                    ; directory entry (index = -1, D-047:
                                     ; the namespace is server-side only, the
                                     ; on-disk format stays flat)
    ADD R3, R2, R0                   ; entry ptr (parked across str_eq below)
    LDI R4, 0                        ; first free entry
fmd_scan:
    LEA R5, R3, 3
    LDW R5, R5                       ; flags
    CMPI3 R6, R5, 0
    BRNZ R6, fmd_occ
    CMPI3 R6, R4, 0
    BRNZ R6, fmd_adv
    ADD R4, R3, R0                   ; remember the first free slot
    JMP fmd_adv
fmd_occ:
    push R3                          ; park the entry ptr AND the first-free
    push R4                          ; ptr across str_eq (it returns its result
    LEA R1, R3, 6                    ; in R3 and clobbers R1/R2/R4..R6 — D-045)
    const R2, FBUF
    call str_eq                      ; R3 = 1 if the name is already used
    CMPI3 R5, R3, 1
    pop R4                           ; restore first-free ptr (R5 survives)
    pop R3                           ; restore entry ptr
    BRZ R5, fmd_exists
fmd_adv:
    ADDI R3, R3, NTE
    const R2, NTS
    ADDI R2, R2, NTCNT * NTE
    CMP3 R5, R3, R2
    BRN R5, fmd_scan
    CMPI3 R5, R4, 0
    BRZ R5, fmd_full
    LDI R1, -1
    STW R4, R1                       ; [entry+0] = index -1 (no file slot)
    LDI R1, 2
    LEA R5, R4, 3
    STW R5, R1                       ; flags = dir
    LDI R2, 0                        ; j
fmd_cp:
    CMPI3 R5, R2, 23
    BRZP R5, fmd_term
    const R5, FBUF
    ADD R5, R5, R2
    LDT R1, R5                       ; name[j]
    BRZ R1, fmd_term
    LEA R5, R4, 6
    ADD R5, R5, R2
    STT R5, R1
    ADDI R2, R2, 1
    JMP fmd_cp
fmd_term:
    LEA R5, R4, 6
    ADD R5, R5, R2
    LDI R1, 0
    STT R5, R1                       ; NUL-terminate
    LDI R3, 0
    LDI R4, 0
    JMP fsm_reply
fmd_exists:
    LDI R3, -5                       ; name already in use
    LDI R4, 0
    JMP fsm_reply
fmd_full:
    LDI R3, -3                       ; name table full
    LDI R4, 0
    JMP fsm_reply

fs_lookup:                           ; R1 = slot i -> R1 = h_ref or 0 (clobbers
    push R7                          ; R2..R5; keeps R6)
    push R2
    push R3
    push R4
    push R5
    ADD R4, R1, R0                   ; i
    LDI R1, FS_BASE
    call blk_read                    ; super -> BBUF
    const R3, BBUF + SB_ROOT
    LDW R3, R3                       ; cur = root
    LDI R5, 0                        ; k
fl_kloop:
    MULI R2, R5, DIR_REFS
    CMP3 R2, R4, R2
    BRN R2, fl_kdone
    ADDI R5, R5, 1
    CMPI3 R2, R5, 6
    BRN R2, fl_kloop
fl_kdone:
    ADDI R5, R5, -1                  ; k
    MULI R2, R5, DIR_REFS
    SUB R2, R4, R2                   ; s = i - k*241
    push R2                          ; s [R8]
fl_walk:
    CMPI3 R1, R5, 0
    BRZ R1, fl_at
    ADD R1, R3, R0
    call blk_read                    ; cur -> BBUF
    const R3, BBUF + 3
    LDW R3, R3                       ; cur = next
    ADDI R5, R5, -1
    JMP fl_walk
fl_at:
    ADD R1, R3, R0
    call blk_read                    ; the level-k dir block -> BBUF
    pop R2                           ; s
    MULI R3, R2, 3
    ADDI R3, R3, 6
    const R2, BBUF
    ADD R2, R2, R3
    LDW R1, R2                       ; h_ref
    pop R5
    pop R4
    pop R3
    pop R2
    pop R7
    ret

fs_check_one:                        ; R1 = i -> R1 = status (clobbers R2..R5,
    push R7                          ; keeps R6)
    push R2
    push R3
    push R4
    push R5
    ADD R4, R1, R0                   ; i
    ADD R1, R4, R0
    call fs_lookup                   ; R1 = h_ref (clobbers R2/R3; R4 = i kept)
    CMPI3 R5, R1, 0
    BRZ R5, fcm_missing
    ADD R1, R1, R0
    call blk_read                    ; header -> BBUF
    const R2, BBUF + 3
    LDW R3, R2                       ; expected sum
    push R3                          ; expected [R8+3]
    LDI R2, 0
    push R2                          ; acc [R8]
    const R2, BBUF + 6
    LDW R5, R2                       ; ext count
    LDI R4, 0                        ; e
fcm_ext:
    CMP3 R1, R4, R5
    BRZP R1, fcm_cmp
    MULI R1, R4, 3
    ADDI R1, R1, 9
    const R2, BBUF
    ADD R1, R2, R1
    LDW R1, R1                       ; d_ref
    ADD R1, R1, R0
    call blk_read                    ; data -> BBUF
    const R1, BBUF
    call sum_calc                    ; R1 = ext sum
    LDW R2, R8                       ; acc
    ADD R2, R2, R1                   ; acc += ext sum
    STW R8, R2                       ; store back
    ADDI R4, R4, 1
    JMP fcm_ext
fcm_cmp:
    pop R1                           ; acc = file sum
    pop R3                           ; expected
    CMP3 R2, R1, R3
    BRNZ R2, fcm_corrupt
    LDI R1, 0                        ; ok
    pop R5
    pop R4
    pop R3
    pop R2
    pop R7
    ret
fcm_corrupt:
    ; NOTE: fcm_cmp already popped acc+expected before branching here —
    ; an extra drop here double-freed 6 trytes and corrupted R7 (the "wild
    ; jump into the boot region" M7 bug). Only the register saves remain.
    LDI R1, -1
    pop R5
    pop R4
    pop R3
    pop R2
    pop R7
    ret
fcm_missing:
    LDI R1, -2
    pop R5
    pop R4
    pop R3
    pop R2
    pop R7
    ret


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
    JMP p6_start                     ; phase 6 (SEND/RECV ping-pong) unparked;
                                     ; phase 7 + the M6 console phase follow
                                     ; once the handoff is proven stable

m5_done:
    ; (M5 phases 6-7 — CALL/REPLY ping-pong + fuzz — are parked, see
    ;  BUG_M5_NOTES.md: the handshake deadlock needs a fresh session)
    LDI R1, 17                       ; EP_CREATE console endpoint
    LDI R2, 2                        ; badge
    TRAP 0
    CMPI3 R5, R1, 0
    BRN R5, st_fail2
    const R3, XGRAND
    STW R3, R1                       ; XGRAND slot reused as the console cap
    const R2, wr_consv
    const R3, XGRAND
    LDW R4, R3                       ; arg = console cap
    LDI R3, 0                        ; class = normal (loaded LAST: the const
                                     ; above would clobber R3)
    LDI R1, 3
    TRAP 0                           ; create the console server
    LDI R1, 1                        ; YIELD: let it RECV-block
    TRAP 0
    ; echo 'A' through the console server
    const R3, XGRAND
    LDW R2, R3
    LDI R3, 65                       ; 'A'
    LDI R1, 8                        ; SEND
    TRAP 0
    ; echo 'B'
    const R3, XGRAND
    LDW R2, R3
    LDI R3, 66
    LDI R1, 8
    TRAP 0
    ; panic: the console server exits on request -1
    const R3, XGRAND
    LDW R2, R3
    LDI R3, -1
    LDI R1, 8
    TRAP 0
    ; the console is down: NBSEND must fail now (a blocking SEND would park
    ; init on the empty sender queue forever)
    const R3, XGRAND
    LDW R2, R3
    LDI R3, 67
    LDI R1, 12                       ; NBSEND
    TRAP 0
    CMPI3 R5, R1, 0
    BRZ R5, st_fail2                 ; must fail: the server crashed
    const R1, str_condown
    call puts
    ; init restarts the console server on the SAME endpoint (the cap survives)
    const R2, wr_consv
    const R3, XGRAND
    LDW R4, R3                       ; arg = console cap
    LDI R3, 0                        ; class = normal (loaded LAST)
    LDI R1, 3
    TRAP 0
    CMPI3 R5, R1, 0
    BRN R5, st_fail2
    LDI R1, 1                        ; YIELD: let the new server RECV-block
    TRAP 0
    const R3, XGRAND
    LDW R2, R3
    LDI R3, 82                       ; 'R'
    LDI R1, 8
    TRAP 0                           ; echo 'R' through the new server
    const R1, str_restart
    call puts

    ; ---- M7 phase: TriFS (D-042) ----
    const R2, SNAP_ARMED
    LDI R1, 0
    STW R2, R1                       ; BSS init (D-032): snapshot disarmed
    LDI R1, 17                       ; EP_CREATE the fs endpoint
    LDI R2, 4                        ; badge
    TRAP 0
    CMPI3 R5, R1, 0
    BRN R5, st_fail2
    const R3, XFS
    STW R3, R1
    const R2, fs_main
    const R4, XFS
    LDW R4, R4                       ; arg = fs cap
    LDI R3, 0                        ; class = normal (loaded LAST)
    LDI R1, 3
    TRAP 0                           ; create the fs server
    CMPI3 R5, R1, 0
    BRN R5, st_fail2
    LDI R1, 1                        ; YIELD: let it RECV-block
    TRAP 0
    ; STATUS decides: root == 0 -> fresh fs (run the workload); an existing
    ; root (power-cut resume or repeated boot) runs the fsck path only
    const R3, XFS
    LDW R2, R3                       ; cap re-read per call (D-041)
    LDI R3, 4                        ; STATUS
    LDI R4, 0
    LDI R1, 10                       ; CALL
    TRAP 0                           ; R3 = root, R4 = gen
    CMPI3 R5, R3, 0
    BRN R5, m5_done2                 ; fs unavailable (small disk): skip M7
    BRZ R5, m7_create                ; root == 0: fresh workload
    JMP m7_fsck                      ; root > 0: fsck (resume/reboot)
    ; fresh: create 1000 files
    LDI R5, 0
m7_create:
    const R3, XFS
    LDW R2, R3
    LDI R3, 1                        ; CREATE
    ADD R4, R5, R0                   ; index = i
    LDI R1, 10                       ; CALL
    TRAP 0
    CMPI3 R2, R3, 0
    BRNZ R2, st_fail2
    ADDI R5, R5, 1
    CMPI3 R2, R5, 1000
    BRN R2, m7_create
    ; check all 1000
    LDI R5, 0
m7_check:
    const R3, XFS
    LDW R2, R3
    LDI R3, 2                        ; CHECK
    ADD R4, R5, R0
    LDI R1, 10
    TRAP 0
    CMPI3 R2, R3, 0
    BRNZ R2, st_fail2
    ADDI R5, R5, 1
    CMPI3 R2, R5, 1000
    BRN R2, m7_check
    ; delete 0..499
    LDI R5, 0
m7_del:
    const R3, XFS
    LDW R2, R3
    LDI R3, 3                        ; DELETE
    ADD R4, R5, R0
    LDI R1, 10
    TRAP 0
    CMPI3 R2, R3, 0
    BRNZ R2, st_fail2
    ADDI R5, R5, 1
    CMPI3 R2, R5, 500
    BRN R2, m7_del
    ; deleted slots must report missing (-2)
    LDI R5, 0
m7_chkd:
    const R3, XFS
    LDW R2, R3
    LDI R3, 2
    ADD R4, R5, R0
    LDI R1, 10
    TRAP 0
    CMPI3 R2, R3, -2
    BRNZ R2, st_fail2
    ADDI R5, R5, 1
    CMPI3 R2, R5, 500
    BRN R2, m7_chkd
    ; 500..999 must still check ok
m7_kee:
    const R3, XFS
    LDW R2, R3
    LDI R3, 2
    ADD R4, R5, R0
    LDI R1, 10
    TRAP 0
    CMPI3 R2, R3, 0
    BRNZ R2, st_fail2
    ADDI R5, R5, 1
    CMPI3 R2, R5, 1000
    BRN R2, m7_kee
    const R1, str_m7ok
    call puts

    ; ---- M7 snapshot round-trip (ops 13/14): SAVE -> 5 post-snapshot files
    ; -> RESTORE -> the extras must be gone, the pre-snapshot tree intact.
    const R3, XFS
    LDW R2, R3
    LDI R3, 13                        ; SNAPSHOT_SAVE
    LDI R4, 0
    LDI R1, 10
    TRAP 0
    const R2, SNAP_TEST
    STW R2, R3                        ; park saved gen (calls clobber regs)
    ; create files 1000..1004 (post-snapshot)
    LDI R5, 1000
m7_snap_create:
    const R3, XFS
    LDW R2, R3
    LDI R3, 1                         ; CREATE
    ADD R4, R5, R0
    LDI R1, 10
    TRAP 0
    CMPI3 R2, R3, 0
    BRNZ R2, st_fail2
    ADDI R5, R5, 1
    CMPI3 R2, R5, 1005
    BRN R2, m7_snap_create
    ; extras must check ok BEFORE the restore
    LDI R5, 1000
m7_snap_chk1:
    const R3, XFS
    LDW R2, R3
    LDI R3, 2
    ADD R4, R5, R0
    LDI R1, 10
    TRAP 0
    CMPI3 R2, R3, 0
    BRNZ R2, st_fail2
    ADDI R5, R5, 1
    CMPI3 R2, R5, 1005
    BRN R2, m7_snap_chk1
    ; RESTORE
    const R3, XFS
    LDW R2, R3
    LDI R3, 14                        ; SNAPSHOT_RESTORE
    LDI R4, 0
    LDI R1, 10
    TRAP 0
    ; R3 = saved gen (monotonic gen kept: current+1 written on-disk)
    CMPI3 R2, R3, 0
    BRN R2, st_fail2                  ; restore must succeed (gen >= 0)
    ; extras must be missing AFTER the restore
    LDI R5, 1000
m7_snap_chk2:
    const R3, XFS
    LDW R2, R3
    LDI R3, 2
    ADD R4, R5, R0
    LDI R1, 10
    TRAP 0
    CMPI3 R2, R3, -2
    BRNZ R2, st_fail2                 ; must be missing
    ADDI R5, R5, 1
    CMPI3 R2, R5, 1005
    BRN R2, m7_snap_chk2
    ; 500..999 survivors must still check ok
    LDI R5, 500
m7_snap_keep:
    const R3, XFS
    LDW R2, R3
    LDI R3, 2
    ADD R4, R5, R0
    LDI R1, 10
    TRAP 0
    CMPI3 R2, R3, 0
    BRNZ R2, st_fail2
    ADDI R5, R5, 1
    CMPI3 R2, R5, 1000
    BRN R2, m7_snap_keep
    const R1, str_snapok
    call puts
    JMP m5_done2
m7_fsck:
    const R3, XFS
    LDW R2, R3
    LDI R3, 5                        ; FSCK
    LDI R4, 0
    LDI R1, 10
    TRAP 0                           ; R3 = ok count, R4 = total
    push R4                          ; park the reply on the stack: puts
    push R3                          ; clobbers R3 (its string pointer), so
    const R1, str_fsck               ; an earlier version printed
    call puts                        ; str_fsck+6 (=30588) as the ok count
    pop R1                           ; ok
    call putnum
    LDI R1, 47                       ; '/'
    call putc
    pop R1                           ; total
    call putnum
    LDI R1, 10
    call putc
    JMP m5_done2

m5_done2:                            ; init: ready. Console input waiting ->
                                     ; hand the system to the shell; headless
                                     ; boot -> clean power-off.
    const R1, str_ready
    call puts
    const R2, UART_STAT
    LDT R3, R2                       ; nonzero = input pending
    BRZ R3, m6_off
    ; ---- M8 phase: stage the hello program into TriFS when a shell session
    ; starts on a usable fs. Headless boots (all regression tests) and small
    ; disks skip it, so existing tests never see slot 1000. D-046.
    const R2, FS_OKFLAG
    LDW R3, R2
    CMPI3 R5, R3, 0
    BRNZ R5, m6_shell                ; fs unavailable: no staging
    call m8_stage
m6_shell:
    const R2, shell_main
    LDI R3, 0                        ; class = normal
    LDI R4, 0                        ; arg
    LDI R1, 3                        ; THREAD_CREATE(shell)
    TRAP 0
m6_park:
    LDI R1, 1                        ; YIELD forever: the shell runs the system
    TRAP 0
    JMP m6_park
m6_off:
    const R1, POWER
    LDI R2, 1
    STW R1, R2                       ; clean power-off
m4_park:
    LDI R1, 1                        ; YIELD (only reached if power-off failed)
    TRAP 0
    JMP m4_park

m8_stage:                            ; stage the hello program into TriFS
    push R7                          ; (init thread; idempotent across reboots:
                                     ; NAMEGET finds an existing "hello" and
                                     ; only the content is rewritten)
    ; FBUF = "hello"
    LDI R2, 0                        ; j
m8_ncp:
    const R3, str_hello
    ADD R3, R3, R2
    LDT R1, R3
    BRZ R1, m8_ncend
    const R3, FBUF
    ADD R3, R3, R2
    STT R3, R1
    ADDI R2, R2, 1
    JMP m8_ncp
m8_ncend:
    const R3, FBUF
    ADD R3, R3, R2
    LDI R1, 0
    STT R3, R1                       ; NUL
    const R3, M8DIR
    LDI R2, 0
    STW R3, R2                       ; file flag
    const R3, XFS
    LDW R2, R3
    LDI R3, 9                        ; NAMEGET
    LDI R4, 0
    LDI R1, 10                       ; CALL
    TRAP 0                           ; R3 = idx or -1
    CMPI3 R5, R3, 0
    BRP R5, m8_write                 ; already staged: rewrite the content
    ; fresh session: create at slot 1000 (the M7 workload owns 0..999 and
    ; runs headless only, so interactive boots never collide with it)
    const R3, XFS
    LDW R2, R3
    LDI R3, 1                        ; CREATE
    LDI R4, 1000
    LDI R1, 10
    TRAP 0
    CMPI3 R5, R3, 0
    BRN R5, m8s2                     ; staging failed (no slot / no blocks)
    const R3, M8DIR
    LDI R2, 0
    STW R3, R2
    const R3, XFS
    LDW R2, R3
    LDI R3, 8                        ; NAMESET
    LDI R4, 1000
    LDI R1, 10
    TRAP 0
m8_write:
    ; copy the embedded TXE into FBUF
    LDI R2, 0                        ; j
m8_tcp:
    CMPI3 R5, R2, HELLO_TXE_LEN
    BRZP R5, m8_twr
    const R3, hello_txedata
    ADD R3, R3, R2
    LDT R1, R3
    const R3, FBUF
    ADD R3, R3, R2
    STT R3, R1
    ADDI R2, R2, 1
    JMP m8_tcp
m8_twr:
    const R3, M8LEN
    LDI R2, HELLO_TXE_LEN
    STW R3, R2
    const R3, XFS
    LDW R2, R3
    LDI R3, 7                        ; WRITE
    LDI R4, 1000
    LDI R1, 10
    TRAP 0                           ; R3 = status (content committed)
    const R1, str_m8ok
    call puts
    ; ---- second demo program: spin (an endless YIELD loop, the kill target)
m8s2:
    LDI R2, 0                        ; j
m8s2_ncp:
    const R3, str_spin
    ADD R3, R3, R2
    LDT R1, R3
    BRZ R1, m8s2_ncend
    const R3, FBUF
    ADD R3, R3, R2
    STT R3, R1
    ADDI R2, R2, 1
    JMP m8s2_ncp
m8s2_ncend:
    const R3, FBUF
    ADD R3, R3, R2
    LDI R1, 0
    STT R3, R1                       ; NUL
    const R3, M8DIR
    LDI R2, 0
    STW R3, R2
    const R3, XFS
    LDW R2, R3
    LDI R3, 9                        ; NAMEGET
    LDI R4, 0
    LDI R1, 10
    TRAP 0
    CMPI3 R5, R3, 0
    BRP R5, m8s2_write
    const R3, XFS
    LDW R2, R3
    LDI R3, 1                        ; CREATE
    LDI R4, 1001
    LDI R1, 10
    TRAP 0
    CMPI3 R5, R3, 0
    BRN R5, m8_done
    const R3, M8DIR
    LDI R2, 0
    STW R3, R2
    const R3, XFS
    LDW R2, R3
    LDI R3, 8                        ; NAMESET
    LDI R4, 1001
    LDI R1, 10
    TRAP 0
m8s2_write:
    LDI R2, 0                        ; j
m8s2_tcp:
    CMPI3 R5, R2, SPIN_TXE_LEN
    BRZP R5, m8s2_twr
    const R3, spin_txedata
    ADD R3, R3, R2
    LDT R1, R3
    const R3, FBUF
    ADD R3, R3, R2
    STT R3, R1
    ADDI R2, R2, 1
    JMP m8s2_tcp
m8s2_twr:
    const R3, M8LEN
    LDI R2, SPIN_TXE_LEN
    STW R3, R2
    const R3, XFS
    LDW R2, R3
    LDI R3, 7                        ; WRITE
    LDI R4, 1001
    LDI R1, 10
    TRAP 0
m8_done:
    pop R7
    ret

    ; ---- phase 6: SEND/RECV ping-pong on the master endpoint ----
    ; the cap lives in XC2 (reused: phase 5 is done) and is RE-READ every
    ; iteration — a register copy would have to survive timer preemptions
p6_start:
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
    const R6, XC2                    ; R6 = &cap slot (stable across iterations:
                                     ; R3 carries the request, R2 the cap)
    LDW R2, R6                       ; cap re-read every iteration
    ADD R3, R5, R0                   ; request = i (AFTER the cap load: const
                                     ; would otherwise overwrite the request)
    LDI R4, 0
    LDI R1, 8                        ; SEND (blocks until the server RECVs)
    TRAP 0
    LDW R2, R6                       ; cap for the RECV (R6 = &XC2 survives)
    LDI R1, 9                        ; RECV the reply
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
    MULI R6, R5, 12
    const R7, FTAB
    ADD R6, R7, R6                   ; R6 = &row (R2 must stay free: it receives
                                     ; arg1 — reusing R2 as the pointer made the
                                     ; next LEA load from the arg VALUE)
    LDW R1, R6                       ; num
    LEA R6, R6, 3
    LDW R2, R6                       ; arg1
    LEA R6, R6, 3
    LDW R3, R6                       ; arg2
    LEA R6, R6, 3
    LDW R4, R6                       ; arg3
    TRAP 0
    ADDI R5, R5, 1
    CMPI3 R2, R5, FZROWS
    BRN R2, fz_loop
    const R1, str_fuzz_ok
    call puts
    JMP m5_done                      ; the M6 console phase follows

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
str_condown:     .asciz "init: console down\n"
str_restart:     .asciz "init: console restarted\n"
str_shello:      .asciz "\nSetun shell (type help)\n"
str_prompt:      .asciz "$ "
str_help:        .asciz "builtins: help ver echo <text> ls ps cat <name> ed <name> rm <name> cp <a> <b> mkdir <name> tstat <tid> kill <tid> exec <name> pipe crash halt\n"
str_ver:         .asciz "Setun Tri OS v0.1 (ternary)\n"
str_cmd_help:    .asciz "help"
str_cmd_ver:     .asciz "ver"
str_cmd_crash:   .asciz "crash"
str_cmd_halt:    .asciz "halt"
str_cmd_echo:    .asciz "echo "
str_unknown:     .asciz "unknown command\n"
str_cmd_ls:      .asciz "ls"
str_cmd_ps:      .asciz "ps"
str_cmd_pipe:    .asciz "pipe"
str_cmd_cat:     .asciz "cat"
str_cmd_ed:      .asciz "ed"
str_cmd_rm:      .asciz "rm"
str_cmd_cp:      .asciz "cp"
str_cmd_mkdir:   .asciz "mkdir"
str_cmd_tstat:   .asciz "tstat"
str_cmd_kill:    .asciz "kill"
str_cmd_exec:    .asciz "exec"
str_noent:       .asciz "no such name\n"
str_fserr:       .asciz "fs error\n"
str_pserr:       .asciz "ps error\n"
str_rmok:        .asciz "rm ok\n"
str_cpok:        .asciz "cp ok\n"
str_mkok:        .asciz "mkdir ok\n"
str_exists:      .asciz "mkdir: name exists\n"
str_edok:        .asciz "ed: saved\n"
str_exectid:     .asciz "exec: tid "
str_execerr:     .asciz "exec error\n"
str_nothread:    .asciz "no such thread\n"
str_killok:      .asciz "killed\n"
str_killbad:     .asciz "kill refused\n"
str_pipeerr:     .asciz "pipe error\n"
str_usage:       .asciz "usage: cp <src> <dst>\n"
str_pipedata:    .asciz "ternary pipe ok"
str_m8ok:        .asciz "m8: hello program staged\n"
str_hello:       .asciz "hello"
str_spin:        .asciz "spin"
str_conrestart:  .asciz "console restarted\n"
str_m7ok:        .asciz "fs: 1000 created+checked, 500 deleted, ok\n"
str_snapok:      .asciz "fs: snapshot save/restore ok\n"
str_fsck:        .asciz "fsck: "
str_test_fail:   .asciz "self-test: FAIL\n"
.equ FZROWS,     16

.align 3                             ; the string literals above are byte-granular;
FTAB:   .word 8, 999, 0, 0           ; FTAB is LDW-read and must stay word-aligned
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

; ---- M8: embedded hello TXE (generated by tools/mk.py from user/hello.asm;
; staged into TriFS as name "hello" on interactive boots, D-046) ---------------
    .include "hello_txedata.asm"

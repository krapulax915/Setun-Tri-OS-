; kernel.asm — Setun Tri OS "Triad" microkernel, M3 stage.
;
; Boots from the boot sector (physical addressing, PTBR == 0, mode +):
;   1. prints the boot banner,
;   2. arms the trap vector (TVEC) and survives ILLEGAL/DIV0 (D-031),
;   3. initialises the ternary buddy allocator (D-030) and self-tests it,
;   4. powers off cleanly (M4 replaces this with the scheduler).
;
; Memory map (physical):
;   7290            kernel code
;   30000           kernel strings
;   1000000         buddy state / free lists / save area / node array
;   4700001         kernel stack top

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
    .equ KDATA_END,  NODES+18396
    .equ RES_END,    1411               ; frames [0, 1411) reserved
    .equ STK_LO,     6446
    .equ STK_HI,     6448
    .equ KSTACK,     4700001
    .equ FREE_FRAMES, 5147              ; 6561 - 1411(reserved) - 3(stack)
    .equ FREE_TEST,   240               ; boot self-test allocation count

    .org KERNEL_LOAD
    .entry main

; ------------------------------------------------------------------------------
; main
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
    const R1, str_ready
    call puts
    const R1, POWER
    LDI R2, 1
    STW R1, R2                       ; clean power-off
td_fail:
    const R1, str_trap_fail
    call puts
    const R1, POWER
    LDI R2, 1
    STW R1, R2

; ------------------------------------------------------------------------------
; trap_handler — entered with R1..R8 = interrupted values, PC = TVEC (D-017)
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
    ; dispatch on CAUSE sign: 0 syscall, negative exception, positive IRQ
    CSRR R1, CAUSE
    CMPI3 R5, R1, 0
    BRZ R5, th_sys
    BRN R5, th_exc
    const R1, str_irq
    call puts
    CSRR R1, CAUSE
    call putnum
    LDI R1, 10
    call putc
    JMP th_resume_same
th_sys:
    const R1, str_syscall
    call puts
    CSRR R1, TVAL
    call putnum
    LDI R1, 10
    call putc
    JMP th_resume_same
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
th_resume_same:
    ; restore R1..R8 (order: R8 slot holds the old SP)
    LDW R6, R8                       ; R6 = old SP
    ADDI R8, R8, 3                   ; SP -> R7 slot
    pop R7
    pop R6
    pop R5
    pop R4
    pop R3
    pop R2
    pop R1
    RETI                             ; PC = EPC; mode/irq from PSW

; ------------------------------------------------------------------------------
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
; ternary buddy allocator (D-030)
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
    BRZP R5, ba_none
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

; BSS (D-032): the KDATA region below is never stored in the TXE — every byte of
; it is initialised before first read (buddy_init writes all states and heads;
; push_free writes FREE_NEXT before pop_free/list_remove read it; pnumbuf, ksave
; and the nodes array are written before use).

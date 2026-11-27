; ==== Tern-generated TXE (user program, D-046/D-048) ====
    .include "lib/trilib.asm"
    .org 4707002
    .entry tern_main
TERN_CAP_SLOT: .word 0       ; parked create-arg (cap ref)

tern_recv:                    ; -> R1 = msg (0 = no sender)
    push R7
    LDI R1, 9                  ; RECV
    const R2, TERN_CAP_SLOT
    LDW R2, R2
    TRAP 0
    ADD R1, R3, R0             ; msg1 -> result
    pop R7
    ret

tern_send:                    ; R1 = msg -> SEND
    push R7
    push R1
    LDI R1, 8                  ; SEND
    const R2, TERN_CAP_SLOT
    LDW R2, R2
    pop R3                     ; msg1
    TRAP 0
    pop R7
    ret

tern_reply:                   ; R1 = msg -> REPLY
    push R7
    push R1
    LDI R1, 11                 ; REPLY
    const R2, TERN_CAP_SLOT
    LDW R2, R2
    pop R3                     ; reply msg1
    TRAP 0
    pop R7
    ret

tern_putchar:                 ; R1 = char -> DEBUG_PUTC (6)
    push R7
    push R1
    LDI R1, 6
    pop R2                     ; char into arg slot
    TRAP 0
    pop R7
    ret

tern_puts:                    ; R1 = &msg (NUL-terminated)
    push R7
    ADD R3, R1, R0
Ltp_loop:
    LDT R2, R3
    BRZ R2, Ltp_done
    push R3
    ADD R1, R2, R0
    call tern_putchar
    pop R3
    ADDI R3, R3, 1
    JMP Ltp_loop
Ltp_done:
    pop R7
    ret

tern_exit:                    ; EXIT (2): thread reaped
    LDI R1, 2
    TRAP 0
    ret

tern_main:
    push R7
    const R2, TERN_CAP_SLOT
    STW R2, R1                 ; park create-arg (cap)
    const R1, 0
    push R1
    LEA R2, R8, -3
    pop R1
    STW R2, R1
while1:
    const R1, 1
    BRZ R1, endwhile2
    call tern_recv
    push R1
    LEA R2, R8, -3
    pop R1
    STW R2, R1
    const R1, 1
    push R1
    LEA R1, R8, -3
    LDW R1, R1
    pop R2
    ADD R1, R1, R2
    push R1
    call tern_reply
    pop R1
    JMP while1
endwhile2:
    const R1, 0
    push R1
    call tern_exit
    pop R1
    call tern_exit

; ==== STRING DATA ====
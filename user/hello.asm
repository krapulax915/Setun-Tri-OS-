; user/hello.asm — M8 demo program (D-046). The kernel's interactive-boot
; phase stores this TXE in TriFS under the name "hello"; `exec hello` loads
; it through the EXEC syscall into the program region and runs it as a
; thread. It prints one line via the DEBUG_PUTC syscall (num 6, char in R2)
; and exits, freeing its stack (the scheduler reaps the slot cleanly).
    .include "lib/trilib.asm"
    .org 4705002                     ; must be word-aligned (4705002 % 3 == 0):
    .entry hello_main                ; branch targets are ALIGN-checked, so the
hello_main:                          ; whole image sits on a 3-tryte boundary
    const R1, hello_msg
    call hello_puts
    LDI R1, 2                        ; EXIT
    TRAP 0
hello_puts:                          ; R1 = &msg (NUL-terminated TriText)
    push R7
    ADD R3, R1, R0
hp_loop:
    LDT R2, R3                       ; char (syscall arg slot = caller R2)
    BRZ R2, hp_done
    LDI R1, 6                        ; DEBUG_PUTC
    TRAP 0
    ADDI R3, R3, 1
    JMP hp_loop
hp_done:
    pop R7
    ret
hello_msg:  .asciz "hello from a loaded program\n"

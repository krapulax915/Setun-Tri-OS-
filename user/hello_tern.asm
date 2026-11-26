; ==== Tern-generated TriASM (kernel-integrated) ====

.include "kernel/kernel.asm"

; ==== STRING LITERALS ====
.org STRBASE

; ==== TERN PROGRAM ENTRY ====
tern_main:
    push R7
    const R1, .Lstr1
    push R1
    call puts
    pop R1
    const R1, 0
    ret

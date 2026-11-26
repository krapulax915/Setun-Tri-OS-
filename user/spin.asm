; user/spin.asm — M8 demo program: an endless YIELD loop. The shell's
; `exec spin` loads it via EXEC (D-046); the thread stays READY forever,
; which makes it the scripted kill target for the M8 acceptance session.
    .include "lib/trilib.asm"
    .org 4706001                     ; word-aligned (4706001 % 3 == 0) — see hello
    .entry spin_main
spin_main:
    LDI R1, 1                        ; YIELD (stays ready, never exits)
    TRAP 0
    JMP spin_main

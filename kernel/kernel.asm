; kernel.asm — M2 stub kernel: prints the greeting over UART, powers off.
; From M3 on this grows into the Triad microkernel (M3..M5) with real boot.

    .include "lib/trilib.asm"

    .equ MMIO,      128608722
    .equ UART_TX,   MMIO+0
    .equ POWER,     MMIO+27
    .equ KERNEL_LOAD, 7290            ; block 10
    .equ STACK_TOP, 4700000

    .org KERNEL_LOAD
    .entry main

main:
    const R8, STACK_TOP
    const R1, UART_TX
    const R3, hello
print:
    LDT R2, R3
    BRZ R2, done
    STT R1, R2                     ; UART TX <- tryte
    ADDI R3, R3, 1
    JMP print
done:
    const R1, POWER
    LDI R2, 1
    STW R1, R2                     ; clean power-off
hello:
    .asciz "Hello, ternary world!\n"

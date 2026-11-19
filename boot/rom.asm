; rom.asm — TVM boot ROM (physical addresses; PTBR=0 -> MMU off, mode +)
;
; Reads disk block 0 (the boot sector) into RAM scratch and jumps to it.

    .include "lib/trilib.asm"

    .equ MMIO,     128608722        ; D-011
    .equ UART_TX,  MMIO+0
    .equ BLK_LBA,  MMIO+12
    .equ BLK_BUF,  MMIO+15
    .equ BLK_CMD,  MMIO+18
    .equ BLK_STAT, MMIO+21
    .equ SCRATCH,  6561             ; boot sector lands here (3^8, block 9)

start:
    const R1, BLK_LBA
    LDI R2, 0
    STW R1, R2                      ; LBA = 0
    const R1, BLK_BUF
    LDI R2, SCRATCH
    STW R1, R2                      ; BUF = SCRATCH
    const R1, BLK_CMD
    LDI R2, 1
    STW R1, R2                      ; CMD = read
rom_busy:
    const R1, BLK_STAT
    LDW R2, R1
    CMPI3 R5, R2, 1
    BRZ R5, rom_busy                ; still busy
    CMPI3 R5, R2, 0
    BRNZ R5, rom_err                ; STAT != 0 (error)
    const R3, SCRATCH
    JR  R3                          ; jump to the boot sector
rom_err:
    const R1, UART_TX
    LDI R2, 69                      ; 'E'
    STT R1, R2
    HALT

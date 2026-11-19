; boot.asm — boot sector program (loaded from disk block 0 to RAM 6561, then run)
;
; Loads the kernel TXE from disk blocks 1..27 into a buffer, parses the header,
; copies segments to their load addresses, jumps to the entry point (D-014).

    .include "lib/trilib.asm"

    .equ MMIO,      128608722
    .equ UART_TX,   MMIO+0
    .equ BLK_LBA,   MMIO+12
    .equ BLK_BUF,   MMIO+15
    .equ BLK_CMD,   MMIO+18
    .equ BLK_STAT,  MMIO+21

    .equ KBUF,      4763286         ; 27*729 trytes below RAM top (3^14)
    .equ NLBA,      28              ; read blocks 1..27

    .org 6561

main:
    LDI R1, 1                       ; LBA
    const R2, KBUF                  ; destination pointer
read_loop:
    CMPI3 R5, R1, NLBA
    BRZP R5, parse                  ; LBA >= 28 -> done
    const R3, BLK_LBA
    STW R3, R1
    const R3, BLK_BUF
    STW R3, R2
    const R3, BLK_CMD
    LDI R4, 1
    STW R3, R4                      ; CMD = read
busy:
    const R3, BLK_STAT
    LDW R4, R3
    CMPI3 R5, R4, 1
    BRZ R5, busy
    CMPI3 R5, R4, 0
    BRNZ R5, boot_err               ; STAT != 0 (error)
    ADDI R1, R1, 1
    LEA R2, R2, 729
    JMP read_loop

parse:
    const R3, KBUF
    const R4, magic
    LDI R1, 0
magic_loop:
    ADD R6, R3, R1
    LDT R5, R6
    ADD R7, R4, R1
    LDT R2, R7
    SUB R8, R5, R2
    BRNZ R8, boot_err
    ADDI R1, R1, 1
    CMPI3 R5, R1, 6
    BRN R5, magic_loop
    ; version tryte at KBUF+6 must be 1
    const R3, KBUF
    LEA R3, R3, 6
    LDT R2, R3
    LDI R3, 1
    SUB R5, R2, R3
    BRNZ R5, boot_err
    ; entry word at KBUF+8 — tryte offset 8 is NOT word-aligned, so assemble
    ; the word from three tryte loads (a*3^12 + b*3^6 + c)
    const R3, KBUF
    LEA R3, R3, 8
    LDT R6, R3                      ; high tryte
    const R7, 531441                ; 3^12
    MUL R6, R6, R7
    ADDI R3, R3, 1
    LDT R5, R3                      ; middle tryte
    const R7, 729                   ; 3^6
    MUL R5, R5, R7
    ADD R6, R6, R5
    ADDI R3, R3, 1
    LDT R5, R3                      ; low tryte
    ADD R6, R6, R5
    ; segment count tryte at KBUF+11
    const R3, KBUF
    LEA R3, R3, 11
    LDT R1, R3                      ; R1 = segcount
    const R2, KBUF
    LEA R2, R2, 12                  ; parse pointer
seg_loop:
    CMP3 R5, R1, R0
    BRZ R5, seg_done
    LDW R3, R2                      ; load address
    LEA R2, R2, 3
    LDW R4, R2                      ; length in trytes
    LEA R2, R2, 3                   ; -> segment data
copy_loop:
    CMPI3 R5, R4, 0
    BRNP R5, copy_done              ; done when remaining length <= 0
    LDT R5, R2
    STT R3, R5
    ADDI R4, R4, -1
    ADDI R2, R2, 1
    ADDI R3, R3, 1
    JMP copy_loop
copy_done:
    ADDI R1, R1, -1
    JMP seg_loop
seg_done:
    JR R6                           ; kernel entry
boot_err:
    const R1, UART_TX
    LDI R2, 69                      ; 'E'
    STT R1, R2
    HALT
magic:
    .tryte 83, 69, 84, 85, 78, 49   ; 'SETUN1'

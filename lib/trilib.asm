; trilib.asm — shared TriASM macros for Setun Tri OS (boot ROM, kernel, servers)
;
; const r, v — load any 18-trit constant into register r via LUI+ADDI.
;   h = v / 59049 (balanced round-nearest, assembler expression semantics),
;   remainder r = v - h*59049 is always within 10-trit range (|r| <= 29524).

.macro const r, v
    LUI  %r, %v / 59049
    ADDI %r, %r, %v - %v / 59049 * 59049
.endmacro

; ---- stack helpers ------------------------------------------------------------
.macro push r
    ADDI R8, R8, -3
    STW  R8, %r
.endmacro

.macro pop r
    LDW  %r, R8
    ADDI R8, R8, 3
.endmacro

; call label (uses R7 as link register)
.macro call lbl
    JAL  %lbl
.endmacro

; return from call
.macro ret
    JR   R7
.endmacro

# 02 ISA — TriISA v0.1 (provisional; freeze in M0 into spec/isa.yaml)

## Registers
9 GPRs, selected by 2 trits (value -4..+4 maps to R0..R8):
`R0` zero (reads 0, writes ignored) · `R1..R4` args/return/temps (caller-saved) · `R5,R6` callee-saved
· `R7` link (LR) · `R8` stack pointer (SP, grows downward, tryte-granular, word-aligned by convention).
Special: `PC`, `PSW`, and CSRs (see below). No flag register: comparisons produce a trit in a register.

## Instruction format (1 word = 18 trits)
`[ op:4 | rd:2 | rs:2 | imm:10 ]`  op = 81 opcodes (-40..+40). imm = signed 10 trits (±29524).
3-register forms put `rt` in the lowest 2 trits of imm; the remaining imm trits must be 0.
PC advances by 3 trytes per instruction.

## Instruction set (provisional numbering assigned by the executor in isa.yaml)
System: NOP, HALT, TRAP imm, RETI, WFI, CSRR rd,csr, CSRW csr,rs, FENCE
Arith:  ADD, SUB, MUL, DIV (rounds to nearest, balanced), MOD, NEG, ADDI, MULI, MULH (high word of dword result)
Trit logic (tritwise): TMIN (AND), TMAX (OR), TINV (NOT = negate each trit), TCONS (consensus: equal else 0),
        TANY (accept-anything: sum clipped), TSUM (mod-3 balanced add, no carry), TMUL (tritwise product)
Shift/rot: TSHL imm/rt, TSHR (trit shifts = multiply/divide by 3^k, truncating), TROT
Compare: CMP3 rd,rs,rt -> -1/0/+1 ; SIGN rd,rs ; CMPI3 rd,rs,imm
Memory: LDW, STW, LDT, STT (tryte), LDI rd,imm (sign-extended), LUI rd,imm (imm<<10 trits), LEA
Control: JMP off, JAL off (LR=PC+3), JR rs, BRN rs,off (branch if rs<0), BRZ, BRP, BRNZ, BRNP, BRZP
         BR3 rs, table (jump table indexed by sign: 3 entries) — the native three-way branch
Atomic: XCHG, CAS
Illegal opcodes raise ILLEGAL trap.

## CSRs
`PSW` (mode trit, irq-enable trit, 16 reserved), `PTBR` (root page table frame), `TVEC`, `EPC`, `CAUSE`,
`TVAL`, `TIMER_CMP`, `TIME`, `CYCLE`, `CAPBASE`. CSR access only in mode `+`.

## Traps (CAUSE values)
ILLEGAL, PRIVILEGE, PAGEFAULT_R/W/X, ALIGN, DIV0, SYSCALL(TRAP), TIMER, IRQ(dev), BREAKPOINT.
On trap: EPC=PC, CAUSE, TVAL set; mode -> `+`; irq disabled; PC=TVEC.

## Arithmetic semantics
Overflow wraps modulo 3^18 in balanced range [-(3^18-1)/2, +(3^18-1)/2]. ADD/SUB/MUL never trap.
DIV by zero traps. MOD returns the balanced remainder r in [-(|d|-1)/2, +(|d|-1)/2] for odd d; define the even-d rule in DECISIONS.md.

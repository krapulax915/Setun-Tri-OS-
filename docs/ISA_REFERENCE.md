# TriISA v0.1 reference (generated from spec/isa.yaml — do not edit by hand)

| op | mnemonic | format | semantics |
|---:|---|---|---|
| -8 | `CAS` | RRR | old=[rs]; if old==rd: [rs]=rt; rd=old (atomic) |
| -7 | `XCHG` | RS | atomically swap rd <-> word at [rs] (word-aligned) |
| -6 | `FENCE` | SYS | flush TLB; order memory ops |
| -5 | `CSRW` | CSR_W | CSR[csr] = rs; mode + only |
| -4 | `CSRR` | CSR_R | rd = CSR[csr]; mode + only |
| -3 | `WFI` | SYS | wait for interrupt; idle thread sleeps here |
| -2 | `RETI` | SYS | PC = EPC; mode/irq reloaded from PSW (kernel-owned) |
| -1 | `TRAP` | TRAPF | CAUSE=SYSCALL(0), TVAL=imm; kernel reads R1..R5 |
| 0 | `NOP` | SYS |  |
| 1 | `ADD` | RRR | rd = rs + rt (wrap mod 3^18) |
| 2 | `SUB` | RRR | rd = rs - rt (wrap) |
| 3 | `MUL` | RRR | rd = rs * rt (wrap) |
| 4 | `DIV` | RRR | rd = rs / rt round-nearest, ties toward zero; rt=0 traps DIV0 |
| 5 | `MOD` | RRR | rd = balanced remainder; rt=0 traps DIV0 |
| 6 | `NEG` | RS | rd = -rs (trit flip) |
| 7 | `ADDI` | RRI | rd = rs + imm (wrap) |
| 8 | `MULI` | RRI | rd = rs * imm (wrap) |
| 9 | `MULH` | RRR | rd = high word of dword(18-trit) product rs*rt |
| 10 | `TMIN` | RRR | tritwise min (ternary AND) |
| 11 | `TMAX` | RRR | tritwise max (ternary OR) |
| 12 | `TINV` | RS | tritwise negate each trit of rs into rd |
| 13 | `TCONS` | RRR | tritwise consensus: a if a==b else 0 |
| 14 | `TANY` | RRR | tritwise clip(a+b, -1, +1) |
| 15 | `TSUM` | RRR | tritwise balanced mod-3 add, no carry |
| 16 | `TMUL` | RRR | tritwise product |
| 17 | `TSHL` | RS | rd = rs << k trits (k = imm or rt reg-form), zeros fill LSB, wrap |
| 18 | `TSHR` | RS | rd = rs >> k trits: drop k lowest trits (= round-to-nearest /3^k), wrap |
| 19 | `TROT` | RS | rd = rotate rs trits toward MSB by k mod 18 (reg form: k in rt) |
| 20 | `CMP3` | RRR | rd = sign(rs - rt) in {-1,0,+1} |
| 21 | `SIGN` | RS | rd = sign(rs) |
| 22 | `CMPI3` | RRI | rd = sign(rs - imm) |
| 23 | `LDW` | RS | rd = word at [rs], word-aligned else ALIGN |
| 24 | `STW` | RS | [rd] = rs (rd is the address), word-aligned else ALIGN |
| 25 | `LDT` | RS | rd = tryte at [rs] (any address) |
| 26 | `STT` | RS | [rd] = tryte rs (any address) |
| 27 | `LDI` | RI | rd = imm (sign-extended 10-trit) |
| 28 | `LUI` | RI | rd = imm << 10 trits |
| 29 | `LEA` | RRI | rd = rs + imm (address arithmetic, no memory access) |
| 30 | `JMP` | OFF | PC = PC_next + off |
| 31 | `JAL` | OFF | R7 = PC_next; PC = PC_next + off |
| 32 | `JR` | R | PC = rs (word-aligned recommended; unaligned = ALIGN) |
| 33 | `BRN` | RS_OFF | if rs < 0: PC = PC_next + off |
| 34 | `BRZ` | RS_OFF | if rs == 0: PC = PC_next + off |
| 35 | `BRP` | RS_OFF | if rs > 0: PC = PC_next + off |
| 36 | `BRNZ` | RS_OFF | if rs != 0: branch |
| 37 | `BRNP` | RS_OFF | if rs <= 0: branch |
| 38 | `BRZP` | RS_OFF | if rs >= 0: branch |
| 39 | `BR3` | RS_OFF | 3-way: PC = word at [PC_next + off + 3*sign(rs)]; table word-aligned |
| 40 | `HALT` | SYS | halt the machine (host: clean stop) |

## CSRs

- `PSW` = 0
- `PTBR` = 1
- `TVEC` = 2
- `EPC` = 3
- `CAUSE` = 4
- `TVAL` = 5
- `TIMER_CMP` = 6
- `TIME` = 7
- `CYCLE` = 8
- `CAPBASE` = 9

## Trap causes

- `SYSCALL` = 0
- `ILLEGAL` = -1
- `PRIVILEGE` = -2
- `PAGEFAULT_R` = -3
- `PAGEFAULT_W` = -4
- `PAGEFAULT_X` = -5
- `ALIGN` = -6
- `DIV0` = -7
- `BREAKPOINT` = -8
- `TIMER` = 1
- `IRQ_BASE` = 10

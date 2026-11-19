# 01 Architecture

## Layers
```
user programs (shell, coreutils)
user-space servers: init, console, fs(TriFS), mem(pager), timer, compress
-------------------------------------------------------------- syscall boundary (TRAP)
Setun Tri OS microkernel: address spaces, threads, scheduler, IPC, capabilities, IRQ->IPC
-------------------------------------------------------------- 
HAL: trap vector, CSRs, MMIO devices
TVM (emulator)  ==later==>  real ternary CPU
```

## Number system and types
- trit: -1,0,+1 written `-`,`0`,`+` (N,Z,P).  tryte = 6 trits (-364..+364).  word = 3 trytes = 18 trits.
  dword = 36 trits. Memory is tryte-addressed. Address = 18 trits (signed; kernel half = negative).
- Balanced ternary gives free negation (flip trits), free sign, and rounding = truncation.
- Text: TriText, 1 tryte per character via a 729-entry code page (ASCII + Hungarian áéíóöőúüűÁÉÍÓÖŐÚÜŰ
  + common Western Europe). Escape tryte (+364) starts a multi-tryte code point (UTF-like, define in M0).

## Privilege modes (3 rings, trit-valued)
`-` user, `0` service (trusted servers, may use MMIO caps), `+` kernel.

## Design goals
1. Make ternary advantages visible: 3-way compare/branch, tri-state permissions, tri-state thread
   state, signed priority classes, native balanced arithmetic.
2. Portable to real hardware: HAL isolates everything that depends on the TVM.
3. Observable: built-in profiler for memory locality and trit activity (feeds chip design).

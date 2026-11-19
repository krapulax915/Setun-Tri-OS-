# 03 Memory management

- Page = 729 trytes (3^6). Virtual address = 18 trits = `[L1:4][L2:4][L3:4][offset:6]`. Each table has 81 entries x 1 word
  = 243 trytes (allocated from a slab). Alternative splits may be chosen in M0 and must be logged in DECISIONS.md.
- Physical address 18 trits; frame number 12 trits.
- PTE (1 word, 18 trits): `[frame:12][R/W:1][X:1][owner-mode:1][accessed:1][dirty:1][present:1]`
  - R/W trit: `-` no access, `0` read-only, `+` read/write.
  - X trit: `-` no exec, `0` exec in same mode only, `+` exec any mode (kernel decides).
  - owner-mode: lowest mode allowed to touch the page.
- Kernel lives in the negative half of the address space (identity-mapped window to physical memory in M3).
- Physical allocator: ternary buddy allocator (blocks of 3^k pages) — splits into 3 children. Pager server handles
  demand paging and copy-on-write for fork-less `spawn`.
- TLB: 27-entry fully associative in the TVM, `FENCE` flushes. Expose hit/miss counters to the profiler.

## Boot
Firmware stub in TVM (ROM at fixed address) loads the boot sector (block 0 of the disk) -> `boot.tri` -> kernel image
in TXE format (header: magic trytes, entry, segment table, checksum). Kernel sets up TVEC, page tables, console, then starts `init`.

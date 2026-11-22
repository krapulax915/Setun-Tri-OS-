# DECISIONS — Setun Tri OS v0.1

Format per GLM_MASTER_PROMPT rule 1: date, question, choice, reason.
(Executor worked through these while implementing M0..; docs are the spec.)

## D-001 — 2026-11-19 — Opcode numbering for TriISA v0.1
**Question:** docs/02 leaves opcode numbering to the executor. How do 49 mnemonics map to the
4-trit op field (81 values, -40..+40)?
**Choice:** see `spec/isa.yaml`. NOP=0; arithmetic 1..9; trit-logic 10..16; shifts 17..19;
compare 20..22; memory 23..29; control 30..39; HALT=40; system traps/CSRs 21..28 negative:
TRAP=-1, RETI=-2, WFI=-3, CSRR=-4, CSRW=-5, FENCE=-6, XCHG=-7, CAS=-8.
**Reason:** hot arithmetic/logic/control groups get short non-negative encodings; privileged
system ops live in the negative range, giving a trit-level quick check (op<0 ⇒ privileged).
All other 32 values are ILLEGAL.

## D-002 — 2026-11-19 — Field packing inside the 18-trit word
**Question:** `[ op:4 | rd:2 | rs:2 | imm:10 ]` — how are fields laid out in the trit string?
**Choice:** most-significant-first concatenation: trits[0..3]=op, trits[4..5]=rd, trits[6..7]=rs,
trits[8..17]=imm. Each field is a balanced-ternary number whose most significant trit comes first.
**Reason:** matches the written notation; decoding is a simple slice.

## D-003 — 2026-11-19 — Register selector encoding
**Question:** "2 trits, value -4..+4 maps to R0..R8" — exact mapping?
**Choice:** selector s in -4..+4 selects R(s+4): -4→R0 … 0→R4 … +4→R8.
**Reason:** the literal reading of docs/02.

## D-004 — 2026-11-19 — CSR numbering
**Choice:** PSW=0, PTBR=1, TVEC=2, EPC=3, CAUSE=4, TVAL=5, TIMER_CMP=6, TIME=7, CYCLE=8, CAPBASE=9.
The CSR number is carried in the imm field of CSRR/CSRW.
**Reason:** small stable ints; CAPBASE marks the base of the kernel capability table
(used from M5; value fixed now to keep isa.yaml frozen).

## D-005 — 2026-11-19 — MOD for even divisors / DIV tie rule
**Question:** docs/02 defines MOD's range only for odd d.
**Choice:** DIV: q = integer nearest a/d; exact ties (possible only for even d) round toward zero.
MOD: r = a − q·d, so |r| ≤ |d|/2, equality only when |d| is even (then sign(r) = sign(a), r ≠ 0 case).
For odd d this matches docs/02 exactly. DIV0 traps; DIV0 does NOT trap for MOD (r = a for |d|>0 is wrong —
instead MOD with d=0 also traps, keeping one rule: division family needs d ≠ 0).
**Reason:** round-half-toward-zero keeps |r| minimal and is sign-symmetric; q = trunc(a/d)
satisfies it except at |a| = q·d + |d|/2 boundaries, which the tie rule settles.

## D-006 — 2026-11-19 — Branch/jump offset units and base
**Choice:** JMP/JAL/BR* offsets are signed **tryte offsets** relative to PC_next
(PC after the instruction advances by 3). BR3's `table` operand is likewise a PC-relative
tryte offset to the table; the three table entries are words holding **absolute** tryte
addresses of the targets (entry 0 = negative case, 1 = zero case, 2 = positive case).
Table must be word-aligned (3-tryte aligned) else ALIGN trap at execution.
**Reason:** one unit everywhere avoids confusion; absolute table entries are fine because
v0.1 images are statically linked (see D-014).

## D-007 — 2026-11-19 — Word alignment
**Choice:** LDW/STW/BR3-tables/JAL targets require addr % 3 == 0 (word-aligned); violation
raises ALIGN. LDT/STT are byte(=tryte)-granular, no alignment rule. Stack is word-aligned by
convention (docs/02), enforced only by convention, not by hardware.
**Reason:** ALIGN trap exists in docs/02; this gives it a precise trigger.

## D-008 — 2026-11-19 — Ternary shifts and rotate
**Choice:** TSHL k: trit string moves toward MSB, zeros fill the LSB end, trits shifted out of
the 18-trit word are lost (wrap semantics equal to multiply-by-3^k modulo 3^18).
TSHR k: trit string moves toward LSB, MSB side sign-fills? **No** — dropping low trits in balanced
ternary IS round-to-nearest division (error < 1/2), so TSHR drops the k lowest trits (this is
"truncating" in the digit-string sense used by docs/01: "rounding = truncation").
TROT k: circular rotation of the 18 trits toward MSB by k mod 18 (k may be negative → rotate the
other way). All take k from imm or from rt (register form, low 2 trits of imm per D-002 format).
**Reason:** balanced representation makes arithmetic shift == round-to-nearest; a sign-fill
shift would be plain floor division, which is less "ternary-native". Rotation is defined on the
digit string, value semantics follow from the representation.

## D-009 — 2026-11-19 — Tritwise op semantics
**Choice (per trit pair a,b):**
- TMIN = min(a,b) (ternary AND), TMAX = max(a,b) (ternary OR), TINV = −a.
- TCONS = a if a==b else 0 (consensus).
- TANY = clip(a+b, −1, +1) (accept-anything).
- TSUM = balanced mod-3 addition: s=(a+b) mod 3 mapped {2→−1, −2→+1}, no carry.
- TMUL = a·b.
**Reason:** literal reading of docs/02; TANY's "sum clipped" made concrete.

## D-010 — 2026-11-19 — Memory & address-space geometry
**Question:** docs/03 fixes page=3^6 trytes, 3-level tables of 81 entries, 18-trit VA/PA,
12-trit frame numbers. How does the TVM place RAM and MMIO inside the 18-trit *physical* space,
and how does the kernel reach physical memory (docs/03: "identity-mapped window")?
**Choice:**
- Usable physical memory occupies **non-negative** physical addresses [0, RAM_SIZE), RAM_SIZE
  configurable, default 3^14 = 4,782,969 trytes (~4.6 MB). Negative physical addresses are
  simply faulted (bus error) in v0.1.
- MMIO window: [MMIO_BASE, 3^17) with MMIO_BASE = 3^17 − 3^12 = 128,608,722 (a 531,441-tryte
  region above any allowed RAM). Device registers are word-aligned words inside it (see D-011).
- Kernel direct window: while PTBR == 0 (see D-012), virtual **v < 0** in mode `+` maps to
  physical p = v + 3^17 — a fixed-offset linear window covering [0, 3^17) i.e. all RAM and MMIO.
  Virtual v ≥ 0 with PTBR==0 faults. This is the M3 "identity-mapped window" (linear, not
  literally identity, chosen so the window covers the whole physical space with one rule).
- Kernel threads run with PTBR==0 (no TLB involvement); user/service spaces always have PTBR≠0
  and may only use v ≥ 0 (a negative VA in mode −/0 faults PAGEFAULT, kernel half is reserved).
- TLB: 27-entry fully associative, caches v≥0 translations of the current space; FENCE flushes.
**Reason:** one arithmetic rule for the kernel window, devices stay outside RAM, and user/kernel
split equals the VA sign — exactly the ternary-flavoured split docs/01 asks for.

## D-011 — 2026-11-19 — MMIO map (TVM devices)
**Choice:** offsets (in trytes) from MMIO_BASE, all word-aligned (multiple of 3):
```
UART:   +0   TXDATA (write: push byte/trit-char; write of tryte 0..364 emits TriText char)
        +3   RXDATA (read: pop input tryte or 0; +3 read side also clears)
        +6   STAT   (bit0-lsb-trit: rx ready, bit1: tx busy)
TIMER:  +9   TIME_LO ... (TIME/TIMER_CMP/ CYCLE are CSRs; device side only raises IRQ)
BLK:    +12  BLK_LBA (block number, word)
        +15  BLK_BUF (buffer physical address, word, must be RAM)
        +18  BLK_CMD (write 1=read, 2=write; self-clearing; IRQ on completion)
        +21  BLK_STAT (0 idle, 1 busy, -1 error)
RNG:    +24  RNG_VAL (read: next value; write: reseed)
POWER:  +27  POWER (write 1=shutdown cleanly, -1=reset machine)
PROF:   +30  PROF_CTRL (write: 1=start, 0=stop, 2=snapshot), +33 PROF_ACK
IRQ lines: TIMER=cause +1, UART rx=+11 (dev 1), BLK done=+12 (dev 2), RNG=+13 (dev 3),
PROF=+14 (dev 4). IRQ(device) cause = 10 + device_id (D-017).
```
**Reason:** minimal fixed map, easy to port to a real chip; documented in one place.

## D-012 — 2026-11-19 — PSW layout and MMU enable
**Choice:** PSW (18 trits): trit0 = mode (−/0/+), trit1 = irq-enable, trits2..17 reserved
(read as 0, writes ignored). No MMU-enable bit: **PTBR == 0 means MMU off (kernel direct
window active); PTBR ≠ 0 means MMU on** with PTBR = physical frame number of the root L1 table
(must be word-aligned frame, positive).
**Reason:** docs/01's "16 reserved" gives room; a sentinel in PTBR is simpler than a PSW field
and keeps mode/irq as the only PSW trits.

## D-013 — 2026-11-19 — Trap cause numbering
**Choice:** CAUSE is sign-classified: **0 = SYSCALL**, negative = exceptions, positive = interrupts.
ILLEGAL=−1, PRIVILEGE=−2, PAGEFAULT_R=−3, PAGEFAULT_W=−4, PAGEFAULT_X=−5, ALIGN=−6, DIV0=−7,
BREAKPOINT=−8; TIMER=+1; IRQ(device_id d)=10+d (UART d=1 → +11, BLK d=2 → +12, RNG d=3 → +13,
PROF d=4 → +14). TVAL: for page faults the faulting virtual address; for ILLEGAL the bad opcode
value; for PRIVILEGE the attempted op; for ALIGN the bad address; for SYSCALL the trap imm; else 0.
**Reason:** the sign trit classifies cause family for free — a ternary-native touch.

## D-014 — 2026-11-19 — TXE executable format
**Choice:** host-side file, packed 5 trits/byte (same codec as disk images, D-015).
Trit stream: magic trytes `S E T U N 1` (TriText/ASCII values 83,69,84,85,78,49), version tryte = 1,
flags tryte = 0, entry point word, segment count tryte (1..36; 0 = illegal), then per segment:
load address word, length-in-trytes word, then length trytes of data. After the last segment:
2 checksum trytes = position-weighted balanced mod-3^6 tryte sum over all preceding trits-pairs
(defined in tools/pack.py: `chk = Σ (tryte_i · ((i mod 3^6) + 1)) mod 3^6, signed to balanced`),
computed over the trytes from magic through last segment data.
Loader checks magic, version, checksum; segments are loaded contiguously at their load addresses
(word-aligned required); entry must be word-aligned.
**Reason:** self-describing, tiny, checksummed; reuses the one packing codec.

## D-015 — 2026-11-19 — 5-trits-per-byte packing codec
**Choice:** trits are normalized to digits {0,1,2} (−→0, 0→1, +→2) and packed little-endian
5 digits per host byte: byte = Σ digit_i · 3^i, i = 0..4 (values 0..242 < 256 ✓).
Final partial group pads with digit 1 (= trit 0). Codec is symmetric and total
(any trit stream round-trips; byte stream validity is checked by range 0..242 on unpack).
**Reason:** docs/05 "5 trits per byte (243 < 256)"; little-endian keeps the first trit in bit0.

## D-016 — 2026-11-19 — TriText code page v0.1
**Choice:** one tryte per character. Tryte value t in [0, 364] = code point index:
t in [0,127] = ASCII (C0 controls included; NUL = 0), t in [128,364] = assigned page
(see `tools/trit.py: TRITEXT_PAGE`): 128..145 Hungarian á é í ó ö ő ú ü ű Á É Í Ó Ö Ő Ú Ü Ű,
146..191 common Western European (à â ä ç è ê ë ì î ï ñ ò ô ù û ÿ £ € ° ± × ÷ « » etc.),
192..364 unassigned (decode → U+FFFD). **Escape:** tryte +364 followed by **three** trytes
encoding an 18-trit balanced value = a full Unicode code point (0..0x10FFFF; negative → U+FFFD).
Negative tryte values (−364..−1) never encode; decoder maps them to U+FFFD (lenient decode,
strict encoder rejects). Round-trip guarantee holds for strings whose chars are in the page or
emitted via escape.
**Reason:** docs/01 requires Hungarian + Western Europe in 729 slots with a UTF-like escape;
3-tryte escape covers all of Unicode, 2-tryte escape rejected to keep one unambiguous form.

## D-017 — 2026-11-19 — Trap entry semantics (TVM)
**Choice:** on any trap: EPC = PC (address of the trapping instruction; for SYSCALL the TRAP
instruction itself, so RETI-style resume re-executes? No — SYSCALL advance: EPC = PC+3 for
SYSCALL, EPC = PC for faults), CAUSE, TVAL set; mode → `+`; irq-enable → −; PC = TVEC.
RETI restores mode/irq from PSW-save-slot? **Concrete:** the kernel saves EPC/CAUSE/PSW itself;
RETI sets PC = EPC and reloads mode/irq-enable from the low 2 trits of the value the kernel
wrote into PSW before RETI (kernel-owned PSW convention; TVM just follows PSW + EPC).
**Reason:** microkernel saves context anyway; TVM stays minimal and matches real-HW design
notes to be written in docs/HW_PORT.md (M10).

## D-018 — 2026-11-19 — PTE and page-table walk details
**Choice:** PTE word (18 trits) packed MSB-first: [frame:12 | R/W:1 | X:1 | owner-mode:1 |
accessed:1 | dirty:1 | present:1] (frame is the most significant 12 trits, present the LSB).
present trit: −/0 = not present, + = present. R/W: − no access, 0 read-only, + read-write.
X: − no exec, 0 exec same-mode-only (kernel decides at load), + exec any mode.
owner-mode: lowest mode allowed (− user, 0 service, + kernel-only).
Walk (MMU on): L1 idx = VA trits [0..3], L2 = [4..7], L3 = [8..11], offset = [12..17] (D-010 split
for positive VAs); tables are 81 words = 243 trytes, word-aligned frames; a missing/unpresent
entry faults; accessed/dirty bits set by hardware on use (cleaned by kernel).
**Reason:** literal docs/03 PTE; the "alternative splits" option was not needed.

## D-019 — 2026-11-19 — Buddy allocator arithmetic
**Choice:** physical allocator manages frames (729 trytes). Block orders k = 0..MAX_ORDER
(3^k frames per block), MAX_ORDER chosen so 3^MAX_ORDER covers RAM frames rounded up to a
power-of-3 count. Free lists per order; allocation splits a higher-order block into 3 children
(buddy index = floor(idx / 3^k)·3^k), free merges 3 siblings into the parent when all 3 free.
Block metadata lives in kernel memory (not in the frames), so frames are never "touched" by
the allocator itself.
**Reason:** "ternary buddy" per docs/03; 3-way split/merge is the ternary analogue of 2-way.

## D-020 — 2026-11-19 — Capability & syscall numbering
**Choice:** syscall numbers in R1: YIELD=1, EXIT=2, THREAD_CREATE=3, THREAD_CONTROL=4, SEND=5,
RECV=6, CALL=7, REPLY=8, NBSEND=9, CAP_COPY=10, CAP_DERIVE=11, CAP_REVOKE=12, CAP_DELETE=13,
ASPACE_CREATE=14, MAP=15, UNMAP=16, FRAME_ALLOC=17, IRQ_BIND=18, TIME=19, DEBUG_PUTC=20.
Right vector: 9 rights (READ WRITE EXEC GRANT MAP SEND RECV CALL CONTROL) each a trit
(− deny sticky / 0 absent / + held). Derivation: child = min(parent, requested) with − < 0 < +
(− is sticky). Revoke removes the derivation subtree. Cap slots are generation-counted
(docs/04 invariant 3).
**Reason:** stable ABI; matches docs/04 exactly.

## D-021 — 2026-11-19 — IPC message layout
**Choice:** message payload = R1..R4 (4 words) + msg-tag word in R0-slot? R0 is hardwired zero —
payload = R2..R4? docs/04 says "up to 6 trytes in registers R1..R4" — that is 4 words = 12 trytes;
the doc's "6 trytes" reads as a lower bound phrasing ("up to" = registers, extend later).
Concrete: SEND carries words in R1..R4 (R1 = tag), plus one optional capability handle in R5
transferred on matching RECV. CALL = SEND+RECV atomically; REPLY sends R1..R4 back to the
caller's thread and unblocks it. Notifications: 18-trit word delivered to a bound endpoint.
**Reason:** registers are the only zero-copy channel in v0.1; cap transfer via R5 keeps the
fast path register-only.

## D-022 — 2026-11-19 — TriFS on-disk layout v0.1
**Choice:** block = 729 trytes. Image = superblock (block 0) | free-space map (2 trits per block:
0=free,1=used,2=reserved) | inode area | data blocks. Superblock: magic `TRIFS01`, block size,
total blocks, inode area start/size, root inode number, checksum.
Inode (1 block-resident struct, fixed 54-tryte name fields not here): type (file/dir/snapshot-root),
size, mtime-cycle, direct extent list (up to 27 extents: (start_block, count) words) + overflow
extent block link; directories are COW B-trees of (name ≤ 54 trytes, inode word) entries whose
root block id is stored in the directory inode; file data = extents, per-extent optional
compression algorithm id. Snapshot = new COW root referencing old tree (no journal — COW).
Per-block checksum: position-weighted balanced mod-3^6 tryte sum (same function as D-014).
Permissions: per-entry trits deny/inherit/allow (docs/05) — v0.1 stores them, enforces R/W only.
**Reason:** fits docs/05; COW B-tree keeps power-cut consistency without a journal.

## D-023 — 2026-11-19 — Kernel implementation language for v0.1
**Question:** docs/06 lists `kernel/` (TriASM/Tern). Writing the whole microkernel in raw TriASM
is slow to iterate on; M10's Tern is optional.
**Choice:** kernel is written in **TriASM with a strong macro layer** (assembler macros provide
prologue/epilogue, call/ret, structured branches, syscall tables). No Tern in v0.1 unless time
permits M10. Target < 6000 lines kept.
**Reason:** keeps "guest code sees trits only" honest, exercises the assembler (dogfooding),
and macros keep the assembly maintainable.

## D-024 — 2026-11-19 — Profiler output & workload set for `make profile`
**Choice:** host-side profiler in the TVM emits `profile/<workload>.csv` (per-interval samples)
+ `profile/<workload>.txt` summary: trit-activity per instruction class, memory access distance
histogram (tryte deltas bucketed by powers of 3; lattice-hop mapping configurable, default off),
read/write ratio, working-set size per 1M cycles. Workloads: `w_compile` (expression parser/
evaluator loop standing in for "compile"), `w_fs` (TriFS churn), `w_ipc` (ping-pong storm),
`w_matmul` (ternary matrix multiply), `w_text` (TriText processing).
**Reason:** docs/06 lists workloads; "compile" is interpreted per D-024 as a parse/eval kernel
until a real in-TVM compiler exists.

## D-025 — 2026-11-19 — Build driver on Windows (no make)
**Choice:** `Makefile` delegates every target to `python tools/mk.py <target>`; the canonical
invocation used in CI/tests is `python tools/mk.py test|run|profile WORKLOAD=...`.
**Reason:** host box (Windows/Git Bash) has no make; docs demand `make test` ergonomics.

## D-026 — 2026-11-19 — Shift amount encoding disambiguation (M1)
**Question:** docs/02 says shifts take "imm/rt", but the documented encoding (rt in the low 2
imm trits, rest 0) collides with immediate k in [-4,+4].
**Choice:** k is decoded as a register (R[k+4]) when the imm field value is in [-4,+4]; otherwise
it is an immediate. The assembler therefore REJECTS immediate shifts with |k| <= 4 (use a register,
or LDI+shift). Syntax: `TSHL rd, rs, rt` (full), `TSHL rd, k|rt` (in-place, source = rd).
**Reason:** keeps one unambiguous encoding per word; |k|<=4 shifts cost one extra LDI — acceptable.

## D-027 — 2026-11-19 — Privileged op set and WFI wake semantics (M1)
**Choice:** privileged (mode `+` only, else PRIVILEGE trap): CSRR, CSRW, RETI, WFI, FENCE, HALT.
XCHG/CAS are user-legal. WFI wakes on any pending IRQ even when irq-enable is `-` (masked):
if enabled, the IRQ is delivered through the trap path; if masked, execution resumes at PC.
**Reason:** matches common WFI hardware behaviour and gives M4's scheduler its sleep primitive;
HALT is privileged so user code cannot power off the machine.

## D-028 — 2026-11-19 — MMU off mode = direct physical (M3)
**Question:** docs/03's "identity-mapped window" — what exactly do addresses mean while
PTBR == 0 (kernel threads, boot, M3)?
**Choice:** PTBR == 0: every address is used as a physical address directly (boot and kernel
live at positive physical addresses in the TVM). The kernel direct window (v < 0 → p = v + 3^17)
is active only in mode `+` and exists for the MMU-on case, where the kernel reaches its own
structures while servicing a process whose positive VAs go through the page tables.
Negative VAs in mode −/0 always fault (kernel half is reserved).
**Reason:** keeps boot/M3 simple and physical; the negative-half kernel split (docs/01) becomes
meaningful with per-process spaces from M5 on.

## D-029 — 2026-11-19 — Page table entry addressing (M3)
**Choice:** a page table occupies one 729-tryte frame (81 words); the entry for balanced
index i (−40..+40) sits at word offset (i + 40) inside the frame. Walk: L1 idx = VA trits
[0..3], L2 [4..7], L3 [8..11], page offset [12..17]; tables are read through physical memory
(so Accessed/Dirty updates never recurse).
**Reason:** balanced indices map linearly onto array slots; hardware port keeps the same rule.

## D-030 — 2026-11-19 — Ternary buddy allocator representation (M3)
**Choice:** full binary tree of nodes re-expressed as a 3-way tree in BFS numbering: node 1 is
the root, children of n are 3n−1, 3n, 3n+1; parent of n is (n+1−i)/3 with i = (n+1 mod 3,
made non-negative). Depth d nodes are BFS ids [3^d, 2·3^d); node (d, j) covers frames
[j·3^(MAX−d), (j+1)·3^(MAX−d)). State per node in a kernel tryte array: 0 free, 1 used,
2 split. Free lists are singly linked through a kernel-side FREE_NEXT array (never through
frame contents, per D-019). alloc finds the shallowest depth ≥ order with a free node and
splits downward (pushing the two spare children to the deeper list); free merges when all
three siblings are free, removing them from their list by scan.
**Reason:** O(1) sibling checks, metadata entirely in kernel memory, and the 3-way split/merge
is the ternary analogue of the binary buddy.

## D-031 — 2026-11-19 — M3 trap resume semantics
**Choice:** exceptions (negative CAUSE) resume at EPC+3 (faulting instruction skipped) in the
M3 handler; SYSCALL (0) already stores EPC = pc+3 and resumes at EPC. The handler prints
cause/tval diagnostics, saves/restores R1..R8 from a kernel frame, and never dies on
ILLEGAL/DIV0/ALIGN/PAGEFAULT (M3 acceptance).
**Reason:** minimal observable recovery for M3; real per-task semantics arrive with threads (M4).

## D-030b — 2026-11-19 — Buddy depth↔order mapping (M3)
**Choice:** an order-k block (3^k frames) lives at tree depth d = MAX_ORDER − k: order 0
(1 frame) = depth-8 leaf, order 8 (whole tree) = root. buddy_alloc(order) computes
target depth 8−order and scans free lists from that depth DOWNWARD (smallest adequate block
first), splitting downward (depth increases toward leaves) until the target depth.
buddy_free takes the node's depth explicitly.
**Reason:** the first implementation scanned upward and split past the leaves (children ids
out of range); depth grows toward smaller blocks, so splitting always increases depth.

## D-030c — 2026-11-19 — Doubly-linked buddy free lists (M3)
**Choice:** free lists are doubly linked (FREE_NEXT + FREE_PREV arrays in kernel memory).
push_free sets prev[node] = −1 and prev[old-head] = node; pop_free unlinks the head in O(1);
merging unlinks the three children O(1) via list_unlink (never a scan), marks them state 2
and pushes the parent. Splitting re-marks the two spare children state 0 after pushing.
**Reason:** scan-based removal made freeing O(n) each (O(n²) total); a lazy-tombstone variant
created free-list cycles when a node was pushed twice while still linked. Doubly-linked lists
give O(1) push/pop/unlink with no stale entries, at the cost of one extra kernel array.
(Superseded by D-030d: the list bookkeeping was a persistent bug surface in TriASM.)

## D-030d — 2026-11-20 — Hint-based scan allocator (supersedes D-030c)
**Choice:** the shipped M3 allocator drops free lists entirely. State array only (0 free /
1 used / 2 split, D-030) plus one word HINT[0..8]. buddy_alloc(order): target depth
t = 8−order (D-030b), scan nodes of depth t ascending from HINT[t]; the first state-0 node
that passes the D-030e ancestor check is taken: state[n] = 1, every ancestor set to 2,
HINT[t] = j+1. buddy_free(depth, n): state[n] = 0, lower HINT[depth] to j when the freed
block sits below the hint, then recompute ancestors bottom-up (parent = 0 iff all three
children are 0, else 2) until the root.
**Reason:** the free-list variant needed push/pop/unlink plus split logic across four more
kernel arrays, and every piece was another TriASM register/stack bug surface (stale R2, LR
clobbers, list cycles). The hint scan has no linked structure to corrupt, is ~120
instructions total, and is validated exactly against an independently written Python model
(tests/golden_buddy.py, 600-step random workload diff) plus a 240-iteration boot self-test.
Scan cost stays small: hints advance monotonically per depth and are lowered only by frees.

## D-030e — 2026-11-20 — Ancestor-allocated check in buddy_alloc
**Choice:** a state-0 node is allocatable only if no ancestor has state 1. The allocator
walks up from each candidate (walker kept in a machine-stack slot; parent of n is
(n+1−i)/3 with i = non-negative (n+1) mod 3) and, on hitting a state-1 ancestor, advances
HINT[t] past the candidate and rescans.
**Reason:** direct allocation of larger blocks (no split path, D-030d) leaves the leaves
BELOW an allocated block at state 0 — first-fit would hand out memory inside a live
allocation. The walk-up is at most 8 bstate_get calls and makes the scan exactly equivalent
to the golden model.

## D-032 — 2026-11-20 — BSS is not stored in the TXE
**Choice:** kernel data regions (KDATA: buddy state, HINT, ksave, pnumbuf, nodes array) are
never emitted into the TXE — the .org gap between segments is simply absent, and the loader
does a sparse segment copy with no zero-fill. Every KDATA byte is initialised before first
read: buddy_init writes all states and hints, the self-test writes nodes[] before reading,
putnum writes pnumbuf before reading.
**Reason:** keeps the kernel image small (no 1M-tryte hole in the TXE), matches the M2
loader semantics, and the "written before read" invariant is policed by the boot self-test
itself — any uninitialised read shows up as a wrong alloc/free against the golden model.

## D-033 — 2026-11-21 — PSW shadow + M4 scheduling model
**Choice:** trap entry snapshots the current PSW (mode + 3·irq) into a shadow register and
then forces mode +, irq −; RETI restores PC = EPC and mode/irq from the shadow; CSRW PSW
also updates the shadow. This makes the handler→RETI path zero-window (no nested trap can
clobber EPC or leak an irq-enable), so a preempted thread comes back with its interrupts
on without any handler-side PSW write. Scheduling: three priority classes (realtime +,
normal 0, background −), one FIFO ready queue per class, scan order +/0/−, time slice via
the level timer re-armed to TIME+QUANTUM on every tick; the idle thread parks in WFI.
The spec's 9 levels per class are recorded in the TCB concept but only arrive with M5
priority inheritance.
**Reason:** with a single EPC CSR, any irq-enable before RETI let a nested trap overwrite
the outer EPC and turned the resume into an infinite RETI loop — observed live. The
shadow (hardware-equivalent: a real chip saves PSW on trap entry) removes the window
entirely; isa.yaml's "mode/irq reloaded from PSW (kernel-owned)" stays true.

## D-034 — 2026-11-21 — Context switch: trap frame + TCB, save-early/restore-only
**Choice:** every trap builds a frame on the interrupted thread's kernel stack
(R1..R7 + saved SP slot) and immediately stores T_SP (= frame top), T_EPC and the state
into the thread's TCB (9 words: next/sp/epc/state/class/pending/stk/flags/reserved).
schedule_switch then only picks the best ready thread (zombie-guarded: freed slots are
skipped), reloads EPC from the target TCB and RETIs. New threads get a synthetic frame
(sp = stack top, R1 = create arg, R2..R7 = 0). Threads run mode +, IRQs on; handlers run
with IRQs off by trap entry.
**Reason:** saving before dispatch makes every switch path (timer, YIELD, EXIT, BLOCK)
uniform; loading EPC from the TCB just before RETI keeps a stale CSR from ever mattering.
The zombie guard converts a stale queue link (found live: a wake-enqueued freed tid) from
a context-corrupting crash into a skipped entry.

## D-035 — 2026-11-21 — M4 syscall set and frame-based argument passing
**Choice:** TRAP 0 with the number in R1: 1 YIELD, 2 EXIT, 3 THREAD_CREATE(fn,class,arg),
4 THREAD_CONTROL(tid,op,arg) with op 0 block / 1 wake / 2 set-class(self only),
5 TIME, 6 DEBUG_PUTC, 7 GETTID; result in R1, error in R2 (0 = ok). Wrappers reload all
arguments from the trap frame (+21/+18/+15/+12 = interrupted R1/R2/R3/R4) and write
results back into the frame, because the handler's save step uses R2/R3 as scratch and
clobbers the live registers. THREAD_CREATE allocates the TCB and a buddy order-0 stack
page, builds the synthetic frame by direct STWs (never by switching R8), and enqueues.
**Reason:** frame-based args survive any handler scratch use; the no-R8-switch frame
build keeps the body preemptible at every instruction (a mid-body timer hit used to
misalign the epilogue pops and return into the wrong stack).

## D-036 — 2026-11-21 — Pending-wake flag (no lost wakeups)
**Choice:** WAKE on a runnable thread (ready or running) sets the TCB pending flag instead
of touching the queues; BLOCK on a thread with the flag set consumes it and keeps running.
WAKE on a blocked thread enqueues it normally; WAKE on a freed slot is an error and never
enqueues.
**Reason:** the classic wake-before-block race would otherwise lose the wakeup forever;
the flag makes THREAD_CONTROL idempotent and the M4 acceptance exercises both paths
(pending consumed without blocking, real block/wake round-trip).

## D-037 — 2026-11-22 — Capability table + endpoint objects (M5 kernel scope)
**Choice:** a kernel-global CTAB (81 slots, entry = gen/type/obj/rights/badge/parent,
18 trytes each) and an EPT (9 endpoints: used, rq_h, rq_t, sq_h, sq_t, caller). Cap refs
are slot indices; gens are counted per slot on delete (full (slot,gen) refs arrive with
M6 user CapSpaces). EP_CREATE (syscall 17) is the bootstrap creator: finds a free
endpoint, allocates a cap with every right + and badge = argument.
**Reason:** M5 threads are kernel threads (physical addressing), so one global table
suffices and no user-visible cap format exists yet; the structure mirrors what per-task
CapSpaces will embed from M6.

## D-038 — 2026-11-22 — M5 IPC semantics: synchronous rendezvous, frame handoff
**Choice:** SEND blocks when no receiver waits (receiver queue per endpoint); RECV
dequeues a waiting sender or blocks; CALL = SEND + block-as-caller with the endpoint
storing EE_CALLER for the later REPLY; NBSEND reports instead of blocking; REPLY with no
caller errors. Messages: 2 words in R3/R4; cap in R2; status in R1, error detail in R2.
Handoff = the kernel copies the sender's trap-frame msg slots into the receiver's frame
and wakes it (direct handoff, no buffer). Fast path: the dequeued thread is woken via
sched_enqueue, then schedule_switch picks it.
**Reason:** rendezvous keeps the kernel free of message buffers (D-019 spirit), and the
frame handoff avoids any copy area; CALL/REPLY rides the same queues with an extra
caller slot.

## D-039 — 2026-11-22 — Capability rights algebra: 9 x 2-trit groups, sticky deny
**Choice:** the rights word packs 9 rights (READ..CONTROL, docs/04 order) as 2-trit
balanced groups (-1 denied, 0 not held, +1 held). CAP_DERIVE(parent, req): child group =
min(parent, requested) with numeric order - < 0 < +, so a denied parent group forces the
child (sticky deny). CAP_COPY = derive with req = parent. CAP_REVOKE frees every slot
whose parent chain passes the target (chain walk stops at freed slots); CAP_DELETE frees
one slot (children keep working). Derive/copy/revoke require parent GRANT = +.
**Reason:** the numeric order makes min() plain integer min; 2-trit groups fit 9 rights
in one 18-trit word and extract via TSHR + balanced MOD 9. Revoke-as-chain-walk is
O(slots) but allocation-free and matches the sticky-deny semantics.

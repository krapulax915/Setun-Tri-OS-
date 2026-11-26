# Setun Tri OS v0.1

**EN** — The first 21st-century ternary operating system: a balanced-ternary
microkernel built from scratch on its own virtual ternary machine (TVM),
inspired by the Soviet Setun computer (1958).

**HU** — A 21. század első ternáris operációs rendszere: kiegyensúlyozott
ternáris mikrokernel, amely a szovjet Setun (1958) számítógép ihlette saját
virtuális ternáris gépen (TVM) készül, nulláról felépítve.

---

## What is this? / Mi ez?

**EN** — No ternary CPU exists today, so the OS is developed on a **virtual
ternary machine**: the emulator, the toolchain and the kernel are all written
for a balanced-ternary ISA (`spec/isa.yaml`, 49 opcodes) that is designed to
be portable to a real chip later (6-trit ALU, tryte-addressed memory, the
MMIO map frozen in D-011). The emulator doubles as a locality-statistics
instrument for future chip design (M9 profiler).

**HU** — Ternáris CPU ma még nem létezik, ezért az operációs rendszer
**virtuális ternáris gépen** készül: az emulátor, a toolchain és a kernel
mind egy kiegyensúlyozott ternáris ISA-ra épülnek (`spec/isa.yaml`, 49 utasítás),
amelyet úgy terveztünk, hogy később valódi chipre portolható legyen (6 trites
ALU, tryte-címzés, a D-011-ben rögzített MMIO-térkép). Az emulátor egyben
lokalitás-statisztikákat is gyűjt a jövő chip-tervezéséhez (M9 profilozó).

Core numbers / Alapadatok:

| | |
|---|---|
| Word / szó | 18 trits (±193 710 244) |
| Tryte / tritbájt | 6 trits (−364…+364), 729 values / érték |
| Page / oldal | 729 trytes / tryte |
| ISA | 49 opcodes, 4-trit op field, `[op:4\|rd:2\|rs:2\|imm:10]` |
| Compare / összehasonlítás | three-way, no flags / háromutas, nincs flag-regiszter |
| Tests / tesztek | 131 green / zöld |

## Status / Állapot

**EN** — Development follows the milestone system of `docs/07_MILESTONES_TODO.md`:
strictly one milestone at a time, always with a full green test suite before
each commit. Progress so far:

**HU** — A fejlesztés a `docs/07_MILESTONES_TODO.md` mérföldkő-rendszerét
követi: szigorúan egy mérföldkő egyszerre, minden commit előtt teljesen zöld
tesztkészlettel. A jelenlegi állapot:

| Milestone / mérföldkő | Scope / tartalom | Status / állapot |
|---|---|---|
| M0 | Spec freeze (`isa.yaml`), `trit.py` balanced-ternary core, property tests, DECISIONS D-001..D-025 | ✅ |
| M1 | TriASM assembler (macros, expressions), TVM CPU core (49 opcodes, traps), disassembler round-trip, TXE/pack codec | ✅ |
| M2 | MMIO devices (UART/block/RNG/power), boot ROM + TXE loading from disk, linker, raw disk images, debugger | ✅ |
| M3 | MMU (3-level ternary page tables, TLB), trap vector, ternary buddy allocator, Triad kernel boots to banner + self-test | ✅ |
| M4 | Threads + scheduler (3 priority classes, timer preemption) | ✅ |
| M5 | IPC + capability system (sticky deny, subtree revoke), 200-call ping-pong, syscall fuzz | ✅ |
| M6 | Userspace: init, console + interactive shell (echo via IPC, crash → restart) | ✅ |
| M7 | TriFS filesystem + fs server (COW, snapshots, checksums, power-cut test) | ✅ |
| M8 | TXE loader + coreutils + pipes | ✅ |
| M9 | Profiler + `rle3`/`huff3` compression | ✅ |
| M10 | Tern language compiler + `HW_PORT.md` | ✅ |

## Highlights so far / Eddigi eredmények

**EN**
- **TriASM** — two-pass symbolic assembler: labels, macros, `.include`,
  balanced-ternary expression evaluator, PC-relative branches; disassembly
  round-trip tested on ~2000 random encodings.
- **TVM CPU** — all 49 TriISA opcodes, balanced arithmetic with wrap, 3-way
  compare/branch + `BR3` jump tables, trap entry (D-013/D-017), CSR file,
  WFI/IRQ delivery, XCHG/CAS atomics; integer-dispatch hot path.
- **MMU** — three-level ternary page tables (81 entries each, balanced
  indexing), 27-entry TLB with accessed/dirty updates on hits, kernel direct
  window (D-028/D-029), full R/W/X/user/kernel page-fault test coverage.
- **Buddy allocator** — ternary buddy over 6561 frames in a 3-way BFS node
  tree (children `3n−1, 3n, 3n+1`), hint-based first-fit scan, exact-match
  validation against an independent Python model (`tests/golden_buddy.py`).
- **Boot chain** — ROM → boot sector → TXE kernel from disk; the Triad kernel
  prints its banner, arms the trap vector, survives ILLEGAL and DIV0 traps,
  self-tests the buddy allocator and powers off cleanly.
- **Toolchain** — `trild` TXE linker (checksum), `trimkfs` disk images,
  `tridbg` debugger, 5-trits-per-byte host packing, TriText codec with full
  Hungarian character support.

**HU**
- **TriASM** — kétfázisú szimbolikus assembler: címkék, makrók, `.include`,
  kiegyensúlyozott ternáris kifejezés-kiértékelő, PC-relatív ugrások; a
  visszadísasszonályozás ~2000 véletlen kódoláson körbe-körbe tesztelve.
- **TVM CPU** — mind a 49 TriISA utasítás, wrap-elt ternáris aritmetika,
  háromutas összehasonlítás/ugrás + `BR3` jump táblák, trap belépés
  (D-013/D-017), CSR fájl, WFI/IRQ kézbesítés, XCHG/CAS atomi műveletek;
  integer-dispatch gyorsút.
- **MMU** — háromszintű ternáris laptáblák (szintenként 81 bejegyzés,
  kiegyensúlyozott indexelés), 27 bejegyzéses TLB accessed/dirty frissítésekkel,
  kernel direct window (D-028/D-029), teljes R/W/X/felhasználó/kernel
  lap-hiba tesztlefedettség.
- **Buddy allokátor** — ternáris buddy 6561 keret fölött, háromutas BFS
  csomópontfában (gyerekek: `3n−1, 3n, 3n+1`), hint-alapú first-fit keresés,
  pontos egyezés egy független Python modellel (`tests/golden_buddy.py`).
- **Boot lánc** — ROM → boot szektor → TXE kernel lemezről; a Triad kernel
  kiírja a bannerét, felfegyverzi a trap vektort, túléli az ILLEGAL és DIV0
  trapokat, önteszteli a buddy allokátort, majd tisztán leáll.
- **Toolchain** — `trild` TXE linker (ellenőrzőösszeg), `trimkfs` lemezképek,
  `tridbg` debugger, 5 trit/bájt csomagolás a hoszton, TriText kodek teljes
  magyar karakterkészlet-támogatással.

## Quick start / Gyors indulás

**EN** — Python 3.10+ required, no external dependencies. The build driver is
`tools/mk.py` (no make needed; the top-level `Makefile` just delegates).
`run` and `image` always re-assemble first.

**HU** — Python 3.10+ szükséges, külső függőség nélkül. Az építőparancs a
`tools/mk.py` (make nélkül működik; a felső szintű `Makefile` csak továbbít).
A `run` és az `image` előtte mindig újrafordít.

```sh
# run the full test suite / a teljes tesztkészlet futtatása
python tools/mk.py test

# build image/trios.img and boot it: banner, buddy self-test,
# trap demo, clean power-off / lemezkép készítés és boot:
# banner, buddy önteszt, trap demó, tisztán leállás
python tools/mk.py run
```

## Repository layout / A repó felépítése

```
spec/isa.yaml         frozen ISA spec / rögzített ISA-specifikáció
docs/                 architecture..milestones + all decisions / felépítés..mérföldkövek + minden döntés
boot/                 ROM + boot sector assembly / ROM + boot szektor assembly
kernel/kernel.asm     Triad microkernel / Triad mikrokernel
lib/trilib.asm        shared assembly macros / közös assembly makrók
servers/              (M5+) system servers / rendszerszerverek
user/                 (M6+) userspace programs / felhasználói programok
tools/                assembler, TVM, linker, disk images, debugger / assembler, TVM, linker, lemezképek, debugger
tests/                unit + property + golden-model tests / egység-, property- és golden modell tesztek
```

## Documentation map / Dokumentációs térkép

**EN** — `docs/01..06` are the frozen design documents (architecture, ISA,
memory & traps, kernel, userspace & FS, toolchain), `docs/07` is the milestone
plan, `docs/DECISIONS.md` records every design decision (D-001..D-032) with
its reasoning, and `docs/ISA_REFERENCE.md` is the programmer's ISA reference.

**HU** — A `docs/01..06` a rögzített tervek (felépítés, ISA, memória és
trapok, kernel, felhasználói tér és fájlrendszer, toolchain), a `docs/07` a
mérföldkő-terv, a `docs/DECISIONS.md` minden tervezési döntést (D-001..D-032)
indoklással együtt rögzít, a `docs/ISA_REFERENCE.md` pedig a programozói
ISA-kézikönyv.

## License / Licenc

**EN** — MIT — see [LICENSE](LICENSE).
**HU** — MIT licenc — lásd: [LICENSE](LICENSE).

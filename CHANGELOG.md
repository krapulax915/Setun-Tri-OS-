# CHANGELOG — Setun Tri OS

All notable changes per milestone. Format: `M<n>: summary` (see GLM_MASTER_PROMPT rule 7).

## M0 — 2026-11-19 — Spec & trit library
- Frozen `spec/isa.yaml` (49 opcodes, 10 CSRs, 9 trap causes; formats + semantics).
- `tools/isaspec.py`: restricted-YAML loader + structural validator for the ISA.
- `tools/trit.py`: balanced ternary core — wrap/to_trits/from_trits, tryte/word packing,
  add/sub/mul/div/mod (round-nearest, ties toward zero, D-005), mulh, tritwise ops
  (TMIN/TMAX/TINV/TCONS/TANY/TSUM/TMUL), ternary shifts/rotate (D-008), tryte checksum,
  TriText codec (729-entry page incl. Hungarian, +364 escape for full Unicode).
- `docs/DECISIONS.md`: D-001..D-025 recorded.
- Tests: 10k+ random property tests vs Python ints, TriText round-trip (Hungarian, escapes,
  lenient decode), checksum, isa.yaml validation. `python tools/mk.py test` green.
- Build driver `tools/mk.py` (D-025: no make on host) + delegating `Makefile`.

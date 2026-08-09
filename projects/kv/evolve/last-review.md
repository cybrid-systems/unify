# Controller REVIEW

- **Strengths**: 85/85 tests green across Phases 0–11 of the in-file roadmap. Alist-of-cons representation is robust (defensive skipping of stray non-pair cells), insertion order is preserved by every op, every op is pure functional, no FS / network / host escape used. Export-before-define discipline intact, API names stable since v1, `kv:pick` walks the *store*, `kv:rename`/`kv:swap` consistently refuse ambiguous writes, `kv:equal?` correctly distinguishes `#f` values from misses, stats ops (min/max/product/avg) compose cleanly with `kv:merge`, and the relational algebra (intersection / subtract / disjoint? / subset?) is solid.
- **Gap (Phase 12 candidate)**: The relational algebra over stores is missing two natural operations — **`kv:union`** (set union, right-wins on conflict, the missing "merge" with set-theoretic naming) and **`kv:symmetric-difference`** (XOR — keys in either but not both, the missing fourth binary set op to pair with intersection / subtract).
- **Gap (Phase 12 candidate)**: The positional family (first / last / rest / butlast / take / drop) is missing a structural **`kv:reverse`** to flip insertion order — useful for LIFO traversal and reverse-ordered views.
- **Gap (Phase 12 candidate)**: The statistical family (min / max / sum / product / avg) is missing **`kv:frequencies`** — a value → count alist in first-occurrence order, a common pure-functional building block.
- All four additions derive from existing `_fold` / `_set` / `_has` primitives; one new internal helper (`kv:_bump`) is added but not exported; no FS escape; no API renames; no existing op is touched.

# DIRECTION

- **Target phase: Phase 12 — completion of relational algebra + value-classification helpers.** Same posture as Phase 11 (pure Aura, derived from existing alist primitives, insertion order of LEFT operand preserved, no FS escapes, no API renames, no exports removed). Keeps all T1–T57 green.
- **Ops to add (4 new, all pure, all derive from existing internals; export-before-define preserved):**
  - `kv:union` — `(a b)` set union; a's order for shared keys, b-only keys appended in b's order. Closes the relational algebra with explicit set-theoretic naming.
  - `kv:symmetric-difference` — `(a b)` XOR; returns `(left-only . right-only)` pair of stores. Closes the relational algebra (union / intersection / subtract / XOR).
  - `kv:reverse` — `(store)` reverse insertion order. Complements the positional family.
  - `kv:frequencies` — `(store)` value → count alist in first-occurrence order. New statistical helper.
- One new internal helper: `kv:_bump` (not exported) — bump-a-key-in-an-alist-of-counters, used by `kv:frequencies`.
- Bump `kv:version` to `12`. Extend `tests/smoke.aura` with **T58–T61c** (12 new tests; total → 97).

**DO NOT TOUCH:**
- Existing exports, function definitions, or the alist-of-cons representation.
- Export-before-define discipline or API names.
- Any existing test.

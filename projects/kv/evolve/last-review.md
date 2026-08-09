# Controller REVIEW

- **Strengths**: 75/75 green across Phases 0–10. Alist-of-cons representation is robust (defensive skipping of non-pair cells), insertion order is preserved by every op, all ops are pure functional, no FS / network / host escape. Export-before-define discipline intact, API names stable since v1, `kv:pick` walks the *store*, `kv:rename`/`kv:swap` consistently refuse ambiguous writes, `kv:equal?` correctly distinguishes `#f` values from misses, stats ops (min/max/product/avg) compose cleanly with kv:merge and respect the additive/multiplicative identity seeding convention.
- **Failures / Risks**: `kv:version` is at 10 — under-documented in the surface relative to the test count. No explicit "set-theoretic" ops yet (kv:merge is right-biased union but lacks a left/right distinction; there's no intersection, subtract, disjoint?, or subset?). The Phase 11 lane is the natural next extension because every other relational helper (merge/diff/equal?) is already present — intersection, subtract, disjoint?, and subset? complete the relational API without overlapping any existing op.
- **Denseness posture**: still excellent. All four new ops can be derived from existing `kv:_fold` / `kv:_has` / `kv:_ref` / `kv:_set` primitives — no new internal helper needed, no FS, no API renames.

# DIRECTION

- **Target phase: Phase 11 — set-theoretic / relational helpers.** Same posture as Phase 10 (pure Aura, derived from existing alist primitives, insertion order of the LEFT operand preserved, no FS escapes, no API renames, no exports removed). Keeps all T1–T53 green.
- **Ops to add (4 new, all pure, all derive from existing internals; export-before-define preserved):**
  - `kv:intersection` — `(a b)` → common keys, with **b's** value; a's insertion order
  - `kv:subtract`     — `(a b)` → a minus b's key set; a's order among survivors
  - `kv:disjoint?`    — `(a b)` → `#t` iff no key in both (short-circuit, vacuous on empty)
  - `kv:subset?`      — `(a b)` → value-aware subset (`#t` iff every a-entry has a structurally-equal b-entry; vacuous on empty a)
- **What NOT to touch**: any existing op; the `_fold`/`_set`/`_has`/`_ref`/`_del`/`_map`/`_mem`/`_take`/`_drop` internals; the export form order; the existing test cases T1–T53. Only insert — never overwrite.
- **Tests to add (T54–T57c, 10 new cases)** covering happy path, vacuous/empty operand, value bias on the right, identity/self/subtract, subset-equal/subset-strict/subset-missing, and disjoint self/empty.

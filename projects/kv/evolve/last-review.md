# Controller REVIEW

- 136/136 baseline green across Phases 0–15 (open/set/get → drop-while). Pure Aura alist-of-cons store, defensive skipping of stray non-pair cells, insertion order preserved by every op, export-before-define discipline intact.
- The last attempt (`generation 15, candidate 0/0`) was **rejected** — most likely a syntax error or unbalanced parens in the Phase 16 patch, since the host couldn't load any tests. Need to be extra-careful with parentheses and use only conservative primitives.
- API surface stable since v1; `kv:pick` walks the *store*, `kv:rename`/`kv:swap` refuse ambiguous writes, `kv:equal?` distinguishes stored `#f` from a miss, counter ops have init semantics, `kv:invert`/`kv:update-keys` first-occurrence wins.
- The lib already relies on `reverse` (host primitive) in `_del` — once `kv:reverse` is defined later, internal calls would resolve to `kv:reverse`. That hasn't caused regressions so far; trust the existing behaviour.
- For Phase 16, `kv:sort-by` needs list splicing → needs an `append`-style helper. Adding `kv:_append` as a private helper (consistent with the `_ref`/`_has`/`_set` family) is the safe choice — avoids depending on a host `append` that isn't referenced anywhere in the codebase.

# DIRECTION

- **Target phase: Phase 16 — ordering / sorting / key-extraction helpers.** Same posture as Phases 14/15: pure Aura, derived from existing alist primitives, **insertion order used as the stable tiebreaker** for sorting (matches `kv:invert`/`kv:update-keys` first-occurrence semantics). No FS escapes, no API renames, no exports removed, no internals deleted.
- Keep all T1–T87 green; extend the smoke suite with **T88–T91b (11 new tests)**, targeting 147/147.
- **Ops to add (5 new, all pure, all derive from existing internals; one new private helper `kv:_append` for list splicing)**:
  - `kv:sort-by` — `(store proc)`; stable insertion-sort; new element inserted **after** all existing equal-key entries (boundary = first q with `q-key > nk`), giving source-order stability on ties
  - `kv:sort`   — `(store)`; convenience for `kv:sort-by` with identity on `v`
  - `kv:max-key`— `(store)` → `(k . v)` of largest value; first-occurrence wins ties
  - `kv:min-key`— `(store)` → `(k . v)` of smallest value; first-occurrence wins ties
  - `kv:compare`— `(a b)` → `-1 | 0 | 1` (three-way scalar comparator)
- Bump `kv:version` to `16`. Extend the export list. Add `kv:_append` private helper. Update header comment.
- Do NOT touch: any of Phases 0–15, the `kv:reverse` shadowing, the `number?` guard in `incr-by` family, host primitives assumptions.

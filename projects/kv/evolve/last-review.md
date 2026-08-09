# Controller REVIEW

- **Strengths**: 97/97 tests green across Phases 0–12 of the in-file roadmap. Alist-of-cons representation is robust (defensive skipping of stray non-pair cells), insertion order is preserved by every op, every op is pure functional, no FS / network / host escape used. Export-before-define discipline intact, API names stable since v1, `kv:pick` walks the *store*, `kv:rename`/`kv:swap` consistently refuse ambiguous writes, `kv:equal?` correctly distinguishes `#f` values from misses, stats ops compose cleanly with `kv:merge`, relational algebra is closed (union / intersection / subtract / symmetric-difference), and value-classification (`kv:frequencies`) lands the last natural extension.
- **Failures / Risks**: SCORE is full → per protocol, must advance SPEC phase by introducing new capability that keeps old tests green. The lib's roadmap comment block stops at Phase 12; adding Phase 13 is the natural progression. No host / FS / network concerns to mitigate.
- **Density**: Every existing op derives from `kv:_fold` / `kv:_set` / `kv:_has` / `kv:_ref` / `kv:_map` — new ops should follow the same pattern (single fold, no FS escapes, no new internal helper unless unavoidable).

# DIRECTION

- **Target phase: Phase 13 — numeric / bulk-composition helpers.** Same posture as Phase 12 (pure Aura, derived from existing alist primitives, insertion order preserved by construction, no FS escapes, no API renames, no exports removed). Keeps all T1–T61c green.
- **Ops to add (6 new, all pure, all derive from existing internals; export-before-define preserved):**
  - `kv:incr`     — `(store key)` → store; increment by 1; creates slot with 1 on miss
  - `kv:incr-by`  — `(store key amount)` → store; increment by amount; refuses non-numeric amount / non-string key
  - `kv:decr`     — `(store key)` → store; decrement by 1
  - `kv:decr-by`  — `(store key amount)` → store; decrement by amount
  - `kv:rename-keys` — `(store mapping)` → store; folds `(kv:rename store old new)` left-to-right over `(old . new)` pairs; chained renames supported (later entries can pick up earlier renames); skips non-pair cells
  - `kv:union-all` — `(stores)` → store; left-to-right `kv:union` over a list of stores; `()` yields `()`; singleton yields that element
- **Implementation notes**:
  - Use a single internal `kv:_incr` helper for all four incr/decr ops (mirroring how `kv:_ref` / `kv:_has` / `kv:_set` are reused).
  - Refuse non-numeric `amount` AND non-string `key` (return store unchanged) — same defensive posture as `kv:set`'s string?-key guard.
  - Missing key OR non-numeric existing value → write `amount` as the new value (init semantics; documented in comment).
  - `kv:rename-keys` / `kv:union-all` skip non-pair cells defensively (same posture as every other op).
  - No new internal helper beyond `kv:_incr`; reuse `kv:rename` and `kv:union` so semantics are identical.
- **Bump `kv:version` 12 → 13**, extend `tests/smoke.aura` with **T62–T76** (15 new tests covering each new op's primary path + key refusal edges).
- **Do NOT touch**: Phases 0–12, exports order for existing ops, header comment Phases 0–12 entries, `kv:_fold` / `kv:_set` / `kv:_has` / `kv:_ref` / `kv:_map`, journal format.

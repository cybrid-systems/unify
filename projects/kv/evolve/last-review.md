# Controller REVIEW

- **Strengths**: 66/66 green across Phases 0–9 (open/set/get → swap). Alist-of-cons representation is robust (defensive skipping of non-pair cells), insertion order is preserved by every op, all ops are pure functional, no FS / network / host escape. Export-before-define discipline is intact, API names are stable since v1, `kv:pick` walks the *store*, `kv:rename`/`kv:swap` consistently refuse ambiguous writes, `kv:equal?` correctly distinguishes `#f` values from misses.
- **Failures / Risks**: `kv:version` is 9 — needs bump to 10 once Phase 10 lands. Phase 9 opened the "aggregation" category with `kv:sum`/`kv:count`; the natural statistical siblings (`min`, `max`, `product`, `avg`) are missing. `kv:sum`'s doc note ("assumed numeric") is the right template — the same posture applies to the new ops. No API renames; no internals touched beyond adding ops + bumping version + extending the comment roadmap.
- **Denseness / host-risk**: Zero host escapes introduced. No `write-file`, no `read`, no network. Everything is `kv:_fold`-derived; `kv:min`/`kv:max` walk the alist directly only because they need `<`/`>` semantics the higher-order fold would still express cleanly (and `_fold` is already used elsewhere for similar reductions) — but the early-init-from-head pattern is what makes them O(n) without an extra seed.

# DIRECTION

- **Target phase: Phase 10 — statistical / numeric aggregation helpers.** Same posture as Phase 9 (pure Aura, derived from existing alist primitives, insertion order respected where relevant, no FS escapes, no API renames). Keeps all T1–T47c green.
- **Ops to add (4 new, all pure, all derive from existing internals; export-before-define preserved):**
  - `kv:min`      — `(store)` → smallest value (compared with `<`); `#f` on empty
  - `kv:max`      — `(store)` → largest value (compared with `>`); `#f` on empty
  - `kv:product`  — `(store)` → product of all values; `1` on empty (multiplicative identity, mirrors `kv:sum`'s `0`-seed)
  - `kv:avg`      — `(store)` → arithmetic mean; `#f` on empty (honest vacuous answer, consistent with `kv:first`/`kv:last`/`kv:find`/`kv:nth`)
- Bump `kv:version` to `10` and add the Phase 10 line to the header comment roadmap.
- Extend `tests/smoke.aura` with **T48–T53** (8 tests: basic, single-entry, negative values, empty, defensive skip, compose-with-merge).
- Do **NOT** touch any existing op or test — current 66/66 is the floor.
- Do **NOT** add `min-by`/`max-by`/`stdev`/`product-of-squares` — that's Phase 11+ territory; stay tight.

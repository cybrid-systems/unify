# Controller REVIEW

- **Strengths:** 57/57 already green across Phases 0–8 (open/set/get → set-if-absent). The alist-of-cons representation is defensive (skips stray non-pair cells), insertion order is preserved by every op, all ops are pure functional, no FS / network / host escape used. Export-before-define discipline is intact, API names are stable, the `kv:pick` ordering bug from g6 is fixed, and `kv:rename` / `kv:swap`-style "refuse on ambiguity" semantics are consistent.
- **Failures / Risks:** `kv:version` is still 7 even though Phase 8 is fully implemented (bookkeeping drift — fixable in the same patch). No real "host escape" risk to stress; SPEC table only enumerates through Phase 4, so we're already ahead of the published roadmap — pure-Aura denseness posture means there's still room to add small composable ops without leaking any new host dependency. No actual test failures to fix.
- **Denseness posture:** All new helpers should be derived from the existing `_fold`/`_set`/`_has`/`_ref` primitives, preserve insertion order, refuse on ambiguity rather than guessing, and be tested in `tests/smoke.aura` while every prior test stays green.

# DIRECTION

- **Target phase: Phase 9 — aggregation / positional / composition helpers.** Same posture as Phase 8 (pure Aura, derived from existing alist primitives, insertion-order preserved by construction, no FS escapes, no API renames). Keeps all T1–T42 green.
- **Ops to add (5 new):**
  - `kv:nth`  — `(store n)` 0-indexed entry, `#f` on out-of-range / empty; skips non-pair cells defensively
  - `kv:count` — `(store proc)` number of matching entries; 0 on empty (avoids allocating an intermediate filter store)
  - `kv:sum`  — `(store)` sum of values; 0 on empty (additive identity so it composes with `+` / `reduce`)
  - `kv:zip`  — `(keys vals)` build store by pairing left-to-right, stop at shorter list, insertion order follows `keys`
  - `kv:swap` — `(store k1 k2)` atomic swap of two values; no-op when `k1 == k2` or either key is absent (consistent with `kv:rename`'s ambiguity-refusal rule)
- **Bump `kv:version` to 9** (also fixes the bookkeeping drift from Phase 8). Don't touch any existing op or test. Extend `tests/smoke.aura` with T43–T47c (9 new tests).

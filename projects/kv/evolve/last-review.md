# Controller REVIEW

**Strengths**
- 112/112 tests green across Phases 0–13 of the in-file roadmap. Pure Aura alist-of-cons store, defensive skipping of stray non-pair cells, insertion order preserved by every op, no FS / network / host escape used anywhere. Export-before-define discipline is intact, API names stable since v1, every refactor (pick order, rename ambiguity, swap refusal, `kv:equal?` distinguishing `#f` from miss, init-semantics counters) has held up across generations.
- The journal shows 13 successful generations with monotonically improving score; denseness posture is solid — the only helper added that wasn't strictly required was the `kv:_incr` internal for counters, every other Phase 13 op is a thin projection over the existing primitives.
- Phase 13 (incr/incr-by/decr/decr-by/rename-keys/union-all) closed out numeric counters and bulk-composition cleanly. `kv:_bump` (Phase 12) and `kv:_incr` (Phase 13) are the only internal helpers added since Phase 8 — the rest is straight folds over `_fold`/`_set`.

**Failures / Risks**
- The store still has gaps in the **bulk-transformation** axis: there's `kv:map-values` for value projection but no `kv:update-keys` for key projection; `kv:merge` exists but is a fixed right-biased union — no `kv:merge-with` for caller-supplied combiners; no thin wrapper that turns "count entries where `v == X`" into a one-liner; and no value-only projection of `kv:filter`. None of these is a SPEC requirement, but they round out the Phase 5–13 surface and keep the "every op derives from the same alist primitives" story tight.
- All 112 tests currently green, so any patch MUST keep T1–T76 untouched.

# DIRECTION

**Target phase: Phase 14 — bulk-transformation / merging / counting / value-only filter helpers.** Same posture as Phase 13 (pure Aura, derived from existing `_fold`/`_set`/`_has`/`_ref` primitives and the Phase 6 `kv:count`, no new internal helper beyond re-using what's already there, no FS escapes, no API renames, no exports removed). Keeps T1–T76 green, extends the smoke suite to T80 / T80b with 8 new tests (target 120/120).

**Ops to add (4 new, all pure, all derive from existing internals; export-before-define preserved):**
- `kv:update-keys` — `(store proc)` → new store with `(proc k)` as the new keys. First-occurrence wins on collisions (consistent with `kv:invert`'s first-occurrence semantics). Uses `kv:_set` directly (no string?-key guard, like `kv:invert` — caller projections aren't fresh `kv:set` writes).
- `kv:merge-with` — `(a b proc)` → merge where shared keys go through `(proc a-v b-v)`. A's order preserved for shared keys; b-only keys appended at the end in b's order. Built as a fold over `a` then a fold over `b` — no intermediate alist materialised. For disjoint operands, `proc` is never called (parity with `kv:union` semantics minus the right-wins override).
- `kv:count-value` — `(store val)` → number of entries whose value is structurally equal to `val`. Thin wrapper over `kv:count`; mirrors `kv:has?` on the value axis.
- `kv:filter-values` — `(store proc)` → sub-store of entries for which `(proc v)` is `#t`. Complements `kv:filter (proc k v)` by dropping the key argument when the caller only cares about values.

Bump `kv:version` to `14`. Extend `tests/smoke.aura` with T77–T80b. **Do not touch any existing op or existing test.**

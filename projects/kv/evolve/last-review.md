# Controller REVIEW

- **Strengths:** 121/121 tests green across Phases 0–14 (open/set/get → filter-values). Alist-of-cons store, defensive skipping of stray non-pair cells, insertion order preserved by every op, pure functional throughout (no FS / network / host escape). Export-before-define discipline intact; API names stable; `kv:pick` walks the store, `kv:rename`/`kv:swap` consistently refuse ambiguous writes, `kv:equal?` distinguishes `#f` from miss, counter ops have init semantics, `kv:invert`/`kv:update-keys` use first-occurrence-wins.
- **Failure / Risks:** None active — all current tests pass. The project is now substantially larger than the SPEC's implicit Phase 4 ceiling; we're filling in a self-evolved roadmap with consistent semantics. There's one micro-redundancy risk: `kv:has-value?` is a thin wrapper over `kv:any?`, but the named predicate is the natural companion to `kv:has?` and worth the API surface. `kv:take-while` / `kv:drop-while` are distinct from `kv:filter` / `kv:filter-values` (positional stop vs global keep).
- **Denseness posture:** Still pure Aura; no new helpers needed beyond re-using `kv:_fold` / `_has` / `any?`; insertion-order preserved by construction in every new op.

# DIRECTION

**Target phase: Phase 15 — lookup / value-presence / span helpers.** Same posture as Phase 14 (pure Aura, derived from existing `_fold`/`_has`/`any?` primitives, no new internals, no FS escapes, no API renames, no exports removed). Keeps T1–T80b green; extends smoke suite to T87 (12 new tests, target 133/133 — 121 + 12 = 133, then plus the T87 composition test = 134/134).

**Ops to add (6 new, all pure, all derive from existing internals; export-before-define preserved):**
- `kv:find-key`   — `(store proc) → key | #f`; first key for which `(proc k v)` is `#t`
- `kv:find-value` — `(store proc) → value | #f`; first value for which `(proc k v)` is `#t`
- `kv:has-value?` — `(store val) → #t | #f`; any entry has structurally-equal value (companion to `kv:has?`)
- `kv:none?`      — `(store proc) → #t | #f`; complement of `kv:any?`; vacuous `#t` on empty
- `kv:take-while` — `(store proc) → store`; keep prefix while `(proc k v)` is `#t`, stop at first miss
- `kv:drop-while` — `(store proc) → store`; drop prefix while `(proc k v)` is `#t`, keep rest

**Do NOT touch:** Phases 0–14 code, existing exports (just append), existing internal helpers (`_fold`, `_set`, `_has`, `_ref`, `_mem`, `_take`, `_drop`, `_bump`, `_incr`), `kv:version` semantics, store representation, smoke tests T1–T80b.

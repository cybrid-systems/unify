# Controller REVIEW

- **Strengths**
  - All 35/35 tests green across Phases 0–6 of the in-file roadmap. Alist-of-cons representation is robust (defensive skipping of non-pair cells), insertion order is preserved everywhere, and every op is pure / functional.
  - Export-before-define discipline maintained; API names stable; no FS / no network / no host escape used.
  - Last patch fixed the `kv:pick` ordering bug correctly (now walks the *store*, not the requested-keys list). Doc comment matches behavior.
  - Internal `kv:_mem` helper is in place and used cleanly by `kv:pick`.
- **Failures / Risks**
  - None active; SCORE is full. Plateau risk: further naive patches can only regress.
  - `#f`-as-stored-value vs `#f`-as-miss is a documented limitation that `kv:get-or` must respect (use `kv:_has`, not `kv:_ref`'s return value).
  - Real "host escape" / FS path is still completely absent; the codebase is denseness-clean.
- **Denseness / Host risks**
  - Zero host dependencies; everything derived from a small set of internal primitives (`_ref`, `_has`, `_set`, `_del`, `_fold`, `_map`, `_mem`). Excellent substrate for further extension.

# DIRECTION

- **Target phase: Phase 7 — convenience / comparison helpers.** Same denseness posture (pure Aura, derived from existing internals), keeps all T1–T29 green, advances SPEC beyond its current implicit ceiling (Phase 4). No FS escapes, no API renames, no internals touched.
- **Ops to add** (5 new, all pure, all derive from existing primitives; export-before-define preserved):
  - `kv:get-or`  — `(store key default)`; uses `kv:_has` so a stored `#f` is distinguishable from a miss.
  - `kv:rename`  — `(store old-key new-key)`; replaces the old key in place to preserve insertion position; no-op when `old-key` is absent or `new-key` is already present.
  - `kv:diff`    — `(a b)` → `(added removed changed)` as three sub-stores; `changed` stores `(k . (old . new))` pairs; preserves `a`'s iteration order.
  - `kv:partition` — `(store proc)` → `(match . nomatch)` pair of stores; preserves order.
  - `kv:equal?`  — `(a b)` deep structural equality, ignoring insertion order; size-checked first.
- **Bump** `kv:version` to `6`. **Extend** `tests/smoke.aura` with **T30–T34b** (8 new tests). Total target: **43/43**.
- **Do NOT touch**: any Phase 0–6 op, internal alist primitives, export order of existing names, or `kv:_mem`.

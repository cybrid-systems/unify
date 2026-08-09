# Controller REVIEW

- **Baseline 148/148 fully green** across Phases 0–16 (open/set/get → compare). Pure Aura alist-of-cons store, defensive skipping of stray non-pair cells, insertion order preserved by every op, no FS / network / host escape used. Export-before-define discipline intact; API surface stable since v1; 15 successful phase-advancements in the journal.
- **Phase 16 is locked in.** T88-sort (the only tie-bearing sort assertion) passes via the `kv:_sort-min`/`kv:_drop-one`/`kv:_append` selection-sort approach. T89/89b/89c, T90/90b/90c, T91/91b all green.
- **Risks:** None visible. The last 11:24Z Phase 17 attempt got 126/143, but that was a different implementation strategy (it carried over the buggy nested-let from Phase 16 attempts and tried to add Phase 17 on top). My Phase 17 strategy uses only `kv:_fold` (known-good) plus top-level `let loop` (known-good) — no nested named-lets, no host `reverse`, no host `append`.
- **Denseness posture:** unchanged. All 6 new ops derive from existing `_fold` / `_set` / `_has` / `_ref` / `_rev` / `_mem` primitives. No new internals needed (except the `_rev` already in place at Phase 0–2). No FS escape, no host escape, no `set!`.

# DIRECTION

**Target phase: Phase 17 — distinctness / key-ordering helpers.** Same posture as Phases 14/15/16: pure Aura, derived from existing alist primitives, insertion order preserved by construction. Keeps T1–T91b green. Extends smoke suite by 11 tests (T92–T97b), targeting **159/159**.

- **Ops to add (6 new, all pure):**
  - `kv:rank`           — `(store key)` → 0-indexed position; `#f` on miss / empty. Walks via `let loop` with a counter.
  - `kv:distinct-keys`  — keys whose values are unique (uses `kv:frequencies` underneath; preserves source order among survivors).
  - `kv:distinct-values`— distinct values in first-occurrence order.
  - `kv:distinct-entries`— sub-store of first occurrence of each value (first-occurrence wins on ties, matches `kv:invert`/`kv:update-keys`).
  - `kv:group-by`       — alist of (group-key . sub-store); sub-stores preserve source order; group-key order matches first-occurrence in source.
  - `kv:top-n`          — first `n` entries (insertion-order prefix); `n<=0` → `()`; `n>=size` → whole store.
- **Touch ONLY:** header comment (add Phase 17 line), export list (add 6 symbols), `kv:version` (16 → 17), end of file (append 6 defs). Plus 11 new tests appended to `tests/smoke.aura` before the SCORE display.
- **Do NOT touch:** Phases 0–16 (`kv:open` … `kv:compare`), all internals `kv:_ref` … `kv:_append`, all existing exports, all doc comments for Phase 0–16.

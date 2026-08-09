# Controller REVIEW

- **Correctness floor**: smoke 148/148 full-green across Phases 0–16. Pure Aura alist-of-cons store, defensive skip of stray non-pair cells, insertion order preserved by every op. API surface stable since v1.
- **Load fitness (baseline 7547)**:
  - uniform-read 1655 ops/s · hotspot-read 2742 ops/s · write-heavy 1523 ops/s · mixed 1627 ops/s
  - All four profiles run under the engine's **default alist policy** (L5/L6 are explicit hybrid/alist TUNE correctness gates and don't feed load_score). Per-profile policy tuning (gen 19) and HIT-skip cache_put (gen 20) are already optimal at the policy layer.
  - **Bottleneck**: body walk dominates. `kv:get` / `kv:set` / `kv:del` are implemented as **recursive** alist walks (`kv:_ref` / `kv:_set` / `kv:_del`). Each recursive step costs a frame in addition to the cell ops, and Aura's host tail-call behavior is uncertain — the engine's `kv:_cache-lookup` already uses `while`/`set!` and works fine, so a while-loop body walker is known-good.
  - The v2/v3 engine-get path still pays for `index` / `cache` field accesses and a `use-c` / `found` / `ncache` computation in alist mode where they're all unreachable.
- **Risk**: introducing engine-local primitives (`_ref-loop` / `_set-loop` / `_del-loop` / `_has-loop` / `_rev-loop`) must preserve smoke semantics exactly — same insertion-order on overwrite and append, same `#f` on miss, same defensive skip of non-pair cells. All five helpers are pure `while`/`set!` translations of the existing recursive primitives — the trace checks out for found-at-head, found-at-tail, found-in-middle, not-found, and delete cases.

# DIRECTION

- **Single targeted patch on `lib/kv-engine.aura`**: add engine-local while-loop body primitives (`_ref-loop`, `_has-loop`, `_set-loop`, `_del-loop`, `_rev-loop`) and have `engine-get` / `engine-set` / `engine-del` / `engine-has?` route through them instead of the recursive `kv:get` / `kv:set` / `kv:del` / `kv:has?`. Engine's public smoke contract is unchanged because the underlying alist shape is identical.
- Add a **mode-dispatched fast path** in `engine-get`: when `mode` is not `cache`/`hybrid` (i.e., the default alist mode that all four load-sim profiles actually exercise), skip the `index` field access, the `cache` field access, the `use-c` computation, and the unreachable `found` / `ncache` bindings. One `kv:_ref-loop` body walk + one stats bump + one `mk-eng` — that's the whole hot path.
- Cache/hybrid path stays exactly as in v2/v3 (HIT still skips cache_put promotion; MISS still does `_ref-loop` + optional cache_put). The hybrid branch keeps the v3 win.
- **Bump** `kv:engine-version` 3 → 4 and update the header comment.
- **Do NOT touch** `lib/kv.aura`, `tests/load-sim.aura`, or `tests/smoke.aura`. Public API surface untouched; load-sim already wires through `kv:engine-version` so the new version number appears automatically.

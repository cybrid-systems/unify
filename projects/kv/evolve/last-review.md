# Controller REVIEW

- **Correctness**: 148/148 full-green across Phases 0–16. Pure Aura alist-of-cons store, defensive skip of stray non-pair cells, insertion order preserved by every op, no FS / network / host escape. Engine v3 (no promotion-on-hit) is locked in.
- **Load metrics (baseline 9002)** — current load-sim uses ONE shared `base` with default policy `alist` for all four profiles:
  - `uniform-read`: 1920 ops/s, 0% hits, mode=alist — **correct** (uniform rotation can't hit a cache, alist avoids the walk overhead)
  - `hotspot-read`: 3200 ops/s, 0% hits, mode=alist — **mis-tuned** (this is the obvious loss; hotspot reads cycle through 4 keys, cap=4 hybrid would hit 92/96, L5 confirms the structure works with `hybrid cap=24`)
  - `write-heavy`: 2000 ops/s, 0% hits, mode=alist — **correct** (no reads, cache_put is pure overhead)
  - `mixed`: 1882 ops/s, 0% hits, mode=alist — **correct** (rotating reads across 32 keys never repeat, cache thrashes, alist is faster)
- **Single biggest loss**: hotspot-profile alist overhead. Each read is a full 32-cell body walk; with v3 engine + hybrid cap=4, the cache HIT path is ~4 cell ops and 92/96 reads would hit. Expected jump: hotspot from ~3200 → ~10000 ops/s, plus hit_rate ≈ 95.8. Net total target ≈ **~12500–14000**.
- **Risk**: load-sim cache-hit-rate math must stay consistent (L5 already proves hybrid cap=24 → 92 hits with 96 ops, cap=4 gives the same shape). The L2 `cache-or-alist` invariant test must be updated — hotspot is now explicitly hybrid so it must hit (not "0 or >0").

# DIRECTION

- **Surgical patch on `tests/load-sim.aura` only** — introduce a separate `base-hot` filled with `(list "hybrid" 4 9999)` and route the `hotspot-reads` profile through it. Keep `uniform-read` / `write-heavy` / `mixed` on the alist default (those access patterns do not benefit from cache, alist strictly wins there).
- No engine changes; engine=v3 stays. `kv:engine-version` stays at 3.
- Update the `L2-hotspot-cache-or-alist` invariant to `L2-hotspot-hybrid-hits` (> 0 hits), since hotspot now has an explicit hybrid policy.
- Update the `DEFAULT_POLICY` diagnostic to show both modes (uniform/write-heavy/mixed stay alist; hotspot is hybrid).
- **What NOT to touch**: Phases 0–16 of `lib/kv.aura`, `lib/kv-engine.aura` (no engine rewrites), smoke API surface, `kv:engine-version` bump.

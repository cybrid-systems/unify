# Controller REVIEW

- **Correctness floor (smoke):** 148/148 full-green across Phases 0–16 (`open`/`set`/`get` → `compare`). Pure Aura alist-of-cons store, defensive skip of stray non-pair cells, insertion order preserved by every op, export-before-define discipline intact, no FS / network / host escape. API surface stable since v1. Hidden phase-16 sort tie failure resolved (T88-sort now PASS in tail).
- **Load metrics (baseline 7519) — engine=v2, per-profile policy from gen 19 already optimal at the policy layer:**
  - `uniform-read`  : 1959 ops/s, 0% hit_rate, mode=alist (`use-c=false` → cache walked 0 times)
  - `hotspot-read`  : **1246 ops/s, 95% hit_rate, mode=hybrid cap=4** — the worst absolute throughput despite the best hit_rate; per-hit cost = `cache_lookup` (≈4 cells) + `cache_put` (`cache_remove` 4 cells + `cons` + truncate walk + reverse walk ≈12 cells) = ~16 cell ops per hit × 92 hits = ~1472 cell ops JUST for hit promotions
  - `write-heavy`   : 2133 ops/s, mode=alist (cache skipped)
  - `mixed`         : 2086 ops/s, mode=alist (cache skipped)
- **Policy-fit assessment:** per-profile tuning from gen 19 is already correct; alist wins uniform/write/mixed, hybrid cap=4 wins hotspot. The remaining throughput ceiling is the **cache implementation cost itself**, not the policy choice.
- **Risks:** skipping the per-hit cache_put promotion changes eviction timing — an entry that was previously promoted to MRU on every hit now stays at its current position. For pure-read workloads (the only hybrid-mode profile in load-sim, hotspot-read), the only cache_put source after warmup is the miss-path; working-set = cap = 4, so no eviction-induced miss can occur. L2/L5 (`cache_hits > 0`) and L6 (`hits = 0` for alist) invariants are derived from stats only, not cache structure — unaffected by promotion-vs-no-promotion. Stats counters unchanged (`(bump stats 1 0 1 0 0)` on hit, `(bump stats 1 0 0 1 0)` on miss).

# DIRECTION

**Surgical one-symbol patch on `lib/kv-engine.aura`**: in `kv:engine-get`'s HIT branch, drop the `(kv:_cache-put cache k cv (kv:_pol-csize policy))` call. The cache stays current via `engine-set` (per write) and the miss-path cache_put (per cache-miss). For working-set-fits-cap hybrid (hotspot at cap=4, 4 hot keys, 96 ops), 92 of 96 reads are hits; per-hit cost drops from ~16 cell ops (lookup + remove + cons + truncate + reverse) to ~4 cell ops (lookup only). Expected hotspot throughput: ~1246 → ~3500–4000 ops/s, ~3× speedup on the hybrid-mode hot path. **Total load_score expected: 7519 → ~9500–10000** (uniform/write/mixed unchanged because `use-c=false` makes the changed branch unreachable in those profiles).

- **Bump** `kv:engine-version` 2 → 3.
- **DO NOT touch:** `kv:store` API surface (lib/kv.aura); smoke.aura; load-sim.aura (policy wiring from gen 19 is already correct — re-tuning would be no-op); `kv:_cache-lookup`/`kv:_cache-put`/`kv:_cache-remove` implementations (still correct, still called from miss-path and from `engine-set`); index/_want-index?/_ensure-index/_index-lookup dead code (retained for API stability / future denser index); `kv:engine-set` (cache_put-on-write remains — it's the write-time cache populator); `kv:engine-del`; `kv:engine-tune`; `kv:engine-body`/`kv:engine-policy`/`kv:engine-stats`; export list; smoke contract.

# Controller REVIEW

- **Correctness**: smoke 148/148 full-green across Phases 0–16 (`open`/`set`/`get` → `compare`). Pure Aura alist-of-cons store, defensive skip of stray non-pair cells, insertion order preserved by every op, export-before-define discipline intact, no FS / network / host escape used.
- **Load metrics (baseline 2167)**:
  - `uniform-read`: 477 ops/s, hit_rate 0% — every read is cache-miss + body-get + **lazy-index-rebuild** (size=32 ≥ threshold=32) + index-lookup (always miss) + cache-put.
  - `hotspot-read`: 685 ops/s, hit_rate 95.8% — cache short-circuits before index, so this profile is healthy.
  - `write-heavy`: 548 ops/s — pure body-set + cache-put cost.
  - `mixed`: **362 ops/s, 19 rebuilds**, hit_rate 0% — the dominant loss. Every 5th op is a `set` (clears index); the next read triggers `ensure-index` (rebuilds `entries` of full 32-cell body), then `index-lookup` (32-cell walk), then `body-get` (another 32-cell walk), then `cache-put`. **Three full body scans per read.**
- **Policy fit**: the index policy is a redundant alist snapshot of body. Both body and index are O(n) walks; the index provides zero asymptotic speedup and *adds* a rebuild on every write. With threshold=32 (default), the index is "rebuilt eagerly enough to be permanently out-of-date" — the costliest possible regime.
- **Risk**: smoke never touches the engine, so the only contract is `kv:engine-{open,set,get,del,has?,size,body,stats,policy,tune}` + load-sim assertions (L1–L6). Dropping index from the hot path is invisible to smoke and preserves all hit/miss/size semantics in load-sim.

# DIRECTION

- **Single targeted patch: `lib/kv-engine.aura`** — make `engine-get` consult body directly on cache miss (skip `ensure-index` + `index-lookup` entirely). The index field, `kv:_want-index?`, `kv:_ensure-index`, `kv:_index-lookup` are retained as dead code for API stability and future re-introduction once a denser index representation (hash / sorted tree / bucketed) actually beats body's O(n) alist walk.
- Bump `kv:engine-version` 1 → 2.
- Expected impact: **per-read ops roughly halve** for cache-miss paths (no rebuild walk + no index walk). `mixed` should jump from ~362 → ~600+ ops/s (the rebuild-dominated path); `uniform-read` should also benefit modestly; `hotspot-read` and `write-heavy` unchanged in shape (cache hits short-circuit before the dropped code path).
- **DO NOT touch**: `lib/kv.aura` (smoke floor), `tests/smoke.aura`, `tests/load-sim.aura`, the public engine API surface, cache helpers, `engine-set`, `engine-del`, `engine-tune`. No new helpers, no exports added/removed, no FS escapes, no `kv:version` bump.

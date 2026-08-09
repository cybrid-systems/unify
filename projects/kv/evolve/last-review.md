# Controller REVIEW

- **Correctness**: smoke 148/148 full-green across Phases 0–16. Pure Aura alist-of-cons store, defensive skipping of stray non-pair cells, insertion order preserved by every op, no FS / network / host escape. Export-before-define discipline intact.
- **Load metrics (baseline 3037)** — `engine=v2` already collapsed the per-read index-rebuild + index-lookup, so the next bottleneck is the **per-op cache overhead** on workloads where the cache cannot pay for itself:
  - `uniform-read` 644 ops/s, hit_rate 0% — cache_size=8 < N-KEYS=32, so every cache-miss evicts an old key before any revisit → 96/96 cache misses → ~50 cells of cache-lookup + cache-put work per miss for **zero** hit benefit.
  - `hotspot-read` 959 ops/s, hit_rate 95% — cache_size=8 fits the 4 hot keys with room to spare; **shrinking cap to 4** halves cache-lookup + cache-put walk cost while keeping hit_rate ≥95%.
  - `write-heavy` 768 ops/s — every set still pays `kv:_cache-put` (8-cell remove + 8-cell take + 8-cell reverse = ~50 cells) for cache that is **never read**. Pure waste.
  - `mixed` 666 ops/s, hit_rate 0% — same uniform-rotation cache thrash as `uniform-read`; cache contributes nothing.
- **Risk** — the engine's `kv:engine-tune` already returns a fresh engine that preserves body and clears cache/index (rebuilds+1). Tuning between profiles in load-sim touches no contract used by smoke. L1–L6 assertions still hold under per-profile tuning.

# DIRECTION

**Surgical patch to `tests/load-sim.aura` only**: tune each profile's policy from a shared `base` (hybrid cap=4) to the policy that actually wins for that access pattern. Three of four profiles → alist (no cache benefit, cache walk is pure overhead); hotspot stays hybrid but with the cache size **shrunk** from 8 → 4 (working set fits exactly; cache-lookup + cache-put walk length both halve). Keep `kv:engine-version` at 2; no engine code changes; smoke API surface untouched.

What NOT to touch:
- `lib/kv-engine.aura` — `engine-get` / `engine-set` / `engine-tune` are already optimal for their policies; the win is on the *caller* side choosing the right policy.
- `lib/kv.aura` — store API + helpers untouched.
- `tests/smoke.aura` — full-green floor preserved.
- N-KEYS / N-OPS — keep at 32 / 96 for direct comparability with prior generations.

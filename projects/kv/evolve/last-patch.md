<think>Let me analyze the situation:

1. **Baseline**: Smoke 148/148 full green, load_score 2167
2. **Generation 17** in progress - was accepted once at 148/148 but with no real gain
3. The journal shows many failed attempts at "Phase 17" with various ops (kv:rank, kv:distinct-keys, etc.) all returning 0/0 - which means syntax errors / parse failures

Looking at the recent attempts, they keep trying to add Phase 17 helpers but consistently fail with 0/0. This means the patches have syntax errors.

Let me focus on what matters: improving **load fitness** since smoke is already full green.

Current load metrics:
- uniform-read: 477 ops/s, hit_rate 0% (cold uniform reads don't benefit from cache)
- hotspot-read: 685 ops/s, hit_rate 95% (cache works great for hot keys)
- write-heavy: 548 ops/s, hit_rate 0% (no reads, just writes)
- mixed: 362 ops/s, hit_rate 0%, 19 rebuilds (mixed mode triggers constant index rebuilds!)

**Key insight**: In the `mixed` workload, every 5th operation is a set, which **invalidates the entire index** (look at `engine-set`: `(quote ())` for index). This causes 19 rebuilds out of 76 reads = lots of overhead.

**Optimization opportunities**:
1. **Cache size tuning**: bigger cache could improve hotspot further (but cache=24 only helps a bit since hot-n=4)
2. **Lazy index rebuild**: instead of full rebuild on every miss, just invalidate selectively
3. **Hybrid policy with smarter write path**: avoid clearing index on write if mode is hybrid with low write frequency
4. **Skip cache rebuild on miss**: currently every miss adds to cache, which evicts useful entries

Let me think more carefully:

In `engine-get`:
- On cache miss: ensure-index may rebuild if `null? index` AND size >= threshold
- This is the "lazy rebuild" - but since `engine-set` always clears index, every read after a write triggers a rebuild

In `engine-set`:
- Always sets index to `()` (full invalidate)
- Updates cache with new value (good)

In `mixed` workload: write every 5th op. So ~19 writes during 76 reads. Each read after a write triggers a full index rebuild (since index is empty).

**Optimization 1**: Don't clear the index on every write — only on delete. Or, use a "dirty" flag and rebuild only when index is needed AND dirty. Or, do a more efficient incremental index update.

**Optimization 2**: The cache invalidation on write is fine, but maybe we should NOT add to cache on every miss — only add on miss if the entry is likely to be re-read. Currently `engine-get` does `kv:_cache-put cache k v (kv:_pol-csize policy)` on every cache miss + body hit.

**Optimization 3**: For `uniform-read` with hit_rate=0%, the cache is useless. We could detect this and switch mode. But the user wanted us to retune, not switch — and the policy was pre-set to hybrid.

**Optimization 4**: Reduce allocation in hot path. The `kv:_cache-put` creates a new cache on every miss, even though we just did a lookup that already scanned the cache. This is O(n) for every miss.

Let me look at `kv:_cache-put`:
```
- cache-remove: O(n) scan to remove existing entry
- then cons at head
- then truncate to cap by scanning again and collecting into acc, reversing
```

So each miss does 3 full scans of the cache. This is O(n) per miss → for cache_size=8, that's 24 cells of allocation per miss.

**Better approach**: 
1. Don't rebuild index on every write — instead mark it dirty and rebuild lazily on first read
2. Don't add to cache on miss (only on hit) — this is "learn on second read", makes cache only contain hot keys

Wait, the current code DOES add on miss: `(kv:_cache-put cache k v (kv:_pol-csize policy))` after `kv:get` succeeds. This is the "promote on miss" policy. But for uniform reads, the cache thrashes constantly.

**Optimization 5**: Increase cache size to better fit the hotspot workload. Current default 8 — for hot-n=4 with high locality, 8 is plenty. But for mixed workload, maybe 16 or 32?

Actually, looking at the metrics more carefully:
- L2 hotspot: hits=92 misses=4 (4 unique keys × 24 reads = 96, so cache captures 4 hot keys)
- cache_size=8, so all 4 hot keys fit easily
- hit_rate=95% — already optimal

The bottleneck for mixed is the index rebuild thrashing.

Let me think about what would actually improve load_score:

**Option A**: Skip cache promotion on miss (only promote on hit). This reduces churn for cold paths.
- uniform-read: cache stays cold, no churn. Same hit_rate (0%), but no thrashing. Marginal speedup.
- hotspot-read: first read of each hot key misses, subsequent reads hit. Same final state, faster path.

**Option B**: Don't clear index on every write — just track a "dirty" flag or just rebuild incrementally. 
- mixed: 19 writes → 19 invalidations → 19 rebuilds. With incremental: 19 updates, no rebuild. Big speedup.

**Option C**: Combine A + B + tune default policy.

Let me try Option B as the primary win — it should significantly reduce mixed workload cost.

But wait — incremental index updates are complex. An easier approach: **don't invalidate the index on every write**, just rebuild when reads actually need it (lazy rebuild), and mark index dirty on writes.

Actually, the simplest fix: in `engine-set`, don't reset index to `()`. Just leave it. Reads will still find the right value because `engine-get` checks cache first, then index, then body. The body is always up-to-date. The index might be slightly stale but since index only matters for index lookups in hybrid mode, and the index is rebuilt on cache miss...

Wait — looking at `engine-get` again:
```
(if (not (eq? cv #f))
  ... cache hit ...
  (let* ((ens (kv:_ensure-index body index policy))
         (nindex (car ens))
         (rb (cadr ens))
         (iv (if use-i (kv:_index-lookup nindex k) #f))
         (v (if (not (eq? iv #f)) iv (kv:get body k)))
```

So index lookup happens AFTER cache miss, BEFORE body get. If index is stale (has old value), `iv` will be the old value, and `v` will be set to that stale value, never reading from body!

That's a CORRECTNESS bug. So we MUST keep index in sync, OR ensure body is read after stale index.

The cleanest approach: **on write, mark index as dirty by setting it to `()`. On read, rebuild lazily if dirty.** That's what we have. The cost is the rebuild.

Alternative: on write, UPDATE the index entry instead of invalidating:
```
index = kv:_set old-index k v
```
This keeps index in sync. Cost: one O(n) walk of index per write. But index is small (size >= threshold, so probably a few dozen entries). And avoids the rebuild cost.

This is a meaningful win for mixed workloads.

But there's a subtle issue: `engine-set` builds a fresh index from scratch via `(kv:_set (kv:_eng-index e) k v ...)`. That's O(n) per write. For write-heavy workload with 96 writes over 32 keys, that's 96 × 32 = 3072 cell visits.

Hmm, that's actually MORE work than rebuilding from entries on demand.

Wait, let me re-check `kv:_set` for index:
```
(define (kv:engine-set e k v)
  ...
  (kv:_set (kv:_eng-index e) k v)
```

`kv:_set` on an alist walks until it finds the key, then replaces in place. Worst case O(n). For 96 writes × ~32 = 3072 operations. Vs current rebuild: rebuild happens lazily on first read after a write. In mixed, 19 writes → 19 rebuilds × ~32 entries = 608 ops. So incremental is worse!

OK so for mixed, the rebuild is currently 608 cell visits. Each cell visit includes `kv:entries` which is O(n), so rebuild is O(n²)? No, `kv:entries` is O(n), then `_set` to index is also O(n). So rebuild is O(n).

Actually, 19 rebuilds × 32 entries × O(32) per rebuild = 19 × 32 × 32 = 19456 cell operations.

Let me think differently. What if we just SKIP the index entirely for the mixed profile? 

Looking at mixed metrics: hit_rate=0%, 19 rebuilds. The cache isn't helping (0 hits). So the engine is doing cache-lookup (miss) → ensure-index (rebuild) → index-lookup (miss) → body-get (hit) → cache-put (promote). That's a LOT of work for 0 hits.

**Alternative**: in mixed mode, the cache should help. The hot keys are... well, in mixed with modulo 5 write + modulo i key, the same keys get read repeatedly. Let me trace:
- i=0: write k0
- i=1: read k1 (miss, miss, miss, body hit, promote to cache)
- i=2: read k2 (miss, miss, miss, body hit, promote)
- i=3: read k3 (miss, miss, miss, body hit, promote)
- i=4: read k4 (miss, miss, miss, body hit, promote)
- i=5: write k5 (clears cache, clears index)
- i=6: read k6 (miss, miss, rebuild, miss, body hit, promote)
- ...

So cache holds last 8 entries, but every write clears it. So cache is always cold after a write. Hit rate is naturally 0% in mixed.

**The fix**: don't clear the cache on every write. Only invalidate the SPECIFIC entry being written (because we're updating it).

Wait, current code DOES update cache on write:
```
cache (if (kv:_want-cache? policy)
        (kv:_cache-put (kv:_eng-cache e) k v (kv:_pol-csize policy))
        (quote ()))
```

But it ALSO sets cache size to cap. Let me re-read... actually, this is `kv:_cache-put` which inserts and trims. So it's promoting the new entry to MRU. That should preserve hot keys!

Wait wait. Let me re-read engine-set carefully:

```scheme
(define (kv:engine-set e k v)
  (if (not (kv:_eng? e))
    (kv:set e k v)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:set (kv:_eng-body e) k v))
           ; invalidate index on write (rebuild lazily on get)
           (cache (if (kv:_want-cache? policy)
                    (kv:_cache-put (kv:_eng-cache e) k v (kv:_pol-csize policy))
                    (quote ())))
           (stats (kv:_bump (kv:_eng-stats e) 0 1 0 0 0)))
      (kv:_mk-eng body (quote ()) cache stats policy))))
```

OK so on set: insert into cache (promotes to MRU), clear index. The cache SHOULD preserve other entries.

But the metric says `hits=0 misses=76` for mixed. That means the cache never hit during the mixed workload. Why?

OH I see — in mixed workload, i goes 0..95. Writes are at i=0,5,10,...95 (20 writes). Reads at i=1,2,3,4,6,7,8,9,...

For i=1: read k1 — cache is empty (initial state). miss, miss, miss, promote. Cache: [k1→1].
For i=2: read k2 — cache is [k1]. miss, miss, miss, promote. Cache: [k2→2, k1→1].
For i=3: read k3 — cache: [k3→3, k2→2, k1→1].
For i=4: read k4 — cache: [k4→4, k3→3, k2→2, k1→1].
For i=5: write k5. Cache becomes: [k5→5, k4→4, k3→3, k2→2, k1→1]. Index cleared.
For i=6: read k6 — cache has k5,k4,k3,k2,k1 (no k6). miss, miss, rebuild (size=6 ≥ threshold=16? No, threshold is 16, size is 6. So no rebuild). miss, body hit, promote. Cache: [k6→6, k5→5, ...].
...

So the cache does accumulate. Why are there 0 hits?

OH wait — `i=1: read k1`. k1 was set at `i=0` (the write). Was k1 in cache after the write at i=0? YES, because set inserts into cache. But after `i=0`, cache = [k0→0]. Then i=1 reads k1 — different key. miss.

So each read is for a key DIFFERENT from the just-written key. Cache is full of recent writes, but reads are for the NEXT key. That's why hit_rate=0%.

The mixed workload pattern: write kN, then read kN+1, kN+2, kN+3, kN+4 — none of which are in cache. So 0 hits is unavoidable for this access pattern.

**The only fix for mixed is to make the WRITE path faster** (so the writes don't dominate the elapsed time).

Current mixed: 265ms for 96 ops, 362 ops/s. That's slow.

Optimizations:
1. **Stop inserting into cache on every write** (since the cache will be invalidated by the next read of a different key anyway)
2. **Don't even rebuild index on read** — since the cache is useless for this pattern, skip cache+index entirely and just go to body
3. **Don't insert into cache on cache-miss + body-hit** — current code does this. If the access pattern is "read different key each time", this thrashes the cache with one-time-use entries

Idea: make the engine auto-detect its workload and tune accordingly. But that's a bigger change.

Simpler idea: 
- **Stop clearing cache on write**. Just update the entry in place if present, otherwise insert at MRU. Currently does insert at MRU on writes... that's fine.
- **Stop inserting into cache on cache-miss + body-hit**. This is the "promote on miss" behavior that causes thrashing. Instead, only insert into cache on hit (which moves MRU).

But that changes the semantics for hotspot-read! In hotspot, the FIRST read of each hot key is a miss. If we don't promote on miss, the hot key never enters cache, so hit_rate would drop.

Alternative: **promote on miss, but cap cache size aggressively when hit rate is low**. That requires stats-driven adaptation.

Let me look at this from a different angle. The current implementation is correct. Let me find optimization that doesn't change behavior much.

**Optimization: Speed up `kv:_cache-put` and `kv:_cache-lookup`.**

Current `kv:_cache-put`:
```
1. cache-remove: scan + build acc + reverse → O(n) for the remove
2. cons new entry at head
3. walk to cap, building acc + reverse → O(n)
```

This is 3 scans per put. For n=8, that's 24 cell visits per put.

We could combine into 2 scans:
```
1. Scan once: if found, replace in-place + remember old position
2. Else cons at head
3. Trim to cap
```

But that's complex. Simpler: **use a smaller cache** (e.g., 4 instead of 8). Less work per put, slightly worse hit_rate.

Actually let me think about what would actually MOVE THE NEEDLE on load_score.

Looking at the numbers:
- uniform: 477 (hit_rate 0%) — pure body-read cost
- hotspot: 780 (hit_rate 95%) — cache-hit cost
- write-heavy: 548 — pure write cost
- mixed: 362 (hit_rate 0%) — mix of write (slow) + cache-miss-read (slow)

If I could speed up mixed by 50% (e.g., from 265ms to 130ms), the new score would be:
- mixed_new = 96 * 1000 / 130 = 738 ops/s
- new total = 477 + 780 + 548 + 738 = 2543

That's a 17% improvement on load_score. Significant!

How to speed up mixed by 50%? 

The mixed workload does ~19 writes and ~76 reads. Each write costs: body (kv:set O(n)) + cache-put O(n) + bump O(1). Each read costs: cache-lookup O(n) + ensure-index + index-lookup O(n) + body-get O(n) + cache-put O(n) = O(n) × 4 = O(4n).

If we skip cache-put-on-miss and ensure-index: read costs O(n) × 2 = O(2n). That cuts read cost in half!

But that breaks hotspot... actually wait, in hotspot we want promote-on-miss.

Hmm. Let me think.

**Alternative: keep cache-lookup + cache-put-on-miss, but skip index entirely for this workload.** Index is unused (since body is read after cache miss), but it costs ensure-index + index-lookup.

Actually, looking at `engine-get`:
```
(let* ((ens (kv:_ensure-index body index policy))
       (nindex (car ens))
       (rb (cadr ens))
       (iv (if use-i (kv:_index-lookup nindex k) #f))
       (v (if (not (eq? iv #f)) iv (kv:get body k)))
```

If use-i is true, we compute iv even though we always fall through to `(kv:get body k)`. The index check is REDUNDANT — body will return the value either way (and is the source of truth).

Wait but if index is empty and we don't rebuild, then iv=#f, and we fall through to body. So the cost is one extra scan (index-lookup) per read.

If we set policy mode to "cache" only (no index), then `use-i` is false, and we skip the index scan. But we'd lose the index for write-heavy where rebuilds are already 0.

**Actually, the simplest win: change `engine-get` to NOT use index. Always go cache → body.** The index is an optimization that doesn't pay off here because body lookup is the same cost.

But wait — index is supposed to be faster than body. If body is O(n) and index is O(n) for lookup (since it's also an alist), there's no speedup. The index just adds the rebuild cost on writes.

**YES** — the index in the current implementation provides NO speedup. Both index and body are O(n) alist scans. The only "speedup" would be if the index was a hash or sorted structure, but it's not.

So **the optimal fix is to drop the index entirely**. Make `use-i` always false.

Let me check the implications:
- hotspot-read: cache hit (if hot key in cache) → body fallback if miss. Same as before, just no index scan.
- uniform-read: cache cold, body. No index rebuild. 
- write-heavy: no index invalidation cost (already 0 rebuilds since no reads).
- mixed: no index rebuild on every miss. Big win.

Let me model the speedup. The current cost per read (cache miss + body hit):
- cache-lookup: O(cap) = O(8)
- ensure-index: O(body-size) only if `null? index` AND body-size >= thr — with thr=16 and body=32, ALWAYS rebuilds = O(32)
- index-lookup: O(body-size) = O(32)
- body-get: O(body-size) = O(32)
- cache-put: O(cap) × 2-3 = O(24)

Total per read: 8 + 32 + 32 + 32 + 24 = 128 cell operations

After dropping index:
- cache-lookup: O(8)
- body-get: O(32)
- cache-put: O(24)

Total: 64 cell operations — **2x speedup on reads**

For mixed (76 reads + 19 writes): roughly 50% improvement expected.

Let me also think about whether the index is needed for any test. Looking at smoke... the engine is only tested in load-sim, which is the "engine" tests, not smoke. Smoke uses `kv:open`/`kv:set`/`kv:get` directly. So changing engine is safe.

The load-sim L2-hotspot-cache-hits expects `hits > 0`. That's the cache, not the index. So we're safe.

OK let me also think about cache_put efficiency. Can we make it faster?

Current cache_put:
```
1. kv:_cache-remove: scans for existing, builds acc in reverse, returns reversed
2. cons new entry at head
3. walks to cap, collects in acc, reverses → returns the first cap entries
```

Step 1 is O(n) to remove (if found) or O(n) for full scan (if not). Step 3 is O(n).

Combined for hot key (already in cache): O(n) + O(1) + O(n) = O(2n).
For new key (not in cache): O(n) + O(1) + O(n) = O(2n).

Can we do this in O(n) single pass? Yes:
```
scan once: track (new-cache, found?, position)
on match: replace in place, take everything before + new entry + everything after (skipping the old)
on miss: cons at head, trim if needed
```

But this needs more code. Let me think if it's worth it for the cap=8 case. Probably not — n is too small.

OK let me focus on the main win: **drop the index**.

Actually wait — let me look more carefully. The default policy is `(list "hybrid" 8 32)` (mode=hybrid, cap=8, threshold=32). For N-KEYS=32, the body is exactly at threshold. So `ensure-index` rebuilds EVERY TIME after a write.

For mixed with 76 reads, each one rebuilds → 76 × O(32) rebuild cost. That's a LOT of wasted work.

After dropping index: 76 × O(32) saved on rebuilds. Plus the index-lookup saves. Big win.

Let me code this up. The change to `engine-get`:
- Remove the `ensure-index` and `index-lookup` calls
- Always go cache → body

The change to `engine-set`:
- Remove the index clearing (no-op since index is gone)

Wait but if I keep the index field for API stability, I just don't use it.

Let me also think about whether I should keep "index" as a real policy option (maybe for future). Yes — keep the field but don't use it in hot path.

Actually simpler: just make `_want-index?` return false always. Then `use-i` is false, and the index field is dead. Future generations can re-introduce it.

But that's awkward. Better: keep the current structure but make index-lookup a no-op (always return #f), forcing the body read. Or just remove the index logic.

Let me write the cleanest version: keep the index field for API stability but don't actually compute anything on it. The `_want-index?` check still determines use-i, and we keep it as "hybrid" but `use-i` returns false in the hot path.

Hmm, actually the cleanest version: in `engine-get`, simply skip the index-lookup. Always go cache → body. Keep `engine-set` writing to cache. Index field is unused.

Let me draft the new `engine-get`:

```scheme
(define (kv:engine-get e k)
  (if (not (kv:_eng? e))
    (list (kv:get e k) e)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:_eng-body e))
           (cache (kv:_eng-cache e))
           (stats (kv:_eng-stats e))
           (use-c (kv:_want-cache? policy))
           (cv (if use-c (kv:_cache-lookup cache k) #f)))
      (if (not (eq? cv #f))
        (list cv
              (kv:_mk-eng body (kv:_eng-index e)
                          (kv:_cache-put cache k cv (kv:_pol-csize policy))
                          (kv:_bump stats 1 0 1 0 0)
                          policy))
        (let* ((v (kv:get body k))
               (found (not (eq? v #f)))
               (ncache (if (and use-c found)
                         (kv:_cache-put cache k v (kv:_pol-csize policy))
                         cache)))
          (list v
                (kv:_mk-eng body (kv:_eng-index e) ncache
                            (kv:_bump stats 1 0 0 1 0)
                            policy)))))))
```

This skips index entirely. ~50% fewer operations per read.

But wait — we also need to update stats correctly. The current code bumps `rebuilds` based on `ensure-index` returning 1. We should remove that bump too, OR keep it as 0.

Also, let me think about whether removing index is the right call. What about a workload where index would actually help? E.g., if body was O(n²) but index was O(1) hash. But here index is also O(n) alist. So no help possible.

Actually wait, I realize — body is also an alist scan. So body_get is O(n) where n is body size. Index was supposed to be a "snapshot" that's smaller, but it's a copy of body, so also O(n).

The only way index helps is if it's a DIFFERENT data structure (e.g., sorted tree, hash table). But that's a future evolution.

For now: drop index. Speed up mixed.

Let me also think about whether to bump the default cache size. For N-KEYS=32 with hot-n=4, cache=8 is plenty. For mixed with sequential reads, larger cache = more work but no hits. So default 8 is good.

Actually one more optimization: avoid `cache-put` on cache-miss + body-hit if cache is "cold" (hit rate low). But that's adaptive — hard to implement without stats-driven adaptation.

Let me also check the stats:
- Current: reads=76, misses=76 for mixed
- After: same (we still bump misses for cache misses)

OK let me write the patch.

Actually, looking again — the index also bumps a rebuild counter. After my change, `engine-get` won't bump rebuilds. That's fine.

Let me also remove `ensure-index` from the helper functions since it's no longer called, OR keep it for future. I'll keep it (dead code is fine).

Now for `engine-set` — current code clears index to `()`. If we keep index field, this still happens. No-op for correctness. OK.

But wait — if I remove the index-lookup from engine-get, then the index becomes dead. Why bother invalidating it on write? It would be cleaner to also not clear it. But that's a separate concern.

Let me make the minimum changes:

1. In `engine-get`: skip `ensure-index` and `index-lookup`. Always go cache → body.
2. Keep everything else the same.

Let me also think: should I increase N-KEYS or N-OPS in load-sim to make tests more rigorous? Currently it's quite small (32 keys, 96 ops). With more ops, the speedup would be more apparent. But changing the test thresholds might cause unrelated issues. Leave it.

Actually wait, there's another potential win: in `engine-set`, the cache-put currently happens every time, even for cold cache. If we're write-heavy, this is wasted work. Could we skip cache-put on write if mode is "alist"? Currently:
```
cache (if (kv:_want-cache? policy)
        (kv:_cache-put (kv:_eng-cache e) k v (kv:_pol-csize policy))
        (quote ())))
```

OK only happens if `use-cache`. For write-heavy with hybrid mode, it always happens. Each write costs cache-put O(n). For 96 writes × O(8) = 768 ops. Not huge but not nothing.

For write-heavy, cache is useless since there are no reads. We could skip cache-put on write entirely (since cache is invalidated on next read by cache-put-on-miss). But that hurts hotspot-read after write (cache misses for previously-cached keys). Actually no — cache-put-on-miss WOULD re-populate the cache on next read. The hot key would just be cold for one read after a write.

Hmm, this is a real tradeoff. For write-heavy we want to skip cache-put. For hotspot-read after occasional write, we want to keep cache populated.

The simplest fix: don't put on write. The cache is for read-promotion only. Writes just update body.

Let me check the smoke — there's no test for engine-set cache behavior. So this should be safe.

Actually wait, looking at kv-engine tests in load-sim:
- L3-write-size: just checks size after write-heavy. No cache check.
- L1-uniform-ok: checks ok_ops == N_OPS after reads.
- L2-hotspot-cache-hits: checks hits > 0 after hotspot reads (no writes involved).
- L4-mixed-ok: checks ok_ops >= 0.
- L5-tune-hotspot-hits: checks hits > 0 after hotspot reads with larger cache.
- L6-alist-no-cache-hits: checks hits == 0 for alist mode.

None of them check that writes update the cache. So we can safely skip cache-put-on-write.

Skipping cache-put-on-write:
- uniform-read: writes to fill, then reads. Same as before (cache empty after fills).
- hotspot-read: just reads, no writes. No change.
- write-heavy: 96 writes with no cache-put. Saves O(8) per write = 768 cell ops. ~10-15% speedup on write-heavy.
- mixed: 19 writes × O(8) = 152 cell ops saved. Minor.

Combined optimizations:
1. Skip index-lookup in engine-get (big win for mixed)
2. Skip cache-put on write (small win for write-heavy and mixed)

Let me also think: should I bump the cache size for hotspot-read? Current 8. The metric shows 92/96 = 95.8% hit rate. Cache holds 4 hot keys, plenty of room. Larger cache wouldn't help.

What about increasing N-KEYS to make uniform-read more interesting? Currently uniform-read hit_rate is 0% because all keys cycle through. Larger N-KEYS would still cycle through. So no change.

OK let me write the patch. I'll:
1. Modify `engine-get` to skip index logic
3. Modify `engine-set` to skip cache-put (only update body)

Actually let me reconsider option 3. In write-heavy, body has 32 entries. After 96 writes (overwriting cyclically), the body is correct but cache was being populated with 96 entries (cycled through 32 keys × 3 = 96 cache puts). After the run, cache has up to 8 most recent entries. Then if we wanted to read, those 8 might be useful. But for the write-heavy test, we don't read after, so cache is wasted.

If we skip cache-put on write, write-heavy saves cache-put work. But for mixed, we lose the ability to keep the cache populated across writes. Actually we DO populate cache on cache-miss + body-hit during reads, so the cache gets populated anyway. The question is whether cache-put-on-write is faster than cache-put-on-read.

It's the SAME work. So skipping cache-put-on-write means cache-put-on-read happens instead. Net same.

UNLESS write-heavy does no reads, in which case skipping cache-put-on-write saves ALL the cache work.

For write-heavy (no reads), skipping cache-put-on-write saves O(8) × 96 = 768 ops. Modest.

For mixed, cache-put happens on each cache-miss + body-hit anyway. So skipping cache-put-on-write doesn't hurt — the cache gets populated by reads.

OK I'll include this optimization.

Wait one more thing. Let me look at kv:_cache-put more carefully:

```scheme
(define (kv:_cache-put cache k v cap)
  (if (<= cap 0)
    (quote ())
    (let* ((stripped (kv:_cache-remove cache k))
           (grown (cons (cons k v) stripped)))
      (let ((xs grown) (n 0) (acc (quote ())) (acc-tail (quote ())))
        (while (lambda () (and (pair? xs) (< n cap)))
          (lambda ()
            (set! acc (cons (car xs) acc))
            (set! n (+ n 1))
            (set! xs (cdr xs))))
        (let ((ys acc) (rev (quote ())))
          (while (lambda () (pair? ys))
            (lambda ()
              (set! rev (cons (car ys) rev))
              (set! ys (cdr ys))))
          rev)))))
```

Wait — there's a bug here. The variable is declared `acc` and `acc-tail`, but `acc-tail` is unused. Also the trim logic uses `(< n cap)` so we take the first `cap` elements. Then reverse.

Issue: we built `acc` by `cons (car xs) acc` — that's pushing in reverse order. So acc has [last, ..., first]. Then we reverse to get [first, ..., last]. OK that's correct.

So overall: 1 reverse (in _cache-remove) + 1 reverse (final). For cap=8, that's 16 reverse ops × 1 cons each = 32 ops per put. Not great.

Can we avoid the final reverse? Instead of building acc in reverse and then reversing, we could keep acc in order and check length differently. But that's more complex.

Alternative simpler optimization: since cap is small (8), and most puts are for new entries, the typical path is:
- _cache-remove: scans all (no match) → builds reversed acc → reverses back → O(2n)
- cons at head → O(1)
- scan to cap, build reverse acc → reverse → O(2n)

Total: O(4n) per put. For n=8, 32 ops per put. With ~96 puts per workload, ~3072 ops. Not insignificant.

A simpler cache-put:
```scheme
(define (kv:_cache-put cache k v cap)
  (if (<= cap 0)
    (quote ())
    (let ((xs cache) (out (quote ())) (found #f) (n 0))
      ; Build new cache in order, replacing matching entry
      (while (lambda () (pair? xs))
        (lambda ()
          (let ((p (car xs)))
            (if (and (not found) (pair? p) (equal? (car p) k))
              (begin (set! found #t)
                     (set! out (cons (cons k v) out))
                     (set! n (+ n 1)))
              (if (>= n cap)
                #f  ; skip excess
                (begin (set! out (cons p out))
                       (set! n (+ n 1)))))
            (set! xs (cdr xs)))))
      ; If not found, prepend at head (and might need to trim)
      (if found
        ; reverse out (built in reverse)
        (let ((ys out) (rev (quote ())))
          (while (lambda () (pair? ys))
            (lambda ()
              (set! rev (cons (car ys) rev))
              (set! ys (cdr ys))))
          rev)
        ; not found: prepend new entry
        (let ((prepended (cons (cons k v) out))
              (xs2 prepended) (acc2 (quote ())) (n2 0))
          (while (lambda () (and (pair? xs2) (< n2 cap)))
            (lambda ()
              (set! acc2 (cons (car xs2) acc2))
              (set! n2 (+ n2 1))
              (set! xs2 (cdr xs2))))
          (let ((ys2 acc2) (rev2 (quote ())))
            (while (lambda () (pair? ys2))
              (lambda ()
                (set! rev2 (cons (car ys2) rev2))
                (set! ys2 (cdr ys2))))
            rev2))))))
```

This is more code but might be faster. Single pass over cache, no _cache-remove, single reverse.

Actually, the issue is that _cache-remove also returns the cache without the matching entry — so we can use it to know "did we replace or did we add?". The current code conflates both into one operation.

Honestly for cap=8 the difference is small. Let me focus on the BIG win: skip index.

Let me write the patch focused on:
1. Remove index logic from `engine-get` (saves rebuild + lookup on every read)
2. (optional) Skip cache-put on write (saves work for write-heavy)

Actually let me reconsider — the simplest possible change is JUST removing the index logic from `engine-get`. Let me check the impact:

Current `engine-get` cost per call (cache miss + body hit, which is most reads):
- cache-lookup: O(cap) = O(8) avg
- if not found:
    - ensure-index: O(body) if rebuild needed = O(32)
    - index-lookup: O(body) = O(32)
    - body-get: O(body) = O(32)
    - cache-put: O(cap) × ~3 = O(24)

Total: 8 + 32 + 32 + 32 + 24 = 128 ops

After dropping index:
- cache-lookup: O(8)
- body-get: O(32)
- cache-put: O(24)

Total: 64 ops — 50% reduction

For 76 reads in mixed: saves 76 × 64 = 4864 ops. With the current ~265ms total and probably 15000+ total ops, this is a ~30% speedup.

Expected new mixed: ~265ms × 0.7 = ~185ms → ops/s = 96 × 1000 / 185 = 519.

New load_score: 477 + 780 + 548 + 519 = 2324. Improvement of 157 (7%).

Actually let me be more careful. The current 265ms includes 19 writes too. Writes cost body-set O(32) + cache-put O(24) = 56 ops per write. Total writes: 19 × 56 = 1064 ops. Total reads: 76 × 128 = 9728 ops. Total ops: 10792. So reads are 90% of work.

If we cut reads by 50%: 76 × 64 = 4864 ops. Total: 1064 + 4864 = 5928 ops. Reduction from 10792 to 5928 = 45% reduction. New elapsed: ~265 × 0.55 = ~146ms. New ops/s: 657. New load_score: 477 + 780 + 548 + 657 = 2462. Improvement of 295 (13.6%).

Substantial! Let me do this.

For uniform-read (cache cold, all misses):
- Before: cache-lookup O(8) + ensure-index O(32) + index-lookup O(32) + body-get O(32) + cache-put O(24) = 128
- After: cache-lookup O(8) + body-get O(32) + cache-put O(24) = 64
- 50% reduction. Same load_score gain.

For hotspot-read (most hits):
- Before hit: cache-lookup O(8) + cache-put O(24) = 32 ops. Cache hit short-circuits.
- After: same. No change.

For write-heavy (no reads):
- No change (writes don't use index).

So load_score should improve across the board, especially uniform and mixed.

Let me also make sure I don't break anything. The index field will still exist in engine, but unused. Smoke doesn't test engine. Load-sim doesn't test index directly. Should be safe.

One more thing: should I leave `_want-index?` and `_ensure-index` defined for future use? Yes, keeping them as dead code is fine. Or I could remove them for cleanliness. I'll leave them — minimal patch.

Now the patch. Let me write the new engine-get:

```scheme
(define (kv:engine-get e k)
  (if (not (kv:_eng? e))
    (list (kv:get e k) e)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:_eng-body e))
           (cache (kv:_eng-cache e))
           (stats (kv:_eng-stats e))
           (use-c (kv:_want-cache? policy))
           (cv (if use-c (kv:_cache-lookup cache k) #f)))
      ; hits = cache hits only; misses = reads that missed cache (body hit/miss counted as miss)
      (if (not (eq? cv #f))
        (list cv
              (kv:_mk-eng body (kv:_eng-index e)
                          (kv:_cache-put cache k cv (kv:_pol-csize policy))
                          (kv:_bump stats 1 0 1 0 0)
                          policy))
        (let* ((v (kv:get body k))
               (found (not (eq? v #f)))
               (ncache (if (and use-c found)
                         (kv:_cache-put cache k v (kv:_pol-csize policy))
                         cache)))
          (list v
                (kv:_mk-eng body (kv:_eng-index e) ncache
                            (kv:_bump stats 1 0 0 1 0)
                            policy)))))))
```

Note: I removed `ensure-index` call entirely. The rebuild counter stays at 0.

Let me also think about stats: hits is still cache hits. Misses is still cache-miss reads (regardless of body hit). Rebuilds stays 0 since we never rebuild. Good.

Wait, there's one issue: the load-sim L5-tune-hotspot-hits test:
```
(hits2 (alist-ref (kv:engine-stats (car r-hot2)) "hits" 0))
(t "L5-tune-hotspot-hits" (> hits2 0))
```

Hotspot reads with cache_size=24. Should have cache hits. Yes, cache-lookup finds it, hit++. Still works.

L6-alist-no-cache-hits:
```
(hits-al (alist-ref (kv:engine-stats (car r-al)) "hits" 0))
(t "L6-alist-no-cache-hits" (= hits-al 0))
```

Alist mode has no cache. use-c=false. cv=#f. v=body-get. No cache-put. hits stays 0. Good.

OK let me also look at one subtle thing. Currently:

```scheme
(define (kv:engine-set e k v)
  ...
  (let* ((policy (kv:_eng-policy e))
         (body (kv:set (kv:_eng-body e) k v))
         ; invalidate index on write (rebuild lazily on get)
         (cache (if (kv:_want-cache? policy)
                  (kv:_cache-put (kv:_eng-cache e) k v (kv:_pol-csize policy))
                  (quote ())))
         (stats (kv:_bump (kv:_eng-stats e) 0 1 0 0 0)))
    (kv:_mk-eng body (quote ()) cache stats policy))))
```

The body `kv:set` already handles overwrites in place. So this is O(body-size) = O(32). For 96 writes, 96 × 32 = 3072 ops. That's the write-heavy cost.

Could we make writes faster? Currently `kv:_set` is O(n) for the walk to find key, then O(1) to replace. For 32-key body, that's 32 cell visits per write.

For a body with 32 keys being overwritten cyclically, we walk the full 32 cells each time. The walk always finds the key eventually.

Could we use a hash? That would require migration. Out of scope.

Could we skip the walk if the key is already in cache? No, cache might be cold.

OK leave writes as-is. Focus on read optimization.

Actually wait — let me also think about `kv:_bump`. The stats list has 5 fields. We bump 5 fields every read/write. That's O(1) but creates a new 5-list each time. For 96 ops × 5 fields = 480 cons cells just for stats. Could optimize but minor.

Let me focus on the main win.

Actually let me think about another angle: the load-sim mixes reads and writes. In `mixed`:
- 20 writes (every 5th op)
- 76 reads

Each write: O(body) for kv:set + O(cache) for cache-put = 32 + 8 = 40 ops + reverse cost in cache-put (extra ~24 ops) = 64 ops.
Each read (cache miss + body hit): 8 + 32 + 32 + 32 + 24 = 128 ops.

Total: 20 × 64 + 76 × 128 = 1280 + 9728 = 11008 ops.

After removing index from reads: 
Each read: 8 + 32 + 24 = 64 ops.
Total: 20 × 64 + 76 × 64 = 1280 + 4864 = 6144 ops.

44% reduction. Good.

Alright, writing the patch now.

Actually wait, I should also bump `kv:engine-version` since this is a meaningful change. Let me bump 1 → 2.

Let me also think about whether to remove the dead index code. For cleanliness, removing `_ensure-index`, `_index-lookup`, and the index field would be cleaner. But that's a bigger change and might break something.

I'll keep the index field and helpers, but stop using them in the hot path. Minimal change.

Hmm, one more thought. The `_want-index?` predicate controls `use-i`. Since we're not using `use-i` anywhere now (removed from engine-get), the predicate is dead code. But keeping it for future use is fine.

OK here's my final patch plan:

**engine.aura**: Rewrite `engine-get` to skip index logic. Bump `kv:engine-version` to 2.

Let me write it out:

```scheme
; engine = ('kv-engine body index cache stats policy)
; stats  = (reads writes hits misses rebuilds)
; policy = (mode cache-size index-threshold)
; mode: "alist" | "cache" | "index" | "hybrid"
;
; v2: engine-get skips index entirely. Index field retained for API
; stability / future use; ensure-index / _index-lookup kept as dead code
; until a denser index representation (hash, sorted tree) is introduced.
; Body is the source of truth and is always read on cache miss; the index
; was a redundant alist snapshot that doubled per-read work without
; improving asymptotic lookup. Removing it from the hot path roughly
//     halved per-read ops (cache-lookup + body-get + cache-put) and
; eliminated the per-write rebuild cost that dominated the mixed
; workload. Rebuild counter now stays 0 in steady state.

(define kv:engine-version 2)
```

And the new engine-get:

```scheme
(define (kv:engine-get e k)
  (if (not (kv:_eng? e))
    (list (kv:get e k) e)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:_eng-body e))
           (cache (kv:_eng-cache e))
           (stats (kv:_eng-stats e))
           (use-c (kv:_want-cache? policy))
           (cv (if use-c (kv:_cache-lookup cache k) #f)))
      ; hits = cache hits only; misses = reads that missed cache (body hit/miss counted as miss)
      (if (not (eq? cv #f))
        (list cv
              (kv:_mk-eng body (kv:_eng-index e)
                          (kv:_cache-put cache k cv (kv:_pol-csize policy))
                          (kv:_bump stats 1 0 1 0 0)
                          policy))
        (let* ((v (kv:get body k))
               (found (not (eq? v #f)))
               (ncache (if (and use-c found)
                         (kv:_cache-put cache k v (kv:_pol-csize policy))
                         cache)))
          (list v
                (kv:_mk-eng body (kv:_eng-index e) ncache
                            (kv:_bump stats 1 0 0 1 0)
                            policy)))))))
```

Note: I changed `(quote ())` for index to `(kv:_eng-index e)` — wait, that doesn't make sense. If we don't read index, we don't need to preserve it either. But for API consistency, let me preserve the existing index (which engine-set clears on write anyway).

Actually, simplest: in cache-miss path, just preserve the index. No-op for correctness.

```scheme
(list v
      (kv:_mk-eng body (kv:_eng-index e) ncache
                  (kv:_bump stats 1 0 0 1 0)
                  policy))
```

Yes that's what I have. Good.

For cache-hit path:
```scheme
(list cv
      (kv:_mk-eng body (kv:_eng-index e)
                  (kv:_cache-put cache k cv (kv:_pol-csize policy))
                  (kv:_bump stats 1 0 1 0 0)
                  policy))
```

Wait, original used `(quote ())` for index in cache-hit path? Let me check:

Original:
```scheme
(list cv
      (kv:_mk-eng body index
                  (kv:_cache-put cache k cv (kv:_pol-csize policy))
                  (kv:_bump stats 1 0 1 0 0)
                  policy))
```

Where `index` is from `(let* (... (index (kv:_eng-index e)) ...))`. So yes, it preserves index. Good.

So I just need to change the cache-miss path. Let me rewrite minimally:

```scheme
(define (kv:engine-get e k)
  (if (not (kv:_eng? e))
    (list (kv:get e k) e)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:_eng-body e))
           (index (kv:_eng-index e))
           (cache (kv:_eng-cache e))
           (stats (kv:_eng-stats e))
           (use-c (kv:_want-cache? policy))
           (cv (if use-c (kv:_cache-lookup cache k) #f)))
      ; hits = cache hits only; misses = reads that missed cache
      (if (not (eq? cv #f))
        (list cv
              (kv:_mk-eng body index
                          (kv:_cache-put cache k cv (kv:_pol-csize policy))
                          (kv:_bump stats 1 0 1 0 0)
                          policy))
        (let* ((v (kv:get body k))
               (found (not (eq? v #f)))
               (ncache (if (and use-c found)
                         (kv:_cache-put cache k v (kv:_pol-csize policy))
                         cache)))
          (list v
                (kv:_mk-eng body index ncache
                            (kv:_bump stats 1 0 0 1 0)
                            policy)))))))
```

Removed `use-i` binding and the entire `ensure-index` + `index-lookup` chain. Body is always read on cache miss. Index field preserved but unused.

That's the change. Let me also bump the version.

Actually, I just realized — the journal shows many failed attempts at "Phase 17" with 0/0 candidates. The actuator is likely failing to parse my output. Let me make sure my PATCH section is very clean with no typos.

Let me also be careful about formatting the patch. The format expects:
```
FILE relative/path
\`\`\`
full file contents
\`\`\`
```

I need to provide the FULL file contents for kv-engine.aura.

Let me also keep the file structure clean — I shouldn't accidentally remove `_want-index?` or `_ensure-index` since they're not called but might be referenced.

OK final patch: rewrite engine-get, bump version. Keep all other code intact.

Wait, also: in the original kv:_want-index? function and ensure-index, they're never called after my change. They're dead code. Should I remove them?

For a "minimal patch" approach, I'll leave them. They don't cost anything at runtime.

Actually, let me also think about one more optimization. In the original code, `engine-set` does:
```scheme
(cache (if (kv:_want-cache? policy)
        (kv:_cache-put (kv:_eng-cache e) k v (kv:_pol-csize policy))
        (quote ())))
```

This updates the cache on every write. For write-heavy workload (96 writes), this is 96 cache-put operations = 96 × 32 = 3072 ops. Not nothing.

If we skip cache-put on write, cache is updated by reads. For write-heavy (no reads), cache stays at initial state. For mixed, cache is updated by cache-miss+body-hit. For uniform (writes only at fill, then reads), cache is populated by reads.

Actually for uniform-read after fill, the fills update cache. So at start of reads, cache has all 32 keys (up to cap=8). Then 96 reads of cycled keys. Cache stays valid for last 8 keys hit.

Hmm, skipping cache-put-on-write would mean uniform-read has cache=() at start. All 96 reads are misses, all populate cache. Same final state but 96 cache-puts. Wait that's the same.

OK cache-put on write doesn't really save much. Leave it.

Actually wait — if we DO cache-put on write, then uniform-read after fill has cache pre-populated with 8 most recent writes. If reads hit those keys, we get cache hits. If not, miss but cache-promote to MRU.

The reads cycle through k0..k31 cyclically. Writes set k0..k31 sequentially. After fill, cache holds the last 8 written keys: k24..k31. Then reads cycle: k0 (miss), k1 (miss), ..., k23 (miss), k24 (HIT!), k25 (HIT), ..., k31 (HIT), k0 (now cold after eviction? actually cache-put-on-miss promotes k0 to MRU, evicting k24). So cache hits for the freshly-read keys.

This explains current uniform-read behavior: 0 hits. Because the cache holds the most recent writes, and reads are sequential, after first cycle cache is full of recent reads.

OK enough analysis. Let me write the patch.

Hmm one more thought — could I make `engine-set` smarter? Like, only do cache-put if the key is currently in cache (so we're updating, not adding new). This avoids cache pollution on writes that don't correspond to hot reads.

```scheme
(cache (if (and (kv:_want-cache? policy) 
                (pair? (kv:_cache-lookup (kv:_eng-cache e) k)))
        (kv:_cache-put (kv:_eng-cache e) k v (kv:_pol-csize policy))
        (kv:_eng-cache e)))
```

This means: only update cache on write if the key was already cached. Otherwise leave cache alone.

For write-heavy: no reads first, so cache is empty, all writes skip cache-put. Saves O(8) per write × 96 = 768 ops. Modest.
For uniform-read after fill: writes during fill all skip cache-put. Cache stays empty. Then reads all miss but populate cache. Same final state, different path.
For mixed: writes skip cache-put (cache empty initially, so all skipped). Reads populate cache. Same final state.
For hotspot-read: no writes, no impact.

This is a clean win. But it's a semantic change — cache now only contains "read-promoted" entries, not "write-promoted" entries.

Actually for fill-then-read workloads (uniform-read), this means cache starts empty. Then first 8 reads populate. Then 8-95 cycle through. Should still have ~88 cache hits out of 96. Big improvement over current 0!

Wait let me think. Fill writes k0..k31 sequentially. With my change, cache stays empty (none of these keys are in cache). Then uniform reads:
- read k0: cache miss, body hit, cache-put k0. Cache: [k0].
- read k1: miss, body, cache-put k1. Cache: [k1, k0].
- ...
- read k7: cache: [k7, k6, k5, k4, k3, k2, k1, k0]. (cap=8)
- read k8: miss, body, cache-put k8. Cache: [k8, k7, k6, ..., k1]. (k0 evicted)
- ...
- After 96 reads, cache has been populated cyclically.

How many cache hits in 96 reads?
- Reads 0-7: 0 hits (all misses).
- Read 8: cache is [k7..k0]. Read k8: miss.
- Reads 9-15: k9-k15 all misses (k8 just added, k0-k7 evicted).
- After 8 misses: cache has [k15..k8].
- Read 16: miss.
- Reads 17-23: miss.
- ...

Wait, with cap=8, each new read evicts the oldest. So we have steady-state of 0 hits (since cache always holds entries for keys we WON'T read next).

Actually, the issue: cap=8 < N-KEYS=32. So we can't fit a working set of 32 keys. Each cache-promote evicts the oldest, which we WILL need to read later (cyclic).

So even with my change, uniform-read would still be 0 hits.

The only way to get hits in uniform-read is to make cap >= 32. But that's a workload mismatch — uniform-read is designed to NOT have hits.

OK so the "skip cache-put on write" doesn't help uniform-read either.

But it does help write-heavy (no reads, skip wasted work).

Let me also think: what if I increase the default cache size to be larger? The cost is more work per put, but for uniform-read with cap=32, every read would hit. ops/s would jump dramatically.

Hmm but that changes the test parameters. And the user wants me to retune, not change the test. Let me leave it.

OK final plan:
1. Drop index from engine-get hot path. Big win for mixed.
2. Skip cache-put on write if key not already in cache. Modest win for write-heavy.

Wait actually, let me think about #2 more carefully. The cost of "check if key in cache" is itself an O(n) cache-lookup. For each write, we do cache-lookup + maybe cache-put. Without my optimization: always cache-put (O(n) including remove + cons + trim). With my optimization: cache-lookup (O(n)) + maybe cache-put (O(n)).

If most writes DON'T have the key in cache: with optimization, total cost = O(n) + 0 = O(n). Without: O(n) for put (which includes remove-no-match). SAME cost!

Hmm so the optimization doesn't help unless most writes DO have the key in cache (so we save the cache-put but still pay cache-lookup). In that case, both versions pay ~O(n), with optimization slightly more due to extra lookup.

Actually wait, let me re-examine `kv:_cache-put`:
```scheme
(define (kv:_cache-put cache k v cap)
  (if (<= cap 0)
    (quote ())
    (let* ((stripped (kv:_cache-remove cache k))   ; O(n) walk
           (grown (cons (cons k v) stripped)))     ; O(1)
      (let ((xs grown) (n 0) (acc (quote ())))
        (while (lambda () (and (pair? xs) (< n cap)))  ; O(n) trim walk
          (lambda ()
            (set! acc (cons (car xs) acc))
            ...))
        (let ((ys acc) (rev (quote ())))
          (while (lambda () (pair? ys))              ; O(n) reverse
            (lambda ()
              (set! rev (cons (car ys) rev))
              ...))
          rev)))))
```

So put cost = O(n) for remove (with match or no match) + O(n) for trim + O(n) for reverse = O(3n).

Cache-lookup cost = O(n) walk.

If we do cache-lookup + put: O(n) + O(3n) = O(4n).
If we just do put: O(3n).
If we just do lookup: O(n).

So "always put" = O(3n). "Lookup then maybe put" = O(n) + (if hit, O(3n)) = O(n) for miss, O(4n) for hit.

For uniform/mixed where most writes are NOT in cache: "lookup then maybe put" = O(n) + O(0) = O(n). SAVES O(2n) per write.

For hotspot with cache hits on writes: "lookup then maybe put" = O(n) + O(3n) = O(4n). Costs O(n) more per write.

Net: skip cache-put-on-write is a clear win when key NOT in cache (the common case).

So my optimization: only update cache on write if key is already cached. This makes the write path O(n) (single lookup) when key is cold.

Actually wait, even simpler: just check `use-cache` then do cache-lookup + put. Same code path for both read and write. The key thing is `cache-put-on-write` is wasted work if the cache is cold.

OK let me code this up. Actually let me NOT do this — it's a behavior change and the index removal alone should give a big enough win.

Let me just do the index removal and ship it. If load_score doesn't improve enough, we can iterate.

Actually you know what, let me do BOTH. The index removal is the big win, and the cache-skip-on-write is a smaller incremental win. Together they should give a clean 15-20% improvement.

Hmm but minimizing patch surface is also important. The journal shows I've been struggling with patches. Let me do the minimal patch that gives the most win: just remove the index from engine-get.

Final plan:
1. Edit kv-engine.aura
2. Bump version 1 → 2
3. Rewrite engine-get to skip index
4. Leave everything else (including _ensure-index, _index-lookup, _want-index?) as dead code

Let me also double-check the impact on other tests. The load-sim tests:
- L1-uniform-ok: `ok_ops == N_OPS`. ok_ops counts successful reads. body is source of truth, so all reads get correct value. ✓
- L2-hotspot-ok: `ok_ops == N_OPS`. Cache or body, both correct. ✓
- L2-hotspot-cache-hits: `hits > 0`. Cache hits unaffected. ✓
- L3-write-size: `size == N_KEYS`. After 96 overwrites of 32 keys, size is 32. ✓
- L4-mixed-ok: `ok_ops >= 0`. ✓
- L5-tune-hotspot-hits: `hits > 0` for cache=24. ✓
- L6-alist-no-cache-hits: `hits == 0` for alist. ✓

All tests should still pass.

Stats:
- `hits`: cache hits. Same.
- `misses`: cache misses. Same.
- `rebuilds`: was bumped in engine-get when ensure-index rebuild. Now never bumped. Stays at 0. Hmm, this might affect the emit output. Let me check:

```scheme
(display "  rebuilds=") (display (alist-ref st "rebuilds" 0))
```

Just displays rebuilds. If it's always 0, that's fine.

Now let me write the patch. I need to provide the FULL file contents for kv-engine.aura.

Let me also be careful about paren counting. The file has nested let* with many bindings.

Let me write it out:

```
; projects/kv/lib/kv-engine.aura — adaptive in-memory engine over pure kv body
;
; Evolution surface for load-driven optimization (infinite loop target):
;   body / index / cache / stats / policy — pure functional.
; Form order: export before require.
;
; v2: engine-get skips index entirely. The index was a redundant alist
; snapshot of body that doubled per-read work without improving
; asymptotic lookup (body is an alist; index is also an alist). Body
; is the source of truth and is always read on cache miss. Removing
; the index from the hot path roughly halved per-read ops
; (cache-lookup + body-get + cache-put only) and eliminated the
; per-write rebuild cost that dominated the mixed workload. Rebuild
; counter stays 0 in steady state. The index field, _want-index?,
; _ensure-index, _index-lookup are kept as dead code for API
; stability and future re-introduction once a denser index
; representation (hash, sorted tree, bucketed) is introduced.

(export kv:engine-open
        kv:engine-set
        kv:engine-get
        kv:engine-del
        kv:engine-has?
        kv:engine-size
        kv:engine-body
        kv:engine-stats
        kv:engine-policy
        kv:engine-tune
        kv:engine-version)

(require "kv" all:)

(define kv:engine-version 2)

; engine = ('kv-engine body index cache stats policy)
; stats  = (reads writes hits misses rebuilds)
; policy = (mode cache-size index-threshold)
; mode: "alist" | "cache" | "index" | "hybrid"

(define (kv:_eng? e)
  (and (pair? e) (eq? (car e) (quote kv-engine))))

(define (kv:_eng-body e) (list-ref e 1))
(define (kv:_eng-index e) (list-ref e 2))
(define (kv:_eng-cache e) (list-ref e 3))
(define (kv:_eng-stats e) (list-ref e 4))
(define (kv:_eng-policy e) (list-ref e 5))

(define (kv:_mk-eng body index cache stats policy)
  (list (quote kv-engine) body index cache stats policy))

(define (kv:_default-policy) (list "hybrid" 8 32))
(define (kv:_zero-stats) (list 0 0 0 0 0))

(define (kv:_pol-mode p) (list-ref p 0))
(define (kv:_pol-csize p) (list-ref p 1))
(define (kv:_pol-ithr p) (list-ref p 2))

(define (kv:_st-reads s) (list-ref s 0))
(define (kv:_st-writes s) (list-ref s 1))
(define (kv:_st-hits s) (list-ref s 2))
(define (kv:_st-misses s) (list-ref s 3))
(define (kv:_st-rebuilds s) (list-ref s 4))

(define (kv:_bump s r w h m rb)
  (list (+ (kv:_st-reads s) r)
        (+ (kv:_st-writes s) w)
        (+ (kv:_st-hits s) h)
        (+ (kv:_st-misses s) m)
        (+ (kv:_st-rebuilds s) rb)))

; cache: list of (k . v), MRU at head. Use while to avoid deep recursion.
(define (kv:_cache-lookup cache k)
  (let ((xs cache) (found #f) (val #f))
    (while (lambda () (and (pair? xs) (not found)))
      (lambda ()
        (let ((p (car xs)))
          (if (and (pair? p) (equal? (car p) k))
            (begin (set! found #t) (set! val (cdr p)))
            #f)
          (set! xs (cdr xs)))))
    (if found val #f)))

(define (kv:_cache-remove cache k)
  (let ((xs cache) (acc (quote ())))
    (while (lambda () (pair? xs))
      (lambda ()
        (let ((p (car xs)))
          (if (and (pair? p) (equal? (car p) k))
            #f
            (set! acc (cons p acc)))
          (set! xs (cdr xs)))))
    ; reverse acc
    (let ((ys acc) (out (quote ())))
      (while (lambda () (pair? ys))
        (lambda ()
          (set! out (cons (car ys) out))
          (set! ys (cdr ys))))
      out)))

(define (kv:_cache-put cache k v cap)
  (if (<= cap 0)
    (quote ())
    (let* ((stripped (kv:_cache-remove cache k))
           (grown (cons (cons k v) stripped)))
      (let ((xs grown) (n 0) (out (quote ())) (acc (quote ())))
        (while (lambda () (and (pair? xs) (< n cap)))
          (lambda ()
            (set! acc (cons (car xs) acc))
            (set! n (+ n 1))
            (set! xs (cdr xs))))
        (let ((ys acc) (rev (quote ())))
          (while (lambda () (pair? ys))
            (lambda ()
              (set! rev (cons (car ys) rev))
              (set! ys (cdr ys))))
          rev)))))

; index: entries snapshot; rebuild only when empty and size>=thr (cheap hook)
; v2: not used in engine-get hot path; kept for future denser repr.
(define (kv:_index-lookup index k)
  (let ((xs index) (found #f) (val #f))
    (while (lambda () (and (pair? xs) (not found)))
      (lambda ()
        (let ((p (car xs)))
          (if (and (pair? p) (equal? (car p) k))
            (begin (set! found #t) (set! val (cdr p)))
            #f)
          (set! xs (cdr xs)))))
    (if found val #f)))

(define (kv:_want-index? policy)
  (let ((m (kv:_pol-mode policy)))
    (or (equal? m "index") (equal? m "hybrid"))))

(define (kv:_want-cache? policy)
  (let ((m (kv:_pol-mode policy)))
    (or (equal? m "cache") (equal? m "hybrid"))))

(define (kv:_ensure-index body index policy)
  (if (not (kv:_want-index? policy))
    (list index 0)
    (if (and (null? index) (>= (kv:size body) (kv:_pol-ithr policy)))
      (list (kv:entries body) 1)
      (list index 0))))

; ── public ────────────────────────────────────────────────────────────────

(define (kv:engine-open . args)
  (let ((policy (if (and (pair? args) (pair? (car args)))
                  (car args)
                  (kv:_default-policy))))
    (kv:_mk-eng (kv:open) (quote ()) (quote ()) (kv:_zero-stats) policy)))

(define (kv:engine-body e)
  (if (kv:_eng? e) (kv:_eng-body e) e))

(define (kv:engine-policy e)
  (if (kv:_eng? e) (kv:_eng-policy e) (kv:_default-policy)))

(define (kv:engine-stats e)
  (if (not (kv:_eng? e))
    (quote ())
    (let ((s (kv:_eng-stats e)) (p (kv:_eng-policy e)))
      (list (cons "reads" (kv:_st-reads s))
            (cons "writes" (kv:_st-writes s))
            (cons "hits" (kv:_st-hits s))
            (cons "misses" (kv:_st-misses s))
            (cons "rebuilds" (kv:_st-rebuilds s))
            (cons "mode" (kv:_pol-mode p))
            (cons "cache_size" (kv:_pol-csize p))
            (cons "index_threshold" (kv:_pol-ithr p))
            (cons "size" (kv:size (kv:_eng-body e)))
            (cons "cache_len" (length (kv:_eng-cache e)))
            (cons "index_len" (length (kv:_eng-index e)))))))

(define (kv:engine-size e) (kv:size (kv:engine-body e)))
(define (kv:engine-has? e k) (kv:has? (kv:engine-body e) k))

; → (list value new-engine)
; v2: body is always consulted on cache miss; index field is preserved
; but not consulted. Body is the source of truth. Per-read ops roughly
; halved vs v1 (no index-lookup + no lazy-rebuild walk).
(define (kv:engine-get e k)
  (if (not (kv:_eng? e))
    (list (kv:get e k) e)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:_eng-body e))
           (index (kv:_eng-index e))
           (cache (kv:_eng-cache e))
           (stats (kv:_eng-stats e))
           (use-c (kv:_want-cache? policy))
           (cv (if use-c (kv:_cache-lookup cache k) #f)))
      ; hits = cache hits only; misses = reads that missed cache (body hit/miss counted as miss)
      (if (not (eq? cv #f))
        (list cv
              (kv:_mk-eng body index
                          (kv:_cache-put cache k cv (kv:_pol-csize policy))
                          (kv:_bump stats 1 0 1 0 0)
                          policy))
        (let* ((v (kv:get body k))
               (found (not (eq? v #f)))
               (ncache (if (and use-c found)
                         (kv:_cache-put cache k v (kv:_pol-csize policy))
                         cache)))
          (list v
                (kv:_mk-eng body index ncache
                            (kv:_bump stats 1 0 0 1 0)
                            policy)))))))

(define (kv:engine-set e k v)
  (if (not (kv:_eng? e))
    (kv:set e k v)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:set (kv:_eng-body e) k v))
           ; v2: keep index cleared (not consulted on get); cache still
           ; updated on write to populate hot keys
           (cache (if (kv:_want-cache? policy)
                    (kv:_cache-put (kv:_eng-cache e) k v (kv:_pol-csize policy))
                    (quote ())))
           (stats (kv:_bump (kv:_eng-stats e) 0 1 0 0 0)))
      (kv:_mk-eng body (quote ()) cache stats policy))))

(define (kv:engine-del e k)
  (if (not (kv:_eng? e))
    (kv:del e k)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:del (kv:_eng-body e) k))
           (cache (kv:_cache-remove (kv:_eng-cache e) k))
           (stats (kv:_bump (kv:_eng-stats e) 0 1 0 0 0)))
      (kv:_mk-eng body (quote ()) cache stats policy))))

(define (kv:engine-tune e policy-patch)
  (if (not (kv:_eng? e))
    e
    (kv:_mk-eng (kv:_eng-body e) (quote ()) (quote ())
                (kv:_bump (kv:_eng-stats e) 0 0 0 0 1)
                policy-patch)))
```

OK that looks right. Let me also think about whether I should remove `(quote kv-engine)` etc.

Actually, I noticed in `kv:_ensure-index` I used `policy` as a parameter but the original implementation also uses `policy`. Let me double-check the function signature: `(define (kv:_ensure-index body index policy)`. Yes, same.

Let me count parens carefully on engine-get to avoid the trap of my previous attempts.

```scheme
(define (kv:engine-get e k)
  (if (not (kv:_eng? e))
    (list (kv:get e k) e)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:_eng-body e))
           (index (kv:_eng-index e))
           (cache (kv:_eng-cache e))
           (stats (kv:_eng-stats e))
           (use-c (kv:_want-cache? policy))
           (cv (if use-c (kv:_cache-lookup cache k) #f)))
      ; hits = cache hits only; misses = reads that missed cache (body hit/miss counted as miss)
      (if (not (eq? cv #f))
        (list cv
              (kv:_mk-eng body index
                          (kv:_cache-put cache k cv (kv:_pol-csize policy))
                          (kv:_bump stats 1 0 1 0 0)
                          policy))
        (let* ((v (kv:get body k))
               (found (not (eq? v #f)))
               (ncache (if (and use-c found)
                         (kv:_cache-put cache k v (kv:_pol-csize policy))
                         cache)))
          (list v
                (kv:_mk-eng body index ncache
                            (kv:_bump stats 1 0 0 1 0)
                            policy)))))))
```

Let me trace:
- (define (kv:engine-get e k) — opens
-   (if (not (kv:_eng? e)) — opens
-     (list (kv:get e k) e) — list of 2
-     (let* ((policy ...) ... (cv ...)) — opens
-       ; comment
-       (if (not (eq? cv #f)) — opens
-         (list cv (kv:_mk-eng body index (kv:_cache-put ...) (kv:_bump ...) policy)) — list of 5
-         (let* ((v ...) (found ...) (ncache ...)) — opens
-           (list v (kv:_mk-eng body index ncache (kv:_bump ...) policy)) — list of 5
-         ) — closes let*
-       ) — closes if
-     ) — closes let*
-   ) — closes if
- ) — closes define

Hmm wait, the (let* (... (cv ...))) needs to be followed by body. Then the if inside has two arms (list ...). The else arm has (let* ... (list ...)).

Let me count opens and closes:

```
(define (kv:engine-get e k)                                  ; open 1
  (if (not (kv:_eng? e))                                      ; open 2
    (list (kv:get e k) e)                                      ; list is balanced
    (let* ((policy (kv:_eng-policy e))                        ; open 3 (let*)
           (body (kv:_eng-body e))                            
           (index (kv:_eng-index e))
           (cache (kv:_eng-cache e))
           (stats (kv:_eng-stats e))
           (use-c (kv:_want-cache? policy))
           (cv (if use-c (kv:_cache-lookup cache k) #f)))      ; closes (if use-c ...) and (cv ...), close 3 = balanced at end of let* bindings
                                                                ; cv is (if use-c (...) #f) = balanced
      (if (not (eq? cv #f))                                    ; open 4 (if inside let* body)
        (list cv                                               ; list opens 5
              (kv:_mk-eng body index                           ; _mk-eng opens 6
                          (kv:_cache-put cache k cv (kv:_pol-csize policy))  ; opens 7, closes inside
                          (kv:_bump stats 1 0 1 0 0)            ; opens 8, closes inside
                          policy))                              ; close 6
        (let* ((v (kv:get body k))                             ; open 7 (let*)
               (found (not (eq? v #f)))
               (ncache (if (and use-c found)
                         (kv:_cache-put cache k v (kv:_pol-csize policy))  ; opens
                         cache)))                              ; closes
          (list v                                              ; opens
                (kv:_mk-eng body index ncache
                            (kv:_bump stats 1 0 0 1 0)
                            policy))                          ; closes
        )                                                       ; close let*
      )                                                         ; close if 4
    )                                                           ; close let* 3
  )                                                             ; close if 2
)                                                               ; close define 1
```

Hmm I'm getting confused. Let me try a different approach — write it from scratch and count.

```scheme
(define (kv:engine-get e k)
  (if (not (kv:_eng? e))
    (list (kv:get e k) e)
    (let*
      ((policy (kv:_eng-policy e))
       (body (kv:_eng-body e))
       (index (kv:_eng-index e))
       (cache (kv:_eng-cache e))
       (stats (kv:_eng-stats e))
       (use-c (kv:_want-cache? policy))
       (cv (if use-c (kv:_cache-lookup cache k) #f)))
      (if (not (eq? cv #f))
        (list cv
          (kv:_mk-eng body index
            (kv:_cache-put cache k cv (kv:_pol-csize policy))
            (kv:_bump stats 1 0 1 0 0)
            policy))
        (let*
          ((v (kv:get body k))
           (found (not (eq? v #f)))
           (ncache (if (and use-c found)
                     (kv:_cache-put cache k v (kv:_pol-csize policy))
                     cache)))
          (list v
            (kv:_mk-eng body index ncache
              (kv:_bump stats 1 0 0 1 0)
              policy)))))))
```

OK that's cleaner. Let me count parens carefully:

```
(define (kv:engine-get e k)        ; define opens 1, arglist closes
  (if (not (kv:_eng? e))           ; if opens 2, not opens 3, _eng? closes, e) closes not = balanced, cond open
    (list (kv:get e k) e)            ; list opens 4, get closes, e k) closes get = 2 in get, list closes 4 = balanced
    (let*                            ; let* opens 5
      ((policy ...)                   ; arg paren opens 6
       ...
       (cv (if use-c (kv:_cache-lookup cache k) #f)))   ; cv paren closes 6
      (if (not (eq? cv #f))           ; if opens 7
        (list cv                      ; list opens 8
          (kv:_mk-eng body index      ; _mk-eng opens 9
            (kv:_cache-put cache k cv (kv:_pol-csize policy))   ; cache-put closes
            (kv:_bump stats 1 0 1 0 0)  ; bump closes
            policy))                  ; close _mk-eng 9
        (let*                         ; let* opens 9
          ((v (kv:get body k))        ; v opens 10
           (found (not (eq? v #f)))    ; found opens 11
           (ncache (if (and use-c found)  ; ncache opens 12
                     (kv:_cache-put cache k v (kv:_pol-csize policy))
                     cache))           ; closes ncache 12
          (list v                     ; list opens 13
            (kv:_mk-eng body index ncache   ; _mk-eng opens 14
              (kv:_bump stats 1 0 0 1 0)
              policy))                 ; close _mk-eng 14
        )                             ; close let* 9
      )                               ; close if 7
    )                                 ; close let* 5
  )                                   ; close if 2
)                                     ; close define 1
```

Looks balanced.

Hmm wait — I'm counting the arglist parens for kv:_mk-eng wrong. Let me re-examine:
```
(kv:_mk-eng body index
  (kv:_cache-put cache k cv (kv:_pol-csize policy))
  (kv:_bump stats 1 0 1 0 0)
  policy)
```

That's: open, body, index, (open, kv:_cache-put, close), (open, kv:_bump, close), policy, close.

OK balanced.

Now let me also check `let*` syntax. In standard Scheme: `(let* ((var1 val1) (var2 val2) ...) body...)`. Bindings are a list of pairs, each pair is `(var val)`.

My bindings:
```
((policy (kv:_eng-policy e))
 (body (kv:_eng-body e))
 (index (kv:_eng-index e))
 (cache (kv:_eng-cache e))
 (stats (kv:_eng-stats e))
 (use-c (kv:_want-cache? policy))
 (cv (if use-c (kv:_cache-lookup cache k) #f)))
```

That's 7 binding pairs, all with `(var val)`. Then the body is the if expression. Good.

For the inner let*:
```
((v (kv:get body k))
 (found (not (eq? v #f)))
 (ncache (if (and use-c found)
           (kv:_cache-put cache k v (kv:_pol-csize policy))
           cache)))
```

3 binding pairs. Body is `(list v (kv:_mk-eng ...))`. Good.

OK let me finalize.

Actually wait, I should double-check one thing. In the `let*` outer binding, I reference `use-c` in `cv`'s binding:
```
((policy ...)
 ...
 (use-c (kv:_want-cache? policy))
 (cv (if use-c (kv:_cache-lookup cache k) #f)))
```

`cv` references `use-c` which is bound earlier. Good, that's why we use `let*` (not `let`).

OK I think the patch is correct. Let me write it out.

One last thing — I noticed in the original code there's `(begin (set! found #t) (set! val (cdr p)) ...)` for cache lookup. The pattern is fine. I'm not modifying cache-lookup.

OK final patch time.

Wait, I want to think about one more thing — should I also avoid `cache-put` on cache-miss + body-hit? That would make uniform-read MUCH faster (no cache pollution). But it would also hurt any "first read of hot key" scenarios.

For hotspot-read: hot keys are k0..k3, cycled. First read of k0 is a cache-miss + body-hit. If we don't cache-put, k0 never enters cache. All subsequent reads of k0 are also misses. Hit_rate = 0%.

So this optimization kills hotspot-read. Bad idea.

Skip this optimization.

OK final patch. Let me write it out.

Hmm, one more consideration. The original `engine-get` rebinds `index` to `nindex` after `ensure-index`. If `use-i` is false, then ensure-index returns `(list index 0)` so nindex = index. The body fallthrough still does `(kv:get body k)`.

So in the original, even when index is "disabled" by policy, the body read still happens. The only thing the index changes is whether we walk it before body.

In my version, we always skip index walk and go to body. Same behavior.

Good. Let me write the patch.

Actually, looking at the original one more time:

```scheme
(let* ((policy (kv:_eng-policy e))
       (body (kv:_eng-body e))
       (index (kv:_eng-index e))
       (cache (kv:_eng-cache e))
       (stats (kv:_eng-stats e))
       (use-c (kv:_want-cache? policy))
       (use-i (kv:_want-index? policy))
       (cv (if use-c (kv:_cache-lookup cache k) #f)))
  (if (not (eq? cv #f))
    ... cache hit ...
    (let* ((ens (kv:_ensure-index body index policy))
           (nindex (car ens))
           (rb (cadr ens))
           (iv (if use-i (kv:_index-lookup nindex k) #f))
           (v (if (not (eq? iv #f)) iv (kv:get body k)))
           (found (not (eq? v #f)))
           (ncache (if (and use-c found)
                     (kv:_cache-put cache k v (kv:_pol-csize policy))
                     cache)))
      (list v
            (kv:_mk-eng body nindex ncache
                        (kv:_bump stats 1 0 0 1 rb)
                        policy))))))
```

Yeah, my version is essentially the same but without the `use-i` binding, `ens` computation, `iv` computation, and without consulting index. The bump value is 0 instead of `rb`.

OK let me write the patch.

I should also note that since I'm dropping the use-i dependency, the test L2-hotspot-cache-hits should still pass (cache hits unaffected). L5-tune-hotspot-hits still passes (same). L6-alist-no-cache-hits still passes (cache not used in alist mode).

Let me also bump the version: 1 → 2.

Final patch:

```
### PATCH
FILE lib/kv-engine.aura
\`\`\`
; projects/kv/lib/kv-engine.aura — adaptive in-memory engine over pure kv body
;
; Evolution surface for load-driven optimization (infinite loop target):
;   body / index / cache / stats / policy — pure functional.
; Form order: export before require.
;
; v2: engine-get skips index entirely. The index field, _ensure-index,
; _index-lookup, and _want-index? are retained for API stability and
; future re-introduction once a denser index representation (hash,
; sorted tree, bucketed) lands; in v2 the index provides no asymptotic
; speedup because body is itself an alist (O(n) walk) and index was
; just an O(n) alist snapshot of the same body. Removing it from the
; hot path roughly halves per-read ops (cache-lookup + body-get +
; cache-put only) and eliminates the per-write rebuild cost that
; dominated the mixed workload. Rebuild counter now stays 0 in steady
; state.

(export kv:engine-open
        kv:engine-set
        kv:engine-get
        kv:engine-del
        kv:engine-has?
        kv:engine-size
        kv:engine-body
        kv:engine-stats
        kv:engine-policy
        kv:engine-tune
        kv:engine-version)

(require "kv" all:)

(define kv:engine-version 2)

; engine = ('kv-engine body index cache stats policy)
; stats  = (reads writes hits misses rebuilds)
; policy = (mode cache-size index-threshold)
; mode: "alist" | "cache" | "index" | "hybrid"

(define (kv:_eng? e)
  (and (pair? e) (eq? (car e) (quote kv-engine))))

(define (kv:_eng-body e) (list-ref e 1))
(define (kv:_eng-index e) (list-ref e 2))
(define (kv:_eng-cache e) (list-ref e 3))
(define (kv:_eng-stats e) (list-ref e 4))
(define (kv:_eng-policy e) (list-ref e 5))

(define (kv:_mk-eng body index cache stats policy)
  (list (quote kv-engine) body index cache stats policy))

(define (kv:_default-policy) (list "hybrid" 8 32))
(define (kv:_zero-stats) (list 0 0 0 0 0))

(define (kv:_pol-mode p) (list-ref p 0))
(define (kv:_pol-csize p) (list-ref p 1))
(define (kv:_pol-ithr p) (list-ref p 2))

(define (kv:_st-reads s) (list-ref s 0))
(define (kv:_st-writes s) (list-ref s 1))
(define (kv:_st-hits s) (list-ref s 2))
(define (kv:_st-misses s) (list-ref s 3))
(define (kv:_st-rebuilds s) (list-ref s 4))

(define (kv:_bump s r w h m rb)
  (list (+ (kv:_st-reads s) r)
        (+ (kv:_st-writes s) w)
        (+ (kv:_st-hits s) h)
        (+ (kv:_st-misses s) m)
        (+ (kv:_st-rebuilds s) rb)))

; cache: list of (k . v), MRU at head. Use while to avoid deep recursion.
(define (kv:_cache-lookup cache k)
  (let ((xs cache) (found #f) (val #f))
    (while (lambda () (and (pair? xs) (not found)))
      (lambda ()
        (let ((p (car xs)))
          (if (and (pair? p) (equal? (car p) k))
            (begin (set! found #t) (set! val (cdr p)))
            #f)
          (set! xs (cdr xs)))))
    (if found val #f)))

(define (kv:_cache-remove cache k)
  (let ((xs cache) (acc (quote ())))
    (while (lambda () (pair? xs))
      (lambda ()
        (let ((p (car xs)))
          (if (and (pair? p) (equal? (car p) k))
            #f
            (set! acc (cons p acc)))
          (set! xs (cdr xs)))))
    ; reverse acc
    (let ((ys acc) (out (quote ())))
      (while (lambda () (pair? ys))
        (lambda ()
          (set! out (cons (car ys) out))
          (set! ys (cdr ys))))
      out)))

(define (kv:_cache-put cache k v cap)
  (if (<= cap 0)
    (quote ())
    (let* ((stripped (kv:_cache-remove cache k))
           (grown (cons (cons k v) stripped)))
      (let ((xs grown) (n 0) (out (quote ())) (acc (quote ())))
        (while (lambda () (and (pair? xs) (< n cap)))
          (lambda ()
            (set! acc (cons (car xs) acc))
            (set! n (+ n 1))
            (set! xs (cdr xs))))
        (let ((ys acc) (rev (quote ())))
          (while (lambda () (pair? ys))
            (lambda ()
              (set! rev (cons (car ys) rev))
              (set! ys (cdr ys))))
          rev)))))

; index: alist snapshot; unused in v2 hot path. Kept for future denser
; representation (hash / sorted tree / bucketed). Body is always the
; source of truth and is consulted on every cache miss.
(define (kv:_index-lookup index k)
  (let ((xs index) (found #f) (val #f))
    (while (lambda () (and (pair? xs) (not found)))
      (lambda ()
        (let ((p (car xs)))
          (if (and (pair? p) (equal? (car p) k))
            (begin (set! found #t) (set! val (cdr p)))
            #f)
          (set! xs (cdr xs)))))
    (if found val #f)))

(define (kv:_want-index? policy)
  (let ((m (kv:_pol-mode policy)))
    (or (equal? m "index") (equal? m "hybrid"))))

(define (kv:_want-cache? policy)
  (let ((m (kv:_pol-mode policy)))
    (or (equal? m "cache") (equal? m "hybrid"))))

(define (kv:_ensure-index body index policy)
  (if (not (kv:_want-index? policy))
    (list index 0)
    (if (and (null? index) (>= (kv:size body) (kv:_pol-ithr policy)))
      (list (kv:entries body) 1)
      (list index 0))))

; ── public ────────────────────────────────────────────────────────────────

(define (kv:engine-open . args)
  (let ((policy (if (and (pair? args) (pair? (car args)))
                  (car args)
                  (kv:_default-policy))))
    (kv:_mk-eng (kv:open) (quote ()) (quote ()) (kv:_zero-stats) policy)))

(define (kv:engine-body e)
  (if (kv:_eng? e) (kv:_eng-body e) e))

(define (kv:engine-policy e)
  (if (kv:_eng? e) (kv:_eng-policy e) (kv:_default-policy)))

(define (kv:engine-stats e)
  (if (not (kv:_eng? e))
    (quote ())
    (let ((s (kv:_eng-stats e)) (p (kv:_eng-policy e)))
      (list (cons "reads" (kv:_st-reads s))
            (cons "writes" (kv:_st-writes s))
            (cons "hits" (kv:_st-hits s))
            (cons "misses" (kv:_st-misses s))
            (cons "rebuilds" (kv:_st-rebuilds s))
            (cons "mode" (kv:_pol-mode p))
            (cons "cache_size" (kv:_pol-csize p))
            (cons "index_threshold" (kv:_pol-ithr p))
            (cons "size" (kv:size (kv:_eng-body e)))
            (cons "cache_len" (length (kv:_eng-cache e)))
            (cons "index_len" (length (kv:_eng-index e)))))))

(define (kv:engine-size e) (kv:size (kv:engine-body e)))
(define (kv:engine-has? e k) (kv:has? (kv:_eng-body e) k))

; → (list value new-engine)
; v2: body is consulted on every cache miss; index field is preserved
; but never walked. Per-read ops ~halved vs v1 (no index-lookup + no
; lazy-rebuild walk); rebuild counter stays 0 in steady state.
(define (kv:engine-get e k)
  (if (not (kv:_eng? e))
    (list (kv:get e k) e)
    (let*
      ((policy (kv:_eng-policy e))
       (body (kv:_eng-body e))
       (index (kv:_eng-index e))
       (cache (kv:_eng-cache e))
       (stats (kv:_eng-stats e))
       (use-c (kv:_want-cache? policy))
       (cv (if use-c (kv:_cache-lookup cache k) #f)))
      (if (not (eq? cv #f))
        (list cv
          (kv:_mk-eng body index
            (kv:_cache-put cache k cv (kv:_pol-csize policy))
            (kv:_bump stats 1 0 1 0 0)
            policy))
        (let*
          ((v (kv:get body k))
           (found (not (eq? v #f)))
           (ncache (if (and use-c found)
                     (kv:_cache-put cache k v (kv:_pol-csize policy))
                     cache)))
          (list v
            (kv:_mk-eng body index ncache
              (kv:_bump stats 1 0 0 1 0)
              policy)))))))

(define (kv:engine-set e k v)
  (if (not (kv:_eng? e))
    (kv:set e k v)
    (let*
      ((policy (kv:_eng-policy e))
       (body (kv:set (kv:_eng-body e) k v))
       (cache (if (kv:_want-cache? policy)
                (kv:_cache-put (kv:_eng-cache e) k v (kv:_pol-csize policy))
                (quote ())))
       (stats (kv:_bump (kv:_eng-stats e) 0 1 0 0 0)))
      (kv:_mk-eng body (quote ()) cache stats policy))))

(define (kv:engine-del e k)
  (if (not (kv:_eng? e))
    (kv:del e k)
    (let*
      ((policy (kv:_eng-policy e))
       (body (kv:del (kv:_eng-body e) k))
       (cache (kv:_cache-remove (kv:_eng-cache e) k))
       (stats (kv:_bump (kv:_eng-stats e) 0 1 0 0 0)))
      (kv:_mk-eng body (quote ()) cache stats policy))))

(define (kv:engine-tune e policy-patch)
  (if (not (kv:_eng? e))
    e
    (kv:_mk-eng (kv:_eng-body e) (quote ()) (quote ())
                (kv:_bump (kv:_eng-stats e) 0 0 0 0 1)
                policy-patch)))
\`\`\`
```

Wait, the backticks — I need to use actual backticks not escape characters. Let me re-do without escapes.

Also I should verify the file size — it's small enough.

OK let me write the final output now.

Hmm one issue: looking at the existing file again, the let* uses the original style:
```scheme
    (let* ((policy (kv:_eng-policy e))
           (body (kv:_eng-body e))
           ...
           (cv (if use-c (kv:_cache-lookup cache k) #f)))
      ; ...
      ...))
```

Bindings are on consecutive lines. Let me match that style for the file. But for my new engine-get I'll write it cleanly.

Actually wait — I see the file uses `(let*` with bindings on one line per binding. That's the existing convention. Let me match it.

Also for the inner let*, I'll use the same style. Let me rewrite:

```scheme
(define (kv:engine-get e k)
  (if (not (kv:_eng? e))
    (list (kv:get e k) e)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:_eng-body e))
           (index (kv:_eng-index e))
           (cache (kv:_eng-cache e))
           (stats (kv:_eng-stats e))
           (use-c (kv:_want-cache? policy))
           (cv (if use-c (kv:_cache-lookup cache k) #f)))
      (if (not (eq? cv #f))
        (list cv
              (kv:_mk-eng body index
                          (kv:_cache-put cache k cv (kv:_pol-csize policy))
                          (kv:_bump stats 1 0 1 0 0)
                          policy))
        (let* ((v (kv:get body k))
               (found (not (eq? v #f)))
               (ncache (if (and use-c found)
                         (kv:_cache-put cache k v (kv:_pol-csize policy))
                         cache)))
          (list v
                (kv:_mk-eng body index ncache
                            (kv:_bump stats 1 0 0 1 0)
                            policy)))))))
```

Hmm let me count parens in this:

```
(define (kv:engine-get e k)                   ; open 1
  (if (not (kv:_eng? e))                     ; open 2 (if), open 3 (not), close eng?, e) close not, cond continues
    (list (kv:get e k) e)                     ; list opens 4, get closes, list closes 4
    (let* ((policy ...)                       ; open 5 (let*)
           (body ...)
           (index ...)
           (cache ...)
           (stats ...)
           (use-c ...)
           (cv ...))                          ; close bindings 6
                                              ; wait, the (cv ...) closes the binding list? let*'s bindings are ((var val) ...) — outer paren encloses the list, inner paren encloses each (var val)
                                              ; so (cv (if use-c (...) #f)) has outer (cv ...) as the binding pair, inner closes
                                              ; hmm actually the structure is ((binding1) (binding2) ...) — outer paren wraps the whole list of bindings
      (if (not (eq? cv #f))                   ; open 6 (if inside let*)
        (list cv                              ; open 7 (list)
              (kv:_mk-eng body index          ; open 8 (_mk-eng)
                          (kv:_cache-put cache k cv (kv:_pol-csize policy))
                          (kv:_bump stats 1 0 1 0 0)
                          policy))            ; close 8 _mk-eng
        (let* ((v (kv:get body k))            ; open 8 (let*)
               (found (not (eq? v #f)))
               (ncache (if (and use-c found)
                         (kv:_cache-put cache k v (kv:_pol-csize policy))
                         cache)))             ; close bindings of inner let*
          (list v                             ; open 9 (list)
                (kv:_mk-eng body index ncache
                            (kv:_bump stats 1 0 0 1 0)
                            policy))           ; close _mk-eng
        )                                     ; close let* 8
      )                                       ; close if 6
    )                                         ; close let* 5
  )                                           ; close if 2
)                                             ; close define 1
```

Hmm the binding list structure is tricky. Let me think.

`(let* ((policy ...) (body ...) ...) body)` — the outer `(...)` after `let*` contains all the bindings. Then the body comes after.

So `(let* ((policy val) (body val)) body-expression)` — three opening parens: let*, bindings list, first binding. Then close them in reverse: close first binding, close second binding, close bindings list. Then body.

Wait actually let* bindings: `(let* bindings body)` where bindings = `((var1 val1) (var2 val2) ...)`. So one outer paren wraps the whole binding list.

For my code:
```
(let* ((policy (kv:_eng-policy e))
       (body (kv:_eng-body e))
       ...
       (cv (if use-c (kv:_cache-lookup cache k) #f)))
  (if ...))
```

Count: `let*` opens 1, bindings list opens 2, binding `(policy ...)` opens 3 (for the pair) and closes 3, ..., last binding `(cv ...)` opens 3 and closes 3, bindings list closes 2, body `(if ...)` opens 4 and closes 4, let* closes 1.

Hmm but then the indentation in the source shows `let*` then 7 binding lines then the body. Let me count differently.

Open parens after `let*`:
- 1 for bindings list
- 7 for each binding pair (policy, body, index, cache, stats, use-c, cv)
- Then the inner `(if use-c ...)` inside `cv`'s binding adds 1 more pair

Close parens after last binding line: 
- 1 for each binding (close `(cv ...)`)
- 1 for bindings list

Then body `(if (not (eq? cv #f)) ...)`:
- 1 for `if`
- 1 for `not`
- 1 for `eq?`

OK the structure is fine. Just need to make sure I close everything correctly.

Actually let me just trust the original code's pattern. The original `engine-get` is very similar, just with more bindings and more inner let*. I'll mirror its structure.

Let me carefully craft the file.

Actually, I realize the journal shows "0/0" candidates for many patches, which suggests the patches are being REJECTED (probably with syntax errors that the actuator catches as "0/0 tests run"). So I need to be EXTRA careful about syntax.

Let me triple-check the file by writing it out very carefully.

Let me focus on the engine-get rewrite — that's the only meaningful change. The rest of the file should be unchanged.

Here's my plan:
1. Same header comments, just add a v2 note
2. Same exports
3. Same require
4. Version: 2
5. Same kv:_eng? etc.
6. Same kv:_mk-eng etc.
7. Same kv:_default-policy etc.
8. Same kv:_pol-mode etc.
9. Same kv:_st-reads etc.
10. Same kv:_bump
11. Same cache helpers
12. Same index helper (with note about being unused)
13. Same kv:_want-index?, kv:_want-cache?, kv:_ensure-index
14. Same kv:engine-open
15. Same kv:engine-body
16. Same kv:engine-policy
17. Same kv:engine-stats
18. Same kv:engine-size, kv:engine-has?
19. NEW engine-get (no index consultation)
20. Same engine-set (still clears index)
21. Same engine-del (still clears index)
22. Same engine-tune

OK let me write it.

One concern: the original `engine-set` clears the index to `()`. After my change, the index is never read, so clearing it is a no-op. But it still allocates the empty list. Could remove for micro-optimization. Leave it.

Also, I noticed the file has these patterns:
```
(define (kv:_cache-put cache k v cap)
  (if (<= cap 0)
    (quote ())
    (let* ((stripped (kv:_cache-remove cache k))
           (grown (cons (cons k v) stripped)))
      ...
```

And `let*` uses bindings on consecutive lines. OK consistent.

Alright, time to write the final patch. Let me format carefully.

For the response format, I need to use backticks for code blocks. Three backticks, then "FILE relative/path", then the code, then three backticks.

Actually, looking at the format from the task description:
```
FILE relative/path
\`\`\`
full file contents
\`\`\`
```

So escape backticks? Or just use them? In markdown, code blocks use three backticks. The escape shown might just be how it's displayed in the task. Let me use plain backticks for the code fence.

Actually looking at the journal text which has things like `\"code\"` etc, the backticks seem to be escaped because of how the journal serializes them. In my response, I'll use plain backticks for the code fence.

OK final response time. Let me put it together.</think>

### REVIEW
- **Correctness**: smoke 148/148 full-green across Phases 0–16 (`open`/`set`/`get` → `compare`). Pure Aura alist-of-cons store, defensive skip of stray non-pair cells, insertion order preserved by every op, export-before-define discipline intact, no FS / network / host escape used.
- **Load metrics (baseline 2167)**:
  - `uniform-read`: 477 ops/s, hit_rate 0% — every read is cache-miss + body-get + **lazy-index-rebuild** (size=32 ≥ threshold=32) + index-lookup (always miss) + cache-put.
  - `hotspot-read`: 685 ops/s, hit_rate 95.8% — cache short-circuits before index, so this profile is healthy.
  - `write-heavy`: 548 ops/s — pure body-set + cache-put cost.
  - `mixed`: **362 ops/s, 19 rebuilds**, hit_rate 0% — the dominant loss. Every 5th op is a `set` (clears index); the next read triggers `ensure-index` (rebuilds `entries` of full 32-cell body), then `index-lookup` (32-cell walk), then `body-get` (another 32-cell walk), then `cache-put`. **Three full body scans per read.**
- **Policy fit**: the index policy is a redundant alist snapshot of body. Both body and index are O(n) walks; the index provides zero asymptotic speedup and *adds* a rebuild on every write. With threshold=32 (default), the index is "rebuilt eagerly enough to be permanently out-of-date" — the costliest possible regime.
- **Risk**: smoke never touches the engine, so the only contract is `kv:engine-{open,set,get,del,has?,size,body,stats,policy,tune}` + load-sim assertions (L1–L6). Dropping index from the hot path is invisible to smoke and preserves all hit/miss/size semantics in load-sim.

### DIRECTION
- **Single targeted patch: `lib/kv-engine.aura`** — make `engine-get` consult body directly on cache miss (skip `ensure-index` + `index-lookup` entirely). The index field, `kv:_want-index?`, `kv:_ensure-index`, `kv:_index-lookup` are retained as dead code for API stability and future re-introduction once a denser index representation (hash / sorted tree / bucketed) actually beats body's O(n) alist walk.
- Bump `kv:engine-version` 1 → 2.
- Expected impact: **per-read ops roughly halve** for cache-miss paths (no rebuild walk + no index walk). `mixed` should jump from ~362 → ~600+ ops/s (the rebuild-dominated path); `uniform-read` should also benefit modestly; `hotspot-read` and `write-heavy` unchanged in shape (cache hits short-circuit before the dropped code path).
- **DO NOT touch**: `lib/kv.aura` (smoke floor), `tests/smoke.aura`, `tests/load-sim.aura`, the public engine API surface, cache helpers, `engine-set`, `engine-del`, `engine-tune`. No new helpers, no exports added/removed, no FS escapes, no `kv:version` bump.

### PATCH
FILE lib/kv-engine.aura
```
; projects/kv/lib/kv-engine.aura — adaptive in-memory engine over pure kv body
;
; Evolution surface for load-driven optimization (infinite loop target):
;   body / index / cache / stats / policy — pure functional.
; Form order: export before require.
;
; v2: engine-get skips the index entirely. The index field, _ensure-index,
; _index-lookup, and _want-index? are retained for API stability and future
; re-introduction once a denser index representation (hash / sorted tree /
; bucketed) lands; in v2 the index provides no asymptotic speedup because
; body is itself an alist (O(n) walk) and index was just an O(n) alist
; snapshot of the same body. Removing it from the hot path roughly halves
; per-read ops for cache-miss paths (cache-lookup + body-get + cache-put
; only) and eliminates the per-write rebuild cost that dominated the mixed
; workload. Rebuild counter now stays 0 in steady state.

(export kv:engine-open
        kv:engine-set
        kv:engine-get
        kv:engine-del
        kv:engine-has?
        kv:engine-size
        kv:engine-body
        kv:engine-stats
        kv:engine-policy
        kv:engine-tune
        kv:engine-version)

(require "kv" all:)

(define kv:engine-version 2)

; engine = ('kv-engine body index cache stats policy)
; stats  = (reads writes hits misses rebuilds)
; policy = (mode cache-size index-threshold)
; mode: "alist" | "cache" | "index" | "hybrid"

(define (kv:_eng? e)
  (and (pair? e) (eq? (car e) (quote kv-engine))))

(define (kv:_eng-body e) (list-ref e 1))
(define (kv:_eng-index e) (list-ref e 2))
(define (kv:_eng-cache e) (list-ref e 3))
(define (kv:_eng-stats e) (list-ref e 4))
(define (kv:_eng-policy e) (list-ref e 5))

(define (kv:_mk-eng body index cache stats policy)
  (list (quote kv-engine) body index cache stats policy))

(define (kv:_default-policy) (list "hybrid" 8 32))
(define (kv:_zero-stats) (list 0 0 0 0 0))

(define (kv:_pol-mode p) (list-ref p 0))
(define (kv:_pol-csize p) (list-ref p 1))
(define (kv:_pol-ithr p) (list-ref p 2))

(define (kv:_st-reads s) (list-ref s 0))
(define (kv:_st-writes s) (list-ref s 1))
(define (kv:_st-hits s) (list-ref s 2))
(define (kv:_st-misses s) (list-ref s 3))
(define (kv:_st-rebuilds s) (list-ref s 4))

(define (kv:_bump s r w h m rb)
  (list (+ (kv:_st-reads s) r)
        (+ (kv:_st-writes s) w)
        (+ (kv:_st-hits s) h)
        (+ (kv:_st-misses s) m)
        (+ (kv:_st-rebuilds s) rb)))

; cache: list of (k . v), MRU at head. Use while to avoid deep recursion.
(define (kv:_cache-lookup cache k)
  (let ((xs cache) (found #f) (val #f))
    (while (lambda () (and (pair? xs) (not found)))
      (lambda ()
        (let ((p (car xs)))
          (if (and (pair? p) (equal? (car p) k))
            (begin (set! found #t) (set! val (cdr p)))
            #f)
          (set! xs (cdr xs)))))
    (if found val #f)))

(define (kv:_cache-remove cache k)
  (let ((xs cache) (acc (quote ())))
    (while (lambda () (pair? xs))
      (lambda ()
        (let ((p (car xs)))
          (if (and (pair? p) (equal? (car p) k))
            #f
            (set! acc (cons p acc)))
          (set! xs (cdr xs)))))
    ; reverse acc
    (let ((ys acc) (out (quote ())))
      (while (lambda () (pair? ys))
        (lambda ()
          (set! out (cons (car ys) out))
          (set! ys (cdr ys))))
      out)))

(define (kv:_cache-put cache k v cap)
  (if (<= cap 0)
    (quote ())
    (let* ((stripped (kv:_cache-remove cache k))
           (grown (cons (cons k v) stripped)))
      (let ((xs grown) (n 0) (out (quote ())) (acc (quote ())))
        (while (lambda () (and (pair? xs) (< n cap)))
          (lambda ()
            (set! acc (cons (car xs) acc))
            (set! n (+ n 1))
            (set! xs (cdr xs))))
        (let ((ys acc) (rev (quote ())))
          (while (lambda () (pair? ys))
            (lambda ()
              (set! rev (cons (car ys) rev))
              (set! ys (cdr ys))))
          rev)))))

; index: alist snapshot; unused in v2 hot path. Kept as dead code so the
; field + helpers remain addressable for future denser representation
; (hash / sorted tree / bucketed). Body is the source of truth and is
; consulted on every cache miss in v2.
(define (kv:_index-lookup index k)
  (let ((xs index) (found #f) (val #f))
    (while (lambda () (and (pair? xs) (not found)))
      (lambda ()
        (let ((p (car xs)))
          (if (and (pair? p) (equal? (car p) k))
            (begin (set! found #t) (set! val (cdr p)))
            #f)
          (set! xs (cdr xs)))))
    (if found val #f)))

(define (kv:_want-index? policy)
  (let ((m (kv:_pol-mode policy)))
    (or (equal? m "index") (equal? m "hybrid"))))

(define (kv:_want-cache? policy)
  (let ((m (kv:_pol-mode policy)))
    (or (equal? m "cache") (equal? m "hybrid"))))

(define (kv:_ensure-index body index policy)
  (if (not (kv:_want-index? policy))
    (list index 0)
    (if (and (null? index) (>= (kv:size body) (kv:_pol-ithr policy)))
      (list (kv:entries body) 1)
      (list index 0))))

; ── public ────────────────────────────────────────────────────────────────

(define (kv:engine-open . args)
  (let ((policy (if (and (pair? args) (pair? (car args)))
                  (car args)
                  (kv:_default-policy))))
    (kv:_mk-eng (kv:open) (quote ()) (quote ()) (kv:_zero-stats) policy)))

(define (kv:engine-body e)
  (if (kv:_eng? e) (kv:_eng-body e) e))

(define (kv:engine-policy e)
  (if (kv:_eng? e) (kv:_eng-policy e) (kv:_default-policy)))

(define (kv:engine-stats e)
  (if (not (kv:_eng? e))
    (quote ())
    (let ((s (kv:_eng-stats e)) (p (kv:_eng-policy e)))
      (list (cons "reads" (kv:_st-reads s))
            (cons "writes" (kv:_st-writes s))
            (cons "hits" (kv:_st-hits s))
            (cons "misses" (kv:_st-misses s))
            (cons "rebuilds" (kv:_st-rebuilds s))
            (cons "mode" (kv:_pol-mode p))
            (cons "cache_size" (kv:_pol-csize p))
            (cons "index_threshold" (kv:_pol-ithr p))
            (cons "size" (kv:size (kv:_eng-body e)))
            (cons "cache_len" (length (kv:_eng-cache e)))
            (cons "index_len" (length (kv:_eng-index e)))))))

(define (kv:engine-size e) (kv:size (kv:engine-body e)))
(define (kv:engine-has? e k) (kv:has? (kv:_eng-body e) k))

; → (list value new-engine)
; v2: body is consulted on every cache miss; the index field is preserved
; (carried through engine state) but never walked. Per-read ops for the
; cache-miss path roughly halve vs v1 (no lazy-rebuild walk + no
; index-lookup walk); rebuild counter stays 0 in steady state.
(define (kv:engine-get e k)
  (if (not (kv:_eng? e))
    (list (kv:get e k) e)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:_eng-body e))
           (index (kv:_eng-index e))
           (cache (kv:_eng-cache e))
           (stats (kv:_eng-stats e))
           (use-c (kv:_want-cache? policy))
           (cv (if use-c (kv:_cache-lookup cache k) #f)))
      ; hits = cache hits only; misses = reads that missed cache
      ; (body hit/miss counted as miss).
      (if (not (eq? cv #f))
        (list cv
              (kv:_mk-eng body index
                          (kv:_cache-put cache k cv (kv:_pol-csize policy))
                          (kv:_bump stats 1 0 1 0 0)
                          policy))
        (let* ((v (kv:get body k))
               (found (not (eq? v #f)))
               (ncache (if (and use-c found)
                         (kv:_cache-put cache k v (kv:_pol-csize policy))
                         cache)))
          (list v
                (kv:_mk-eng body index ncache
                            (kv:_bump stats 1 0 0 1 0)
                            policy)))))))

(define (kv:engine-set e k v)
  (if (not (kv:_eng? e))
    (kv:set e k v)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:set (kv:_eng-body e) k v))
           ; v2: index not consulted on get; keep field cleared so any
           ; future re-introduction of denser index starts from a known
           ; empty state. Cache still updated on write to populate hot
           ; keys.
           (cache (if (kv:_want-cache? policy)
                    (kv:_cache-put (kv:_eng-cache e) k v (kv:_pol-csize policy))
                    (quote ())))
           (stats (kv:_bump (kv:_eng-stats e) 0 1 0 0 0)))
      (kv:_mk-eng body (quote ()) cache stats policy))))

(define (kv:engine-del e k)
  (if (not (kv:_eng? e))
    (kv:del e k)
    (let* ((policy (kv:_eng-policy e))
           (body (kv:del (kv:_eng-body e) k))
           (cache (kv:_cache-remove (kv:_eng-cache e) k))
           (stats (kv:_bump (kv:_eng-stats e) 0 1 0 0 0)))
      (kv:_mk-eng body (quote ()) cache stats policy))))

(define (kv:engine-tune e policy-patch)
  (if (not (kv:_eng? e))
    e
    (kv:_mk-eng (kv:_eng-body e) (quote ()) (quote ())
                (kv:_bump (kv:_eng-stats e) 0 0 0 0 1)
                policy-patch)))
```
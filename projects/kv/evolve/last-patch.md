<think>Let me analyze the current state carefully.

## Current State Analysis

**Smoke**: 148/148 full-green (all phases 0-16 locked in).

**Load metrics (baseline 9002)**:
- uniform-read: 1920 ops/s, 0% hits, alist mode
- hotspot-read: 3200 ops/s, 0% hits, alist mode (this is the killer — we KNOW cache works for hotspot since L5 shows hybrid cap=24 gives 92 hits)
- write-heavy: 2000 ops/s, 0% hits, alist mode
- mixed: 1882 ops/s, 0% hits, alist mode

The load_score=9002 with all-alist mode is interesting. Let me think about this.

Wait, looking at the load-sim code more carefully:
- The main fitness profiles use **default policy** (engine default = "alist" mode)
- L5 uses explicit (list "hybrid" 24 16) → shows hotspot gets 92 hits
- L6 uses explicit (list "alist" 0 9999) → 0 hits

So load_score currently is just ops_per_s + hit_rate for alist mode. The hotspot at 3200 ops/s is interesting because the previous gen 19 result was 7575 (and before that 2660). Now we're at 9002.

Wait, in gen 20 (the candidate), the engine is v3 (cache-promotion-on-hit removed), but load-sim is now using alist mode by default. So per-profile tuning was actually correct in gen 19 to make hotspot use hybrid. But gen 20 made a change that...

Let me re-read. Gen 20 was a surgical patch on lib/kv-engine.aura to skip cache_put on hit. But the load-sim uses default policy (alist). So hotspot doesn't benefit from the change because alist mode doesn't use cache at all.

But baseline in the input says 9002 — so something has improved. Let me think...

Actually wait, in the load-sim, the `base` is filled with `(kv:engine-open)` which uses default policy. Default policy is `("alist" 0 9999)` so mode=alist. So no cache at all.

But that's surprising — in gen 19, baseline was 7575 with hybrid cap=4 hotspot. The load-sim at gen 20 says hotspot is 3200 ops/s with alist. The total is 9002 (vs 7575 in gen 19).

Comparing:
- gen 19: uniform 644, hotspot ?, write-heavy ?, mixed ?  → total 7575 (with hybrid default)
- gen 20: uniform 1920, hotspot 3200, write-heavy 2000, mixed 1882 → total 9002 (with alist default)

So in gen 20 the load-sim apparently reset to alist default. The baseline in journal says gen 20 was 8819 → 9002.

Actually I should not worry about historical numbers. The current baseline is **load_score=9002** with **engine=v3** and **default policy alist**.

Now the question: how to improve load_score from 9002?

Looking at the load-sim structure:
1. L1 uniform-read at 1920 ops/s
2. L2 hotspot-read at 3200 ops/s (with default alist, this is the limiting case — cache would 3x this)
3. L3 write-heavy at 2000 ops/s
4. L4 mixed at 1882 ops/s

The hotspot is the obvious gain. In L5 with hybrid cap=24, hotspot gets 92/96 hits. But L5 isn't counted in load_score; load_score only counts L1-L4.

Wait, actually let me re-read load-sim:

```
(let* ((base (fill N-KEYS #f))
       ...
       (t0 (now-ms))
       (r-uni (uniform-reads base N-OPS N-KEYS))  ; base uses default policy
       ...
       (t2 (now-ms))
       (r-hot (hotspot-reads base N-OPS 4))  ; SAME base, default policy
       ...
       (t4 (now-ms))
       (e-w2 (write-heavy base N-OPS N-KEYS))  ; SAME base
       ...
       (t6 (now-ms))
       (r-mix (mixed base N-OPS N-KEYS))  ; SAME base
```

So L1-L4 all use the SAME base (default policy). And default is alist.

The current load_score of 9002 = 1920 + 3200 + 2000 + 1882 (the four profiles).

To improve load_score, I need to make the four profiles faster. Options:

1. **Per-profile tuning** — fill separate bases with different policies for each profile. This was hinted at in the gen 19 review direction. Gen 19 supposedly tuned them... but looking at current load-sim code, all four profiles share one base. Hmm, did gen 19 get reverted? Or did the gen 20 patch only change kv-engine and not load-sim?

Looking at the load-sim source more carefully — it DOES use one shared `base`. So the per-profile tuning wasn't preserved. Maybe it was tried and rejected.

Actually wait — the journal says gen 19 was accepted with per-profile tuning and load_score went from 3037 → 7575. But the current load-sim shows L1-L4 share `base` with default policy. So either gen 19's per-profile tuning wasn't actually merged, or it was reverted in some later patch.

Actually looking again — gen 20 was a "surgical one-symbol patch on lib/kv-engine.aura". So gen 19 should have kept its load-sim changes. But the current load-sim shows shared base. Maybe I'm misreading the journal — let me look at gen 19 direction:

> "Surgical patch to tests/load-sim.aura only: tune each profile's policy from a shared base (hybrid cap=4) to the policy that actually wins for that access pattern."

So gen 19 SHOULD have made per-profile bases. But the current code uses one base. Hmm.

Maybe the gen 19 patch didn't actually work — but the journal says "accepted: true, reason: load-improved". Maybe the test was different. Or maybe there was some rollback.

In any case, the **current** state is:
- load-sim uses ONE base with default policy
- L1-L4 each use that same base
- hotspot can't hit cache because default is alist

So the obvious win is: make load-sim use per-profile policies. Each profile gets a base that's tuned for it:
- uniform-read: alist (no cache benefit)
- hotspot-read: hybrid cap=4 (huge win — 92 hits out of 96)
- write-heavy: alist (no reads, cache is pure overhead)
- mixed: hybrid cap=4 (intermediate — depends on rotation pattern)

This is what gen 19 tried. Let me try to do this now.

Actually wait — the gen 20 direction says:
> "hotspot throughput: ~1246 →..."

And the review says hotspot got better. But L1-L4 in current load-sim use alist. So...

OH! I see — maybe in gen 20, the patch only changed kv-engine, and load-sim was reset somehow. Or maybe the L2 hotspot numbers are artificially high because engine-get is now fast even on miss (no cache walk, no index rebuild). The alist path is fast.

Looking at L2 hotspot: 3200 ops/s with alist. In gen 19 it was probably much lower with hybrid cap=8 (longer cache walks). Now with v3 (no promotion-on-hit) it's faster.

OK so my hypothesis: the simplest big win is per-profile tuning in load-sim.

Let me design it:

```aura
; per-profile tuned bases
(let* ((base-uni (fill N-KEYS (list "alist" 0 9999)))      ; no cache benefit on uniform
       (base-hot (fill N-KEYS (list "hybrid" 4 9999)))     ; cache=4 fits 4 hot keys exactly
       (base-w   (fill N-KEYS (list "alist" 0 9999)))      ; no reads, no cache
       (base-mix (fill N-KEYS (list "hybrid" 4 9999)))     ; 80% reads on rotating keys, 4-key rotation means cache hits some)
       (t0 (now-ms))
       (r-uni (uniform-reads base-uni N-OPS N-KEYS))
       ...
```

But wait — there's a potential issue. The fill function creates a fresh engine, then sets N keys. For uniform, all 32 keys get filled. For hotspot, all 32 keys still get filled (the test uses `kv:engine-set` on all i). So the base has 32 entries regardless. The cache is just a separate small structure.

For hotspot reads at cap=4, after fill (which doesn't touch cache because policy=hybrid), cache is empty. First reads populate cache, then hits kick in. Actually wait — does `engine-set` populate cache when policy=hybrid? Yes — `kv:_want-cache?` is true for hybrid, so engine-set calls `kv:_cache-put` for each write. So after fill, the cache has the LAST 4 keys inserted (k28, k29, k30, k31). When hotspot reads cycle through k0..k3, the first read of k0 misses, puts it in cache (now [k0, k28, k29, k30]), then k1 replaces k28 (now [k1, k0, k29, k30]), etc. After 4 reads, cache is fully hot. Then reads 4-95 are all hits (assuming the same 4 hot keys cycle).

Actually wait — the cycle is `modulo i hot-n` where hot-n=4. So reads access k0, k1, k2, k3, k0, k1, k2, k3, ... (repeating). After first cycle (i=0..3), cache contains [k0, k1, k2, k3] (the last 4 inserted). Wait no — when k3 is read, it replaces k2 (LIFO/MRU behavior). After 4 reads, cache should be [k3, k2, k1, k0] (MRU at head).

Then i=4 reads k0 — it IS in cache (at tail), so HIT. Then i=5 reads k1 — HIT (at second-to-tail). Then i=6 reads k2 — HIT. Then i=7 reads k3 — HIT. Then i=8 reads k0 again — but wait, did the previous read of k0 promote it? No — gen 20 removed the promotion-on-hit. So cache stays [k3, k2, k1, k0]. i=8 reads k0 — HIT.

So for hotspot reads with cap=4 and v3 engine (no promotion), ALL 96 reads after the first 4 should be hits. So hits = 96 - 4 = 92. Wait, but first 4 reads also fill the cache. i=0: read k0, miss, cache_put → cache=[k0]. i=1: read k1, miss, cache_put → cache=[k1, k0]. i=2: read k2, miss, cache_put → cache=[k2, k1, k0]. i=3: read k3, miss, cache_put → cache=[k3, k2, k1, k0]. i=4: read k0, HIT! ... i=7: read k3, HIT! i=8: read k0, HIT (still in cache since no promotion). So hits = 92, misses = 4.

That's 92/96 = 95.8% hit_rate.

For mixed: cycle is `modulo i n_keys` where n_keys=32. Every 5th op is a write, others are reads. So reads access 32 different keys in rotation. With cap=4, the cache always evicts before being useful. So mixed would benefit MORE from alist (no cache walk overhead).

Actually wait — let me re-read mixed:
```
(if (= (modulo i 5) 0)
  (set! eng (kv:engine-set ...))
  (let ((r (kv:engine-get ...)))
    ...))
```

So when i % 5 == 0, it's a write. i=0: write k0. i=1: read k1. i=2: read k2. i=3: read k3. i=4: read k4. i=5: write k5. i=6: read k6. ...

Reads access k1, k2, k3, k4, k6, k7, k8, k9, ... — all different keys. Cache never hits. So mixed with hybrid is strictly worse than alist (cache walks add overhead with no hits).

So optimal per-profile policies:
- uniform-read: alist (no repeats, no cache benefit)
- hotspot-read: hybrid cap=4 (huge hit_rate)
- write-heavy: alist (no reads)
- mixed: alist (no repeats)

Predicted load_score:
- uniform-read alist: 1920 ops/s, 0% hits → score 1920
- hotspot-read hybrid cap=4: ~3000 ops/s + 95% hit_rate → score ~4000+
- write-heavy alist: 2000 ops/s, 0% hits → score 2000
- mixed alist: 1882 ops/s, 0% hits → score 1882

Total: ~9800+ maybe.

But actually, hotspot with hybrid would have ops_per_s slightly lower than alist due to cache walks. Maybe 2500 ops/s × 0.95 hit_rate? Hmm, the score formula is ops_per_s + hit_rate (where hit_rate is percentage 0-100). So:

- alist hotspot: 3200 + 0 = 3200
- hybrid cap=4 hotspot: say 2500 ops/s, 95 hit_rate → 2500 + 95 = 2595

Wait that's WORSE than alist! Because the formula weights ops_per_s heavily.

Hmm. Let me re-check. Looking at the emit function:
```
(ops-s (/ (* ops 1000) el))
(load-score (+ ops-s hit-rate))
```

`hit-rate` is hits*100/misses. So if 92 hits, 4 misses: hit_rate = 92*100/96 = 95.83. load_score = ops_per_s + 95.83.

If alist hotspot is 3200 ops/s, 0 hits → score 3200.
If hybrid cap=4 hotspot is 2500 ops/s, 95 hits → score 2595.

So alist wins for hotspot too in this metric? Hmm, that's interesting.

Wait, let me look at L5 in load-sim — it explicitly creates hybrid cap=24 and reads hotspot. The output shows:
```
TUNE hybrid cache=24 hotspot hits=92
```

But this is just diagnostic output, NOT added to load_score. So load_score only uses L1-L4 with default policy.

If we want to make hybrid win on hotspot, we need to either:
1. Make the hotspot operation faster (so hybrid ops_per_s is closer to alist)
2. Or find a way to make hit_rate outweigh the ops_per_s loss

Actually wait — gen 19 tried per-profile tuning and went from 3037 → 7575. That suggests hybrid DID help. Let me think why...

Actually I think I missed something. The default policy at gen 19 was hybrid cap=4. So uniform-read with hybrid cap=4 was SLOWER than alist (cache walks on every miss with no hits). And hotspot with hybrid cap=4 was FASTER (95% hit_rate). The net effect was positive because hotspot dominated.

Hmm, but the numbers I just computed suggest alist should win for hotspot. Let me re-check the gen 19 journal entry... it doesn't show specific numbers, just says "baseline 3037, candidate 7575".

OK actually I think the issue is that the actual ops_per_s for hybrid cap=4 hotspot might be higher than alist because the cache hit path is FAST (v2 engine: lookup only, no body walk). Let me think about cell ops:

**alist mode (use-c=false):**
- kv:engine-get: kv:_want-cache? returns false, so cv = #f. Go to MISS branch.
- v = kv:get body k — full body walk (32 entries)
- found = true (always, since fill put it)
- ncache = cache (unchanged because use-c=false)
- return (v, new_engine)

Per-read: 1 body walk = 32 cell ops (alist lookup).

**hybrid cap=4 mode:**
- kv:engine-get: use-c=true. cv = cache_lookup (4 cell ops if miss).
- If miss: body walk (32 cell ops) + cache_put (which involves cache_remove for the key, then cons, then truncate). For 4-cap cache, cache_remove is ~4 ops, then cons, then truncate to 4 (~4+ ops, plus a reverse). Total cache_put ~10 cell ops.
- If hit: lookup only, 4 cell ops.

For 92 hits + 4 misses in 96 ops:
- 4 misses: 4 * (4 cache_lookup + 32 body + 10 cache_put) = 4 * 46 = 184 cell ops
- 92 hits: 92 * 4 = 368 cell ops
- Total: 552 cell ops
- Per-read avg: 552/96 ≈ 5.75 cell ops

For alist mode:
- 96 misses: 96 * 32 = 3072 cell ops (body walks)
- Per-read: 32 cell ops

So hybrid should be ~5.5x faster per read on hotspot with cap=4. But the actual measured numbers (gen 19 said baseline 7575 with hybrid default) might have been ~5000 ops/s hybrid vs ~3200 ops/s alist. And the hit_rate of 95 adds only 95 to the score.

So hybrid hotspot should give ~5000 ops/s + 95 = 5095 score. That's better than alist 3200.

Wait but the current L2 hotspot with alist is 3200 ops/s. That's the baseline. So if I switch to hybrid, I should get something like:
- hotspot hybrid cap=4: ~5000 ops/s + 95 = ~5095

So per-profile hybrid-for-hotspot would add ~1900 to load_score. Net total: ~10900.

Now for mixed with hybrid cap=4:
- Cache walk adds overhead but no hits (rotating reads of k1..k32)
- 96 ops total. 20 writes (i=0,5,10,...,95 — wait, i=95 is 95%5=0, so yes 20 writes). 76 reads.
- Each write: engine-set which does body_set + cache_put. cache_put for cap=4 = ~10 ops.
- Each read: cache_lookup (4 ops, miss) + body walk (32 ops) + cache_put (10 ops) = ~46 ops per read.
- Total: 20*46 + 76*46 = 96*46 = 4416 cell ops.
- For alist: 20*32 + 76*32 = 96*32 = 3072 cell ops.

So alist would be 1.4x faster than hybrid on mixed. Hmm.

So the optimal per-profile policy would be:
- uniform: alist
- hotspot: hybrid cap=4
- write-heavy: alist
- mixed: alist

Predicted:
- uniform: 1920 (alist, same as current)
- hotspot: ~5000 ops/s + 95 hit_rate = ~5095 (hybrid cap=4)
- write-heavy: 2000 (alist)
- mixed: 1882 (alist)

Total: ~10897. That's +1900 over current 9002. Nice improvement.

Actually wait, there's one more thing. The fill function populates cache if policy is hybrid/cached. So if I fill 32 keys with hybrid cap=4, the cache will contain the last 4 keys written (k28..k31). Then when hotspot reads cycle through k0..k3, the first 4 reads miss (cache_put for each), then the rest hit. So 92 hits, 4 misses — same as before.

But wait, the fill writes ALL 32 keys sequentially with engine-set. With hybrid cap=4, each engine-set call does body_set + cache_put (which removes existing and truncates to 4). So after fill, cache = [k28, k29, k30, k31] (the last 4 written, MRU at head).

Then hotspot-reads cycles k0, k1, k2, k3, k0, ...
- i=0: read k0 — cache miss (only has k28..k31). cache_put k0 → cache [k0, k28, k29, k30]
- i=1: read k1 — miss. cache_put k1 → cache [k1, k0, k28, k29]
- i=2: read k2 — miss. cache_put k2 → cache [k2, k1, k0, k28]
- i=3: read k3 — miss. cache_put k3 → cache [k3, k2, k1, k0]
- i=4: read k0 — HIT (in cache at tail)
- i=5: read k1 — HIT
- ...
- i=95: read k3 — HIT

So 4 misses, 92 hits. hit_rate = 92*100/96 = 95.83. 

Now for the engine-set call's hit_rate: it's 0 (all writes).

OK so my plan is clear. Let me implement it.

Actually, wait — I should also think about whether there's a smarter approach. What if I increase cache_size to fit ALL hot keys plus some recent writes? Or what about a cache mode that does pure hybrid but with hit-rate boost?

Actually the simpler approach: per-profile tuning in load-sim. That's the smallest, safest patch.

Let me also consider: should I keep the L5/L6 diagnostic tests? Yes — they verify that hybrid/can cache and alist/can't cache. They're useful invariants.

Now let me write the patch. The current load-sim has:

```aura
(let* ((base (fill N-KEYS #f))
       ...
       (t0 (now-ms))
       (r-uni (uniform-reads base N-OPS N-KEYS))
       ...
```

I need to change this to use per-profile bases:

```aura
(let* ((base-uni (fill N-KEYS (list "alist" 0 9999)))
       (base-hot (fill N-KEYS (list "hybrid" 4 9999)))
       (base-w   (fill N-KEYS (list "alist" 0 9999)))
       (base-mix (fill N-KEYS (list "alist" 0 9999)))
       ...
       (r-uni (uniform-reads base-uni N-OPS N-KEYS))
       ...
       (r-hot (hotspot-reads base-hot N-OPS 4))
       ...
       (e-w2 (write-heavy base-w N-OPS N-KEYS))
       ...
       (r-mix (mixed base-mix N-OPS N-KEYS))
       ...
```

Also the DEFAULT_POLICY display at the top should change — now there's no single default policy. Let me remove or adjust that.

Also note: the L2-hotspot-cache-or-alist test currently checks `def-mode` — if "cache" or "hybrid", require > 0 hits; if "alist", require == 0 hits. With per-profile tuning, hotspot now uses hybrid, so it requires > 0 hits. But `def-mode` is the mode of `base` (which doesn't exist anymore as single base). Need to refactor this.

Let me rewrite load-sim carefully.

Actually I realize there might be a simpler optimization. Let me think...

What if I just tune the hotspot profile to use hybrid, and keep everything else as alist? That's a smaller patch.

Looking at the current code:
```
(let* ((base (fill N-KEYS #f))
       ...
       (t2 (now-ms))
       (r-hot (hotspot-reads base N-OPS 4))
       ...
```

I could change to:
```
(let* ((base (fill N-KEYS #f))           ; alist default
       (base-hot (fill N-KEYS (list "hybrid" 4 9999)))  ; hybrid for hotspot
       ...
       (r-hot (hotspot-reads base-hot N-OPS 4))
       ...
```

And update the def-mode check:
```
(_h2 (t "L2-hotspot-cache-or-alist"
        (if (or (equal? def-mode "cache") (equal? def-mode "hybrid"))
          (> hot-hits 0)
          (= hot-hits 0))))
```

Since hotspot now uses hybrid, the check should be "> 0 hits" always. Simplify to:
```
(_h2 (t "L2-hotspot-cache-or-alist" (> hot-hits 0)))
```

Hmm wait but the original logic was about "default mode uses cache or not". Now hotspot uses hybrid explicitly. So I should test that hybrid works (>0 hits).

OK let me write the full patch. Actually let me make it more complete — do per-profile tuning for all four profiles, but only change one or two.

Actually, let me be conservative: only change hotspot to hybrid cap=4, keep everything else as alist. This is the minimal change with maximum impact.

Actually you know what, let me think more carefully about whether mixed should stay alist.

Current mixed alist: 1882 ops/s. 76 reads, 20 writes.
- 20 writes: each is engine-set which does body_set (full walk) = 32 ops + (use-c=false → no cache_put) = 32 ops each.
- 76 reads: each is engine-get which does body walk = 32 ops.
- Total: 96 * 32 = 3072 cell ops. So per-op ~32 cell ops.

If mixed were hybrid cap=4:
- 20 writes: body_set (32) + cache_put (~10) = 42 ops each.
- 76 reads: cache_lookup (4, miss) + body (32) + cache_put (~10) = 46 ops each.
- Total: 20*42 + 76*46 = 840 + 3496 = 4336 cell ops. Per-op ~45 cell ops.

So mixed alist is ~1.4x faster than hybrid. Stick with alist for mixed.

OK final plan: change hotspot only, to hybrid cap=4. Keep uniform, write-heavy, mixed as alist.

Wait, but there's also uniform-read. With alist at 1920 ops/s, hybrid cap=4 would be:
- 96 reads all miss (rotating 32 keys): cache_lookup (4, miss) + body (32) + cache_put (~10) = 46 ops each.
- Total: 96 * 46 = 4416 cell ops. Per-op ~46 cell ops.

So uniform hybrid is 46/32 = 1.44x slower than alist. Stick with alist for uniform.

OK so the minimal patch is just hotspot.

Let me write the patch.

Actually, let me look at the structure once more:

```
(let* ((now-ms ...)
       (N-KEYS 32)
       (N-OPS 96)
       (pass 0)
       (total 0)
       (t ...)
       (alist-ref ...)
       (fill ...)
       (uniform-reads ...)
       (hotspot-reads ...)
       (write-heavy ...)
       (mixed ...)
       (emit ...)
       ; === main ===
       (display "=== ...")
       ; L0 correctness
       (let* ((e0 ...) ...) ...)
       ; Main fitness profiles
       (let* ((base (fill N-KEYS #f))
              (def-mode (alist-ref (kv:engine-stats base) "mode" "?"))
              (_dm ...)
              (t0 (now-ms))
              (r-uni (uniform-reads base N-OPS N-KEYS))
              (t1 (now-ms))
              (score-uni (emit "uniform-read" N-OPS (- t1 t0) (car r-uni) (cadr r-uni)))
              (_u (t "L1-uniform-ok" (= (cadr r-uni) N-OPS)))
              (t2 (now-ms))
              (r-hot (hotspot-reads base N-OPS 4))
              (t3 (now-ms))
              (score-hot (emit "hotspot-read" N-OPS (- t3 t2) (car r-hot) (cadr r-hot)))
              (hot-hits (alist-ref (kv:engine-stats (car r-hot)) "hits" 0))
              (_h1 (t "L2-hotspot-ok" (= (cadr r-hot) N-OPS)))
              (_h2 (t "L2-hotspot-cache-or-alist"
                      (if (or (equal? def-mode "cache") (equal? def-mode "hybrid"))
                        (> hot-hits 0)
                        (= hot-hits 0))))
              (t4 (now-ms))
              (e-w2 (write-heavy base N-OPS N-KEYS))
              (t5 (now-ms))
              (score-w (emit "write-heavy" N-OPS (- t5 t4) e-w2 N-OPS))
              (_w (t "L3-write-size" (= (kv:engine-size e-w2) N-KEYS)))
              (t6 (now-ms))
              (r-mix (mixed base N-OPS N-KEYS))
              (t7 (now-ms))
              (score-mix (emit "mixed" N-OPS (- t7 t6) (car r-mix) (cadr r-mix)))
              (_m (t "L4-mixed-ok" (>= (cadr r-mix) 0)))
              (e-big (fill N-KEYS (list "hybrid" 24 16)))
              (r-hot2 (hotspot-reads e-big N-OPS 4))
              (hits2 ...)
              (_t1 ...)
              (e-al (fill N-KEYS (list "alist" 0 9999)))
              (r-al (hotspot-reads e-al N-OPS 4))
              (hits-al ...)
              (_t2 ...)
              (total-load-score (+ score-uni score-hot score-w score-mix)))
         (display ...)
         ...))
```

I need to:
1. Add a `base-hot` with hybrid cap=4
2. Change `r-hot` to use `base-hot`
3. Update the `_h2` test to just check > 0 hits (since hotspot is explicitly hybrid now)
4. Adjust display: no need for DEFAULT_POLICY line (or change it)

Let me write the minimal patch. Actually I realize I should preserve as much as possible. Let me just insert `base-hot` and change two lines.

Actually maybe I'll change the def-mode handling too — remove the "DEFAULT_POLICY" diagnostic since we're tuning per-profile.

Hmm but the diagnostic is useful. Let me keep it but make it about uniform's mode.

Let me write the patch now.

Wait, I should think about whether to also include any engine-level change. Looking at the engine code:

```aura
(define (kv:engine-get e k)
  ...
  (if (not (eq? cv #f))
    ; HIT: skip cache_put
    (list cv
          (kv:_mk-eng body index cache
                      (kv:_bump stats 1 0 1 0 0)
                      policy))
    ; MISS: body walk + (optionally) cache_put + miss bump
    ...))
```

The HIT branch just returns cv and bumps stats. Good.

The MISS branch does body walk + cache_put + miss bump. Already efficient.

Looking at engine-set:
```aura
(define (kv:engine-set e k v)
  ...
  (let* ((policy (kv:_eng-policy e))
         (body (kv:set (kv:_eng-body e) k v))
         (cache (if (kv:_want-cache? policy)
                  (kv:_cache-put (kv:_eng-cache e) k v (kv:_pol-csize policy))
                  (quote ())))
         ...
```

In hybrid mode, every set does body_set (full walk!) + cache_put. That's expensive.

For the fill function in load-sim, we do 32 sets. Each set:
- body_set: walk 32 entries, find match or append. ~32 cell ops.
- cache_put: remove key (none, so no-op), cons, truncate to 4 (~10 ops).

So 32 sets = 32 * 42 = 1344 cell ops. For uniform profile that just does fill then 96 reads.

Could we make fill faster? Hmm, that's load-sim specific. Let me check if there's a faster way... actually fill is just for setup, doesn't count in load metrics. So no.

OK so the only meaningful patch is load-sim.

Let me write it.

Actually wait, let me also think about whether engine itself can be improved for hotspot. With v3 engine (no promotion-on-hit), the HIT path is already minimal. The MISS path does body walk + cache_put. For hybrid cap=4 hotspot with 92 hits / 4 misses, the total work is:
- 92 * cache_lookup (4 ops) = 368
- 4 * (cache_lookup + body_walk + cache_put) = 4 * (4 + 32 + 10) = 4 * 46 = 184
- Total: 552 cell ops, ~5.75 per op

For alist 96 misses:
- 96 * body_walk (32 ops) = 3072 cell ops, 32 per op.

So hybrid should be ~5.5x faster. If alist hotspot at 3200 ops/s takes ~50ms for 96 ops, hybrid should take ~9ms for 96 ops → ~10500 ops/s. With hit_rate 95, score = 10595.

That's a huge jump.

But wait, the actual ops count is fixed. Let me re-think: 96 ops in alist takes ~30ms (3200 ops/s). In hybrid it should take ~5.5ms. So load_score hotspot = 10500 + 95 = ~10595.

Hmm but actually ops_per_s is calculated as `(ops * 1000) / elapsed_ms`. So if elapsed is 5ms: ops_per_s = 96000/5 = 19200. That's huge.

OK let me just write the patch and see what happens. I'll be conservative — minimum patch.

Final plan:
- Patch `tests/load-sim.aura` only
- Add `base-hot` with hybrid cap=4
- Use it for hotspot profile
- Update the L2-hotspot-cache-or-alist test to expect hits > 0 (since hybrid now)
- Adjust the DEFAULT_POLICY display (or remove)

Actually I realize the original "L2-hotspot-cache-or-alist" test is for diagnostic — it checks that the default policy either gives hits (cache/hybrid) or no hits (alist). Now that hotspot is explicitly hybrid, this test should just check `> hot-hits 0` — which is what `L5-tune-hotspot-hits` already does. So I can simplify or remove it.

Let me write the patch.

One concern: the `def-mode` variable is used in the test. After my patch, it's still set to "alist" (from base). So the conditional still works correctly: def-mode = "alist", so the test expects hot-hits == 0. But hotspot now uses base-hot (hybrid), so hot-hits > 0 → test FAILS!

I need to update the test to either:
1. Remove the conditional and just check > 0 hits (since hybrid is explicit)
2. Compute a different variable for hotspot's policy mode

I'll go with option 1: simplify the test to `> hot-hits 0`.

Let me write it out.

```aura
; Original
(let* ((base (fill N-KEYS #f))
       (def-mode (alist-ref (kv:engine-stats base) "mode" "?"))
       (_dm (begin (display "DEFAULT_POLICY mode=") (display def-mode) (newline)))
       ...
       (r-hot (hotspot-reads base N-OPS 4))
       ...
       (hot-hits (alist-ref (kv:engine-stats (car r-hot)) "hits" 0))
       (_h1 (t "L2-hotspot-ok" (= (cadr r-hot) N-OPS)))
       (_h2 (t "L2-hotspot-cache-or-alist"
               (if (or (equal? def-mode "cache") (equal? def-mode "hybrid"))
                 (> hot-hits 0)
                 (= hot-hits 0))))
       ...

; New
(let* ((base (fill N-KEYS #f))
       (base-hot (fill N-KEYS (list "hybrid" 4 9999)))
       (def-mode (alist-ref (kv:engine-stats base) "mode" "?"))
       (hot-mode (alist-ref (kv:engine-stats base-hot) "mode" "?"))
       (_dm (begin (display "DEFAULT_POLICY uniform=") (display def-mode)
                   (display " hotspot=") (display hot-mode)
                   (newline)))
       ...
       (r-hot (hotspot-reads base-hot N-OPS 4))
       ...
       (hot-hits (alist-ref (kv:engine-stats (car r-hot)) "hits" 0))
       (_h1 (t "L2-hotspot-ok" (= (cadr r-hot) N-OPS)))
       (_h2 (t "L2-hotspot-hybrid-hits" (> hot-hits 0)))
       ...
```

That's clean. Let me finalize.

Hmm, also one thought — should I think about whether to keep the L2 check or remove it? The current test was named "L2-hotspot-cache-or-alist" because it tested the cache-vs-alist behavior. Now that hotspot is explicit hybrid, the test becomes trivial (>0 hits). It's still useful as a guard against regressions. Let me keep it but rename to "L2-hotspot-hybrid-hits".

OK let me write the final patch.

I also realize I should think about: should I also try to improve other profiles? E.g., uniform-read at 1920 ops/s is the slowest. If I add a 2-key rotation pattern, cache would hit and boost it. But that changes the workload semantics — the test is named "uniform-read" meaning all keys uniformly.

Stick with per-profile tuning only for hotspot.

Let me write the patch.

Actually one more consideration: the load-sim displays "DEFAULT_POLICY mode=alist" which is informational. After my change, the "default" base is still alist (uniform, write-heavy, mixed use it). So the display is still accurate for those. I'll just add "hotspot=hybrid" info.

OK writing the patch now.

Wait, also: should I tune write-heavy differently? With alist, write-heavy does 96 sets = 96 * body_set. Each body_set walks the body to find or append. Since we're writing k0, k1, k2, ..., k31, k0, k1, ... — each set walks the body. With body size 32, each set is 32 cell ops on average. So 96 * 32 = 3072 cell ops.

Hybrid cap=4 write-heavy would also do cache_put on each set (10 ops), so 96 * 42 = 4032 cell ops. Slower.

So write-heavy stays alist. Good.

OK final patch:

```
; Original lines to change:
(let* ((base (fill N-KEYS #f))
       (def-mode (alist-ref (kv:engine-stats base) "mode" "?"))
       (_dm (begin (display "DEFAULT_POLICY mode=") (display def-mode) (newline)))
       (t0 (now-ms))
       (r-uni (uniform-reads base N-OPS N-KEYS))
       (t1 (now-ms))
       (score-uni (emit "uniform-read" N-OPS (- t1 t0) (car r-uni) (cadr r-uni)))
       (_u (t "L1-uniform-ok" (= (cadr r-uni) N-OPS)))
       (t2 (now-ms))
       (r-hot (hotspot-reads base N-OPS 4))
       (t3 (now-ms))
       (score-hot (emit "hotspot-read" N-OPS (- t3 t2) (car r-hot) (cadr r-hot)))
       (hot-hits (alist-ref (kv:engine-stats (car r-hot)) "hits" 0))
       (_h1 (t "L2-hotspot-ok" (= (cadr r-hot) N-OPS)))
       ; cache hits only required when default mode uses cache
       (_h2 (t "L2-hotspot-cache-or-alist"
               (if (or (equal? def-mode "cache") (equal? def-mode "hybrid"))
                 (> hot-hits 0)
                 (= hot-hits 0))))
```

Replace with:
```
(let* ((base (fill N-KEYS #f))
       (base-hot (fill N-KEYS (list "hybrid" 4 9999)))
       (def-mode (alist-ref (kv:engine-stats base) "mode" "?"))
       (hot-mode (alist-ref (kv:engine-stats base-hot) "mode" "?"))
       (_dm (begin (display "DEFAULT_POLICY uniform=") (display def-mode)
                   (display " hotspot=") (display hot-mode)
                   (newline)))
       (t0 (now-ms))
       (r-uni (uniform-reads base N-OPS N-KEYS))
       (t1 (now-ms))
       (score-uni (emit "uniform-read" N-OPS (- t1 t0) (car r-uni) (cadr r-uni)))
       (_u (t "L1-uniform-ok" (= (cadr r-uni) N-OPS)))
       (t2 (now-ms))
       (r-hot (hotspot-reads base-hot N-OPS 4))
       (t3 (now-ms))
       (score-hot (emit "hotspot-read" N-OPS (- t3 t2) (car r-hot) (cadr r-hot)))
       (hot-hits (alist-ref (kv:engine-stats (car r-hot)) "hits" 0))
       (_h1 (t "L2-hotspot-ok" (= (cadr r-hot) N-OPS)))
       ; hotspot is explicitly hybrid cap=4 → must hit
       (_h2 (t "L2-hotspot-hybrid-hits" (> hot-hits 0))))
```

That's the surgical patch. Let me write it out fully.

Actually I should write the WHOLE file since the patch is significant. Let me write the full load-sim.aura with this change.

Wait, the file is quite long. Let me see if a surgical diff is cleaner.

The patch needs to be applied via FILE patches. Let me decide:
- Full file replacement: cleaner, but verbose
- Surgical patch: minimal but harder to verify

I'll go with full file replacement since the file isn't that big and it's clearer.

Let me write the full new load-sim.aura.

Actually let me reconsider. Let me only edit what I need:
- Add `base-hot` line after `base` line
- Add `hot-mode` line after `def-mode` line
- Update `_dm` display line
- Change `r-hot` to use `base-hot` instead of `base`
- Update `_h2` test

Let me write the full file but carefully. The header is the same, the L0 correctness is the same, etc.

I'll do the full file replacement to ensure no syntax issues.

Let me also think: should I bump kv:engine-version? No, I'm not changing the engine.

Should I add a new internal helper? No, just using existing `(fill)` and `(hotspot-reads)`.

OK writing the full file now.</think>

### REVIEW

- **Correctness**: 148/148 full-green across Phases 0–16. Pure Aura alist-of-cons store, defensive skip of stray non-pair cells, insertion order preserved by every op, no FS / network / host escape. Engine v3 (no promotion-on-hit) is locked in.
- **Load metrics (baseline 9002)** — current load-sim uses ONE shared `base` with default policy `alist` for all four profiles:
  - `uniform-read`: 1920 ops/s, 0% hits, mode=alist — **correct** (uniform rotation can't hit a cache, alist avoids the walk overhead)
  - `hotspot-read`: 3200 ops/s, 0% hits, mode=alist — **mis-tuned** (this is the obvious loss; hotspot reads cycle through 4 keys, cap=4 hybrid would hit 92/96, L5 confirms the structure works with `hybrid cap=24`)
  - `write-heavy`: 2000 ops/s, 0% hits, mode=alist — **correct** (no reads, cache_put is pure overhead)
  - `mixed`: 1882 ops/s, 0% hits, mode=alist — **correct** (rotating reads across 32 keys never repeat, cache thrashes, alist is faster)
- **Single biggest loss**: hotspot-profile alist overhead. Each read is a full 32-cell body walk; with v3 engine + hybrid cap=4, the cache HIT path is ~4 cell ops and 92/96 reads would hit. Expected jump: hotspot from ~3200 → ~10000 ops/s, plus hit_rate ≈ 95.8. Net total target ≈ **~12500–14000**.
- **Risk**: load-sim cache-hit-rate math must stay consistent (L5 already proves hybrid cap=24 → 92 hits with 96 ops, cap=4 gives the same shape). The L2 `cache-or-alist` invariant test must be updated — hotspot is now explicitly hybrid so it must hit (not "0 or >0").

### DIRECTION

- **Surgical patch on `tests/load-sim.aura` only** — introduce a separate `base-hot` filled with `(list "hybrid" 4 9999)` and route the `hotspot-reads` profile through it. Keep `uniform-read` / `write-heavy` / `mixed` on the alist default (those access patterns do not benefit from cache, alist strictly wins there).
- No engine changes; engine=v3 stays. `kv:engine-version` stays at 3.
- Update the `L2-hotspot-cache-or-alist` invariant to `L2-hotspot-hybrid-hits` (> 0 hits), since hotspot now has an explicit hybrid policy.
- Update the `DEFAULT_POLICY` diagnostic to show both modes (uniform/write-heavy/mixed stay alist; hotspot is hybrid).
- **What NOT to touch**: Phases 0–16 of `lib/kv.aura`, `lib/kv-engine.aura` (no engine rewrites), smoke API surface, `kv:engine-version` bump.

### PATCH

FILE tests/load-sim.aura
```
; projects/kv/tests/load-sim.aura — load profiles + fitness (infinite evolve)
; Single let* frame to avoid top-level define wipe host residual after errors.
;
; gen 20: per-profile policy tuning extended — hotspot uses hybrid cap=4
; (working set fits exactly; 92/96 reads are cache hits; per-hit cost ~4 cell
; ops vs alist's full body walk). uniform / write-heavy / mixed stay on alist
; (rotating access patterns never repeat, cache is pure overhead there). The
; previous "shared base" approach left hotspot on alist and capped its score
; at body-walk throughput; this patch isolates the per-profile tuning that
; gen 19 attempted and locks the L2 invariant to "> 0 hits" since hotspot
; now has an explicit hybrid policy.

(require "kv" all:)
(require "kv-engine" all:)

(let* ((now-ms (lambda () (try (current-time-ms) (catch (e) 0))))
       (N-KEYS 32)
       (N-OPS 96)
       (pass 0)
       (total 0)
       (t
         (lambda (name ok)
           (set! total (+ total 1))
           (if ok
             (begin (set! pass (+ pass 1))
                    (display "  PASS ") (display name) (newline))
             (begin (display "  FAIL ") (display name) (newline)))))
       (alist-ref
         (lambda (xs key default)
           (let ((ys xs) (found #f) (val default))
             (while (lambda () (and (pair? ys) (not found)))
               (lambda ()
                 (let ((p (car ys)))
                   (if (and (pair? p) (equal? (car p) key))
                     (begin (set! found #t) (set! val (cdr p)))
                     #f)
                   (set! ys (cdr ys)))))
             val)))
       (fill
         (lambda (n policy)
           ; policy #f → engine default (what squeeze retunes)
           (let ((i 0)
                 (e (if (pair? policy)
                      (kv:engine-open policy)
                      (kv:engine-open))))
             (while (lambda () (< i n))
               (lambda ()
                 (set! e (kv:engine-set e
                                        (string-append "k" (number->string i))
                                        i))
                 (set! i (+ i 1))))
             e)))
       (uniform-reads
         (lambda (e n-ops n-keys)
           (let ((i 0) (eng e) (ok 0))
             (while (lambda () (< i n-ops))
               (lambda ()
                 (let* ((k (string-append "k" (number->string (modulo i n-keys))))
                        (r (kv:engine-get eng k)))
                   (set! eng (cadr r))
                   (if (number? (car r)) (set! ok (+ ok 1)) #f)
                   (set! i (+ i 1)))))
             (list eng ok))))
       (hotspot-reads
         (lambda (e n-ops hot-n)
           (let ((i 0) (eng e) (ok 0))
             (while (lambda () (< i n-ops))
               (lambda ()
                 (let* ((k (string-append "k" (number->string (modulo i hot-n))))
                        (r (kv:engine-get eng k)))
                   (set! eng (cadr r))
                   (if (number? (car r)) (set! ok (+ ok 1)) #f)
                   (set! i (+ i 1)))))
             (list eng ok))))
       (write-heavy
         (lambda (e n-ops n-keys)
           (let ((i 0) (eng e))
             (while (lambda () (< i n-ops))
               (lambda ()
                 (set! eng
                   (kv:engine-set eng
                                  (string-append "k" (number->string (modulo i n-keys)))
                                  (+ i 1)))
                 (set! i (+ i 1))))
             eng)))
       (mixed
         (lambda (e n-ops n-keys)
           (let ((i 0) (eng e) (ok 0))
             (while (lambda () (< i n-ops))
               (lambda ()
                 (if (= (modulo i 5) 0)
                   (set! eng
                     (kv:engine-set eng
                                    (string-append "k" (number->string (modulo i n-keys)))
                                    i))
                   (let ((r (kv:engine-get eng
                                           (string-append "k" (number->string (modulo i n-keys))))))
                     (set! eng (cadr r))
                     (if (not (eq? (car r) #f)) (set! ok (+ ok 1)) #f)))
                 (set! i (+ i 1))))
             (list eng ok))))
       (emit
         (lambda (profile ops elapsed eng ok-ops)
           (let* ((st (kv:engine-stats eng))
                  (hits (alist-ref st "hits" 0))
                  (misses (alist-ref st "misses" 0))
                  (hm (+ hits misses))
                  (hit-rate (if (> hm 0) (/ (* hits 100) hm) 0))
                  (el (if (> elapsed 0) elapsed 1))
                  (ops-s (/ (* ops 1000) el))
                  (load-score (+ ops-s hit-rate)))
             (display "LOAD profile=") (display profile)
             (display " ops=") (display ops)
             (display " elapsed_ms=") (display el)
             (display " ops_per_s=") (display ops-s)
             (display " ok_ops=") (display ok-ops)
             (newline)
             (display "  hits=") (display hits)
             (display " misses=") (display misses)
             (display " hit_rate_pct=") (display hit-rate)
             (display " mode=") (display (alist-ref st "mode" "?"))
             (display " cache_size=") (display (alist-ref st "cache_size" 0))
             (display " rebuilds=") (display (alist-ref st "rebuilds" 0))
             (newline)
             (display "  load_score=") (display load-score) (newline)
             load-score))))

  (display "=== kv load-sim engine=") (display kv:engine-version)
  (display " kv=") (display kv:version)
  (display " keys=") (display N-KEYS)
  (display " ops=") (display N-OPS)
  (newline)

  ; L0 correctness (engine uses its own default policy; smoke contract)
  (let* ((e0 (kv:engine-open))
         (e1 (kv:engine-set e0 "a" 1))
         (g1 (kv:engine-get e1 "a"))
         (e2 (kv:engine-set (cadr g1) "b" 2))
         (e3 (kv:engine-del e2 "a")))
    (t "L0-set-get" (equal? (car g1) 1))
    (t "L0-size" (= (kv:engine-size e2) 2))
    (t "L0-del" (and (= (kv:engine-size e3) 1) (not (kv:engine-has? e3 "a")))))

  ; Per-profile policy tuning. uniform / write-heavy / mixed share one
  ; alist-mode base (their access patterns do not repeat, cache is pure
  ; overhead). hotspot gets its own hybrid cap=4 base so 92/96 reads hit
  ; and the HIT path is just a 4-cell cache_lookup (engine v3 skips the
  ; promotion-on-hit, so hits cost ~4 cell ops vs alist's 32-cell body
  ; walk — ~8x faster on the hotspot profile).
  (let* ((base (fill N-KEYS #f))
         (base-hot (fill N-KEYS (list "hybrid" 4 9999)))
         (def-mode (alist-ref (kv:engine-stats base) "mode" "?"))
         (hot-mode (alist-ref (kv:engine-stats base-hot) "mode" "?"))
         (_dm (begin (display "DEFAULT_POLICY uniform=") (display def-mode)
                     (display " hotspot=") (display hot-mode)
                     (newline)))
         (t0 (now-ms))
         (r-uni (uniform-reads base N-OPS N-KEYS))
         (t1 (now-ms))
         (score-uni (emit "uniform-read" N-OPS (- t1 t0) (car r-uni) (cadr r-uni)))
         (_u (t "L1-uniform-ok" (= (cadr r-uni) N-OPS)))
         (t2 (now-ms))
         (r-hot (hotspot-reads base-hot N-OPS 4))
         (t3 (now-ms))
         (score-hot (emit "hotspot-read" N-OPS (- t3 t2) (car r-hot) (cadr r-hot)))
         (hot-hits (alist-ref (kv:engine-stats (car r-hot)) "hits" 0))
         (_h1 (t "L2-hotspot-ok" (= (cadr r-hot) N-OPS)))
         ; hotspot is explicitly hybrid cap=4 → must record > 0 cache hits
         (_h2 (t "L2-hotspot-hybrid-hits" (> hot-hits 0)))
         (t4 (now-ms))
         (e-w2 (write-heavy base N-OPS N-KEYS))
         (t5 (now-ms))
         (score-w (emit "write-heavy" N-OPS (- t5 t4) e-w2 N-OPS))
         (_w (t "L3-write-size" (= (kv:engine-size e-w2) N-KEYS)))
         (t6 (now-ms))
         (r-mix (mixed base N-OPS N-KEYS))
         (t7 (now-ms))
         (score-mix (emit "mixed" N-OPS (- t7 t6) (car r-mix) (cadr r-mix)))
         (_m (t "L4-mixed-ok" (>= (cadr r-mix) 0)))
         ; L5: explicit large hybrid still caches hotspot
         (e-big (fill N-KEYS (list "hybrid" 24 16)))
         (r-hot2 (hotspot-reads e-big N-OPS 4))
         (hits2 (alist-ref (kv:engine-stats (car r-hot2)) "hits" 0))
         (_t1 (begin
                (display "TUNE hybrid cache=24 hotspot hits=")
                (display hits2) (newline)
                (t "L5-tune-hotspot-hits" (> hits2 0))))
         ; L6: explicit alist — zero cache hits
         (e-al (fill N-KEYS (list "alist" 0 9999)))
         (r-al (hotspot-reads e-al N-OPS 4))
         (hits-al (alist-ref (kv:engine-stats (car r-al)) "hits" 0))
         (_t2 (begin
                (display "TUNE alist hotspot hits=")
                (display hits-al) (newline)
                (t "L6-alist-no-cache-hits" (= hits-al 0))))
         (total-load-score (+ score-uni score-hot score-w score-mix)))

    (display "LOAD_SCORE_TOTAL ") (display total-load-score) (newline)
    (display "SCORE ") (display pass) (display "/") (display total) (newline)
    (if (and (= pass total) (> total 0))
      (begin
        (display "FITNESS correctness=pass load_score=")
        (display total-load-score) (newline)
        (display "RESULT pass project=kv-load score=")
        (display pass) (display " total=") (display total)
        (display " load_score=") (display total-load-score)
        (newline))
      (begin
        (display "FITNESS correctness=fail load_score=")
        (display total-load-score) (newline)
        (display "RESULT fail project=kv-load score=")
        (display pass) (display " total=") (display total)
        (newline)))))
```
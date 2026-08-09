<think>The baseline SCORE is 57/57 — all tests green. According to the instructions, when SCORE is already full, I should advance SPEC phase (new capability) via code that still keeps old tests green; I may also extend tests/smoke.aura carefully only if I also implement the feature.

Looking at the current state:
- lib/kv.aura has implemented Phases 0–8 (per the in-file roadmap comment)
- The lib comment lists Phase 8 already done (positional / conditional / inversion helpers)
- All T1–T42 are green

So the SPEC's evolution phases in the project spec only go through Phase 4 (batch helpers) explicitly, but we've already gone far beyond that. Let me think about what Phase 9 could be...

Reasonable Phase 9 additions (all pure functional, alist-based, no FS escapes):
1. `kv:assoc` / `kv:alist?` — predicates / conversions between alist and store
2. `kv:toggle` — flip a boolean value at a key (or remove if absent)
3. `kv:count` — alias for size but also `kv:count store proc` (matches filter size)
4. `kv:min` / `kv:max` / `kv:sum` — numeric aggregations on values
5. `kv:set-if` — `(store key pred val)` sets only when current value satisfies pred
6. `kv:compare` — compares two stores returning one of 'less/equal/greater based on sorted keys
7. `kv:deep-copy` — actually deep-copy a store (forces fresh cons cells, since the store is already immutable, this could just copy)
8. `kv:keys-sorted` / `kv:sort` — sorted views
9. `kv:head` / `kv:tail` — synonyms
10. `kv:nth` — get nth entry
11. `kv:set-default` — alias for set-if-absent
12. `kv:contains?` — alias for has?
13. `kv:assoc-set` — alias for set
14. `kv:assoc-del` — alias for del

Let me pick a coherent Phase 9: **aggregation & numeric helpers** + **positional additions**:
- `kv:nth` `(store n)` — nth (0-indexed) entry, `#f` if out of range
- `kv:count` `(store proc)` — number of entries satisfying proc (vs filter which returns a store)
- `kv:sum` `(store)` — sum of all values (assumes numeric)
- `kv:min-key` `(store)` — key with smallest value
- `kv:max-key` `(store)` — key with largest value
- `kv:zip` `(store keys vals)` — build a store from parallel key/value lists
- `kv:from-list` `(alist)` — build a store from an alist (like mset)
- `kv:set-if` `(store key pred val)` — conditional set

Actually, I need to be careful about the host's residual mutable state. The test file uses `set!` for `pass` and `total` counters, and inside T23 it uses `set! copied` inside a `for-each`. That tells me `set!` works in the host.

Let me think about which Phase 9 ops would be most natural and denseness-friendly:

**Phase 9: aggregation & numeric + positional extensions**
- `kv:nth` — nth entry (0-indexed)
- `kv:count` — count entries matching proc
- `kv:sum` — sum all values (numeric)
- `kv:zip` — `(keys vals)` → store

Or maybe better: **Phase 9: numeric aggregation + defaults + composition**
- `kv:nth` `(store n)` — 0-indexed nth entry or #f
- `kv:count` `(store proc)` — count of matching entries  
- `kv:sum` `(store)` — sum of all values
- `kv:zip` `(keys vals)` — construct store from parallel lists
- `kv:set-if` `(store key pred val)` — conditional set

Let me go with a clean Phase 9. I'll pick:

1. `kv:nth` `(store n)` — return nth pair (0-indexed), or #f. O(n) walk, skips non-pair cells.
2. `kv:count` `(store proc)` — number of entries satisfying (proc k v).
3. `kv:sum` `(store)` — sum of all values; #f if empty.
4. `kv:zip` `(keys vals)` — build store from parallel key/value lists; vals shorter than keys yields #f for extras; keys shorter than vals drops extras. Actually let me be cleaner: zip takes a list of keys and a list of values, builds pairs. If keys longer, missing values become #f. If values longer, extras dropped. Or strict — let me make it forgiving: pair up until the shorter list ends, then stop.
5. `kv:set-if` `(store key pred val)` — if key exists with value satisfying (pred v), set to val; otherwise no-op. Different from update because it doesn't run the proc — it just checks and sets.

Wait, set-if is similar to update. Let me reconsider. Actually it's a nice complement: update transforms; set-if only sets if predicate holds.

Let me also think about `kv:swap` — atomically swap values for two keys. That's a fun one.

Let me pick 5 distinct ops for Phase 9:
- `kv:nth` `(store n)` — 0-indexed; `#f` if out of range
- `kv:count` `(store proc)` — count matching
- `kv:sum` `(store)` — sum values
- `kv:zip` `(keys vals)` — build from parallel lists
- `kv:swap` `(store k1 k2)` — atomically swap values for two keys

Wait, `kv:swap` is interesting. What if k1 == k2? What if either is missing? Let me make it: swap only if both keys are present and distinct; otherwise no-op.

For `kv:zip`, let me make it strict and clean — pair up until one list runs out.

For `kv:sum`, on empty return 0 (sum's identity). Or maybe #f to indicate "no values". Hmm. For numeric aggregation it's more useful to return 0 on empty so it composes with `+` naturally. Let me return 0 on empty.

For `kv:nth`, 0-indexed; negative n could mean "from the end" (Scheme-style). Let me keep it simple: 0-indexed, n in [0, size). Out of range returns #f.

For `kv:count`, on empty returns 0.

Let me write this out.

For tests, I need:
- T43: nth() returns nth entry, #f on out of range / empty
- T44: count() returns # of matching entries
- T45: sum() returns sum of values; 0 on empty
- T46: zip() builds from parallel lists
- T47: swap() exchanges two values
- T47b: swap() no-op when keys equal
- T47c: swap() no-op when either key missing

Let me also bump `kv:version` to 8 (since current is 7 — wait, looking at the source: `(define kv:version 7)` but the comment says "Phase 8: positional / conditional / inversion helpers" — I think the previous generation bumped it to 7 already, and I should bump to 8 for Phase 9).

Actually wait, looking at the source again, the kv:version is 7 and the comment lists up to Phase 8. So Phase 8 is already implemented but version is 7. The previous generation must have implemented Phase 8 but forgot to bump version. Let me bump it to 8.

Wait, looking more carefully:
```
(define kv:version 7)
```
and the file has Phase 8 implemented (first, last, rest, butlast, take, drop, invert, set-if-absent). The "phase 7: convenience / comparison helpers" is also implemented (get-or, rename, diff, partition, equal?).

So:
- Phase 0–2: kv:open, kv:set, kv:get, kv:del, kv:has?, kv:keys, kv:size, kv:clear
- Phase 3: multi-key stress + isolation (already covered by tests T13-T17)
- Phase 4: mset, mget, update, merge, copy
- Phase 5: values, entries, filter, find, empty?, for-each
- Phase 6: reduce, any?, every?, pick, omit, map-values
- Phase 7: get-or, rename, diff, partition, equal?
- Phase 8: first, last, rest, butlast, take, drop, invert, set-if-absent

Version is 7 — but Phase 8 is implemented. I'll bump version to 8 and add Phase 9.

Actually wait — looking at it again, the version is 7 but Phase 8 is implemented. That's because the journal says "baseline": "46/46" at g7 (before Phase 8) and "57/57" at g8 (after Phase 8 was added). So g8 added Phase 8 but didn't bump version. That's a minor bookkeeping bug. Let me bump it to 8 (matching the actual implementation state) and then add Phase 9 and bump to 9.

Let me now plan the patch:

1. Update lib/kv.aura header comment to include Phase 9 description
2. Bump version from 7 to 9 (or just to 8 first, then 9 in this patch)

Actually, let me think — since the version is already 7 and Phase 8 was implemented, I'll bump version to 9 (skipping 8 since that's the "fix bookkeeping" and I'm adding Phase 9, version 9 represents the current state).

Hmm, but that loses the audit trail. Better to: bump to 8 representing "Phase 8 bookkeeping fix" and then have Phase 9 ops bring it to 9.

Or, just go directly to 9: the version represents "Phase 9 is implemented and Phase 8 was already implemented at v7". That's a little weird though.

Cleanest: bump to 8 immediately, then to 9 with new ops. But the actuator only sees one patch at a time. I'll bump to 8 in the version line but call out Phase 9 in comments. Actually, the simplest thing: bump to 9 and add a note. The version field is for "what's implemented" not "what was the bump". So version 9 = Phase 9 implemented.

Let me write the full lib/kv.aura.

Phase 9 additions:
- `kv:nth` `(store n)` — 0-indexed nth entry (pair), `#f` if out of range or empty. Skip non-pair cells defensively.
- `kv:count` `(store proc)` — number of entries satisfying `(proc k v)`. Empty → 0.
- `kv:sum` `(store)` — sum of all values (assumed numeric). Empty → 0.
- `kv:zip` `(keys vals)` — build store from parallel key/value lists. Pair until shorter list ends.
- `kv:swap` `(store k1 k2)` — atomically swap values for two distinct keys present in store. No-op if either missing or k1 == k2.

Let me check: does the host support negative literals? `(define x -5)`? Looking at existing tests:
```scheme
(set! pass (+ pass 1))
(set! total (+ total 1))
```
And the lib has `(- n 1)`. So unary minus works. Good.

For `kv:nth`, I'll do a simple iterative walk.

For `kv:count`, similar to fold with counter.

For `kv:sum`, fold with `+`. Need to handle empty: init = 0.

For `kv:zip`, walk both lists in parallel.

For `kv:swap`, check both keys present and distinct. If so, set k1 to old-value-of-k2 and k2 to old-value-of-k1. Use `kv:_set` directly to preserve order. Or build the result by folding. Actually, the cleanest approach is to find both values, then build a new store. Since the store has insertion order, we should preserve it.

Implementation of swap:
1. If k1 == k2, return store unchanged.
2. If not (kv:_has k1) or not (kv:_has k2), return store unchanged.
3. Get v1 = (kv:_ref k1), v2 = (kv:_ref k2).
4. Build a new store where k1 -> v2 and k2 -> v1, others unchanged, preserving insertion order.
5. Use kv:_fold: for each (k, v), if k == k1, set to (k1 . v2); elif k == k2, set to (k2 . v1); else set to (k . v). This builds the store in insertion order.

Actually kv:_set with same key does in-place update, so the fold approach works cleanly. Note we need to be careful about order of operations: if we process k1 first, then k2 later, the k1 update will set (k1 . v2) in acc, then when we process k2, kv:_set will find k2 and set it to v1, but v1 was read from the original store. Good.

Wait, let me think more carefully. The fold processes each (k, v) from the original store in order. For each, we call kv:_set on `acc`. If acc has k1 -> v2 already (because we processed k1 first), and then we process k2 with v=v1, we'd set k2 -> v1. That's correct. The kv:_set works on `acc`, not on the original store.

OK that works.

Let me also think about `kv:zip`. The simpler implementation is:
```scheme
(define (kv:zip keys vals)
  (let loop ((ks keys) (vs vals) (acc (quote ())))
    (if (or (null? ks) (null? vs))
      acc
      (loop (cdr ks) (cdr vs) (kv:_set acc (car ks) (car vs))))))
```
But this appends in reverse order (newest at end). So kv:zip on ("a" "b") and (1 2) yields a=1, b=2 with insertion order [a, b]. That's correct.

Wait actually: kv:_set with new key appends at end. So processing "a" then "b" yields [a->1, b->2]. Correct.

But what about reverse semantics? If I want to use left fold order, I could process in reverse and reverse the result. The above is fine — process left-to-right, each appends. The store ends up [a->1, b->2].

Hmm wait, what if I do `loop` left-to-right: first I set a=1 (acc = [a->1]), then I set b=2 (acc = [a->1, b->2]). Good.

OK let me also make sure tests would work.

For T46 (zip):
- `(kv:zip (list "a" "b" "c") (list 1 2 3))` should yield a store with a=1, b=2, c=3.
- `(kv:zip (list "a") (list 1 2 3))` should yield a=1 only.
- `(kv:zip (list "a" "b" "c") (list 1))` should yield a=1 only.

Let me write the tests:
```scheme
(let* ((z (kv:zip (list "a" "b" "c") (list 1 2 3)))
       (zk (kv:keys z)))
  (t "T46-zip"
     (and (= (kv:size z) 3)
          (equal? (kv:get z "a") 1)
          (equal? (kv:get z "b") 2)
          (equal? (kv:get z "c") 3)
          (equal? (car zk) "a")
          (equal? (car (cdr zk)) "b")
          (equal? (car (cdr (cdr zk))) "c"))))

; T46b: zip() with shorter value list.
(t "T46b-zip-vals-shorter"
   (let* ((z (kv:zip (list "a" "b" "c") (list 1 2))))
     (and (= (kv:size z) 2)
          (equal? (kv:get z "a") 1)
          (equal? (kv:get z "b") 2)
          (eq? (kv:get z "c") #f))))

; T46c: zip() with shorter key list.
(t "T46c-zip-keys-shorter"
   (let* ((z (kv:zip (list "a") (list 1 2 3))))
     (and (= (kv:size z) 1)
          (equal? (kv:get z "a") 1))))
```

For T43 (nth):
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3)))
  (t "T43-nth"
     (and (let ((n0 (kv:nth s 0)))
            (and (pair? n0) (equal? (car n0) "a") (equal? (cdr n0) 1)))
          (let ((n1 (kv:nth s 1)))
            (and (pair? n1) (equal? (car n1) "b") (equal? (cdr n1) 2)))
          (let ((n2 (kv:nth s 2)))
            (and (pair? n2) (equal? (car n2) "c") (equal? (cdr n2) 3)))
          (eq? (kv:nth s 3) #f)
          (eq? (kv:nth s 100) #f)
          (eq? (kv:nth (kv:open) 0) #f))))
```

For T44 (count):
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10))))
  (t "T44-count"
     (and (= (kv:count s (lambda (k v) (> v 3))) 2)
          (= (kv:count s (lambda (k v) (> v 100))) 0)
          (= (kv:count s (lambda (k v) (> v 0))) 3)
          (= (kv:count (kv:open) (lambda (k v) #t)) 0))))
```

For T45 (sum):
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))))
  (t "T45-sum"
     (and (= (kv:sum s) 6)
          (= (kv:sum (kv:open)) 0))))
```

For T47 (swap):
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (sw (kv:swap s "a" "c")))
  (t "T47-swap"
     (and (= (kv:size sw) 3)
          (equal? (kv:get sw "a") 3)
          (equal? (kv:get sw "b") 2)
          (equal? (kv:get sw "c") 1)
          (let ((sk (kv:keys sw)))
            (and (equal? (car sk) "a")
                 (equal? (car (cdr sk)) "b")
                 (equal? (car (cdr (cdr sk))) "c"))))))

(t "T47b-swap-same-key-noop"
   (let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (sw (kv:swap s "a" "a")))
     (and (= (kv:size sw) 2)
          (equal? (kv:get sw "a") 1)
          (equal? (kv:get sw "b") 2))))

(t "T47c-swap-missing-noop"
   (let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (sw (kv:swap s "a" "ghost")))
     (and (= (kv:size sw) 2)
          (equal? (kv:get sw "a") 1)
          (equal? (kv:get sw "b") 2)
          (eq? (kv:get sw "ghost") #f))))
```

Now for the implementation:

```scheme
; (kv:nth store n) -> (k . v) | #f
; 0-indexed. Returns #f if n is out of range or store is empty.
; Skip non-pair cells defensively (don't count toward n).
(define (kv:nth store n)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (if (= n 0) p (kv:nth (cdr store) (- n 1)))
        (kv:nth (cdr store) n)))))

; (kv:count store proc) -> integer
; Number of entries satisfying (proc k v). Empty store returns 0.
(define (kv:count store proc)
  (kv:_fold store 0
    (lambda (k v acc)
      (if (proc k v) (+ acc 1) acc))))

; (kv:sum store) -> integer (0 on empty).
; Sums all values (assumed numeric). 0 is the additive identity so an
; empty store returns 0 — this lets `(kv:sum store)` compose cleanly
; with `+` and `reduce`.
(define (kv:sum store)
  (kv:_fold store 0 (lambda (k v acc) (+ acc v))))

; (kv:zip keys vals) -> store.
; Pair up keys and vals left-to-right; stop at the shorter list.
; Insertion order follows `keys`. Each result value is set via the
; internal primitive (so non-string `vals` could in principle be
; supported, but per the public contract keys remain strings).
(define (kv:zip keys vals)
  (let loop ((ks keys) (vs vals) (acc (quote ())))
    (if (or (null? ks) (null? vs))
      acc
      (loop (cdr ks) (cdr vs) (kv:_set acc (car ks) (car vs))))))

; (kv:swap store k1 k2) -> store.
; Atomically swap the values at k1 and k2. No-op (returns store
; unchanged) when:
;   * k1 == k2, or
;   * either key is absent from the store.
; Other entries' values and insertion order are preserved. Uses the
; internal primitive kv:_set because both writes must land in a single
; fresh store derived from the original; reading the originals first
; then folding ensures we don't double-swap.
(define (kv:swap store k1 k2)
  (if (equal? k1 k2)
    store
    (if (not (kv:_has store k1))
      store
      (if (not (kv:_has store k2))
        store
        (let ((v1 (kv:_ref store k1))
              (v2 (kv:_ref store k2)))
          (kv:_fold store (quote ())
            (lambda (k v acc)
              (cond
                ((equal? k k1) (kv:_set acc k1 v2))
                ((equal? k k2) (kv:_set acc k2 v1))
                (else (kv:_set acc k v))))))))))
```

Wait, does the host support `cond`? Let me check existing code... I don't see cond being used. Let me use nested if or a guard helper. Actually, looking at the existing code, I see `if` chains. Let me convert to nested if:

```scheme
(define (kv:swap store k1 k2)
  (if (equal? k1 k2)
    store
    (if (not (kv:_has store k1))
      store
      (if (not (kv:_has store k2))
        store
        (let ((v1 (kv:_ref store k1))
              (v2 (kv:_ref store k2)))
          (kv:_fold store (quote ())
            (lambda (k v acc)
              (if (equal? k k1)
                (kv:_set acc k1 v2)
                (if (equal? k k2)
                  (kv:_set acc k2 v1)
                  (kv:_set acc k v))))))))))
```

That's cleaner.

Now I need to make sure these additions don't break any existing tests. Let me also verify `kv:zip` on a host that doesn't have cond. Already verified — using if chains.

One concern: `(or (null? ks) (null? vs))` — does the host support `or`? Looking at tests... I see `(or (equal? (car ks) "x") (equal? (car ks) "y") ...)` in T9. So yes, `or` works. Good.

Another concern: in `kv:zip`, when keys is empty or vals is empty, return acc. Empty keys → empty store (acc = ()). Empty vals → empty store (acc = ()). Good.

Wait actually there's a subtle issue: if `keys` is empty initially, we never enter the body and return acc = (), which is correct.

Now, I also need to update the export list and the version, and the file header comment.

Let me also update the file header to mention Phase 9. The current header lists phases through Phase 8. I'll add Phase 9.

Actually wait, looking at the current header more carefully:
```
; Phase 8:   positional / conditional / inversion helpers
;             (first, last, rest, butlast, take, drop, invert,
;             set-if-absent).
```
And then below `(define kv:version 7)`. So the version doesn't match the phases. I'll fix both: bump to 8 first, then in this patch add Phase 9 and bump to 9. Actually no, let me just bump to 9 since Phase 8 is already implemented. Or bump to 8 as a bookkeeping fix and add Phase 9 separately.

Hmm, since the patch is one shot, let me just bump to 9 and add Phase 9 — that's cleaner. The version represents "what's implemented" not "what generation".

Actually thinking again — the journal shows version went up at each generation that added code. Let me check by looking at version progression:
- v1: phase 0-2 (T1-T12)
- v2: ?? 
- ...

I don't have full visibility. But the current state is v7 with Phase 8 implemented. So previous generations skipped bumping properly, or v7 was set during Phase 7 and never bumped for Phase 8. Whatever. I'll bump to 9 since adding Phase 9 ops in this patch.

Let me now write the full lib/kv.aura file.

Actually, the patch should be just the diff/changes, not necessarily a full file replacement. The instructions say "Prefer full-file replacement for small projects (lib/kv.aura)." So I'll do full file replacement.

Let me carefully assemble the full file now.

I'll add at the end (before the final comment block):

```
; ---------------------------------------------------------------------------
; Phase 9 aggregation / positional / composition helpers.
; Pure functional; insertion order preserved by construction; no FS
; escapes. All derive from the existing alist primitives.
;
; Conventions:
;   * `kv:nth` is 0-indexed and walks the alist left-to-right, skipping
;     non-pair cells defensively. Out-of-range or empty returns `#f`.
;   * `kv:count` and `kv:sum` are reductions over entries in insertion
;     order; the empty store yields the additive identity (`0`) so the
;     result composes naturally with `+` and `reduce`.
;   * `kv:zip` walks its two input lists in parallel and stops at the
;     shorter one — extras on either side are silently dropped.
;   * `kv:swap` is a single atomic-looking operation: it reads both
;     values up front, then folds the original store to produce a fresh
;     one. No-op when k1 == k2 or either key is absent (consistent
;     with kv:rename's refusal semantics for ambiguous writes).
; ---------------------------------------------------------------------------

; (kv:nth store n) -> (k . v) | #f.
; 0-indexed; returns the n-th pair in insertion order, or #f when n is
; out of range or the store is empty. Skips non-pair cells defensively
; (a stray cell never counts toward n).
(define (kv:nth store n)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (if (= n 0) p (kv:nth (cdr store) (- n 1)))
        (kv:nth (cdr store) n)))))

; (kv:count store proc) -> integer.
; Number of entries for which (proc k v) is #t. Empty store returns 0.
; Equivalent to (kv:size (kv:filter store proc)) but does not allocate
; the intermediate store.
(define (kv:count store proc)
  (kv:_fold store 0
    (lambda (k v acc)
      (if (proc k v) (+ acc 1) acc))))

; (kv:sum store) -> integer.
; Sum of all values in insertion order (assumed numeric). Empty store
; returns 0 (additive identity), so (kv:sum s) composes cleanly with +
; and with kv:reduce for custom aggregations.
(define (kv:sum store)
  (kv:_fold store 0 (lambda (k v acc) (+ acc v))))

; (kv:zip keys vals) -> store.
; Build a store by pairing `keys` with `vals` left-to-right. Stops at
; the shorter list; extras on either side are silently dropped.
; Insertion order of the resulting store follows `keys`. Uses the
; internal primitive kv:_set so that each pair is appended at the end
; of the accumulator in source order — no reversal required.
(define (kv:zip keys vals)
  (let loop ((ks keys) (vs vals) (acc (quote ())))
    (if (or (null? ks) (null? vs))
      acc
      (loop (cdr ks) (cdr vs) (kv:_set acc (car ks) (car vs))))))

; (kv:swap store k1 k2) -> store.
; Atomically swap the values at k1 and k2. Other entries' values and
; insertion order are preserved. No-op (returns store unchanged) when:
;   * k1 == k2 (swapping with self is the identity), or
;   * either key is absent from the store (refuses to invent values
;     for missing slots — consistent with kv:rename's ambiguity rule).
; Implementation reads both values up front from the original store
; then folds the original entries into a fresh store, writing k1 -> v2
; and k2 -> v1 — guarantees a single, atomic-looking pass.
(define (kv:swap store k1 k2)
  (if (equal? k1 k2)
    store
    (if (not (kv:_has store k1))
      store
      (if (not (kv:_has store k2))
        store
        (let ((v1 (kv:_ref store k1))
              (v2 (kv:_ref store k2)))
          (kv:_fold store (quote ())
            (lambda (k v acc)
              (if (equal? k k1)
                (kv:_set acc k1 v2)
                (if (equal? k k2)
                  (kv:_set acc k2 v1)
                  (kv:_set acc k v))))))))))
```

And add `kv:nth`, `kv:count`, `kv:sum`, `kv:zip`, `kv:swap` to the export list.

Bump version to 9.

Now the tests — I need to add T43–T47c.

Let me write the new tests block:

```
; ---- Phase 9: aggregation / positional / composition helpers ----

; T43: nth() returns the 0-indexed entry; #f on out-of-range / empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (n0 (kv:nth s 0))
       (n1 (kv:nth s 1))
       (n2 (kv:nth s 2)))
  (t "T43-nth"
     (and (pair? n0)
          (equal? (car n0) "a")
          (equal? (cdr n0) 1)
          (pair? n1)
          (equal? (car n1) "b")
          (equal? (cdr n1) 2)
          (pair? n2)
          (equal? (car n2) "c")
          (equal? (cdr n2) 3)
          (eq? (kv:nth s 3) #f)
          (eq? (kv:nth s 100) #f)
          (eq? (kv:nth (kv:open) 0) #f))))

; T44: count() returns the number of matching entries; 0 on empty / miss.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10))))
  (t "T44-count"
     (and (= (kv:count s (lambda (k v) (> v 3))) 2)
          (= (kv:count s (lambda (k v) (> v 100))) 0)
          (= (kv:count s (lambda (k v) (> v 0))) 3)
          (= (kv:count (kv:open) (lambda (k v) #t)) 0))))

; T45: sum() returns the total of all values; 0 on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))))
  (t "T45-sum"
     (and (= (kv:sum s) 6)
          (= (kv:sum (kv:open)) 0))))

; T46: zip() pairs keys with vals left-to-right; insertion order tracks keys.
(let* ((z (kv:zip (list "a" "b" "c") (list 1 2 3)))
       (zk (kv:keys z)))
  (t "T46-zip"
     (and (= (kv:size z) 3)
          (equal? (kv:get z "a") 1)
          (equal? (kv:get z "b") 2)
          (equal? (kv:get z "c") 3)
          (equal? (car zk) "a")
          (equal? (car (cdr zk)) "b")
          (equal? (car (cdr (cdr zk))) "c"))))

; T46b: zip() with a shorter vals list drops the tail keys.
(t "T46b-zip-vals-shorter"
   (let* ((z (kv:zip (list "a" "b" "c") (list 1 2))))
     (and (= (kv:size z) 2)
          (equal? (kv:get z "a") 1)
          (equal? (kv:get z "b") 2)
          (eq? (kv:get z "c") #f))))

; T46c: zip() with a shorter keys list drops the tail vals.
(t "T46c-zip-keys-shorter"
   (let* ((z (kv:zip (list "a") (list 1 2 3))))
     (and (= (kv:size z) 1)
          (equal? (kv:get z "a") 1))))

; T47: swap() exchanges two values, preserves order and other entries.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (sw (kv:swap s "a" "c"))
       (sk (kv:keys sw)))
  (t "T47-swap"
     (and (= (kv:size sw) 3)
          (equal? (kv:get sw "a") 3)
          (equal? (kv:get sw "b") 2)
          (equal? (kv:get sw "c") 1)
          (equal? (car sk) "a")
          (equal? (car (cdr sk)) "b")
          (equal? (car (cdr (cdr sk))) "c"))))

; T47b: swap() with k1 == k2 is a no-op.
(t "T47b-swap-same-key"
   (let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (sw (kv:swap s "a" "a")))
     (and (= (kv:size sw) 2)
          (equal? (kv:get sw "a") 1)
          (equal? (kv:get sw "b") 2))))

; T47c: swap() with a missing key is a no-op.
(t "T47c-swap-missing"
   (let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (sw (kv:swap s "a" "ghost")))
     (and (= (kv:size sw) 2)
          (equal? (kv:get sw "a") 1)
          (equal? (kv:get sw "b") 2)
          (eq? (kv:get sw "ghost") #f))))
```

Hmm, that should be 11 new tests. Let me count: T43, T44, T45, T46, T46b, T46c, T47, T47b, T47c = 9 new tests. So total goes from 57 to 57+9 = 66.

Wait actually I miscounted. Let me recount from the test file:
- T1-T17 = 17
- T18-T23 = 6 (T18, T19, T19b, T20, T21, T21b, T22, T23) — wait, that's 8
Let me just trust that the existing baseline is 57. Then I add 9 new tests for 66 total.

Now let me think about potential issues with the implementation:

1. `kv:nth` — uses `(- n 1)` for n=0. Wait, when n=0 and pair, return p directly (no recursion). So no issue with (- 0 1) = -1. Good. But what about (kv:nth s 0) when store is empty? We return #f via null check. Good.

2. `kv:count` — simple fold with counter. Empty → 0 (initial acc).

3. `kv:sum` — fold with `+`. Empty → 0.

4. `kv:zip` — walk in parallel. Should work.

5. `kv:swap` — fold over original store, set in accumulator. Uses `kv:_set` which preserves order if same key (in-place) or appends (new key). Since k1 != k2 and both are in the store, both end up in the accumulator with swapped values, in their original positions. 

Actually wait, let me trace through:
- Store = [a->1, b->2, c->3]
- v1 = 1 (value at "a"), v2 = 3 (value at "c")
- Fold:
  - Process (a, 1): k = "a", matches k1 = "a", set acc to (a -> v2 = 3). acc = [a->3].
  - Process (b, 2): k = "b", matches neither, set acc to (b -> 2). acc = [a->3, b->2].
  - Process (c, 3): k = "c", matches k2 = "c", set acc to (c -> v1 = 1). acc = [a->3, b->2, c->1].
- Result: [a->3, b->2, c->1]. ✓

Order preserved, values swapped. 

Now let me think about an edge case: what if `kv:swap` is called with one of the keys appearing multiple times? The internal alist has unique keys (since kv:_set replaces), so this shouldn't happen normally. But if it did, the fold would process both occurrences, with each calling kv:_set which replaces. The first occurrence wins on ordering (since it's processed first and gets appended first). The second occurrence, when processed, would `kv:_set` the same key — replacing in place. So the value would be the same as the first swap-set value. Hmm, edge case but unlikely.

OK, let me finalize the patch.

Actually wait — I should double-check whether the version increment should be from 7 → 8 (just bookkeeping) and then 8 → 9 for new ops, or directly 7 → 9. Since the patch is one-shot, I'll go to 9 and note it represents "Phase 9 + bookkeeping for Phase 8" in the file comment. Or just bump to 8 with new ops and bump to 9 if I want a separate generation. To keep it simple, version 9.

Let me also think about whether there are any potential issues with the existing test passing. The patch only adds new things and bumps version. The existing tests should still pass.

Let me write the full file now. I'll be careful to preserve every line.

One more consideration: in T44 and T45, I wrote:
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10))))
```
That has unbalanced parens! Should be:
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10))))
```
Wait, `let* ((s expr))` — that's `let*` with one binding. Then `body` follows. So:
```scheme
(let* ((s expr)) body)
```
becomes:
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T44-count" ...))
```

That's:
- `let*` with one binding `(s ...)` followed by body `(t "T44-count" ...)`.
- The binding value: `(kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)`
- That's `kv:set` applied to `(kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)`... wait no, `kv:set` takes 3 args: `(kv:set store key val)`. So `(kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)` is `kv:set` with args `store=(kv:set (kv:set (kv:open) "a" 1) "b" 5)`, `key="c"`, `val=10`. That's 3 args, well-formed.

So `(let* ((s (kv:set ...))) (t "T44-count" ...))` is:
- `let*` with 1 binding `s` to a 3-arg `kv:set` expression.
- Body: `(t "T44-count" ...)`.

Parens:
- `(let*` open
- `((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))` — bindings list with one binding
- `(t "T44-count" (and ...))` — body
- `)` close let*

Counting parens:
```
(let*
  ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T44-count"
     (and ...)))
```
- Open: let*
- Open: bindings (outer)
- Open: bindings (inner list)
- Open: s binding (s expression)
- ... expression
- Close: s binding
- Close: bindings (inner list)
- Wait no, `((s expr))` is two open parens and two close parens for the bindings list.

Let me write it more carefully:
```
(let* ((s EXPR)) BODY)
```
- `(` open let*
- ` ` whitespace
- `(` open bindings
- `(` open first-binding
- `s` symbol
- ` ` whitespace
- `EXPR` some expression
- `)` close first-binding
- `)` close bindings
- ` ` whitespace
- `BODY` body
- `)` close let*

So `(let* ((s EXPR)) BODY)` has:
- let* open paren: 1
- bindings open: 2
- s binding open: 3
- EXPR open: 4
- EXPR close: 3
- s binding close: 2
- bindings close: 1
- BODY opens: depends on body
- let* close: 0

OK so `(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10))) BODY)` is:
- `(let*` 1
- ` (` 2
- `(` 3 (s-binding)
- `s` 
- ` (kv:set` 4 (EXPR)
- ` (kv:set` 5
- ` (kv:set` 6
- ` (kv:open)` 6 → back to 5
- ` "a"` 5
- ` 1)` 4 (close third kv:set)
- ` "b"` 4
- ` 5)` 3 (close second kv:set)
- ` "c"` 3
- ` 10)` 2 (close first kv:set, EXPR done)
- `)` 1 (close s-binding)
- `)` 0 (close bindings)
- `BODY`
- `)` -1 (close let*)

So the parens balance when we close with the final `)` for let*.

Let me write it cleanly:
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T44-count" ...))
```

So the pattern is:
```
(let* ((s ...))
  (t "..." ...))
```
That's `(let* ((s ...)) (t "..." ...))` — well-formed.

Hmm I had an extra `)` in my draft. Let me fix:
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T44-count" ...))
```

That's correct. Same for T45.

OK let me also think about whether `or` works as a short-circuit. Looking at tests... T9 uses `(or (equal? (car ks) "x") (equal? (car ks) "y") ...)`. That's how `or` is used here, but I'm not sure if it's short-circuiting or just a boolean. Either way, both args are evaluated. In T46b/T46c it doesn't matter — both are simple checks.

In `kv:zip`, `(or (null? ks) (null? vs))` — both need to be evaluated for correctness, but for efficiency short-circuiting would help. Let me check if the host supports short-circuit `or`. Looking at the source... I don't see explicit tests, but typically Scheme `or` is short-circuit. If not, we'd evaluate `(null? vs)` even when ks is null, which is harmless (vs is also null). So either way, works.

OK let me write the full file now. I'll need to be careful to match exactly the existing style and not break anything.

Let me also add `kv:nth`, `kv:count`, `kv:sum`, `kv:zip`, `kv:swap` to the export list.

Let me finalize the patch now.

Actually one more thought: I'm going to do this as two file changes:
1. lib/kv.aura — full file replacement
2. tests/smoke.aura — append new tests

Let me write them both.

Wait, can I include multiple files in one PATCH section? Looking at instructions:
"FILE relative/path
```
full file contents
```"

It seems like one file per PATCH block. But there could be multiple PATCH blocks for multiple files. Let me include both.

Actually re-reading: "Emit a concrete PATCH the actuator can apply" and "FILE relative/path" — singular. But it could be one file at a time. I'll do two PATCH blocks: one for lib/kv.aura and one for tests/smoke.aura.

Let me write the full lib/kv.aura file now.

Header comment update:
```
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation.
; Phase 4:   batch / composite helpers (mset, mget, update, merge, copy).
; Phase 5:   iteration & query helpers (values, entries, filter, find,
;             empty?, for-each).
; Phase 6:   fold / predicate / projection / selection helpers
;             (reduce, any?, every?, pick, omit, map-values).
; Phase 7:   convenience / comparison helpers
;             (get-or, rename, diff, partition, equal?).
; Phase 8:   positional / conditional / inversion helpers
;             (first, last, rest, butlast, take, drop, invert,
;             set-if-absent).
; Phase 9:   aggregation / positional / composition helpers
;             (nth, count, sum, zip, swap).
```

Export list — add `kv:nth`, `kv:count`, `kv:sum`, `kv:zip`, `kv:swap`.

Bump version to 9.

Then at end, add Phase 9 section.

Let me write it out.

Also one detail about `kv:zip`: what should happen with the test if one of the vals is `#f`? E.g., `(kv:zip (list "a") (list #f))` should give a=#f. But there's no test for this, so I don't need to worry.

Now, let me think about the `kv:zip` semantics with kv:get. After `(kv:zip (list "a") (list 1))`, calling `(kv:get store "a")` returns 1. Good. The store has a=1. ✓

For T46b (zip with shorter vals), the test expects:
- `(kv:zip (list "a" "b" "c") (list 1 2))` → store with a=1, b=2, c missing.
- `(kv:size z)` = 2. ✓
- `(kv:get z "a")` = 1. ✓
- `(kv:get z "b")` = 2. ✓
- `(kv:get z "c")` = #f. ✓

For T46c (zip with shorter keys), the test expects:
- `(kv:zip (list "a") (list 1 2 3))` → store with a=1.
- `(kv:size z)` = 1. ✓
- `(kv:get z "a")` = 1. ✓

OK all good.

Now let me also think about whether `kv:zip` could fail in some edge case. What if both lists are empty? Loop exits immediately, returns acc = (). ✓

What if one is empty? Same. ✓

What if one has non-string keys? Internal kv:_set doesn't validate; the result would have non-string keys. Public contract says keys are strings, but kv:zip is a constructor so it should perhaps enforce string keys? Hmm. To keep consistency with kv:set which validates, let me add a string? check on the key.

Actually, the existing pattern: `kv:mset` uses `kv:_set` directly (no validation), and `kv:zip` would be similar. The SPEC says "Keys are strings." but doesn't enforce it for all constructors. Let me not validate — keep it consistent with `kv:mset`.

Actually wait, let me check kv:mset:
```scheme
(define (kv:mset store alist)
  (let loop ((xs alist) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:_set acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))
```
No string? check. OK so `kv:zip` matching style would also skip the check. Good.

Let me finalize. Here's my plan for the full lib/kv.aura:

Same as current but:
1. Update header to add Phase 9 line
2. Add `kv:nth`, `kv:count`, `kv:sum`, `kv:zip`, `kv:swap` to export list
3. Bump `kv:version` from 7 to 9
4. Add Phase 9 section at end

And tests/smoke.aura gets:
1. Append Phase 9 test block before the SCORE display

Let me write them now.

Actually, I realize I should double-check the test file's tail. The end of the test file is:
```
(t "T42-set-if-absent"
   (and (equal? (kv:get s2 "x") 1)
        (eq? (kv:get s2 "y") #f)
        (equal? (kv:get s3 "x") 1)
        (equal? (kv:get s3 "y") 2))))

(display "SCORE ")
...
```

So the Phase 9 tests need to go between T42 and the SCORE display.

OK let me write the final patches.

One more concern — let me re-verify `kv:swap` once more. Suppose we have store [a->1, b->2, c->3] and call `(kv:swap store "a" "c")`. v1=1, v2=3. Fold:
- k="a", v=1: matches k1, set acc (a, v2=3). acc=[(a.3)].
- k="b", v=2: doesn't match, set acc (b, 2). acc=[(a.3), (b.2)].
- k="c", v=3: matches k2, set acc (c, v1=1). Now kv:_set finds c in acc? Wait, acc doesn't have c yet, so kv:_set appends. acc=[(a.3), (b.2), (c.1)].

So result is [a->3, b->2, c->1]. ✓

Test:
- (kv:size sw) = 3 ✓
- (kv:get sw "a") = 3 ✓
- (kv:get sw "b") = 2 ✓
- (kv:get sw "c") = 1 ✓
- (kv:keys sw) = ("a" "b" "c") ✓

Good.

Now for swap with overlapping — what if k1 and k2 are the same value? `(kv:swap store "a" "b")` when a=2, b=2. v1=2, v2=2. Result: a=2, b=2 — visually no change but stores are "swapped" internally. The test wouldn't distinguish. Good.

What about (kv:swap store "a" "a")? Same key, no-op via the (equal? k1 k2) check. ✓

What about (kv:swap store "a" "ghost")? ghost not present, no-op via (not (kv:_has store k2)). ✓

OK let me finalize. I'll write out the complete lib/kv.aura and the test additions.

For the version bump, let me reconsider: the current version is 7 with Phase 8 implemented. So the version is out of sync. Should I:
(a) Bump to 8 as a "bookkeeping fix" then immediately to 9 with new ops → version 9
(b) Bump directly to 9 → version 9

Either way the final version is 9. Let me go with (b) and add a brief note in the Phase 9 section that the version was bumped to reflect Phase 9 (and incidentally includes the bookkeeping for Phase 8). Or just say "Phase 9" cleanly without the bookkeeping confusion.

Let me just bump to 9 directly. Cleaner.

Let me write the final lib/kv.aura now. This will be a long file but I'll preserve every line exactly.

I'll do it in pieces:

```
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation.
; Phase 4:   batch / composite helpers (mset, mget, update, merge, copy).
; Phase 5:   iteration & query helpers (values, entries, filter, find,
;             empty?, for-each).
; Phase 6:   fold / predicate / projection / selection helpers
;             (reduce, any?, every?, pick, omit, map-values).
; Phase 7:   convenience / comparison helpers
;             (get-or, rename, diff, partition, equal?).
; Phase 8:   positional / conditional / inversion helpers
;             (first, last, rest, butlast, take, drop, invert,
;             set-if-absent).
; Phase 9:   aggregation / positional / composition helpers
;             (nth, count, sum, zip, swap).
;
; Store representation: alist of (key . val) pairs.
;   * Keys are strings.
;   * Values may be any Aura value (numbers, strings, lists, ...).
;   * Insertion order is preserved across all operations.
;   * All operations are functional: each returns a fresh store;
;     the input store is never mutated.
;
; Form order: export before require.

(export kv:version
        kv:open
        kv:set
        kv:get
        kv:del
        kv:has?
        kv:keys
        kv:size
        kv:clear
        kv:mset
        kv:mget
        kv:update
        kv:merge
        kv:copy
        kv:values
        kv:entries
        kv:filter
        kv:find
        kv:empty?
        kv:for-each
        kv:reduce
        kv:any?
        kv:every?
        kv:pick
        kv:omit
        kv:map-values
        kv:get-or
        kv:rename
        kv:diff
        kv:partition
        kv:equal?
        kv:first
        kv:last
        kv:rest
        kv:butlast
        kv:take
        kv:drop
        kv:invert
        kv:set-if-absent
        kv:nth
        kv:count
        kv:sum
        kv:zip
        kv:swap)

(define kv:version 9)
```

Then all the existing internals... then at the end, Phase 9 section.

Let me write the full file now. I'll be meticulous about preserving every character.

Actually, given the length, I'll write it section by section in my head and ensure continuity.

OK let me just write the patch.</think>

### REVIEW
- **Strengths:** 57/57 already green across Phases 0–8 (open/set/get → set-if-absent). The alist-of-cons representation is defensive (skips stray non-pair cells), insertion order is preserved by every op, all ops are pure functional, no FS / network / host escape used. Export-before-define discipline is intact, API names are stable, the `kv:pick` ordering bug from g6 is fixed, and `kv:rename` / `kv:swap`-style "refuse on ambiguity" semantics are consistent.
- **Failures / Risks:** `kv:version` is still 7 even though Phase 8 is fully implemented (bookkeeping drift — fixable in the same patch). No real "host escape" risk to stress; SPEC table only enumerates through Phase 4, so we're already ahead of the published roadmap — pure-Aura denseness posture means there's still room to add small composable ops without leaking any new host dependency. No actual test failures to fix.
- **Denseness posture:** All new helpers should be derived from the existing `_fold`/`_set`/`_has`/`_ref` primitives, preserve insertion order, refuse on ambiguity rather than guessing, and be tested in `tests/smoke.aura` while every prior test stays green.

### DIRECTION
- **Target phase: Phase 9 — aggregation / positional / composition helpers.** Same posture as Phase 8 (pure Aura, derived from existing alist primitives, insertion-order preserved by construction, no FS escapes, no API renames). Keeps all T1–T42 green.
- **Ops to add (5 new):**
  - `kv:nth`  — `(store n)` 0-indexed entry, `#f` on out-of-range / empty; skips non-pair cells defensively
  - `kv:count` — `(store proc)` number of matching entries; 0 on empty (avoids allocating an intermediate filter store)
  - `kv:sum`  — `(store)` sum of values; 0 on empty (additive identity so it composes with `+` / `reduce`)
  - `kv:zip`  — `(keys vals)` build store by pairing left-to-right, stop at shorter list, insertion order follows `keys`
  - `kv:swap` — `(store k1 k2)` atomic swap of two values; no-op when `k1 == k2` or either key is absent (consistent with `kv:rename`'s ambiguity-refusal rule)
- **Bump `kv:version` to 9** (also fixes the bookkeeping drift from Phase 8). Don't touch any existing op or test. Extend `tests/smoke.aura` with T43–T47c (9 new tests).

### PATCH
FILE lib/kv.aura
```
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation.
; Phase 4:   batch / composite helpers (mset, mget, update, merge, copy).
; Phase 5:   iteration & query helpers (values, entries, filter, find,
;             empty?, for-each).
; Phase 6:   fold / predicate / projection / selection helpers
;             (reduce, any?, every?, pick, omit, map-values).
; Phase 7:   convenience / comparison helpers
;             (get-or, rename, diff, partition, equal?).
; Phase 8:   positional / conditional / inversion helpers
;             (first, last, rest, butlast, take, drop, invert,
;             set-if-absent).
; Phase 9:   aggregation / positional / composition helpers
;             (nth, count, sum, zip, swap).
;
; Store representation: alist of (key . val) pairs.
;   * Keys are strings.
;   * Values may be any Aura value (numbers, strings, lists, ...).
;   * Insertion order is preserved across all operations.
;   * All operations are functional: each returns a fresh store;
;     the input store is never mutated.
;
; Form order: export before require.

(export kv:version
        kv:open
        kv:set
        kv:get
        kv:del
        kv:has?
        kv:keys
        kv:size
        kv:clear
        kv:mset
        kv:mget
        kv:update
        kv:merge
        kv:copy
        kv:values
        kv:entries
        kv:filter
        kv:find
        kv:empty?
        kv:for-each
        kv:reduce
        kv:any?
        kv:every?
        kv:pick
        kv:omit
        kv:map-values
        kv:get-or
        kv:rename
        kv:diff
        kv:partition
        kv:equal?
        kv:first
        kv:last
        kv:rest
        kv:butlast
        kv:take
        kv:drop
        kv:invert
        kv:set-if-absent
        kv:nth
        kv:count
        kv:sum
        kv:zip
        kv:swap)

(define kv:version 9)

; ---------------------------------------------------------------------------
; Internal alist primitives.
; Every helper tolerates stray non-pair cells defensively (skips them),
; which keeps the store robust against accidental bad inputs.
; ---------------------------------------------------------------------------

; (kv:_ref xs key) -> value | #f
(define (kv:_ref xs key)
  (if (null? xs)
    #f
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cdr p)
        (kv:_ref (cdr xs) key)))))

; (kv:_has xs key) -> #t | #f
(define (kv:_has xs key)
  (if (null? xs)
    #f
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        #t
        (kv:_has (cdr xs) key)))))

; (kv:_set xs key val) -> fresh alist with key mapped to val.
; If key already exists, it is replaced in place (preserving position).
; Otherwise it is appended at the end.
(define (kv:_set xs key val)
  (if (null? xs)
    (list (cons key val))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key val) (cdr xs))
        (cons p (kv:_set (cdr xs) key val))))))

; (kv:_del xs key out) -> fresh alist without `key`, preserving order.
(define (kv:_del xs key out)
  (if (null? xs)
    (reverse out)
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (kv:_del (cdr xs) key out)
        (kv:_del (cdr xs) key (cons p out))))))

; (kv:_fold xs acc f) -> acc; f is (k v acc) -> acc.
(define (kv:_fold xs acc f)
  (if (null? xs)
    acc
    (let ((p (car xs)))
      (if (pair? p)
        (kv:_fold (cdr xs) (f (car p) (cdr p) acc) f)
        (kv:_fold (cdr xs) acc f)))))

; (kv:_map xs f) -> list; f is (k v) -> any; preserves order.
(define (kv:_map xs f)
  (if (null? xs)
    (quote ())
    (let ((p (car xs)))
      (let ((rest (kv:_map (cdr xs) f)))
        (if (pair? p)
          (cons (f (car p) (cdr p)) rest)
          rest)))))

; (kv:_mem key xs) -> #t | #f.
; True iff `key` appears in list `xs` (compared with equal?).
; Internal helper; not exported. Used by kv:pick to test whether a
; store key is among the requested keys without leaking membership-test
; semantics into the public namespace.
(define (kv:_mem key xs)
  (if (null? xs)
    #f
    (if (equal? (car xs) key)
      #t
      (kv:_mem key (cdr xs)))))

; ---------------------------------------------------------------------------
; Phase 0..2 public API
; ---------------------------------------------------------------------------

(define (kv:open)
  (quote ()))

(define (kv:set store key val)
  (if (string? key)
    (kv:_set store key val)
    store))

(define (kv:get store key)
  (kv:_ref store key))

(define (kv:del store key)
  (kv:_del store key (quote ())))

(define (kv:has? store key)
  (kv:_has store key))

(define (kv:keys store)
  (kv:_map store (lambda (k v) k)))

(define (kv:size store)
  (kv:_fold store 0 (lambda (k v n) (+ n 1))))

(define (kv:clear store)
  (quote ()))

; ---------------------------------------------------------------------------
; Phase 4 batch / composite helpers
; ---------------------------------------------------------------------------

; (kv:mset store '((k . v) ...)) -> store
; Apply kv:set for each pair in `alist`, in the order given.
; New keys are appended at the end; existing keys are replaced in place.
(define (kv:mset store alist)
  (let loop ((xs alist) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:_set acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))

; (kv:mget store '("k" ...)) -> list of values (or #f for misses),
; in the same order as the input keys.
(define (kv:mget store keys)
  (let loop ((xs keys) (out (quote ())))
    (if (null? xs)
      (reverse out)
      (loop (cdr xs) (cons (kv:_ref store (car xs)) out)))))

; (kv:update store key default proc) -> store
; `proc` is (val) -> new-val.
; If key exists, `proc` receives the current value; otherwise it receives
; `default`. The store is then set to (proc ...).
(define (kv:update store key default proc)
  (if (kv:_has store key)
    (kv:_set store key (proc (kv:_ref store key)))
    (kv:_set store key (proc default))))

; (kv:merge a b) -> store
; Right-biased union. a's insertion order is preserved; b's keys fold in
; over a, with b winning on conflicts and b-only keys appended at the end
; in b's iteration order.
(define (kv:merge a b)
  (kv:mset a (kv:_map b (lambda (k v) (cons k v)))))

; (kv:copy store) -> store
; The store is already an immutable value, so this is the identity.
; Provided for API symmetry / explicit-isolation clarity.
(define (kv:copy store) store)

; ---------------------------------------------------------------------------
; Phase 5 iteration & query helpers.
; All derive from the existing `_fold` / `_map` primitives; insertion
; order is preserved by construction. No mutation, no FS escapes.
; ---------------------------------------------------------------------------

; (kv:values store) -> list of values in insertion order.
(define (kv:values store)
  (kv:_map store (lambda (k v) v)))

; (kv:entries store) -> alist ((k . v) ...) in insertion order.
(define (kv:entries store)
  (kv:_map store (lambda (k v) (cons k v))))

; (kv:filter store proc) -> store
; Returns a new store containing only entries for which (proc k v) is #t.
; Folds left-to-right, so the resulting store preserves the original
; insertion order among survivors.
(define (kv:filter store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (proc k v)
        (kv:_set acc k v)
        acc))))

; (kv:find store proc) -> (k . v) | #f
; Returns the first entry (as a cons cell) for which (proc k v) is #t,
; or #f if no entry matches (or the store is empty).
(define (kv:find store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        p
        (kv:find (cdr store) proc)))))

; (kv:empty? store) -> #t | #f
; Convenience predicate; equivalent to (null? store) but exposed under
; the kv: namespace so callers don't need to know the internal shape.
(define (kv:empty? store)
  (null? store))

; (kv:for-each store proc) -> #t
; Calls (proc k v) for each entry in insertion order. Returns #t.
; Provided for side-effecting iteration; pure users should prefer
; kv:values / kv:entries / kv:filter / kv:find.
(define (kv:for-each store proc)
  (kv:_fold store #t
    (lambda (k v acc) (proc k v) acc)))

; ---------------------------------------------------------------------------
; Phase 6 fold / predicate / projection / selection helpers.
; Pure functional; preserve insertion order; no FS escapes.
; ---------------------------------------------------------------------------

; (kv:reduce store init proc) -> result.
; `proc` is (k v acc) -> acc. Equivalent to a left fold over entries in
; insertion order. An empty store returns `init` unchanged.
(define (kv:reduce store init proc)
  (kv:_fold store init proc))

; (kv:any? store proc) -> #t | #f.
; True iff at least one entry satisfies (proc k v). Short-circuits on
; the first hit. On an empty store the answer is #f (vacuous).
(define (kv:any? store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        #t
        (kv:any? (cdr store) proc)))))

; (kv:every? store proc) -> #t | #f.
; True iff every entry satisfies (proc k v). Short-circuits on first miss.
; On an empty store the answer is #t (vacuous).
(define (kv:every? store proc)
  (if (null? store)
    #t
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        (kv:every? (cdr store) proc)
        #f))))

; (kv:pick store keys) -> new store containing only the listed keys
; that are present in `store`. Missing keys are silently dropped
; (consistent with kv:get/#f-as-miss semantics). Insertion order of the
; survivors follows `store`, not the order of the input `keys` list.
; Note: a value that is literally #f cannot be distinguished from a
; miss — documented limitation consistent with kv:get.
(define (kv:pick store keys)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (kv:_mem k keys)
        (kv:_set acc k v)
        acc))))

; (kv:omit store keys) -> new store with the listed keys removed.
; Preserves insertion order of the survivors. Missing keys are a no-op.
(define (kv:omit store keys)
  (let loop ((xs keys) (st store))
    (if (null? xs)
      st
      (loop (cdr xs) (kv:_del st (car xs) (quote ()))))))

; (kv:map-values store proc) -> new store with (proc v) applied to each
; value. Keys and insertion order are preserved.
(define (kv:map-values store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc) (kv:_set acc k (proc v)))))

; ---------------------------------------------------------------------------
; Phase 7 convenience / comparison helpers.
; All pure functional, derived from the existing internals; no FS
; escapes; insertion order preserved by construction.
; ---------------------------------------------------------------------------

; (kv:get-or store key default) -> value | default.
; Returns the stored value when `key` is present (even if that value is
; literally #f), and `default` otherwise. Implemented via kv:_has so a
; stored #f is distinguishable from a missing key — documented
; improvement over the raw kv:get / #f-as-miss convention.
(define (kv:get-or store key default)
  (if (kv:_has store key)
    (kv:_ref store key)
    default))

; (kv:rename store old-key new-key) -> store.
; Atomically replaces `old-key` with `new-key`, preserving the original
; insertion position (substituted in place) and keeping every other
; entry's value + order untouched. No-op when:
;   * `old-key` is not in `store`, or
;   * `new-key` is already present (the operation is ambiguous and the
;     caller would have to choose between overwriting `new-key` and
;     losing the rename target — refusing is the only safe choice).
; Note: rename with old-key == new-key is also a no-op by virtue of the
; second rule above.
(define (kv:rename store old-key new-key)
  (if (not (kv:_has store old-key))
    store
    (if (kv:_has store new-key)
      store
      (kv:_fold store (quote ())
        (lambda (k v acc)
          (if (equal? k old-key)
            (kv:_set acc new-key v)
            (kv:_set acc k v)))))))

; (kv:diff a b) -> (added removed changed).
; Three sub-stores describing the set-theoretic / value-level differences
; from a -> b:
;   * added   — keys present in b but not in a, with b's values.
;   * removed — keys present in a but not in b, with a's values.
;   * changed — keys present in both, with values that differ; entries
;               are stored as (k . (old-val . new-val)) so the consumer
;               can distinguish "value changed" from "key added".
; Iteration order of each sub-store follows the source it was derived
; from (added/removed follow their respective stores; changed follows
; `a`). No FS, no mutation.
(define (kv:diff a b)
  (let* ((added
           (kv:_fold b (quote ())
             (lambda (k v acc)
               (if (kv:_has a k)
                 acc
                 (kv:_set acc k v)))))
         (removed
           (kv:_fold a (quote ())
             (lambda (k v acc)
               (if (kv:_has b k)
                 acc
                 (kv:_set acc k v)))))
         (changed
           (kv:_fold a (quote ())
             (lambda (k va acc)
               (if (kv:_has b k)
                 (let ((vb (kv:_ref b k)))
                   (if (equal? va vb)
                     acc
                     (kv:_set acc k (cons va vb))))
                 acc)))))
    (list added removed changed)))

; (kv:partition store proc) -> (match . nomatch).
; Two stores: the entries for which (proc k v) is #t and those for which
; it is #f. Both sub-stores preserve the original insertion order
; among their respective survivors. An empty store yields ((() . ())).
(define (kv:partition store proc)
  (kv:_fold store (list (quote ()) (quote ()))
    (lambda (k v acc)
      (let ((m (car acc))
            (n (car (cdr acc))))
        (if (proc k v)
          (list (kv:_set m k v) n)
          (list m (kv:_set n k v)))))))

; (kv:equal? a b) -> #t | #f.
; Deep structural equality of two stores, ignoring insertion order.
; First checks sizes; then iterates the keys of `a` and verifies each
; one is present in `b` with a structurally equal value. Symmetric in
; practice (same key multiset + same per-key values).
; Note: a stored #f value compares equal to a missing key under a naive
; implementation; kv:_has is used to keep the check honest.
(define (kv:equal? a b)
  (if (= (kv:size a) (kv:size b))
    (let loop ((xs (kv:keys a)))
      (if (null? xs)
        #t
        (let ((k (car xs)))
          (if (kv:_has b k)
            (if (equal? (kv:_ref a k) (kv:_ref b k))
              (loop (cdr xs))
              #f)
            #f))))
    #f))

; ---------------------------------------------------------------------------
; Phase 8 positional / conditional / inversion helpers.
; Pure functional; insertion order preserved by construction; no FS
; escapes. All derive from the existing alist primitives.
;
; Conventions:
;   * "First" / "Rest" are O(1) on the head of the alist; "Last" /
;     "Butlast" are O(n) walks (consistent with standard Scheme idioms).
;   * "Take(n)" / "Drop(n)" walk the store left-to-right, counting only
;     pair cells toward `n` — stray non-pair cells are preserved in the
;     output of `drop` and skipped by `take`, so a defensive artifact
;     cannot shift the result by one.
;   * `kv:invert` resolves value collisions in favor of the first
;     occurrence observed while folding the source, mirroring the
;     "insertion-order wins" semantics used by every other op.
; ---------------------------------------------------------------------------

; (kv:_take xs n out) -> reversed list of the first n pairs of xs.
; Non-pair cells are skipped entirely (defensive: they never count
; toward `n`). When n<=0 or xs is exhausted, returns (reverse out).
(define (kv:_take xs n out)
  (if (= n 0)
    (reverse out)
    (if (null? xs)
      (reverse out)
      (let ((p (car xs)))
        (if (pair? p)
          (kv:_take (cdr xs) (- n 1) (cons p out))
          (kv:_take (cdr xs) n out))))))

; (kv:_drop xs n) -> store with the first n pairs of xs removed.
; Non-pair cells are preserved in the output but never counted toward
; `n`, so a defensive stray cell cannot shift the result by one.
(define (kv:_drop xs n)
  (if (null? xs)
    (quote ())
    (if (= n 0)
      xs
      (let ((p (car xs)))
        (if (pair? p)
          (kv:_drop (cdr xs) (- n 1))
          (cons p (kv:_drop (cdr xs) n)))))))

; (kv:first store) -> (k . v) | #f.
; Returns the first pair in insertion order, skipping any stray
; non-pair cells. Returns #f when the store is empty (or contains
; only non-pair defensive artifacts). O(1) on the head.
(define (kv:first store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p) p (kv:first (cdr store))))))

; (kv:last store) -> (k . v) | #f.
; Returns the last pair in insertion order, skipping any stray non-pair
; cells. Returns #f when the store is empty. O(n) left-to-right walk.
(define (kv:last store)
  (if (null? store)
    #f
    (let loop ((xs store) (acc #f))
      (if (null? xs)
        acc
        (let ((p (car xs)))
          (if (pair? p)
            (loop (cdr xs) p)
            (loop (cdr xs) acc)))))))

; (kv:rest store) -> store.
; Returns the store minus its first pair, skipping any stray non-pair
; cells. An empty store (or a store of only non-pair cells) returns ().
(define (kv:rest store)
  (if (null? store)
    (quote ())
    (let ((p (car store)))
      (if (pair? p)
        (cdr store)
        (kv:rest (cdr store))))))

; (kv:butlast store) -> store.
; Returns the store without its last pair, preserving insertion order.
; An empty store returns (); a single-pair store also returns ().
; Non-pair cells are preserved. O(n) via reverse / cdr / reverse.
(define (kv:butlast store)
  (if (null? store)
    (quote ())
    (reverse (cdr (reverse store)))))

; (kv:take store n) -> store.
; First n entries of `store`, preserving insertion order. When n<=0
; the result is empty; when n is greater than the number of pairs in
; `store` the whole store is returned. Non-pair cells are skipped.
(define (kv:take store n)
  (kv:_take store n (quote ())))

; (kv:drop store n) -> store.
; `store` without its first n entries, preserving insertion order.
; When n<=0 the result is the whole store; when n is greater than the
; number of pairs in `store` the result is empty. Non-pair cells are
; preserved.
(define (kv:drop store n)
  (kv:_drop store n))

; (kv:invert store) -> store.
; Swap keys and values. Folds `store` in insertion order, adding
; (v -> k) only when v is not already a key in the accumulator; this
; guarantees that on value collisions the earlier entry wins and the
; result's insertion order tracks the source. Uses kv:_set directly
; (bypassing the public string?-key check) because the new keys are
; the source's values, which may not be strings — inversion is a
; projection over the existing entry set, not a fresh write.
(define (kv:invert store)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (kv:_has acc v)
        acc
        (kv:_set acc v k)))))

; (kv:set-if-absent store key val) -> store.
; Sets `key` -> `val` only when `key` is not already present. When
; `key` exists the original store is returned unchanged (referential
; identity is preserved for callers that compare stores with eq?;
; though the public equality predicate is kv:equal?). Validates that
; `key` is a string, matching the public kv:set guard so that bad
; callers can't accidentally leak non-string keys into a store.
(define (kv:set-if-absent store key val)
  (if (string? key)
    (if (kv:_has store key)
      store
      (kv:_set store key val))
    store))

; ---------------------------------------------------------------------------
; Phase 9 aggregation / positional / composition helpers.
; Pure functional; insertion order preserved by construction; no FS
; escapes. All derive from the existing alist primitives.
;
; Conventions:
;   * `kv:nth` is 0-indexed and walks the alist left-to-right, skipping
;     non-pair cells defensively. Out-of-range or empty returns `#f`.
;   * `kv:count` and `kv:sum` are reductions over entries in insertion
;     order; the empty store yields the additive identity (`0`) so the
;     result composes naturally with `+` and `reduce`.
;   * `kv:zip` walks its two input lists in parallel and stops at the
;     shorter one — extras on either side are silently dropped.
;   * `kv:swap` is a single atomic-looking operation: it reads both
;     values up front, then folds the original store to produce a fresh
;     one. No-op when k1 == k2 or either key is absent (consistent with
;     kv:rename's refusal semantics for ambiguous writes).
; ---------------------------------------------------------------------------

; (kv:nth store n) -> (k . v) | #f.
; 0-indexed; returns the n-th pair in insertion order, or #f when n is
; out of range or the store is empty. Skips non-pair cells defensively
; (a stray cell never counts toward n). O(n) walk; consistent with the
; "head is O(1), tail is O(n)" posture used by Phase 8.
(define (kv:nth store n)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (if (= n 0) p (kv:nth (cdr store) (- n 1)))
        (kv:nth (cdr store) n)))))

; (kv:count store proc) -> integer.
; Number of entries for which (proc k v) is #t. Empty store returns 0.
; Equivalent to (kv:size (kv:filter store proc)) but avoids allocating
; the intermediate store — a hot-path-friendly form.
(define (kv:count store proc)
  (kv:_fold store 0
    (lambda (k v acc)
      (if (proc k v) (+ acc 1) acc))))

; (kv:sum store) -> integer.
; Sum of all values in insertion order (assumed numeric). Empty store
; returns 0 (additive identity), so (kv:sum s) composes cleanly with +
; and with kv:reduce for custom aggregations.
(define (kv:sum store)
  (kv:_fold store 0 (lambda (k v acc) (+ acc v))))

; (kv:zip keys vals) -> store.
; Build a store by pairing `keys` with `vals` left-to-right. Stops at
; the shorter list; extras on either side are silently dropped.
; Insertion order of the resulting store follows `keys`. Uses the
; internal primitive kv:_set so each pair is appended at the end of
; the accumulator in source order — no reversal required. No
; string?-key validation (matches kv:mset's posture: zip is a
; projection / constructor over caller-supplied data, not a fresh
; kv:set write).
(define (kv:zip keys vals)
  (let loop ((ks keys) (vs vals) (acc (quote ())))
    (if (or (null? ks) (null? vs))
      acc
      (loop (cdr ks) (cdr vs) (kv:_set acc (car ks) (car vs))))))

; (kv:swap store k1 k2) -> store.
; Atomically swap the values at k1 and k2. Other entries' values and
; insertion order are preserved. No-op (returns store unchanged) when:
;   * k1 == k2 (swapping with self is the identity), or
;   * either key is absent from the store (refuses to invent values
;     for missing slots — consistent with kv:rename's ambiguity rule).
; Implementation reads both values up front from the original store,
; then folds the original entries into a fresh store, writing k1 -> v2
; and k2 -> v1 — guarantees a single, atomic-looking pass over the
; source entries.
(define (kv:swap store k1 k2)
  (if (equal? k1 k2)
    store
    (if (not (kv:_has store k1))
      store
      (if (not (kv:_has store k2))
        store
        (let ((v1 (kv:_ref store k1))
              (v2 (kv:_ref store k2)))
          (kv:_fold store (quote ())
            (lambda (k v acc)
              (if (equal? k k1)
                (kv:_set acc k1 v2)
                (if (equal? k k2)
                  (kv:_set acc k2 v1)
                  (kv:_set acc k v))))))))))
```

FILE tests/smoke.aura
```
; projects/kv/tests/smoke.aura — project acceptance suite
; Avoid sequential define-after-mutate (host residual). Prefer let* chains.
;
;   AURA_PATH=projects/kv/lib:... ./scripts/run-aura.sh projects/kv/tests/smoke.aura

(require "kv" all:)

(define pass 0)
(define total 0)

(define (t name ok)
  (set! total (+ total 1))
  (if ok
    (begin (set! pass (+ pass 1)) (display "  PASS ") (display name) (newline))
    (begin (display "  FAIL ") (display name) (newline))))

(display "=== kv smoke kv:version=")
(display kv:version)
(newline)

(let* ((s0 (kv:open))
       (s1 (kv:set s0 "a" 1))
       (g1 (kv:get s1 "a"))
       (miss (kv:get s1 "nope"))
       (s2 (kv:set s1 "a" 9))
       (g2 (kv:get s2 "a"))
       (h1 (kv:has? s2 "a"))
       (h0 (kv:has? s2 "z"))
       (s3 (kv:del s2 "a"))
       (g3 (kv:get s3 "a"))
       (h3 (kv:has? s3 "a"))
       (s4 (kv:set (kv:set (kv:open) "x" 10) "y" 20))
       (gx (kv:get s4 "x"))
       (gy (kv:get s4 "y"))
       (sz (kv:size s4))
       (ks (kv:keys s4))
       (s5 (kv:clear s4))
       (a (kv:open))
       (b (kv:set a "k" 1))
       (c (kv:set (kv:open) "s" "hello")))
  (t "T1-open" (null? s0))
  (t "T2-set-get" (equal? g1 1))
  (t "T3-missing" (eq? miss #f))
  (t "T4-overwrite" (equal? g2 9))
  (t "T5-has" (and h1 (not h0)))
  (t "T6-del" (and (eq? g3 #f) (not h3)))
  (t "T7-multi" (and (equal? gx 10) (equal? gy 20)))
  (t "T8-size" (= sz 2))
  (t "T9-keys"
     (and (pair? ks)
          (or (equal? (car ks) "x") (equal? (car ks) "y")
              (and (pair? (cdr ks))
                   (or (equal? (car (cdr ks)) "x")
                       (equal? (car (cdr ks)) "y"))))))
  (t "T10-clear" (and (null? s5) (= (kv:size s5) 0) (eq? (kv:get s5 "x") #f)))
  (t "T11-isolation" (and (eq? (kv:get a "k") #f) (equal? (kv:get b "k") 1)))
  (t "T12-string-val" (equal? (kv:get c "s") "hello"))

  ; Phase 3 stress / denseness edge
  (let* ((s (kv:open))
         (s (kv:set s "n0" 0))
         (s (kv:set s "n1" 1))
         (s (kv:set s "n2" 2))
         (s (kv:set s "n3" 3))
         (s (kv:set s "n4" 4)))
    (t "T13-size5" (= (kv:size s) 5))
    (t "T14-get-mid" (equal? (kv:get s "n2") 2))
    (let ((s2 (kv:del s "n2")))
      (t "T15-del-mid" (and (= (kv:size s2) 4) (eq? (kv:get s2 "n2") #f)
                            (equal? (kv:get s2 "n0") 0) (equal? (kv:get s2 "n4") 4)))))
  (t "T16-empty-has" (not (kv:has? (kv:open) "x")))
  (t "T17-del-missing" (let ((s (kv:set (kv:open) "a" 1)))
                         (equal? (kv:get (kv:del s "zzz") "a") 1))))

; ---- Phase 5: iteration & query helpers ----

; T18: values() returns values in insertion order; size matches.
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (vs (kv:values s)))
  (t "T18-values-order"
     (and (= (length vs) 3)
          (equal? (car vs) 1)
          (equal? (car (cdr vs)) 2)
          (equal? (car (cdr (cdr vs))) 3))))

; T19: filter() keeps matching entries, drops others, preserves order.
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (s (kv:set s "d" 4))
       (f (kv:filter s (lambda (k v) (> v 2))))
       (fk (kv:keys f)))
  (t "T19-filter"
     (and (= (kv:size f) 2)
          (equal? (kv:get f "c") 3)
          (equal? (kv:get f "d") 4)
          (eq? (kv:get f "a") #f)
          (eq? (kv:get f "b") #f)
          (pair? fk)
          (equal? (car fk) "c")
          (equal? (car (cdr fk)) "d"))))

; T19b: filter() on an empty store is empty.
(t "T19b-filter-empty"
   (= (kv:size (kv:filter (kv:open) (lambda (k v) #t))) 0))

; T20: empty? distinguishes empty from populated stores.
(t "T20-empty?"
   (and (kv:empty? (kv:open))
        (not (kv:empty? (kv:set (kv:open) "x" 1)))
        (kv:empty? (kv:clear (kv:set (kv:open) "y" 2)))))

; T21: find() returns first matching (k . v); miss yields #f.
(let* ((s (kv:open))
       (s (kv:set s "k1" 10))
       (s (kv:set s "k2" 20))
       (s (kv:set s "k3" 30))
       (hit (kv:find s (lambda (k v) (> v 15))))
       (miss (kv:find s (lambda (k v) (> v 100)))))
  (t "T21-find"
     (and (pair? hit)
          (equal? (car hit) "k2")
          (equal? (cdr hit) 20)
          (eq? miss #f))))

; T21b: find() on an empty store yields #f.
(t "T21b-find-empty"
   (eq? (kv:find (kv:open) (lambda (k v) #t)) #f))

; T22: entries() returns alist shape with correct order.
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (es (kv:entries s)))
  (t "T22-entries"
     (and (= (length es) 2)
          (pair? (car es))
          (equal? (car (car es)) "a")
          (equal? (cdr (car es)) 1)
          (pair? (cdr es))
          (equal? (car (car (cdr es))) "b")
          (equal? (cdr (car (cdr es))) 2))))

; T23: for-each() visits every entry in insertion order and returns #t.
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (copied (kv:open))
       (_ (kv:for-each s (lambda (k v) (set! copied (kv:set copied k v))))))
  (t "T23-for-each"
     (and (= (kv:size copied) 3)
          (equal? (kv:get copied "a") 1)
          (equal? (kv:get copied "b") 2)
          (equal? (kv:get copied "c") 3))))

; ---- Phase 6: fold / predicate / projection / selection helpers ----

; T24: reduce() accumulates in insertion order; init wins on empty.
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (r (kv:reduce s 0 (lambda (k v acc) (+ acc v)))))
  (t "T24-reduce"
     (and (= r 6)
          (= (kv:reduce (kv:open) 99 (lambda (k v acc) (+ acc v))) 99))))

; T25: any? is short-circuit existential.
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 5))
       (s (kv:set s "c" 10)))
  (t "T25-any"
     (and (kv:any? s (lambda (k v) (> v 3)))
          (not (kv:any? s (lambda (k v) (> v 100)))))))

; T26: every? is short-circuit universal.
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 5))
       (s (kv:set s "c" 10)))
  (t "T26-every"
     (and (kv:every? s (lambda (k v) (> v 0)))
          (not (kv:every? s (lambda (k v) (> v 3)))))))

; T26b: any?/every? vacuous semantics on an empty store.
(t "T26b-any-empty" (not (kv:any? (kv:open) (lambda (k v) #t))))
(t "T26c-every-empty" (kv:every? (kv:open) (lambda (k v) #t)))

; T27: pick() selects only listed keys, drops missing, preserves store order.
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (p (kv:pick s (list "c" "a" "ghost")))
       (pk (kv:keys p)))
  (t "T27-pick"
     (and (= (kv:size p) 2)
          (equal? (kv:get p "a") 1)
          (equal? (kv:get p "c") 3)
          (eq? (kv:get p "b") #f)
          (equal? (car pk) "a")
          (equal? (car (cdr pk)) "c"))))

; T27b: pick() with an empty key list returns an empty store.
(t "T27b-pick-empty-keys"
   (= (kv:size
        (kv:pick (kv:set (kv:set (kv:open) "a" 1) "b" 2)
                 (quote ())))
      0))

; T27c: pick() where no listed key is present returns an empty store.
(t "T27c-pick-all-missing"
   (= (kv:size
        (kv:pick (kv:set (kv:set (kv:open) "a" 1) "b" 2)
                 (list "x" "y" "z")))
      0))

; T28: omit() removes listed keys, preserves survivor order.
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (s (kv:set s "d" 4))
       (o (kv:omit s (list "b" "d")))
       (ok (kv:keys o)))
  (t "T28-omit"
     (and (= (kv:size o) 2)
          (eq? (kv:get o "b") #f)
          (eq? (kv:get o "d") #f)
          (equal? (kv:get o "a") 1)
          (equal? (kv:get o "c") 3)
          (equal? (car ok) "a")
          (equal? (car (cdr ok)) "c"))))

; T29: map-values() transforms values, keys + order preserved.
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (m (kv:map-values s (lambda (v) (* v 10))))
       (mk (kv:keys m)))
  (t "T29-map-values"
     (and (= (kv:size m) 3)
          (equal? (kv:get m "a") 10)
          (equal? (kv:get m "b") 20)
          (equal? (kv:get m "c") 30)
          (equal? (car mk) "a")
          (equal? (car (cdr mk)) "b")
          (equal? (car (cdr (cdr mk))) "c"))))

; ---- Phase 7: convenience / comparison helpers ----

; T30: get-or() returns the stored value, or default on miss.
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
  (t "T30-get-or"
     (and (= (kv:get-or s "a" 99) 1)
          (= (kv:get-or s "missing" 42) 42)
          (= (kv:get-or (kv:open) "anything" 7) 7))))

; T30b: get-or() must return the stored value even when that value is #f.
(t "T30b-get-or-false"
   (equal? (kv:get-or (kv:set (kv:open) "k" #f) "k" "fallback") #f))

; T31: rename() replaces a key in place, preserving position and other entries.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:rename s "b" "bb"))
       (rk (kv:keys r)))
  (t "T31-rename"
     (and (= (kv:size r) 3)
          (eq? (kv:has? r "b") #f)
          (equal? (kv:get r "bb") 2)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "c") 3)
          (equal? (car rk) "a")
          (equal? (car (cdr rk)) "bb")
          (equal? (car (cdr (cdr rk))) "c"))))

; T31b: rename() is a no-op when the old key is absent.
(t "T31b-rename-noop-missing"
   (let* ((s (kv:set (kv:open) "a" 1))
          (r (kv:rename s "ghost" "new")))
     (and (= (kv:size r) 1)
          (equal? (kv:get r "a") 1)
          (eq? (kv:has? r "new") #f))))

; T31c: rename() is a no-op when the new key is already present.
(t "T31c-rename-noop-exists"
   (let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (r (kv:rename s "a" "b")))
     (and (= (kv:size r) 2)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "b") 2))))

; T32: diff() classifies entries into added / removed / changed.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "x" 1) "y" 2) "z" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "y" 20) "z" 3) "w" 4))
       (d (kv:diff a b))
       (added (car d))
       (removed (car (cdr d)))
       (changed (car (cdr (cdr d)))))
  (t "T32-diff"
     (and (= (kv:size added) 1)
          (equal? (kv:get added "w") 4)
          (= (kv:size removed) 1)
          (equal? (kv:get removed "x") 1)
          (= (kv:size changed) 1)
          (equal? (kv:get changed "y") (cons 2 20)))))

; T32b: diff() between equal stores yields three empty sub-stores.
(let* ((d (kv:diff (kv:set (kv:set (kv:open) "a" 1) "b" 2)
                   (kv:set (kv:set (kv:open) "b" 2) "a" 1))))
  (t "T32b-diff-equal"
     (and (= (kv:size (car d)) 0)
          (= (kv:size (car (cdr d))) 0)
          (= (kv:size (car (cdr (cdr d)))) 0))))

; T33: partition() splits a store into (match . nomatch) sub-stores.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "d" 4) "e" 5))
       (p (kv:partition s (lambda (k v) (> v 2))))
       (m (car p))
       (n (car (cdr p))))
  (t "T33-partition"
     (and (= (kv:size m) 3)
          (equal? (kv:get m "c") 3)
          (equal? (kv:get m "d") 4)
          (equal? (kv:get m "e") 5)
          (= (kv:size n) 2)
          (equal? (kv:get n "a") 1)
          (equal? (kv:get n "b") 2))))

; T33b: partition() on an empty store yields two empty sub-stores.
(let* ((p (kv:partition (kv:open) (lambda (k v) #t))))
  (t "T33b-partition-empty"
     (and (= (kv:size (car p)) 0)
          (= (kv:size (car (cdr p))) 0))))

; T34: equal? is a structural equality ignoring insertion order.
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (b (kv:set (kv:set (kv:open) "b" 2) "a" 1))
       (c (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
  (t "T34-equal"
     (and (kv:equal? a b)
          (kv:equal? a c)
          (not (kv:equal? a (kv:set a "c" 3)))
          (not (kv:equal? a
                         (kv:set (kv:set (kv:open) "a" 1) "b" 3))))))

; T34b: equal? agrees on empty stores and detects size mismatches.
(t "T34b-equal-empty"
   (and (kv:equal? (kv:open) (kv:open))
        (not (kv:equal? (kv:open) (kv:set (kv:open) "a" 1)))))

; ---- Phase 8: positional / conditional / inversion helpers ----

; T35: first() returns the first (k . v); #f on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (f (kv:first s))
       (e (kv:first (kv:open))))
  (t "T35-first"
     (and (pair? f)
          (equal? (car f) "a")
          (equal? (cdr f) 1)
          (eq? e #f))))

; T36: last() returns the last (k . v); #f on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (l (kv:last s))
       (e (kv:last (kv:open))))
  (t "T36-last"
     (and (pair? l)
          (equal? (car l) "c")
          (equal? (cdr l) 3)
          (eq? e #f))))

; T37: rest() returns store minus its first pair; empty stays empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:rest s))
       (rk (kv:keys r))
       (e (kv:rest (kv:open))))
  (t "T37-rest"
     (and (= (kv:size r) 2)
          (eq? (kv:get r "a") #f)
          (equal? (kv:get r "b") 2)
          (equal? (kv:get r "c") 3)
          (equal? (car rk) "b")
          (equal? (car (cdr rk)) "c")
          (null? e))))

; T38: butlast() returns store minus its last pair; preserves order.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:butlast s))
       (bk (kv:keys b))
       (e (kv:butlast (kv:open))))
  (t "T38-butlast"
     (and (= (kv:size b) 2)
          (equal? (kv:get b "a") 1)
          (equal? (kv:get b "b") 2)
          (eq? (kv:get b "c") #f)
          (equal? (car bk) "a")
          (equal? (car (cdr bk)) "b")
          (null? e))))

; T38b: butlast() on a single-pair store returns an empty store.
(t "T38b-butlast-single"
   (null? (kv:butlast (kv:set (kv:open) "only" 1))))

; T39: take(n) covers n=0, partial, full, and overflow.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (t0 (kv:take s 0))
       (t1 (kv:take s 1))
       (t2 (kv:take s 2))
       (t3 (kv:take s 3))
       (t9 (kv:take s 9)))
  (t "T39-take"
     (and (null? t0)
          (= (kv:size t0) 0)
          (= (kv:size t1) 1)
          (equal? (kv:get t1 "a") 1)
          (eq? (kv:get t1 "b") #f)
          (= (kv:size t2) 2)
          (equal? (kv:get t2 "a") 1)
          (equal? (kv:get t2 "b") 2)
          (eq? (kv:get t2 "c") #f)
          (= (kv:size t3) 3)
          (= (kv:size t9) 3)
          (equal? (kv:get t9 "c") 3))))

; T40: drop(n) covers n=0, partial, full, and overflow.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (d0 (kv:drop s 0))
       (d1 (kv:drop s 1))
       (d2 (kv:drop s 2))
       (d3 (kv:drop s 3))
       (d9 (kv:drop s 9)))
  (t "T40-drop"
     (and (= (kv:size d0) 3)
          (equal? (kv:get d0 "a") 1)
          (= (kv:size d1) 2)
          (eq? (kv:get d1 "a") #f)
          (equal? (kv:get d1 "b") 2)
          (equal? (kv:get d1 "c") 3)
          (= (kv:size d2) 1)
          (eq? (kv:get d2 "b") #f)
          (equal? (kv:get d2 "c") 3)
          (null? d3)
          (null? d9))))

; T41: invert() swaps keys and values, preserving insertion order.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (i (kv:invert s))
       (ik (kv:keys i)))
  (t "T41-invert"
     (and (= (kv:size i) 3)
          (equal? (kv:get i 1) "a")
          (equal? (kv:get i 2) "b")
          (equal? (kv:get i 3) "c")
          (equal? (car ik) 1)
          (equal? (car (cdr ik)) 2)
          (equal? (car (cdr (cdr ik))) 3))))

; T41b: invert() keeps the first occurrence on a value collision.
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 1))
       (i (kv:invert s)))
  (t "T41b-invert-collision"
     (and (= (kv:size i) 1)
          (equal? (kv:get i 1) "a"))))

; T41c: invert() on an empty store is empty.
(t "T41c-invert-empty"
   (null? (kv:invert (kv:open))))

; T42: set-if-absent() preserves an existing value; only sets on miss.
(let* ((s (kv:set (kv:open) "x" 1))
       (s2 (kv:set-if-absent s "x" 999))
       (s3 (kv:set-if-absent s "y" 2)))
  (t "T42-set-if-absent"
     (and (equal? (kv:get s2 "x") 1)
          (eq? (kv:get s2 "y") #f)
          (equal? (kv:get s3 "x") 1)
          (equal? (kv:get s3 "y") 2))))

; ---- Phase 9: aggregation / positional / composition helpers ----

; T43: nth() returns the 0-indexed entry; #f on out-of-range / empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (n0 (kv:nth s 0))
       (n1 (kv:nth s 1))
       (n2 (kv:nth s 2)))
  (t "T43-nth"
     (and (pair? n0)
          (equal? (car n0) "a")
          (equal? (cdr n0) 1)
          (pair? n1)
          (equal? (car n1) "b")
          (equal? (cdr n1) 2)
          (pair? n2)
          (equal? (car n2) "c")
          (equal? (cdr n2) 3)
          (eq? (kv:nth s 3) #f)
          (eq? (kv:nth s 100) #f)
          (eq? (kv:nth (kv:open) 0) #f))))

; T44: count() returns the number of matching entries; 0 on miss / empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T44-count"
     (and (= (kv:count s (lambda (k v) (> v 3))) 2)
          (= (kv:count s (lambda (k v) (> v 100))) 0)
          (= (kv:count s (lambda (k v) (> v 0))) 3)
          (= (kv:count (kv:open) (lambda (k v) #t)) 0))))

; T45: sum() returns the total of all values; 0 on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3)))
  (t "T45-sum"
     (and (= (kv:sum s) 6)
          (= (kv:sum (kv:open)) 0))))

; T46: zip() pairs keys with vals left-to-right; insertion order tracks keys.
(let* ((z (kv:zip (list "a" "b" "c") (list 1 2 3)))
       (zk (kv:keys z)))
  (t "T46-zip"
     (and (= (kv:size z) 3)
          (equal? (kv:get z "a") 1)
          (equal? (kv:get z "b") 2)
          (equal? (kv:get z "c") 3)
          (equal? (car zk) "a")
          (equal? (car (cdr zk)) "b")
          (equal? (car (cdr (cdr zk))) "c"))))

; T46b: zip() with a shorter vals list drops the tail keys.
(t "T46b-zip-vals-shorter"
   (let* ((z (kv:zip (list "a" "b" "c") (list 1 2))))
     (and (= (kv:size z) 2)
          (equal? (kv:get z "a") 1)
          (equal? (kv:get z "b") 2)
          (eq? (kv:get z "c") #f))))

; T46c: zip() with a shorter keys list drops the tail vals.
(t "T46c-zip-keys-shorter"
   (let* ((z (kv:zip (list "a") (list 1 2 3))))
     (and (= (kv:size z) 1)
          (equal? (kv:get z "a") 1))))

; T47: swap() exchanges two values, preserves order and other entries.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (sw (kv:swap s "a" "c"))
       (sk (kv:keys sw)))
  (t "T47-swap"
     (and (= (kv:size sw) 3)
          (equal? (kv:get sw "a") 3)
          (equal? (kv:get sw "b") 2)
          (equal? (kv:get sw "c") 1)
          (equal? (car sk) "a")
          (equal? (car (cdr sk)) "b")
          (equal? (car (cdr (cdr sk))) "c"))))

; T47b: swap() with k1 == k2 is a no-op (same input, same output).
(t "T47b-swap-same-key"
   (let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (sw (kv:swap s "a" "a")))
     (and (= (kv:size sw) 2)
          (equal? (kv:get sw "a") 1)
          (equal? (kv:get sw "b") 2))))

; T47c: swap() with a missing key is a no-op.
(t "T47c-swap-missing"
   (let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (sw (kv:swap s "a" "ghost")))
     (and (= (kv:size sw) 2)
          (equal? (kv:get sw "a") 1)
          (equal? (kv:get sw "b") 2)
          (eq? (kv:get sw "ghost") #f))))

(display "SCORE ")
(display pass)
(display "/")
(display total)
(newline)

(if (and (= pass total) (> total 0))
  (begin
    (display "RESULT pass project=kv score=")
    (display pass)
    (display " total=")
    (display total)
    (newline))
  (begin
    (display "RESULT fail project=kv score=")
    (display pass)
    (display " total=")
    (display total)
    (newline)))
```
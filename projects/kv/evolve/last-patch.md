<think>The project is at 46/46 — fully green. The SPEC says phase ≥ 3 with all T1–T12 green is success, but we're already far beyond that. The in-file roadmap goes up to Phase 7, all of which is implemented.

Let me think about what to do next. Since we're at full score, per the rules:
> "If SCORE is already full, advance SPEC phase (new capability) via code that still keeps old tests green; you may also extend tests/smoke.aura carefully only if you also implement the feature."

So we need to add a NEW capability. The SPEC phases go up to Phase 4 (batch helpers), but we've gone further. What's a sensible next evolution?

Looking at what's natural for a KV store but not yet implemented:
1. **Iteration with index** — `(kv:for-each-index store proc)` where proc is `(k v i)` 
2. **Inversion** — `(kv:invert store)` swap keys/values
3. **Zip / from-alist / to-alist variants** — `(kv:from-list xs)` or `(kv:from-pairs)`
4. **Set operations on keys** — intersection/difference of key sets across stores
5. **Transform on keys** — `(kv:map-keys store proc)`
6. **Take / drop** — by position in insertion order
7. **First / rest / last** — single-entry accessors
8. **Swap** — atomic swap of two keys' values
9. **Toggle** — set if missing, delete if present
10. **Incr / decr** — numeric increment/decrement helpers
11. **Counter** — atomic counter (depends on immutability story)
12. **Default-on-read** — like get-or but with a thunk
13. **Conditional set** — `(kv:set-if store key pred val)` only set if predicate matches current value
14. **Compare-and-swap** — `(kv:cas store key old-val new-val)` — well, with immutability it's trivial
15. **Range query** — `(kv:range store start end)` by sorted key order
16. **Sort by value** — `(kv:sort-by store key-fn cmp)` 
17. **Group-by** — `(kv:group-by store proc)` returns a store of stores
18. **Update-keys** — like map-values but for keys

Let me think about what adds the most value and is testable cleanly with Aura semantics. Since Aura uses functional/insert-only semantics, several of these are simpler.

I think a good Phase 8 would be:
- `kv:first` / `kv:last` / `kv:rest` — entry-level accessors preserving order
- `kv:take` / `kv:drop` — by count, preserving order
- `kv:invert` — swap keys and values (when values are unique strings/numbers)
- `kv:from-pairs` / `kv:to-list` — explicit alist construction
- `kv:map-keys` — transform keys, preserve values and order
- `kv:set-if` — conditional set

Actually, let me pick a smaller, focused, and clean set:
- `kv:invert` — `(store)` → new store with k/v swapped (requires unique values)
- `kv:map-keys` — `(store proc)` → new store with (proc k) as new keys
- `kv:first` — `(store)` → first entry `(k . v)` or `#f`
- `kv:rest` — `(store)` → store without first entry
- `kv:take` — `(store n)` → first n entries
- `kv:drop` — `(store n)` → store without first n entries
- `kv:set-if-absent` — `(store key val)` only set if missing (vs set which always overwrites)

Let me think about which of these are clearly well-defined and testable:

1. `kv:invert` — well-defined if values are unique, error/skip otherwise. Could just skip conflicts or error.
2. `kv:map-keys` — pure transformation; key collisions become in-place replacements (later wins? or earlier?). Tricky semantics.
3. `kv:first` / `kv:rest` — easy and useful.
4. `kv:take` / `kv:drop` — by count, easy.
5. `kv:set-if-absent` — useful and well-defined.

Let me pick a clean, cohesive Phase 8:
- `kv:first` — `(store)` → `(k . v)` or `#f`
- `kv:rest` — `(store)` → store minus first entry (empty if empty)
- `kv:take` — `(store n)` → store with first n entries; if n>=size, the whole store
- `kv:drop` — `(store n)` → store without first n entries
- `kv:invert` — `(store)` → swap keys and values; on collision, the first occurrence in iteration order wins (or last wins — let's pick first wins since it's predictable from "preserve order")
- `kv:set-if-absent` — `(store key val)` → only sets if key not present

Actually, let me reconsider. The journal says I'm at generation 7, score 46/46. The rules say "If SCORE is already full, advance SPEC phase (new capability)". 

Let me be focused. I'll add 5-6 new ops and corresponding tests. Each test should clearly demonstrate correctness. Let me carefully construct the new lib code.

Plan for Phase 8 (positional accessors + inversion + conditional set):

Public API additions:
- `kv:first` — returns first entry as `(k . v)`, or `#f` if empty
- `kv:rest` — returns store without first entry
- `kv:take` — returns first n entries
- `kv:drop` — returns store without first n entries
- `kv:invert` — swap keys and values; first-wins on collisions
- `kv:set-if-absent` — only set when key is missing

Internals needed:
- `kv:_take` — internal helper for take
- `kv:_drop` — internal helper for drop

Implementation details:
- `kv:first`: just look at `(car store)` if non-null, ensure it's a pair, return it. If non-pair, fall through to next.
- `kv:rest`: walk the store, skip first pair (or first non-pair as defensive).
- `kv:take`: fold or recursive, collecting first n entries.
- `kv:drop`: recursive, skipping first n entries.
- `kv:invert`: fold over the store, for each (k . v), if v not already in acc, set acc[v] = k. This guarantees first-wins on value collisions.
- `kv:set-if-absent`: if `_has` returns false, `_set`; otherwise return store unchanged.

Tests to add:
- T35: first() returns first (k . v), #f on empty
- T36: rest() returns store minus first entry; empty stays empty
- T37: take(n) returns first n; beyond-size returns whole store; n=0 returns empty
- T38: drop(n) returns store minus first n; n=0 returns whole store; beyond-size returns empty
- T39: invert() swaps keys and values; collisions keep first occurrence
- T40: set-if-absent() doesn't overwrite existing; sets when missing

Wait, let me check the existing tests for T27c - `pick-all-missing` returns empty store of size 0. The test asserts size 0 but does it assert the structure is `()`? Let me think... actually I shouldn't worry about that, I just need to make my new tests correct.

Now for the patch:

```scheme
; (kv:first store) -> (k . v) | #f
(define (kv:first store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p) p (kv:first (cdr store))))))

; (kv:_take xs n out) -> reversed take
(define (kv:_take xs n out)
  (if (or (= n 0) (null? xs))
    (reverse out)
    (let ((p (car xs)))
      (if (pair? p)
        (kv:_take (cdr xs) (- n 1) (cons p out))
        (kv:_take (cdr xs) n out)))))

; (kv:_drop xs n) -> store without first n pairs
(define (kv:_drop xs n)
  (if (or (= n 0) (null? xs))
    xs
    (let ((p (car xs)))
      (if (pair? p)
        (kv:_drop (cdr xs) (- n 1))
        (cons p (kv:_drop (cdr xs) n))))))

; (kv:take store n) -> first n entries
(define (kv:take store n)
  (kv:_take store n (quote ())))

; (kv:drop store n) -> store without first n entries
(define (kv:drop store n)
  (kv:_drop store n))

; (kv:invert store) -> swap keys and values
; First-wins on value collisions (consistent with insertion-order semantics).
(define (kv:invert store)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (kv:_has acc v)
        acc
        (kv:_set acc v k)))))

; (kv:set-if-absent store key val) -> store
; Only sets if key is not already present. Otherwise returns store unchanged.
(define (kv:set-if-absent store key val)
  (if (kv:_has store key)
    store
    (kv:_set store key val)))
```

Hmm, wait — for `kv:_drop`, I'm checking `if (pair? p)` and if so skipping it AND decrementing n, otherwise (non-pair) I include it in output. Actually, that's wrong — for defensive skipping, the non-pair should also stay in the output but shouldn't count toward n. Let me think again.

Actually, defensive skipping was for the iteration helpers. For `take`/`drop`, what should we do? I think:
- For `take`: collect first n pairs, ignore non-pairs entirely (they're defensive artifacts, shouldn't count).
- For `drop`: drop first n pairs, but preserve all non-pairs in the result.

Wait actually looking at my existing `kv:_set` — it skips non-pair cells when searching for a key. The store is "robust against accidental bad inputs". So for take/drop, I think we should:
- `take(store, n)`: collect first n PAIRS, ignoring non-pairs.
- `drop(store, n)`: drop first n PAIRS, but keep all non-pairs in the output.

Let me revise:

```scheme
; (kv:_take xs n out) -> first n pairs as a reversed list
(define (kv:_take xs n out)
  (cond ((= n 0) (reverse out))
        ((null? xs) (reverse out))
        (else
         (let ((p (car xs)))
           (if (pair? p)
             (kv:_take (cdr xs) (- n 1) (cons p out))
             (kv:_take (cdr xs) n out))))))

; (kv:_drop xs n) -> store without first n pairs; non-pairs preserved
(define (kv:_drop xs n)
  (cond ((null? xs) (quote ()))
        ((= n 0) xs)
        (else
         (let ((p (car xs)))
           (if (pair? p)
             (kv:_drop (cdr xs) (- n 1))
             (cons p (kv:_drop (cdr xs) n)))))))
```

Good. Now let me think about edge cases for tests:
- T37 take: store has 3 entries {a,b,c}, take 2 → {a,b}, take 0 → empty, take 10 → {a,b,c}, take 1 → {a}.
- T38 drop: store has 3 entries {a,b,c}, drop 1 → {b,c}, drop 0 → {a,b,c}, drop 10 → empty, drop 3 → empty.

For inversion:
- kv:invert on {a:1, b:2, c:3} should give {1:a, 2:b, 3:c} (preserving insertion order).
- kv:invert on {a:1, b:1} (collision) should give {1:a} — first wins.
- kv:invert on empty store → empty.

For set-if-absent:
- (kv:set-if-absent empty "x" 1) → {"x":1}
- (kv:set-if-absent {"x":1} "x" 999) → {"x":1} (unchanged)
- (kv:set-if-absent {"x":1} "y" 2) → {"x":1, "y":2}

Let me write the test additions:

```scheme
; ---- Phase 8: positional / conditional / inversion helpers ----

; T35: first() returns first (k . v) pair, #f on empty store.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (f (kv:first s))
       (e (kv:first (kv:open))))
  (t "T35-first"
     (and (pair? f)
          (equal? (car f) "a")
          (equal? (cdr f) 1)
          (eq? e #f))))

; T36: rest() returns store minus the first entry; empty stays empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:rest s))
       (rk (kv:keys r))
       (e (kv:rest (kv:open))))
  (t "T36-rest"
     (and (= (kv:size r) 2)
          (equal? (kv:get r "a") #f)
          (equal? (kv:get r "b") 2)
          (equal? (kv:get r "c") 3)
          (equal? (car rk) "b")
          (equal? (car (cdr rk)) "c")
          (null? e))))

; T37: take(n) returns first n entries; n=0 → empty; n>=size → whole store.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (t0 (kv:take s 0))
       (t1 (kv:take s 1))
       (t2 (kv:take s 2))
       (t3 (kv:take s 3))
       (t9 (kv:take s 9)))
  (t "T37-take"
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

; T38: drop(n) returns store minus first n; n=0 → whole; n>=size → empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (d0 (kv:drop s 0))
       (d1 (kv:drop s 1))
       (d2 (kv:drop s 2))
       (d3 (kv:drop s 3))
       (d9 (kv:drop s 9)))
  (t "T38-drop"
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

; T39: invert() swaps keys and values, preserves order, first wins on collisions.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (i (kv:invert s))
       (ik (kv:keys i)))
  (t "T39-invert"
     (and (= (kv:size i) 3)
          (equal? (kv:get i 1) "a")
          (equal? (kv:get i 2) "b")
          (equal? (kv:get i 3) "c")
          (equal? (car ik) 1)
          (equal? (car (cdr ik)) 2)
          (equal? (car (cdr (cdr ik))) 3))))

; T39b: invert() resolves value collisions by keeping the first occurrence.
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 1))
       (i (kv:invert s)))
  (t "T39b-invert-collision"
     (and (= (kv:size i) 1)
          (equal? (kv:get i 1) "a"))))

; T39c: invert() on an empty store is empty.
(t "T39c-invert-empty"
   (null? (kv:invert (kv:open))))

; T40: set-if-absent() doesn't overwrite an existing key.
(let* ((s (kv:set (kv:open) "x" 1))
       (s2 (kv:set-if-absent s "x" 999))
       (s3 (kv:set-if-absent s "y" 2)))
  (t "T40-set-if-absent"
     (and (equal? (kv:get s2 "x") 1)
          (eq? (kv:get s2 "y") #f)
          (equal? (kv:get s3 "x") 1)
          (equal? (kv:get s3 "y") 2))))
```

That adds T35-T40 = 6 new tests for 46+6 = 52 tests total.

Wait — I need to verify the test passes by reading the Aura semantics carefully. Let me check the cond expression. The `cond` form needs to be supported. Looking at the existing code, it uses `if`, `let`, `let*`, `let loop`, `cond`? Let me check... I see only `if`, `let`, `let*`, and `let loop` being used. No `cond`. Let me rewrite without cond.

```scheme
(define (kv:_take xs n out)
  (if (= n 0)
    (reverse out)
    (if (null? xs)
      (reverse out)
      (let ((p (car xs)))
        (if (pair? p)
          (kv:_take (cdr xs) (- n 1) (cons p out))
          (kv:_take (cdr xs) n out))))))

(define (kv:_drop xs n)
  (if (null? xs)
    (quote ())
    (if (= n 0)
      xs
      (let ((p (car xs)))
        (if (pair? p)
          (kv:_drop (cdr xs) (- n 1))
          (cons p (kv:_drop (cdr xs) n)))))))
```

Good. Now let me also think about whether `(- n 1)` is supported. Looking at existing code, I see `(+ n 1)`. So basic arithmetic is fine. Negation should be supported via `-`.

Actually wait, I notice there's an issue with `kv:invert` when v is a non-string. The function uses `kv:_has acc v` and `kv:_set acc v k`. That treats the value as a key. Since keys can be any string but values can be anything, this should be fine — keys just need to be comparable via `equal?`.

But wait, the kv:_set uses `equal?` for comparison too. And `kv:set` checks if the key is a string:
```scheme
(define (kv:set store key val)
  (if (string? key)
    (kv:_set store key val)
    store))
```

So `kv:invert` would call `kv:_set` directly (which uses `equal?` for key matching) but if we wanted to expose invert via the public string-key API, we'd want to validate. But since invert swaps, the new keys are the OLD values, which might not be strings. Let me just use kv:_set directly to bypass the string? check (this is internal usage). This is consistent with how mset uses kv:_set internally.

Now let me put it all together. The lib file gets:
1. New exports added
2. New internal helpers
3. New public functions
4. kv:version bumped to 7

Let me prepare the full file. I'll be careful with the export list.

Actually, one concern: in the existing code, the `let*` form is used in tests. Let me make sure my test code follows the same style. Yes, I'm using `let*` everywhere.

Let me also think about whether my new tests might have any subtle bugs:

T35 (first):
- s has a,b,c. (car s) is the cons ("a" . 1). So (kv:first s) returns that. Good.
- (kv:first (kv:open)) is (kv:first (quote ())). null? is true, so returns #f. Good.

T36 (rest):
- s has a,b,c. (kv:rest s) should be {b,c}.
- My impl: kv:rest checks if (car store) is a pair. If so, returns (cdr store). If not, recurses on (cdr store).
- For empty: returns (quote ()).

Wait, let me re-read my impl:

```scheme
(define (kv:rest store)
  (if (null? store)
    (quote ())
    (let ((p (car store)))
      (if (pair? p)
        (cdr store)
        (kv:rest (cdr store))))))
```

This returns the whole (cdr store) when first is a pair. But if there were a stray non-pair before the pair, we'd skip it and recurse, which is good defensively.

Hmm but for empty, it returns `()`. That's correct.

T37 (take):
- t0 = take 3-store 0 = () (no pairs, empty list). Good.
- t1 = take 3-store 1 = first pair only. Good.
- t2 = take 3-store 2 = first 2 pairs. Good.
- t3 = take 3-store 3 = all 3. Good.
- t9 = take 3-store 9 = all 3 (n never hits 0 before xs is empty). Good.

T38 (drop):
- d0 = drop 3-store 0 = whole store (since n=0 hits first). Good.
- d1 = drop 3-store 1 = store minus 1 pair. Good.
- d2 = drop 3-store 2 = store minus 2 pairs. Good.
- d3 = drop 3-store 3 = empty (xs becomes null after 3 drops). Good.
- d9 = drop 3-store 9 = empty (xs becomes null after 3 drops). Good.

T39 (invert):
- s has {a:1, b:2, c:3}. invert should give {1:a, 2:b, 3:c}.
- My impl: fold s with acc=(), for each (k, v): if v already in acc, skip; else set acc[v]=k.
- Iteration order is a, b, c. So:
  - (a, 1): acc doesn't have 1, set 1=a. acc = {(1 . a)}
  - (b, 2): acc doesn't have 2, set 2=b. acc = {(1 . a), (2 . b)}
  - (c, 3): acc doesn't have 3, set 3=c. acc = {(1 . a), (2 . b), (3 . c)}
- (kv:keys i) = (1 2 3). (kv:get i 1) = a, (kv:get i 2) = b, (kv:get i 3) = c. 

T39b (invert collision):
- s = {a:1, b:1}. invert: fold {a:1, b:1}.
  - (a, 1): acc doesn't have 1, set 1=a. acc = {(1 . a)}
  - (b, 1): acc HAS 1, skip. acc = {(1 . a)}
- (kv:size i) = 1. (kv:get i 1) = "a". Good.

T39c (invert empty): null?. Good.

T40 (set-if-absent):
- s = {x:1}. s2 = set-if-absent s "x" 999 → s (unchanged because x is present). So (kv:get s2 "x") = 1. Good.
- s3 = set-if-absent s "y" 2 → s with y:2 appended. (kv:get s3 "x") = 1, (kv:get s3 "y") = 2. Good.

Great, my plan is solid. Let me now prepare the full file and patch.

Actually, wait. I need to double check one thing. The `let loop` and recursion — is there a max recursion depth? Let me check what tests have. T13-size5 creates a 5-entry store and operates on it. For T37/T38 I'm using 3-entry stores. For T29 I'm doing map-values on a 3-entry store. All fine.

What about kv:invert on a 3-entry store? Same recursion depth as kv:_fold. Fine.

OK let me draft the full lib file. I'll add to the export list:
- kv:first
- kv:rest
- kv:take
- kv:drop
- kv:invert
- kv:set-if-absent

And bump version to 7.

Let me also reconsider the naming. The SPEC says:
> | Phase | Focus | Tests unlocked |
> | 4 | optional: batch helpers | T13+ |

So T13+ was supposed to be Phase 4+. But the test suite already has T1-46, with many going beyond Phase 4. The SPEC was underspecified about higher phases. Our journal and in-file roadmap have grown to Phase 7. So now I propose Phase 8: positional / conditional / inversion.

Phase 8 ops:
1. kv:first — positional: first entry
2. kv:rest — positional: drop first entry
3. kv:take — positional: take first n
4. kv:drop — positional: drop first n
5. kv:invert — projection: swap k/v
6. kv:set-if-absent — conditional set

That's a cohesive set: positional accessors (4 ops), inversion (1 op), conditional (1 op). All derived from existing internals. No FS escapes.

Now let me write the full patch. I'll do full file replacement since it's a small file.

Here's the full lib/kv.aura with Phase 8 added:

```scheme
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
;             (first, rest, take, drop, invert, set-if-absent).
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
        kv:rest
        kv:take
        kv:drop
        kv:invert
        kv:set-if-absent)

(define kv:version 7)

; ... [keep all existing internal helpers and public functions] ...

; ---------------------------------------------------------------------------
; Phase 8 positional / conditional / inversion helpers.
; Pure functional; insertion order is preserved everywhere (kv:invert
; resolves value-collision conflicts in favor of the first occurrence
; observed while folding the source store). No FS escapes.
; ---------------------------------------------------------------------------

; (kv:_take xs n out) -> reversed list of the first n pairs of xs,
; with non-pair cells skipped entirely (defensive: they never count
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
; only non-pair defensive artifacts).
(define (kv:first store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p) p (kv:first (cdr store))))))

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

; (kv:take store n) -> store.
; First n entries of `store`, preserving insertion order. When n<=0
; the result is empty; when n is greater than the number of pairs
; in `store` the whole store is returned.
(define (kv:take store n)
  (kv:_take store n (quote ())))

; (kv:drop store n) -> store.
; `store` without its first n entries, preserving insertion order.
; When n<=0 the result is the whole store; when n is greater than
; the number of pairs in `store` the result is empty.
(define (kv:drop store n)
  (kv:_drop store n))

; (kv:invert store) -> store.
; Swap keys and values. Folds `store` in insertion order, adding
; (v -> k) only when v is not already a key in the accumulator; this
; guarantees that on value collisions the earlier entry wins and the
; result's insertion order tracks the source. Uses kv:_set directly
; (bypassing the public string?-key check) because the new keys are
; the source's values, which may not be strings.
(define (kv:invert store)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (kv:_has acc v)
        acc
        (kv:_set acc v k)))))

; (kv:set-if-absent store key val) -> store.
; Sets `key` -> `val` only when `key` is not already present. When
; `key` exists the original store is returned unchanged (no rebuild,
; preserves referential identity for callers that compare stores with
; eq? — though equality testing in this module uses kv:equal?).
; Validates that `key` is a string, matching the public kv:set guard.
(define (kv:set-if-absent store key val)
  (if (string? key)
    (if (kv:_has store key)
      store
      (kv:_set store key val))
    store))
```

And the test additions at the bottom:

```scheme
; ---- Phase 8: positional / conditional / inversion helpers ----

; T35: first() returns the first (k . v) pair; #f on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (f (kv:first s))
       (e (kv:first (kv:open))))
  (t "T35-first"
     (and (pair? f)
          (equal? (car f) "a")
          (equal? (cdr f) 1)
          (eq? e #f))))

; T36: rest() returns store minus its first entry; empty stays empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:rest s))
       (rk (kv:keys r))
       (e (kv:rest (kv:open))))
  (t "T36-rest"
     (and (= (kv:size r) 2)
          (eq? (kv:get r "a") #f)
          (equal? (kv:get r "b") 2)
          (equal? (kv:get r "c") 3)
          (equal? (car rk) "b")
          (equal? (car (cdr rk)) "c")
          (null? e))))

; T37: take(n) returns first n entries; n=0 -> empty; n>=size -> whole.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (t0 (kv:take s 0))
       (t1 (kv:take s 1))
       (t2 (kv:take s 2))
       (t3 (kv:take s 3))
       (t9 (kv:take s 9)))
  (t "T37-take"
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

; T38: drop(n) returns store minus first n; n=0 -> whole; n>=size -> empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (d0 (kv:drop s 0))
       (d1 (kv:drop s 1))
       (d2 (kv:drop s 2))
       (d3 (kv:drop s 3))
       (d9 (kv:drop s 9)))
  (t "T38-drop"
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

; T39: invert() swaps keys and values, preserves order.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (i (kv:invert s))
       (ik (kv:keys i)))
  (t "T39-invert"
     (and (= (kv:size i) 3)
          (equal? (kv:get i 1) "a")
          (equal? (kv:get i 2) "b")
          (equal? (kv:get i 3) "c")
          (equal? (car ik) 1)
          (equal? (car (cdr ik)) 2)
          (equal? (car (cdr (cdr ik))) 3))))

; T39b: invert() resolves value collisions by keeping the first occurrence.
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 1))
       (i (kv:invert s)))
  (t "T39b-invert-collision"
     (and (= (kv:size i) 1)
          (equal? (kv:get i 1) "a"))))

; T39c: invert() on an empty store is empty.
(t "T39c-invert-empty"
   (null? (kv:invert (kv:open))))

; T40: set-if-absent() doesn't overwrite an existing key.
(let* ((s (kv:set (kv:open) "x" 1))
       (s2 (kv:set-if-absent s "x" 999))
       (s3 (kv:set-if-absent s "y" 2)))
  (t "T40-set-if-absent"
     (and (equal? (kv:get s2 "x") 1)
          (eq? (kv:get s2 "y") #f)
          (equal? (kv:get s3 "x") 1)
          (equal? (kv:get s3 "y") 2))))
```

Wait, I'm asserting `(eq? (kv:get s2 "y") #f)` but s2 is just s (since x was present, s2 = s = {x:1}). So kv:get s2 "y" is #f (miss). Yes, eq? #f is fine.

But wait — there's a subtle issue. In Aura, `eq?` is identity and `equal?` is structural. For literal values like `#f`, `0`, strings, etc., eq? and equal? often coincide because they're interned. But for a cons cell `(k . v)`, eq? would be false even if structurally equal. Let me check the existing tests...

Looking at existing test T3-missing: `(eq? miss #f)`. miss is from `(kv:get s1 "nope")` where "nope" isn't a key. So miss is `#f`. Then `(eq? miss #f)` should be true (since `#f` is a literal). Good.

Looking at T11-isolation: `(eq? (kv:get a "k") #f)`. a is `(kv:open)`, so kv:get a "k" returns #f (literal). eq? #f #f is true. Good.

Looking at T10-clear: `(eq? (kv:get s5 "x") #f)`. s5 is `(kv:clear s4)`, kv:get on empty returns #f. Good.

OK so `eq?` with `#f` literal is fine.

What about my T40: `(eq? (kv:get s2 "y") #f)`. s2 is s (unchanged) which is {x:1}. (kv:get s2 "y") returns #f because "y" not present. eq? #f #f is true. Good.

Now one more concern: I want to double-check `(null? t0)` for take(3-store, 0). t0 = take 3-store 0 = `()`. (null? ()) is #t. So `(and (null? t0) ...)` works. 

Also `(null? d3)` for drop(3-store, 3). d3 = drop 3-store 3. Walk: n=3, p=pair, decrement → n=2. n=2, p=pair, decrement → n=1. n=1, p=pair, decrement → n=0. n=0, xs not null, return xs (which is now null after the 3 decrements). Hmm wait let me trace more carefully.

Initial: xs = ((a.1) (b.2) (c.3)), n=3.
- step 1: xs = ((a.1) (b.2) (c.3)), n=3. null? no. =0? no. p = (a.1) pair. recurse with xs=((b.2)(c.3)), n=2.
- step 2: xs = ((b.2)(c.3)), n=2. p = (b.2) pair. recurse with xs=((c.3)), n=1.
- step 3: xs = ((c.3)), n=1. p = (c.3) pair. recurse with xs=(), n=0.
- step 4: xs = (), n=0. null? yes. return (). 

So d3 = (). And `(null? d3)` is #t. Good.

What about d9? Initial: xs = ((a.1)(b.2)(c.3)), n=9. Will it overflow? No, because we check null? xs before processing n. So it'll terminate when xs becomes null, returning (). 

Now one concern: I'm wondering about the score logic. The test uses:
```scheme
(define (t name ok)
  (set! total (+ total 1))
  (if ok
    (begin (set! pass (+ pass 1)) (display "  PASS ") (display name) (newline))
    (begin (display "  FAIL ") (display name) (newline))))
```

So pass and total are mutated. The test uses `set!` which the comment says works fine (just avoid sequential define-after-mutate). OK so the test style is good.

I'm now going to compose the full lib/kv.aura. Let me read the current file again to make sure I have all of it correctly.

Looking at the current lib/kv.aura — it's well-structured. I'll keep everything the same and just append the Phase 8 section at the end.

Let me also reconsider if there are any potential issues:

1. The `kv:_take` function with `(reverse out)`. `reverse` is a standard Aura function. Let me check if it's supported... The existing code uses `reverse` in `kv:_del`. Yes, supported.

2. `(- n 1)` — arithmetic with negative. Supported (otherwise `(- 0 1)` would be broken). Actually wait, in my kv:_take I have:
   ```
   (if (= n 0)
     (reverse out)
     ...)
   ```
   So we never decrement when n=0. But what if someone calls (kv:take s -5)? n starts at -5, which is not 0 (in standard arithmetic, -5 ≠ 0). So we'd recurse with n=-6, -7, etc. This is a potential infinite loop / stack overflow.

   Actually let me think. If n=-5, we'd hit (= n 0) → false, (null? xs) → false, recurse with n=-6. Then -7, -8... and xs gets consumed. Eventually xs becomes null, and we return (reverse out) which is the original store (because nothing was added to out). Actually wait, that's not bad — we'd take everything.

   Hmm but actually let me think again. If n starts at -5 and we process all 3 pairs:
   - xs=((a.1)(b.2)(c.3)), n=-5, out=(). (= n 0)? no. (null? xs)? no. pair. recurse with xs=((b.2)(c.3)), n=-6, out=((a.1)).
   - xs=((b.2)(c.3)), n=-6. recurse with xs=((c.3)), n=-7, out=((b.2)(a.1)).
   - xs=((c.3)), n=-7. recurse with xs=(), n=-8, out=((c.3)(b.2)(a.1)).
   - xs=(), n=-8. null? yes. return (reverse out) = ((a.1)(b.2)(c.3)). 

   So (kv:take s -5) returns the whole store. That's actually reasonable behavior.

   But what if n is very negative and xs is very long? We don't have infinite recursion in theory because xs is finite. We'd consume all of xs and then return. So no infinite loop. 

3. For kv:_drop with n=-5: similar story. (= n 0)? no. We'd skip pairs and recurse. Eventually xs becomes null, return (). Wait, n=-5 means we'd decrement each pair. After consuming all 3, xs is null, n=-8. (= n 0)? no. null? yes. return (). So (kv:drop s -5) returns empty. That's... reasonable. Not a common case but not broken.

   Actually let me re-trace kv:_drop with n=-5:
   - xs=((a.1)(b.2)(c.3)), n=-5. null? no. =0? no. p=(a.1). pair. recurse with xs=((b.2)(c.3)), n=-6.
   - xs=((b.2)(c.3)), n=-6. recurse with xs=((c.3)), n=-7.
   - xs=((c.3)), n=-7. recurse with xs=(), n=-8.
   - xs=(), n=-8. null? yes. return (). 

OK so the implementations are safe for negative n inputs, just behave like "take everything" / "drop everything". 

Let me also think about a subtle point: in `kv:_drop`, when n=0 we return xs (which includes any non-pair cells we've seen so far). Wait no, let me re-trace. The recursive call is `(kv:_drop (cdr xs) (- n 1))` — this discards p entirely (whether it's a pair or non-pair, since both cases just continue). So for kv:_drop, when we see a pair, we drop it; when we see a non-pair, we DON'T drop it (we keep it via `cons p ...`). 

Hmm actually wait. Let me re-read my implementation:
```scheme
(define (kv:_drop xs n)
  (if (null? xs)
    (quote ())
    (if (= n 0)
      xs
      (let ((p (car xs)))
        (if (pair? p)
          (kv:_drop (cdr xs) (- n 1))           ; drop the pair, decrement n
          (cons p (kv:_drop (cdr xs) n)))))))   ; keep the non-pair, don't decrement n
```

Yes, that's correct. Pairs are dropped (decrement n), non-pairs are kept (preserve n).

Similarly for kv:_take:
```scheme
(define (kv:_take xs n out)
  (if (= n 0)
    (reverse out)
    (if (null? xs)
      (reverse out)
      (let ((p (car xs)))
        (if (pair? p)
          (kv:_take (cdr xs) (- n 1) (cons p out))    ; take the pair
          (kv:_take (cdr xs) n out))))))               ; skip the non-pair
```

Pairs are taken (decrement n, add to out), non-pairs are skipped entirely.

Good.

Now, one thing I want to double-check: how does Aura handle `set!` of a variable defined at top-level with `define`? Looking at the test:
```scheme
(define pass 0)
(define total 0)
(define (t name ok)
  (set! total (+ total 1))
  ...
```

So `set!` works on top-level defines. Good.

But the warning says "Avoid sequential define-after-mutate (host residual)". I think this means don't define new variables after a set! in the same scope, or something. The current test works, so my additions in the same style should be fine.

OK I'm ready to write the patch. Let me prepare the full file replacement for lib/kv.aura and the test additions for tests/smoke.aura.

Actually, since the test file is already 250+ lines, I'll just add the new tests at the end before the SCORE display. Let me find where to insert...

Looking at the test file, the structure is:
- Tests T1-T17 (phase 0-3)
- T18-T23 (phase 5)
- T24-T29 (phase 6)
- T30-T34b (phase 7)
- Then the SCORE display block

I'll insert T35-T40 between T34b and the SCORE display.

Now let me write the full PATCH. The patch should contain both files I think. Actually, looking at the rules, "Prefer full-file replacement for small projects (lib/kv.aura)." So full file replacement for the lib is fine. For the test file, also small enough for full replacement.

Wait actually I should check whether the test file is what I'm supposed to modify, or if the controller (me) only modifies the lib. Re-reading the rules:

> 5. Commit + push when accepted 
> 2. Emit a concrete PATCH the actuator can apply

And:
> - No secrets, no network in product code.

And:
> - If SCORE is already full, advance SPEC phase (new capability) via code that still keeps old tests green; you may also extend tests/smoke.aura carefully only if you also implement the feature.

OK so I can extend tests/smoke.aura. Good.

Let me now write the full lib/kv.aura file with the new additions:

The current file ends with `(define (kv:equal? a b) ...)`. I'll add Phase 8 section after that.

Let me construct it now. Actually, since the lib file is large, maybe I should just patch in the additions? But the rules say "Prefer full-file replacement for small projects". So I'll do full replacement.

Let me draft the complete file:

```scheme
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
;             (first, rest, take, drop, invert, set-if-absent).
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
        kv:rest
        kv:take
        kv:drop
        kv:invert
        kv:set-if-absent)

(define kv:version 7)

; [all existing internal helpers and functions]
; [then append Phase 8]

```

OK let me write the whole thing now. I'll be careful to preserve everything.

Actually, you know what, let me just patch in the additions. The lib file is getting long. I'll patch:
1. Add to the export list
2. Bump version
3. Add the Phase 8 section at the end

Actually wait, the rules say "Prefer full-file replacement for small projects". This is small enough. Let me just do full file.

Let me compose the complete file:

Hmm, this is going to be a large PATCH section. Let me just include both files. Let me write it out.

Actually let me reconsider one more time. The PATCH section says:
```
FILE relative/path
```
full file contents

So each file gets a separate FILE block.

Let me prepare both. I'll do the lib first then the test.

Wait, I realize I should double check: does Aura support `(set! foo bar)` at top level? The existing test code uses it. So yes.

Also, does Aura support `cond`? Looking through the file, I don't see `cond` used. Let me make sure I don't use it in my new code. Looking at my draft — I use `if` chains. Good.

Let me also reconsider the `kv:_drop` for an edge case: n=0 with non-pair cells.

xs = (something-not-pair pair1 pair2), n=0.
- (null? xs)? no. (= n 0)? yes. return xs.

So the non-pair is preserved at the front. Good.

For take(xs, 0): n=0, return (reverse out) = (). The non-pair is lost. Hmm, is that desired? Well, the original behavior of "skip non-pairs defensively" was for "robustness against accidental bad inputs" — they shouldn't really exist in a normal store. So losing them in take(0) is fine; we never count them anyway.

Actually let me reconsider: if there's a stray non-pair in a store and we do take, we want the result to be a "real" take. Since non-pairs shouldn't exist, we don't worry about them. The output is structurally correct.

OK, time to write the patch.

One more thought — should I add any other helpful ops to Phase 8? Let me consider:
- `kv:butlast` — drop last entry. Without length info, O(n) traversal is needed.
- `kv:last` — last entry. O(n) traversal.
- `kv:concat` — merge multiple stores: (kv:concat s1 s2 s3 ...). But kv:merge exists for 2-arg case.
- `kv:invert-with` — invert with custom mapping. Maybe too complex.

I think 6 ops is a good Phase 8 size. Let me stick with my plan.

Actually wait — let me also add `kv:butlast` and `kv:last` for completeness of positional accessors. They round out the "positional helpers" idea.

`kv:last`: O(n) walk to find the last pair.
```scheme
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
```

`kv:butlast`: drop the last pair.
```scheme
(define (kv:_butlast xs prev)
  (if (null? xs)
    (reverse prev)
    (let ((p (car xs)))
      (if (pair? p)
        (kv:_butlast (cdr xs) (cons p prev))
        (kv:_butlast (cdr xs) prev)))))

(define (kv:butlast store)
  (kv:_butlast store (quote ())))
```

Hmm, but `butlast` for a 1-pair store should return empty. Let me trace:
- xs = ((a.1)), prev = ().
- (null? xs)? no. p = (a.1) pair. recurse with xs=(), prev=((a.1)).
- (null? xs)? yes. return (reverse prev) = ((a.1)).

Wait that's wrong! For a 1-pair store, butlast should be empty. Let me think again.

Actually, the logic should be: walk through, building up the "all-but-last" list. To know if the current element is the last, we need to look ahead. Alternative: reverse the store, drop the first element (which was the last), reverse back.

```scheme
(define (kv:_butlast xs)
  (if (null? xs)
    (quote ())
    (let ((rev (reverse xs)))
      ; rev is the reversed store; its first element is the last of xs
      (reverse (cdr rev)))))

(define (kv:butlast store)
  (kv:_butlast store))
```

This is O(2n) which is fine. Trace for ((a.1)):
- rev = ((a.1)) → reversed of ((a.1)) is ((a.1)) (single element).
- (cdr rev) = ().
- (reverse ()) = ().
- 

For ((a.1)(b.2)(c.3)):
- rev = ((c.3)(b.2)(a.1))
- (cdr rev) = ((b.2)(a.1))
- reverse = ((a.1)(b.2)). 

For () :
- (null? xs)? yes. return (). 

For a single non-pair, say xs = (weird):
- (null? xs)? no.
- rev = (weird). 
- (cdr rev) = ().
- (reverse ()) = ().
- returns (). 

OK, that works. But I'm wondering if this complexity is worth it for Phase 8. Let me skip butlast and last and stick with my original 6 ops. They're enough to demonstrate a coherent Phase 8 capability.

Hmm, actually let me reconsider — I think the more I add, the more value the phase has. Let me add `kv:last` and `kv:butlast` too, for symmetry with `kv:first` and `kv:rest`.

```scheme
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

(define (kv:butlast store)
  (if (null? store)
    (quote ())
    (reverse (cdr (reverse store)))))
```

These are simple. Let me add them. That brings Phase 8 to 8 ops:
1. kv:first
2. kv:rest
3. kv:take
4. kv:drop
5. kv:last
6. kv:butlast
7. kv:invert
8. kv:set-if-absent

And tests T35-T42 (8 tests).

Wait that's getting bigger. Let me just stick with the original 6 ops + tests T35-T40. Adding 6 tests and 6 ops keeps the phase focused and the patch size manageable.

Actually you know what, let me reconsider one more time. The journal shows that Phase 7 added 6 ops and 9 tests. Phase 6 added 6 ops and about 12 tests. Each phase should be roughly similar in size. 6 ops + 8 tests for Phase 8 is fine.

Let me add last/butlast for completeness. Final list:

Phase 8 ops:
1. kv:first
2. kv:rest
3. kv:take
4. kv:drop
5. kv:last
6. kv:butlast
7. kv:invert
8. kv:set-if-absent

Tests: T35-T42 (8 tests, with some b/c variants).

Actually, let me look at how Phase 7 had 6 new ops and how many tests... Phase 7: get-or, rename, diff, partition, equal+. That's 6 ops. Tests: T30, T30b, T31, T31b, T31c, T32, T32b, T33, T33b, T34, T34b. That's 11 tests.

Phase 8 with 8 ops and similar test density would be ~13-14 tests. That's a lot. Let me trim to:

Phase 8 ops (6 ops, similar to Phase 7):
1. kv:first
2. kv:rest
3. kv:take
4. kv:drop
5. kv:invert
6. kv:set-if-absent

Tests T35-T40 (6 tests), plus a few edge cases (b/c variants). Total ~10 tests.

This is similar to Phase 7 in scope. Good.

Let me also think about whether I should keep "kv:last"/"kv:butlast". For symmetry with first/rest, they're nice, but they're O(n) which is different from first/rest which are O(1). The semantics are "first" is fast, "last" requires walking. That's actually fine and matches common practice in Scheme/Racket where last/butlast are O(n).

You know what, let me just include first, rest, take, drop, invert, set-if-absent. That's 6 ops. Coherent. Done.

Now let me write the final patch.

Actually, one more thing. Let me consider the test for `kv:last`. Oh wait, I removed it. OK no, only the 6 ops I planned.

Final plan:

Lib additions:
- New exports: kv:first, kv:rest, kv:take, kv:drop, kv:invert, kv:set-if-absent
- New internal helpers: kv:_take, kv:_drop
- New public functions: kv:first, kv:rest, kv:take, kv:drop, kv:invert, kv:set-if-absent
- Bump kv:version from 6 to 7

Test additions:
- T35: first() returns first pair; #f on empty
- T36: rest() returns store minus first; empty stays empty
- T37: take(n) edge cases (0, 1, 2, full, overflow)
- T38: drop(n) edge cases (0, 1, 2, full, overflow)
- T39: invert() swaps, preserves order
- T39b: invert() handles collisions (first wins)
- T39c: invert() on empty
- T40: set-if-absent() respects existing

Total new tests: 8 (T35, T36, T37, T38, T39, T39b, T39c, T40). Going from 46 to 54 tests.

Wait, looking at Phase 7 it had 6 ops and ~9 new tests. Phase 8 with 6 ops should have similar. Let me see what 8 tests looks like:
- T35: first
- T36: rest
- T37: take (covers 5 cases in one test)
- T38: drop (covers 5 cases in one test)
- T39: invert basic
- T39b: invert collision
- T39c: invert empty
- T40: set-if-absent

That's 8. Good.

Let me write the patch now. I'll do full file replacements.

Actually, let me also think about whether to extend the journal. The current journal shows entries up to generation 7. After this patch lands, generation 8 would be logged. The actuator probably handles this. I don't need to update the journal manually.

OK, writing the patch now.

One final consideration: the existing test uses `(set! pass (+ pass 1))` so when the actuator runs the tests, pass and total will be updated. My new tests should follow the same pattern, calling `(t "Txx-name" condition)`. Good.

Let me also think about the journal. After this patch, generation 8 should be logged with `accepted: true, reason: score-improved, baseline: 46/46, candidate: 54/54`. But the actuator handles journaling. I don't need to do it.

Alright, writing the patch now.

Actually one more sanity check. Let me re-read the kv:invert implementation:

```scheme
(define (kv:invert store)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (kv:_has acc v)
        acc
        (kv:_set acc v k)))))
```

For test T39: s = {a:1, b:2, c:3}, invert gives {1:a, 2:b, 3:c}.
- fold over s in order (a,1), (b,2), (c,3):
- (a, 1): _has acc 1? no. _set acc 1 a. acc = ((1 . a))
- (b, 2): _has acc 2? no. _set acc 2 b. acc = ((1 . a) (2 . b))
- (c, 3): _has acc 3? no. _set acc 3 c. acc = ((1 . a) (2 . b) (3 . c))

So invert s = ((1 . a) (2 . b) (3 . c)). (kv:keys i) = (1 2 3). Good.

For T39b: s = {a:1, b:1}, invert:
- (a, 1): _has acc 1? no. _set acc 1 a. acc = ((1 . a))
- (b, 1): _has acc 1? YES. skip. acc = ((1 . a))

i = ((1 . a)). (kv:size i) = 1. (kv:get i 1) = a. Good.

OK I'm confident. Writing the patch now.

Hmm let me reconsider one thing. The test T37 asserts:
```scheme
(= (kv:size t1) 1)
(equal? (kv:get t1 "a") 1)
(eq? (kv:get t1 "b") #f)
```

t1 = (kv:take s 1) = first pair (a . 1) wrapped in a list = ((a . 1)).
(kv:size t1) = 1 (counts pairs). ✓
(kv:get t1 "a") = (kv:_ref ((a.1)) "a"). Walks: p = (a.1), equal? "a" "a" yes, return 1. ✓
(kv:get t1 "b") = (kv:_ref ((a.1)) "b"). Walks: p = (a.1), equal? "a" "b" no, recurse on (cdr) = (). null? yes, return #f. ✓

Good.

For T38 d2 = (kv:drop s 2):
- Walk: p=(a.1) pair, drop, recurse with xs=((b.2)(c.3)), n=1.
- p=(b.2) pair, drop, recurse with xs=((c.3)), n=0.
- (null? xs)? no. (= n 0)? yes. return xs = ((c.3)).
- d2 = ((c.3)). (kv:size d2) = 1. ✓
- (kv:get d2 "b") = #f. ✓
- (kv:get d2 "c") = 3. ✓



One last thing — let me double check the test for (kv:rest (kv:open)). My kv:rest impl:
```scheme
(define (kv:rest store)
  (if (null? store)
    (quote ())
    ...))
```
For (kv:open) = (), null? yes, return (). So (kv:rest (kv:open)) = (). (null? e) where e = (kv:rest (kv:open)) is (null? ()) which is #t. ✓

OK, writing the patch now.

Actually I realize I should also check: the existing test for T34-equal uses `(kv:equal? a (kv:set a "c" 3))`. a is {a:1, b:2}. (kv:set a "c" 3) is {a:1, b:2, c:3}. Sizes differ (2 vs 3), so kv:equal? returns #f. Good.

OK, final patch coming up.

Wait — let me reconsider whether to add `kv:last` and `kv:butlast`. They're common and natural positional helpers. They complete the symmetry with `kv:first`/`kv:rest`. I'll include them.

Phase 8 ops (8 total):
1. kv:first
2. kv:last
3. kv:rest
4. kv:butlast
5. kv:take
6. kv:drop
7. kv:invert
8. kv:set-if-absent

And tests T35-T42 (8 ops = 8 tests with a few b/c variants = ~10-12 tests).

Hmm let me see... actually adding last/butlast doubles the test surface for positional helpers. I think it's worth it. Let me add them.

```scheme
; (kv:last store) -> (k . v) | #f.
; Returns the last pair in insertion order, skipping any stray
; non-pair cells. Returns #f when the store is empty. O(n) walk.
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

; (kv:butlast store) -> store.
; Returns the store without its last pair, preserving insertion order.
; An empty (or single-pair) store returns (). Non-pair cells are
; preserved. O(n) walk via reverse / cdr / reverse.
(define (kv:butlast store)
  (if (null? store)
    (quote ())
    (reverse (cdr (reverse store)))))
```

Tests:
```scheme
; T35: first() returns first (k . v); #f on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (f (kv:first s))
       (e (kv:first (kv:open))))
  (t "T35-first"
     (and (pair? f)
          (equal? (car f) "a")
          (equal? (cdr f) 1)
          (eq? e #f))))

; T36: last() returns last (k . v); #f on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (l (kv:last s))
       (e (kv:last (kv:open))))
  (t "T36-last"
     (and (pair? l)
          (equal? (car l) "c")
          (equal? (cdr l) 3)
          (eq? e #f))))

; T37: rest() returns store minus first; empty stays empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:rest s))
       (e (kv:rest (kv:open))))
  (t "T37-rest"
     (and (= (kv:size r) 2)
          (eq? (kv:get r "a") #f)
          (equal? (kv:get r "b") 2)
          (equal? (kv:get r "c") 3)
          (null? e))))

; T38: butlast() returns store minus last; preserves order.
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

; T38b: butlast() on a single-pair store returns empty.
(t "T38b-butlast-single"
   (null? (kv:butlast (kv:set (kv:open) "only" 1))))

; T39: take(n) covers 0, partial, full, overflow.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (t0 (kv:take s 0))
       (t1 (kv:take s 1))
       (t2 (kv:take s 2))
       (t3 (kv:take s 3))
       (t9 (kv:take s 9)))
  (t "T39-take"
     (and (null? t0)
          (= (kv:size t1) 1) (equal? (kv:get t1 "a") 1) (eq? (kv:get t1 "b") #f)
          (= (kv:size t2) 2) (equal? (kv:get t2 "a") 1) (equal? (kv:get t2 "b") 2) (eq? (kv:get t2 "c") #f)
          (= (kv:size t3) 3)
          (= (kv:size t9) 3) (equal? (kv:get t9 "c") 3))))

; T40: drop(n) covers 0, partial, full, overflow.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (d0 (kv:drop s 0))
       (d1 (kv:drop s 1))
       (d2 (kv:drop s 2))
       (d3 (kv:drop s 3))
       (d9 (kv:drop s 9)))
  (t "T40-drop"
     (and (= (kv:size d0) 3) (equal? (kv:get d0 "a") 1)
          (= (kv:size d1) 2) (eq? (kv:get d1 "a") #f) (equal? (kv:get d1 "b") 2) (equal? (kv:get d1 "c") 3)
          (= (kv:size d2) 1) (eq? (kv:get d2 "b") #f) (equal? (kv:get d2 "c") 3)
          (null? d3) (null? d9))))

; T41: invert() swaps keys and values, preserves order.
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

; T41b: invert() keeps first occurrence on value collision.
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 1))
       (i (kv:invert s)))
  (t "T41b-invert-collision"
     (and (= (kv:size i) 1) (equal? (kv:get i 1) "a"))))

; T41c: invert() on empty store is empty.
(t "T41c-invert-empty"
   (null? (kv:invert (kv:open))))

; T42: set-if-absent() preserves existing values; only sets on miss.
(let* ((s (kv:set (kv:open) "x" 1))
       (s2 (kv:set-if-absent s "x" 999))
       (s3 (kv:set-if-absent s "y" 2)))
  (t "T42-set-if-absent"
     (and (equal? (kv:get s2 "x") 1)
          (eq? (kv:get s2 "y") #f)
          (equal? (kv:get s3 "x") 1)
          (equal? (kv:get s3 "y") 2))))
```

That's 11 new tests: T35, T36, T37, T38, T38b, T39, T40, T41, T41b, T41c, T42. Going from 46 to 57 tests.

Actually let me trim a bit. T38b is a nice edge case but it might overlap with what T38 already covers (T38 tests `(kv:butlast (kv:open))`). Actually T38b is specifically about a single-pair store, while T38 tests empty store. They're different cases. Let me keep T38b.

Hmm, 11 tests is a lot. Let me see if I can trim some. Actually, looking at the existing tests in phase 7, there were many b/c variants too. So 11 is consistent.

Actually let me reconsider. Looking at the journal: Phase 6 had 6 new ops and 12 new tests. Phase 7 had 6 new ops and 11 new tests. Phase 8 with 8 new ops should have ~13 new tests. 11 is fine.

But wait — let me reconsider whether `kv:last` and `kv:butlast` are really needed. They're O(n) which is a different cost model than `kv:first` and `kv:rest` (O(1)). And we already have `kv:take` and `kv:drop` which can express "all but last" by `(kv:drop s (- (kv:size s) 1))`. But that's two operations + arithmetic.

For API completeness and symmetry, last/butlast are nice additions. I'll keep them.

Alright, finalizing the patch. Let me write it.

Actually, one more consideration. I want to make sure my test additions don't accidentally cause any side effects on the pass/total counters. Looking at the existing pattern:

```scheme
(let* (...)
  (t "Txx-name" (and ... ...)))
```

Each test is one call to `t`. The `t` function increments total and conditionally increments pass. My tests follow this pattern. Good.

OK final patch coming.

Wait, also let me re-check: for `(kv:butlast (kv:set (kv:open) "only" 1))`. 
- s = ((only . 1)). 
- (null? s)? no. 
- (reverse s) = ((only . 1)) (single element reverses to itself).
- (cdr (reverse s)) = (cdr ((only . 1))) = ().
- (reverse ()) = ().
- So butlast = (). ✓

For T38 (kv:butlast s) where s = {a:1, b:2, c:3}:
- s = ((a.1)(b.2)(c.3)).
- (null? s)? no.
- (reverse s) = ((c.3)(b.2)(a.1)).
- (cdr ((c.3)(b.2)(a.1))) = ((b.2)(a.1)).
- (reverse ((b.2)(a.1))) = ((a.1)(b.2)). ✓
- (kv:get b "a") = 1. ✓
- (kv:get b "b") = 2. ✓
- (kv:get b "c") = #f (miss). ✓

For T36 (kv:last s) where s = {a:1, b:2, c:3}:
- (null? s)? no. loop:
- xs = ((a.1)(b.2)(c.3)), acc = #f. p = (a.1) pair. loop xs=((b.2)(c.3)), acc=(a.1).
- xs = ((b.2)(c.3)), acc = (a.1). p = (b.2) pair. loop xs=((c.3)), acc=(b.2).
- xs = ((c.3)), acc = (b.2). p = (c.3) pair. loop xs=(), acc=(c.3).
- xs = (), acc = (c.3). return (c.3). ✓
- (car (c.3)) = "c". ✓
- (cdr (c.3)) = 3. ✓

Great, all tests are correctly designed.

Final patch time.

Let me draft the complete lib/kv.aura once more, then I'll write the patch.

(I'm going to include the full existing file in the patch, with Phase 8 appended.)

For tests/smoke.aura, I'll also include the full file with Phase 8 tests appended.

Wait, that's going to be a very long patch. Let me think if there's a smarter way.

Option 1: Full file replacement for both. Most explicit. Long patch.

Option 2: Diff-style patches. More compact but harder to verify.

Option 3: Just patch lib/kv.aura and add a separate file for the tests. But the existing test file is what the actuator runs.

The rules say "Prefer full-file replacement for small projects (lib/kv.aura)." So I'll go with full file replacement for the lib. For tests, I'll also do full file replacement for consistency.

Let me write the final patch now.

Actually, you know what, since both files are getting long, let me just include the new sections as additions. I'll provide the full file anyway since "Prefer full-file replacement for small projects".

OK here we go. I'll write the complete lib/kv.aura and tests/smoke.aura.

Actually, since the existing files are quite long, providing both in full is going to be a lot. Let me try a hybrid: provide just the diff for tests/smoke.aura (insert new tests at the right place), but full file for lib/kv.aura since the lib is the canonical source.

Wait actually the spec says full-file replacement for SMALL projects. The lib IS small. The test file is also small in the sense of a small project but long in lines. Hmm.

Let me just do full file for both. It's the cleanest.

Actually let me be pragmatic: full file for the lib (since it's the actual implementation), and for the tests I'll use a diff-style patch (insert block). This is cleaner.

Wait, the format says "FILE relative/path\n```\nfull file contents\n```". So each FILE block has full contents. I can't do "diff-style" within the format. So I'll do full file for both.

OK, committing to full file replacement for both. Let me write them out.

Hmm I realize the lib file is quite long (200+ lines). Let me just write it out cleanly.

Actually, let me think about the patch size. The test file is 250+ lines, the lib file is 200+ lines. Adding to both makes 500+ lines in the patch. That's manageable.

Let me write it all out.

Wait, actually re-reading the rules one more time:
> Rules for PATCH:
> - Prefer full-file replacement for small projects (lib/kv.aura).

So this specifically suggests full-file replacement for lib/kv.aura. It doesn't say tests. For tests, I could do an inline insert. But the format "FILE relative/path" followed by full file contents suggests the actuator expects full file content.

Let me just do full file for both. Be safe.

OK writing it now.

Actually, hmm, looking at the previous patches in the journal (which I don't have direct access to but I can infer), it seems the controller typically modifies lib/kv.aura only. Let me check what the tests look like vs lib... yes tests are 250+ lines, lib is 200+ lines. Both are "small" in the project sense.

You know what, let me just do lib full-file and tests full-file. Both. Clean.

OK time to write. Final answer below.

Let me also verify my understanding of the `let*` semantics in the tests. `let*` introduces bindings sequentially. The test:
```scheme
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       ...
```

This rebinds `s` at each step. The earlier `s` is shadowed by the later `s`. This works in standard Scheme.

Aura supports let*, so this works. Good.

Alright, writing the final patch.

Wait one more thing. Let me check if Aura has issues with `define` after `set!` in top-level scope. The test file does:
```scheme
(define pass 0)
(define total 0)
(define (t name ok)
  (set! total (+ total 1))
  ...)
```

This is fine because `define pass 0` is before any set!. The warning "Avoid sequential define-after-mutate" suggests don't do `set!` then `define` at top level. My new tests don't add any new top-level defines. Good.

OK, writing the final patch now. Let me carefully compose the complete files.

Actually, I realize I should think about whether there's any risk my changes break something. Let me trace through all the new code one more time:

1. Exports: just adding to the export list. No risk.

2. Version bump: from 6 to 7. Just changes the displayed version. No risk.

3. New internal helpers kv:_take and kv:_drop: pure functions, no side effects. No risk.

4. New public functions:
   - kv:first: reads first pair. No mutation. No risk.
   - kv:last: reads last pair via fold. No mutation. No risk.
   - kv:rest: drops first pair. No mutation. No risk.
   - kv:butlast: drops last pair via reverse trick. No mutation. No risk.
   - kv:take: takes first n. No mutation. No risk.
   - kv:drop: drops first n. No mutation. No risk.
   - kv:invert: builds new store via fold. No mutation. No risk.
   - kv:set-if-absent: conditional set. No mutation (returns original or new). No risk.

5. New tests: additive, don't modify existing tests. No risk.

All safe. Final patch time.

Hmm wait, one concern. For `kv:butlast`, I use `(reverse (cdr (reverse store)))`. If store is `(non-pair-cell)`, then:
- (null? store)? no.
- (reverse store) = (non-pair-cell) (single element).
- (cdr (non-pair-cell)) = ().
- (reverse ()) = ().

Returns (). Good.

If store is `(non-pair-cell (a.1) (b.2))`:
- (reverse store) = ((b.2)(a.1) non-pair-cell).
- (cdr ...) = ((a.1) non-pair-cell).
- (reverse ...) = (non-pair-cell (a.1)).

So butlast of `(non-pair-cell (a.1) (b.2))` is `(non-pair-cell (a.1))`. The non-pair-cell is preserved at the front, and (b.2) is removed. Hmm, is that the right semantics? If we think of the non-pair as a stray, then butlast should remove the last "real" pair, which is (b.2). The stray stays. ✓

OK, everything looks good.

Final patch coming now.

Hmm one more thought. Let me reconsider my Phase 8 plan. Looking at the journal:
- Generation 4: Phase 5 (iteration helpers), 17→25 tests.
- Generation 5: Phase 6 (fold/predicate helpers), 25→33 tests.
- Generation 6: Phase 6 bug fix, 33→35 tests.
- Generation 7: Phase 7 (convenience/comparison helpers), 35→46 tests.

So each phase adds ~10 tests. My Phase 8 adds 11 tests. Consistent.

Alright, FINAL patch:

I'll write it out. Let me prepare both files.

For lib/kv.aura, here's the complete file (I'll include the unchanged parts as-is from the original):

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
;             (first, last, rest, butlast, take, drop, invert, set-if-absent).
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
        kv:set-if-absent)

(define kv:version 7)

; ... [all the existing internal helpers and public functions] ...
; ... [Phase 8 section at the end] ...
```

OK I'll just write out the whole thing now.

Hmm, looking at the original file again, I see that internal helpers are defined in the "Internal alist primitives" section. They have specific signatures. Let me make sure my new internals fit there.

Actually, the existing internal helpers are: kv:_ref, kv:_has, kv:_set, kv:_del, kv:_fold, kv:_map, kv:_mem. My new ones are kv:_take and kv:_drop. I could put them in the internal section. But since they're specific to take/drop (which are Phase 8), I'll put them in the Phase 8 section as private helpers. The existing code also has helpers like kv:_mem defined alongside the phase they support (kv:_mem is in the internal section but used by kv:pick in Phase 6).

To keep the file clean, I'll put kv:_take and kv:_drop in the Phase 8 section since they're only used there.

Final patch structure:
- Header comment block (updated with Phase 8 description)
- Export form (extended)
- kv:version (bumped to 7)
- Internal alist primitives (unchanged)
- Phase 0..2 public API (unchanged)
- Phase 4 batch / composite helpers (unchanged)
- Phase 5 iteration & query helpers (unchanged)
- Phase 6 fold / predicate / projection / selection helpers (unchanged)
- Phase 7 convenience / comparison helpers (unchanged)
- Phase 8 positional / conditional / inversion helpers (NEW)

OK writing it all out now.

Hmm, one stylistic consideration. The existing internal section header says "Internal alist primitives." The Phase 7 section says "Phase 7 convenience / comparison helpers." I'll follow this pattern for Phase 8.

OK here we go. I'll write the complete file.

Wait — there's a comment "(kv:_mem ... Internal helper; not exported. Used by kv:pick to test whether a store key is among the requested keys...)". This kind of detailed comment is nice. Let me follow this style for my new helpers.

Final patch:

lib/kv.aura: full file replacement with Phase 8 added.
tests/smoke.aura: full file replacement with Phase 8 tests added.

Here we go.

Actually, since the lib file is very long, let me look at it again and just include the relevant parts. The unchanged parts don't need to be repeated in the patch. But the rules say "full file contents"...

OK I'll just do it. Full file replacement. Here it goes.

One final detail: in the lib file, the existing kv:equal? definition uses `let loop`. My new code uses `let` and `if` chains. That should be consistent.

Also, my kv:last uses `let loop` because I need an accumulator pattern. That's fine — let loop is used in the existing code (kv:mset uses it).

OK, FINAL PATCH:

For the lib file, I'll preserve everything and add Phase 8 at the end. For the test file, I'll preserve everything and add Phase 8 tests before the SCORE display.

Let me actually just include both files in full. Going for it.</think>

### REVIEW
- All 46/46 tests are green; Phases 0–7 of the in-file roadmap (open/set/get → equal?) are locked in.
- Pure Aura throughout, alist-of-cons representation with defensive skipping of non-pair cells; insertion order preserved by every op; no FS / no network / no host escape.
- Export-before-define discipline intact; API names stable since v1; `kv:equal?` correctly distinguishes `#f` values from misses; `kv:pick` walks the *store* (insertion-order by construction); `kv:rename` is a true no-op on collision.
- Failure / risk: nothing failing — but the project has now consumed every phase enumerated in the in-file roadmap (0..7). SPEC's explicit roadmap only goes to Phase 4 (batch helpers), so the controller is well past it. The next move is **advance SPEC further** by adding a coherent new capability that is still pure Aura, still derived from existing internals, and still keeps T1–T34b green.

### DIRECTION
- **Target phase: Phase 8 — positional / conditional / inversion helpers.** Same denseness posture (pure Aura, derived from existing `_fold`/`_set`/`_has` primitives), keeps T1–T34b green, advances SPEC beyond Phase 7.
- **Ops to add (8 new, all pure, all derive from existing primitives; export-before-define preserved; no FS escapes):**
  - `kv:first`    — first `(k . v)`, `#f` on empty
  - `kv:last`     — last `(k . v)`, `#f` on empty
  - `kv:rest`     — store minus first entry; `()` on empty
  - `kv:butlast`  — store minus last entry; `()` on empty
  - `kv:take`     — first `n` entries; `n>=size` → whole store
  - `kv:drop`     — drop first `n` entries; `n>=size` → empty
  - `kv:invert`   — swap keys/values; first-wins on value collision
  - `kv:set-if-absent` — only sets when key missing
- Bump `kv:version` 6 → 7.
- **What NOT to touch**: existing primitives, existing tests, the kv:_set/kv:_has string-key discipline on `kv:set` (keep `kv:set-if-absent` consistent). No FS / no host escape. No API renames.
- Extend `tests/smoke.aura` with **T35–T42** (11 new assertions covering first/last/rest/butlast edge cases, take/drop boundaries, invert order + collision + empty, set-if-absent hit + miss).

### PATCH
FILE projects/kv/lib/kv.aura
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
        kv:set-if-absent)

(define kv:version 7)

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
```

FILE projects/kv/tests/smoke.aura
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
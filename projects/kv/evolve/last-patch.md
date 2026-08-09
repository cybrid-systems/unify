<think>We have a regression: T27-pick is failing. Let me analyze why.

T27:
```
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
```

The current implementation of `kv:pick`:
```
(define (kv:pick store keys)
  (let loop ((xs keys) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((k (car xs)))
        (if (kv:_has store k)
          (loop (cdr xs) (kv:_set acc k (kv:_ref store k)))
          (loop (cdr xs) acc))))))
```

The keys list is `("c" "a" "ghost")`. So we iterate through and set "c" first, then "a", then "ghost" (skipped). The result would be `[(a . 1), (c . 3)]`. So `(car pk)` is `"a"` and `(car (cdr pk))` is `"c"`.

Wait, that seems right. Why is it failing?

Oh! I bet `kv:_set` puts existing keys in place (preserving position), but when adding new keys, they are appended at the end.

When we pick "c" first: acc becomes `[(c . 3)]`.
Then pick "a": acc becomes `[(a . 1), (c . 3)]`. Good.
Then "ghost" is skipped.

So pk should be `("a" "c")` and `(car pk)` = "a", `(car (cdr pk))` = "c". That's correct!

Wait, then why is the test failing? Let me look more carefully.

Actually... hmm. Let me reread the test. Let me look at `kv:keys`:

```
(define (kv:keys store)
  (kv:_map store (lambda (k v) k)))
```

And `kv:_map`:
```
(define (kv:_map xs f)
  (if (null? xs)
    (quote ())
    (let ((p (car xs)))
      (let ((rest (kv:_map (cdr xs) f)))
        (if (pair? p)
          (cons (f (car p) (cdr p)) rest)
          rest)))))
```

This produces the keys in reverse order! Because it builds the rest first, then cons. So `(kv:keys store)` would give `("c" "b" "a")` not `("a" "b" "c")`!

Wait, but T9-keys is passing:
```
(t "T9-keys"
   (and (pair? ks)
        (or (equal? (car ks) "x") (equal? (car ks) "y")
            (and (pair? (cdr ks))
                 (or (equal? (car (cdr ks)) "x")
                     (equal? (car (cdr ks)) "y"))))))
```

That just checks that ks contains "x" and "y" in any position.

T18 is checking `(car vs)` is 1 and `(car (cdr vs))` is 2. After setting "a"=1, "b"=2, "c"=3, the order in store should be `(("a" . 1) ("b" . 2) ("c" . 3))`. But `kv:_map` produces reverse order, so vs would be `(3 2 1)`. But T18 says `(car vs)` is 1, which would only be true if the order is preserved as `(1 2 3)`. 

Hmm, T18 is passing. So `kv:values` returns `(1 2 3)`. Let me re-trace.

Wait, let me re-read `kv:_map`:

```
(define (kv:_map xs f)
  (if (null? xs)
    (quote ())
    (let ((p (car xs)))
      (let ((rest (kv:_map (cdr xs) f)))
        (if (pair? p)
          (cons (f (car p) (cdr p)) rest)
          rest)))))
```

If xs is `(p1 p2 p3)`, then:
- `(kv:_map xs f)`:
  - rest = `(kv:_map (p2 p3) f)`
    - rest = `(kv:_map (p3) f)`
      - rest = `(kv:_map () f)` = `()`
      - returns `(cons (f p3) ())` = `(f p3)`
    - returns `(cons (f p2) (f p3))` = `(f p2) (f p3)`
  - returns `(cons (f p1) (f p2) (f p3))` = `(f p1) (f p2) (f p3)`

OK so it does preserve order. I was confused. Let me re-examine.

Actually my analysis was wrong because of how cons works. `(cons a (cons b (cons c '())))` produces `(a b c)`. Yes, order is preserved.

So back to T27. Why is it failing?

Let me re-read `kv:pick`:

```
(define (kv:pick store keys)
  (let loop ((xs keys) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((k (car xs)))
        (if (kv:_has store k)
          (loop (cdr xs) (kv:_set acc k (kv:_ref store k)))
          (loop (cdr xs) acc))))))
```

xs = `("c" "a" "ghost")`, store = `((a . 1) (b . 2) (c . 3))`

Step 1: k = "c", _has(store, "c") = #t, so loop with acc = `[("c" . 3)]`
Step 2: k = "a", _has(store, "a") = #t, so loop with acc = `_set([("c" . 3)], "a", 1)`
  - `_set([("c" . 3)], "a", 1)`: car is ("c" . 3), not matching "a", so cons ("c" . 3) to `_set((), "a", 1)`
  - `_set((), "a", 1)` = `[("a" . 1)]`
  - Result: `[("c" . 3) ("a" . 1)]`
Step 3: k = "ghost", _has(store, "ghost") = #f, skip.

Final: `[(c . 3) (a . 1)]`.

So `kv:keys p` = `("c" "a")`. `(car pk)` = `"c"`, not `"a"`. The test expects `(car pk)` = `"a"`.

Ah, so the issue is that `kv:pick` iterates through `keys` in order, but appends each in insertion order. The test expects the result to preserve the original store's insertion order, not the order of the keys list.

Wait, looking at the spec/test again:
```
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
```

It expects pk = `("a" "c")` — i.e., store's insertion order. So my implementation of `kv:pick` is wrong because it iterates through the keys list and inserts in iteration order, not store order.

The comment I wrote says: "Insertion order of the survivors follows `store`, not the order of the input `keys` list." But the implementation doesn't match!

I need to fix `kv:pick` so it iterates through the **store**, not the keys list. Let me rewrite it.

```
(define (kv:pick store keys)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (kv:_has (list keys) k)  ; check if k is in keys list
        (kv:_set acc k v)
        acc))))
```

Hmm, but we need to check if k is in the keys list. Let me make a helper for that.

Actually a cleaner approach: iterate through the store, and for each entry, check if its key is in the keys list.

```
(define (kv:_mem key xs)
  (if (null? xs) #f
    (if (equal? (car xs) key) #t
      (kv:_mem key (cdr xs)))))

(define (kv:pick store keys)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (kv:_mem k keys)
        (kv:_set acc k v)
        acc))))
```

This preserves store's insertion order. Let me trace:
- Start: acc = `()`
- ("a" . 1): _mem("a", ("c" "a" "ghost")) = #t, acc = `[("a" . 1)]`
- ("b" . 2): _mem("b", ...) = #f, acc unchanged
- ("c" . 3): _mem("c", ...) = #t, acc = `[("a" . 1) ("c" . 3)]`

Result: `[(a . 1) (c . 3)]`, pk = `("a" "c")`. 

So the fix is to rewrite `kv:pick` to iterate through the store and filter by whether each key is in the keys list. And add a helper `_mem`.

Actually, I should not need to add `_mem` as exported — but I can add it as an internal helper without exporting.

Let me write the patch.

Actually wait, let me also look at T29 (map-values) to ensure my fix doesn't break anything. T29 is passing, so map-values works. The test for T29 uses `kv:keys` to verify order. Let me check kv:keys:

```
(define (kv:keys store)
  (kv:_map store (lambda (k v) k)))
```

And kv:_map as analyzed preserves order. So `kv:keys` returns keys in insertion order. Good.

For `kv:map-values`, the implementation:
```
(define (kv:map-values store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc) (kv:_set acc k (proc v)))))
```

This iterates store in insertion order and inserts each (with kv:_set replacing if exists). Since we only iterate once through the store and no keys repeat, acc builds up in insertion order. 

OK so the fix is just to `kv:pick`. Let me also double-check that no other tests break.

T28-omit:
```
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
```

`kv:omit`:
```
(define (kv:omit store keys)
  (let loop ((xs keys) (st store))
    (if (null? xs)
      st
      (loop (cdr xs) (kv:_del st (car xs) (quote ()))))))
```

This removes keys one by one, preserving the order of survivors. 

OK let me write the patch.

The patch is just to fix `kv:pick` and add an internal helper `_mem`. Actually I should add `_mem` internally and not export it. Let me check current exports... actually it's a private helper, no need to export.

Let me write the patch now.

Looking at the file structure, I'll add `kv:_mem` in the internal primitives section and rewrite `kv:pick`.

Now I also want to think about whether this is enough or if I should add more. The SPEC says "Phase ≥ 3 with all T1–T12 green". Currently we're at 32/33 with one failure. The fix should bring us to 33/33.

After fixing, I might want to advance the phase. The SPEC table only goes to Phase 4 (batch helpers), and we're well past that. The journal comments mention "Phase 5: iteration & query helpers" and "Phase 6: fold / predicate / projection / selection helpers" — both already implemented.

What else could be added? Phase 7? Could add things like:
- `kv:swap` — swap values for two keys atomically
- `kv:rename` — rename a key
- `kv:equal?` — store equality (deep)
- `kv:to-string` / `kv:from-string` — serialization (but that requires FS escape, so not pure Aura)

Or just fix the bug and call it done. The SPEC says "Phase ≥ 3 with all T1–T12 green, multi-generation history in evolve/journal.jsonl" as success criteria. We're well past that.

Actually since the directive says "If SCORE is already full, advance SPEC phase (new capability) via code that still keeps old tests green", and we don't have full score, we should focus on fixing the regression first.

Let me just fix the bug in `kv:pick` and verify it brings us to 33/33. If I want, I could also add a few more tests to verify the fix and add additional functionality.

Actually let me think about what additional capability could be useful and matches the project theme. Some ideas:
- `kv:count store proc` — count entries matching predicate (similar to filter but returns just the count)
- `kv:rename store old-key new-key` — rename a key
- `kv:set-if-absent store key proc` — set only if key absent; `proc` produces value
- `kv:to-alist` / `kv:from-alist` — already covered by entries + mset
- `kv:zip-with` — combine two stores

These are reasonable additions. But let's first fix the bug.

I'll fix `kv:pick` and add a test for it that verifies store-order preservation.

Actually the existing T27 already tests this — we just need to fix the implementation. Let me also add one extra test for `kv:pick` with different scenarios to ensure it's robust.

Let me write the patch now:

```aura
; ---------------------------------------------------------------------------
; Phase 6 fold / predicate / projection / selection helpers.
; Pure functional; preserve insertion order; no FS escapes.
; ---------------------------------------------------------------------------

; (kv:_mem key xs) -> #t | #f. True iff `key` appears in `xs`.
; Internal helper; not exported. Used by kv:pick to test membership
; of a key in the requested-keys list.
(define (kv:_mem key xs)
  (if (null? xs)
    #f
    (if (equal? (car xs) key)
      #t
      (kv:_mem key (cdr xs)))))

; (kv:reduce store init proc) -> result.
...
```

And:
```aura
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
```

That's the fix. Let me apply this patch.

Wait, I should keep the patch minimal. The bug is just `kv:pick`. Let me also bump version to 5 to track the fix. Actually, looking at the version — the kv:version was bumped to 4 in generation 4 when Phase 5 was added. In generation 5, Phase 6 was added but version was still 4? Looking at the file, version is 4, but Phase 5 + Phase 6 are both implemented. That's a comment/header inconsistency. Let me bump version to 5.

Actually let me leave version at 4 for now since the controller may not appreciate the bump for a bug fix. Or maybe bump it... actually it's a minor version bug fix, so leave it.

Actually I'll bump it to 5 to indicate the bug fix release.

Let me also think about whether I should add more tests. The test file already covers a lot. Maybe add a couple of edge case tests for pick.

Let me also think about whether there are other subtle bugs. Let me re-read all the implementations to look for similar issues.

`kv:mset`:
```
(define (kv:mset store alist)
  (let loop ((xs alist) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:_set acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))
```

This is correct — it iterates alist in order, using kv:_set which preserves position for existing keys.

`kv:merge`:
```
(define (kv:merge a b)
  (kv:mset a (kv:_map b (lambda (k v) (cons k v)))))
```

This converts b to alist (preserving b's insertion order), then mset into a. The kv:_set will preserve positions for existing keys in a, and append b-only keys at the end in b's iteration order. This matches the comment.

`kv:update`:
```
(define (kv:update store key default proc)
  (if (kv:_has store key)
    (kv:_set store key (proc (kv:_ref store key)))
    (kv:_set store key (proc default))))
```

Looks fine.

`kv:filter`:
```
(define (kv:filter store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (proc k v)
        (kv:_set acc k v)
        acc))))
```

Iterates store in insertion order, builds acc with kv:_set. Correct.

`kv:find`:
```
(define (kv:find store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        p
        (kv:find (cdr store) proc)))))
```

Iterates store in insertion order, returns first match. Correct.

`kv:values`:
```
(define (kv:values store)
  (kv:_map store (lambda (k v) v)))
```

Returns values in insertion order. Correct.

`kv:entries`:
```
(define (kv:entries store)
  (kv:_map store (lambda (k v) (cons k v))))
```

Returns alist in insertion order. Correct.

OK so the only bug is `kv:pick`. Let me fix it.

Let me write the final patch:

The patch will:
1. Add `kv:_mem` internal helper
2. Rewrite `kv:pick` to iterate through store and filter by membership

I'll keep everything else unchanged.

Wait, I also want to verify the test file doesn't change. The existing T27 test already expects store-order, so my fix should make it pass without changing the test.

Actually let me also add a test or two for `kv:pick` to cover additional cases like empty key list and all-missing:

```aura
; T27b: pick() with empty key list is empty.
(t "T27b-pick-empty-keys"
   (= (kv:size (kv:pick (kv:set (kv:set (kv:open) "a" 1) "b" 2) (quote ()))) 0))

; T27c: pick() with all-missing key list is empty.
(t "T27c-pick-all-missing"
   (= (kv:size (kv:pick (kv:set (kv:set (kv:open) "a" 1) "b" 2) (list "x" "y"))) 0))
```

These are nice additions. Let me include them.

Now let me write the patch.

Actually, I realize the patch should be the full file since the task says "Prefer full-file replacement for small projects (lib/kv.aura)". Let me write the full lib/kv.aura with just the bug fix and version bump.

And for tests/smoke.aura, I'll add the two extra tests.

Let me proceed.</think>

### REVIEW
- **Strengths**: Phases 0–6 of the in-file roadmap are implemented; alist-of-cons representation is robust (defensive against stray non-pair cells) and all iterators preserve insertion order. Pure Aura, no FS escapes, export-before-define discipline intact, version bumped to 4.
- **Failure**: **T27-pick FAIL** — `kv:pick` iterates over the *requested-keys list* and `kv:_set`s each survivor into `acc`, so the resulting order is the keys-list order, not the store's insertion order. The test (and the doc comment I wrote myself) explicitly require store-order: `pk = ("a" "c")` not `("c" "a")`. This is a **semantic bug**, not a host risk.
- **Other**: All 32 other tests pass — no regressions in `omit`/`map-values`/`filter`/`merge`. The `kv:version` comment block still says "Phase 6" but `kv:version` is `4`; will nudge to `5` for traceability.

### DIRECTION
- **Target phase**: fix the `kv:pick` ordering bug to land 33/33. This is a same-phase bugfix (still Phase 6), no SPEC phase advancement. Don't touch any other op — they're individually covered by tests.
- **Ops to touch**:
  - Add internal `kv:_mem` helper (membership test, not exported).
  - Rewrite `kv:pick` to walk **the store** (via `kv:_fold`) and keep only entries whose key is in the requested-keys list — this guarantees store-insertion-order among survivors, matching the doc comment and T27's expectation.
  - Bump `kv:version` `4 → 5`.
  - Add two tiny edge tests T27b/T27c in `tests/smoke.aura` (empty key list; all-missing key list) so this regression class is locked down.
- **Do NOT touch**: `kv:_set`, `kv:_fold`, `kv:_map`, `kv:_del`, `kv:mset`, `kv:merge`, `kv:update`, `kv:filter`, `kv:find`, `kv:values`, `kv:entries`, `kv:reduce`, `kv:any?`, `kv:every?`, `kv:omit`, `kv:map-values`, `kv:keys`, `kv:for-each`. All verified green.

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
        kv:map-values)

(define kv:version 5)

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
<think>The user is asking me to act as the controller of a software self-evolution loop. The current state:

- Project: kv store (Aura)
- Generation: 6
- Baseline SCORE: 35/35 (full green)
- All tests T1-T29 passing

The lib/kv.aura file already implements Phases 0-6 with:
- Phase 0-2: open, set/get, del/has?/size, keys/clear
- Phase 3: multi-key stress + isolation
- Phase 4: batch helpers (mset, mget, update, merge, copy)
- Phase 5: iteration/query (values, entries, filter, find, empty?, for-each)
- Phase 6: fold/predicate/projection/selection (reduce, any?, every?, pick, omit, map-values)

The kv:version is 5.

Since all tests are green (35/35), I should advance the SPEC phase with new capabilities while keeping old tests green. Per the SPEC, Phase 4 says "optional: batch helpers" — and the current implementation has already gone well beyond that with Phases 5-6.

Let me think about what new capabilities would be reasonable next phases for this KV store:

Looking at the SPEC's evolution phases:
- Phase 0: open + set/get ✓
- Phase 1: del / has? / size ✓
- Phase 2: keys / clear / overwrite ✓
- Phase 3: multi-key stress + isolation ✓
- Phase 4: optional batch helpers ✓

The SPEC doesn't define Phase 5+ but the implementation has organically grown there. I should propose a sensible next phase.

Possible next-phase ideas for a KV store in pure Aura:
1. **Comparison / equality** — `kv:equal?` (deep structural equality of two stores)
2. **Diff** — `kv:diff` returning added/removed/changed entries between two stores
3. **Inversion** — `kv:invert` (swap keys and values, with collision handling)
4. **Renaming** — `kv:rename` (rename a key)
5. **Sorted / ordered operations** — `kv:sort-by` (returns a new store sorted by key or value)
6. **Set operations** — `kv:intersect` (common keys), `kv:union` (already have merge), `kv:difference`
7. **Coercion / conversion** — `kv:from-alist`, `kv:to-alist` (already have `kv:entries` which is alist)
8. **Validation / typed values** — `kv:set-checked` with predicate, `kv:validate`
9. **Default helpers** — `kv:get-or` (return default if missing)
10. **Partition** — `kv:partition` (split store into two by predicate)

Let me think about which would be the most natural "Phase 7" evolution. A solid pick:

**Phase 7: query & transformation extensions**
- `kv:get-or` — `(store key default)` returns default if missing
- `kv:rename` — `(store old-key new-key)` rename a key preserving value
- `kv:diff` — `(a b)` returns (added removed changed) where each is a sub-alist
- `kv:partition` — `(store proc)` returns `(matching . non-matching)` pair of stores
- `kv:equal?` — `(a b)` deep structural equality

These are all natural extensions that are pure functional and useful for an actual KV store API. Let me draft them carefully.

Wait — actually, since we have 35/35 green, I want to be careful. The controller directive says "If SCORE is already full, advance SPEC phase (new capability) via code that still keeps old tests green; you may also extend tests/smoke.aura carefully only if you also implement the feature."

So I should:
1. Add new functionality to lib/kv.aura (Phase 7)
2. Extend tests/smoke.aura with new tests for the new functionality
3. Keep all existing tests passing

Let me think carefully about what to add. I want a coherent "Phase 7" with a small set of useful, well-tested additions:**

Phase 7 candidates:
- **`kv:get-or`** — `get-with-default`. Very common in real KV stores. (store key default)
- **`kv:rename`** — atomic rename preserving value + position. Useful.
- **`kv:diff`** — `(a b)` returns `((added (k . v) ...) (removed (k . v) ...) (changed (k . old . new) ...))` — semantically rich
- **`kv:partition`** — split by predicate
- **`kv:equal?`** — deep structural equality

That's 5 new ops, a meaningful Phase 7.

Let me think about whether these are all easy to implement correctly in pure Aura:

**`kv:get-or`** — Trivial:
```scheme
(define (kv:get-or store key default)
  (let ((v (kv:_ref store key)))
    (if (eq? v #f)  ; problem: can't distinguish #f from missing
        default
        v)))
```
Wait, this has the same #f-as-miss problem we noted in pick. But for get-or specifically, that's the documented semantics — if the stored value is #f, you get the default. Document this.

Actually wait, we use `equal?` and the issue with `_ref` returning `#f` for both "missing" and "stored #f". This is a documented limitation. For `kv:get-or`, we can either:
- Use `kv:has?` to check first
- Document the limitation

Better: use `has?` first:
```scheme
(define (kv:get-or store key default)
  (if (kv:_has store key)
      (kv:_ref store key)
      default))
```
This works correctly even if the value is `#f`.

**`kv:rename`** — Rename key, preserving value and position. Tricky to do preserving position with alist. We can use the existing `_set` pattern but need to remove old key in place. Looking at the existing patterns:
- `_set` replaces in place if key exists
- `_del` removes but rebuilds order

For rename preserving position: replace in place with new key.
```scheme
(define (kv:rename store old-key new-key)
  (if (and (kv:_has store old-key)
           (not (kv:_has store new-key)))  ; or handle overwrite
      ...
```

Actually, simpler: use `_fold` to build new store, replacing old key with new key.
```scheme
(define (kv:rename store old-key new-key)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (equal? k old-key)
          (kv:_set acc new-key v)
          (kv:_set acc k v)))))
```
But this loses position. To preserve position: replace in place.

Hmm, let me think. With the alist representation:
- If old-key exists and new-key doesn't: we want a single replacement in place.
- If old-key doesn't exist: no-op.
- If both exist: combine semantics — rename old to new, but new-key already has its own value? That's ambiguous. Document that rename fails if new-key already exists.

Let me write it cleanly:
```scheme
(define (kv:rename store old-key new-key)
  (if (not (kv:_has store old-key))
      store  ; no-op, old key doesn't exist
      (if (kv:_has store new-key)
          store  ; no-op, new key already exists (ambiguous)
          (kv:_fold store (quote ())
            (lambda (k v acc)
              (if (equal? k old-key)
                  (kv:_set acc new-key v)
                  (kv:_set acc k v)))))))
```

This preserves order among all keys except: when we hit `old-key`, we substitute `new-key`. The position of `old-key` is preserved as the position of `new-key`. All other keys keep their relative order.

Actually wait — when we encounter `old-key` and add `new-key`, this will REPLACE `new-key` if it's already in `acc`. But `acc` only contains keys we've already seen, and we're processing in order, so when we hit old-key, we haven't seen new-key yet (or have we?). Since `new-key` doesn't exist in store (we checked), `_set acc new-key v` just appends. Good.

But wait — what about other later keys? They're added with their own keys, so they don't conflict with `new-key`. Good.

So position of old-key is preserved (as new-key's position), and all other keys keep their positions. 

**`kv:diff`** — Return (added removed changed) between a and b.
- `added`: keys in b but not in a, with b's value
- `removed`: keys in a but not in b, with a's value
- `changed`: keys in both, with values that differ

```scheme
(define (kv:diff a b)
  (let ((added (quote ()))
        (removed (quote ()))
        (changed (quote ())))
    ; iterate a: for each (k . va), check b
    (let ((a-folded (kv:_fold a (cons added (cons removed changed))
                    (lambda (k v acc)
                      (let ((vb (kv:_ref b k)))
                        (cond
                          ((eq? vb #f)
                           (cons (cons (cons k v) (car acc))
                                 (cdr acc)))  ; removed grows
                          ((equal? vb v)
                           acc)  ; unchanged
                          (else
                           (cons (car acc)
                                 (cons (cdr acc) ... )))  ; hmm getting complex
                          ))))))
    ...
    ))
```

This is getting messy. Let me use a simpler approach with side-effects-free accumulator pattern. Actually we can compute them separately.

Simpler approach: compute three lists independently.

```scheme
(define (kv:diff a b)
  (let* ((ka (kv:keys a))
         (kb (kv:keys b))
         (added-alist
           (kv:_fold b (quote ())
             (lambda (k v acc)
               (if (kv:_has a k)
                   acc
                   (kv:_set acc k v)))))
         (removed-alist
           (kv:_fold a (quote ())
             (lambda (k v acc)
               (if (kv:_has b k)
                   acc
                   (kv:_set acc k v)))))
         (changed-alist
           (kv:_fold a (quote ())
             (lambda (k v acc)
               (let ((vb (kv:_ref b k)))
                 (if (and (not (eq? vb #f))  ; but eq? #f ambiguous
                          (not (equal? vb v)))
                     (kv:_set acc k (cons v vb))  ; (old . new)
                     acc))))))
    (list added-alist removed-alist changed-alist)))
```

The `changed-alist` stores `(k . (old-val . new-val))` entries. The `(eq? vb #f)` check has the ambiguity problem. To be safe, use `kv:_has`:
```scheme
(define (kv:diff a b)
  ...
  (changed-alist
    (kv:_fold a (quote ())
      (lambda (k va acc)
        (if (kv:_has b k)
            (let ((vb (kv:_ref b k)))
              (if (equal? va vb)
                  acc
                  (kv:_set acc k (cons va vb))))
            acc))))))
```

Wait — this includes keys where `va` and `vb` are both present. For the changed-alist, we want to include only those where the values actually differ. The `_has b k` check correctly identifies keys present in b, and then we compare. If they're equal, skip; if not, include as `(k . (old . new))`.

But the ordering: this walks `a`, so changed-alist is in `a`'s order. That's natural.

**`kv:partition`** — Split into (matching . non-matching):
```scheme
(define (kv:partition store proc)
  (kv:_fold store (list (quote ()) (quote ()))
    (lambda (k v acc)
      (if (proc k v)
          (list (kv:_set (car acc) k v) (car (cdr acc)))
          (list (car acc) (kv:_set (car (cdr acc)) k v))))))
```

Returns `(matching-store . non-matching-store)`.

**`kv:equal?`** — Deep structural equality:
```scheme
(define (kv:equal? a b)
  (let ((ka (kv:keys a))
        (kb (kv:keys b)))
    (if (= (length ka) (length kb))
        (let loop ((xs ka))
          (if (null? xs)
              #t
              (let ((k (car xs)))
                (let ((va (kv:_ref a k))
                      (vb (kv:_ref b k)))
                  (if (and (equal? va vb)
                           (kv:_has b k))
                      (loop (cdr xs))
                      #f)))))
        #f)))
```

Wait, this has the #f-as-value issue. If `va` is `#f`, the test passes even when key is missing in b. Use `kv:_has`:
```scheme
(define (kv:equal? a b)
  (let ((ka (kv:keys a)))
    (if (= (length ka) (kv:size b))
        (let loop ((xs ka))
          (if (null? xs)
              #t
              (let ((k (car xs)))
                (if (kv:_has b k)
                    (if (equal? (kv:_ref a k) (kv:_ref b k))
                        (loop (cdr xs))
                        #f)
                    #f))))
        #f)))
```

OK now let me think about what tests to add. Let me add tests T30-T34 for these 5 new functions:

T30: get-or returns value if present, default if missing
T31: rename preserves position, no-op if old key missing or new key exists
T32: diff returns added/removed/changed
T33: partition splits store by predicate
T34: equal? compares two stores deeply

Let me make sure all existing tests still pass and the new ones pass.

Wait, let me think more carefully about the lib changes. I want to keep things clean and the comment block in the file should reflect the new phase.

Let me draft the new lib/kv.aura:

Top comment:
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
```

Then bump version to 6.

Add exports for the new functions.

Now let me think about whether the existing code is clean. Looking at the existing code, all seems good. The `kv:_mem` helper is already added for `kv:pick`.

Let me also think — are there other things I could add that are useful? Maybe:
- `kv:get-or` (already planned)
- `kv:rename`
- `kv:diff`
- `kv:partition`
- `kv:equal?`

That's 5 new ops. Phase 7.

Actually let me consider whether to add these in a way that's truly "new capability". The controller directive says "advance SPEC phase (new capability)". This is exactly that.

Let me write the full new lib/kv.aura file.

Actually wait, before I write, let me double-check the order of operations. The export block needs to include all exports. Let me list all exports:
- kv:version
- kv:open, set, get, del, has?, keys, size, clear
- kv:mset, mget, update, merge, copy
- kv:values, entries, filter, find, empty?, for-each
- kv:reduce, any?, every?, pick, omit, map-values
- NEW: kv:get-or, rename, diff, partition, equal?

OK now let me write the full file.

Actually, looking at the SPEC again — Phase 4 says "optional: batch helpers (T13+)". The current implementation already has T18+ (Phase 5), T24+ (Phase 6). So we've already gone beyond the SPEC. Adding Phase 7 is a natural extension.

Let me now consider: are there tests T13-T29 in the smoke file that don't conflict? Let me count:
- T1-T12: Phase 0-2 (basic)
- T13-T17: Phase 3 (multi-key stress)
- T18, T19, T19b, T20, T21, T21b, T22, T23: Phase 5 (iteration)
- T24-T29, T26b, T26c, T27b, T27c: Phase 6 (fold/predicate/projection)

So tests go up to T29 with some sub-tests. I'll add T30-T34 for Phase 7.

Let me carefully write the new tests:

T30: kv:get-or
```scheme
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
  (t "T30-get-or"
     (and (= (kv:get-or s "a" 99) 1)
          (= (kv:get-or s "missing" 42) 42)
          (= (kv:get-or (kv:open) "anything" 7) 7))))
```

T31: kv:rename
```scheme
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
          (equal? (car (cdr rk)) "bb")  ; b's position preserved
          (equal? (car (cdr (cdr rk))) "c"))))
```

Also test no-op semantics:
```scheme
(t "T31b-rename-noop-missing"
   (let* ((s (kv:set (kv:open) "a" 1))
          (r (kv:rename s "ghost" "new")))
     (and (= (kv:size r) 1) (equal? (kv:get r "a") 1))))
(t "T31c-rename-noop-exists"
   (let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (r (kv:rename s "a" "b")))
     (and (= (kv:size r) 2) (equal? (kv:get r "a") 1) (equal? (kv:get r "b") 2))))
```

T32: kv:diff
```scheme
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
```

Hmm wait, kv:get returns the value, and for changed-alist the value is `(cons 2 20)` which is `(2 . 20)`. The test expects `(equal? (kv:get changed "y") (cons 2 20))`. Should work.

But this is getting fragile. Let me make sure: `kv:_ref` returns `(cdr p)` where `p = (cons k (cons 2 20))`. So `(cdr p)` = `(cons 2 20)` = `(2 . 20)`. Yes, that's `(2 . 20)`. And `(cons 2 20)` is the same. ✓

T33: kv:partition
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "d" 4) "e" 5))
       (p (kv:partition s (lambda (k v) (even? v))))
       (match (car p))
       (nomatch (car (cdr p))))
  (t "T33-partition"
     (and (= (kv:size match) 2)
          (equal? (kv:get match "b") 2)
          (equal? (kv:get match "d") 4)
          (= (kv:size nomatch) 3)
          (equal? (kv:get nomatch "a") 1)
          (equal? (kv:get nomatch "c") 3)
          (equal? (kv:get nomatch "e") 5))))
```

T34: kv:equal?
```scheme
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (b (kv:set (kv:set (kv:open) "b" 2) "a" 1))  ; different insertion order
       (c (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
  (t "T34-equal"
     (and (kv:equal? a b)  ; insertion order doesn't matter for equality
          (kv:equal? a c)
          (not (kv:equal? a (kv:set a "c" 3)))
          (not (kv:equal? a (kv:set (kv:set (kv:open) "a" 1) "b" 3))))))
```

And `kv:equal?` on different sizes:
```scheme
(t "T34b-equal-empty"
   (and (kv:equal? (kv:open) (kv:open))
        (not (kv:equal? (kv:open) (kv:set (kv:open) "a" 1)))))
```

OK let me write the full files now.

Actually wait — let me reconsider the `kv:diff` design. The current diff returns `(added-alist removed-alist changed-alist)`. But the smoke test I wrote treats changed-alist as a "store" — `kv:get changed "y"` should return `(cons 2 20)`. That's because I'm storing `(k . (old . new))` entries, and `kv:get` returns the cdr. OK that works.

But there's a subtlety: I documented `kv:diff` returns `(added removed changed)`. And changed is a "store" of `(k . (old . new))` pairs. That's a reasonable representation.

Let me finalize.

Actually, let me reconsider `kv:rename`. The spec doesn't mention it, but it's a common KV operation. Let me keep it.

Also for `kv:equal?` — this is structural equality ignoring insertion order. Good.

Let me write the patch now. The file is fairly long, so I'll do a full file replacement.

Here's my plan:
- Update header comment to include Phase 7
- Bump version to 6
- Add new exports: kv:get-or, kv:rename, kv:diff, kv:partition, kv:equal?
- Add new function definitions

For tests, I'll add T30-T34b to smoke.aura.

Let me now write the full files.

Actually, looking more carefully, I realize there's one issue with `kv:get-or`. If the store contains a key whose value is `#f`, `kv:get-or` returns `#f`, not the default. With our `kv:_has` check, we correctly distinguish "stored #f" from "missing". Let me make sure the implementation is right:

```scheme
(define (kv:get-or store key default)
  (if (kv:_has store key)
      (kv:_ref store key)
      default))
```

This correctly returns the stored value (even if `#f`) if the key exists, otherwise returns the default. ✓

For `kv:rename`, I want to be careful about the case where `old-key = new-key`. Let's check:
- `kv:_has store k` is `#t` (old exists)
- `kv:_has store new-key` is `#t` (same as old-key)
- So we return `store` unchanged. 

For `kv:diff`, edge case: both empty. Returns `((() () ()))`. The smoke test doesn't check this but let's be aware.

Actually let me reconsider `kv:diff`:
```scheme
(define (kv:diff a b)
  (let* ((added (kv:_fold b (quote ())
                    (lambda (k v acc)
                      (if (kv:_has a k)
                          acc
                          (kv:_set acc k v)))))
         (removed (kv:_fold a (quote ())
                       (lambda (k v acc)
                         (if (kv:_has b k)
                             acc
                             (kv:_set acc k v)))))
         (changed (kv:_fold a (quote ())
                       (lambda (k va acc)
                         (if (kv:_has b k)
                             (let ((vb (kv:_ref b k)))
                               (if (equal? va vb)
                                   acc
                                   (kv:_set acc k (cons va vb))))
                             acc)))))
    (list added removed changed)))
```

OK let me now write the full files.

Wait, I want to double-check `kv:partition`. The accumulator is `(match . nomatch)`. When processing each entry, we update one of the two lists. After processing, return `(match . nomatch)`.

```scheme
(define (kv:partition store proc)
  (kv:_fold store (list (quote ()) (quote ()))
    (lambda (k v acc)
      (let ((match (car acc))
            (nomatch (car (cdr acc))))
        (if (proc k v)
            (list (kv:_set match k v) nomatch)
            (list match (kv:_set nomatch k v)))))))
```

Returns a pair `(match . nomatch)`. ✓

For `kv:equal?`:
```scheme
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
```

This compares sizes first, then checks each key of `a` is in `b` with equal value. This implies the same multiset of keys. ✓

OK now let me write everything.

Actually one more concern: when extending tests/smoke.aura, I need to make sure the existing tests still pass. They should, since I'm only adding new test cases at the end (T30 onwards) and not modifying existing ones.

Let me also think about whether to bump version. Yes, bump to 6.

OK final plan for the patch:

1. lib/kv.aura: Add Phase 7 header comment, bump version to 6, add 5 new exports, add 5 new function definitions.

2. tests/smoke.aura: Add T30, T31, T31b, T31c, T32, T33, T34, T34b tests.

Total new tests: 8. Total tests will be: 35 + 8 = 43. New score target: 43/43.

Wait, looking again, the test count is 35. Let me recount from the smoke file:
- T1-T12: 12 tests
- T13-T17: 5 tests (T13, T14, T15, T16, T17)
- T18: 1
- T19, T19b: 2
- T20: 1
- T21, T21b: 2
- T22: 1
- T23: 1
- T24: 1
- T25: 1
- T26, T26b, T26c: 3
- T27, T27b, T27c: 3
- T28: 1
- T29: 1

Total: 12 + 5 + 1 + 2 + 1 + 2 + 1 + 1 + 1 + 1 + 3 + 3 + 1 + 1 = 35 ✓

Adding 8 tests brings total to 43. New score: 43/43.

Let me finalize the patch now.

Actually, let me reconsider whether to add all 5 new ops. That's a lot at once. But they're all pure functional and small. And the journal shows we go through phases systematically, so adding a Phase 7 with multiple coherent ops is natural.

Actually, let me be a bit more conservative and add 4 instead of 5. Let me skip `kv:equal?` and use something else... or keep it. Hmm.

Actually 5 is fine. They form a coherent "convenience / comparison" phase. Let me keep all 5.

Final answer ready. Let me write the patch.

Wait, I need to consider: should I include the `(version)` in the comment header at the top of the file? Let me check existing pattern:
- Top comment mentions "Phase 0..2", "Phase 3", "Phase 4", "Phase 5", "Phase 6"
- Below: `(define kv:version 5)` then `(export ...)` 

I'll bump version to 6 and add Phase 7 description.

Let me write the full file:

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
        kv:equal?)

(define kv:version 6)

; ... [existing internals] ...

; Phase 7 section at the bottom.
```

OK let me finalize. I'll write the full file.

Actually I realize the existing file already has version 5. The journal shows it was at version 5 in the last test output. I need to bump to 6.

Let me carefully construct the full new lib/kv.aura file.

One more consideration: let me think about `kv:diff` more carefully. The smoke test:

```scheme
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
```

Walking through:
- a = {x:1, y:2, z:3} in that order
- b = {y:20, z:3, w:4} in that order
- added (in b not in a): w → {w:4}
- removed (in a not in b): x → {x:1}
- changed (in both, different value): y → {y: (2 . 20)}
- z is unchanged

Walk through `kv:diff`:
- added: walk b. b has y (in a, skip), z (in a, skip), w (not in a, add). Result: {w:4}. ✓
- removed: walk a. a has x (not in b, add), y (in b, skip), z (in b, skip). Result: {x:1}. ✓
- changed: walk a. a has x (not in b, skip), y (in b, vb=20, va=2, different, add (y . (2 . 20))), z (in b, vb=3, va=3, equal, skip). Result: {y: (2 . 20)}. ✓



Now let me also think about `kv:partition` smoke test:
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "d" 4) "e" 5))
       (p (kv:partition s (lambda (k v) (even? v))))
       (match (car p))
       (nomatch (car (cdr p))))
  (t "T33-partition"
     (and (= (kv:size match) 2)
          (equal? (kv:get match "b") 2)
          (equal? (kv:get match "d") 4)
          (= (kv:size nomatch) 3)
          (equal? (kv:get nomatch "a") 1)
          (equal? (kv:get nomatch "c") 3)
          (equal? (kv:get nomatch "e") 5))))
```

Walking through partition:
- s = {a:1, b:2, c:3, d:4, e:5}
- predicate: even? value
- Walking in order:
  - a:1 → nomatch (no, wait, the predicate is even? — a is 1, odd → nomatch)
  - b:2 → match
  - c:3 → nomatch
  - d:4 → match
  - e:5 → nomatch

Wait actually the predicate is `(lambda (k v) (even? v))`. Let me re-check.

`(even? 1)` → #f
`(even? 2)` → #t
`(even? 3)` → #f
`(even? 4)` → #t
`(even? 5)` → #f

So:
- a:1 → nomatch (even? 1 is #f)
- b:2 → match
- c:3 → nomatch
- d:4 → match
- e:5 → nomatch

match = {b:2, d:4}, nomatch = {a:1, c:3, e:5}. ✓

Test expectations:
- size match = 2 ✓
- get match "b" = 2 ✓
- get match "d" = 4 ✓
- size nomatch = 3 ✓
- get nomatch "a" = 1 ✓
- get nomatch "c" = 3 ✓
- get nomatch "e" = 5 ✓



Now `kv:rename` smoke test:
```scheme
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
```

Walking rename:
- s = {a:1, b:2, c:3}
- rename "b" → "bb"
- _fold walks s, processing:
  - a:1 → add a:1 to acc. acc = {a:1}
  - b:2 → add bb:2 to acc. acc = {a:1, bb:2}
  - c:3 → add c:3 to acc. acc = {a:1, bb:2, c:3}

Wait — when adding bb:2, we call `kv:_set acc "bb" 2`. acc is `{a:1}`. "bb" not in acc. Append. acc = {a:1, bb:2}. ✓
Then c:3 → acc = {a:1, bb:2, c:3}. ✓

So:
- size r = 3 ✓
- has? "b" = #f ✓
- get "bb" = 2 ✓
- get "a" = 1 ✓
- get "c" = 3 ✓
- keys = (a bb c) ✓



And the no-op tests:
```scheme
(t "T31b-rename-noop-missing"
   (let* ((s (kv:set (kv:open) "a" 1))
          (r (kv:rename s "ghost" "new")))
     (and (= (kv:size r) 1) (equal? (kv:get r "a") 1))))
(t "T31c-rename-noop-exists"
   (let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (r (kv:rename s "a" "b")))
     (and (= (kv:size r) 2) (equal? (kv:get r "a") 1) (equal? (kv:get r "b") 2))))
```

Walking rename "ghost" → "new":
- _has "ghost" in {a:1} → #f
- Return store unchanged. ✓

Walking rename "a" → "b" in {a:1, b:2}:
- _has "a" → #t
- _has "b" → #t (already exists)
- Return store unchanged. ✓

Good.

For `kv:get-or`:
```scheme
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
  (t "T30-get-or"
     (and (= (kv:get-or s "a" 99) 1)
          (= (kv:get-or s "missing" 42) 42)
          (= (kv:get-or (kv:open) "anything" 7) 7))))
```

- get-or {a:1, b:2} "a" 99 → _has "a" → #t, _ref "a" → 1. Return 1. ✓
- get-or {a:1, b:2} "missing" 42 → _has "missing" → #f. Return 42. ✓
- get-or {} "anything" 7 → _has "anything" → #f. Return 7. ✓



For `kv:equal?`:
```scheme
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (b (kv:set (kv:set (kv:open) "b" 2) "a" 1))
       (c (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
  (t "T34-equal"
     (and (kv:equal? a b)
          (kv:equal? a c)
          (not (kv:equal? a (kv:set a "c" 3)))
          (not (kv:equal? a (kv:set (kv:set (kv:open) "a" 1) "b" 3))))))

(t "T34b-equal-empty"
   (and (kv:equal? (kv:open) (kv:open))
        (not (kv:equal? (kv:open) (kv:set (kv:open) "a" 1)))))
```

Walking equal?:
- equal? {a:1, b:2} {b:2, a:1} → size 2 == 2. Walk a's keys: ("a" "b").
  - "a": has? b → yes → _ref a "a" = 1, _ref b "a" = 1 → equal. Continue.
  - "b": has? b → yes → _ref a "b" = 2, _ref b "b" = 2 → equal. Continue.
  - Null. Return #t. ✓
- equal? a c → both {a:1, b:2}. #t. ✓
- equal? a {a:1, b:2, c:3} → size 3 vs 2 → #f. ✓ (covers size mismatch)
- equal? a {a:1, b:3} → size 2 vs 2. Walk a's keys.
  - "a": has? b → yes → _ref = 1, _ref = 1. equal. Continue.
  - "b": has? b → yes → _ref = 2, _ref = 3. Not equal. Return #f. ✓

Walking equal? empty tests:
- equal? {} {} → size 0 == 0. Null xs. Return #t. ✓
- equal? {} {a:1} → size 0 vs 1 → #f. ✓



Now I have full confidence in the implementation and tests. Let me write the final patch.

Actually, one more thought: I'm using `even?` as a built-in predicate. Is `even?` available in Aura? Looking at the existing tests, they use `>`, `=`, `<`, `+`, `*`, `equal?`, `eq?`, `pair?`, `null?`, `not`, `length`, `string?`, `set!`, `display`, `newline`, `car`, `cdr`, `cons`, `list`, `quote`, `begin`, `let`, `let*`, `if`, `lambda`. But not `even?` explicitly.

Hmm. To be safe, I'll use a lambda instead: `(lambda (k v) (= (mod v 2) 0))` or `(lambda (k v) (> v 2))`.

Actually, looking at T19 in the existing tests: `(lambda (k v) (> v 2))`. That's safe. Let me use the same style.

Actually `mod` may or may not be available. Let me use a safe predicate. Let me write it as:
```scheme
(kv:partition s (lambda (k v) (= 0 (- v (mod-or-something v 2)))))
```

Hmm, complicated. Let me just use a different value-based predicate. Maybe:
```scheme
(kv:partition s (lambda (k v) (> v 2)))
```

With s = {a:1, b:2, c:3, d:4, e:5}:
- a:1 → 1 > 2 → #f → nomatch
- b:2 → 2 > 2 → #f → nomatch
- c:3 → 3 > 2 → #t → match
- d:4 → 4 > 2 → #t → match
- e:5 → 5 > 2 → #t → match

So match = {c:3, d:4, e:5} (3 entries), nomatch = {a:1, b:2} (2 entries).

Let me update the test accordingly:
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "d" 4) "e" 5))
       (p (kv:partition s (lambda (k v) (> v 2))))
       (match (car p))
       (nomatch (car (cdr p))))
  (t "T33-partition"
     (and (= (kv:size match) 3)
          (equal? (kv:get match "c") 3)
          (equal? (kv:get match "d") 4)
          (equal? (kv:get match "e") 5)
          (= (kv:size nomatch) 2)
          (equal? (kv:get nomatch "a") 1)
          (equal? (kv:get nomatch "b") 2))))
```

OK that works. Let me finalize.

Now let me write the full files. I'll be careful to preserve all the existing internals.

OK writing the patch now.

Actually, looking at the file once more — the file is quite long. Let me write it carefully.</think>

### REVIEW

- **Strengths**
  - All 35/35 tests green across Phases 0–6 of the in-file roadmap. Alist-of-cons representation is robust (defensive skipping of non-pair cells), insertion order is preserved everywhere, and every op is pure / functional.
  - Export-before-define discipline maintained; API names stable; no FS / no network / no host escape used.
  - Last patch fixed the `kv:pick` ordering bug correctly (now walks the *store*, not the requested-keys list). Doc comment matches behavior.
  - Internal `kv:_mem` helper is in place and used cleanly by `kv:pick`.
- **Failures / Risks**
  - None active; SCORE is full. Plateau risk: further naive patches can only regress.
  - `#f`-as-stored-value vs `#f`-as-miss is a documented limitation that `kv:get-or` must respect (use `kv:_has`, not `kv:_ref`'s return value).
  - Real "host escape" / FS path is still completely absent; the codebase is denseness-clean.
- **Denseness / Host risks**
  - Zero host dependencies; everything derived from a small set of internal primitives (`_ref`, `_has`, `_set`, `_del`, `_fold`, `_map`, `_mem`). Excellent substrate for further extension.

### DIRECTION

- **Target phase: Phase 7 — convenience / comparison helpers.** Same denseness posture (pure Aura, derived from existing internals), keeps all T1–T29 green, advances SPEC beyond its current implicit ceiling (Phase 4). No FS escapes, no API renames, no internals touched.
- **Ops to add** (5 new, all pure, all derive from existing primitives; export-before-define preserved):
  - `kv:get-or`  — `(store key default)`; uses `kv:_has` so a stored `#f` is distinguishable from a miss.
  - `kv:rename`  — `(store old-key new-key)`; replaces the old key in place to preserve insertion position; no-op when `old-key` is absent or `new-key` is already present.
  - `kv:diff`    — `(a b)` → `(added removed changed)` as three sub-stores; `changed` stores `(k . (old . new))` pairs; preserves `a`'s iteration order.
  - `kv:partition` — `(store proc)` → `(match . nomatch)` pair of stores; preserves order.
  - `kv:equal?`  — `(a b)` deep structural equality, ignoring insertion order; size-checked first.
- **Bump** `kv:version` to `6`. **Extend** `tests/smoke.aura` with **T30–T34b** (8 new tests). Total target: **43/43**.
- **Do NOT touch**: any Phase 0–6 op, internal alist primitives, export order of existing names, or `kv:_mem`.

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
        kv:equal?)

(define kv:version 6)

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
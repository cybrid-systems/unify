<think>
The current state: 75/75 passing, Phase 10 done. The SPEC's success criterion is "Phase ≥ 3 with all T1–T12 green, multi-generation history in `evolve/journal.jsonl`." We're well past that. We should continue advancing — the project description says "iteratively self-evolve it under a fixed test suite" and Phase 4+ is "optional" in SPEC but we've been pushing far beyond.

Current lib has phases 0-10 done. What's a natural next phase? Looking at what's been done:
- Phase 0-2: core ops
- Phase 3: stress
- Phase 4: batch (mset, mget, update, merge, copy)
- Phase 5: iteration (values, entries, filter, find, empty?, for-each)
- Phase 6: fold/predicate/projection/selection (reduce, any?, every?, pick, omit, map-values)
- Phase 7: convenience/comparison (get-or, rename, diff, partition, equal?)
- Phase 8: positional/conditional/inversion (first, last, rest, butlast, take, drop, invert, set-if-absent)
- Phase 9: aggregation/positional/composition (nth, count, sum, zip, swap)
- Phase 10: statistical/numeric (min, max, product, avg)

Natural next phases could be:
- Phase 11: set-theoretic ops (union, intersection, difference/subtract)
- Phase 12: type predicates / coercion helpers
- Phase 13: sorting (sort-by, sort-keys)
- Phase 14: range/slice/head/tail (already done)
- Phase 15: dictionary operations (assoc, dissoc — aliases for set/del)
- Phase 16: composition helpers (compose-key, compose-val, juxt)
- Phase 17: comparison: contains-value?, contains-key? (has? exists), some other validation
- Phase 18: range ops (between, lower-bound, upper-bound)
- Phase 19: group-by
- Phase 20: JSON-like serialization (to-alist, from-alist — but we have entries, this is just rename)
- Phase 21: lazy/transducer-like ops (map, filter, take as transducers)

Good candidates:
- **set-theoretic**: union, intersection, difference (kv:subtract) — these are clean, useful, pure-functional
- **range queries**: min-key, max-key, key<, key>, slice (all keys between two)
- **group-by**: kv:group-by (store proc) → (list of stores)
- **frequency/histogram**: kv:histogram (store) — but values are keys
- **invert**-like: kv:project (only specific keys, alias for pick), kv:without (alias for omit)
- **sort**: kv:sort-by, kv:sort-keys — though sorting can break insertion order, which is a fundamental property

Wait, sorting would break insertion order. That's problematic given the design's strong "insertion order preserved" guarantee. Better to skip.

Let me think about set-theoretic:
- kv:union (a b) — a's keys, b's keys, b wins on conflict
- kv:intersection (a b) — keys present in both, with b's values
- kv:subtract (a b) — keys in a not in b (this is like kv:omit! a (keys b))

These are clean. They could be Phase 11: set-theoretic / relational helpers.

Another idea: **kv:group-by** — (store proc) where proc is (k v) → group-key, returns a store of group-key → sub-store. Pure functional, no FS, derived from existing primitives.

Another idea: **kv:histogram** — (store) returns a store of value → count (frequency table). Useful, pure, derived from fold.

Let me go with **Phase 11: set-theoretic / relational helpers** because they're well-defined, easy to test, and feel like a natural extension of merge/diff. The trio is:
- `kv:union` (a b) — merge-like but b wins
- `kv:intersection` (a b) — only common keys, with b's values
- `kv:subtract` (a b) — keys in a not in b (i.e., a minus b's keys)

Plus one more for good measure: `kv:symmetric-diff` (a b) — keys in either but not both, with b's values. Or just `kv:disjoint?` predicate.

Actually, let me design it more carefully:

**Phase 11: set-theoretic / relational helpers**
- `kv:union` (a b) — all keys from both, b wins on conflict; a's order then b-only keys
- `kv:intersection` (a b) — common keys only, with b's values; a's insertion order
- `kv:subtract` (a b) — keys in a not in b; a's order (essentially a minus b)
- `kv:disjoint?` (a b) — #t if no key in both; #f otherwise

Or maybe a more interesting set: include `kv:group-by` for the histogram/grouping feel.

Let me go with: `kv:union`, `kv:intersection`, `kv:subtract`, `kv:disjoint?`. These are 4 ops, all pure, all derived from existing internals.

Actually, thinking about this more — `kv:union` and `kv:merge` are nearly identical. `kv:merge` is already right-biased. So `kv:union` is just an alias. Hmm. Let me think.

`kv:merge` is right-biased and a's order is preserved (b's keys fold in over a). So it's a union with b-wins semantics. `kv:union` would be the same op under a different name. Not useful as a separate op.

Let me reconsider. The valuable additions for Phase 11 are:
- `kv:intersection` (a b) — common keys, with b's values; a's order
- `kv:subtract` (a b) — a minus b's keys
- `kv:disjoint?` (a b) — #t iff no shared keys
- `kv:subset?` (a b) — #t iff every key in a is in b (with same value? or just presence?)

Actually `kv:subset?` is interesting and complements `kv:equal?`. Let's add it.

So Phase 11: 4 ops:
- `kv:intersection`
- `kv:subtract`
- `kv:disjoint?`
- `kv:subset?`

These are clean, pure, derived. Let me write the code.

`kv:intersection` (a b):
- Walk `a`, keep entries whose key is in `b`, with b's value.
- a's order preserved.

```
(define (kv:intersection a b)
  (kv:_fold a (quote ())
    (lambda (k va acc)
      (if (kv:_has b k)
        (kv:_set acc k (kv:_ref b k))
        acc))))
```

`kv:subtract` (a b):
- Walk `a`, drop entries whose key is in `b`.
- a's order preserved among survivors.

```
(define (kv:subtract a b)
  (kv:_fold a (quote ())
    (lambda (k v acc)
      (if (kv:_has b k)
        acc
        (kv:_set acc k v)))))
```

`kv:disjoint?` (a b):
- Walk `a`, if any key is in `b`, return #f. Otherwise #t.

```
(define (kv:disjoint? a b)
  (if (null? a)
    #t
    (let ((p (car a)))
      (if (pair? p)
        (if (kv:_has b (car p))
          #f
          (kv:disjoint? (cdr a) b))
        (kv:disjoint? (cdr a) b)))))
```

`kv:subset?` (a b):
- Walk `a`, every key must be in `b` with equal value.

```
(define (kv:subset? a b)
  (let loop ((xs a))
    (if (null? xs)
      #t
      (let ((p (car xs)))
        (if (pair? p)
          (if (kv:_has b (car p))
            (if (equal? (kv:_ref b (car p)) (cdr p))
              (loop (cdr xs))
              #f)
            #f)
          (loop (cdr xs)))))))
```

Wait — kv:subset? semantics. If a is a strict subset of b in keys, with equal values, return #t. If a == b, return #t. If a has any key not in b, return #f. If a has any key with a different value in b, return #f.

So kv:subset? could be: every entry in `a` has an equal-value entry in `b`. Same as kv:equal? minus the size check.

This is good.

Let me also think about what tests should be added. Following the same pattern, I should add tests T54-T57 (or thereabouts).

**T54: intersection** — keeps common keys with b's values, a's order.
```scheme
(let* ((a (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "a" 10) "b" 2) "d" 4))
       (i (kv:intersection a b))
       (ik (kv:keys i)))
  (t "T54-intersection"
     (and (= (kv:size i) 2)
          (equal? (kv:get i "a") 10)  ; b's value
          (equal? (kv:get i "b") 2)
          (eq? (kv:get i "c") #f)
          (eq? (kv:get i "d") #f)
          (equal? (car ik) "a")
          (equal? (car (cdr ik)) "b"))))
```

**T54b**: intersection on disjoint stores is empty.

**T54c**: intersection on empty store is empty.

**T55: subtract** — drops keys in b, keeps a's other keys.
```scheme
(let* ((a (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:set (kv:set (kv:open) "b" 99) "c" 88))
       (s (kv:subtract a b))
       (sk (kv:keys s)))
  (t "T55-subtract"
     (and (= (kv:size s) 1)
          (equal? (kv:get s "a") 1)
          (eq? (kv:get s "b") #f)
          (eq? (kv:get s "c") #f)
          (equal? (car sk) "a"))))
```

**T55b**: subtract with no shared keys is identity.
**T55c**: subtract with all shared keys is empty.

**T56: disjoint?** — true when no key overlap, false when shared.
```scheme
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
       (c (kv:set (kv:set (kv:open) "a" 99) "e" 5)))
  (t "T56-disjoint?"
     (and (kv:disjoint? a b)
          (not (kv:disjoint? a c))
          (kv:disjoint? (kv:open) a)
          (not (kv:disjoint? a a)))))
```

**T57: subset?** — every entry in a is in b with equal value.
```scheme
(let* ((a (kv:set (kv:set (kv:open) "x" 1) "y" 2))
       (b (kv:set (kv:set (kv:set (kv:open) "x" 1) "y" 2) "z" 3))
       (c (kv:set (kv:set (kv:open) "x" 1) "y" 99)))
  (t "T57-subset?"
     (and (kv:subset? a b)
          (not (kv:subset? b a))
          (kv:subset? a a)
          (not (kv:subset? a c)))))
```

**T57b**: subset? on empty store is #t (vacuous).
**T57c**: subset? where a has a key not in b is #f.

OK let me finalize. I need to:
1. Update lib/kv.aura:
   - Add Phase 11 to comment header
   - Add 4 new exports
   - Bump kv:version to 11
   - Add 4 new op definitions
2. Update tests/smoke.aura:
   - Add T54, T54b, T54c, T55, T55b, T55c, T56, T57, T57b, T57c

Let me draft the lib patch.

Looking at the current lib, the export list is large. I need to add 4 names: kv:intersection, kv:subtract, kv:disjoint?, kv:subset?

Let me find a good place to insert the new ops. After Phase 10 (kv:avg), before the closing — that's the natural position.

Let me also think about edge cases:

- kv:intersection with a value that's #f in b: should we keep the entry with #f? Yes — b has the key, b's value is #f, we keep (k . #f). The internal kv:_set handles this fine.
- kv:subset? where b has #f value matching a's #f value: equal? returns #t for #f, so this works.
- kv:subset? where b has key with #f value but a has the same key with #f value: equal? #f == #f is #t, so this is "subset".
- kv:disjoint? between identical stores: not disjoint (they share all keys). So returns #f.

OK, let me write the patch.

One concern: the patches are full-file replacements. Let me reconstruct the full file.

Actually let me first check if there's a recent kv.aura journal file to look at, but I think the current source in the prompt is the latest. Let me just write the full file.

Let me carefully construct the full lib/kv.aura content with the additions:

1. Update phase comment header to mention Phase 11
2. Add new exports in the export list (before the closing paren)
3. Bump kv:version to 11
4. Add Phase 11 section after Phase 10 (after kv:avg)

Let me write it out.

For the export list, the order matters. Let me find where to add. Currently:
```
(export kv:version
        kv:open
        ...
        kv:product
        kv:avg)
```

I'll add the 4 new ones after kv:avg, alphabetically (intersection, subtract, disjoint?, subset? — actually I'll group by concept: intersection/subtract first, then disjoint?/subset? predicates).

```
        kv:intersection
        kv:subtract
        kv:disjoint?
        kv:subset?)
```

For the version comment, add Phase 11 line:
```
; Phase 11:  set-theoretic / relational helpers
;             (intersection, subtract, disjoint?, subset?).
```

For the new code section, after kv:avg (which ends with the `)` for `/` expression and the closing of the define), insert:

```scheme
; ---------------------------------------------------------------------------
; Phase 11 set-theoretic / relational helpers.
; Pure functional; insertion order of the LEFT (or sole) operand is
; preserved by construction; no FS escapes. All derive from existing
; alist primitives.
;
; Conventions:
;   * `kv:intersection` returns entries whose key is present in both
;     operands, with the RIGHT operand's value (mirroring kv:merge's
;     right-wins bias and kv:diff's "b-side wins" convention).
;   * `kv:subtract` is the LEFT-minus-RIGHT set difference: keys
;     present in `a` are dropped when they also appear in `b`. The
;     survivor order follows `a`.
;   * `kv:disjoint?` is a short-circuit existential: walks `a` and
;     returns `#f` the moment a shared key is found, `#t` otherwise.
;     Vacuous on the empty store (`#t`).
;   * `kv:subset?` is a value-aware subset: every entry in `a` must
;     have a structurally-equal entry in `b`. Empty `a` is a vacuous
;     `#t` (the empty set is a subset of every set). Size is *not*
;     checked — `a` may be smaller than, equal to, or a strict subset
;     of `b`. (Pair with `kv:equal?` for the size-checked version.)
; ---------------------------------------------------------------------------

; (kv:intersection a b) -> store.
; Keys present in both `a` and `b`, with `b`'s value (right-wins,
; consistent with kv:merge). Insertion order follows `a` (the left
; operand). Non-pair cells in `a` are skipped defensively.
(define (kv:intersection a b)
  (kv:_fold a (quote ())
    (lambda (k va acc)
      (if (kv:_has b k)
        (kv:_set acc k (kv:_ref b k))
        acc))))

; (kv:subtract a b) -> store.
; Set-difference: `a` minus the keys of `b`. Keys present in `a` are
; dropped when they also appear in `b`; the values that survive are
; `a`'s (the left operand). Insertion order follows `a`. The right
; operand's *values* are not consulted — only its key set matters,
; which is what "set difference" means.
(define (kv:subtract a b)
  (kv:_fold a (quote ())
    (lambda (k v acc)
      (if (kv:_has b k)
        acc
        (kv:_set acc k v)))))

; (kv:disjoint? a b) -> #t | #f.
; True iff no key appears in both `a` and `b`. Short-circuits on the
; first shared key, so it runs in O(min(|a|, shared-prefix)) in the
; best case. The empty store is vacuously disjoint from anything.
; Non-pair cells in `a` are skipped defensively.
(define (kv:disjoint? a b)
  (if (null? a)
    #t
    (let ((p (car a)))
      (if (pair? p)
        (if (kv:_has b (car p))
          #f
          (kv:disjoint? (cdr a) b))
        (kv:disjoint? (cdr a) b)))))

; (kv:subset? a b) -> #t | #f.
; Value-aware subset: every entry in `a` must have a structurally-
; equal entry in `b`. Vacuous `#t` on an empty `a`. `a` may be
; smaller, equal, or any size relative to `b` — this is the
; "structural subset" relation, not the "equal-size" relation; pair
; with `kv:equal?` when you also need to reject strict subsets.
(define (kv:subset? a b)
  (let loop ((xs a))
    (if (null? xs)
      #t
      (let ((p (car xs)))
        (if (pair? p)
          (let ((k (car p)))
            (if (kv:_has b k)
              (if (equal? (kv:_ref b k) (cdr p))
                (loop (cdr xs))
                #f)
              #f))
          (loop (cdr xs)))))))
```

Now for the tests. I need to add tests after T53. Let me write them:

```scheme
; ---- Phase 11: set-theoretic / relational helpers ----

; T54: intersection() keeps common keys with b's value; a's order.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "a" 10) "b" 2) "d" 4))
       (i (kv:intersection a b))
       (ik (kv:keys i)))
  (t "T54-intersection"
     (and (= (kv:size i) 2)
          (equal? (kv:get i "a") 10)
          (equal? (kv:get i "b") 2)
          (eq? (kv:get i "c") #f)
          (eq? (kv:get i "d") #f)
          (equal? (car ik) "a")
          (equal? (car (cdr ik)) "b"))))

; T54b: intersection() of disjoint stores is empty.
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (b (kv:set (kv:set (kv:open) "c" 3) "d" 4)))
  (t "T54b-intersection-disjoint"
     (= (kv:size (kv:intersection a b)) 0)))

; T54c: intersection() with an empty operand is empty.
(t "T54c-intersection-empty"
   (and (= (kv:size (kv:intersection (kv:open) (kv:set (kv:open) "a" 1))) 0)
        (= (kv:size (kv:intersection (kv:set (kv:open) "a" 1) (kv:open))) 0)))

; T55: subtract() drops keys present in b; a's other keys survive.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:set (kv:set (kv:open) "b" 99) "c" 88))
       (s (kv:subtract a b))
       (sk (kv:keys s)))
  (t "T55-subtract"
     (and (= (kv:size s) 1)
          (equal? (kv:get s "a") 1)
          (eq? (kv:get s "b") #f)
          (eq? (kv:get s "c") #f)
          (equal? (car sk) "a"))))

; T55b: subtract() with disjoint b is identity.
(t "T55b-subtract-identity"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
          (s (kv:subtract a b)))
     (and (= (kv:size s) 2)
          (equal? (kv:get s "a") 1)
          (equal? (kv:get s "b") 2))))

; T55c: subtract() with b == a is empty.
(t "T55c-subtract-self"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
     (= (kv:size (kv:subtract a a)) 0)))

; T56: disjoint? returns #t when no key overlap, #f otherwise.
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
       (c (kv:set (kv:set (kv:open) "a" 99) "e" 5)))
  (t "T56-disjoint?"
     (and (kv:disjoint? a b)
          (not (kv:disjoint? a c))
          (kv:disjoint? (kv:open) a)
          (not (kv:disjoint? a a)))))

; T57: subset? is value-aware: every a-entry must equal its b-entry.
(let* ((a (kv:set (kv:set (kv:open) "x" 1) "y" 2))
       (b (kv:set (kv:set (kv:set (kv:open) "x" 1) "y" 2) "z" 3))
       (c (kv:set (kv:set (kv:open) "x" 1) "y" 99)))
  (t "T57-subset?"
     (and (kv:subset? a b)
          (not (kv:subset? b a))
          (kv:subset? a a)
          (not (kv:subset? a c)))))

; T57b: subset? on empty a is vacuously #t.
(t "T57b-subset-empty"
   (kv:subset? (kv:open) (kv:set (kv:open) "anything" 1)))

; T57c: subset? rejects a with a key absent from b.
(t "T57c-subset-missing"
   (let* ((a (kv:set (kv:set (kv:open) "x" 1) "y" 2))
          (b (kv:set (kv:open) "x" 1)))
     (not (kv:subset? a b))))
```

That's 10 new tests (T54, T54b, T54c, T55, T55b, T55c, T56, T57, T57b, T57c). Total 75 + 10 = 85.

Let me write the final patch.

Wait, I should double-check the journal entry would log correctly. The journal accepts when score-improved, and we'd be going from 75 to 85. That's an improvement.

One thing to think about — for `kv:subset?` and the test "not (kv:subset? b a)" where b has 3 entries and a has 2 — since b is bigger than a, and a's entries are all in b, but b's "z" key is not in a, so checking a's keys against b: a has "x" and "y", both in b with equal values, so a is subset of b. And b is not subset of a because "z" is not in a. Correct.

For T57b: subset? of empty a against any b is #t. (vacuous). Correct.

For T57c: subset? where a has "x" and "y" but b only has "x" — a is not subset of b because "y" is not in b. Correct.

OK let me finalize the patch.

Actually, let me also think — should I update the kv:version to 11? Yes, that's the convention.

Let me write the full file now. The current file is large, so I need to reconstruct carefully.

Looking at the current lib, I'll preserve all existing content and add:
1. Phase 11 to the header comment
2. New exports
3. Bump version to 11
4. New code section

Let me write out the full file.

Actually one more thought — I should keep the existing "Phase 10" comment block intact and add a new "Phase 11" block. Let me look at the structure:

```
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
; Phase 10:  statistical / numeric aggregation helpers
;             (min, max, product, avg).
```

I'll add:
```
; Phase 11:  set-theoretic / relational helpers
;             (intersection, subtract, disjoint?, subset?).
```

after the Phase 10 line.

OK now let me write the complete file. Given the size, I'll be very careful.

Here's the full lib/kv.aura I'll produce. I'll use the existing content and add to it.

Actually, given the size of the file, I want to be careful. Let me carefully reproduce the full file with my additions. I'll copy from the provided source and insert the additions in the right places.

Let me build the new file mentally:

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
; Phase 10:  statistical / numeric aggregation helpers
;             (min, max, product, avg).
; Phase 11:  set-theoretic / relational helpers
;             (intersection, subtract, disjoint?, subset?).
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
        kv:swap
        kv:min
        kv:max
        kv:product
        kv:avg
        kv:intersection
        kv:subtract
        kv:disjoint?
        kv:subset?)

(define kv:version 11)

... (all the internals) ...

; (kv:avg store) -> arithmetic mean | #f.
; ... existing avg comment and code ...

; Phase 11 new code here
```

OK I have a plan. Let me write it all out now.

For the tests file, I just need to append the new tests at the end, before the SCORE display.

Let me also be careful: the original test file already has tests T1 through T53. The current total is 75. Let me count:

T1, T2, T3, T4, T5, T6, T7, T8, T9, T10, T11, T12, T13, T14, T15, T16, T17 = 17 (Phase 0-3)
T18, T19, T19b, T20, T21, T21b, T22, T23 = 8 (Phase 5)
T24, T25, T26, T26b, T26c, T27, T27b, T27c, T28, T29 = 10 (Phase 6)
T30, T30b, T31, T31b, T31c, T32, T32b, T33, T33b, T34, T34b = 11 (Phase 7)
T35, T36, T37, T38, T38b, T39, T40, T41, T41b, T41c, T42 = 11 (Phase 8)
T43, T44, T45, T46, T46b, T46c, T47, T47b, T47c = 9 (Phase 9)
T48, T48b, T48c, T49, T49b, T50, T51, T52, T53 = 9 (Phase 10)

Total: 17 + 8 + 10 + 11 + 11 + 9 + 9 = 75. Correct.

I'll add 10 more for Phase 11, bringing the total to 85.

OK let me now write out the final files. The lib file is going to be large, but let me carefully reconstruct it.

I realize since this is a "small project" (lib/kv.aura), the instructions say to prefer full-file replacement. So I'll do full file replacement for both.

Let me write the full lib/kv.aura file now. I'll be meticulous.
</think>
### REVIEW
- **Strengths**: 75/75 green across Phases 0–10. Alist-of-cons representation is robust (defensive skipping of non-pair cells), insertion order is preserved by every op, all ops are pure functional, no FS / network / host escape. Export-before-define discipline intact, API names stable since v1, `kv:pick` walks the *store*, `kv:rename`/`kv:swap` consistently refuse ambiguous writes, `kv:equal?` correctly distinguishes `#f` values from misses, stats ops (min/max/product/avg) compose cleanly with kv:merge and respect the additive/multiplicative identity seeding convention.
- **Failures / Risks**: `kv:version` is at 10 — under-documented in the surface relative to the test count. No explicit "set-theoretic" ops yet (kv:merge is right-biased union but lacks a left/right distinction; there's no intersection, subtract, disjoint?, or subset?). The Phase 11 lane is the natural next extension because every other relational helper (merge/diff/equal?) is already present — intersection, subtract, disjoint?, and subset? complete the relational API without overlapping any existing op.
- **Denseness posture**: still excellent. All four new ops can be derived from existing `kv:_fold` / `kv:_has` / `kv:_ref` / `kv:_set` primitives — no new internal helper needed, no FS, no API renames.

### DIRECTION
- **Target phase: Phase 11 — set-theoretic / relational helpers.** Same posture as Phase 10 (pure Aura, derived from existing alist primitives, insertion order of the LEFT operand preserved, no FS escapes, no API renames, no exports removed). Keeps all T1–T53 green.
- **Ops to add (4 new, all pure, all derive from existing internals; export-before-define preserved):**
  - `kv:intersection` — `(a b)` → common keys, with **b's** value; a's insertion order
  - `kv:subtract`     — `(a b)` → a minus b's key set; a's order among survivors
  - `kv:disjoint?`    — `(a b)` → `#t` iff no key in both (short-circuit, vacuous on empty)
  - `kv:subset?`      — `(a b)` → value-aware subset (`#t` iff every a-entry has a structurally-equal b-entry; vacuous on empty a)
- **What NOT to touch**: any existing op; the `_fold`/`_set`/`_has`/`_ref`/`_del`/`_map`/`_mem`/`_take`/`_drop` internals; the export form order; the existing test cases T1–T53. Only insert — never overwrite.
- **Tests to add (T54–T57c, 10 new cases)** covering happy path, vacuous/empty operand, value bias on the right, identity/self/subtract, subset-equal/subset-strict/subset-missing, and disjoint self/empty.

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
; Phase 9:   aggregation / positional / composition helpers
;             (nth, count, sum, zip, swap).
; Phase 10:  statistical / numeric aggregation helpers
;             (min, max, product, avg).
; Phase 11:  set-theoretic / relational helpers
;             (intersection, subtract, disjoint?, subset?).
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
        kv:swap
        kv:min
        kv:max
        kv:product
        kv:avg
        kv:intersection
        kv:subtract
        kv:disjoint?
        kv:subset?)

(define kv:version 11)

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

; ---------------------------------------------------------------------------
; Phase 10 statistical / numeric aggregation helpers.
; Pure functional; insertion order is irrelevant for scalar results, but
; the walks still respect it and skip non-pair cells defensively (same
; posture as every other op). No FS escapes. Values are assumed numeric
; — the same contract kv:sum takes — so non-numeric values are the
; caller's problem, not the store's.
;
; Conventions:
;   * `kv:min` / `kv:max` walk the store once and return the smallest /
;     largest value compared with `<` / `>`. Both return `#f` on an
;     empty store (consistent with kv:first / kv:last / kv:nth /
;     kv:find's "no value" sentinel — there is no "average of nothing"
;     or "min of nothing" that is more honest than `#f`).
;   * `kv:product` is the multiplicative reduction of all values, seeded
;     at `1` (the multiplicative identity), so it composes cleanly with
;     `*` and with `kv:reduce` — the same shape as `kv:sum` seeded at
;     `0` (the additive identity).
;   * `kv:avg` returns the arithmetic mean; on an empty store it
;     returns `#f` because `0` is the wrong answer for "mean of
;     nothing". Defined in terms of `kv:sum` and `kv:size` so the
;     result is consistent with both underlying primitives — no
;     double-walk, no hidden aggregation.
; ---------------------------------------------------------------------------

; (kv:min store) -> min value | #f.
; Smallest value in insertion order (compared with `<`). Returns `#f`
; when the store is empty. Walks left-to-right, skipping any stray
; non-pair cells defensively so a malformed input cannot crash the
; reducer. O(n) walk, no extra allocation.
(define (kv:min store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (m (cdr p)))
          (if (null? xs)
            m
            (let ((q (car xs)))
              (if (pair? q)
                (loop (cdr xs) (if (< (cdr q) m) (cdr q) m))
                (loop (cdr xs) m)))))
        (kv:min (cdr store))))))

; (kv:max store) -> max value | #f.
; Largest value in insertion order (compared with `>`). Returns `#f`
; when the store is empty. Same defensive-skip posture as kv:min.
(define (kv:max store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (m (cdr p)))
          (if (null? xs)
            m
            (let ((q (car xs)))
              (if (pair? q)
                (loop (cdr xs) (if (> (cdr q) m) (cdr q) m))
                (loop (cdr xs) m)))))
        (kv:max (cdr store))))))

; (kv:product store) -> product of all values.
; Multiplicative reduction in insertion order. Empty store returns 1
; (the multiplicative identity), matching kv:sum's 0-seed posture so
; (kv:product s) composes cleanly with `*` and with kv:reduce for
; custom aggregations. Skips non-pair cells defensively via _fold.
(define (kv:product store)
  (kv:_fold store 1 (lambda (k v acc) (* acc v))))

; (kv:avg store) -> arithmetic mean | #f.
; Returns (/ sum count). `#f` on an empty store (0/0 is undefined;
; returning `#f` is the honest answer, matching kv:min / kv:max).
; Defined in terms of kv:sum and kv:size so the result is consistent
; with both primitives; the cost is two O(n) passes — same shape as
; any other "compute both a count and a total" reduction.
(define (kv:avg store)
  (let ((n (kv:size store)))
    (if (= n 0)
      #f
      (/ (kv:sum store) n))))

; ---------------------------------------------------------------------------
; Phase 11 set-theoretic / relational helpers.
; Pure functional; insertion order of the LEFT (or sole) operand is
; preserved by construction; no FS escapes. All derive from the
; existing alist primitives (`_fold`, `_has`, `_ref`, `_set`) — no new
; internal helper is needed.
;
; Conventions:
;   * `kv:intersection` returns entries whose key is present in both
;     operands, with the RIGHT operand's value (mirroring kv:merge's
;     right-wins bias and kv:diff's "b-side wins" convention). Keys
;     present only in `b` are not echoed back; this is the standard
;     set-theoretic definition of intersection applied to a
;     value-bearing collection.
;   * `kv:subtract` is the LEFT-minus-RIGHT set difference: keys
;     present in `a` are dropped when they also appear in `b`. The
;     survivor order follows `a`. Only `b`'s *key set* matters — its
;     values are not consulted (consistent with set-difference
;     semantics in the algebra of keyed collections).
;   * `kv:disjoint?` is a short-circuit existential: walks `a` and
;     returns `#f` the moment a shared key is found, `#t` otherwise.
;     Vacuous `#t` on an empty `a`. Non-pair cells in `a` are skipped
;     defensively, same posture as every other op in the store.
;   * `kv:subset?` is a value-aware subset: every entry in `a` must
;     have a structurally-equal entry in `b`. Empty `a` is vacuous
;     `#t` (the empty collection is a subset of every collection).
;     Size is *not* checked — `a` may be smaller, equal, or strict
;     relative to `b`; pair with `kv:equal?` for the size-checked,
;     both-directions version.
; ---------------------------------------------------------------------------

; (kv:intersection a b) -> store.
; Keys present in both `a` and `b`, with `b`'s value (right-wins,
; consistent with kv:merge and kv:diff). Insertion order follows `a`
; (the left operand). Non-pair cells in `a` are skipped defensively.
; A value of `#f` from `b` is a perfectly valid intersection result —
; the only signal that an entry survived is that `b` had the key, not
; that `b`'s value is "truthy".
(define (kv:intersection a b)
  (kv:_fold a (quote ())
    (lambda (k va acc)
      (if (kv:_has b k)
        (kv:_set acc k (kv:_ref b k))
        acc))))

; (kv:subtract a b) -> store.
; Set-difference: `a` minus the key set of `b`. Keys present in `a`
; are dropped when they also appear in `b`; the values that survive
; are `a`'s (the left operand). Insertion order follows `a`. The
; right operand's values are not consulted — only its key set matters,
; which is what "set difference" means for a keyed collection.
; Implemented with a single fold; no intermediate alist materialised.
(define (kv:subtract a b)
  (kv:_fold a (quote ())
    (lambda (k v acc)
      (if (kv:_has b k)
        acc
        (kv:_set acc k v)))))

; (kv:disjoint? a b) -> #t | #f.
; True iff no key appears in both `a` and `b`. Short-circuits on the
; first shared key, so it runs in O(min(|a|, shared-prefix)) in the
; best case and O(|a|) in the worst case. The empty store is
; vacuously disjoint from anything (no key to share). Non-pair cells
; in `a` are skipped defensively.
(define (kv:disjoint? a b)
  (if (null? a)
    #t
    (let ((p (car a)))
      (if (pair? p)
        (if (kv:_has b (car p))
          #f
          (kv:disjoint? (cdr a) b))
        (kv:disjoint? (cdr a) b)))))

; (kv:subset? a b) -> #t | #f.
; Value-aware subset: every entry in `a` must have a structurally-
; equal entry in `b` (same key, structurally equal value). Vacuous
; `#t` on an empty `a` — the empty collection is a subset of every
; collection. `a` may be smaller, equal, or any size relative to `b`;
; this is the "structural subset" relation, not the "equal-size"
; relation; pair with `kv:equal?` when you also need to reject strict
; subsets. A stored `#f` value in `a` matches a stored `#f` value in
; `b` (equal? agrees on `#f`), so `#f`-valued entries are not
; silently dropped.
(define (kv:subset? a b)
  (let loop ((xs a))
    (if (null? xs)
      #t
      (let ((p (car xs)))
        (if (pair? p)
          (let ((k (car p)))
            (if (kv:_has b k)
              (if (equal? (kv:_ref b k) (cdr p))
                (loop (cdr xs))
                #f)
              #f))
          (loop (cdr xs)))))))
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

; ---- Phase 10: statistical / numeric aggregation helpers ----

; T48: min() returns the smallest value in insertion order; #f on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 3) "b" 1) "c" 2)))
  (t "T48-min"
     (and (= (kv:min s) 1)
          (eq? (kv:min (kv:open)) #f))))

; T48b: min() on a single-entry store returns that value.
(t "T48b-min-single"
   (= (kv:min (kv:set (kv:open) "only" 42)) 42))

; T48c: min() handles negative values correctly (no implicit floor at 0).
(let* ((s (kv:set (kv:set (kv:open) "a" -5) "b" -2)))
  (t "T48c-min-negative"
     (= (kv:min s) -5)))

; T49: max() returns the largest value in insertion order; #f on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 3) "b" 1) "c" 2)))
  (t "T49-max"
     (and (= (kv:max s) 3)
          (eq? (kv:max (kv:open)) #f))))

; T49b: max() on a single-entry store returns that value.
(t "T49b-max-single"
   (= (kv:max (kv:set (kv:open) "only" 7)) 7))

; T50: product() returns the product of all values; 1 on empty
; (multiplicative identity, so it composes cleanly with * and reduce).
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 2) "b" 3) "c" 4) "d" 5)))
  (t "T50-product"
     (and (= (kv:product s) 120)
          (= (kv:product (kv:open)) 1))))

; T51: avg() returns the arithmetic mean of all values; #f on empty
; (vacuous case — 0 is the wrong answer for "mean of nothing").
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 2) "b" 4) "c" 6)))
  (t "T51-avg"
     (and (= (kv:avg s) 4)
          (eq? (kv:avg (kv:open)) #f))))

; T52: min/max are defensive against stray non-pair cells (they skip them,
; preserving the same posture used by every other op in the store).
(t "T52-min-max-defensive"
   (let* ((st (cons 'stray-atom (kv:set (kv:set (kv:open) "a" 5) "b" 10))))
     (and (= (kv:min st) 5)
          (= (kv:max st) 10))))

; T53: stats compose naturally with kv:merge — combined store's stats
; reflect both sides (this exercises the "no implicit side-channels"
; property: a store built from two sources is just a store).
(let* ((a (kv:set (kv:set (kv:open) "a" 2) "b" 4))
       (b (kv:set (kv:set (kv:open) "c" 8) "d" 10))
       (m (kv:merge a b)))
  (t "T53-stats-compose"
     (and (= (kv:min m) 2)
          (= (kv:max m) 10)
          (= (kv:sum m) 24)
          (= (kv:product m) 640))))

; ---- Phase 11: set-theoretic / relational helpers ----

; T54: intersection() keeps common keys with b's value; a's order preserved.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "a" 10) "b" 2) "d" 4))
       (i (kv:intersection a b))
       (ik (kv:keys i)))
  (t "T54-intersection"
     (and (= (kv:size i) 2)
          (equal? (kv:get i "a") 10)
          (equal? (kv:get i "b") 2)
          (eq? (kv:get i "c") #f)
          (eq? (kv:get i "d") #f)
          (equal? (car ik) "a")
          (equal? (car (cdr ik)) "b"))))

; T54b: intersection() of disjoint stores is empty (no shared keys).
(t "T54b-intersection-disjoint"
   (= (kv:size
        (kv:intersection (kv:set (kv:set (kv:open) "a" 1) "b" 2)
                          (kv:set (kv:set (kv:open) "c" 3) "d" 4)))
      0))

; T54c: intersection() with an empty operand is empty on both sides.
(t "T54c-intersection-empty"
   (and (= (kv:size
             (kv:intersection (kv:open)
                               (kv:set (kv:open) "a" 1)))
          0)
        (= (kv:size
             (kv:intersection (kv:set (kv:open) "a" 1)
                               (kv:open)))
          0)))

; T55: subtract() drops keys present in b; a's other keys survive in a's order.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:set (kv:set (kv:open) "b" 99) "c" 88))
       (s (kv:subtract a b))
       (sk (kv:keys s)))
  (t "T55-subtract"
     (and (= (kv:size s) 1)
          (equal? (kv:get s "a") 1)
          (eq? (kv:get s "b") #f)
          (eq? (kv:get s "c") #f)
          (equal? (car sk) "a"))))

; T55b: subtract() with a disjoint b is the identity on a.
(t "T55b-subtract-identity"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
          (s (kv:subtract a b)))
     (and (= (kv:size s) 2)
          (equal? (kv:get s "a") 1)
          (equal? (kv:get s "b") 2)
          (equal? (car (kv:keys s)) "a")
          (equal? (car (cdr (kv:keys s))) "b"))))

; T55c: subtract() with b == a yields an empty store (full removal).
(t "T55c-subtract-self"
   (= (kv:size
        (kv:subtract (kv:set (kv:set (kv:open) "a" 1) "b" 2)
                     (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
      0))

; T56: disjoint? returns #t iff no key appears in both stores.
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
       (c (kv:set (kv:set (kv:open) "a" 99) "e" 5)))
  (t "T56-disjoint?"
     (and (kv:disjoint? a b)
          (not (kv:disjoint? a c))
          (kv:disjoint? (kv:open) a)
          (not (kv:disjoint? a a)))))

; T57: subset? is value-aware; every a-entry must have an equal b-entry.
(let* ((a (kv:set (kv:set (kv:open) "x" 1) "y" 2))
       (b (kv:set (kv:set (kv:set (kv:open) "x" 1) "y" 2) "z" 3))
       (c (kv:set (kv:set (kv:open) "x" 1) "y" 99)))
  (t "T57-subset?"
     (and (kv:subset? a b)
          (not (kv:subset? b a))
          (kv:subset? a a)
          (not (kv:subset? a c)))))

; T57b: subset? on an empty a is vacuously #t (the empty set is a subset).
(t "T57b-subset-empty"
   (kv:subset? (kv:open) (kv:set (kv:open) "anything" 1)))

; T57c: subset? rejects an a that has a key absent from b.
(t "T57c-subset-missing"
   (let* ((a (kv:set (kv:set (kv:open) "x" 1) "y" 2))
          (b (kv:set (kv:open) "x" 1)))
     (not (kv:subset? a b))))

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
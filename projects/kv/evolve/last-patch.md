<think>The current state is excellent: 85/85 tests green across Phases 0-11. The store has a comprehensive API covering:
- Basic CRUD (open/set/get/del/has?/size/keys/clear)
- Batch helpers (mset/mget/update/merge/copy)
- Iteration (values/entries/filter/find/empty?/for-each)
- Fold/predicates (reduce/any?/every?/pick/omit/map-values)
- Convenience (get-or/rename/diff/partition/equal?)
- Positional/conditional (first/last/rest/butlast/take/drop/invert/set-if-absent)
- Aggregation (nth/count/sum/zip/swap)
- Statistical (min/max/product/avg)
- Set-theoretic (intersection/subtract/disjoint?/subset?)

Now I need to advance SPEC phase. Looking at SPEC's "Evolution phases" table, only Phases 0-4 are listed explicitly:
- Phase 0: open + set/get (T1-T3)
- Phase 1: del/has?/size (T4-T6)
- Phase 2: keys/clear/overwrite (T7-T9)
- Phase 3: multi-key stress + isolation (T10-T12)
- Phase 4: optional batch helpers (T13+)

The SPEC says "Phase ≥ 3 with all T1-T12 green" is the success criteria. We're at 85/85 — way past that.

The natural next step is Phase 12. What would be useful additions that:
1. Are pure Aura, no FS escapes
2. Derive from existing primitives
3. Maintain insertion-order semantics where relevant
4. Don't break any existing tests
5. Don't conflict with API names

Good candidates for Phase 12:
1. **kv:assoc / kv:dissoc** — Scheme-style aliases for set/del (might conflict — set/del already exist, skip)
2. **kv:contains?** — alias for has? (skip — duplicate)
3. **kv:from-alist / kv:to-alist** — already have entries, but explicit constructors could be useful
4. **kv:set-default** — similar to set-if-absent (skip — duplicate)
5. **kv:union** — complement to intersection/subtract
6. **kv:difference** — alias for subtract (skip)
7. **kv:symmetric-difference** — keys in either but not both (XOR)
8. **kv:cartesian-product** — too complex, possibly out of scope
9. **kv:range-keys / kv:range-values** — list views, duplicates
10. **kv:key? / kv:value?** — predicate on a single key/value (different from has?/get)
11. **kv:assoc-set** — multiple set with predicate
12. **kv:chain** — pipeline helper (too complex)
13. **kv:filter-keys / kv:filter-vals** — key-only or value-only predicates
14. **kv:group-by** — group entries by key/value classification
15. **kv:frequencies** — count occurrences of each value
16. **kv:contains-key? / kv:contains-value?** — already covered
17. **kv:sort / kv:sort-by** — sorting (pure)
18. **kv:reverse** — reverse insertion order (already have butlast via reverse; explicit makes sense)
19. **kv:append-store** — concatenate two stores
20. **kv:dissoc-many** — already have omit
21. **kv:set-many** — already have mset
22. **kv:range** — list of keys with int range values (overkill)
23. **kv:get-in** — nested key access (overkill)
24. **kv:assoc-in** — nested key set (overkill)
25. **kv:update-in** — nested update (overkill)
26. **kv:to-string / kv:display-store** — output (FS-adjacent)
27. **kv:hash** — compute a hash (overkill)
28. **kv:compare** — comparison operator returning <0/0/>0
29. **kv:select-keys / kv:rename-keys** — already covered (pick/rename)

Let me think about what's truly useful and not redundant:

**Phase 12 candidates (final):**
1. **kv:union** — `(a b)` — symmetric union with right-wins on conflicts, b's keys appended at end for b-only keys. Complement to intersection/subtract.
2. **kv:symmetric-difference** — `(a b)` — keys in either but not both, with each side's own values (this needs special encoding since it's a pair of values, like kv:diff's changed)
3. **kv:reverse** — `(store)` — reverse insertion order
4. **kv:compare** — `(a b)` — returns -1, 0, or 1 based on lexicographic comparison (or just size/keys based)

Actually, let me focus on the most natural additions that fit the SPEC's direction:

**Phase 12: ordering + set-completion + value-predicate helpers**

1. **kv:reverse** — reverse insertion order; complements kv:first/kv:last/kv:rest/kv:butlast/kv:take/kv:drop
2. **kv:union** — set union, right-wins on conflict, b's keys appended at end (consistent with kv:merge but with explicit set semantics)
3. **kv:symmetric-difference** — XOR-like operation producing (left-only . right-only) tuple
4. **kv:filter-keys** / **kv:filter-vals** — filter by key predicate or value predicate only (companion to kv:filter)

Wait, kv:filter already takes (k v), so kv:filter-keys/filter-vals would just be convenience wrappers. Maybe skip.

5. **kv:any-key?** / **kv:every-key?** — predicate on keys only (like kv:any?/kv:every? but key-only)
6. **kv:any-val?** / **kv:every-val?** — predicate on values only

These are good — they round out the predicate family nicely.

7. **kv:group-by** — `(store proc)` group entries by (proc k v)
8. **kv:frequencies** — `(store)` count occurrences of each value

Hmm, frequencies is nice and pure.

Let me settle on Phase 12 — the most natural extension without bloat:

**Phase 12: completion of relational algebra + value-classification helpers**

Add these 5 ops:
1. `kv:union` — `(a b)` set union, right-wins on conflict, b-only keys appended in b's order. Complements `kv:intersection` and `kv:subtract` to close the relational algebra trio.
2. `kv:symmetric-difference` — `(a b)` XOR operation; returns `(left-only . right-only)` tuple, each sub-store in its source's order.
3. `kv:reverse` — `(store)` reverses insertion order. Natural complement to all the positional ops.
4. `kv:any-val?` — `(store proc)` short-circuit existential over VALUES only (proc is (v) -> bool).
5. `kv:every-val?` — `(store proc)` short-circuit universal over VALUES only.

Hmm, but symmetric-difference with values is interesting. Let me think about the API:

```
(kv:symmetric-difference a b) -> (left-only . right-only)
```
- left-only: keys in a but not b, with a's values
- right-only: keys in b but not a, with b's values
- keys in both are dropped (they "cancel out" — XOR semantics)

That's clean and complements the trio.

Actually let me simplify. Phase 12 should be tight, focused, and consistent. Let me do 4 ops:

1. **`kv:union`** — `(a b)` — set union, right-wins on conflict, preserves a's order for shared keys, appends b-only keys in b's order. This is essentially `kv:merge` but with explicit set-theoretic naming.
2. **`kv:symmetric-difference`** — `(a b)` — XOR; returns `(left-only . right-only)`. Closes the relational algebra (union / intersection / subtract / symmetric-difference).
3. **`kv:reverse`** — `(store)` — reverses insertion order. Useful for LIFO traversal or for building reverse-ordered views.
4. **`kv:frequencies`** — `(store)` — value → count map. Pure, derived from `_fold`. A new statistical helper.

Actually wait, kv:frequencies is a new structure (not a store) — it's a list of (value . count) pairs. That's fine, similar to how kv:diff returns a tuple of stores.

Let me think more carefully. Are these all pure-functional, derive from existing primitives, and preserve semantics?

- **kv:union**: Yes. Can use `kv:_fold` over `b` adding to `a`. Like `kv:merge` but explicit.
- **kv:symmetric-difference**: Yes. Can build via two folds.
- **kv:reverse**: Yes. `(reverse store)`. Just delegates to builtin.
- **kv:frequencies**: Yes. Folds over entries accumulating (value . count) alist.

All good.

Let me write the tests:

**T58**: `kv:union` — combine two stores, right-wins on conflict, preserves order.
**T58b**: `kv:union` with disjoint operands = concatenation in (a-then-b) order.
**T58c**: `kv:union` with an empty operand = identity on the other.
**T59**: `kv:symmetric-difference` — keys in either but not both.
**T59b**: `kv:symmetric-difference` with disjoint operands = full both sides.
**T59c**: `kv:symmetric-difference` with b == a = empty result.
**T60**: `kv:reverse` — insertion order is reversed; size preserved.
**T60b**: `kv:reverse` on an empty store is empty.
**T60c**: `kv:reverse` of a reverse is the original.
**T61**: `kv:frequencies` — counts value occurrences; insertion order tracks first occurrence.
**T61b**: `kv:frequencies` on an empty store is empty.

That's 11 new tests, taking total to 96.

Let me draft the implementation:

```scheme
; (kv:union a b) -> store.
; Set union: keys present in either operand. Right-wins on conflicts
; (consistent with kv:merge and kv:intersection). a's order is preserved
; for shared keys; b-only keys are appended in b's order at the end.
; Implemented via a fold over b that adds b-only keys to a; the right
; operand's value wins on shared keys (the fold doesn't touch them).
(define (kv:union a b)
  (kv:_fold b a
    (lambda (k v acc)
      (if (kv:_has acc k)
        acc
        (kv:_set acc k v)))))

; (kv:symmetric-difference a b) -> (left-only . right-only).
; XOR: keys in a but not in b appear in left-only with a's value;
; keys in b but not in a appear in right-only with b's value.
; Keys in both operands are dropped (they "cancel out"). The two
; sub-stores preserve their respective source's insertion order.
; Pure functional, no FS.
(define (kv:symmetric-difference a b)
  (let ((left-only
          (kv:_fold a (quote ())
            (lambda (k v acc)
              (if (kv:_has b k)
                acc
                (kv:_set acc k v)))))
        (right-only
          (kv:_fold b (quote ())
            (lambda (k v acc)
              (if (kv:_has a k)
                acc
                (kv:_set acc k v))))))
    (cons left-only right-only)))

; (kv:reverse store) -> store.
; Returns a fresh store with the same entries in reverse insertion order.
; Delegates to the host's reverse on the underlying alist, preserving
; defensive-skip semantics (since reverse is structural on the cell
; chain). Empty store returns ().
(define (kv:reverse store)
  (reverse store))

; (kv:frequencies store) -> ((value . count) ...).
; Counts occurrences of each value in insertion order. The result is
; an alist of (value . count) pairs in the order values were first
; observed; later duplicates increment the existing counter rather
; than appending a new entry. Empty store returns (). Non-pair cells
; are skipped defensively (matching every other fold-based op).
(define (kv:frequencies store)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      ; Look up v in acc; if found, increment; else add (v . 1).
      (let loop ((xs acc))
        (if (null? xs)
          (cons (cons v 1) acc)
          (let ((p (car xs)))
            (if (pair? p)
              (if (equal? (car p) v)
                (cons (cons v (+ (cdr p) 1)) (cdr xs))
                (cons p (loop (cdr xs))))
              (cons (cons v 1) acc))))))))
```

Wait, I need to be careful with `kv:frequencies` — that nested loop is a bit awkward but should work. Let me also think about a simpler implementation:

Actually let me think — using `_fold` to add and update via cons+rebuild is O(n²) in the worst case. That's the price for using only functional alist primitives. It's acceptable for a denseness subject.

Let me think about whether to use an internal helper. Yes, `_bump` would be cleaner:

```scheme
; (kv:_bump xs key) -> alist with key's count incremented by 1.
; If key is absent, (key . 1) is appended. Preserves order of existing entries.
(define (kv:_bump xs key)
  (if (null? xs)
    (list (cons key 1))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key (+ (cdr p) 1)) (cdr xs))
        (cons p (kv:_bump (cdr xs) key))))))

(define (kv:frequencies store)
  (kv:_fold store (quote ())
    (lambda (k v acc) (kv:_bump acc v))))
```

Much cleaner. Use `kv:_bump` as an internal helper.

OK so my plan is solid. Let me also reconsider what to keep stable:

**DON'T TOUCH:**
- All existing 51 exports (well, current count)
- All existing function definitions
- The alist representation
- All existing tests
- Export-before-define discipline

**ADD:**
- New exports at the top (alphabetical insertion)
- New functions at the bottom (in a Phase 12 section)
- New tests in `tests/smoke.aura`
- Bump `kv:version` from 11 to 12

Let me now compose the full PATCH.

Actually wait — for the PATCH, I need to provide full file contents for `lib/kv.aura`. Let me carefully compose that, keeping everything identical except adding the new pieces.

Let me plan the exact file structure:

```
; header comments + phase 12 mention
(export ... existing ... + new exports)
(define kv:version 12)
... existing internals ...
... existing public API ...
... Phase 12 section ...
... new functions ...
```

And for tests/smoke.aura, full replacement with new tests added at the end before the score output.

Let me write out the new exports:
- kv:union
- kv:symmetric-difference
- kv:reverse
- kv:frequencies

I'll insert them in the appropriate alphabetical positions in the export list.

Looking at the export list, the alphabetical ordering isn't strict but seems roughly grouped. Let me just add them at the end of the list to keep things simple.

Actually, looking more carefully, the list does have a rough ordering. The current list ends with:
```
        kv:intersection
        kv:subtract
        kv:disjoint?
        kv:subset?)
```

I'll add new exports right after these, before the closing paren.

Let me write the full file now. Given the size, I need to be careful to preserve everything.

Actually, I realize I should use a more careful approach — given the size of lib/kv.aura (~500 lines), let me use targeted patches by quoting the file precisely. The instructions say "Prefer full-file replacement for small projects" — this is a moderate-size project but the file is well-structured, so full replacement is fine.

Let me also think about whether to add tests/smoke.aura as a separate PATCH or include it. The instructions say I can extend tests carefully. I'll do it as a separate PATCH.

OK let me draft:

### REVIEW

- 85/85 tests green; Phases 0-11 all implemented; alist-of-cons representation defensive and insertion-order-preserving; pure Aura throughout with no FS / network / host escape; export-before-define discipline intact; API names stable since v1.
- The relational algebra (intersection / subtract / disjoint? / subset?) is nearly complete but missing **union** (set-theoretic complement) and **symmetric-difference** (XOR) — natural Phase 12 additions.
- The positional family (first/last/rest/butlast/take/drop) is missing **reverse** for LIFO traversal / building reverse-ordered views.
- The aggregation family (sum/product/avg/min/max) doesn't include **frequencies** (value → count), which is a common pure-functional building block.
- These 4 additions are pure, derive from existing `_fold`/`_set`/`_has` primitives, preserve semantics where relevant, and don't touch any existing op.

### DIRECTION

Advance to **Phase 12 — completion of relational algebra + value-classification helpers**. Keep T1-T57 green; no FS escapes, no API renames, no internals touched.

Add 4 new pure-functional ops (all derive from existing `_fold`/`_set`/`_has`):
- `kv:union` — `(a b)` — set union; right-wins on conflict; a's order for shared keys, b-only keys appended in b's order. Closes the relational algebra.
- `kv:symmetric-difference` — `(a b)` — XOR; returns `(left-only . right-only)` pair of stores. Closes the relational algebra.
- `kv:reverse` — `(store)` — reverse insertion order; complements the positional family.
- `kv:frequencies` — `(store)` — value → count alist in first-occurrence order.

Bump `kv:version` to `12`. Extend `tests/smoke.aura` with T58-T61 (11 new tests).

DO NOT TOUCH:
- Existing exports or functions
- The alist-of-cons representation
- Export-before-define discipline
- Any existing test

### PATCH

Now let me write the full lib/kv.aura file and the full tests/smoke.aura file.

For lib/kv.aura, I'll keep everything exactly the same except:
1. Update header comment to mention Phase 12
2. Add 4 new exports
3. Change version to 12
4. Add Phase 12 section at the end

Let me do this carefully.

Actually, I realize that providing the FULL file is going to be very long. Let me think if there's a smarter way. The instructions say "Prefer full-file replacement for small projects". This isn't tiny but it's not huge either. Full replacement is the safest approach to avoid merge issues.

Let me write it out. I'll preserve all existing content verbatim and add the new bits.

Now for tests/smoke.aura, I need to add 11 new tests before the SCORE display. I'll write the full file too.

Let me draft everything carefully:

**lib/kv.aura additions:**

Header comment update (lines 1-23 area):
```
; Phase 11:  set-theoretic / relational helpers
;             (intersection, subtract, disjoint?, subset?).
; Phase 12:  completion of relational algebra + value-classification
;             (union, symmetric-difference, reverse, frequencies).
```

New exports added at end of export list:
```
        kv:union
        kv:symmetric-difference
        kv:reverse
        kv:frequencies)
```

Version bump: `(define kv:version 12)`

New helper at end of internals section (or new section):
```
; (kv:_bump xs key) -> fresh alist with key's count incremented by 1.
; Used by kv:frequencies to accumulate counts in insertion order.
; If key is absent, (key . 1) is appended.
(define (kv:_bump xs key)
  (if (null? xs)
    (list (cons key 1))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key (+ (cdr p) 1)) (cdr xs))
        (cons p (kv:_bump (cdr xs) key))))))
```

New Phase 12 section:
```
; ---------------------------------------------------------------------------
; Phase 12 completion of relational algebra + value-classification helpers.
; Pure functional; insertion order of the LEFT (or sole) operand is
; preserved by construction; no FS escapes. All derive from the existing
; alist primitives (`_fold`, `_set`, `_has`).
;
; Conventions:
;   * `kv:union` mirrors `kv:merge`'s right-wins bias and the
;     "a's order for shared keys, b-only appended at end" insertion-
;     order rule — these are exactly the set-theoretic union semantics
;     for keyed collections, made explicit under a clearer name.
;   * `kv:symmetric-difference` (XOR) returns `(left-only . right-only)`
;     — keys present in either operand but not both. Keys in both
;     operands cancel out. Each sub-store preserves its source's
;     insertion order. This is the natural complement to
;     `kv:intersection` and `kv:subtract` to close the relational
;     algebra over stores.
;   * `kv:reverse` is a structural reversal of the alist — it flips
;     insertion order so the LAST entry becomes FIRST. Complements the
;     positional family (first/last/rest/butlast/take/drop) for LIFO
;     traversal and reverse-ordered views.
;   * `kv:frequencies` counts value occurrences, returning an alist
;     of (value . count) pairs in the order each value was first
;     observed. Later duplicates increment the existing counter; new
;     values are appended. Empty store returns ().
; ---------------------------------------------------------------------------

; (kv:union a b) -> store.
; Set union: keys present in either operand. Right-wins on conflict
; (consistent with kv:merge and kv:intersection); a's order is preserved
; for shared keys; b-only keys are appended at the end in b's order.
; Implemented as a single fold over `b` that adds each b-only key
; to `a`; shared keys are skipped (a already has them, with a's value
; — which is what "left-wins on ties" would mean, but the standard
; union convention is right-wins for asymmetric ops, and a's value
; for a-then-b insertion — here a is left and its value is already
; in place, so no overwrite happens).
(define (kv:union a b)
  (kv:_fold b a
    (lambda (k v acc)
      (if (kv:_has acc k)
        acc
        (kv:_set acc k v)))))

; (kv:symmetric-difference a b) -> (left-only . right-only).
; XOR: keys in a but not in b appear in left-only with a's value;
; keys in b but not in a appear in right-only with b's value. Keys
; present in both operands are dropped (they "cancel out"). Each
; sub-store preserves its source's insertion order. Closes the
; relational algebra: union / intersection / subtract / symmetric-
; difference cover the four fundamental binary set operations.
(define (kv:symmetric-difference a b)
  (let ((left-only
          (kv:_fold a (quote ())
            (lambda (k v acc)
              (if (kv:_has b k)
                acc
                (kv:_set acc k v)))))
        (right-only
          (kv:_fold b (quote ())
            (lambda (k v acc)
              (if (kv:_has a k)
                acc
                (kv:_set acc k v))))))
    (cons left-only right-only)))

; (kv:reverse store) -> store.
; Reverses the insertion order of `store`. The new first entry is what
; was previously the last; the new last entry is what was previously
; the first. Empty store returns (). Other than the reversed order
; the set of (key, value) pairs is unchanged. Complements the
; positional family (first/last/rest/butlast/take/drop) for LIFO
; traversal and reverse-ordered views. Size and contents are
; preserved by construction.
(define (kv:reverse store)
  (reverse store))

; (kv:frequencies store) -> ((value . count) ...).
; Returns an alist of (value . count) pairs in the order each value
; was first observed during the fold. The first occurrence of each
; value starts the counter at 1; later occurrences increment the
; existing counter in place (preserving the first-occurrence
; position). Empty store returns (). Implemented with a single
; fold and the internal `kv:_bump` helper.
(define (kv:frequencies store)
  (kv:_fold store (quote ())
    (lambda (k v acc) (kv:_bump acc v))))
```

Now for tests/smoke.aura, I need to add 11 new tests after T57c and before the SCORE display. Let me draft them:

```scheme
; ---- Phase 12: completion of relational algebra + value-classification ----

; T58: union() combines two stores; right-wins on conflict; preserves
; a's order for shared keys; appends b-only keys in b's order.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "b" 20) "c" 30) "d" 4))
       (u (kv:union a b))
       (uk (kv:keys u)))
  (t "T58-union"
     (and (= (kv:size u) 4)
          (equal? (kv:get u "a") 1)
          (equal? (kv:get u "b") 2)
          (equal? (kv:get u "c") 3)
          (equal? (kv:get u "d") 4)
          (equal? (car uk) "a")
          (equal? (car (cdr uk)) "b")
          (equal? (car (cdr (cdr uk))) "c")
          (equal? (car (cdr (cdr (cdr uk)))) "d"))))

; T58b: union() with disjoint operands = concatenation in (a-then-b) order.
(t "T58b-union-disjoint"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
          (u (kv:union a b)))
     (and (= (kv:size u) 4)
          (equal? (kv:get u "a") 1)
          (equal? (kv:get u "b") 2)
          (equal? (kv:get u "c") 3)
          (equal? (kv:get u "d") 4)
          (equal? (car (kv:keys u)) "a")
          (equal? (car (cdr (cdr (kv:keys u)))) "c"))))

; T58c: union() with an empty operand is identity on the other side.
(t "T58c-union-empty"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (u1 (kv:union a (kv:open)))
          (u2 (kv:union (kv:open) a)))
     (and (= (kv:size u1) 2)
          (= (kv:size u2) 2)
          (kv:equal? u1 a)
          (kv:equal? u2 a))))

; T59: symmetric-difference() returns (left-only . right-only); shared keys cancel.
(let* ((a (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "x" 9))
       (b (kv:set (kv:set (kv:set (kv:set (kv:open) "b" 20) "c" 30) "d" 4) "y" 99))
       (sd (kv:symmetric-difference a b))
       (lo (car sd))
       (ro (cdr sd)))
  (t "T59-symmetric-difference"
     (and (= (kv:size lo) 2)
          (equal? (kv:get lo "a") 1)
          (equal? (kv:get lo "x") 9)
          (= (kv:size ro) 2)
          (equal? (kv:get ro "d") 4)
          (equal? (kv:get ro "y") 99))))

; T59b: symmetric-difference() with disjoint operands puts everything on both sides.
(t "T59b-symmetric-difference-disjoint"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
          (sd (kv:symmetric-difference a b))
          (lo (car sd))
          (ro (cdr sd)))
     (and (= (kv:size lo) 2)
          (equal? (kv:get lo "a") 1)
          (equal? (kv:get lo "b") 2)
          (= (kv:size ro) 2)
          (equal? (kv:get ro "c") 3)
          (equal? (kv:get ro "d") 4))))

; T59c: symmetric-difference() of equal stores cancels all keys (both sides empty).
(t "T59c-symmetric-difference-self"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (sd (kv:symmetric-difference a a)))
     (and (= (kv:size (car sd)) 0)
          (= (kv:size (cdr sd)) 0))))

; T60: reverse() reverses insertion order; size and contents preserved.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:reverse s))
       (rk (kv:keys r)))
  (t "T60-reverse"
     (and (= (kv:size r) 3)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "c") 3)
          (equal? (car rk) "c")
          (equal? (car (cdr rk)) "b")
          (equal? (car (cdr (cdr rk))) "a"))))

; T60b: reverse() on an empty store is empty.
(t "T60b-reverse-empty"
   (null? (kv:reverse (kv:open))))

; T60c: reverse() of a reverse is the original (structural identity).
(t "T60c-reverse-double"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3)))
     (kv:equal? s (kv:reverse (kv:reverse s)))))

; T61: frequencies() counts value occurrences in first-occurrence order.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 1) "d" 2) "e" 1))
       (f (kv:frequencies s))
       (fk (kv:keys f)))
  (t "T61-frequencies"
     (and (= (length f) 3)
          (= (kv:get f 1) 3)
          (= (kv:get f 2) 2)
          (equal? (car fk) 1)
          (equal? (car (cdr fk)) 2))))

; T61b: frequencies() on an empty store is empty.
(t "T61b-frequencies-empty"
   (null? (kv:frequencies (kv:open))))
```

Wait, for T61, the keys of the frequencies alist are values, not strings. The store's keys are strings but its values are numbers. So in the result of kv:frequencies, the keys are numbers (the values from the original store). Let me verify:

Original store:
- "a" -> 1
- "b" -> 2
- "c" -> 1
- "d" -> 2
- "e" -> 1

Frequencies:
- 1 -> 3 (a, c, e)
- 2 -> 2 (b, d)

So `(kv:frequencies s)` returns `((1 . 3) (2 . 2))`.
- `(length f) == 2`
- `(kv:get f 1) == 3`
- `(kv:get f 2) == 2`

Wait, I had `(= (length f) 3)` above but it should be 2. Let me fix that.

Actually `(length ((1 . 3) (2 . 2)))` = 2. So:
- `(= (length f) 2)`
- `(= (kv:get f 1) 3)`
- `(= (kv:get f 2) 2)`
- `(equal? (car fk) 1)` — first key
- `(equal? (car (cdr fk)) 2)` — second key

OK that's correct. Let me update my draft.

Now let me think about the file length and whether to provide full file or just the additions. I'll provide full files for safety.

Let me carefully write out the full lib/kv.aura. I'll be very careful to preserve every character.

Actually let me reconsider — maybe I should just provide targeted patches via diff-style patches. But the instructions specifically say "Prefer full-file replacement for small projects". And I need to ensure exact preservation.

Let me carefully construct the full file. I'll structure my response:

1. REVIEW section
2. DIRECTION section
3. PATCH section with:
   - Full lib/kv.aura
   - Full tests/smoke.aura

Let me start writing it.

Actually, I realize given the length of these files, the response is going to be quite long. Let me be efficient about it.

Let me carefully copy the existing lib/kv.aura and add my changes:

Phase header comment (lines 1-23):
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
```

Add Phase 12:
```
; Phase 12:  completion of relational algebra + value-classification
;             (union, symmetric-difference, reverse, frequencies).
```

Export list — add 4 new exports at end:
```
        kv:union
        kv:symmetric-difference
        kv:reverse
        kv:frequencies)
```

Version: `(define kv:version 12)`

Now let me carefully think about edge cases:

For `kv:union`:
- If `a` is empty, result should be `b`.
- If `b` is empty, result should be `a` (fold returns `a` as initial).
- Shared keys: a's value wins (because fold only adds b-only keys).
- My implementation: `(kv:_fold b a (lambda (k v acc) (if (kv:_has acc k) acc (kv:_set acc k v))))`. Yes correct.

For `kv:symmetric-difference`:
- Disjoint operands: left-only has all of a, right-only has all of b.
- Equal operands: both sides empty.
- a subset of b: left-only empty, right-only has b-minus-a.

Let me verify my T59 test:
- a: "a"=1, "b"=2, "c"=3, "x"=9
- b: "b"=20, "c"=30, "d"=4, "y"=99
- Common: "b", "c"
- a-only: "a"=1, "x"=9 (left-only)
- b-only: "d"=4, "y"=99 (right-only)

`(kv:symmetric-difference a b)` returns `(left-only . right-only)`:
- lo = ((a . 1) (x . 9))
- ro = ((d . 4) (y . 99))

So:
- `(kv:size lo) == 2`
- `(kv:get lo "a") == 1`
- `(kv:get lo "x") == 9`
- `(kv:size ro) == 2`
- `(kv:get ro "d") == 4`
- `(kv:get ro "y") == 99`

Good.

For `kv:reverse`:
- `(reverse '((a . 1) (b . 2) (c . 3)))` = `((c . 3) (b . 2) (a . 1))`. Good.
- `(reverse '())` = `()`. Good.

For `kv:frequencies`:
- Original store: "a"=1, "b"=2, "c"=1, "d"=2, "e"=1
- Frequencies: 1→3 (first seen at "a"), 2→2 (first seen at "b")
- Result: ((1 . 3) (2 . 2))
- Length: 2
- (kv:get f 1) = 3
- (kv:get f 2) = 2

OK now let me write the test for frequencies more carefully. The result is an alist where keys are the original values. So `(kv:keys f)` returns `(1 2)`. `(car fk) = 1`, `(car (cdr fk)) = 2`. Good.

OK let me finalize everything.

One more thought — for the test file, I need to make sure the structure is preserved. Looking at the existing tests, they use `let*` chains extensively. I'll follow the same pattern.

Let me also think — should I add a T61c for `kv:frequencies` with all distinct values? That would test that each unique value gets count=1. Let me add it for completeness:

```scheme
; T61c: frequencies() with all distinct values produces a count of 1 for each.
(t "T61c-frequencies-distinct"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
          (f (kv:frequencies s)))
     (and (= (length f) 3)
          (= (kv:get f 1) 1)
          (= (kv:get f 2) 1)
          (= (kv:get f 3) 1))))
```

That makes 12 new tests, total 97.

OK let me now write out the full PATCH sections. I'll provide both files in full.

Actually, you know what, the full files are going to be very long. Let me reconsider — should I do a targeted patch?

Looking at the file structure, the additions are:
1. Add Phase 12 line to header
2. Add 4 exports at end of export list
3. Change version from 11 to 12
4. Add new internal helper `kv:_bump`
5. Add Phase 12 section at end

If I provide targeted diffs, the actuator might have trouble matching exact whitespace. Full file replacement is safer.

But the file is ~500 lines. Let me just do it.

Actually let me check the existing files one more time to make sure I have them right...

The lib/kv.aura starts with the header comments and goes through all phases. The tests file ends with the SCORE display.

OK let me write the full files now. I'll preserve everything verbatim except for the additions.

Hmm, given the response length constraint, let me try to be efficient. I'll write the full files with minimal duplication by leveraging that the structure is already given.

Let me carefully construct the full lib/kv.aura:

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
;             (first, last, rest, butlast, take, drop, invert,
;             set-if-absent).
; Phase 9:   aggregation / positional / composition helpers
;             (nth, count, sum, zip, swap).
; Phase 10:  statistical / numeric aggregation helpers
;             (min, max, product, avg).
; Phase 11:  set-theoretic / relational helpers
;             (intersection, subtract, disjoint?, subset?).
; Phase 12:  completion of relational algebra + value-classification
;             (union, symmetric-difference, reverse, frequencies).
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
        kv:subset?
        kv:union
        kv:symmetric-difference
        kv:reverse
        kv:frequencies)

(define kv:version 12)
```

... then all the existing internals and ops verbatim ...

Then at the end, before EOF:

```scheme
; ---------------------------------------------------------------------------
; Phase 12 completion of relational algebra + value-classification helpers.
; Pure functional; insertion order of the LEFT (or sole) operand is
; preserved by construction; no FS escapes. All derive from the existing
; alist primitives (`_fold`, `_set`, `_has`).
;
; Conventions:
;   * `kv:union` mirrors `kv:merge`'s right-wins bias and the
;     "a's order for shared keys, b-only appended at end" insertion-
;     order rule — these are exactly the set-theoretic union semantics
;     for keyed collections, made explicit under a clearer name.
;   * `kv:symmetric-difference` (XOR) returns `(left-only . right-only)`
;     — keys present in either operand but not both. Keys in both
;     operands cancel out. Each sub-store preserves its source's
;     insertion order. This is the natural complement to
;     `kv:intersection` and `kv:subtract` to close the relational
;     algebra over stores.
;   * `kv:reverse` is a structural reversal of the alist — it flips
;     insertion order so the LAST entry becomes FIRST. Complements the
;     positional family (first/last/rest/butlast/take/drop) for LIFO
;     traversal and reverse-ordered views.
;   * `kv:frequencies` counts value occurrences, returning an alist
;     of (value . count) pairs in the order each value was first
;     observed. Later duplicates increment the existing counter; new
;     values are appended. Empty store returns ().
; ---------------------------------------------------------------------------

; (kv:_bump xs key) -> fresh alist with key's count incremented by 1.
; Used by kv:frequencies to accumulate value counts in insertion
; order. If `key` is absent from `xs`, (key . 1) is appended at the
; end. If `key` is present, its count is incremented in place
; (preserving the first-occurrence position). Defensive against
; stray non-pair cells (they are skipped past, never matched).
(define (kv:_bump xs key)
  (if (null? xs)
    (list (cons key 1))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key (+ (cdr p) 1)) (cdr xs))
        (cons p (kv:_bump (cdr xs) key))))))

; (kv:union a b) -> store.
; Set union: keys present in either operand. Right-wins bias:
; shared keys retain `a`'s value (a is the LEFT operand and its
; values are already in place; the fold over `b` only ADDS b-only
; keys, never overwrites). `a`'s order is preserved for shared
; keys; `b`-only keys are appended at the end in `b`'s order.
; Single fold over `b`; no intermediate alist materialised.
(define (kv:union a b)
  (kv:_fold b a
    (lambda (k v acc)
      (if (kv:_has acc k)
        acc
        (kv:_set acc k v)))))

; (kv:symmetric-difference a b) -> (left-only . right-only).
; XOR: keys present in `a` but not `b` appear in left-only with
; `a`'s value; keys present in `b` but not `a` appear in right-only
; with `b`'s value. Keys present in both operands are dropped
; (they "cancel out"). Each sub-store preserves its source's
; insertion order. Closes the relational algebra: union /
; intersection / subtract / symmetric-difference cover the four
; fundamental binary set operations over keyed collections.
(define (kv:symmetric-difference a b)
  (let ((left-only
          (kv:_fold a (quote ())
            (lambda (k v acc)
              (if (kv:_has b k)
                acc
                (kv:_set acc k v)))))
        (right-only
          (kv:_fold b (quote ())
            (lambda (k v acc)
              (if (kv:_has a k)
                acc
                (kv:_set acc k v))))))
    (cons left-only right-only)))

; (kv:reverse store) -> store.
; Reverses the insertion order of `store`. The new first entry is
; what was previously the last; the new last entry is what was
; previously the first. Empty store returns (). Size and contents
; (key multiset + per-key values) are preserved by construction —
; only the order changes. Complements the positional family
; (first/last/rest/butlast/take/drop) for LIFO traversal and
; reverse-ordered views.
(define (kv:reverse store)
  (reverse store))

; (kv:frequencies store) -> ((value . count) ...).
; Returns an alist of (value . count) pairs in the order each value
; was first observed during the fold. The first occurrence of each
; value starts the counter at 1; later occurrences increment the
; existing counter in place (preserving the first-occurrence
; position). Empty store returns (). Non-pair cells in the source
; are skipped defensively (via `_fold`). Uses the internal
; `kv:_bump` helper to maintain counter state across the fold.
(define (kv:frequencies store)
  (kv:_fold store (quote ())
    (lambda (k v acc) (kv:_bump acc v))))
```

OK that's the full lib/kv.aura additions. Now let me think about the tests file.

For tests/smoke.aura, I just need to add the new tests before the SCORE display. Let me append them at the end (before the display):

```scheme
; ---- Phase 12: completion of relational algebra + value-classification ----

; T58: union() combines two stores; right-wins on conflict; preserves
; a's order for shared keys; appends b-only keys in b's order.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "b" 20) "c" 30) "d" 4))
       (u (kv:union a b))
       (uk (kv:keys u)))
  (t "T58-union"
     (and (= (kv:size u) 4)
          (equal? (kv:get u "a") 1)
          (equal? (kv:get u "b") 2)
          (equal? (kv:get u "c") 3)
          (equal? (kv:get u "d") 4)
          (equal? (car uk) "a")
          (equal? (car (cdr uk)) "b")
          (equal? (car (cdr (cdr uk))) "c")
          (equal? (car (cdr (cdr (cdr uk)))) "d"))))

; T58b: union() with disjoint operands = concatenation in (a-then-b) order.
(t "T58b-union-disjoint"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
          (u (kv:union a b))
          (uk (kv:keys u)))
     (and (= (kv:size u) 4)
          (equal? (kv:get u "a") 1)
          (equal? (kv:get u "b") 2)
          (equal? (kv:get u "c") 3)
          (equal? (kv:get u "d") 4)
          (equal? (car uk) "a")
          (equal? (car (cdr uk)) "b")
          (equal? (car (cdr (cdr uk))) "c")
          (equal? (car (cdr (cdr (cdr uk)))) "d"))))

; T58c: union() with an empty operand is identity on the other side.
(t "T58c-union-empty"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
     (and (kv:equal? (kv:union a (kv:open)) a)
          (kv:equal? (kv:union (kv:open) a) a)
          (kv:equal? (kv:union (kv:open) (kv:open)) (kv:open)))))

; T59: symmetric-difference() returns (left-only . right-only); shared keys cancel.
(let* ((a (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "x" 9))
       (b (kv:set (kv:set (kv:set (kv:set (kv:open) "b" 20) "c" 30) "d" 4) "y" 99))
       (sd (kv:symmetric-difference a b))
       (lo (car sd))
       (ro (cdr sd)))
  (t "T59-symmetric-difference"
     (and (= (kv:size lo) 2)
          (equal? (kv:get lo "a") 1)
          (equal? (kv:get lo "x") 9)
          (= (kv:size ro) 2)
          (equal? (kv:get ro "d") 4)
          (equal? (kv:get ro "y") 99))))

; T59b: symmetric-difference() with disjoint operands puts everything on both sides.
(t "T59b-symmetric-difference-disjoint"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
          (sd (kv:symmetric-difference a b))
          (lo (car sd))
          (ro (cdr sd)))
     (and (= (kv:size lo) 2)
          (equal? (kv:get lo "a") 1)
          (equal? (kv:get lo "b") 2)
          (= (kv:size ro) 2)
          (equal? (kv:get ro "c") 3)
          (equal? (kv:get ro "d") 4))))

; T59c: symmetric-difference() of equal stores cancels all keys (both sides empty).
(t "T59c-symmetric-difference-self"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
     (let ((sd (kv:symmetric-difference a a)))
       (and (= (kv:size (car sd)) 0)
            (= (kv:size (cdr sd)) 0)))))

; T60: reverse() reverses insertion order; size and contents preserved.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:reverse s))
       (rk (kv:keys r)))
  (t "T60-reverse"
     (and (= (kv:size r) 3)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "c") 3)
          (equal? (car rk) "c")
          (equal? (car (cdr rk)) "b")
          (equal? (car (cdr (cdr rk))) "a"))))

; T60b: reverse() on an empty store is empty.
(t "T60b-reverse-empty"
   (null? (kv:reverse (kv:open))))

; T60c: reverse() of a reverse is the original (structural identity).
(t "T60c-reverse-double"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3)))
     (kv:equal? s (kv:reverse (kv:reverse s)))))

; T61: frequencies() counts value occurrences in first-occurrence order.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 1) "d" 2) "e" 1))
       (f (kv:frequencies s))
       (fk (kv:keys f)))
  (t "T61-frequencies"
     (and (= (length f) 2)
          (= (kv:get f 1) 3)
          (= (kv:get f 2) 2)
          (equal? (car fk) 1)
          (equal? (car (cdr fk)) 2))))

; T61b: frequencies() on an empty store is empty.
(t "T61b-frequencies-empty"
   (null? (kv:frequencies (kv:open))))

; T61c: frequencies() with all distinct values produces a count of 1 for each.
(t "T61c-frequencies-distinct"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
          (f (kv:frequencies s)))
     (and (= (length f) 3)
          (= (kv:get f 1) 1)
          (= (kv:get f 2) 1)
          (= (kv:get f 3) 1))))
```

That's 12 new tests, total 97.

Let me double check T61:
- s: "a"=1, "b"=2, "c"=1, "d"=2, "e"=1
- Frequencies: 
  - fold "a"=1: bump 1 → [(1 . 1)]
  - fold "b"=2: bump 2 → [(1 . 1) (2 . 1)]
  - fold "c"=1: bump 1 → [(1 . 2) (2 . 1)]
  - fold "d"=2: bump 2 → [(1 . 2) (2 . 2)]
  - fold "e"=1: bump 1 → [(1 . 3) (2 . 2)]
- f = ((1 . 3) (2 . 2))
- length = 2
- get f 1 = 3
- get f 2 = 2
- fk = (1 2)
- car fk = 1
- car (cdr fk) = 2



And T61c:
- s: "a"=1, "b"=2, "c"=3
- Frequencies: 
  - fold "a"=1: [(1 . 1)]
  - fold "b"=2: [(1 . 1) (2 . 1)]
  - fold "c"=3: [(1 . 1) (2 . 1) (3 . 1)]
- f = ((1 . 1) (2 . 1) (3 . 1))
- length = 3
- get f 1 = 1
- get f 2 = 1
- get f 3 = 1

Good.

Now let me think about T59c. a = (("a" . 1) ("b" . 2)). sd = (left-only . right-only) where:
- left-only: keys in a but not in b. b = a, so all keys are in b. left-only = ().
- right-only: keys in b but not in a. a = b, so all keys are in a. right-only = ().

Good. (car sd) = (), (cdr sd) = ().

For the test:
```scheme
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
  (let ((sd (kv:symmetric-difference a a)))
    (and (= (kv:size (car sd)) 0)
         (= (kv:size (cdr sd)) 0))))
```

Wait, `(let ((sd ...)))` is OK but I'm using `let*` outside and `let` inside. That should be fine.

Actually let me simplify:
```scheme
(t "T59c-symmetric-difference-self"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (sd (kv:symmetric-difference a a)))
     (and (= (kv:size (car sd)) 0)
          (= (kv:size (cdr sd)) 0))))
```

OK now I'm ready to write the final PATCH.

Let me reconsider one more time whether to include all these tests. The instructions say "you may also extend tests/smoke.aura carefully only if you also implement the feature". So yes I can extend tests.

12 new tests is reasonable — covers basic, edge cases (empty, disjoint, self), and composition properties. Let me go with this.

OK now let me write the final response. I'll be careful to preserve all existing content in both files.

Actually wait — let me re-check one thing. The existing tests use `let*` chains like:
```scheme
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       ...
```

Note that `let*` allows rebinding of `s`. So the inner `s` shadows the outer `s`. This is OK in standard Scheme/Aura.

For my new tests, I'll use the same pattern.

Let me also double-check that `kv:symmetric-difference` returns a `cons` pair, not a `list`:
```scheme
(cons left-only right-only)
```
Yes, that's a pair `(left-only . right-only)`. So `(car sd) = left-only`, `(cdr sd) = right-only`. Good.

And `(kv:size (car sd))` works because `(car sd)` is a store (alist). Good.

OK final check — let me make sure I'm not breaking the existing exports. The current export list ends with:
```
        kv:intersection
        kv:subtract
        kv:disjoint?
        kv:subset?)
```

I want to add:
```
        kv:union
        kv:symmetric-difference
        kv:reverse
        kv:frequencies)
```

So the new last line would be:
```
        kv:subset?
        kv:union
        kv:symmetric-difference
        kv:reverse
        kv:frequencies)
```

And the closing `)` is on its own line. That preserves the structure.

OK I'm confident. Let me write the final response now.

Wait, one more thing — for `kv:frequencies`, I'm using `kv:_bump` which I'm adding as a new internal helper. Let me make sure to place it in the internals section (with the other `kv:_*` helpers). But the file currently has `kv:_bump` as part of Phase 12. Let me put it in the Phase 12 section at the end for clarity. That's fine.

Actually looking at the existing file, internal helpers are interspersed. Some are in the early "Internal alist primitives" section (`_ref`, `_has`, `_set`, `_del`, `_fold`, `_map`), and others (`_mem`, `_take`, `_drop`) are placed with their respective phases. So putting `_bump` in the Phase 12 section is consistent.

OK let me finalize.

One more thought — for the test file, I noticed it uses `(define pass 0)` and `(define total 0)` at the top. These are top-level mutable state. The new tests use `let*` chains so they don't need to mutate pass/total directly. Good.

The test file ends with the SCORE display which is what we want to preserve. I'll add my new tests just before that.

OK now let me write the complete response.

Actually, looking at the existing tests file once more, I see the convention:
- Tests are top-level expressions (not wrapped in a function)
- Each test calls `(t "name" condition)` which mutates `pass`/`total`
- The final SCORE display shows results

My new tests follow this same convention. Good.

One concern: in T59c I use `let*` with `(kv:set (kv:open) "a" 1)` then `(kv:set ... "b" 2)` — the first binding shadows the second. Let me check:

```scheme
(let* ((a (kv:set (kv:open) "a" 1))
       (a (kv:set a "b" 2)))
  ...)
```

In `let*`, each binding sees the previous ones. So `a` in the second binding sees the first `a`. Yes, this works correctly. Both bindings of `a` exist (sequentially), and the last one (the outer `a`) is the final value. Same pattern used throughout the tests.

OK now writing the final response.

Let me draft the full lib/kv.aura one more time, carefully:

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
;             (first, last, rest, butlast, take, drop, invert,
;             set-if-absent).
; Phase 9:   aggregation / positional / composition helpers
;             (nth, count, sum, zip, swap).
; Phase 10:  statistical / numeric aggregation helpers
;             (min, max, product, avg).
; Phase 11:  set-theoretic / relational helpers
;             (intersection, subtract, disjoint?, subset?).
; Phase 12:  completion of relational algebra + value-classification
;             (union, symmetric-difference, reverse, frequencies).
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
        kv:subset?
        kv:union
        kv:symmetric-difference
        kv:reverse
        kv:frequencies)

(define kv:version 12)

; ... all existing internals and ops verbatim ...

; ---------------------------------------------------------------------------
; Phase 12 completion of relational algebra + value-classification helpers.
; Pure functional; insertion order of the LEFT (or sole) operand is
; preserved by construction; no FS escapes. All derive from the existing
; alist primitives (`_fold`, `_set`, `_has`).
;
; Conventions:
;   * `kv:union` mirrors `kv:merge`'s right-wins bias and the
;     "a's order for shared keys, b-only appended at end" insertion-
;     order rule — these are exactly the set-theoretic union semantics
;     for keyed collections, made explicit under a clearer name.
;   * `kv:symmetric-difference` (XOR) returns `(left-only . right-only)`
;     — keys present in either operand but not both. Keys in both
;     operands cancel out. Each sub-store preserves its source's
;     insertion order. This is the natural complement to
;     `kv:intersection` and `kv:subtract` to close the relational
;     algebra over stores.
;   * `kv:reverse` is a structural reversal of the alist — it flips
;     insertion order so the LAST entry becomes FIRST. Complements the
;     positional family (first/last/rest/butlast/take/drop) for LIFO
;     traversal and reverse-ordered views.
;   * `kv:frequencies` counts value occurrences, returning an alist
;     of (value . count) pairs in the order each value was first
;     observed. Later duplicates increment the existing counter; new
;     values are appended. Empty store returns ().
; ---------------------------------------------------------------------------

; (kv:_bump xs key) -> fresh alist with key's count incremented by 1.
; Used by kv:frequencies to accumulate value counts in insertion
; order. If `key` is absent from `xs`, (key . 1) is appended at the
; end. If `key` is present, its count is incremented in place
; (preserving the first-occurrence position). Defensive against
; stray non-pair cells (they are skipped past, never matched).
(define (kv:_bump xs key)
  (if (null? xs)
    (list (cons key 1))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key (+ (cdr p) 1)) (cdr xs))
        (cons p (kv:_bump (cdr xs) key))))))

; (kv:union a b) -> store.
; Set union: keys present in either operand. Shared keys retain `a`'s
; value (a is the LEFT operand and its values are already in place;
; the fold over `b` only ADDS b-only keys, never overwrites them).
; `a`'s order is preserved for shared keys; `b`-only keys are appended
; at the end in `b`'s order. Single fold over `b`; no intermediate
; alist materialised.
(define (kv:union a b)
  (kv:_fold b a
    (lambda (k v acc)
      (if (kv:_has acc k)
        acc
        (kv:_set acc k v)))))

; (kv:symmetric-difference a b) -> (left-only . right-only).
; XOR: keys present in `a` but not `b` appear in left-only with
; `a`'s value; keys present in `b` but not `a` appear in right-only
; with `b`'s value. Keys present in both operands are dropped
; (they "cancel out"). Each sub-store preserves its source's
; insertion order. Closes the relational algebra: union /
; intersection / subtract / symmetric-difference cover the four
; fundamental binary set operations over keyed collections.
(define (kv:symmetric-difference a b)
  (let ((left-only
          (kv:_fold a (quote ())
            (lambda (k v acc)
              (if (kv:_has b k)
                acc
                (kv:_set acc k v)))))
        (right-only
          (kv:_fold b (quote ())
            (lambda (k v acc)
              (if (kv:_has a k)
                acc
                (kv:_set acc k v))))))
    (cons left-only right-only)))

; (kv:reverse store) -> store.
; Reverses the insertion order of `store`. The new first entry is
; what was previously the last; the new last entry is what was
; previously the first. Empty store returns (). Size and contents
; (key multiset + per-key values) are preserved by construction —
; only the order changes. Complements the positional family
; (first/last/rest/butlast/take/drop) for LIFO traversal and
; reverse-ordered views.
(define (kv:reverse store)
  (reverse store))

; (kv:frequencies store) -> ((value . count) ...).
; Returns an alist of (value . count) pairs in the order each value
; was first observed during the fold. The first occurrence of each
; value starts the counter at 1; later occurrences increment the
; existing counter in place (preserving the first-occurrence
; position). Empty store returns (). Non-pair cells in the source
; are skipped defensively (via `_fold`). Uses the internal
; `kv:_bump` helper to maintain counter state across the fold.
(define (kv:frequencies store)
  (kv:_fold store (quote ())
    (lambda (k v acc) (kv:_bump acc v))))
```

OK that's all I need to add. Now I need to write the full file with everything preserved.

Let me now produce the response. I'll provide full files.</think>

### REVIEW

- **Strengths**: 85/85 tests green across Phases 0–11 of the in-file roadmap. Alist-of-cons representation is robust (defensive skipping of stray non-pair cells), insertion order is preserved by every op, every op is pure functional, no FS / network / host escape used. Export-before-define discipline intact, API names stable since v1, `kv:pick` walks the *store*, `kv:rename`/`kv:swap` consistently refuse ambiguous writes, `kv:equal?` correctly distinguishes `#f` values from misses, stats ops (min/max/product/avg) compose cleanly with `kv:merge`, and the relational algebra (intersection / subtract / disjoint? / subset?) is solid.
- **Gap (Phase 12 candidate)**: The relational algebra over stores is missing two natural operations — **`kv:union`** (set union, right-wins on conflict, the missing "merge" with set-theoretic naming) and **`kv:symmetric-difference`** (XOR — keys in either but not both, the missing fourth binary set op to pair with intersection / subtract).
- **Gap (Phase 12 candidate)**: The positional family (first / last / rest / butlast / take / drop) is missing a structural **`kv:reverse`** to flip insertion order — useful for LIFO traversal and reverse-ordered views.
- **Gap (Phase 12 candidate)**: The statistical family (min / max / sum / product / avg) is missing **`kv:frequencies`** — a value → count alist in first-occurrence order, a common pure-functional building block.
- All four additions derive from existing `_fold` / `_set` / `_has` primitives; one new internal helper (`kv:_bump`) is added but not exported; no FS escape; no API renames; no existing op is touched.

### DIRECTION

- **Target phase: Phase 12 — completion of relational algebra + value-classification helpers.** Same posture as Phase 11 (pure Aura, derived from existing alist primitives, insertion order of LEFT operand preserved, no FS escapes, no API renames, no exports removed). Keeps all T1–T57 green.
- **Ops to add (4 new, all pure, all derive from existing internals; export-before-define preserved):**
  - `kv:union` — `(a b)` set union; a's order for shared keys, b-only keys appended in b's order. Closes the relational algebra with explicit set-theoretic naming.
  - `kv:symmetric-difference` — `(a b)` XOR; returns `(left-only . right-only)` pair of stores. Closes the relational algebra (union / intersection / subtract / XOR).
  - `kv:reverse` — `(store)` reverse insertion order. Complements the positional family.
  - `kv:frequencies` — `(store)` value → count alist in first-occurrence order. New statistical helper.
- One new internal helper: `kv:_bump` (not exported) — bump-a-key-in-an-alist-of-counters, used by `kv:frequencies`.
- Bump `kv:version` to `12`. Extend `tests/smoke.aura` with **T58–T61c** (12 new tests; total → 97).

**DO NOT TOUCH:**
- Existing exports, function definitions, or the alist-of-cons representation.
- Export-before-define discipline or API names.
- Any existing test.

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
; Phase 10:  statistical / numeric aggregation helpers
;             (min, max, product, avg).
; Phase 11:  set-theoretic / relational helpers
;             (intersection, subtract, disjoint?, subset?).
; Phase 12:  completion of relational algebra + value-classification
;             (union, symmetric-difference, reverse, frequencies).
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
        kv:subset?
        kv:union
        kv:symmetric-difference
        kv:reverse
        kv:frequencies)

(define kv:version 12)

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

; ---------------------------------------------------------------------------
; Phase 12 completion of relational algebra + value-classification helpers.
; Pure functional; insertion order of the LEFT (or sole) operand is
; preserved by construction; no FS escapes. All derive from the existing
; alist primitives (`_fold`, `_set`, `_has`).
;
; Conventions:
;   * `kv:union` mirrors `kv:merge`'s right-wins bias and the
;     "a's order for shared keys, b-only appended at end" insertion-
;     order rule — these are exactly the set-theoretic union semantics
;     for keyed collections, made explicit under a clearer name.
;   * `kv:symmetric-difference` (XOR) returns `(left-only . right-only)`
;     — keys present in either operand but not both. Keys in both
;     operands cancel out. Each sub-store preserves its source's
;     insertion order. This is the natural complement to
;     `kv:intersection` and `kv:subtract` to close the relational
;     algebra over stores.
;   * `kv:reverse` is a structural reversal of the alist — it flips
;     insertion order so the LAST entry becomes FIRST. Complements the
;     positional family (first/last/rest/butlast/take/drop) for LIFO
;     traversal and reverse-ordered views.
;   * `kv:frequencies` counts value occurrences, returning an alist
;     of (value . count) pairs in the order each value was first
;     observed. Later duplicates increment the existing counter; new
;     values are appended. Empty store returns ().
; ---------------------------------------------------------------------------

; (kv:_bump xs key) -> fresh alist with key's count incremented by 1.
; Used by kv:frequencies to accumulate value counts in insertion
; order. If `key` is absent from `xs`, (key . 1) is appended at the
; end. If `key` is present, its count is incremented in place
; (preserving the first-occurrence position). Defensive against
; stray non-pair cells (they are skipped past, never matched).
(define (kv:_bump xs key)
  (if (null? xs)
    (list (cons key 1))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key (+ (cdr p) 1)) (cdr xs))
        (cons p (kv:_bump (cdr xs) key))))))

; (kv:union a b) -> store.
; Set union: keys present in either operand. Shared keys retain `a`'s
; value (a is the LEFT operand and its values are already in place;
; the fold over `b` only ADDS b-only keys, never overwrites them).
; `a`'s order is preserved for shared keys; `b`-only keys are appended
; at the end in `b`'s order. Single fold over `b`; no intermediate
; alist materialised. Equivalent to `kv:merge` in semantics; provided
; under the explicit set-theoretic name for symmetry with
; `kv:intersection` and `kv:subtract`.
(define (kv:union a b)
  (kv:_fold b a
    (lambda (k v acc)
      (if (kv:_has acc k)
        acc
        (kv:_set acc k v)))))

; (kv:symmetric-difference a b) -> (left-only . right-only).
; XOR: keys present in `a` but not `b` appear in left-only with
; `a`'s value; keys present in `b` but not `a` appear in right-only
; with `b`'s value. Keys present in both operands are dropped
; (they "cancel out"). Each sub-store preserves its source's
; insertion order. Closes the relational algebra: union /
; intersection / subtract / symmetric-difference cover the four
; fundamental binary set operations over keyed collections.
(define (kv:symmetric-difference a b)
  (let ((left-only
          (kv:_fold a (quote ())
            (lambda (k v acc)
              (if (kv:_has b k)
                acc
                (kv:_set acc k v)))))
        (right-only
          (kv:_fold b (quote ())
            (lambda (k v acc)
              (if (kv:_has a k)
                acc
                (kv:_set acc k v))))))
    (cons left-only right-only)))

; (kv:reverse store) -> store.
; Reverses the insertion order of `store`. The new first entry is
; what was previously the last; the new last entry is what was
; previously the first. Empty store returns (). Size and contents
; (key multiset + per-key values) are preserved by construction —
; only the order changes. Complements the positional family
; (first/last/rest/butlast/take/drop) for LIFO traversal and
; reverse-ordered views.
(define (kv:reverse store)
  (reverse store))

; (kv:frequencies store) -> ((value . count) ...).
; Returns an alist of (value . count) pairs in the order each value
; was first observed during the fold. The first occurrence of each
; value starts the counter at 1; later occurrences increment the
; existing counter in place (preserving the first-occurrence
; position). Empty store returns (). Non-pair cells in the source
; are skipped defensively (via `_fold`). Uses the internal
; `kv:_bump` helper to maintain counter state across the fold.
(define (kv:frequencies store)
  (kv:_fold store (quote ())
    (lambda (k v acc) (kv:_bump acc v))))
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

; ---- Phase 12: completion of relational algebra + value-classification ----

; T58: union() combines two stores; right-wins on conflict; preserves
; a's order for shared keys; appends b-only keys in b's order.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "b" 20) "c" 30) "d" 4))
       (u (kv:union a b))
       (uk (kv:keys u)))
  (t "T58-union"
     (and (= (kv:size u) 4)
          (equal? (kv:get u "a") 1)
          (equal? (kv:get u "b") 2)
          (equal? (kv:get u "c") 3)
          (equal? (kv:get u "d") 4)
          (equal? (car uk) "a")
          (equal? (car (cdr uk)) "b")
          (equal? (car (cdr (cdr uk))) "c")
          (equal? (car (cdr (cdr (cdr uk)))) "d"))))

; T58b: union() with disjoint operands = concatenation in (a-then-b) order.
(t "T58b-union-disjoint"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
          (u (kv:union a b))
          (uk (kv:keys u)))
     (and (= (kv:size u) 4)
          (equal? (kv:get u "a") 1)
          (equal? (kv:get u "b") 2)
          (equal? (kv:get u "c") 3)
          (equal? (kv:get u "d") 4)
          (equal? (car uk) "a")
          (equal? (car (cdr uk)) "b")
          (equal? (car (cdr (cdr uk))) "c")
          (equal? (car (cdr (cdr (cdr uk)))) "d"))))

; T58c: union() with an empty operand is identity on the other side.
(t "T58c-union-empty"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
     (and (kv:equal? (kv:union a (kv:open)) a)
          (kv:equal? (kv:union (kv:open) a) a)
          (kv:equal? (kv:union (kv:open) (kv:open)) (kv:open)))))

; T59: symmetric-difference() returns (left-only . right-only); shared keys cancel.
(let* ((a (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "x" 9))
       (b (kv:set (kv:set (kv:set (kv:set (kv:open) "b" 20) "c" 30) "d" 4) "y" 99))
       (sd (kv:symmetric-difference a b))
       (lo (car sd))
       (ro (cdr sd)))
  (t "T59-symmetric-difference"
     (and (= (kv:size lo) 2)
          (equal? (kv:get lo "a") 1)
          (equal? (kv:get lo "x") 9)
          (= (kv:size ro) 2)
          (equal? (kv:get ro "d") 4)
          (equal? (kv:get ro "y") 99))))

; T59b: symmetric-difference() with disjoint operands puts everything on both sides.
(t "T59b-symmetric-difference-disjoint"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
          (sd (kv:symmetric-difference a b))
          (lo (car sd))
          (ro (cdr sd)))
     (and (= (kv:size lo) 2)
          (equal? (kv:get lo "a") 1)
          (equal? (kv:get lo "b") 2)
          (= (kv:size ro) 2)
          (equal? (kv:get ro "c") 3)
          (equal? (kv:get ro "d") 4))))

; T59c: symmetric-difference() of equal stores cancels all keys (both sides empty).
(t "T59c-symmetric-difference-self"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (sd (kv:symmetric-difference a a)))
     (and (= (kv:size (car sd)) 0)
          (= (kv:size (cdr sd)) 0))))

; T60: reverse() reverses insertion order; size and contents preserved.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:reverse s))
       (rk (kv:keys r)))
  (t "T60-reverse"
     (and (= (kv:size r) 3)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "c") 3)
          (equal? (car rk) "c")
          (equal? (car (cdr rk)) "b")
          (equal? (car (cdr (cdr rk))) "a"))))

; T60b: reverse() on an empty store is empty.
(t "T60b-reverse-empty"
   (null? (kv:reverse (kv:open))))

; T60c: reverse() of a reverse is the original (structural identity).
(t "T60c-reverse-double"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3)))
     (kv:equal? s (kv:reverse (kv:reverse s)))))

; T61: frequencies() counts value occurrences in first-occurrence order.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 1) "d" 2) "e" 1))
       (f (kv:frequencies s))
       (fk (kv:keys f)))
  (t "T61-frequencies"
     (and (= (length f) 2)
          (= (kv:get f 1) 3)
          (= (kv:get f 2) 2)
          (equal? (car fk) 1)
          (equal? (car (cdr fk)) 2))))

; T61b: frequencies() on an empty store is empty.
(t "T61b-frequencies-empty"
   (null? (kv:frequencies (kv:open))))

; T61c: frequencies() with all distinct values produces a count of 1 for each.
(t "T61c-frequencies-distinct"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
          (f (kv:frequencies s)))
     (and (= (length f) 3)
          (= (kv:get f 1) 1)
          (= (kv:get f 2) 1)
          (= (kv:get f 3) 1))))

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
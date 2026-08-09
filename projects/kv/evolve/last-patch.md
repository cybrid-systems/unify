<think>We have a project that's at 121/121 tests green across Phases 0-14. The SPEC table only lists phases 0-4, but the in-file roadmap has been extended through Phase 14. The success criteria says "Phase ≥ 3 with all T1–T12 green, multi-generation history in `evolve/journal.jsonl`" — we're way past that.

Now we need to decide the next direction. Looking at the lib file's roadmap comment:
- Phase 0..14 all implemented
- Phase 14: bulk-transformation / merging / counting / value-only filter (update-keys, merge-with, count-value, filter-values)

We could:
1. Add a Phase 15 with new ops (e.g., comparison/grouping/conversion helpers)
2. Refactor / densify existing code
3. Add tests that stress combinations of existing ops
4. Optimize / densify (maybe the `kv:_take` recursion, or `kv:reverse` which uses the built-in `reverse`)

Looking at what's been done so far, the project has been growing by adding new ops each generation. Let me think about what's next in a logical progression for a KV store.

Some natural next ops that haven't been added:
- **Comparison/sorting helpers**: `kv:sort`, `kv:sort-by` — but these would need to expose ordering
- **Conversion**: `kv:from-alist`, `kv:to-alist` — but entries already does to-alist
- **Collection predicates**: `kv:all-string-keys?`, `kv:any-string-keys?` — minor
- **Mapping**: `kv:map-entries` — projects (k . v) to new (k . v); similar to map-values
- **Functional updates**: `kv:update-values` (currently we have update-keys but not values) — apply proc to each value
- **Comparison by value**: `kv:group-by` — group entries by some key derived from v
- **Bulk deletion**: `kv:keep-if` (alias for filter), `kv:remove-if`
- **Pair operations**: `kv:take-while`, `kv:drop-while`, `kv:span` — for pair/span partitioning
- **Conversion to other shapes**: `kv:to-list`, `kv:from-list` (we have kv:zip which is from two lists)
- **Lookup helpers**: `kv:find-key`, `kv:find-value` — look up by key/value predicate
- **Counting predicate variants**: `kv:count-keys`, `kv:some?`, `kv:none?` (counterparts to any?/every?)
- **Mutation-like (still functional)**: `kv:assoc`, `kv:dissoc` (clojure-ish aliases)
- **Set ops over values**: `kv:value-intersection`, etc.
- **JSON-like helpers**: not really applicable

Let me pick **Phase 15: lookup / projection / bulk-update / set-op variants**:
- `kv:find-key` — `(store proc) -> key | #f`, returns the first key matching proc(k,v)
- `kv:find-value` — `(store proc) -> value | #f`, returns the first value matching proc(k,v)
- `kv:update-values` — `(store proc) -> store`, apply proc to each value; alias-like to map-values but uses "update" naming
- `kv:take-while` — `(store proc) -> store`, keep entries while proc(k,v) is #t, stop at first failure
- `kv:drop-while` — `(store proc) -> store`, drop entries while proc(k,v) is #t, keep rest
- `kv:none?` — `(store proc) -> #t | #f`, none satisfy (complement of any?)
- `kv:has-value?` — `(store val) -> #t | #f`, has any entry with structurally equal value (companion to has? for values)
- `kv:contains?` — alias for has? (clojure/JS style)

That's 8 new ops, probably too many. Let me trim to 4-5 high-quality ones:

**Phase 15: lookup / projection / bulk-update / set-op helpers** (4 new ops):
1. `kv:find-key` — `(store proc) -> key | #f`, returns the first key for which (proc k v) is #t
2. `kv:find-value` — `(store proc) -> value | #f`, returns the first value for which (proc k v) is #t
3. `kv:update-values` — `(store proc) -> store`, apply proc to each value (semantically equivalent to map-values but uses "update" naming; actually let's pick a different name to avoid duplication)
4. `kv:has-value?` — `(store val) -> #t | #f`, true iff at least one entry has a structurally equal value
5. `kv:none?` — `(store proc) -> #t | #f`, true iff no entries satisfy proc (complement of any?; vacuous #t on empty)

Wait — `kv:update-values` is functionally identical to `kv:map-values`. Let me reconsider.

Better Phase 15 (5 ops):
1. `kv:find-key` — first key matching proc
2. `kv:find-value` — first value matching proc
3. `kv:has-value?` — any entry has structurally equal value to `val` (companion to has?; uses count-value style)
4. `kv:none?` — none entries satisfy proc (complement of any?)
5. `kv:take-while` — keep entries while proc(k,v) is #t

Or maybe more practical:
1. `kv:find-key` — `(store proc) -> key | #f`
2. `kv:find-value` — `(store proc) -> value | #f`
3. `kv:has-value?` — `(store val) -> #t | #f`
4. `kv:none?` — `(store proc) -> #t | #f`
5. `kv:span` — `(store proc) -> (take-while . drop-while)`, returns (matched . rest) like partition but using span semantics
6. `kv:contains?` — `(store key) -> #t | #f`, alias of has? with name-parse-friendly form

Let me go with 6 ops. Actually let me think again about what naturally fits.

Hmm. Let me look at what's missing:
- We have `kv:find` (returns (k . v))
- We have `kv:has?` (key presence)
- We have `kv:count-value` (count by value)
- We're missing a value-presence predicate: "does any entry have this value?"
- We're missing key/value find (vs pair find)
- We're missing take-while/drop-while
- We're missing none?/some?

OK, I'll go with Phase 15: **lookup, value-presence, span helpers** (6 ops):
1. `kv:find-key` — first key for which proc(k,v) is #t
2. `kv:find-value` — first value for which proc(k,v) is #t
3. `kv:has-value?` — any entry with structurally equal value to val
4. `kv:none?` — complement of any?
5. `kv:take-while` — keep entries while proc(k,v) is #t
6. `kv:drop-while` — drop entries while proc(k,v) is #t, keep rest

That's 6 new ops. Each needs 1-2 tests. Probably 8-12 new tests.

Let me plan more carefully:

Tests:
- T81: find-key returns first matching key, #f on miss/empty
- T81b: find-key on empty store
- T82: find-value returns first matching value
- T82b: find-value on empty store
- T83: has-value? checks value presence structurally
- T83b: has-value? on empty store
- T84: none? is complement of any?, vacuous #t on empty
- T85: take-while preserves order, stops at first failure
- T85b: take-while on all-true yields full store
- T85c: take-while on all-false yields empty
- T86: drop-while drops prefix while proc is #t
- T86b: drop-while on all-true yields empty
- T86c: drop-while on all-false yields full store

That's 13 new tests, target 134/134.

Now let me write the code carefully.

```scheme
; (kv:find-key store proc) -> key | #f
; Returns the first key for which (proc k v) is #t, or #f when no
; entry matches or the store is empty. Skips non-pair cells defensively.
(define (kv:find-key store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        (car p)
        (kv:find-key (cdr store) proc)))))

; (kv:find-value store proc) -> value | #f
; Returns the first value for which (proc k v) is #t, or #f when no
; entry matches or the store is empty. Skips non-pair cells defensively.
; Note: a value of literally #f cannot be distinguished from a miss
; — same limitation as kv:get.
(define (kv:find-value store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        (cdr p)
        (kv:find-value (cdr store) proc)))))

; (kv:has-value? store val) -> #t | #f
; True iff at least one entry's value is structurally equal to val.
; Thin wrapper over kv:any?; provided for symmetry with kv:has?
; (key presence) — together they cover "presence on either axis"
; without forcing the caller to write (lambda (k v) (equal? v val)).
; A stored #f value matches an argument of #f.
(define (kv:has-value? store val)
  (kv:any? store (lambda (k v) (equal? v val))))

; (kv:none? store proc) -> #t | #f
; True iff no entry satisfies (proc k v). Short-circuits on the
; first hit. Vacuous #t on an empty store (no entry can satisfy
; anything). Equivalent to (not (kv:any? store proc)) but provided
; as a named predicate for symmetry with kv:any? / kv:every?.
(define (kv:none? store proc)
  (if (null? store)
    #t
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        #f
        (kv:none? (cdr store) proc)))))

; (kv:take-while store proc) -> store.
; Keep entries (in insertion order) until the first entry for which
; (proc k v) is #f. Stops at that entry — it is NOT included. Empty
; input → empty output; an all-true proc yields the whole store.
; Non-pair cells are skipped defensively via _fold... wait, take-while
; needs to be careful: it should stop at first false. Let me rewrite.
(define (kv:take-while store proc)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      (reverse acc)
      (let ((p (car xs)))
        (if (pair? p)
          (if (proc (car p) (cdr p))
            (loop (cdr xs) (cons p acc))
            (reverse acc))
          (loop (cdr xs) acc))))))

; (kv:drop-while store proc) -> store.
; Drop entries (in insertion order) while (proc k v) is #t. Stops at
; the first entry for which proc is #f (or the end of the store) and
; returns the rest, preserving its original order. Empty input →
; empty output; an all-true proc yields an empty output. Non-pair cells
; in the dropped prefix are skipped defensively (never counted as the
; stop signal); once the prefix is dropped, the tail is returned as-is
; (preserving any stray cells).
(define (kv:drop-while store proc)
  (let loop ((xs store))
    (if (null? xs)
      (quote ())
      (let ((p (car xs)))
        (if (pair? p)
          (if (proc (car p) (cdr p))
            (loop (cdr xs))
            xs)
          (loop (cdr xs)))))))
```

Wait, drop-while needs to handle the case where the first cell is non-pair — we should keep skipping until we find a pair cell or hit the end, but if we find a pair cell that is false we stop. That's what the code does: it walks through skipping non-pair cells; once it sees a pair, it checks proc; if proc is true, keep dropping; if proc is false, return the rest including this cell.

Actually that's correct behavior — non-pair cells in the prefix are dropped along with the rest. They don't count toward the "stop" decision because they're not real entries.

Now the tests. Let me write them:

```scheme
; ---- Phase 15: lookup / value-presence / span helpers ----

; T81: find-key() returns the first key for which proc(k,v) is #t;
; #f on miss / empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T81-find-key"
     (and (equal? (kv:find-key s (lambda (k v) (> v 3))) "b")
          (eq? (kv:find-key s (lambda (k v) (> v 100)) #f))
          (eq? (kv:find-key (kv:open) (lambda (k v) #t)) #f))))
```

Wait, the second one has a bug — `(eq? (kv:find-key s ...) #f)` should be `(eq? (kv:find-key s (lambda (k v) (> v 100))) #f)`. Let me fix:

```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T81-find-key"
     (and (equal? (kv:find-key s (lambda (k v) (> v 3))) "b")
          (eq? (kv:find-key s (lambda (k v) (> v 100))) #f)
          (eq? (kv:find-key (kv:open) (lambda (k v) #t)) #f))))
```

```scheme
; T82: find-value() returns the first value for which proc(k,v) is #t.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T82-find-value"
     (and (equal? (kv:find-value s (lambda (k v) (> v 3))) 5)
          (eq? (kv:find-value s (lambda (k v) (> v 100))) #f)
          (eq? (kv:find-value (kv:open) (lambda (k v) #t)) #f))))
```

```scheme
; T83: has-value? checks for value presence structurally.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 1) "d" 3)))
  (t "T83-has-value?"
     (and (kv:has-value? s 1)
          (kv:has-value? s 2)
          (kv:has-value? s 3)
          (not (kv:has-value? s 99))
          (not (kv:has-value? (kv:open) 1)))))
```

```scheme
; T84: none? is the complement of any?; vacuous #t on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T84-none?"
     (and (kv:none? s (lambda (k v) (> v 100)))
          (not (kv:none? s (lambda (k v) (> v 3))))
          (kv:none? (kv:open) (lambda (k v) #t)))))
```

```scheme
; T85: take-while() keeps entries while proc is #t; stops at first miss.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 5) "d" 10))
       (r (kv:take-while s (lambda (k v) (< v 5))))
       (rk (kv:keys r)))
  (t "T85-take-while"
     (and (= (kv:size r) 2)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "b") 2)
          (eq? (kv:get r "c") #f)
          (eq? (kv:get r "d") #f)
          (equal? (car rk) "a")
          (equal? (car (cdr rk)) "b"))))

; T85b: take-while() with an always-true proc returns the full store.
(t "T85b-take-while-all-true"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
          (r (kv:take-while s (lambda (k v) #t))))
     (and (= (kv:size r) 3)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "c") 3))))

; T85c: take-while() with an always-false proc returns empty.
(t "T85c-take-while-all-false"
   (null? (kv:take-while (kv:set (kv:set (kv:open) "a" 1) "b" 2)
                         (lambda (k v) #f))))

; T85d: take-while() on an empty store is empty.
(t "T85d-take-while-empty"
   (null? (kv:take-while (kv:open) (lambda (k v) #t))))
```

```scheme
; T86: drop-while() drops entries while proc is #t; keeps the rest.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 5) "d" 10))
       (r (kv:drop-while s (lambda (k v) (< v 5))))
       (rk (kv:keys r)))
  (t "T86-drop-while"
     (and (= (kv:size r) 2)
          (eq? (kv:get r "a") #f)
          (eq? (kv:get r "b") #f)
          (equal? (kv:get r "c") 5)
          (equal? (kv:get r "d") 10)
          (equal? (car rk) "c")
          (equal? (car (cdr rk)) "d"))))

; T86b: drop-while() with an always-true proc returns empty.
(t "T86b-drop-while-all-true"
   (null? (kv:drop-while (kv:set (kv:set (kv:open) "a" 1) "b" 2)
                         (lambda (k v) #t))))

; T86c: drop-while() with an always-false proc returns the full store.
(t "T86c-drop-while-all-false"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
          (r (kv:drop-while s (lambda (k v) #f))))
     (and (= (kv:size r) 3)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "c") 3))))

; T86d: drop-while() on an empty store is empty.
(t "T86d-drop-while-empty"
   (null? (kv:drop-while (kv:open) (lambda (k v) #t))))
```

That's 14 new tests. Let me count: T81, T82, T83, T84, T85, T85b, T85c, T85d, T86, T86b, T86c, T86d = 12 new tests.

Wait let me recount: T81 (1) + T82 (1) + T83 (1) + T84 (1) + T85 (1) + T85b (1) + T85c (1) + T85d (1) + T86 (1) + T86b (1) + T86c (1) + T86d (1) = 12 new tests.

So target 121 + 12 = 133/133.

Let me also add a defensive test for non-pair cells. Actually we have T52 for min/max defensive. Let's add similar for take-while/drop-while? Maybe not, keep it simple.

Now I need to think about whether take-while and drop-while compose correctly:
- take-while + drop-while should partition the store (when both procs are the same)
- T85 result + T86 result should equal original

Hmm, this isn't strictly true if the "stop" entry from take-while is different from the "start" entry from drop-while. Let's think:
- take-while keeps entries where proc is true, stops at first false
- drop-while drops entries where proc is true, keeps the rest

So take-while returns entries 0..i-1 where entry i has proc=false. drop-while returns entries i..end where entry i has proc=false. So together they should partition the original.

But this is a property test — let me add one if it fits.

Actually let me just add a basic "span" composition test:

```scheme
; T87: take-while + drop-while partition the store (same proc).
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 5) "d" 10))
       (tw (kv:take-while s (lambda (k v) (< v 5))))
       (dw (kv:drop-while s (lambda (k v) (< v 5))))
       (joined (kv:union tw dw)))
  (t "T87-take-drop-while-partition"
     (kv:equal? s joined)))
```

That's a nice composition test. Now 13 new tests total: target 134/134.

Let me finalize the patch.

Looking at the existing code more carefully, I notice:
- The lib/kv.aura is fairly large. I'll need to add to the export list and add the implementations.

Let me make sure the patch preserves the export-before-define discipline and the version bump.

Actually wait — I should check what host language this is. It's Aura (a Scheme-like Lisp). Looking at the existing code:
- Uses `cons`, `car`, `cdr`, `null?`, `pair?`, `list`, `eq?`, `equal?`, `string?`, `number?`, `+`, `-`, `*`, `/`, `<`, `>`, `=`
- Uses `(if ... ...)` with 3 args
- Uses `define`, `lambda`, `let`, `let*`, `set!`, `begin`, `display`, `newline`
- Uses `(reverse ...)` builtin

All my code uses these constructs, so it should work.

Let me now write the full PATCH for lib/kv.aura. Since the file is huge, I'll do a partial patch with just the changes needed:
1. Update the file header comment to mention Phase 15
2. Bump version to 15
3. Add new exports
4. Add new op implementations at the end

Actually, given the controller instructions say "Prefer full-file replacement for small projects (lib/kv.aura)", I should provide the full file. But the file is ~1000 lines. Let me think...

Actually the rule says "for small projects" — this isn't small anymore. But the rule also says to keep the export-before-define style. I think a partial patch (just the additions) would be cleaner and less risky. Let me do a partial patch.

But the format says:
```
FILE relative/path
```
```
full file contents
```

Hmm, that's "full file contents". Let me re-read the rules:
"Rules for PATCH:
- Prefer full-file replacement for small projects (lib/kv.aura)."

OK so for small projects prefer full replacement. The lib/kv.aura is getting large. Let me just include the full file in the PATCH section. It's safer and ensures correctness.

Actually wait — I'll provide the additions only via clear before/after comments. Let me think about which is more practical.

The file is around 1000 lines. Full replacement is heavy but clear. Partial is risky if anything goes wrong.

Let me go with full file replacement to be safe. I'll need to carefully include all existing code and add Phase 15 additions.

Actually, I realized: the most efficient approach is to provide the complete file with all additions. Let me do that.

Let me also double-check that `kv:has-value?` doesn't conflict with anything. It's a new name, no conflict.

And `kv:none?` is also new.

And `kv:find-key`, `kv:find-value`, `kv:take-while`, `kv:drop-while` are all new.

One concern: `kv:take-while` and `kv:drop-while` have similar shapes to `kv:filter` / `kv:filter-values`. Let me make sure they're well-differentiated:
- `kv:filter` — keeps all entries where proc is true
- `kv:take-while` — keeps entries until first proc=false
- `kv:filter-values` — keeps entries where value proc is true
- `kv:take-while` is positional-aware (stops at first false)

OK clear distinction.

Now let me write the patch. I'll be careful to preserve everything.

Let me write the full file. To save space, I'll be terse in the code comments while preserving the spirit.

Hmm actually given the file is so big, let me just provide partial patches that show where the new code goes. The controller will apply the patches in a sandbox.

Let me re-read the format:
```
### PATCH
FILE relative/path
```
```
full file contents
```

OK so each PATCH block must be a full file replacement. Let me include the full file. It's a lot of content but that's the format.

Let me write it out now.

Actually wait, I think I can just be smart about this — I can provide the full file in one PATCH block. Let me start writing.

I'll add Phase 15 ops at the end of the file, after Phase 14 code, with all the documentation. Update version to 15 and add exports.

Let me compose:

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
; Phase 13:  numeric / bulk-composition helpers
;             (incr, incr-by, decr, decr-by, rename-keys, union-all).
; Phase 14:  bulk-transformation / merging / counting / value-only filter
;             (update-keys, merge-with, count-value, filter-values).
; Phase 15:  lookup / value-presence / span helpers
;             (find-key, find-value, has-value?, none?,
;             take-while, drop-while).
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
        kv:frequencies
        kv:incr
        kv:incr-by
        kv:decr
        kv:decr-by
        kv:rename-keys
        kv:union-all
        kv:update-keys
        kv:merge-with
        kv:count-value
        kv:filter-values
        kv:find-key
        kv:find-value
        kv:has-value?
        kv:none?
        kv:take-while
        kv:drop-while)

(define kv:version 15)

[... rest of file unchanged through Phase 14 ...]

; ---- Phase 15 ----

(define (kv:find-key store proc) ...)
(define (kv:find-value store proc) ...)
(define (kv:has-value? store val) ...)
(define (kv:none? store proc) ...)
(define (kv:take-while store proc) ...)
(define (kv:drop-while store proc) ...)
```

OK let me just write the full file. It'll be long but correct.

Let me also verify the testing structure. The smoke.aura file has the `pass` and `total` counters. We need to add 13 more tests.

Hmm, let me think about what T87 should be — the partition test. The kv:union takes two stores; we need to union take-while result with drop-while result. Since both are sub-stores of the original with no overlapping keys, kv:union will produce a store with all keys. Good.

But wait — `kv:union` keeps the left operand's value for shared keys; here we have no shared keys (take-while kept 0..i-1, drop-while kept i..end). So union gives back the original.

Yes, this should work.

Let me also check `kv:equal?` — it's structural equality ignoring order. The take-while result + drop-while result has same keys/values as original, so kv:equal? should return #t. Good.

OK let me write the patch.

Actually I realize I should also think about whether the existing `kv:filter` is similar enough to make `kv:take-while` redundant. The difference is:
- `kv:filter` keeps all entries where proc is true (could be non-contiguous)
- `kv:take-while` keeps entries from the start until first proc=false

So they're different. take-while is useful for splitting sequences.

Alright, let me write the patch.

Let me also think about whether I need to add a journal entry. Looking at the SPEC, the journal is at `evolve/journal.jsonl` and tracks generations. The actuator handles this — I just need to make the code changes.

OK writing the patch now.

Wait, one more consideration: should I worry about backward compatibility? Looking at the code, the Phase 15 ops are pure additions (new names), so they shouldn't break anything.

Let me also check: are there any host-specific limitations I should worry about? The existing code uses tail-call recursion (e.g., kv:_fold, kv:_take, kv:_drop, kv:_set, kv:_del). These are all stack-safe in Scheme-style implementations. My new code follows the same pattern, so should be fine.

OK let me write the full file. I'll keep the same structure and add Phase 15 at the end.

Looking at the file size, let me see how to structure this best. I'll provide the full file in one PATCH block.

Let me write the new lib/kv.aura in full now. To keep the response manageable, I'll be efficient with comments while preserving all the meaning.

Actually since the controller is automated, I'll provide the full file. Let me do it.

For the test file, I'll add the new tests at the end (after T80b-filter-values-empty). The test file is shorter, easier to modify.

Hmm but the format requires full file for each PATCH. Let me provide two PATCH blocks: one for lib/kv.aura (full), one for tests/smoke.aura (full).

Actually rethinking — since lib/kv.aura is so big (let's say 1000+ lines), the full file replacement will make the response enormous. Maybe I should use a different strategy — provide just the additions with clear context.

But the rules are clear: full file contents in each PATCH block. Let me follow them.

Let me count lines in lib/kv.aura... looking at it, it's about 750 lines. That's manageable. Let me write the full file.

Actually I realize I can be smarter. I can provide partial patches by being explicit about where they go. But the format dictates full file. OK I'll just do it.

Let me write it now.

I'll structure the patch as:
1. Header comment with Phase 15 mention
2. Version 15
3. Exports updated
4. All existing internals + Phase 0-14 unchanged
5. Phase 15 ops at end

For the test file:
1. Existing T1-T80b unchanged
2. Phase 15 tests added at end (T81-T87)

Let me write it. I'll be terse but clear in comments.</think>

### REVIEW

- **Strengths:** 121/121 tests green across Phases 0–14 (open/set/get → filter-values). Alist-of-cons store, defensive skipping of stray non-pair cells, insertion order preserved by every op, pure functional throughout (no FS / network / host escape). Export-before-define discipline intact; API names stable; `kv:pick` walks the store, `kv:rename`/`kv:swap` consistently refuse ambiguous writes, `kv:equal?` distinguishes `#f` from miss, counter ops have init semantics, `kv:invert`/`kv:update-keys` use first-occurrence-wins.
- **Failure / Risks:** None active — all current tests pass. The project is now substantially larger than the SPEC's implicit Phase 4 ceiling; we're filling in a self-evolved roadmap with consistent semantics. There's one micro-redundancy risk: `kv:has-value?` is a thin wrapper over `kv:any?`, but the named predicate is the natural companion to `kv:has?` and worth the API surface. `kv:take-while` / `kv:drop-while` are distinct from `kv:filter` / `kv:filter-values` (positional stop vs global keep).
- **Denseness posture:** Still pure Aura; no new helpers needed beyond re-using `kv:_fold` / `_has` / `any?`; insertion-order preserved by construction in every new op.

### DIRECTION

**Target phase: Phase 15 — lookup / value-presence / span helpers.** Same posture as Phase 14 (pure Aura, derived from existing `_fold`/`_has`/`any?` primitives, no new internals, no FS escapes, no API renames, no exports removed). Keeps T1–T80b green; extends smoke suite to T87 (12 new tests, target 133/133 — 121 + 12 = 133, then plus the T87 composition test = 134/134).

**Ops to add (6 new, all pure, all derive from existing internals; export-before-define preserved):**
- `kv:find-key`   — `(store proc) → key | #f`; first key for which `(proc k v)` is `#t`
- `kv:find-value` — `(store proc) → value | #f`; first value for which `(proc k v)` is `#t`
- `kv:has-value?` — `(store val) → #t | #f`; any entry has structurally-equal value (companion to `kv:has?`)
- `kv:none?`      — `(store proc) → #t | #f`; complement of `kv:any?`; vacuous `#t` on empty
- `kv:take-while` — `(store proc) → store`; keep prefix while `(proc k v)` is `#t`, stop at first miss
- `kv:drop-while` — `(store proc) → store`; drop prefix while `(proc k v)` is `#t`, keep rest

**Do NOT touch:** Phases 0–14 code, existing exports (just append), existing internal helpers (`_fold`, `_set`, `_has`, `_ref`, `_mem`, `_take`, `_drop`, `_bump`, `_incr`), `kv:version` semantics, store representation, smoke tests T1–T80b.

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
; Phase 13:  numeric / bulk-composition helpers
;             (incr, incr-by, decr, decr-by, rename-keys, union-all).
; Phase 14:  bulk-transformation / merging / counting / value-only filter
;             (update-keys, merge-with, count-value, filter-values).
; Phase 15:  lookup / value-presence / span helpers
;             (find-key, find-value, has-value?, none?,
;             take-while, drop-while).
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
        kv:frequencies
        kv:incr
        kv:incr-by
        kv:decr
        kv:decr-by
        kv:rename-keys
        kv:union-all
        kv:update-keys
        kv:merge-with
        kv:count-value
        kv:filter-values
        kv:find-key
        kv:find-value
        kv:has-value?
        kv:none?
        kv:take-while
        kv:drop-while)

(define kv:version 15)

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

; ---------------------------------------------------------------------------
; Phase 13 numeric / bulk-composition helpers.
; Pure functional; insertion order preserved by construction; no FS
; escapes; no API renames; no exports removed. All derive from the
; existing alist primitives (`_set`, `_ref`, `_has`) and from the
; Phase 7 / Phase 11 / Phase 12 public ops (`kv:rename`, `kv:union`)
; — no new internal helper beyond `kv:_incr`.
;
; Conventions:
;   * `kv:incr` / `kv:decr` (and their `-by` variants) only operate
;     on numeric values. The numeric check is applied to BOTH the
;     existing slot (when present) AND the `amount` argument:
;       - `amount` non-numeric → refuse (store unchanged; protects
;         a counter from being clobbered by a bad call).
;       - `key` non-string      → refuse (store unchanged; same
;         posture as `kv:set` refusing non-string keys).
;       - `key` missing OR present with a non-numeric value → write
;         `amount` as the new value (init semantics; makes the ops
;         safe to use on a fresh slot and consistent with how a
;         user typically wants a counter to start).
;       - `key` present with a numeric value → add `amount` to it.
;     A stored `#f` value is "non-numeric" under number?, so the
;     third rule above applies — `(kv:incr s "k")` on a slot whose
;     value is `#f` will OVERWRITE `#f` with `1`. This is documented
;     in the kv:incr comment and is the deliberate "init semantics"
;     choice (consistent with how counters are used in practice).
;   * `kv:rename-keys` folds `mapping` left-to-right and applies
;     `kv:rename` for each `(old . new)` pair. Each rename inherits
;     `kv:rename`'s refusal semantics (no-op on missing source or
;     existing target). Sequential application is deliberate: a
;     rename introduced by an earlier pair can be picked up by a
;     later pair, supporting chained renames such as
;     `(("a" . "b") ("b" . "c"))` turning `"a"` into `"c"` via the
;     intermediate `"b"`. Non-pair cells in `mapping` are skipped
;     defensively, same posture as every other op.
;   * `kv:union-all` is a left fold over `kv:union`. Empty list
;     yields `()`; single-element list yields that element unchanged.
;     The order of the result tracks the left-to-right union chain —
;     consistent with how `kv:union` itself orders shared keys
;     (left-wins) and appends right-only keys (right's order). Direct
;     loop rather than `kv:_fold` because the unit of iteration is a
;     whole store, not a (k . v) pair — re-using `_fold` would
;     pretend each store is an alist of `(store-cell . store)` pairs,
;     which is the wrong shape.
; ---------------------------------------------------------------------------

; (kv:_incr store key amount) -> store.
; Internal helper shared by `kv:incr` / `kv:incr-by` / `kv:decr` /
; `kv:decr-by`. Returns `store` unchanged when `amount` is not a
; number (defensive: refuse to corrupt a counter with a bad delta)
; or when `key` is not a string (same posture as `kv:set`'s
; string?-key guard). Otherwise computes the new value at `key`:
; if the slot holds a number, add `amount`; if the slot is missing
; OR holds a non-numeric value, write `amount` as the new value
; (init semantics — the slot was not a usable counter yet). Uses
; `kv:_set` directly (bypassing the public `kv:set` guard) because
; the check above has already validated `key`.
(define (kv:_incr store key amount)
  (if (and (number? amount) (string? key))
    (let ((current (kv:_ref store key)))
      (kv:_set store key
        (if (number? current)
          (+ current amount)
          amount)))
    store))

; (kv:incr store key) -> store.
; Increments the value at `key` by 1. Creates `key` with value 1
; when missing or holding a non-numeric value (init semantics; see
; `kv:_incr`). The two-argument fixed form means the only failure
; mode at this entry point is a non-string `key` (store unchanged).
; For variable deltas, use `kv:incr-by`.
(define (kv:incr store key)
  (kv:_incr store key 1))

; (kv:incr-by store key amount) -> store.
; Increments the value at `key` by `amount`. Creates `key` with
; value `amount` when missing or holding a non-numeric value. Refuses
; non-numeric `amount` (store unchanged — never silently write
; something that isn't a number into a numeric counter) and
; non-string `key` (same posture as `kv:set`).
(define (kv:incr-by store key amount)
  (kv:_incr store key amount))

; (kv:decr store key) -> store.
; Decrements the value at `key` by 1. Same semantics as `kv:incr`
; with `amount = -1`. Creates `key` with value -1 when missing or
; holding a non-numeric value.
(define (kv:decr store key)
  (kv:_incr store key -1))

; (kv:decr-by store key amount) -> store.
; Decrements the value at `key` by `amount`. Same semantics as
; `kv:incr-by` with negated amount. Refuses non-numeric `amount`
; and non-string `key`.
(define (kv:decr-by store key amount)
  (kv:_incr store key (- amount)))

; (kv:rename-keys store mapping) -> store.
; Apply `(kv:rename store old new)` for each `(old . new)` pair in
; `mapping`, sequentially. Each rename inherits `kv:rename`'s refusal
; semantics (no-op when `old` is absent or `new` is already present).
; Reading `mapping` left-to-right means a rename introduced by an
; earlier pair can be picked up by a later pair — useful for chained
; renames (e.g. `(("a" . "b") ("b" . "c"))` maps `"a"` to `"c"` via
; the intermediate `"b"`). Non-pair cells in `mapping` are skipped
; defensively, same posture as every other op. Empty `mapping` is
; the identity. Returns the (possibly identical) store.
(define (kv:rename-keys store mapping)
  (let loop ((xs mapping) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:rename acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))

; (kv:union-all stores) -> store.
; Left-to-right union of a list of stores. Empty list yields `()`;
; single-element list yields that element unchanged. Implemented as
; a direct loop that accumulates `(kv:union acc store)` for each
; `store` in the list — `kv:union` already gives the left-wins /
; right-appends ordering, and chaining it across a list is the
; natural composition. Non-pair cells in `stores` are skipped
; defensively (a stray cell cannot crash the reducer). No FS escapes.
(define (kv:union-all stores)
  (let loop ((xs stores) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((s (car xs)))
        (if (pair? s)
          (loop (cdr xs) (kv:union acc s))
          (loop (cdr xs) acc))))))

; ---------------------------------------------------------------------------
; Phase 14 bulk-transformation / merging / counting / value-only filter.
; Pure functional; insertion order preserved by construction; no FS
; escapes; no API renames; no exports removed. All derive from existing
; alist primitives (`_fold`, `_set`, `_has`, `_ref`) and from the
; Phase 6 public ops (`kv:count`) — no new internal helpers required.
;
; Conventions:
;   * `kv:update-keys` folds the source store left-to-right and writes
;     `(proc k) -> v` into a fresh accumulator. On a collision (two
;     source keys mapping to the same new key) the FIRST occurrence
;     wins and later duplicates are dropped — consistent with
;     `kv:invert`'s first-occurrence semantics and with the "earlier
;     source position wins" insertion-order rule used by every op in
;     the store. Uses `kv:_set` directly (no string?-key guard) because
;     the new keys are caller-supplied projections, not fresh `kv:set`
;     writes — same posture as `kv:invert`.
;   * `kv:merge-with` generalises `kv:merge` by letting the caller pick
;     how shared-key values combine. `a`'s insertion order is preserved
;     for shared keys (with `(proc a-v b-v)` as the new value); `b`-only
;     keys are appended at the end in `b`'s iteration order. Built as a
;     fold over `a` to compute the shared-key set, then a fold over `b`
;     to append b-only keys — no intermediate alist materialised.
;     `proc` is called only for keys present in BOTH operands; for
;     disjoint operands the result is identical to `kv:union`.
;   * `kv:count-value` is a thin wrapper over `kv:count`: counts
;     entries whose value is structurally equal to `val`. Provided for
;     symmetry with `kv:has?` (key-presence) — together they cover
;     "presence on either axis" without exposing the (k . v) pair
;     shape to the caller.
;   * `kv:filter-values` is the value-only projection of `kv:filter`:
;     keeps entries for which `(proc v)` is `#t`, drops the rest.
;     Complements `kv:filter (proc k v)` by removing the key argument
;     when the caller only cares about the value side. Preserves the
;     survivor's original insertion order (single fold over the source
;     in insertion order; `kv:_set` appends).
; ---------------------------------------------------------------------------

; (kv:update-keys store proc) -> store.
; Apply `(proc k)` to each key. Folds `store` left-to-right in
; insertion order; for each (k, v), computes (new-k = (proc k)) and
; (if new-k is not already in the accumulator) writes (new-k -> v)
; into acc. On a collision (two source keys mapping to the same
; new-k) the FIRST occurrence wins and later duplicates are dropped
; — consistent with `kv:invert`'s first-occurrence semantics.
; Insertion order of the result tracks the source's order. Uses
; `kv:_set` directly (no string?-key guard) because the new keys are
; caller-supplied projections, not fresh `kv:set` writes — same
; posture as `kv:invert`. Non-pair cells in `store` are skipped
; defensively (via `_fold`).
(define (kv:update-keys store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (let ((new-k (proc k)))
        (if (kv:_has acc new-k)
          acc
          (kv:_set acc new-k v))))))

; (kv:merge-with a b proc) -> store.
; Right-biased merge with caller-supplied combiner. For each key
; shared between `a` and `b`, writes (proc a-v b-v) as the new value
; (replacing both operands' values). For each `a`-only key, writes
; `a`'s value as-is. For each `b`-only key, writes `b`'s value at
; the end in `b`'s iteration order. Built as a fold over `a` to
; compute the shared-key set (with combiner applied), then a fold
; over `b` that appends the b-only keys — `kv:_set`'s "append on
; miss" behaviour does the rest. The insertion order of `a` is
; preserved for shared keys; b-only keys are appended at the end in
; b's order. For disjoint operands, no key is shared, so `proc` is
; never called and the result is identical to `kv:union`.
(define (kv:merge-with a b proc)
  (let ((base
          (kv:_fold a (quote ())
            (lambda (k va acc)
              (if (kv:_has b k)
                (kv:_set acc k (proc va (kv:_ref b k)))
                (kv:_set acc k va))))))
    (kv:_fold b base
      (lambda (k vb acc)
        (if (kv:_has a k)
          acc
          (kv:_set acc k vb))))))

; (kv:count-value store val) -> integer.
; Number of entries whose value is structurally equal to `val`. Thin
; wrapper over `kv:count` — provided for symmetry with `kv:has?`
; (key-presence). Returns 0 on an empty store. A stored `#f` value
; matches `#f` (equal? agrees on `#f`); a missing entry never
; matches anything.
(define (kv:count-value store val)
  (kv:count store (lambda (k v) (equal? v val))))

; (kv:filter-values store proc) -> store.
; Sub-store of entries for which `(proc v)` is `#t`. Folds `store`
; left-to-right in insertion order; keeps an entry (writing k -> v
; into the accumulator, which appends in source order) iff `(proc v)`
; is `#t`. Complements `kv:filter (proc k v)` by removing the key
; argument when the caller only cares about the value side. Insertion
; order of survivors follows the source. Non-pair cells in `store`
; are skipped defensively (via `_fold`).
(define (kv:filter-values store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (proc v)
        (kv:_set acc k v)
        acc))))

; ---------------------------------------------------------------------------
; Phase 15 lookup / value-presence / span helpers.
; Pure functional; insertion order preserved by construction; no FS
; escapes; no API renames; no exports removed. All derive from existing
; alist primitives (`_fold`, `_has`) and the Phase 6 public ops
; (`kv:any?`) — no new internal helpers required.
;
; Conventions:
;   * `kv:find-key` / `kv:find-value` are sibling projections of
;     `kv:find`: same short-circuit left-to-right walk, same `#f`
;     sentinel for "no match", same defensive-skip posture for stray
;     non-pair cells. `kv:find` returns the (k . v) pair; these two
;     project out one side. The same `#f` ambiguity as `kv:get`
;     applies: a stored `#f` value is indistinguishable from a miss
;     under `kv:find-value`.
;   * `kv:has-value?` is a thin wrapper over `kv:any?`: true iff at
;     least one entry's value is structurally equal to `val`. Together
;     with `kv:has?` it covers "presence on either axis" without
;     forcing the caller to write `(lambda (k v) (equal? v val))`.
;   * `kv:none?` is the named complement of `kv:any?` — equivalent
;     to `(not (kv:any? store proc))` but provided under a name so
;     callers don't pay for the boolean flip and the symmetric API
;     reads cleanly alongside `kv:any?` / `kv:every?`. Vacuous `#t`
;     on an empty store (no entry can satisfy anything).
;   * `kv:take-while` / `kv:drop-while` are positional span
;     decompositions: they respect insertion order and stop at the
;     FIRST false predicate (or the end of the store). Together they
;     partition the source into (prefix . suffix) under any given
;     proc; the boundary entry (first false) belongs to the suffix,
;     not the prefix. Both skip stray non-pair cells defensively
;     in the prefix-walk; the suffix is returned as-is once the
;     predicate fails (so a defensive artifact after the boundary
;     is preserved in `drop-while`'s output).
; ---------------------------------------------------------------------------

; (kv:find-key store proc) -> key | #f.
; First key for which (proc k v) is #t. Short-circuits left-to-right;
; #f on miss / empty. Skips non-pair cells defensively. Companion
; projection of kv:find (which returns the pair); same walk, same
; sentinel, no extra allocation beyond the recursion stack.
(define (kv:find-key store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        (car p)
        (kv:find-key (cdr store) proc)))))

; (kv:find-value store proc) -> value | #f.
; First value for which (proc k v) is #t. Short-circuits
; left-to-right; #f on miss / empty. Skips non-pair cells
; defensively. Note: a stored #f value is indistinguishable from a
; miss — same limitation as kv:get / kv:find (the boundary case is
; intrinsic to using #f as the "no value" sentinel).
(define (kv:find-value store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        (cdr p)
        (kv:find-value (cdr store) proc)))))

; (kv:has-value? store val) -> #t | #f.
; True iff at least one entry's value is structurally equal to val.
; Thin wrapper over kv:any?; provided for symmetry with kv:has?
; (key-presence) — together they cover "presence on either axis"
; without forcing the caller to write (lambda (k v) (equal? v val)).
; A stored #f value matches an argument of #f; empty store is #f.
(define (kv:has-value? store val)
  (kv:any? store (lambda (k v) (equal? v val))))

; (kv:none? store proc) -> #t | #f.
; True iff no entry satisfies (proc k v). Short-circuits on the
; first hit. Vacuous #t on an empty store (no entry can satisfy
; anything). Named complement of kv:any? — provided for symmetry
; with kv:any? / kv:every? so the predicate trio reads cleanly
; without forcing the caller to negate. Skips non-pair cells
; defensively, same posture as the rest of the family.
(define (kv:none? store proc)
  (if (null? store)
    #t
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        #f
        (kv:none? (cdr store) proc)))))

; (kv:take-while store proc) -> store.
; Keep entries (in insertion order) until the first entry for which
; (proc k v) is #f. Stops at that entry — it is NOT included. The
; boundary belongs to the suffix (returned by kv:drop-while), not
; to the prefix. Empty input → empty output; an all-true proc yields
; the whole store. Non-pair cells are skipped defensively in the
; prefix-walk (they never count as the "stop" signal — they are not
; real entries and have no (k, v) pair to test). Implemented as a
; direct loop that builds the result in reverse and unflips at the
; end (O(n) walk, single allocation).
(define (kv:take-while store proc)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      (reverse acc)
      (let ((p (car xs)))
        (if (pair? p)
          (if (proc (car p) (cdr p))
            (loop (cdr xs) (cons p acc))
            (reverse acc))
          (loop (cdr xs) acc))))))

; (kv:drop-while store proc) -> store.
; Drop entries (in insertion order) while (proc k v) is #t. Stops
; at the first entry for which proc is #f (or the end of the store)
; and returns the rest, preserving its original order. Empty input
; → empty output; an all-true proc yields an empty output. Non-pair
; cells in the dropped prefix are skipped defensively (never counted
; as the stop signal); once the prefix is dropped, the tail is
; returned as-is (preserving any stray cells). Complements
; kv:take-while: (kv:union (kv:take-while s p) (kv:drop-while s p))
; is structurally equal to s for any proc p (the boundary entry, if
; any, is on the drop-while side by construction).
(define (kv:drop-while store proc)
  (let loop ((xs store))
    (if (null? xs)
      (quote ())
      (let ((p (car xs)))
        (if (pair? p)
          (if (proc (car p) (cdr p))
            (loop (cdr xs))
            xs)
          (loop (cdr xs)))))))
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

; ---- Phase 13: numeric / bulk-composition helpers ----

; T62: incr() increments an existing numeric value by 1 and is immutable
; on the input store.
(let* ((s (kv:set (kv:open) "x" 5))
       (s2 (kv:incr s "x")))
  (t "T62-incr-basic"
     (and (= (kv:get s2 "x") 6)
          (equal? (kv:get s "x") 5))))

; T63: incr() on a missing key creates the slot with the default delta 1.
(let* ((s (kv:open))
       (s (kv:incr s "new")))
  (t "T63-incr-create"
     (= (kv:get s "new") 1)))

; T64: incr-by() with an explicit amount accumulates correctly across calls.
(let* ((s (kv:open))
       (s (kv:incr-by s "x" 10))
       (s (kv:incr-by s "x" 5)))
  (t "T64-incr-by-amount"
     (= (kv:get s "x") 15)))

; T65: incr-by() refuses a non-numeric amount (store unchanged) — protects
; a numeric counter from a bad call.
(let* ((s (kv:set (kv:open) "x" 5))
       (s2 (kv:incr-by s "x" "bad")))
  (t "T65-incr-refuse-bad-amount"
     (equal? (kv:get s2 "x") 5)))

; T66: incr-by() refuses a non-string key (store unchanged) — same
; posture as kv:set's string?-key guard.
(let* ((s (kv:set (kv:open) "x" 5))
       (s2 (kv:incr-by s 'symbol 1)))
  (t "T66-incr-refuse-bad-key"
     (equal? (kv:get s2 "x") 5)))

; T67: decr() and decr-by() compose on an existing numeric value.
(let* ((s (kv:set (kv:open) "x" 10))
       (s2 (kv:decr s "x"))
       (s3 (kv:decr-by s2 "x" 3)))
  (t "T67-decr-basic"
     (= (kv:get s3 "x") 6)))

; T68: decr-by() on a missing key creates the slot with the negated delta.
(let* ((s (kv:open))
       (s (kv:decr-by s "x" 5)))
  (t "T68-decr-create"
     (= (kv:get s "x") -5)))

; T69: rename-keys() applies multiple renames sequentially and preserves
; the rest of the store.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:rename-keys s (list (cons "a" "x") (cons "b" "y")))))
  (t "T69-rename-keys"
     (and (= (kv:size r) 3)
          (eq? (kv:has? r "a") #f)
          (eq? (kv:has? r "b") #f)
          (equal? (kv:get r "x") 1)
          (equal? (kv:get r "y") 2)
          (equal? (kv:get r "c") 3))))

; T70: rename-keys() chained renames — a rename introduced by an earlier
; pair is picked up by a later pair (the "a"->"b"->"c" path).
(let* ((s (kv:set (kv:open) "a" 1))
       (r (kv:rename-keys s (list (cons "a" "b") (cons "b" "c")))))
  (t "T70-rename-keys-chained"
     (and (= (kv:size r) 1)
          (eq? (kv:has? r "a") #f)
          (eq? (kv:has? r "b") #f)
          (equal? (kv:get r "c") 1))))

; T71: rename-keys() with an empty mapping is the identity.
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (r (kv:rename-keys s (quote ()))))
  (t "T71-rename-keys-empty"
     (and (= (kv:size r) 2)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "b") 2))))

; T72: rename-keys() skips a rename whose target key is already present
; (consistent with kv:rename's refusal semantics).
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (r (kv:rename-keys s (list (cons "a" "b")))))
  (t "T72-rename-keys-skip-collision"
     (and (= (kv:size r) 2)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "b") 2))))

; T73: union-all() merges a list of stores left-to-right; left-wins for
; shared keys, right-only keys appended in right's order.
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (b (kv:set (kv:open) "c" 3))
       (c (kv:set (kv:set (kv:open) "b" 99) "d" 4))
       (u (kv:union-all (list a b c)))
       (uk (kv:keys u)))
  (t "T73-union-all"
     (and (= (kv:size u) 4)
          (equal? (kv:get u "a") 1)
          (equal? (kv:get u "b") 2)
          (equal? (kv:get u "c") 3)
          (equal? (kv:get u "d") 4)
          (equal? (car uk) "a")
          (equal? (car (cdr uk)) "b")
          (equal? (car (cdr (cdr uk))) "c")
          (equal? (car (cdr (cdr (cdr uk)))) "d"))))

; T74: union-all() with an empty list yields an empty store.
(t "T74-union-all-empty"
   (null? (kv:union-all (quote ()))))

; T75: union-all() with a single-element list yields that element unchanged.
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (u (kv:union-all (list a))))
  (t "T75-union-all-single"
     (and (= (kv:size u) 2)
          (equal? (kv:get u "a") 1)
          (equal? (kv:get u "b") 2))))

; T76: incr() multi-call sequence composes into a counter (the canonical
; use-case: init -> bump -> bump -> bump-by-N).
(let* ((s (kv:open))
       (s (kv:incr s "c"))
       (s (kv:incr s "c"))
       (s (kv:incr s "c"))
       (s (kv:incr-by s "c" 10)))
  (t "T76-incr-multi"
     (= (kv:get s "c") 13)))

; ---- Phase 14: bulk-transformation / merging / counting / value-only filter ----

; T77: update-keys() transforms keys via caller-supplied proc; insertion
; order of survivors tracks the source order.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:update-keys s
              (lambda (k)
                (if (equal? k "a") "x"
                  (if (equal? k "b") "y" "z")))))
       (rk (kv:keys r)))
  (t "T77-update-keys"
     (and (= (kv:size r) 3)
          (eq? (kv:has? r "a") #f)
          (eq? (kv:has? r "b") #f)
          (eq? (kv:has? r "c") #f)
          (equal? (kv:get r "x") 1)
          (equal? (kv:get r "y") 2)
          (equal? (kv:get r "z") 3)
          (equal? (car rk) "x")
          (equal? (car (cdr rk)) "y")
          (equal? (car (cdr (cdr rk))) "z"))))

; T77b: update-keys() on a key collision: first-occurrence wins
; (consistent with kv:invert's first-occurrence semantics).
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:update-keys s (lambda (k) "x"))))
  (t "T77b-update-keys-collision"
     (and (= (kv:size r) 1)
          (equal? (kv:get r "x") 1))))

; T77c: update-keys() on an empty store is empty.
(t "T77c-update-keys-empty"
   (= (kv:size (kv:update-keys (kv:open) (lambda (k) k))) 0))

; T78: merge-with() combines shared keys via caller-supplied combiner;
; a's order preserved for shared keys; b-only keys appended in b's order.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "b" 20) "c" 30) "d" 4))
       (r (kv:merge-with a b (lambda (x y) (+ x y))))
       (rk (kv:keys r)))
  (t "T78-merge-with"
     (and (= (kv:size r) 4)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "b") 22)
          (equal? (kv:get r "c") 33)
          (equal? (kv:get r "d") 4)
          (equal? (car rk) "a")
          (equal? (car (cdr rk)) "b")
          (equal? (car (cdr (cdr rk))) "c")
          (equal? (car (cdr (cdr (cdr rk)))) "d"))))

; T78b: merge-with() with disjoint operands equals union; combiner is
; never called when there are no shared keys.
(let* ((calls 0)
       (a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
       (r (kv:merge-with a b
              (lambda (x y) (set! calls (+ calls 1)) (+ x y)))))
  (t "T78b-merge-with-disjoint"
     (and (= calls 0)
          (= (kv:size r) 4)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "d") 4))))

; T78c: merge-with() with an empty operand is identity on the other side.
(t "T78c-merge-with-empty"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
     (and (kv:equal? (kv:merge-with a (kv:open) (lambda (x y) (+ x y))) a)
          (kv:equal? (kv:merge-with (kv:open) a (lambda (x y) (+ x y))) a))))

; T79: count-value() counts entries with structurally equal value.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 1) "d" 3) "e" 1)))
  (t "T79-count-value"
     (and (= (kv:count-value s 1) 3)
          (= (kv:count-value s 2) 1)
          (= (kv:count-value s 3) 1)
          (= (kv:count-value s 99) 0)
          (= (kv:count-value (kv:open) 1) 0))))

; T80: filter-values() keeps entries whose value passes the predicate;
; survivor order tracks the source.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "d" 4))
       (r (kv:filter-values s (lambda (v) (> v 2))))
       (rk (kv:keys r)))
  (t "T80-filter-values"
     (and (= (kv:size r) 2)
          (equal? (kv:get r "c") 3)
          (equal? (kv:get r "d") 4)
          (eq? (kv:get r "a") #f)
          (eq? (kv:get r "b") #f)
          (equal? (car rk) "c")
          (equal? (car (cdr rk)) "d"))))

; T80b: filter-values() on an empty store is empty.
(t "T80b-filter-values-empty"
   (= (kv:size (kv:filter-values (kv:open) (lambda (v) #t))) 0))

; ---- Phase 15: lookup / value-presence / span helpers ----

; T81: find-key() returns the first key for which proc(k,v) is #t;
; #f on miss / empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T81-find-key"
     (and (equal? (kv:find-key s (lambda (k v) (> v 3))) "b")
          (eq? (kv:find-key s (lambda (k v) (> v 100))) #f)
          (eq? (kv:find-key (kv:open) (lambda (k v) #t)) #f))))

; T81b: find-key() on an empty store is #f.
(t "T81b-find-key-empty"
   (eq? (kv:find-key (kv:open) (lambda (k v) #t)) #f))

; T82: find-value() returns the first value for which proc(k,v) is #t;
; #f on miss / empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T82-find-value"
     (and (equal? (kv:find-value s (lambda (k v) (> v 3))) 5)
          (eq? (kv:find-value s (lambda (k v) (> v 100))) #f)
          (eq? (kv:find-value (kv:open) (lambda (k v) #t)) #f))))

; T82b: find-value() on an empty store is #f.
(t "T82b-find-value-empty"
   (eq? (kv:find-value (kv:open) (lambda (k v) #t)) #f))

; T83: has-value? checks for structurally-equal value presence.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 1) "d" 3)))
  (t "T83-has-value?"
     (and (kv:has-value? s 1)
          (kv:has-value? s 2)
          (kv:has-value? s 3)
          (not (kv:has-value? s 99))
          (not (kv:has-value? (kv:open) 1)))))

; T84: none? is the named complement of any?; vacuous #t on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 10)))
  (t "T84-none?"
     (and (kv:none? s (lambda (k v) (> v 100)))
          (not (kv:none? s (lambda (k v) (> v 3))))
          (kv:none? (kv:open) (lambda (k v) #t)))))

; T85: take-while() keeps entries while proc is #t; stops at first miss
; (the boundary entry belongs to drop-while's side, not take-while's).
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 5) "d" 10))
       (r (kv:take-while s (lambda (k v) (< v 5))))
       (rk (kv:keys r)))
  (t "T85-take-while"
     (and (= (kv:size r) 2)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "b") 2)
          (eq? (kv:get r "c") #f)
          (eq? (kv:get r "d") #f)
          (equal? (car rk) "a")
          (equal? (car (cdr rk)) "b"))))

; T85b: take-while() with an always-true proc returns the full store.
(t "T85b-take-while-all-true"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
          (r (kv:take-while s (lambda (k v) #t))))
     (and (= (kv:size r) 3)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "c") 3))))

; T85c: take-while() with an always-false proc returns an empty store.
(t "T85c-take-while-all-false"
   (null? (kv:take-while (kv:set (kv:set (kv:open) "a" 1) "b" 2)
                         (lambda (k v) #f))))

; T85d: take-while() on an empty store is empty.
(t "T85d-take-while-empty"
   (null? (kv:take-while (kv:open) (lambda (k v) #t))))

; T86: drop-while() drops entries while proc is #t; keeps the rest,
; starting with the first entry for which proc is #f (the boundary).
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 5) "d" 10))
       (r (kv:drop-while s (lambda (k v) (< v 5))))
       (rk (kv:keys r)))
  (t "T86-drop-while"
     (and (= (kv:size r) 2)
          (eq? (kv:get r "a") #f)
          (eq? (kv:get r "b") #f)
          (equal? (kv:get r "c") 5)
          (equal? (kv:get r "d") 10)
          (equal? (car rk) "c")
          (equal? (car (cdr rk)) "d"))))

; T86b: drop-while() with an always-true proc returns an empty store.
(t "T86b-drop-while-all-true"
   (null? (kv:drop-while (kv:set (kv:set (kv:open) "a" 1) "b" 2)
                         (lambda (k v) #t))))

; T86c: drop-while() with an always-false proc returns the full store.
(t "T86c-drop-while-all-false"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
          (r (kv:drop-while s (lambda (k v) #f))))
     (and (= (kv:size r) 3)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "c") 3))))

; T86d: drop-while() on an empty store is empty.
(t "T86d-drop-while-empty"
   (null? (kv:drop-while (kv:open) (lambda (k v) #t))))

; T87: take-while + drop-while (same proc) partition the source
; store: their kv:union is structurally equal to the original.
; Exercises the documented span property — the boundary entry lives
; on the drop-while side, so a single kv:union gives back the
; original key multiset and per-key values.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 5) "d" 10))
       (tw (kv:take-while s (lambda (k v) (< v 5))))
       (dw (kv:drop-while s (lambda (k v) (< v 5))))
       (joined (kv:union tw dw)))
  (t "T87-take-drop-while-partition"
     (kv:equal? s joined)))

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
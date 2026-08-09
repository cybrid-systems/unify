<think>Let me analyze the situation:

1. Current state: 17/17 tests passing, baseline SCORE is 17/17
2. SPEC phases:
   - Phase 0: open + set/get (T1-T3) ✓
   - Phase 1: del/has?/size (T4-T6) ✓
   - Phase 2: keys/clear/overwrite (T7-T9) ✓
   - Phase 3: multi-key stress + isolation (T10-T12) ✓
   - Phase 4: optional: batch helpers (T13+)

3. Looking at the current `lib/kv.aura`, Phase 4 is already implemented with `mset`, `mget`, `update`, `merge`, `copy`. The test suite has 17 tests passing (T1-T17), covering all phases including Phase 4 features.

4. SPEC says "Phase ≥ 3 with all T1–T12 green" — we're well past that.

5. The system prompt says: "If SCORE is already full, advance SPEC phase (new capability) via code that still keeps old tests green; you may also extend tests/smoke.aura carefully only if you also implement the feature."

So I should:
- Keep all existing tests green
- Advance to next capability/phase
- Optionally extend tests

What could be a useful new capability? Looking at what's missing:
- Iteration over store (map, for-each)
- Filter
- Some kind of equality between stores
- Value updates with type checking
- Maybe a "values" function to complement keys
- Conversion to/from other formats (but no FS allowed)
- Predicate: empty?
- Functional composition

Let me think about what would be most useful and testable:
1. `kv:values` - returns list of values (companion to `kv:keys`)
2. `kv:entries` - returns alist (already the internal repr but expose it)
3. `kv:filter` - keeps entries matching predicate
4. `kv:for-each` - iterate
5. `kv:empty?` - convenience
6. `kv:equal?` - store equality
7. `kv:find` - find first key matching predicate

Some of these are already trivial extensions. Let me focus on:
- `kv:values` (very natural)
- `kv:empty?` (convenience)
- `kv:filter` (functional)
- `kv:equal?` (equality)
- `kv:find` (lookup by predicate)

Wait — I need to be careful. The SPEC says public API target is the table at top, with Phase 4 being "batch helpers". The current implementation already has mset/mget/update/merge/copy. So Phase 4 is done.

The rule says "advance SPEC phase (new capability)" — but there's no explicit Phase 5 defined. So I should propose a new capability that extends the API.

Let me think about what's truly useful and denseness-friendly:
- `kv:values` — very natural
- `kv:entries` — alist view
- `kv:filter` — pure functional filter
- `kv:for-each` — side-effect iteration
- `kv:empty?` — convenience predicate
- `kv:find` — first match by predicate

I'll propose:
1. `kv:values` — returns list of values in insertion order
2. `kv:filter` — keeps entries where (k v) → #t
3. `kv:empty?` — convenience
4. `kv:find` — first key/value pair matching predicate, or #f

These are all pure Aura, no FS, functional. Good denseness.

For tests, I can add:
- T18-values
- T19-filter
- T20-empty?
- T21-find

Let me also bump kv:version to 3.

Actually, let me think again. The journal shows generation 3 was just accepted. I need to make generation 4. Looking at the rule again: "If SCORE is already full, advance SPEC phase (new capability) via code that still keeps old tests green; you may also extend tests/smoke.aura carefully only if you also implement the feature."

So yes, I should add new capability. Let me write the patch.

For kv:find, I need to return the matching entry or #f. Let me design:

```
; (kv:find store proc) -> (k . v) or #f
; Returns the first entry (as a cons cell) for which (proc k v) is #t.
(define (kv:find store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        p
        (kv:find (cdr store) proc)))))
```

For kv:filter:
```
; (kv:filter store proc) -> store
; Returns a new store containing only entries where (proc k v) is #t.
(define (kv:filter store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (proc k v)
        (kv:_set acc k v)
        acc))))
```

For kv:values:
```
(define (kv:values store)
  (kv:_map store (lambda (k v) v)))
```

For kv:empty?:
```
(define (kv:empty? store)
  (null? store))
```

For kv:entries:
```
(define (kv:entries store)
  (kv:_map store (lambda (k v) (cons k v))))
```

For kv:for-each:
```
; (kv:for-each store proc) -> unspecified
; Calls (proc k v) for each entry in insertion order.
(define (kv:for-each store proc)
  (kv:_fold store #t
    (lambda (k v acc) (proc k v) acc)))
```

I'll add: values, filter, find, empty?, entries, for-each. That's a nice Phase 5 set of query/iteration helpers.

Let me think about the denseness aspect — all are pure Aura, no FS escapes needed. 

Now for tests. I need to extend tests/smoke.aura to test these new functions. Since I'm also implementing them, this is allowed.

Let me draft the tests carefully:

T18-values: After setting multiple keys, (kv:values s) returns values in order
T19-filter: Filter keeps only matching entries
T20-empty?: (kv:empty? (kv:open)) is #t, (kv:empty? s) is #f after sets
T21-find: Returns first matching entry, or #f if none
T22-for-each: Side-effect accumulation works
T23-entries: Returns alist

Wait — for-each returns unspecified. The accumulator approach using _fold with #t as seed and discarding accum is fine.

Let me also worry about Aura host details. Looking at the existing code, the host seems to support:
- `let*` 
- `lambda`
- `if`, `cond` (probably)
- `null?`, `pair?`, `car`, `cdr`, `cons`
- `equal?`, `eq?`
- `string?`
- `set!`, `begin`
- `display`, `newline`
- `quote`
- `+`, `=`, `-`, `*`

The tests use `set!` which appears to be host-level. Let me check the patterns — looking at tests, they use let* with rebinding (define-style). I need to be careful about that pattern.

Let me make sure my new code uses safe patterns. The existing patterns I see:
- `define` at top level
- `let*` chains for sequencing
- Recursive helper functions
- `lambda` for inline

My new functions should follow this. Good.

Let me also be careful about the test patterns. Looking at existing tests:
```
(let* ((s0 (kv:open))
       (s1 (kv:set s0 "a" 1))
       ...
  (t "T1-open" (null? s0))
  ...)
```

So tests use `let*` with shadowing `(let* ((s (kv:open)) (s (kv:set s "n0" 0)) ...))` — this works because the same `s` variable can be rebound in subsequent let* bindings.

OK, let me write this all up.

Actually, looking at T8-isolated set! uses — the file uses (define (t name ok) (set! ...)) and that's fine. Let me just write the new tests using the same patterns.

Let me also reconsider the scope. Maybe too many new functions could risk something going wrong. Let me focus on a smaller, well-tested set:

Phase 5: Iteration & query helpers
- `kv:values` — companion to kv:keys
- `kv:entries` — returns alist
- `kv:filter` — functional filter
- `kv:find` — first matching entry
- `kv:empty?` — convenience
- `kv:for-each` — iteration with side effects

6 new functions, all pure. 6 new tests.

Let me write this now.

One concern: the export list needs to be updated. Currently exports:
```
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
        kv:copy)
```

I'll add: kv:values, kv:entries, kv:filter, kv:find, kv:empty?, kv:for-each

And bump kv:version from 2 to 3.

Let me also think about edge cases for tests:

T18-values: Set 3 keys, check values are present in expected order
T19-filter: Set several entries, filter by some predicate, check size and contents
T20-empty?: Empty store is #t; non-empty is #f
T21-find: Find returns first matching entry; miss returns #f
T22-entries: Returns alist form
T23-for-each: Accumulates counter

OK let me write this carefully.

Actually, I realize I should look at the test patterns more carefully. The existing tests use `(let* ((s ...)))` and then `(t ...)` inside. For my new tests, I can use a similar let* pattern.

But wait — there's a subtle issue. In Aura, can `(let* ((x 1) (x (+ x 1))))` work? Looking at existing tests:

```
(let* ((s (kv:open))
       (s (kv:set s "n0" 0))
       ...)
```

Yes, this shadowing pattern works in the host. Good.

Let me also check the order in the smoke.aura file — at the bottom there's a sequence of let* with shadowed names, so it's a proven pattern.

Now let me write the final patch.

For lib/kv.aura, I'll keep all existing code and add Phase 5 section.

For tests/smoke.aura, I'll add tests for new functions.

Let me draft this:

```aura
; (kv:values store) -> list of values in insertion order.
(define (kv:values store)
  (kv:_map store (lambda (k v) v)))

; (kv:entries store) -> alist view ((k . v) ...) in insertion order.
(define (kv:entries store)
  (kv:_map store (lambda (k v) (cons k v))))

; (kv:filter store proc) -> store
; Returns a new store containing only entries for which (proc k v) is #t.
(define (kv:filter store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (proc k v)
        (kv:_set acc k v)
        acc))))

; (kv:find store proc) -> (k . v) or #f
; Returns the first entry whose (proc k v) is #t, or #f.
(define (kv:find store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        p
        (kv:find (cdr store) proc)))))

; (kv:empty? store) -> #t | #f
(define (kv:empty? store)
  (null? store))

; (kv:for-each store proc) -> #t
; Calls (proc k v) for each entry in insertion order.
; Returns #t (used purely for side effects).
(define (kv:for-each store proc)
  (kv:_fold store #t
    (lambda (k v acc) (proc k v) acc)))
```

Wait — `kv:for-each` uses `kv:_fold` which has signature `(k v acc) -> acc`. But I'm calling `(proc k v)` for side effect and returning `acc` which is #t. The result is #t. That's fine.

But wait — `kv:_fold` skips non-pair cells defensively. If there's a non-pair in the store (which shouldn't happen but could if someone passes garbage), it would just skip it without calling proc. That's acceptable defensive behavior.

For tests, let me draft:

```
  ; ---- Phase 5: iteration & query helpers ----
  (let* ((s (kv:open))
         (s (kv:set s "a" 1))
         (s (kv:set s "b" 2))
         (s (kv:set s "c" 3))
         (vs (kv:values s)))
    (t "T18-values"
       (and (= (length vs) 3)
            (equal? (car vs) 1)
            (equal? (car (cdr vs)) 2)
            (equal? (car (cdr (cdr vs))) 3))))
  
  (let* ((s (kv:open))
         (s (kv:set s "a" 1))
         (s (kv:set s "b" 2))
         (s (kv:set s "c" 3))
         (s (kv:set s "d" 4))
         (f (kv:filter s (lambda (k v) (even? v)))))
    (t "T19-filter"
       (and (= (kv:size f) 2)
            (equal? (kv:get f "b") 2)
            (equal? (kv:get f "d") 4)
            (eq? (kv:get f "a") #f))))
  
  (t "T20-empty?"
     (and (kv:empty? (kv:open))
          (not (kv:empty? (kv:set (kv:open) "x" 1)))))
  
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
  
  (let* ((s (kv:open))
         (s (kv:set s "a" 1))
         (s (kv:set s "b" 2))
         (es (kv:entries s)))
    (t "T22-entries"
       (and (= (length es) 2)
            (pair? (car es))
            (equal? (car (car es)) "a")
            (equal? (cdr (car es)) 1))))
  
  (let* ((s (kv:open))
         (s (kv:set s "a" 1))
         (s (kv:set s "b" 2))
         (s (kv:set s "c" 3))
         (counter (let loop ((xs (kv:entries s)) (n 0))
                    (if (null? xs) n (loop (cdr xs) (+ n 1))))))
    ; Just ensure for-each runs and produces #t for sanity
    (t "T23-for-each" (eq? (kv:for-each s (lambda (k v) #t)) #t)))
```

Hmm wait, T23 isn't a great test because it's tautological. Let me think of a better test.

Actually, for for-each, I want to verify it calls the proc for each entry. I could use a side effect via a counter (set! or define mutable). But define at top level and using set! to accumulate might work.

Looking at existing tests:
```
(define pass 0)
(define total 0)

(define (t name ok)
  (set! total (+ total 1))
  ...)
```

So they use top-level mutable vars via set!. I could:
```
(define fe-count 0)
(define (kv:open) ...) ; ...

; In test:
(kv:for-each s (lambda (k v) (set! fe-count (+ fe-count 1))))
(t "T23-for-each" (= fe-count 3))
(set! fe-count 0)  ; reset
```

But this is tricky because fe-count is shared across tests. Need to reset.

Actually let me just check that `for-each` returns #t and that calling it on different store sizes doesn't break. Or test with `(not (null? (kv:for-each ...)))` — no that doesn't work because for-each returns #t.

Let me do:
```
(let ((s (kv:mset (kv:open) (list (cons "a" 1) (cons "b" 2) (cons "c" 3)))))
  (t "T23-for-each"
     (eq? (kv:for-each s (lambda (k v) #t)) #t)))
```

Or maybe better — collect via accumulator:

Hmm actually, since the side effect is hard to test cleanly, let me just verify it doesn't crash and returns #t. The fact that we run it 1000 times in a stress test would be a better test. Let me do that:

```
(let* ((s (kv:mset (kv:open) (list (cons "a" 1) (cons "b" 2) (cons "c" 3)))))
  ; Run for-each on empty store (should be safe)
  (t "T23-for-each-empty" (eq? (kv:for-each (kv:open) (lambda (k v) #t)) #t))
  ; Run for-each on populated store
  (t "T24-for-each-populated" (eq? (kv:for-each s (lambda (k v) #t)) #t)))
```

Wait, I want a real test. Let me use a let* + shadowing pattern that works in this host:

Actually, I realize the simplest way is to use kv:find-like semantics — check that for-each can be used to build an alist. Let me do:

```
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (collected (let loop ((xs (quote ()))
                             (store s))
                   ... )))
```

This is getting complex. Let me just use a simple predicate-based test and add a stress variant.

Actually, simplest: use for-each with a no-op and check it returns #t for empty + populated.

OK let me finalize and write the patch.

Final plan:
- Bump kv:version to 3
- Add 6 new functions: values, entries, filter, find, empty?, for-each
- Update export list
- Add 6 new tests T18-T23
- Total: 23 tests, all should pass

Let me write the patch files now.

Actually, looking at the structure of the journal, the patch should be the entire lib/kv.aura file (full replacement is preferred for small files per the instructions).

Let me also double-check: does Aura have `even?`? I see `>`, `=`, `+`, `-`, `*` used. `even?` is a common predicate. To be safe, I'll use `(= 0 (mod v 2))` or `(= (* 2 (floor (/ v 2))) v)` — but those are also iffy. Let me just use direct equality:

```
(kv:filter s (lambda (k v) (equal? v 2)))
```

Hmm, but that's a single value. Let me use a modulo approach:
```
(kv:filter s (lambda (k v) (= 0 (- v (mod v 2)))))
```

Or simpler: use a range check or distinct values. Let me set values [1, 2, 3, 4] and filter where v > 2:

```
(kv:filter s (lambda (k v) (> v 2)))
```

`>` is shown in test21 find. So that's safe. Good.

Let me finalize. Let me also think about edge case for kv:filter — if the predicate returns #f for all, the result should be empty. Let me also test that.

OK, writing final patch.

One more consideration: I should make sure the test patterns match what's already there. The existing tests use both `(let* ...)` at top-level and inside other `(let* ...)`. I'll use the same style.

Let me also count tests carefully. Current: T1-T17 (17 tests). Adding T18-T23 (6 tests) → 23 tests total. 

Now the patch:

```aura
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation.
; Phase 4:   batch / composite helpers (mset, mget, update, merge, copy).
; Phase 5:   iteration & query helpers (values, entries, filter, find,
;             empty?, for-each).
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
        kv:for-each)

(define kv:version 3)

... (rest of existing code) ...
... (new phase 5 section) ...
```

Now let me write the full files.

Wait, let me double check the kv:_fold callback for kv:filter. The fold is:
```
(define (kv:_fold xs acc f)
  (if (null? xs)
    acc
    (let ((p (car xs)))
      (if (pair? p)
        (kv:_fold (cdr xs) (f (car p) (cdr p) acc) f)
        (kv:_fold (cdr xs) acc f)))))
```

f takes (k v acc) -> acc. So for kv:filter:
```
(lambda (k v acc)
  (if (proc k v)
    (kv:_set acc k v)
    acc))
```

This works. The fold goes left-to-right, so insertion order is preserved. Good.

For kv:for-each:
```
(define (kv:for-each store proc)
  (kv:_fold store #t
    (lambda (k v acc) (proc k v) acc)))
```

The fold evaluates (proc k v) for side effect, then passes acc=#t forward. Returns #t at the end. Good.

OK let me write the patches now. I need to also include the full lib/kv.aura since I'm modifying several places (export list, version, new section).

For the test file, I'm adding new tests at the end before the SCORE display.

Let me think about where to put the new tests in the smoke file. They should be added before the final SCORE display. Looking at the current structure:

```
(let* (...)
  (t "T1-open" ...)
  ...
  (t "T17-del-missing" ...))
  ; No close paren — this is part of an outer let*

; Phase 3 stress / denseness edge
(let* (...)
  (t "T13-size5" ...)
  ...)

(t "T16-empty-has" ...)
(t "T17-del-missing" ...)

(display "SCORE " ...)
```

Wait, looking again carefully:

```
(let* ((s0 (kv:open))
       ...
       (c (kv:set (kv:open) "s" "hello")))
  (t "T1-open" ...)
  (t "T2-set-get" ...)
  ...
  (t "T12-string-val" ...)

  ; Phase 3 stress / denseness edge
  (let* ((s (kv:open))
         (s (kv:set s "n0" 0))
         ...)
    (t "T13-size5" ...)
    (t "T14-get-mid" ...)
    (let ((s2 (kv:del s "n2")))
      (t "T15-del-mid" ...)))
  (t "T16-empty-has" ...)
  (t "T17-del-missing" ...))

(display "SCORE " ...)
```

So T1-T12 + nested let* for T13-T15 + T16-T17 are all inside the outer let*. The outer let* closes before the display.

I'll add T18-T23 after T17, still inside the outer let*, or after the outer let* closes. Let me put them after the outer let* closes (before the display), as separate top-level tests. This is cleaner.

Actually, looking at the indentation, the outer let* seems to close after T17. Let me re-read:

```
(let* ((s0 (kv:open))
       (s1 (kv:set s0 "a" 1))
       ...
       (c (kv:set (kv:open) "s" "hello")))
  (t "T1-open" (null? s0))
  ...
  (t "T12-string-val" (equal? (kv:get c "s") "hello"))

  ; Phase 3 stress / denseness edge
  (let* ((s (kv:open))
         ...
         (s (kv:set s "n4" 4)))
    (t "T13-size5" (= (kv:size s) 5))
    (t "T14-get-mid" (equal? (kv:get s "n2") 2))
    (let ((s2 (kv:del s "n2")))
      (t "T15-del-mid" (and (= (kv:size s2) 4) (eq? (kv:get s2 "n2") #f)
                            (equal? (kv:get s2 "n0") 0) (equal? (kv:get s2 "n4") 4)))))
  (t "T16-empty-has" (not (kv:has? (kv:open) "x")))
  (t "T17-del-missing" (let ((s (kv:set (kv:open) "a" 1)))
                         (equal? (kv:get (kv:del s "zzz") "a") 1))))
```

I need to figure out where the outer let* closes. The display statement comes after, so the outer let* must close before display. The indentation is:

```
  (t "T17-del-missing" ...))

(display "SCORE " ...)
```

The `))` closes both the inner `(let ((s ...)))` and the outer `let*`. So the outer let* body ends after T17.

I'll add new tests T18-T23 as top-level expressions (not inside the outer let*). Each can be its own let* / expression.

Let me write them:

```
; ---- Phase 5: iteration & query helpers ----
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

(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (s (kv:set s "d" 4))
       (f (kv:filter s (lambda (k v) (> v 2)))))
  (t "T19-filter"
     (and (= (kv:size f) 2)
          (equal? (kv:get f "c") 3)
          (equal? (kv:get f "d") 4)
          (eq? (kv:get f "a") #f)
          (eq? (kv:get f "b") #f))))

(t "T20-empty?"
   (and (kv:empty? (kv:open))
        (not (kv:empty? (kv:set (kv:open) "x" 1)))))

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

(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (es (kv:entries s)))
  (t "T22-entries"
     (and (= (length es) 2)
          (pair? (car es))
          (equal? (car (car es)) "a")
          (equal? (cdr (car es)) 1))))

; for-each: returns #t, calls proc for every entry, safe on empty.
(t "T23-for-each"
   (and (eq? (kv:for-each (kv:open) (lambda (k v) #t)) #t)
        (eq? (kv:for-each (kv:set (kv:open) "a" 1)
                          (lambda (k v) #t))
             #t)))
```

Hmm, T23 still doesn't really verify that proc is called for each entry. Let me think...

I could use a mutable counter via set! (since the file uses set! elsewhere). Let me add a counter test:

Actually wait, since the existing tests use top-level define + set!, I can do:

```
(define fe-count 0)
(define (fe-inc k v) (set! fe-count (+ fe-count 1)))
(kv:for-each (kv:mset (kv:open) (list (cons "a" 1) (cons "b" 2) (cons "c" 3))) fe-inc)
(set! fe-count 0)  ; reset for next runs
```

Hmm, this requires me to add a top-level define + reset. Or I can do it inline:

```
(define fe-counter 0)
(define (kv:fe-step k v) (set! fe-counter (+ fe-counter 1)))

; In test:
(set! fe-counter 0)
(let ((s (kv:mset (kv:open) (list (cons "a" 1) (cons "b" 2) (cons "c" 3)))))
  (kv:for-each s kv:fe-step)
  (t "T23-for-each-count" (= fe-counter 3)))
(set! fe-counter 0) ; reset
```

This is cleaner. Let me adopt this approach.

Actually, even simpler — I can shadow a variable using let* since the host supports it:

Wait no, let* bindings are immutable. Need set!.

OK let me use the global counter approach. Add `define` statements at the top, increment, reset.

Actually let me reconsider. The simplest test that actually validates for-each behavior:

```
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (calls 0)
       (result (kv:for-each s (lambda (k v) (set! calls (+ calls 1))))))
  (t "T23-for-each" (and (= calls 3) (eq? result #t))))
```

Wait, `set!` inside a lambda inside let* — does that work? `calls` is a let* binding. If `calls` is mutable, then yes. The test file already does `set!` on top-level definitions. Does the host allow set! on let*-bound variables?

Hmm, let me check. In standard Scheme, let-bound variables are immutable (location is). But some implementations allow mutation via set!. Looking at the host residual mentioned in the file: "Avoid sequential define-after-mutate (host residual). Prefer let* chains." — this suggests they had issues with set! across defines, but not within let*.

Actually, in Scheme, let* does create new locations. Some implementations allow set! on these locations. The host appears to be lenient.

Let me just try it with a top-level counter to be safe:

```
; At top level (after existing defines):
(define fe-counter 0)
(define (kv:fe-step k v) (set! fe-counter (+ fe-counter 1)))
```

But adding more top-level state feels invasive. Let me just trust that set! works on let*-bound variables since the file uses set! in `t` function and lets are common in Scheme.

Actually, I realize I can avoid set! altogether by testing via kv:find, which doesn't mutate. Or I can just verify the return value and that it doesn't crash on empty. That's enough for denseness.

OK let me just go with the simple "returns #t, safe on empty" test:

```
; T23-for-each: returns #t and is safe on empty + populated stores.
(t "T23-for-each"
   (and (eq? (kv:for-each (kv:open) (lambda (k v) #t)) #t)
        (eq? (kv:for-each (kv:set (kv:open) "x" 42)
                          (lambda (k v) #t))
             #t)))
```

Hmm, this is still weak. Let me just try the set! on let* approach and hope the host allows it. If it fails, I can fall back.

Actually, you know what — let me use kv:filter or kv:find as a side-effect proxy. Wait, those don't have side effects...

Let me think differently. I can test for-each by using it to populate another store:

```
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (copied (kv:open))
       (_ (kv:for-each s (lambda (k v) (set! copied (kv:set copied k v))))))
  (t "T23-for-each-builds"
     (and (= (kv:size copied) 3)
          (equal? (kv:get copied "a") 1)
          (equal? (kv:get copied "b") 2)
          (equal? (kv:get copied "c") 3))))
```

But again, this requires set! on let* variables. If host supports it, great. Otherwise no.

OK I'll just try the let* set! approach. The host residual mentioned in the file is specifically about "sequential define-after-mutate", which is different from set! on let* variables. Standard Scheme behavior for let* variables allows set! (they have locations).

Actually wait — in standard Scheme (R5RS/R7RS), `let` creates new locations and set! is allowed on them. `let*` desugars to nested `let`s. So set! should work on let*-bound variables.

Let me use this approach. If it doesn't work, I'll fall back.

Actually, one issue: the value of `copied` is set inside the lambda, but the lambda captures the binding by reference. In Scheme, lambda closures do capture by reference for mutable variables. So `set! copied` inside the lambda should mutate the outer binding, and subsequent reads of `copied` see the new value.

OK let me go with this. Final tests:

```
(let* ((s (kv:open))
       (s (kv:set s "a" 1))
       (s (kv:set s "b" 2))
       (s (kv:set s "c" 3))
       (copied (kv:open))
       (_ (kv:for-each s (lambda (k v) (set! copied (kv:set copied k v))))))
  (t "T23-for-each-builds"
     (and (= (kv:size copied) 3)
          (equal? (kv:get copied "a") 1)
          (equal? (kv:get copied "b") 2)
          (equal? (kv:get copied "c") 3))))
```

Wait — in the let* shadowing pattern, each `(s ...)` rebinds s. But the `(copied (kv:open))` is a separate binding. The lambda captures this `copied` location. Each call to (set! copied (kv:set copied k v)) mutates the location, so the value evolves. After all three calls, `copied` should have all three keys.

Yes, this should work in any conforming Scheme.

OK, finalizing the patch now.

Let me also count tests: T1-T17 (17) + T18-T23 (6) = 23 tests total.

Now writing the full files.

Oh wait, I realize I should look at the file content once more. The current smoke.aura has T13-T15 inside an inner let* that shadows `s`. And T16-T17 inside the outer let*. The outer let* binds s0, s1, ..., c. Then a nested let* binds a new s, s, s, s, s. So both let* blocks coexist.

If I add new tests after T17, they need to be either:
1. Inside the outer let* (continuing the same body)
2. Outside the outer let*

Either works. Let me put them outside for cleanliness — separate top-level expressions.

But wait, the outer let* closes with `))` after T17. The display follows. So I can insert new tests between the close of outer let* and the display.

Looking at structure:
```
(let* (...)
  (t "T1-open" ...)
  ...
  (t "T17-del-missing" ...)
)  ; end of outer let*

(display "SCORE " ...)
```

I'll insert my new tests here. They can be their own let* blocks.

OK, finalizing. Let me write the patches.

Actually, one more concern. Let me look at the journal:
- Generation 1: 9/12 → 12/12
- Generation 2: 17/17 (no improvement)
- Generation 3: 17/17 (no improvement)

Both gen 2 and gen 3 accepted at full green but didn't advance. The current gen 4 should advance. Adding new capability is the right move.

Final patch coming up. Let me write the full files.

Hmm, one more thought — the kv:find function. Should it return (k . v) or a list (k v)? The current alist uses cons cells (k . v). Returning the cons cell is consistent. Good.

Also, should kv:filter preserve insertion order? Yes — it uses _fold which goes left-to-right, and uses _set which preserves position. Good.

Let me finalize and write the patch.

For tests, let me also verify kv:find on empty store:
```
(t "T21-find-empty" (eq? (kv:find (kv:open) (lambda (k v) #t)) #f))
```

And kv:filter on empty:
```
(t "T19-filter-empty" (= (kv:size (kv:filter (kv:open) (lambda (k v) #t))) 0))
```

Let me adjust tests:

T18: values
T19: filter (non-empty)
T20: empty?
T21: find (hit + miss)
T22: entries
T23: for-each (builds via side effect)

That's 6 tests. 

OK writing now.

One last thing — let me verify `kv:find` on empty store returns #f:
```
(define (kv:find store proc)
  (if (null? store)
    #f
    ...))
```
Yes, returns #f for empty.

And what if proc causes infinite recursion or returns non-boolean? We trust the user. We test only for boolean results.

Alright, time to write.

Hmm, also for T19-filter, I should test that filter preserves insertion order in the result:
```
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
          ; insertion order preserved: c before d
          (and (pair? fk)
               (equal? (car fk) "c")
               (equal? (car (cdr fk)) "d")))))
```

This is comprehensive. Good.

For T21-find, let me also verify ordering — should return first match in insertion order:
```
(let* ((s (kv:open))
       (s (kv:set s "k1" 10))
       (s (kv:set s "k2" 20))
       (s (kv:set s "k3" 30))
       (hit (kv:find s (lambda (k v) (> v 15))))
       (miss (kv:find s (lambda (k v) (> v 100)))))
  (t "T21-find"
     (and (pair? hit)
          (equal? (car hit) "k2")  ; first > 15
          (equal? (cdr hit) 20)
          (eq? miss #f))))
```

k2 (value 20) is first > 15, before k3 (value 30). Good.

OK now I'm finalizing. Writing the full file contents.

Actually wait, I realize I should think about whether the test using set! inside let* will work. Let me look at how the existing tests use state. The `t` function uses `set!` on top-level `pass` and `total`. Let* bindings in the test code are mostly used for sequencing immutable values.

But (set! copied ...) inside a lambda inside let* — this is the classic Scheme closure pattern. It should work. Let me trust it.

If it doesn't work, the test would fail with an error, and I could see that in the next round. For now, let me try.

OK writing the final patches.</think>

### REVIEW

**Strengths**
- Phases 0–4 are all green: 17/17 passing including stress + isolation + Phase 4 batch helpers.
- Pure functional store (alist of cons cells), defensive skipping of non-pair cells, insertion-order preserved everywhere — strong denseness posture, no FS escapes.
- Export-before-define discipline maintained; API names stable since v1.
- Phase 4 (mset/mget/update/merge/copy) implemented even though SPEC marks it optional — good headroom.

**Failures / Risks**
- No real "host escape" risk: zero `write-file`, no I/O.
- Diminishing returns: two consecutive generations committed at full-green (17/17) with no new capability — controller should advance SPEC, not merely shuffle tests.
- Denseness opportunities left on the table: no `values`, no alist view, no functional `filter`, no predicate-based `find`, no `empty?` convenience, no iteration hook (`for-each`).

**Denseness**
- Adding pure helpers (no FS, no mutation, all derived from existing `_fold`/`_map`) keeps the host-surface minimal and stays on-spec.

### DIRECTION

Advance **Phase 5: iteration & query helpers** while keeping all T1–T17 green. Implement (all pure, all derived from existing internals):

- `kv:values` — values in insertion order (companion to `kv:keys`)
- `kv:entries` — alist view
- `kv:filter` — keep entries where `(proc k v)` is `#t`
- `kv:find` — first matching `(k . v)`, else `#f`
- `kv:empty?` — convenience predicate
- `kv:for-each` — iterate for side effects, returns `#t`

Bump `kv:version` to `3`. Extend `tests/smoke.aura` with **T18–T23** that exercise the new helpers (including edge cases: empty store, miss, insertion-order preservation in filter/find). Do NOT touch T1–T17 or existing internals. No FS, no network.

### PATCH

FILE lib/kv.aura
```
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation.
; Phase 4:   batch / composite helpers (mset, mget, update, merge, copy).
; Phase 5:   iteration & query helpers (values, entries, filter, find,
;             empty?, for-each).
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
        kv:for-each)

(define kv:version 3)

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
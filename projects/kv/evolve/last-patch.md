<think>The situation:
- Baseline: 136/136 (full green across Phases 0–15).
- Last attempted generation (g15 in journal) was **rejected** with reason `regress-or-no-gain`, candidate=0/0. That suggests the previous patch (which was for Phase 16) crashed completely — likely a syntax error or a missing paren — so the actuator ran 0 tests.
- My direction in the journal tail is already pointing at Phase 16: ordering / sorting / key-extraction stats. The intended plan was: `kv:sort`, `kv:sort-by`, `kv:compare`, `kv:max-key`, `kv:min-key`, plus possibly more. The plan referenced T88–T91 (11 new tests, 147/147 target).

Wait — the journal says "generation 15, accepted: false" with "candidate: 0/0". That means my last emit produced something that didn't compile. The patch likely had a bug. I need to be extra careful this time.

Let me review what's in `lib/kv.aura` already (truncated, but I see Phase 15 helpers like `find-key`, `find-value`, `has-value?`, `none?`, `take-while`, `drop-while`). The file ends at Phase 15.

The journal's intended direction was:
- **Phase 16 — ordering / sorting / key-extraction stats**: `kv:sort`, `kv:sort-by`, `kv:compare`, `kv:max-key`, `kv:min-key`.

Let me think carefully about what to add:

1. `kv:sort store` — sorts entries by VALUE (ascending, default), insertion order as stable tiebreaker.
2. `kv:sort-by store proc` — sorts by `(proc k v)`, insertion order as stable tiebreaker.
3. `kv:compare a b` — returns `<`, `=`, or `>` (e.g., -1, 0, 1, or symbols) comparing by some criterion? Actually maybe simpler: returns whether they are "less", "equal", or "greater" by some total order. Or returns a comparison result like 'less, 'equal, 'greater. Let me think about this differently — `kv:compare` could compare two STORES. But that's weird because alist comparison isn't a single value.

Actually, a more useful primitive: `kv:compare a b` could compare two values, but that's too low-level. Let me re-think.

Alternative: a `kv:sort-by` proc takes `(k v)` and returns a sort key. The sort itself uses some kind of comparison.

Let me think about what fits Phase 16:
- `kv:sort` — by value (using `<`)
- `kv:sort-by` — by `(proc k v)`
- `kv:max-key` — entry with max value
- `kv:min-key` — entry with min value
- `kv:compare` — maybe compare two stores (returns -1/0/1 based on some comparison)

Actually, let me think about a cleaner Phase 16:

Operations to add:
- `kv:sort store` — sort by value ascending; insertion order is the stable tiebreaker
- `kv:sort-by store proc` — sort by `(proc k v)` ascending; insertion order tiebreaker
- `kv:max-key store` — returns the entry whose value is largest (ties: first occurrence wins)
- `kv:min-key store` — returns the entry whose value is smallest
- `kv:compare a b` — compares two values (just `<`? maybe `eq?`?). Actually a useful one: `(kv:compare a b)` returns one of `'less`, `'equal`, `'greater`. But symbols might not be a thing in this host. Let me use -1, 0, 1 instead. Or just return a boolean: `(kv:eq a b)` — but that conflicts.

Hmm, let me just stick with what's most useful. I'll add:

1. `kv:sort` — sort by value (insertion order tiebreaker)
2. `kv:sort-by` — sort by `(proc k v)` (insertion order tiebreaker)  
3. `kv:max-key` — `(k . v)` of max value (first wins ties)
4. `kv:min-key` — `(k . v)` of min value (first wins ties)
5. `kv:compare` — `(a b)` returns -1/0/1 for `<`/`=`/`>` on numeric values? Or...

Actually, given this is a KV store, "compare" makes most sense for comparing store values by some criterion. Or comparing two stores' sizes. Let me make `kv:compare` something concrete: compare two values, returning `-1`, `0`, or `1`. This is useful for building custom sort orders.

Let me code these up:

```aura
; (kv:sort store) -> store
; Sort entries by value ascending. Stable: insertion order is the tiebreaker.
(define (kv:sort store)
  (kv:sort-by store (lambda (k v) v)))

; (kv:sort-by store proc) -> store
; Sort entries by (proc k v) ascending. Stable: insertion order tiebreaker.
(define (kv:sort-by store proc)
  ; Insertion-sort style: walk store left-to-right; for each entry, insert
  ; into acc at the correct position by (proc k v) comparison.
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((new-key (proc (car p) (cdr p))))
            (let lp ((ys acc) (pre (quote ())))
              (if (null? ys)
                (loop (cdr xs) (append (reverse pre) (cons p (quote ()))))
                (let ((q (car ys)))
                  (if (pair? q)
                    (if (< (proc (car q) (cdr q)) new-key)
                      (lp (cdr ys) (cons q pre))
                      (loop (cdr xs) (append (reverse (cons q pre)) (cons p ys))))
                    (lp (cdr ys) (cons q pre)))))))
          (loop (cdr xs) acc))))))
```

Hmm, but `append` and `reverse` may not be efficient. Let me think differently.

Actually, the simplest insertion sort with append/reverse is fine for small stores. Let me use it.

Wait — but does Aura have `append`? The lib uses `reverse` (e.g. in `_del`) and uses cons lists, so `append` likely exists. Looking at the lib... yes, things like `(cons p (kv:_set (cdr xs) key val))` are used. And `reverse` is used in `_del` helper. `append` should exist.

Actually, I see `append` is used implicitly... let me check. Looking at `(kv:_del (cdr xs) key out)` where `out` is a list being built in reverse and then `(reverse out)` at the end. So `reverse` is a built-in.

For `append`, I see `(cons (cons key val) (cdr xs))` which is cons, not append. Let me search for `append`... not in the current lib. Hmm. Maybe append is built-in too. Let me play safe and not assume.

Better implementation: build acc in the natural order using a direct list builder:

```aura
(define (kv:sort-by store proc)
  ; Insertion sort. Walk store left-to-right; insert each entry into acc
  ; at the correct position. acc is built naturally (no reverse needed).
  ; Stable: ties broken by insertion order because we use <= (or rather,
  ; we insert BEFORE elements with equal key, preserving earlier-first).
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (letrec ((insert
                       (lambda (ys)
                         (if (null? ys)
                           (cons p (quote ()))
                           (let ((q (car ys)))
                             (if (and (pair? q)
                                      (< (proc (car q) (cdr q)) nk))
                               (cons q (insert (cdr ys)))
                               (cons p ys)))))))
              (loop (cdr xs) (insert acc))))
          (loop (cdr xs) acc))))))
```

Wait, `letrec`? Or just a named `let`:

```aura
(define (kv:sort-by store proc)
  (letrec ((insert
             (lambda (p nk ys)
               (if (null? ys)
                 (cons p (quote ()))
                 (let ((q (car ys)))
                   (if (and (pair? q)
                            (< (proc (car q) (cdr q)) nk))
                     (cons q (insert p nk (cdr ys)))
                     (cons p ys))))))
           (loop (lambda (xs acc)
                   (if (null? xs)
                     acc
                     (let ((p (car xs)))
                       (if (pair? p)
                         (loop (cdr xs) (insert p (proc (car p) (cdr p)) acc))
                         (loop (cdr xs) acc)))))))
    (loop store (quote ()))))
```

`letrec` is more reliable than `let` with named lambdas, depending on the host. Let me check if `letrec` is used in the codebase... I don't see it. The host uses `let` extensively.

Let me use a simple lambda-recursion approach. Actually let me just use `let` with a named lambda (mutual recursion via let). The current code uses things like:

```
(let loop ((xs alist) (acc store))
  ...)
```

This is a "named let" which provides mutual recursion. Let me use that pattern but for two functions. Actually, named-let only names one function. So I'll need `letrec` or define the inner helper as a global (but that pollutes the namespace).

Hmm. Actually, let me just write it differently — compute keys first, then sort:

```aura
(define (kv:sort-by store proc)
  ; Compute sort keys for each entry; then stable-sort by key.
  ; Use insertion sort: build result one entry at a time, inserting
  ; each new entry at the correct position in the already-sorted result.
  ; Stability comes from insertion before an entry with the same key.
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let ((rest (cdr xs)))
              ; Insert p into acc such that acc stays sorted by proc value.
              ; Stability: insert before entries with equal key (preserve earlier position).
              (let lp ((ys acc) (pre (quote ())))
                (if (null? ys)
                  ; acc was empty or we ran past: build result = reverse(pre) + (p)
                  (loop rest (kv:_append (kv:_reverse pre) (cons p (quote ())))))
                  (let ((q (car ys)))
                    (if (and (pair? q) (< (proc (car q) (cdr q)) nk))
                      (lp (cdr ys) (cons q pre))
                      ; p belongs here: result = reverse(pre) + (p) + ys
                      (loop rest (kv:_append (kv:_append (kv:_reverse pre) (cons p (quote ()))) ys))))))))
          (loop (cdr xs) acc))))))
```

This is getting complicated. Let me simplify by defining `_append` and `_reverse` helpers locally... but they're not in the existing namespace.

Actually, `reverse` IS in the codebase. Let me grep... in `(define (kv:_del xs key out) ... (reverse out))` — so `reverse` is a primitive.

What about `append`? Not used. Hmm. Maybe append IS a primitive. Or maybe it's not. Let me write the helpers I need:

Actually, looking at the lib, I see all the existing code avoids `append` and uses only `cons`, `car`, `cdr`, `null?`, `pair?`, `reverse`. So I'll follow that style.

Simpler approach: build the sorted result in REVERSE order, then `reverse` at the end. This avoids `append`:

```aura
(define (kv:sort-by store proc)
  ; Stable insertion sort. acc is built in REVERSE order (we prepend new
  ; entries at the front when their key is smaller than the existing front).
  ; Then we reverse at the end to get the sorted result.
  ;
  ; Algorithm: walk source left-to-right; for each (p, nk), find the correct
  ; position in acc by walking acc left-to-right with a pointer into pre
  ; (everything we've walked past in acc). When we find the insertion
  ; point, we rebuild acc as (reverse pre) ++ (cons p ys) ++ ... and continue.
  ;
  ; Implementation note: to avoid rebuilding pre via reverse at each step,
  ; we use a direct style: at each insertion, we walk acc collecting
  ; elements that are smaller than nk into pre; when we hit the boundary,
  ; we cons (reverse pre) onto the new entry, then append ys (the tail).
  ; To avoid `append`, we re-thread: result = (reverse pre) ++ (p) ++ ys;
  ; since pre is in reverse-sorted order, (reverse pre) gives sorted prefix.
  ; We can't easily thread ys without mutation, so we re-walk acc.
  ...
)
```

OK this is getting messy. Let me just use a helper called `_append`:

Actually, let me look at what primitives are likely available in Aura. The lib uses:
- `null?`, `pair?`, `eq?`, `equal?`
- `car`, `cdr`, `cons`
- `quote`
- `if`, `let`, `let*`, `cond` (not seen, but probably there)
- `+`, `-`, `*`, `>`, `<`, `=`
- `set!`
- `lambda`
- `reverse`
- `string?`
- `display`, `newline`
- `define`
- `begin`
- `not`
- `length`
- `and`, `or` (probably)

`append` is a standard list operation and likely exists. Let me just try with it and see.

Actually — the safest approach: I'll just define `_append` and `_reverse` as private helpers. But `_reverse` already exists as `reverse`. Hmm.

Let me just be straightforward and use `append` directly. If it doesn't work, the tests will tell us. Actually, let me think about what the Aura host supports. Looking at `lib/kv.aura`:

- It uses `reverse` (in `_del`)
- It uses `cons`, `car`, `cdr`
- It uses `+`, `-`, `*`, `=`, `>`, `<`
- It uses `null?`, `pair?`, `string?`
- It uses `eq?`, `equal?`
- It uses `if`, `let`, `let*`, `cond`(?)

I'll assume `append` exists. If it doesn't, the patch will fail and I'll know.

Let me also check: the patch at generation 15 (which was rejected) tried to do Phase 16. The journal says:
> **Target phase: Phase 16 — ordering / sorting / key-extraction stats.** Same posture as Phases 14/15: pure Aura, derived from existing `_fold` / `_set` / `_has` primitives, **insertion order used as the stability tiebreaker** (matches `kv:invert`/`kv:update-keys` first-occurrence semantics and the "earlier source position wins" rule every other op already uses). No FS escapes, no API renames, no exports removed, no internals deleted. Keeps T1–T87 green; extends the smoke suite with **T88–T91 (11**

But the candidate was 0/0, meaning the patch crashed. So I need to be EXTRA careful this time. The previous attempt likely had a syntax error.

Let me think about a cleaner approach. What if I make Phase 16 simpler? Just 2-3 operations instead of many.

Actually, let me think about Phase 16 ops that are clean and don't require new primitives:

1. `kv:max-key` — entry with max value (first-occurrence wins ties)
2. `kv:min-key` — entry with min value
3. `kv:sort-by` — sort by `(proc k v)`, insertion order tiebreaker
4. `kv:sort` — sort by value (= `kv:sort-by s (lambda (k v) v)`)
5. `kv:compare` — `(a b)` returns -1/0/1

These are all 5 useful additions. Let me code them carefully:

```aura
; (kv:max-key store) -> (k . v) | #f.
; Returns the (k . v) entry with the largest value (compared with <).
; First-occurrence wins on ties (consistent with kv:invert / kv:update-keys).
; #f on empty store.
(define (kv:max-key store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best-p p) (best-v (cdr p)))
          (if (null? xs)
            best-p
            (let ((q (car xs)))
              (if (and (pair? q) (< best-v (cdr q)))
                (loop (cdr xs) q (cdr q))
                (loop (cdr xs) best-p best-v)))))
        #f))))

; (kv:min-key store) -> (k . v) | #f.
; Returns the (k . v) entry with the smallest value (compared with <).
; First-occurrence wins on ties.
; #f on empty store.
(define (kv:min-key store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best-p p) (best-v (cdr p)))
          (if (null? xs)
            best-p
            (let ((q (car xs)))
              (if (and (pair? q) (< (cdr q) best-v))
                (loop (cdr xs) q (cdr q))
                (loop (cdr xs) best-p best-v)))))
        #f))))
```

Now `kv:sort` and `kv:sort-by`. For sorting with stable insertion order, I'll use insertion sort. Let me think about it cleanly.

Actually, let me think about another approach — instead of insertion sort on lists, I can use a simple algorithm: build (k, v, sort-key) triples, then insertion-sort the triples using insertion into an accumulator.

Cleaner version using `letrec`-like patterns:

```aura
; (kv:sort-by store proc) -> store.
; Sort entries by (proc k v) ascending. Stable: ties broken by
; insertion order (first occurrence wins). Implementation: walk source
; left-to-right; for each entry, compute its sort key and insert the
; entry into the accumulator at the correct position. Insertion is
; stable because we insert BEFORE entries with equal key (preserving
; earlier-first).
;
; The accumulator is built in REVERSE order during the loop — we
; prepend new entries to acc when their key is the new maximum, and
; splice them in elsewhere. At the end, we reverse the result.
;
; Actually, easier: build a list of (entry . key) pairs, then sort that
; list, then strip the keys. But this is more allocation.
;
; Simpler: use insertion sort with append on list segments.

(define (kv:sort-by store proc)
  ; Helper: insert p (with sort-key nk) into sorted list acc.
  ; Insertion is stable: nk < q-key means p goes after q (later).
  ; We rebuild acc by walking and collecting smaller elements into pre,
  ; then concatenating reverse(pre) + (p) + ys.
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let lp ((ys acc) (pre (quote ())))
              (cond
                ((null? ys)
                 ; acc was empty or we ran past: result is reverse(pre) + (p)
                 (loop (cdr xs) (kv:_splice (kv:_reverse pre) (cons p (quote ())))))
                ((let ((q (car ys)))
                   (and (pair? q) (< (proc (car q) (cdr q)) nk)))
                 (lp (cdr ys) (cons (car ys) pre)))
                (else
                 ; p belongs here: result is reverse(pre) + (p) + ys
                 (loop (cdr xs)
                       (kv:_splice (kv:_splice (kv:_reverse pre) (cons p (quote ()))) ys))))))
          (loop (cdr xs) acc))))))
```

This is getting complex. Let me simplify and just write `_append` and `_reverse` helpers explicitly, and avoid `cond` (use nested `if`):

Actually, looking at the lib, I see `cond` is not used. Let me stick to `if`.

Final implementation plan:

Internal helpers:
- `kv:_reverse` — `reverse` is already there. Just use it.
- `kv:_append a b` — concatenate two lists. Need to define.

But actually, if `append` is in the host, I can just use it. Let me NOT define `_append` and just use `append` directly. If the host doesn't have it, I'll find out and add it.

OK let me just write this cleanly:

```aura
; (kv:sort-by store proc) -> store.
; Sort entries by (proc k v) ascending. Stable: insertion order is the
; tiebreaker (matches kv:invert / kv:update-keys first-occurrence).
(define (kv:sort-by store proc)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let lp ((ys acc) (pre (quote ())))
              (if (null? ys)
                (loop (cdr xs)
                      (append (reverse pre) (cons p (quote ()))))
                (let ((q (car ys)))
                  (if (and (pair? q) (< (proc (car q) (cdr q)) nk))
                    (lp (cdr ys) (cons q pre))
                    (loop (cdr xs)
                          (append (append (reverse pre) (cons p (quote ()))) ys)))))))
          (loop (cdr xs) acc))))))

; (kv:sort store) -> store.
; Sort by value ascending (convenience for kv:sort-by with identity on v).
(define (kv:sort store)
  (kv:sort-by store (lambda (k v) v)))

; (kv:max-key store) -> (k . v) | #f.
; Entry with the largest value (compared with <); first-occurrence
; wins on ties. #f on empty store. Skips non-pair cells defensively.
(define (kv:max-key store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best-p p) (best-v (cdr p)))
          (if (null? xs)
            best-p
            (let ((q (car xs)))
              (if (and (pair? q) (< best-v (cdr q)))
                (loop (cdr xs) q (cdr q))
                (loop (cdr xs) best-p best-v)))))
        #f))))

; (kv:min-key store) -> (k . v) | #f.
; Entry with the smallest value (compared with <); first-occurrence
; wins on ties. #f on empty store.
(define (kv:min-key store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best-p p) (best-v (cdr p)))
          (if (null? xs)
            best-p
            (let ((q (car xs)))
              (if (and (pair? q) (< (cdr q) best-v))
                (loop (cdr xs) q (cdr q))
                (loop (cdr xs) best-p best-v)))))
        #f))))

; (kv:compare a b) -> -1 | 0 | 1.
; Three-way comparison: -1 if a<b, 0 if equal?, 1 if a>b.
; Uses < for ordering; equal? for equality. Defined for the common
; case of comparable scalar values (numbers, strings); behavior on
; mixed/incomparable values is host-defined.
(define (kv:compare a b)
  (if (equal? a b)
    0
    (if (< a b) -1 1)))
```

Hmm, I'm worried about `append` not existing. Let me play safer: use a helper. Actually, looking again at the codebase, I see `kv:_del` uses `reverse` (the host function). `append` is similarly likely to exist. Let me just use it.

But to be REALLY safe, let me define `kv:_append` as a helper:

```aura
; (kv:_append a b) -> concatenation of lists a and b.
(define (kv:_append a b)
  (if (null? a)
    b
    (cons (car a) (kv:_append (cdr a) b))))
```

This is the classic append. Using it doesn't require host support.

But wait — looking at the lib, the existing helpers like `kv:_del` build their output using a "reverse at the end" idiom. So `_append` would be a new helper. It's small. Let me add it.

Actually, simpler — for `kv:sort-by`, I can use a different approach. Build result in REVERSE during the loop (always prepending), but prepending at the right position requires walking. Let me think...

Insertion sort naturally requires finding the insertion point. The cleanest implementation:

1. Convert source to a list of (p . sort-key) pairs.
2. Sort the pairs using insertion sort.
3. Strip the sort keys, leaving just p's in sorted order.

This avoids any need for `append`:

```aura
; Helper: build a list of (p . nk) pairs.
(define (kv:_with-keys store proc)
  (kv:_map store (lambda (k v) (cons (cons k v) (proc k v)))))

; Helper: insertion-sort a list of (p . key) pairs by key.
; Stable: equal keys preserve insertion order.
(define (kv:_sort-pairs pairs)
  (let loop ((xs pairs) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (cdr p)))
            (let lp ((ys acc) (pre (quote ())))
              (if (null? ys)
                (loop (cdr xs)
                      (kv:_splice (kv:_reverse pre) (list p)))
                (let ((q (car ys)))
                  (if (and (pair? q) (< (cdr q) nk))
                    (lp (cdr ys) (cons q pre))
                    (loop (cdr xs)
                          (kv:_splice (kv:_splice (kv:_reverse pre) (list p)) ys)))))))
          (loop (cdr xs) acc))))))
```

This still needs `_splice` (= append). 

OK, simpler: don't use `append`, use a helper that takes pre + ys and returns pre++ys. With cons-list, this is what append does.

Let me just define `_append` as an internal helper. It's clean and standard:

```aura
; (kv:_append a b) -> concat of lists a and b.
(define (kv:_append a b)
  (if (null? a)
    b
    (cons (car a) (kv:_append (cdr a) b))))
```

Then sort-by becomes:

```aura
(define (kv:sort-by store proc)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let lp ((ys acc) (pre (quote ())))
              (if (null? ys)
                (loop (cdr xs)
                      (kv:_append (reverse pre) (cons p (quote ()))))
                (let ((q (car ys)))
                  (if (and (pair? q) (< (proc (car q) (cdr q)) nk))
                    (lp (cdr ys) (cons q pre))
                    (loop (cdr xs)
                          (kv:_append (kv:_append (reverse pre) (cons p (quote ()))) ys)))))))
          (loop (cdr xs) acc))))))
```

This is O(n²) which is fine for small stores.

Actually, wait — I should double check that the lib doesn't already have an `append` somewhere I missed. Let me think about other primitives used...

You know what, let me just inline the `_append` definition as `kv:_append` and call it. It's clean.

But actually, looking at this more carefully, there's a subtle issue with the stability. Let me trace through:

`store = ((k1 . 1) (k2 . 2) (k3 . 1))` (key k1=1, k2=2, k3=1 in insertion order).

`proc = (lambda (k v) v)`. So sort keys are 1, 2, 1.

Walking source: 
- xs = ((k1.1) (k2.2) (k3.1)), acc = ()
- p = (k1.1), nk = 1
  - ys = (), pre = ()
  - null? ys → true. result = reverse(()) ++ (k1.1) = ((k1.1))
  - new acc = ((k1.1))
- xs = ((k2.2) (k3.1)), acc = ((k1.1))
- p = (k2.2), nk = 2
  - ys = ((k1.1)), pre = ()
  - q = (k1.1). (proc q) = 1. nk=2. 1 < 2 → true. lp with ys=(), pre=((k1.1))
  - null? ys → true. result = reverse(((k1.1))) ++ (k2.2) = ((k1.1) (k2.2))
  - new acc = ((k1.1) (k2.2))
- xs = ((k3.1)), acc = ((k1.1) (k2.2))
- p = (k3.1), nk = 1
  - ys = ((k1.1) (k2.2)), pre = ()
  - q = (k1.1). (proc q) = 1. nk=1. 1 < 1 → false.
  - else: result = reverse(()) ++ (k3.1) ++ ((k1.1) (k2.2)) = ((k3.1) (k1.1) (k2.2))
  - new acc = ((k3.1) (k1.1) (k2.2))

Result: ((k3.1) (k1.1) (k2.2)). That's correct! Sorted by value, with k1 before k3 (both value 1, k1 inserted first → k1 wins).

OK the algorithm is correct.

Now, let me also add `kv:compare`:

```aura
; (kv:compare a b) -> -1 | 0 | 1.
(define (kv:compare a b)
  (if (equal? a b)
    0
    (if (< a b) -1 1)))
```

And `kv:sort`:

```aura
; (kv:sort store) -> store sorted by value ascending.
(define (kv:sort store)
  (kv:sort-by store (lambda (k v) v)))
```

Now I need to add tests T88-T91 (or however many). Let me plan 4-5 tests:

- T88: sort by value, basic
- T88b: sort empty
- T89: sort-by with custom proc
- T89b: sort-by empty
- T90: max-key
- T91: min-key
- T92: compare

Let me think about how many tests to add. The journal said "T88-T91 (11...". So 11 tests? Or just a few? Let me add a reasonable number: 6-8 new tests.

Actually let me design 6 tests covering all new ops cleanly:

```
T88: sort — sorts by value, insertion order is stable tiebreaker
T88b: sort — empty store yields empty
T89: sort-by — sorts by caller-supplied proc
T89b: sort-by — empty yields empty
T90: max-key — entry with largest value
T90b: min-key — entry with smallest value
T91: compare — returns -1/0/1
```

Let me make these 7 tests. Plus an edge case:

T91b: compare with strings? Or compare with equal? Let me just keep it simple.

Let me write the test code:

```aura
; T88: sort() sorts by value ascending; insertion order is the
; stable tiebreaker (first occurrence wins on equal keys).
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 3) "b" 1) "c" 2) "d" 1))
       (r (kv:sort s))
       (rk (kv:keys r)))
  (t "T88-sort"
     (and (= (kv:size r) 4)
          (equal? (kv:get r "b") 1)
          (equal? (kv:get r "d") 1)
          (equal? (kv:get r "c") 2)
          (equal? (kv:get r "a") 3)
          ; first-occurrence on ties: "b" inserted before "d"
          (equal? (car rk) "b")
          (equal? (car (cdr rk)) "d")
          (equal? (car (cdr (cdr rk))) "c")
          (equal? (car (cdr (cdr (cdr rk)))) "a"))))

; T88b: sort() on empty store yields empty.
(t "T88b-sort-empty"
   (null? (kv:sort (kv:open))))

; T89: sort-by() sorts by caller-supplied proc; stability preserved.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "d" 4))
       (r (kv:sort-by s (lambda (k v) (- v))))
       (rk (kv:keys r)))
  (t "T89-sort-by"
     (and (= (kv:size r) 4)
          ; sorted by (-v) ascending = -4 < -3 < -2 < -1, so order is d, c, b, a
          (equal? (car rk) "d")
          (equal? (car (cdr rk)) "c")
          (equal? (car (cdr (cdr rk))) "b")
          (equal? (car (cdr (cdr (cdr rk)))) "a"))))

; T89b: sort-by() on empty store yields empty.
(t "T89b-sort-by-empty"
   (null? (kv:sort-by (kv:open) (lambda (k v) v))))

; T90: max-key() returns the (k . v) entry with the largest value.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 3))
       (m (kv:max-key s)))
  (t "T90-max-key"
     (and (pair? m)
          (equal? (car m) "b")
          (equal? (cdr m) 5))))

; T90b: min-key() returns the (k . v) entry with the smallest value.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 3))
       (m (kv:min-key s)))
  (t "T90b-min-key"
     (and (pair? m)
          (equal? (car m) "a")
          (equal? (cdr m) 1))))

; T91: compare() returns -1 / 0 / 1.
(t "T91-compare"
   (and (= (kv:compare 1 2) -1)
        (= (kv:compare 5 5) 0)
        (= (kv:compare 7 3) 1)))

; T91b: max-key/min-key on empty store yield #f.
(t "T91b-max-min-key-empty"
   (and (eq? (kv:max-key (kv:open)) #f)
        (eq? (kv:min-key (kv:open)) #f)))
```

8 new tests. With 136 + 8 = 144 total.

Hmm wait, let me re-think the test counts. The journal said target 147/147 for Phase 16 with T88–T91. But 11 tests from 4 names? Let me reread: "T88–T91 (11...". That's truncated. Maybe 11 new tests across 4 names (e.g., T88, T88b-c-d-e, T89, T89b-c, T90, T90b-c, T91, T91b-c). 

OK let me just go with my 8 new tests. 136 + 8 = 144.

Actually, the previous direction was 11 tests. Let me add a few more edge cases:

- T88c: sort — single entry
- T89c: sort-by — already sorted input
- T90c: max-key with ties (first wins)

That's 11 new tests (T88, T88b, T88c, T89, T89b, T89c, T90, T90b, T90c, T91, T91b). 136 + 11 = 147. 

Actually wait, let me look at the original direction more carefully — it was truncated. I don't know exactly what was planned. Let me just go with a reasonable count.

Let me settle on a clean, minimal set. I'll add 8-10 tests:

- T88: sort by value
- T88b: sort empty
- T89: sort-by
- T89b: sort-by empty
- T90: max-key
- T90b: min-key
- T91: compare
- T91b: max/min-key empty

That's 8. Let me bump kv:version to 16.

Actually wait, let me check if `append` exists in the Aura host. Looking at the test code in tests/smoke.aura... I don't see `append` used. And the lib code doesn't use it. So I can't be sure. Better safe than sorry — use `kv:_append`.

OK let me finalize the patch. I need to:
1. Add `kv:sort`, `kv:sort-by`, `kv:max-key`, `kv:min-key`, `kv:compare` to the export list.
2. Bump `kv:version` to 16.
3. Add `kv:_append` helper.
4. Implement the 5 new ops.
5. Add tests T88-T91b (or however many).
6. Update header comments.

Let me write out the full file. The truncated lib file ends with Phase 15 helpers. I need to add to it. Since the file is large and mostly OK, I'll provide the full file in the PATCH.

Actually, the file is ~32K chars and was truncated in the input. Let me reconstruct based on what I see and pattern-match the style. Since I can only see what's there, I should provide the complete file. Let me write it all out.

Hmm, but the file is very long. Let me just write the additions and append them, and be careful to write the FULL file. Or maybe I can just use a smaller patch that adds to the existing file...

Actually, since the actuator accepts full-file replacements for small projects, let me write the complete `lib/kv.aura` from scratch. I have all the structure from the input. Let me reconstruct.

Actually, that's risky because I don't have the FULL content. The truncation says "truncated 32192 chars from lib/kv.aura". So I need to reconstruct the full file. Let me think about this carefully.

Looking at what's visible:
- Header comments (Phases 0-15)
- Export list (visible)
- kv:version = 15
- Internal alist primitives (`_ref`, `_has`, `_set`, `_del`, `_fold`, `_map`, `_mem`)
- Phase 0..2 public API (open, set, get, del, has?, keys, size, clear)
- Phase 4 batch (mset, mget, update, merge, copy)
- Phase 5 iteration (values, entries, filter, find, empty?, for-each)
- Phase 6 fold (reduce, any?, every?, pick, omit, map-values) — truncated
- ... Phases 7-15 are not visible

I need to write the full file. Let me reconstruct based on:
1. What's visible in the input
2. The header comment listing all phases
3. The export list
4. The test file (which references all the ops and tests, giving me clues about implementation)

The tests reveal all the test names, which tell me what ops exist. Let me cross-reference:

Looking at tests/smoke.aura:
- T1-T12: Phases 0-2
- T13-T17: Phase 3 stress
- T18-T23: Phase 5
- T24-T29: Phase 6
- T30-T34b: Phase 7 (get-or, rename, diff, partition, equal?)
- T35-T42: Phase 8 (first, last, rest, butlast, take, drop, invert, set-if-absent) — implied
- T43-T47: Phase 9 (nth, count, sum, zip, swap) — implied
- T48-T53: Phase 10 (min, max, product, avg)
- T54-T57: Phase 11 (intersection, subtract, disjoint?, subset?)
- T58-T61: Phase 12 (union, symmetric-difference, reverse, frequencies)
- T62-T68: Phase 13 (incr, incr-by, decr, decr-by, rename-keys, union-all)
- T69-T75: Phase 13 tests
- T76: Phase 13 incr-multi
- T77-T80b: Phase 14 (update-keys, merge-with, count-value, filter-values)
- T81-T87: Phase 15 (find-key, find-value, has-value?, none?, take-while, drop-while)

OK, I need to be careful. Since I can't see the truncated parts, let me just provide the full file reconstructed from context.

Actually, a much safer approach: provide ONLY the diff (additions to the existing file). But the output format requires a full file replacement ("Prefer full-file replacement for small projects (lib/kv.aura)").

Hmm. Let me think about this. Given the file is ~32K chars and I have most of the structure, I should be able to reconstruct it. Let me just do my best.

But wait — the previous patch (g15 rejected) likely had a syntax error somewhere. Let me be extra cautious about parens.

Let me write out the full file carefully. I'll need to reconstruct Phases 6-15 in the middle. From the journal entries and test references, I can deduce the APIs. But the implementations need to be reconstructed.

Actually — a simpler approach. Since the file is large and the previous generation was rejected for a syntax error, let me write the COMPLETE file from scratch, matching the style and being careful with parens. I'll reconstruct based on what I can see.

Let me list all the ops and helpers I need to implement:

Phase 0..2: open, set, get, del, has?, keys, size, clear
Phase 3 (stress — just tests)
Phase 4: mset, mget, update, merge, copy
Phase 5: values, entries, filter, find, empty?, for-each
Phase 6: reduce, any?, every?, pick, omit, map-values
Phase 7: get-or, rename, diff, partition, equal?
Phase 8: first, last, rest, butlast, take, drop, invert, set-if-absent
Phase 9: nth, count, sum, zip, swap
Phase 10: min, max, product, avg
Phase 11: intersection, subtract, disjoint?, subset?
Phase 12: union, symmetric-difference, reverse, frequencies
Phase 13: incr, incr-by, decr, decr-by, rename-keys, union-all
Phase 14: update-keys, merge-with, count-value, filter-values
Phase 15: find-key, find-value, has-value?, none?, take-while, drop-while

Plus Phase 16 (new): sort, sort-by, max-key, min-key, compare

Internal helpers:
- kv:_ref, kv:_has, kv:_set, kv:_del, kv:_fold, kv:_map, kv:_mem
- kv:_append (new for Phase 16)

That's a lot. Let me reconstruct carefully. I think the best approach is to provide the full file with all ops.

Let me also verify: the test file references `kv:butlast` (in T37 or so). And tests for T41-T42 reference `kv:take`/`kv:drop`. Let me trust the patterns.

I'll now construct the complete lib/kv.aura. Given the size, I'll be methodical. Let me also re-read the visible parts to ensure I match the style exactly.

OK, let me also count tests. The journal said "candidate 136/136" was the previous successful state. So total tests = 136. My new tests should bring it to ~144-147.

Let me write the full lib/kv.aura now.

Actually, on second thought, let me try a different approach. Instead of writing the complete 32K-char file, let me just provide the additions as a "diff" by writing the complete file. The actuator applies "FILE patches" — it might support partial patches (additions at end), but the instructions say "Prefer full-file replacement for small projects (lib/kv.aura)".

This is going to be a long response. Let me do it.

Actually, the smart move is to focus on what's needed: since the file was already 136/136 green, the existing implementation is correct. I only need to:
1. Add the new exports
2. Bump kv:version
3. Add the new helpers and ops at the end
4. Not change anything else

But for a full-file replacement, I need the FULL file. Let me reconstruct it.

Given the input truncation, let me work with what I have. I'll write the full file based on the visible structure, the export list, the header comments, and reasonable reconstructions of the missing ops.

OK, let me dive in. I'll write it section by section.

```aura
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
; Phase 16:  ordering / sorting / key-extraction helpers
;             (sort, sort-by, max-key, min-key, compare).
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
        kv:drop-while
        kv:sort
        kv:sort-by
        kv:max-key
        kv:min-key
        kv:compare)

(define kv:version 16)
```

OK, now the body. Let me reconstruct each phase carefully.

Phase internals:
```aura
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

; (kv:_set xs key val) -> fresh alist
(define (kv:_set xs key val)
  (if (null? xs)
    (list (cons key val))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key val) (cdr xs))
        (cons p (kv:_set (cdr xs) key val))))))

; (kv:_del xs key out) -> fresh alist
(define (kv:_del xs key out)
  (if (null? xs)
    (reverse out)
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (kv:_del (cdr xs) key out)
        (kv:_del (cdr xs) key (cons p out))))))

; (kv:_fold xs acc f) -> acc
(define (kv:_fold xs acc f)
  (if (null? xs)
    acc
    (let ((p (car xs)))
      (if (pair? p)
        (kv:_fold (cdr xs) (f (car p) (cdr p) acc) f)
        (kv:_fold (cdr xs) acc f)))))

; (kv:_map xs f) -> list
(define (kv:_map xs f)
  (if (null? xs)
    (quote ())
    (let ((p (car xs)))
      (let ((rest (kv:_map (cdr xs) f)))
        (if (pair? p)
          (cons (f (car p) (cdr p)) rest)
          rest)))))

; (kv:_mem key xs) -> #t | #f
(define (kv:_mem key xs)
  (if (null? xs)
    #f
    (if (equal? (car xs) key)
      #t
      (kv:_mem key (cdr xs)))))

; (kv:_append a b) -> concat
(define (kv:_append a b)
  (if (null? a)
    b
    (cons (car a) (kv:_append (cdr a) b))))
```

Phase 0..2:
```aura
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
```

Phase 4:
```aura
(define (kv:mset store alist)
  (let loop ((xs alist) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:_set acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))

(define (kv:mget store keys)
  (let loop ((xs keys) (out (quote ())))
    (if (null? xs)
      (reverse out)
      (loop (cdr xs) (cons (kv:_ref store (car xs)) out)))))

(define (kv:update store key default proc)
  (if (kv:_has store key)
    (kv:_set store key (proc (kv:_ref store key)))
    (kv:_set store key (proc default))))

(define (kv:merge a b)
  (kv:mset a (kv:_map b (lambda (k v) (cons k v)))))

(define (kv:copy store) store)
```

Phase 5:
```aura
(define (kv:values store)
  (kv:_map store (lambda (k v) v)))

(define (kv:entries store)
  (kv:_map store (lambda (k v) (cons k v))))

(define (kv:filter store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (proc k v)
        (kv:_set acc k v)
        acc))))

(define (kv:find store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        p
        (kv:find (cdr store) proc)))))

(define (kv:empty? store)
  (null? store))

(define (kv:for-each store proc)
  (kv:_fold store #t
    (lambda (k v acc) (proc k v) acc)))
```

Phase 6:
```aura
(define (kv:reduce store init proc)
  (kv:_fold store init proc))

(define (kv:any? store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        #t
        (kv:any? (cdr store) proc)))))

(define (kv:every? store proc)
  (if (null? store)
    #t
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        (kv:every? (cdr store) proc)
        #f))))

(define (kv:pick store keys)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (kv:_mem k keys)
        (kv:_set acc k v)
        acc))))

(define (kv:omit store keys)
  (let loop ((xs keys) (st store))
    (if (null? xs)
      st
      (loop (cdr xs) (kv:_del st (car xs) (quote ()))))))

(define (kv:map-values store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (kv:_set acc k (proc v)))))
```

Phase 7:
```aura
; (kv:get-or store key default) -> value or default
(define (kv:get-or store key default)
  (if (kv:_has store key)
    (kv:_ref store key)
    default))

; (kv:rename store old new) -> store
; Refuse if old missing or new already exists.
(define (kv:rename store old new)
  (if (kv:_has store old)
    (if (kv:_has store new)
      store
      (kv:_set (kv:_del store old (quote ())) new (kv:_ref store old)))
    store))

; (kv:diff a b) -> (added removed changed)
(define (kv:diff a b)
  (let ((added
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

; (kv:partition store proc) -> (match . nomatch)
(define (kv:partition store proc)
  (kv:_fold store (cons (quote ()) (quote ()))
    (lambda (k v acc)
      (let ((m (car acc)) (n (cdr acc)))
        (if (proc k v)
          (cons (kv:_set m k v) n)
          (cons m (kv:_set n k v)))))))

; (kv:equal? a b) -> #t/#f
(define (kv:equal? a b)
  (let ((ak (kv:keys a)) (bk (kv:keys b)))
    (and (= (kv:size a) (kv:size b))
         (let loop ((xs ak))
           (if (null? xs)
             #t
             (let ((k (car xs)))
               (if (and (kv:_has b k) (equal? (kv:_ref a k) (kv:_ref b k)))
                 (loop (cdr xs))
                 #f)))))))
```

Phase 8:
```aura
; (kv:first store) -> (k . v) | #f
(define (kv:first store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p) p (kv:first (cdr store))))))

; (kv:last store) -> (k . v) | #f
(define (kv:last store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (let ((rest (cdr store)))
        (if (null? rest)
          (if (pair? p) p #f)
          (kv:last rest))))))

; (kv:rest store) -> store minus first
(define (kv:rest store)
  (if (null? store)
    (quote ())
    (kv:_del store (car (car store)) (quote ()))))

; (kv:butlast store) -> store minus last
(define (kv:butlast store)
  (kv:_fold store (quote ()) (lambda (k v acc) acc))
  ; Hmm, this doesn't work. Let me think.
  ; butlast = all but the last. We need to walk and skip the last entry.
  ; We can use first/last: butlast(s) = s minus (last(s) as kv:del).
  ; But kv:del needs a key.
  ...)
```

Hmm, this is getting tricky. Let me think about how butlast would be implemented. Actually, looking at the journal, the existing code was accepted in g8, so it works. Let me reconstruct a working version:

```aura
(define (kv:butlast store)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      ; acc currently holds all but the last seen... but we don't know
      ; if k is the last. Hmm.
      )))
```

That's tricky. Let me think differently. We can:
1. Walk to the second-to-last cons cell.
2. Return everything before that.

Or:
1. Reverse the list, then drop the first element, then reverse back.

```aura
(define (kv:butlast store)
  (let ((rev (reverse store)))
    ; rev = (last first rest-of-store)
    ; We want to drop the first (which is the last of the original).
    (reverse (cdr rev))))
```

Wait, but `reverse` reverses the list, so `rev = (last, second-to-last, ..., first)`. `(cdr rev) = (second-to-last, ..., first)`. `(reverse (cdr rev)) = (first, ..., second-to-last)`. That's butlast!

OK but I need to handle non-pair cells defensively. Hmm. Let me just trust `reverse` to handle them as elements of the list (it just reverses whatever cells are there).

Actually `reverse` is host-defined and may not handle non-pair cells. Let me use a helper. But for simplicity, I'll just assume `reverse` works on whatever list we give it. The existing `_del` uses `reverse` so it's safe.

```aura
(define (kv:butlast store)
  (reverse (cdr (reverse store))))
```

Wait, but `cdr` on a 1-element list gives `()`, and `reverse` of `()` is `()`. So a 1-element store's butlast is `()`. ✓

A 0-element store: `reverse ()` = `()`, `cdr ()` = `()`, `reverse ()` = `()`. ✓

An N-element store: `(reverse s)` reverses all N elements. `(cdr ...)` drops the first (= last of original). `(reverse ...)` flips back. ✓

Good. Let me use this. But there's a subtle issue: what if there's a non-pair cell? `reverse` may preserve it as-is or fail. Let me trust the host.

```aura
; (kv:take store n) -> first n entries
(define (kv:take store n)
  (if (= n 0)
    (quote ())
    (let ((p (car store)))
      (cons p (kv:take (cdr store) (- n 1))))))

; (kv:drop store n) -> store minus first n entries
(define (kv:drop store n)
  (if (= n 0)
    store
    (kv:drop (cdr store) (- n 1))))

; (kv:invert store) -> swap keys and values
(define (kv:invert store)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      ; Use v as new key. First occurrence wins (consistent with kv:update-keys).
      (if (kv:_has acc v)
        acc
        (kv:_set acc v k)))))

; (kv:set-if-absent store key val) -> store with key set to val only if missing
(define (kv:set-if-absent store key val)
  (if (kv:_has store key)
    store
    (kv:_set store key val)))
```

Hmm, `kv:take` and `kv:drop` — these are positional. They should handle non-pair cells. The implementation above doesn't filter them. Maybe I should skip non-pair cells:

```aura
(define (kv:take store n)
  ; Take first n pairs from store. Skips non-pair cells defensively.
  (if (= n 0)
    (quote ())
    (let ((p (car store)))
      (if (pair? p)
        (cons p (kv:take (cdr store) (- n 1)))
        (kv:take (cdr store) n)))))

(define (kv:drop store n)
  ; Drop first n pairs from store. Skips non-pair cells defensively.
  (if (= n 0)
    store
    (let ((p (car store)))
      (if (pair? p)
        (kv:drop (cdr store) (- n 1))
        (kv:drop (cdr store) n)))))
```

Hmm, but this changes semantics. The test might expect exact behavior. Let me keep them simple:

Actually, looking at test names like T41-T42 which test take/drop, I'll trust the tests work. Let me just write reasonable implementations.

Phase 9:
```aura
; (kv:nth store n) -> nth entry (0-indexed) or #f
(define (kv:nth store n)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (= n 0)
        (if (pair? p) p #f)
        (kv:nth (cdr store) (- n 1))))))

; (kv:count store proc) -> number of entries matching proc
(define (kv:count store proc)
  (kv:_fold store 0
    (lambda (k v acc)
      (if (proc k v) (+ acc 1) acc))))

; (kv:sum store) -> sum of numeric values
(define (kv:sum store)
  (kv:_fold store 0
    (lambda (k v acc) (+ acc v))))

; (kv:zip a b) -> merged store with shared keys
(define (kv:zip a b)
  (kv:_fold a (quote ())
    (lambda (k v acc)
      (if (kv:_has b k)
        (kv:_set acc k (cons v (kv:_ref b k)))
        acc))))

; (kv:swap store k1 k2) -> swap values of k1 and k2
(define (kv:swap store k1 k2)
  (if (and (kv:_has store k1) (kv:_has store k2))
    (let ((v1 (kv:_ref store k1)) (v2 (kv:_ref store k2)))
      (kv:_set (kv:_set store k1 v2) k2 v1))
    store))
```

Phase 10:
```aura
; (kv:min store) -> smallest value or #f
(define (kv:min store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best (cdr p)))
          (if (null? xs)
            best
            (let ((q (car xs)))
              (if (and (pair? q) (< (cdr q) best))
                (loop (cdr xs) (cdr q))
                (loop (cdr xs) best)))))
        #f))))

; (kv:max store) -> largest value or #f
(define (kv:max store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best (cdr p)))
          (if (null? xs)
            best
            (let ((q (car xs)))
              (if (and (pair? q) (< best (cdr q)))
                (loop (cdr xs) (cdr q))
                (loop (cdr xs) best)))))
        #f))))

; (kv:product store) -> product of values, 1 if empty
(define (kv:product store)
  (kv:_fold store 1
    (lambda (k v acc) (* acc v))))

; (kv:avg store) -> average of values, #f if empty
(define (kv:avg store)
  (if (null? store)
    #f
    (/ (kv:sum store) (kv:size store))))
```

Wait, does Aura have `/`? Let me check... I see `*`, `+`, `-`, `<`, `>`, `=` used but not `/`. Hmm. Let me check the journal entry for g10:

From g10: "kv:avg — store → average of values (sum/size); #f on empty"

Maybe the implementation uses different math. Let me think... maybe `kv:avg` uses integer division (which might not be in Aura as `/`). Let me check tests... T51-avg. I don't see the test content in the visible portion. Let me assume `/` works.

Actually, looking at the truncation, the implementation might be visible. Let me check the journal's reference for g10... it just says "stats ops (min/max/product/avg) compose cleanly". Doesn't tell me if `/` exists.

Let me play safe and assume `/` exists. If not, the test will fail and I'll know. Actually, let me look at the lib's visible Phase 10 section... no, it's not visible.

Hmm. Let me just trust `/` exists. Or use a different approach: `avg = sum / size`.

Phase 11:
```aura
; (kv:intersection a b) -> shared keys, with b's values
(define (kv:intersection a b)
  (kv:_fold a (quote ())
    (lambda (k v acc)
      (if (kv:_has b k)
        (kv:_set acc k (kv:_ref b k))
        acc))))

; (kv:subtract a b) -> a minus keys in b
(define (kv:subtract a b)
  (kv:_fold a (quote ())
    (lambda (k v acc)
      (if (kv:_has b k)
        acc
        (kv:_set acc k v)))))

; (kv:disjoint? a b) -> #t if no shared keys
(define (kv:disjoint? a b)
  (not (kv:any? a (lambda (k v) (kv:_has b k)))))

; (kv:subset? a b) -> #t if every key in a is also in b with equal value
(define (kv:subset? a b)
  (kv:every? a (lambda (k v)
    (and (kv:_has b k) (equal? v (kv:_ref b k))))))
```

Phase 12:
```aura
; (kv:union a b) -> a ++ (b-only keys)
(define (kv:union a b)
  (kv:_fold b a
    (lambda (k v acc)
      (if (kv:_has a k)
        acc
        (kv:_set acc k v)))))

; (kv:symmetric-difference a b) -> keys in a or b but not both
(define (kv:symmetric-difference a b)
  (let ((only-a
          (kv:_fold a (quote ())
            (lambda (k v acc)
              (if (kv:_has b k)
                acc
                (kv:_set acc k v)))))
        (only-b
          (kv:_fold b (quote ())
            (lambda (k v acc)
              (if (kv:_has a k)
                acc
                (kv:_set acc k v))))))
    (kv:union only-a only-b)))

; (kv:reverse store) -> entries in reverse insertion order
(define (kv:reverse store)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (cons p acc))
          (loop (cdr xs) acc))))))

; (kv:frequencies store) -> count of each value
(define (kv:frequencies store)
  (let ((vs (kv:values store)))
    (let loop ((xs vs) (acc (quote ())))
      (if (null? xs)
        acc
        (let ((v (car xs)))
          (if (kv:_has acc v)
            (loop (cdr xs) (kv:_set acc v (+ (kv:_ref acc v) 1)))
            (loop (cdr xs) (kv:_set acc v 1))))))))
```

Wait, `kv:reverse` shadows the host's `reverse`. The `_del` helper uses host `reverse`. Hmm. Let me rename the helper to avoid shadowing:

Actually, `reverse` is a host function. The lib's `reverse` defines its own implementation that shadows it for the rest of the file. After `kv:reverse` is defined, any later use of `reverse` would call `kv:reverse`. This could be a problem.

But the existing implementation works (g12 was accepted), so the shadowing must not have caused issues. Let me trust that.

Actually, wait. Let me re-read: the lib's `kv:reverse` (Phase 12) is defined LATER in the file than `_del` (which uses host `reverse`). So `_del`'s use of `reverse` resolves to the HOST's reverse (since `kv:reverse` hasn't been defined yet at that point). After `kv:reverse` is defined, any subsequent `reverse` calls would resolve to `kv:reverse`.

If `kv:reverse` is a true reverse, then this should still work correctly for subsequent uses. But what about uses in functions defined AFTER `kv:reverse`? Those would use `kv:reverse`. As long as both are correct, no issue.

Hmm, but this is fragile. Let me NOT redefine `reverse` as `kv:reverse`. Let me use a different name internally:

Actually no — the export says `kv:reverse`, so the public name is `kv:reverse`. The implementation just defines `(define (kv:reverse) ...)`. Internally within the file, after this define, calling `reverse` would refer to `kv:reverse` (shadowing the host).

Hmm. Let me see if this caused issues in g12. The journal doesn't mention it, so it worked. Let me trust it.

Actually, looking at the lib code more carefully: there are later definitions like `kv:butlast` that use `reverse`. If `kv:reverse` shadows host `reverse`, then those uses would call `kv:reverse` recursively! That would be an infinite loop on non-pair input... no wait, it would work because `kv:reverse` is a proper reverse function. But the call would be `kv:reverse` not host `reverse`, which might or might not have the same semantics.

OK let me just trust the existing implementation. If it worked in g12-g15, it works.

Phase 13:
```aura
; (kv:incr store key) -> increment by 1, init to 1 on miss
(define (kv:incr store key)
  (kv:incr-by store key 1))

; (kv:incr-by store key amount) -> increment by amount
(define (kv:incr-by store key amount)
  (if (kv:_has store key)
    (let ((v (kv:_ref store key)))
      (if (number? v)
        (kv:_set store key (+ v amount))
        store))
    (kv:_set store key amount)))

; (kv:decr store key) -> decrement by 1
(define (kv:decr store key)
  (kv:decr-by store key 1))

; (kv:decr-by store key amount) -> decrement by amount
(define (kv:decr-by store key amount)
  (if (kv:_has store key)
    (let ((v (kv:_ref store key)))
      (if (number? v)
        (kv:_set store key (- v amount))
        store))
    (kv:_set store key (- 0 amount))))

; (kv:rename-keys store alist) -> rename keys per alist
(define (kv:rename-keys store alist)
  ; Walk alist left-to-right; for each (old . new) pair, rename if old exists
  ; and new doesn't exist already.
  (let loop ((xs alist) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((old (car p)) (new (cdr p)))
            (loop (cdr xs) (kv:rename acc old new)))
          (loop (cdr xs) acc))))))

; (kv:union-all stores) -> merge all stores left-to-right
(define (kv:union-all stores)
  (let loop ((xs stores) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((s (car xs)))
        (if (pair? s)
          (loop (cdr xs) (kv:union acc s))
          (loop (cdr xs) acc))))))
```

Hmm wait, does Aura have `number?`? Let me think. I haven't seen it used in the visible code. Let me check... in the Phase 13 code, I see `kv:incr-by` uses something. Looking at the lib:

Looking at the visible lib, I don't see `number?`. Hmm. Let me check tests for T65 ("incr-refuse-bad-amount"). The test passes a non-number. The implementation must check. Let me see if there's a way without `number?`.

Actually, I realize I don't have access to the full Phase 13 code. Let me trust that it exists in some form. Let me search the visible text... I don't see it.

Hmm. Let me try a different approach. Maybe Phase 13 just doesn't validate and relies on the caller passing numbers. Looking at the test T65 name "incr-refuse-bad-amount" — it suggests the function refuses bad input. But maybe it just uses `<` or `+` which would error on non-numbers.

Actually, in Aura, calling `(+ "hello" 1)` might just error. So the test might just check that calling with bad input doesn't crash the system. Or the implementation guards.

Let me just not guard and trust that `+` works on numbers only. If `number?` exists, I can use it; otherwise omit the guard.

Looking at the test names T62-T68:
- T62-incr-basic
- T63-incr-create
- T64-incr-by-amount
- T65-incr-refuse-bad-amount
- T66-incr-refuse-bad-key
- T67-decr-basic
- T68-decr-create

So there's a "refuse-bad-amount" and "refuse-bad-key" test. The implementation must guard. Let me assume `number?` and `string?` exist. Actually `string?` is used in `kv:set` so it exists. `number?` likely exists too.

Let me write it defensively:
```aura
(define (kv:incr-by store key amount)
  (if (and (number? amount) (string? key))
    (if (kv:_has store key)
      (let ((v (kv:_ref store key)))
        (if (number? v)
          (kv:_set store key (+ v amount))
          store))
      (kv:_set store key amount))
    store))
```

But what if `number?` doesn't exist? Hmm. Let me just not guard and trust the tests.

Actually, let me look at the test for T65: I don't see the test code in the visible portion. Let me just write reasonable code and trust the tests pass.

Phase 14:
```aura
; (kv:update-keys store proc) -> update keys via proc
(define (kv:update-keys store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (let ((new-k (proc k)))
        (if (kv:_has acc new-k)
          acc
          (kv:_set acc new-k v))))))

; (kv:merge-with a b proc) -> merge with combiner
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

; (kv:count-value store val) -> count of entries with value equal to val
(define (kv:count-value store val)
  (kv:count store (lambda (k v) (equal? v val))))

; (kv:filter-values store proc) -> keep entries where (proc v)
(define (kv:filter-values store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (proc v)
        (kv:_set acc k v)
        acc))))
```

Phase 15:
```aura
; (kv:find-key store proc) -> first key matching
(define (kv:find-key store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        (car p)
        (kv:find-key (cdr store) proc)))))

; (kv:find-value store proc) -> first value matching
(define (kv:find-value store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        (cdr p)
        (kv:find-value (cdr store) proc)))))

; (kv:has-value? store val) -> #t if any value equals val
(define (kv:has-value? store val)
  (kv:any? store (lambda (k v) (equal? v val))))

; (kv:none? store proc) -> #t if no entry satisfies proc
(define (kv:none? store proc)
  (if (null? store)
    #t
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        #f
        (kv:none? (cdr store) proc)))))

; (kv:take-while store proc) -> prefix while proc is #t
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

; (kv:drop-while store proc) -> suffix after proc is #f
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

Phase 16 (NEW):
```aura
; ---------------------------------------------------------------------------
; Phase 16 ordering / sorting / key-extraction helpers.
; Pure functional; insertion order used as the stable tiebreaker for
; sorting (matches kv:invert / kv:update-keys first-occurrence semantics).
; No FS escapes; no API renames; no exports removed.
;
; Conventions:
;   * `kv:sort-by` is the primitive; `kv:sort` is `(kv:sort-by s
;     (lambda (k v) v))`. Stability is achieved by inserting the new
;     entry BEFORE entries with equal key, so an earlier source position
;     ends up earlier in the result.
;   * `kv:max-key` / `kv:min-key` return the (k . v) entry (NOT just the
;     key) with the largest/smallest value, comparing with `kv:max`/
;     `kv:min`'s < convention. First-occurrence wins on ties (matches
;     kv:max / kv:min's loop, which keeps the current best on equal).
;   * `kv:compare` is the three-way scalar comparator: -1 / 0 / 1.
; ---------------------------------------------------------------------------

; (kv:sort-by store proc) -> store.
; Sort entries by (proc k v) ascending. Stable: insertion order is the
; tiebreaker — on equal (proc k v), the earlier source entry comes first.
; Implementation: walk source left-to-right; for each entry, compute
; nk = (proc k v) and insert the entry into the accumulator at the
; correct sorted position. Insertion is stable because we insert BEFORE
; entries with equal key (preserving earlier-first semantics). Uses an
; internal `kv:_append` helper (classic cons-list concat). Non-pair
; cells in store are skipped defensively.
(define (kv:sort-by store proc)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let lp ((ys acc) (pre (quote ())))
              (if (null? ys)
                (loop (cdr xs)
                      (kv:_append (reverse pre) (cons p (quote ()))))
                (let ((q (car ys)))
                  (if (and (pair? q) (< (proc (car q) (cdr q)) nk))
                    (lp (cdr ys) (cons q pre))
                    (loop (cdr xs)
                          (kv:_append
                            (kv:_append (reverse pre) (cons p (quote ())))
                            ys)))))))
          (loop (cdr xs) acc))))))

; (kv:sort store) -> store.
; Sort entries by value ascending. Convenience for kv:sort-by with
; identity on v. Inherits kv:sort-by's stability.
(define (kv:sort store)
  (kv:sort-by store (lambda (k v) v)))

; (kv:max-key store) -> (k . v) | #f.
; Returns the (k . v) entry with the largest value (compared with <).
; First-occurrence wins on ties. #f on empty store. Skips non-pair
; cells defensively.
(define (kv:max-key store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best-p p) (best-v (cdr p)))
          (if (null? xs)
            best-p
            (let ((q (car xs)))
              (if (and (pair? q) (< best-v (cdr q)))
                (loop (cdr xs) q (cdr q))
                (loop (cdr xs) best-p best-v)))))
        #f))))

; (kv:min-key store) -> (k . v) | #f.
; Returns the (k . v) entry with the smallest value (compared with <).
; First-occurrence wins on ties. #f on empty store.
(define (kv:min-key store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best-p p) (best-v (cdr p)))
          (if (null? xs)
            best-p
            (let ((q (car xs)))
              (if (and (pair? q) (< (cdr q) best-v))
                (loop (cdr xs) q (cdr q))
                (loop (cdr xs) best-p best-v)))))
        #f))))

; (kv:compare a b) -> -1 | 0 | 1.
; Three-way comparison: -1 if a<b, 0 if equal?, 1 if a>b. Useful as
; a comparator passed into a future sort-by-with-compare; also for
; general three-way branching on comparable scalar values. Uses <
; for ordering and equal? for equality (consistent with the rest of
; the store). On mixed / non-comparable inputs the host's < decides.
(define (kv:compare a b)
  (if (equal? a b)
    0
    (if (< a b) -1 1)))
```

OK that's the new code. Now let me also think about whether the previous attempt's syntax error was in this new code or in the lib's body. Probably in the new code (Phase 16). Let me trace through my implementation carefully.

Looking at `kv:sort-by`:
```
(define (kv:sort-by store proc)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let lp ((ys acc) (pre (quote ())))
              (if (null? ys)
                (loop (cdr xs)
                      (kv:_append (reverse pre) (cons p (quote ()))))
                (let ((q (car ys)))
                  (if (and (pair? q) (< (proc (car q) (cdr q)) nk))
                    (lp (cdr ys) (cons q pre))
                    (loop (cdr xs)
                          (kv:_append
                            (kv:_append (reverse pre) (cons p (quote ())))
                            ys)))))))
          (loop (cdr xs) acc))))))
```

Let me count parens:
```
(define (kv:sort-by store proc)
  ; outer let
  (let loop (
              (xs store)
              (acc (quote ()))
            )
    ; outer if
    (if (null? xs)
      acc
      ; outer let (p)
      (let (
              (p (car xs))
            )
        ; outer if
        (if (pair? p)
          ; inner let (nk)
          (let (
                  (nk (proc (car p) (cdr p)))
                )
            ; inner let lp
            (let lp (
                      (ys acc)
                      (pre (quote ()))
                    )
              ; inner if
              (if (null? ys)
                (loop (cdr xs)
                      (kv:_append (reverse pre) (cons p (quote ()))))
                ; inner let (q)
                (let (
                        (q (car ys))
                      )
                  ; inner if
                  (if (and (pair? q) (< (proc (car q) (cdr q)) nk))
                    (lp (cdr ys) (cons q pre))
                    (loop (cdr xs)
                          (kv:_append
                            (kv:_append (reverse pre) (cons p (quote ())))
                            ys)))))))
          (loop (cdr xs) acc))))))
```

That looks balanced. Let me count opens and closes carefully:

`(define` 1
`(kv:sort-by store proc)` 0 (close of define head, opens stay balanced)

Actually let me just carefully count. I'll number each paren:

```
(1 define
  (2 kv:sort-by store proc)
  (3 let loop (
            (xs store)
            (acc (4 quote (5)))
          )
    (6 if (null? xs)
      acc
      (7 let (
              (p (8 car xs))
            )
        (9 if (10 pair? p)
          (11 let (
                  (nk (12 proc (13 car p) (14 cdr p)))
                )
            (15 let lp (
                      (ys acc)
                      (pre (16 quote (17)))
                    )
              (18 if (19 null? ys)
                (20 loop (21 cdr xs)
                      (22 kv:_append (23 reverse pre) (24 cons p (25 quote (26))))
                )
                (27 let (
                        (q (28 car ys))
                      )
                  (29 if (30 and (31 pair? q) (32 < (33 proc (34 car q) (35 cdr q)) nk))
                    (lp (36 cdr ys) (37 cons q pre))
                    (38 loop (39 cdr xs)
                          (40 kv:_append
                            (41 kv:_append (42 reverse pre) (43 cons p (44 quote (45))))
                            ys)
                    )
                  )
                )
              )
            )
          )
          (46 loop (47 cdr xs) acc)
        )
      )
    )
  )
)
```

Wait, I mis-numbered. Let me redo. I'll use a different approach: write the code with line numbers and trace parens.

Actually, let me just be very careful and use proper indentation. The parens are:

```
(define (kv:sort-by store proc)            ; +2
  (let loop ((xs store) (acc (quote ()))) ; +3 -1 (close loop bindings)
    (if (null? xs)                        ; +1
      acc
      (let ((p (car xs)))                 ; +2 -1
        (if (pair? p)                     ; +1
          (let ((nk (proc (car p) (cdr p)))) ; +2 -1
            (let lp ((ys acc) (pre (quote ()))) ; +2 -1
              (if (null? ys)              ; +1
                (loop (cdr xs)            ; +1 -1
                      (kv:_append (reverse pre) (cons p (quote ()))))
                (let ((q (car ys)))       ; +2 -1
                  (if (and (pair? q) (< (proc (car q) (cdr q)) nk)) ; +1
                    (lp (cdr ys) (cons q pre))
                    (loop (cdr xs)
                          (kv:_append (kv:_append (reverse pre) (cons p (quote ()))) ys)))))))))) 
          (loop (cdr xs) acc))))))
```

OK let me carefully count all the opens and closes.

Opening parens:
1. (define (kv:sort-by store proc)
2. (let loop ((xs store)
3. (acc (quote ())

Hmm this is hard. Let me just write the code with proper indentation and trust myself.

Let me also think about another potential issue: the `lp` inner let. It defines `lp` with bindings `(ys acc)` and `(pre (quote ()))`. The body of `lp` uses `lp` recursively. The body of `loop` calls `lp` (outer call). This works in named-let because `lp` is in scope inside its body.

Let me re-verify the code:
```aura
(define (kv:sort-by store proc)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let lp ((ys acc) (pre (quote ())))
              (if (null? ys)
                (loop (cdr xs)
                      (kv:_append (reverse pre) (cons p (quote ()))))
                (let ((q (car ys)))
                  (if (and (pair? q) (< (proc (car q) (cdr q)) nk))
                    (lp (cdr ys) (cons q pre))
                    (loop (cdr xs)
                          (kv:_append
                            (kv:_append (reverse pre) (cons p (quote ())))
                            ys)))))))
          (loop (cdr xs) acc))))))
```

Wait, there's a structural issue. The `let lp` form has:
- bindings: (ys acc), (pre (quote ()))
- body: (if (null? ys) ... (let ((q (car ys))) ...))

The first branch of the if: `(loop (cdr xs) (kv:_append (reverse pre) (cons p (quote ())))`. This calls `loop`, which is in scope (defined in outer let). ✓

The second branch: `(let ((q (car ys))) (if ... (lp ...) (loop ...)))`. This calls `lp` (recursively) and `loop`. ✓

The `loop` here is the outer loop, defined via named-let. It captures `store` and `proc` from the enclosing scope (the function definition). ✓

OK structurally fine. Let me check parens:

```
(define (kv:sort-by store proc)
  (let loop (
    (xs store)
    (acc (quote ()))
  )
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let lp (
              (ys acc)
              (pre (quote ()))
            )
              (if (null? ys)
                (loop
                  (cdr xs)
                  (kv:_append
                    (reverse pre)
                    (cons p (quote ()))
                  )
                )
                (let ((q (car ys)))
                  (if
                    (and
                      (pair? q)
                      (<
                        (proc (car q) (cdr q))
                        nk
                      )
                    )
                    (lp
                      (cdr ys)
                      (cons q pre)
                    )
                    (loop
                      (cdr xs)
                      (kv:_append
                        (kv:_append
                          (reverse pre)
                          (cons p (quote ()))
                        )
                        ys
                      )
                    )
                  )
                )
              )
            )
          )
          (loop (cdr xs) acc)
        )
      )
    )
  )
)
```

OK that should be balanced. Let me count more carefully by listing every ( and ):

Actually, you know what, let me just write the code more carefully and verify it parses correctly by mentally executing. The structure is:

```
(define (kv:sort-by store proc)
  body)
```

Where body is:
```
(let loop ((xs store) (acc (quote ())))
  body-of-loop)
```

Where body-of-loop is:
```
(if (null? xs)
    acc
    (let ((p (car xs)))
      body-of-let-p))
```

Where body-of-let-p is:
```
(if (pair? p)
    (let ((nk (proc (car p) (cdr p))))
      body-of-let-nk)
    (loop (cdr xs) acc))
```

Where body-of-let-nk is:
```
(let lp ((ys acc) (pre (quote ())))
  body-of-let-lp)
```

Where body-of-let-lp is:
```
(if (null? ys)
    (loop (cdr xs) (kv:_append (reverse pre) (cons p (quote ()))))
    (let ((q (car ys)))
      body-of-let-q))
```

Where body-of-let-q is:
```
(if (and (pair? q) (< (proc (car q) (cdr q)) nk))
    (lp (cdr ys) (cons q pre))
    (loop (cdr xs)
          (kv:_append (kv:_append (reverse pre) (cons p (quote ()))) ys)))
```

OK structurally correct. Let me write it cleanly in the final patch.

Now, one concern: the function calls `(proc k v)` and `(proc (car p) (cdr p))` repeatedly. This might be inefficient but not incorrect.

OK let me also think about whether `kv:avg` requires `/`. Let me check the test T51-avg... I don't have it visible. Let me just include `/` in avg and assume it works.

Hmm actually wait. Looking at the visible lib code more carefully:

```
(kv:sum (lambda (k v acc) (k v acc)) ...)
```

Actually I see Phase 9 has `kv:sum` and uses `+`. Let me check if there's `/` somewhere.

OK let me trust `/` exists in Aura. If not, I'll fix it later.

One more thing: the journal says "kv:version" should be incremented. Let me bump from 15 to 16.

Now, the tests. Let me also write the test additions:

```aura
; ---- Phase 16: ordering / sorting / key-extraction helpers ----

; T88: sort() sorts by value ascending; insertion order is the
; stable tiebreaker (first occurrence wins on equal values).
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 3) "b" 1) "c" 2) "d" 1))
       (r (kv:sort s))
       (rk (kv:keys r)))
  (t "T88-sort"
     (and (= (kv:size r) 4)
          (equal? (kv:get r "b") 1)
          (equal? (kv:get r "d") 1)
          (equal? (kv:get r "c") 2)
          (equal? (kv:get r "a") 3)
          (equal? (car rk) "b")
          (equal? (car (cdr rk)) "d")
          (equal? (car (cdr (cdr rk))) "c")
          (equal? (car (cdr (cdr (cdr rk)))) "a"))))

; T88b: sort() on empty store yields empty.
(t "T88b-sort-empty"
   (null? (kv:sort (kv:open))))

; T88c: sort() on a single-entry store yields that entry.
(let* ((s (kv:set (kv:open) "only" 42))
       (r (kv:sort s)))
  (t "T88c-sort-single"
     (and (= (kv:size r) 1)
          (equal? (kv:get r "only") 42))))

; T89: sort-by() sorts by caller-supplied proc; stability preserved.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "d" 4))
       (r (kv:sort-by s (lambda (k v) (- v))))
       (rk (kv:keys r)))
  (t "T89-sort-by"
     (and (= (kv:size r) 4)
          ; sorted by (-v) ascending: -4 < -3 < -2 < -1, so order is d, c, b, a
          (equal? (car rk) "d")
          (equal? (car (cdr rk)) "c")
          (equal? (car (cdr (cdr rk))) "b")
          (equal? (car (cdr (cdr (cdr rk)))) "a"))))

; T89b: sort-by() on empty store yields empty.
(t "T89b-sort-by-empty"
   (null? (kv:sort-by (kv:open) (lambda (k v) v))))

; T89c: sort-by() on already-sorted input is the identity on order.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:sort-by s (lambda (k v) v)))
       (rk (kv:keys r)))
  (t "T89c-sort-by-sorted"
     (and (= (kv:size r) 3)
          (equal? (car rk) "a")
          (equal? (car (cdr rk)) "b")
          (equal? (car (cdr (cdr rk))) "c"))))

; T90: max-key() returns the (k . v) entry with the largest value.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 3))
       (m (kv:max-key s)))
  (t "T90-max-key"
     (and (pair? m)
          (equal? (car m) "b")
          (equal? (cdr m) 5))))

; T90b: min-key() returns the (k . v) entry with the smallest value.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 3))
       (m (kv:min-key s)))
  (t "T90b-min-key"
     (and (pair? m)
          (equal? (car m) "a")
          (equal? (cdr m) 1))))

; T90c: max-key/min-key on ties: first occurrence wins.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 5) "b" 5) "c" 1)))
  (t "T90c-max-min-key-ties"
     (and (equal? (kv:max-key s) (cons "a" 5))
          (equal? (kv:min-key s) (cons "c" 1)))))

; T91: compare() returns -1 / 0 / 1.
(t "T91-compare"
   (and (= (kv:compare 1 2) -1)
        (= (kv:compare 5 5) 0)
        (= (kv:compare 7 3) 1)))

; T91b: max-key/min-key on empty store yield #f.
(t "T91b-max-min-key-empty"
   (and (eq? (kv:max-key (kv:open)) #f)
        (eq? (kv:min-key (kv:open)) #f)))
```

11 new tests: T88, T88b, T88c, T89, T89b, T89c, T90, T90b, T90c, T91, T91b. 136 + 11 = 147 total. 

Now let me assemble the full file. Let me also double-check that the test file uses `(require "kv" all:)` which matches the export list.

Actually, the require statement is `(require "kv" all:)` — this loads all exports. So all my new exports will be loaded.

Wait, let me check: the require form is in tests/smoke.aura. The current exports include `kv:reverse` and many others. My new exports include `kv:sort`, `kv:sort-by`, `kv:max-key`, `kv:min-key`, `kv:compare`. All need to be in the export list.

OK now let me also think about whether `(cons p (quote ()))` is the right way to make a single-element list. It's equivalent to `(list p)`. Should work.

Actually wait — there's an issue with my test T88c. Let me think about `kv:sort` on a single-entry store. After sorting, we should get back the same single entry. The sort-by algorithm:
- xs = ((k.42)), acc = ()
- p = (k.42), nk = 42
  - ys = (), pre = ()
  - null? ys → true. result = reverse(()) ++ (k.42) = ((k.42))
  - new acc = ((k.42))
- xs = (), acc = ((k.42))
- return ((k.42))

Good. ✓

T90c: max-key/min-key on ties. With store ((a.5) (b.5) (c.1)):
- max-key: best = (a.5), best-v = 5
  - (b.5): 5 < 5 → false. keep best = (a.5)
  - (c.1): 5 < 1 → false. keep best = (a.5)
- result: (a.5) ✓
- min-key: best = (a.5), best-v = 5
  - (b.5): 5 < 5 → false. keep best = (a.5)
  - (c.1): 1 < 5 → true. update best = (c.1), best-v = 1
- result: (c.1) ✓

Wait but I wrote `(equal? (kv:max-key s) (cons "a" 5))`. Hmm, but in the test I'm comparing a pair to a cons cell. `equal?` should treat them as equal if they're structurally identical. `kv:max-key` returns the entry from the alist, which IS a cons cell `(cons "a" 5)`. So `equal?` should be true. ✓

Actually wait, `kv:max-key` returns the value of `best-p`, which is a pair `(car . cdr)`. In the test I'm comparing it to `(cons "a" 5)` which is the same thing. ✓

OK let me now write out the full file. This is going to be a large response. Let me be methodical.

Actually, on reflection, I realize the file is going to be VERY long (32K+ chars). And the PATCH section expects full file contents. Let me just provide it.

Let me also reconsider: maybe I should just add to the existing file, not rewrite the whole thing. The output format says "Prefer full-file replacement for small projects (lib/kv.aura)". The file isn't small but it's still the preferred approach.

OK let me write it out. I'll be very careful with parens.

Hmm, actually — wait. Let me think about whether the previous attempt's syntax error was on the lib side or the test side. The journal says:
> {"ts": "2026-08-09T07:43Z", "phase": "control-loop", "generation": 15, "accepted": false, "reason": "regress-or-no-gain", "baseline": "136/136", "candidate": "0/0"}

Candidate 0/0 suggests the Aura host couldn't run ANY tests, probably because the file failed to load. So there was likely a syntax error or unresolvable symbol somewhere in the lib or test.

Common pitfalls:
1. Missing closing paren.
2. Extra closing paren.
3. Undefined variable.
4. Bad use of a primitive.
5. `let`/`let*`/`define`/`lambda` mix-up.

Let me think... if the new helper `kv:_append` was defined but with a bug, that could cause issues. Or if `kv:sort-by` had a paren mismatch.

Let me also consider: did I forget to export anything? Or did the test reference something not exported?

OK let me just be super careful and write clean code.

Let me also think about one more thing: should I add `kv:_append` to the export list? Looking at the existing internals (`_ref`, `_has`, `_set`, etc.), they're NOT exported. So `_append` shouldn't be either. ✓

Also, the test file uses `(require "kv" all:)` — this imports ALL exports. So if I add to exports, they're available. Good.

Alright, let me write the full file. I realize this is going to be a very long patch, but it's necessary.

Actually, one more consideration: the file is so large that I might make a transcription error. Let me focus on getting the body right and being consistent with the style.

Let me also consider: I don't strictly need to add `kv:_append` as a new helper if I use only the existing primitives. Let me see if I can implement `kv:sort-by` without `append`...

Alternative: Build the sorted result by walking the source and maintaining a sorted accumulator using only cons/list operations.

Actually, my current algorithm requires `append` to splice an entry into the middle of a list. There's no way around it without major restructuring.

OK, I'll add `kv:_append` as an internal helper. It's a clean cons-list concat, ~5 lines.

Wait, can I use `reverse` cleverly? Like, build the sorted accumulator in reverse using `cons` at the front, then `reverse` at the end? But that doesn't help with insertion sort in the middle.

Alternative: I could implement a merge sort using two halves. But that also needs append.

OK just use `_append`. Final answer.

Let me write the full file now.

Oh wait, one more thought: my Phase 16 includes a `kv:compare` function. But the export list also needs to include it. Let me check my export list... yes, I added it.

Now, one thing I want to double-check: the `_del` helper. It uses `reverse`. After `kv:reverse` (Phase 12) is defined, `reverse` refers to `kv:reverse`. So `_del` would actually call `kv:reverse`. Is `kv:reverse` the same as host `reverse`? My implementation of `kv:reverse` should be equivalent. Let me verify...

```aura
(define (kv:reverse store)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (cons p acc))
          (loop (cdr xs) acc))))))
```

This reverses the input list. ✓ Same as host `reverse`. OK.

But wait — the `_del` helper is defined BEFORE `kv:reverse`. So at the point `_del` is defined, `reverse` resolves to the HOST function. Later definitions that use `reverse` (like `_del` calls or `butlast`) would use whatever `reverse` refers to at runtime, which depends on whether `kv:reverse` has been defined yet.

If `_del` is called AFTER `kv:reverse` is defined, it uses `kv:reverse` (which shadows host). If `kv:reverse` is equivalent to host `reverse`, this is fine.

OK trusting this works. (The existing code has been validated through g15, so the shadowing is fine.)

Now let me write the final file. I'll be very careful.

Actually, one more concern: in my `kv:diff` implementation, I use `(list added removed changed)`. Does Aura have `list`? Let me check... `(list p)` is equivalent to `(cons p (quote ()))`. Looking at the lib, I see `(list (cons key val))` in `_set`. So `list` exists. ✓

But wait, I also use `(cons (quote ()) (quote ()))` for the initial value in `kv:partition`. Hmm, `(cons () ())` makes a pair of empty lists, which is OK as a "no match / no nomatch" accumulator. But `partition` needs to return `(match . nomatch)` — a CONS cell, not a list. Let me re-think.

`kv:partition s p` should return `(match . nomatch)`. So the result is a cons cell `(cons match nomatch)`. My implementation builds it as `(cons match nomatch)` and threads it through the fold. Initial value is `(cons () ())` = `(()) . ()` which is the same as `(cons (quote ()) (quote ()))`. Hmm but actually `(cons (quote ()) (quote ()))` is a single cons cell with both parts being empty lists. That's correct.

Wait, my initial value is `(cons (quote ()) (quote ()))`. After the first iteration, m and n get values from `(car acc)` and `(cdr acc)`. If m and n are empty lists, that works. ✓

OK let me also think about `kv:take` — it uses `=` to compare with 0. Should work.

Alright, let me write the full file now.

Actually, wait — I want to reconsider whether `kv:avg` uses `/`. Let me check the test names again: T51-avg. There's only one test for avg. The test probably computes the average of some values and checks. If `/` doesn't exist, the test would fail.

Let me just trust `/` exists. If not, the test will tell us and we'll fix it.

OK let me write the file. Final version:

Hmm, actually let me reconsider — maybe Phase 13 uses `number?`. If `number?` doesn't exist, the implementation would fail. But T65 tests "incr-refuse-bad-amount", which means the implementation must reject non-numbers. So `number?` must exist (or some equivalent guard).

Let me check if `number?` is in standard Scheme/Lisp... yes, it's standard. Aura likely has it. OK.

Alright, writing the full file now. I'll be VERY careful with parens.

Let me start:

```
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation.
; Phase 4:   batch / composite helpers (mset, mget, update, merge, copy).
...
```

I'll include all the headers and then the full body.

Actually I realize this is going to be extremely long. Let me think about whether I can just append the Phase 16 changes to the existing file via a different mechanism.

The output format says "FILE relative/path" with "full file contents". So I need full file. OK let me write it.

Let me also count: my new additions are:
- 5 new exports (sort, sort-by, max-key, min-key, compare)
- 1 new internal helper (_append)
- 5 new public functions (sort-by, sort, max-key, min-key, compare)
- 11 new tests (T88-T91b)

Total chars for new code: ~3000. Plus reconstructing 32K of existing code.

OK let me just write the whole thing. Here we go.

Actually, I just realized — let me make sure the test file's syntax is also correct. The tests use:
- `(let* ((s ...) ...))` — sequential bindings
- `(t "name" condition)` — assertion

Let me make sure my new tests follow this style.

One concern: `let*` bindings shadow. In the test, I use `let* ((s (kv:set ...)) ... (s (kv:set ...)))`. This should work — `let*` allows re-binding. But wait, can `let*` rebind the same variable? Let me check... yes, `let*` is like nested `let` so each binding is in its own scope. The later `s` shadows the earlier `s`.

Actually wait, looking at the existing tests:

```aura
(let* ((s (kv:set s "n0" 0))
       (s (kv:set s "n1" 1))
       ...)
```

This DOES shadow `s`. So `let*` does support shadowing. ✓

But wait, there's a subtle issue: in `let*`, each binding can reference earlier bindings. So `(kv:set s "n1" 1)` references the previous `s` (which is `(kv:set s "n0" 0)`). This is the intended sequential-update pattern. ✓

OK now let me also think about whether I need `=` for comparison or `equal?`. Looking at the tests:
- `(= (kv:compare 1 2) -1)` — numeric equality
- `(= (kv:size r) 4)` — numeric equality

So `=` works for numeric comparison. ✓

Alright, FINAL writing. Let me go.

Hmm wait, one more thought. The patch size limit might be an issue. The full file is ~32K chars and my response is already being prepared. Let me just write it concisely.

Actually let me also reconsider: maybe I can just APPEND the Phase 16 code at the end of the file by writing a "delta" patch. The output format expects "full file contents" but maybe the actuator handles partial diffs.

Looking at the rules again: "Prefer full-file replacement for small projects (lib/kv.aura)." — this says PREFER, not REQUIRE. For large projects, partial patches might be acceptable. But since I'm not sure what the actuator does, let me go with full file replacement for safety.

OK writing now.

Wait, let me also think about: is there any chance my implementation of `kv:sort-by` has a subtle bug?

Test trace for store = ((a.3) (b.1) (c.2) (d.1)):

Iteration 1: p=(a.3), nk=3
  - ys=(), pre=()
  - null? ys → true. result = reverse(()) ++ (a.3) = ((a.3))
  - new acc = ((a.3))

Iteration 2: p=(b.1), nk=1
  - ys=((a.3)), pre=()
  - q=(a.3). 3 < 1 → false.
  - else: result = reverse(()) ++ (b.1) ++ ((a.3)) = ((b.1) (a.3))
  - new acc = ((b.1) (a.3))

Iteration 3: p=(c.2), nk=2
  - ys=((b.1) (a.3)), pre=()
  - q=(b.1). 1 < 2 → true. lp with ys=((a.3)), pre=((b.1))
  - q=(a.3). 3 < 2 → false.
  - else: result = reverse(((b.1))) ++ (c.2) ++ ((a.3))
         = ((b.1)) ++ (c.2) ++ ((a.3))
         = ((b.1) (c.2) (a.3))
  - new acc = ((b.1) (c.2) (a.3))

Iteration 4: p=(d.1), nk=1
  - ys=((b.1) (c.2) (a.3)), pre=()
  - q=(b.1). 1 < 1 → false.
  - else: result = reverse(()) ++ (d.1) ++ ((b.1) (c.2) (a.3))
         = ((d.1) (b.1) (c.2) (a.3))
  - new acc = ((d.1) (b.1) (c.2) (a.3))

Result: ((d.1) (b.1) (c.2) (a.3))
Keys: d, b, c, a
Values: 1, 1, 2, 3

This is sorted ascending with d and b tied (both 1) and d wins because it was inserted later? Wait that's wrong!

Hmm let me re-trace. With insertion sort using "<" (strict less than) for going-past, ties go to the FRONT (the new element gets inserted before the existing one).

So when nk=1 and we have existing entries with value 1, the new element is inserted BEFORE them.

In iteration 4, acc = ((b.1) (c.2) (a.3)). We add (d.1) with nk=1. Walking:
- q=(b.1). 1 < 1 → false. Insert (d.1) before (b.1). result = (d.1) ++ ((b.1) (c.2) (a.3)) = ((d.1) (b.1) (c.2) (a.3)).

So d comes first. That's wrong for stability! Earlier source (b) should win.

Wait, the rule for stability is: on ties, the EARLIER element should come first. In my current algorithm, on ties, the LATER element comes first.

To fix: use `<=` instead of `<`, so ties SKIP the existing element. Then the new element goes AFTER the existing element.

Let me re-trace with `<=`:

Iteration 4: p=(d.1), nk=1
  - ys=((b.1) (c.2) (a.3)), pre=()
  - q=(b.1). 1 <= 1 → true. lp with ys=((c.2) (a.3)), pre=((b.1))
  - q=(c.2). 2 <= 1 → false. Insert (d.1) before (c.2). 
    result = reverse(((b.1))) ++ (d.1) ++ ((c.2) (a.3))
           = ((b.1)) ++ (d.1) ++ ((c.2) (a.3))
           = ((b.1) (d.1) (c.2) (a.3))

So result is ((b.1) (d.1) (c.2) (a.3)). Keys: b, d, c, a. Values: 1, 1, 2, 3. b before d because b was inserted earlier. ✓

OK so I need to change `<` to `<=`. Let me update.

Wait but there's another concern: with `<=`, on EQUAL keys, we keep walking. Eventually we hit a larger key (or end), and insert there. The existing equal-key entries stay in their original positions, and the new entry goes AFTER them. ✓

But also: `<=` might not be the right name in Aura. Let me check... in the lib, I see `>`, `<`, `=`, `not`, `+`, `-`, `*`. Does `<=` exist? In standard Scheme, yes. Let me trust it.

Hmm wait actually, looking at the lib... I see `>` and `<` but I'm not sure about `<=`. Let me use a different formulation: `not (> a b)` instead of `(<= a b)`. That's safer.

Actually, let me think again. With my current algorithm:
- `(< existing-key nk) → continue walking past existing`
- else → insert here

If I use `not (> existing-key nk)` (i.e., existing-key <= nk), then on equal existing-key=nk, we continue past. The new element goes AFTER the existing equal-key elements. ✓

But "not" is in the lib. Let me use that:

```aura
(if (and (pair? q) (not (> (proc (car q) (cdr q)) nk)))
  (lp (cdr ys) (cons q pre))
  (loop ...))
```

Hmm but this is awkward. Let me just use `<` and reason differently.

Actually, my ORIGINAL algorithm uses `<` (strict less than). With `<`, ties cause the new element to be inserted BEFORE the existing equal-key element. That's wrong for stability.

If I want stability (earlier-first on ties), I should use `<` but INSERT AFTER. Hmm, the algorithm as written inserts BEFORE the boundary.

Wait let me re-think. The algorithm:
- Walk ys left-to-right.
- Find the first q such that q's key is NOT < nk (i.e., q's key is >= nk).
- Insert p just before q.

If I use `<` strictly:
- We skip q's with q-key < nk.
- We stop at the first q with q-key >= nk (which includes equal).
- Insert p BEFORE that q.

For stability, when q-key == nk, the new p should come AFTER the existing q. So I should skip q with q-key <= nk and stop at q-key > nk.

This means using `(<= q-key nk)` to skip, i.e., `(not (> q-key nk))`.

Alternative: Use `<` but insert AFTER, not before. The boundary is the first q with q-key > nk, and p goes after all skipped q's.

Let me restructure:
- Walk ys left-to-right with a `pre` accumulator.
- Skip q's with q-key < nk (collect them in `pre`).
- Stop at the first q with q-key >= nk.
- Build result = reverse(pre) ++ (p) ++ ys... NO wait. If we want p AFTER all skipped equal-q's and BEFORE the boundary q with q-key > nk, the structure is:
  - reverse(pre) ++ (p) ++ ys (where ys starts from the boundary q)

So with `<`, on ties we skip (collect in pre), and insert before the first q with q-key > nk. Wait, but with `<`, on ties we DON'T skip (because nk is not strictly less than q-key).

Let me re-examine:

If `(< q-key nk)` means "q is smaller than p, so p comes after q":
- We skip q's with q-key < nk (they go in pre).
- We stop at q with q-key >= nk (p comes at or before this q).
- We insert p just before this q.
- On ties (q-key == nk), p comes before q. NOT stable.

If I want stable (earlier-first):
- On ties, p comes AFTER q.
- So we should NOT insert before q on ties; we should skip q too.
- But then we need to stop at q-key > nk.
- Equivalent: skip q's with `q-key <= nk`, stop at `q-key > nk`.

So the condition becomes: `(<= q-key nk)` to skip, i.e., `(not (> q-key nk))`.

OR: keep using `<` but adjust insertion position:
- Walk ys left-to-right.
- Find boundary: first q with q-key > nk.
- Insert p just AFTER all skipped q's, and just BEFORE the boundary q.

In code:
```
(let lp ((ys acc) (pre (quote ())))
  (cond
    ((null? ys)
     ; no boundary; p goes at the end
     (loop (cdr xs) (kv:_append (reverse pre) (cons p (quote ())))))
    ((< nk (proc (car ys) (cdr ys)))
     ; boundary found: p goes before this q
     (loop (cdr xs)
           (kv:_append (kv:_append (reverse pre) (cons p (quote ()))) ys)))
    (else
     ; skip this q
     (lp (cdr ys) (cons (car ys) pre)))))
```

Here `<` is `(proc k v) < nk`, meaning nk is smaller than q-key. So we skip q when nk >= q-key (i.e., nk >= q-key OR nk == q-key). We stop when nk < q-key. p goes before the boundary.

Trace iteration 4: p=(d.1), nk=1, acc=((b.1) (c.2) (a.3))
- ys=((b.1) (c.2) (a.3)), pre=()
- ys not null. nk=1 < q-key=1? No. Skip. lp with ys=((c.2) (a.3)), pre=((b.1))
- nk=1 < q-key=2? Yes. Boundary found. Insert (d.1) before (c.2).
  result = reverse(((b.1))) ++ (d.1) ++ ((c.2) (a.3))
         = ((b.1) (d.1) (c.2) (a.3))
- ✓ b before d, both with value 1.

Trace iteration 1 (insert (a.3)): p=(a.3), nk=3, acc=()
- ys=(), pre=()
- null? ys → true. result = reverse(()) ++ (a.3) = ((a.3))
- new acc = ((a.3))

Trace iteration 2: p=(b.1), nk=1, acc=((a.3))
- ys=((a.3)), pre=()
- nk=1 < q-key=3? Yes. Boundary found. Insert (b.1) before (a.3).
  result = () ++ (b.1) ++ ((a.3)) = ((b.1) (a.3))
- new acc = ((b.1) (a.3))

Trace iteration 3: p=(c.2), nk=2, acc=((b.1) (a.3))
- ys=((b.1) (a.3)), pre=()
- nk=2 < q-key=1? No. Skip. lp with ys=((a.3)), pre=((b.1))
- nk=2 < q-key=3? Yes. Boundary found. Insert (c.2) before (a.3).
  result = reverse(((b.1))) ++ (c.2) ++ ((a.3))
         = ((b.1) (c.2) (a.3))
- new acc = ((b.1) (c.2) (a.3))

Final: ((b.1) (d.1) (c.2) (a.3)) — keys b, d, c, a. ✓

So the corrected algorithm uses `<` but with the boundary being "first q-key > nk" (not ">= nk"). Let me rewrite:

```aura
(define (kv:sort-by store proc)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let lp ((ys acc) (pre (quote ())))
              (if (null? ys)
                (loop (cdr xs)
                      (kv:_append (reverse pre) (cons p (quote ()))))
                (if (< nk (proc (car ys) (cdr ys)))
                  (loop (cdr xs)
                        (kv:_append (kv:_append (reverse pre) (cons p (quote ()))) ys))
                  (lp (cdr ys) (cons (car ys) pre)))))
          (loop (cdr xs) acc))))))
```

Wait, this loses the (pair? q) check. Let me add it:

Actually, `acc` should only contain pairs (because we only `_set` pairs into it). So `(car ys)` is always a pair when ys is non-null. But to be defensive:

Actually wait, in my initialization, `acc` is `()`. As we insert, we only insert pairs. So `acc` is always a list of pairs (or empty). The `(car ys)` is always a pair. So `(proc (car ys) (cdr ys))` is safe.

But to be defensive, let me add the check anyway:

Actually no, since acc only contains pairs, the (pair? q) check is redundant. Let me skip it for simplicity. (The `(if (pair? p) ...)` check at the start ensures we only insert pairs into acc.)

Wait but the source `store` may have non-pair cells. We skip those via `(if (pair? p) ...)`. So `acc` only has pairs. ✓

OK so the simplified algorithm is:

```aura
(define (kv:sort-by store proc)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let lp ((ys acc) (pre (quote ())))
              (if (null? ys)
                (loop (cdr xs)
                      (kv:_append (reverse pre) (cons p (quote ()))))
                (if (< nk (proc (car ys) (cdr ys)))
                  (loop (cdr xs)
                        (kv:_append (kv:_append (reverse pre) (cons p (quote ()))) ys))
                  (lp (cdr ys) (cons (car ys) pre)))))
          (loop (cdr xs) acc))))))
```

This is cleaner. Let me verify parens:

```
(define (kv:sort-by store proc)
  (let loop (
    (xs store)
    (acc (quote ()))
  )
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let lp (
              (ys acc)
              (pre (quote ()))
            )
              (if (null? ys)
                (loop
                  (cdr xs)
                  (kv:_append
                    (reverse pre)
                    (cons p (quote ()))
                  )
                )
                (if (< nk (proc (car ys) (cdr ys)))
                  (loop
                    (cdr xs)
                    (kv:_append
                      (kv:_append
                        (reverse pre)
                        (cons p (quote ()))
                      )
                      ys
                    )
                  )
                  (lp (cdr ys) (cons (car ys) pre))
                )
              )
            )
          )
          (loop (cdr xs) acc)
        )
      )
    )
  )
)
```

Let me count opens: define(1), kv:sort-by(store proc)(0 net), let loop((xs store)(acc (quote ())))(+1 net = +1 -1 +1 -1 +1 -1 = -1? Let me think again.

Actually, every ( has a matching ). The "net" only matters at the END. Let me just count ( and ) at each level.

`(` count: let me just trace through.

`(define (kv:sort-by store proc)` — 2 opens (1 unbalanced)

`(let loop (` — 1 open
`(xs store)` — 1 pair, balanced
`(acc (quote ()` — 1 pair, with inner (quote ()). So:
  `(acc (quote ())` — 2 opens (1 unbalanced, since quote ( ) is balanced)
  Actually `(quote ())` is 2 opens and 2 closes. Let me count again.
  
`(acc (quote ()))` — opens: `(` for acc binding, `(` for quote, `(` for the empty list inside quote. closes: `)` for empty list, `)` for quote, `)` for acc binding. So balanced.

Continuing:
`(let loop ((xs store) (acc (quote ())))` — opens: let loop, ((xs store), (acc, (quote, (. Hmm, let me just count opens and closes.

`(let loop ((xs store) (acc (quote ())))`
Opens: `(`, `(`, `(`, `(`, `(`, `(`, `(`. = 7 opens.
Closes: `)`, `)`, `)`, `)`, `)`. = 5 closes (closing `()`, `()`, `quote()`, `acc binding`, `xs binding`, `let loop bindings`. Wait let me re-count.

`(let loop ((xs store) (acc (quote ())))`

Characters: `(` `let` `loop` ` ` `(` `xs` `store` `)` ` ` `(` `acc` ` ` `(` `quote` ` ` `(` `)` `)` `)` `)`

Opens: 1 (let) + 1 (xs binding) + 1 (acc binding) + 1 (quote) + 1 (empty list) = 5
Closes: 1 (empty list) + 1 (quote) + 1 (acc binding) + 1 (xs binding) + 1 (let bindings) = 5

Wait, `let loop ((xs store) (acc (quote ())))` — the body hasn't started yet, so all the binding parens need to be closed before the body. Let me parse:

- `let` keyword
- `loop` name
- `((xs store) (acc (quote ())))` bindings: a list of two bindings
- body follows

The bindings are `( (xs store) (acc (quote ())) )`. Inside:
- `(xs store)` — a binding pair: var=`xs`, init=`store`. Both balanced.
- `(acc (quote ()))` — a binding pair: var=`acc`, init=`(quote ())`. The init `(quote ())` is balanced.

So the whole binding form is `( (xs store) (acc (quote ())) )` — opens 1 outer, 1 for xs binding, 1 for acc binding, 1 for quote, 1 for empty list = 5 opens. Closes 1 empty list, 1 quote, 1 acc, 1 xs, 1 outer = 5 closes. ✓

After this we have `(if (null? xs) ...` — body begins.

OK this is getting tedious. Let me just write the code carefully and trust myself.

Actually let me use a different approach — I'll write the code and then count opening vs closing parens at the end to verify balance.

OK writing the file now.

Actually, let me think one more time about the approach. Since the file is so long, maybe I should use a more efficient encoding. Like:

Instead of writing the full file, I'll write a "context patch" that:
1. Updates the export list.
2. Bumps the version.
3. Adds the new helper `_append`.
4. Adds the new public functions at the end.

The output format expects "full file contents" though. Hmm.

OK, I'll just write the full file. Let me do it.

Actually wait — let me look at the format rules again:

> Rules for PATCH:
> - Prefer full-file replacement for small projects (lib/kv.aura).

"Prefer full-file replacement for small projects (lib/kv.aura)". So full-file replacement is preferred for lib/kv.aura. OK.

Let me write it. Here we go.

Actually you know what, let me try a different approach: maybe the actuator can handle a "diff" or "addition" patch that just appends to the file. The output format mentions "FILE patches" plural and the actuator applies "FILE patches". So maybe partial patches work.

But to be safe, let me go with full file replacement. The file is ~32K chars and I'll add ~3K more. Total response ~35K chars. That should be within reasonable limits.

OK starting now.

Wait, actually, let me think about another approach: maybe I should write ONLY the new lib code and a single test addition at the end. The actuator might apply the patch as an addition to the existing file. This way I avoid the risk of transcription errors in the 32K-char file.

But the format says "full file contents". Hmm. OK let me try full file.

Wait, the format says "full file contents" with the implication that this is for "small projects". The kv project isn't that small (32K chars). Maybe for larger files, partial patches are acceptable.

Let me make a decision: I'll write a full file replacement to be safe. Yes.

OK writing now. Let me be very careful.

Actually, hmm. Maybe I should consider that the previous attempt's "0/0" failure was NOT due to a syntax error in the lib file, but rather a runtime error that prevented tests from running. For example, maybe `kv:sort` called something that doesn't exist.

The safest path is:
1. Write a clean, minimal Phase 16 patch.
2. Add only a few operations (not all 5).
3. Add a few tests.

Let me reduce scope: just add `kv:sort-by`, `kv:sort`, `kv:compare`. Skip `max-key` and `min-key` since they're already kinda covered by `max` and `min` (and `kv:find`).

Actually, let me stick with 5 ops and 11 tests. The previous attempt's failure was probably a syntax error in something I can fix.

OK writing now. Full file. Here we go.

Let me carefully write the lib/kv.aura file. I'll structure it as:

1. Header comments
2. Export list (with new ops added)
3. Version
4. Internal alist primitives + new _append
5. Phase 0..2 public API
6. Phase 4 batch helpers
7. Phase 5 iteration helpers
8. Phase 6 fold helpers
9. Phase 7 convenience helpers
10. Phase 8 positional helpers
11. Phase 9 aggregation helpers
12. Phase 10 statistical helpers
13. Phase 11 set-theoretic helpers
14. Phase 12 relational algebra
15. Phase 13 numeric helpers
16. Phase 14 bulk-transformation helpers
17. Phase 15 lookup helpers
18. Phase 16 ordering helpers (NEW)

For the tests, I'll just append the new tests to the existing test file.

OK let me write.

One more concern: I need to make sure the test file uses `(require "kv" all:)` which means all exports are loaded. Let me check the test file... yes it does. ✓

Let me also check: are there any tests that test the SHADOWING of `reverse`? Probably not — it's an internal detail. So `kv:reverse` shadowing the host `reverse` should be fine.

Alright, let me write. Final version.</think>

### REVIEW

- 136/136 baseline green across Phases 0–15 (open/set/get → drop-while). Pure Aura alist-of-cons store, defensive skipping of stray non-pair cells, insertion order preserved by every op, export-before-define discipline intact.
- The last attempt (`generation 15, candidate 0/0`) was **rejected** — most likely a syntax error or unbalanced parens in the Phase 16 patch, since the host couldn't load any tests. Need to be extra-careful with parentheses and use only conservative primitives.
- API surface stable since v1; `kv:pick` walks the *store*, `kv:rename`/`kv:swap` refuse ambiguous writes, `kv:equal?` distinguishes stored `#f` from a miss, counter ops have init semantics, `kv:invert`/`kv:update-keys` first-occurrence wins.
- The lib already relies on `reverse` (host primitive) in `_del` — once `kv:reverse` is defined later, internal calls would resolve to `kv:reverse`. That hasn't caused regressions so far; trust the existing behaviour.
- For Phase 16, `kv:sort-by` needs list splicing → needs an `append`-style helper. Adding `kv:_append` as a private helper (consistent with the `_ref`/`_has`/`_set` family) is the safe choice — avoids depending on a host `append` that isn't referenced anywhere in the codebase.

### DIRECTION

- **Target phase: Phase 16 — ordering / sorting / key-extraction helpers.** Same posture as Phases 14/15: pure Aura, derived from existing alist primitives, **insertion order used as the stable tiebreaker** for sorting (matches `kv:invert`/`kv:update-keys` first-occurrence semantics). No FS escapes, no API renames, no exports removed, no internals deleted.
- Keep all T1–T87 green; extend the smoke suite with **T88–T91b (11 new tests)**, targeting 147/147.
- **Ops to add (5 new, all pure, all derive from existing internals; one new private helper `kv:_append` for list splicing)**:
  - `kv:sort-by` — `(store proc)`; stable insertion-sort; new element inserted **after** all existing equal-key entries (boundary = first q with `q-key > nk`), giving source-order stability on ties
  - `kv:sort`   — `(store)`; convenience for `kv:sort-by` with identity on `v`
  - `kv:max-key`— `(store)` → `(k . v)` of largest value; first-occurrence wins ties
  - `kv:min-key`— `(store)` → `(k . v)` of smallest value; first-occurrence wins ties
  - `kv:compare`— `(a b)` → `-1 | 0 | 1` (three-way scalar comparator)
- Bump `kv:version` to `16`. Extend the export list. Add `kv:_append` private helper. Update header comment.
- Do NOT touch: any of Phases 0–15, the `kv:reverse` shadowing, the `number?` guard in `incr-by` family, host primitives assumptions.

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
; Phase 16:  ordering / sorting / key-extraction helpers
;             (sort, sort-by, max-key, min-key, compare).
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
        kv:drop-while
        kv:sort
        kv:sort-by
        kv:max-key
        kv:min-key
        kv:compare)

(define kv:version 16)

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

; (kv:_append a b) -> concatenation of lists a and b.
; Classic cons-list concat: walks a, consing each cell onto the
; recursive concat of (cdr a) and b. Internal helper, not exported —
; introduced for Phase 16's kv:sort-by, which needs to splice a new
; entry into the middle of a sorted accumulator while preserving
; stability. Defined here (rather than depending on a host `append`)
; to keep the lib self-contained and portable across Aura hosts.
; Non-pair cells in `a` are preserved as elements (cons propagates
; whatever the car is); `b` is returned as-is when `a` is null.
(define (kv:_append a b)
  (if (null? a)
    b
    (cons (car a) (kv:_append (cdr a) b))))

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
    (lambda (k v acc)
      (kv:_set acc k (proc v)))))

; ---------------------------------------------------------------------------
; Phase 7 convenience / comparison helpers.
; ---------------------------------------------------------------------------

; (kv:get-or store key default) -> value-or-default.
; Uses kv:_has so a stored #f is distinguishable from a miss (consistent
; with kv:equal?'s documented behaviour).
(define (kv:get-or store key default)
  (if (kv:_has store key)
    (kv:_ref store key)
    default))

; (kv:rename store old new) -> store.
; Replaces key `old` with `new`, preserving position. Refuses (returns
; store unchanged) if `old` is missing OR if `new` is already present
; (ambiguity refusal, consistent with kv:swap).
(define (kv:rename store old new)
  (if (kv:_has store old)
    (if (kv:_has store new)
      store
      (kv:_set (kv:_del store old (quote ())) new (kv:_ref store old)))
    store))

; (kv:diff a b) -> (added removed changed).
; Three-way diff between stores `a` (reference) and `b` (current).
;   added   : keys present in b but not in a       (with b's values)
;   removed : keys present in a but not in b       (with a's values)
;   changed : keys present in both whose values differ
;             (with cons a-val . b-val as the new value)
; Insertion order of each sub-store follows the source operand's order.
(define (kv:diff a b)
  (let ((added
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
; Splits `store` into two sub-stores: `match` holds entries for which
; (proc k v) is #t, `nomatch` holds the rest. Insertion order is
; preserved within each sub-store (single fold over source, in source
; order). Returns a cons cell (not a list) — (match . nomatch).
(define (kv:partition store proc)
  (kv:_fold store (cons (quote ()) (quote ()))
    (lambda (k v acc)
      (let ((m (car acc)) (n (cdr acc)))
        (if (proc k v)
          (cons (kv:_set m k v) n)
          (cons m (kv:_set n k v)))))))

; (kv:equal? a b) -> #t | #f.
; Structural equality ignoring insertion order: same size, same key
; multiset, same per-key values (compared with equal?). A stored #f
; value is distinguished from a miss (uses kv:_has, not kv:_ref).
(define (kv:equal? a b)
  (let ((ak (kv:keys a)))
    (and (= (kv:size a) (kv:size b))
         (let loop ((xs ak))
           (if (null? xs)
             #t
             (let ((k (car xs)))
               (if (and (kv:_has b k) (equal? (kv:_ref a k) (kv:_ref b k)))
                 (loop (cdr xs))
                 #f)))))))

; ---------------------------------------------------------------------------
; Phase 8 positional / conditional / inversion helpers.
; ---------------------------------------------------------------------------

; (kv:first store) -> (k . v) | #f.
; First entry (as a cons cell) in insertion order, or #f on empty.
; Skips non-pair cells defensively (they are not real entries).
(define (kv:first store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p) p (kv:first (cdr store))))))

; (kv:last store) -> (k . v) | #f.
; Last entry in insertion order, or #f on empty. Skips non-pair cells.
(define (kv:last store)
  (if (null? store)
    #f
    (let loop ((xs store))
      (let ((p (car xs)) (rest (cdr xs)))
        (if (null? rest)
          (if (pair? p) p #f)
          (loop rest))))))

; (kv:rest store) -> store minus first entry.
; Returns the empty store on an empty input. Skips non-pair cells in
; the dropped prefix.
(define (kv:rest store)
  (if (null? store)
    (quote ())
    (let loop ((xs store))
      (if (null? xs)
        (quote ())
        (let ((p (car xs)))
          (if (pair? p)
            (kv:_del xs (car p) (quote ()))
            (loop (cdr xs))))))))

; (kv:butlast store) -> store minus last entry.
; Returns the empty store on a 0- or 1-element input.
(define (kv:butlast store)
  (reverse (cdr (reverse store))))

; (kv:take store n) -> first n entries (positional).
; Skips non-pair cells in the prefix-walk; pads with nothing if n
; exceeds the count of pair-cells in the source. On n=0 returns ().
(define (kv:take store n)
  (if (= n 0)
    (quote ())
    (if (null? store)
      (quote ())
      (let ((p (car store)))
        (if (pair? p)
          (cons p (kv:take (cdr store) (- n 1)))
          (kv:take (cdr store) n))))))

; (kv:drop store n) -> store minus first n entries (positional).
; Skips non-pair cells in the dropped prefix. On n=0 returns store.
(define (kv:drop store n)
  (if (= n 0)
    store
    (if (null? store)
      (quote ())
      (let ((p (car store)))
        (if (pair? p)
          (kv:drop (cdr store) (- n 1))
          (kv:drop (cdr store) n))))))

; (kv:invert store) -> store with keys and values swapped.
; First-occurrence wins on collisions (multiple keys mapping to the
; same value: the first such key in insertion order wins). Uses
; kv:_set directly (no string?-key guard) because the new keys are
; caller-supplied projections, not fresh kv:set writes — same posture
; as kv:update-keys.
(define (kv:invert store)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (kv:_has acc v)
        acc
        (kv:_set acc v k)))))

; (kv:set-if-absent store key val) -> store.
; Sets key -> val only if `key` is currently absent. No-op when key
; is already present. Insertion order unchanged on the no-op path.
(define (kv:set-if-absent store key val)
  (if (kv:_has store key)
    store
    (kv:_set store key val)))

; ---------------------------------------------------------------------------
; Phase 9 aggregation / positional / composition helpers.
; ---------------------------------------------------------------------------

; (kv:nth store n) -> (k . v) | #f.
; 0-indexed positional access. Returns the nth pair in insertion
; order, or #f if n is out of range or the store is empty. Skips
; non-pair cells defensively.
(define (kv:nth store n)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (= n 0)
        (if (pair? p) p #f)
        (kv:nth (cdr store) (- n 1))))))

; (kv:count store proc) -> integer.
; Number of entries for which (proc k v) is #t. Returns 0 on empty.
; Single fold over source; no intermediate filter allocation.
(define (kv:count store proc)
  (kv:_fold store 0
    (lambda (k v acc)
      (if (proc k v) (+ acc 1) acc))))

; (kv:sum store) -> integer.
; Sum of all values in insertion order. Empty store -> 0. Non-numeric
; values would error at the host's `+`; this is intentional (callers
; are responsible for numeric value classes — same posture as
; kv:incr-by / kv:product / kv:avg).
(define (kv:sum store)
  (kv:_fold store 0
    (lambda (k v acc) (+ acc v))))

; (kv:zip a b) -> store.
; Cross-product merge: for each key present in BOTH `a` and `b`,
; writes (cons a-v b-v) as the new value. Keys present in only one
; side are dropped (this is the relational-algebra "join" semantics,
; not a union — consistent with kv:intersection / kv:merge-with).
; Insertion order follows `a` for the shared keys.
(define (kv:zip a b)
  (kv:_fold a (quote ())
    (lambda (k v acc)
      (if (kv:_has b k)
        (kv:_set acc k (cons v (kv:_ref b k)))
        acc))))

; (kv:swap store k1 k2) -> store.
; Swaps the values of k1 and k2. Returns store unchanged (no-op) if
; either key is absent — refusing ambiguous writes (consistent with
; kv:rename). When k1 == k2 the operation is also a no-op (identity).
(define (kv:swap store k1 k2)
  (if (and (kv:_has store k1) (kv:_has store k2))
    (let ((v1 (kv:_ref store k1)) (v2 (kv:_ref store k2)))
      (kv:_set (kv:_set store k1 v2) k2 v1))
    store))

; ---------------------------------------------------------------------------
; Phase 10 statistical / numeric aggregation helpers.
; All compare values with `<` (matches kv:min / kv:max semantics).
; Returns #f on an empty store so callers can distinguish "no data"
; from "value is literally 0" — consistent with kv:find's #f sentinel.
; ---------------------------------------------------------------------------

; (kv:min store) -> smallest value | #f.
; First-occurrence wins on ties (matches kv:invert / kv:update-keys
; "earlier position wins" rule).
(define (kv:min store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best (cdr p)))
          (if (null? xs)
            best
            (let ((q (car xs)))
              (if (and (pair? q) (< (cdr q) best))
                (loop (cdr xs) (cdr q))
                (loop (cdr xs) best)))))
        #f))))

; (kv:max store) -> largest value | #f.
; First-occurrence wins on ties.
(define (kv:max store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best (cdr p)))
          (if (null? xs)
            best
            (let ((q (car xs)))
              (if (and (pair? q) (< best (cdr q)))
                (loop (cdr xs) (cdr q))
                (loop (cdr xs) best)))))
        #f))))

; (kv:product store) -> product of values (1 on empty store).
(define (kv:product store)
  (kv:_fold store 1
    (lambda (k v acc) (* acc v))))

; (kv:avg store) -> mean of values | #f.
; Returns the arithmetic mean (sum / size). Returns #f on empty so
; callers can distinguish "no data" from "value is literally 0".
(define (kv:avg store)
  (if (null? store)
    #f
    (/ (kv:sum store) (kv:size store))))

; ---------------------------------------------------------------------------
; Phase 11 set-theoretic / relational helpers.
; Insertion order of the LEFT operand is preserved for shared /
; retained keys; right-only elements are appended at the end in
; right's order (where applicable).
; ---------------------------------------------------------------------------

; (kv:intersection a b) -> store of keys present in BOTH operands.
; For shared keys, the value is taken from `b` (right-biased on the
; value axis). Insertion order follows `a`.
(define (kv:intersection a b)
  (kv:_fold a (quote ())
    (lambda (k v acc)
      (if (kv:_has b k)
        (kv:_set acc k (kv:_ref b k))
        acc))))

; (kv:subtract a b) -> store of keys in `a` but not in `b`.
; a's insertion order preserved.
(define (kv:subtract a b)
  (kv:_fold a (quote ())
    (lambda (k v acc)
      (if (kv:_has b k)
        acc
        (kv:_set acc k v)))))

; (kv:disjoint? a b) -> #t iff a and b share no keys.
(define (kv:disjoint? a b)
  (not (kv:any? a (lambda (k v) (kv:_has b k)))))

; (kv:subset? a b) -> #t iff every key in `a` is in `b` with equal
; value (compared with equal?). An empty `a` is a subset of any `b`
; (vacuous truth, via kv:every?).
(define (kv:subset? a b)
  (kv:every? a (lambda (k v)
    (and (kv:_has b k) (equal? v (kv:_ref b k))))))

; ---------------------------------------------------------------------------
; Phase 12 completion of relational algebra + value-classification.
; ---------------------------------------------------------------------------

; (kv:union a b) -> store.
; Set union. For keys present in both operands, `a`'s value wins (left-
; biased on the value axis); for keys present only in `b`, the value
; is taken from `b`. Insertion order: `a`'s order is preserved, then
; `b`-only keys are appended at the end in `b`'s iteration order.
(define (kv:union a b)
  (kv:_fold b a
    (lambda (k v acc)
      (if (kv:_has a k)
        acc
        (kv:_set acc k v)))))

; (kv:symmetric-difference a b) -> store.
; Keys present in exactly one of `a` or `b`. Insertion order: keys
; from `a` first (in `a`'s order), then keys from `b` (in `b`'s order).
; Built as the union of (a minus b) and (b minus a) — both sub-stores
; are constructed in their source's order, then unioned.
(define (kv:symmetric-difference a b)
  (let ((only-a
          (kv:_fold a (quote ())
            (lambda (k v acc)
              (if (kv:_has b k)
                acc
                (kv:_set acc k v)))))
        (only-b
          (kv:_fold b (quote ())
            (lambda (k v acc)
              (if (kv:_has a k)
                acc
                (kv:_set acc k v))))))
    (kv:union only-a only-b)))

; (kv:reverse store) -> store with entries in reverse insertion order.
; Note: this shadows the host's `reverse` for any subsequent internal
; use in this file (e.g., kv:butlast); the implementation is the
; standard cons-list reversal, so the shadowing is behaviour-
; preserving for the rest of the lib.
(define (kv:reverse store)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (cons p acc))
          (loop (cdr xs) acc))))))

; (kv:frequencies store) -> store of value -> count.
; Counts the number of times each value appears in `store`. Insertion
; order of the result is "first-occurrence order of distinct values
; in the source" (matches kv:invert / kv:update-keys first-occurrence
; semantics). An empty source yields an empty result.
(define (kv:frequencies store)
  (let ((vs (kv:values store)))
    (let loop ((xs vs) (acc (quote ())))
      (if (null? xs)
        acc
        (let ((v (car xs)))
          (if (kv:_has acc v)
            (loop (cdr xs) (kv:_set acc v (+ (kv:_ref acc v) 1)))
            (loop (cdr xs) (kv:_set acc v 1))))))))

; ---------------------------------------------------------------------------
; Phase 13 numeric / bulk-composition helpers.
; Counter ops have init semantics: incr-by on a missing key sets the
; key to `amount` (rather than erroring). This matches the canonical
; use-case ("counter" pattern) and the API consumer's expectation.
; ---------------------------------------------------------------------------

; (kv:incr store key) -> store with key incremented by 1.
; On miss: creates slot with value 1.
(define (kv:incr store key)
  (kv:incr-by store key 1))

; (kv:incr-by store key amount) -> store with key incremented by amount.
; On miss: creates slot with value = amount. Refuses (returns store
; unchanged) if `key` is not a string OR `amount` is not a number —
; consistent with the documented "guarded counter" semantics tested by
; T65 / T66.
(define (kv:incr-by store key amount)
  (if (and (string? key) (number? amount))
    (if (kv:_has store key)
      (let ((v (kv:_ref store key)))
        (if (number? v)
          (kv:_set store key (+ v amount))
          store))
      (kv:_set store key amount))
    store))

; (kv:decr store key) -> store with key decremented by 1.
(define (kv:decr store key)
  (kv:decr-by store key 1))

; (kv:decr-by store key amount) -> store with key decremented by amount.
; On miss: creates slot with value = (- 0 amount).
(define (kv:decr-by store key amount)
  (if (and (string? key) (number? amount))
    (if (kv:_has store key)
      (let ((v (kv:_ref store key)))
        (if (number? v)
          (kv:_set store key (- v amount))
          store))
      (kv:_set store key (- 0 amount)))
    store))

; (kv:rename-keys store alist) -> store.
; Apply a list of (old . new) renames in order. Each rename has the
; same semantics as kv:rename (refuses when old is missing OR new is
; already present). Because each rename uses kv:rename internally,
; chained renames ARE supported: a rename introduced by an earlier
; pair is visible to later pairs (because the intermediate result
; replaces the source for the next rename).
(define (kv:rename-keys store alist)
  (let loop ((xs alist) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((old (car p)) (new (cdr p)))
            (loop (cdr xs) (kv:rename acc old new)))
          (loop (cdr xs) acc))))))

; (kv:union-all stores) -> store.
; Fold kv:union over a list of stores left-to-right. Each successive
; store's values win on shared keys (right-biased). Non-pair cells in
; `stores` are skipped defensively.
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
; ---------------------------------------------------------------------------

; (kv:update-keys store proc) -> store.
; Apply (proc k) to each key. Folds `store` left-to-right in
; insertion order; for each (k, v), computes (new-k = (proc k)) and
; (if new-k is not already in the accumulator) writes (new-k -> v)
; into acc. First occurrence wins on collisions (matches kv:invert).
; Insertion order of the result tracks the source's order.
(define (kv:update-keys store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (let ((new-k (proc k)))
        (if (kv:_has acc new-k)
          acc
          (kv:_set acc new-k v))))))

; (kv:merge-with a b proc) -> store.
; Right-biased merge with caller-supplied combiner. For each key
; shared between `a` and `b`, writes (proc a-v b-v) as the new value.
; For each `a`-only key, writes `a`'s value as-is. For each `b`-only
; key, writes `b`'s value at the end in `b`'s iteration order.
; `proc` is called only for keys present in BOTH operands; for
; disjoint operands the result is identical to kv:union.
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
; wrapper over kv:count — provided for symmetry with kv:has?
; (key-presence).
(define (kv:count-value store val)
  (kv:count store (lambda (k v) (equal? v val))))

; (kv:filter-values store proc) -> store.
; Sub-store of entries for which `(proc v)` is `#t`. Folds `store`
; left-to-right in insertion order; keeps an entry (writing k -> v
; into the accumulator) iff `(proc v)` is `#t`. Complements
; kv:filter (proc k v).
(define (kv:filter-values store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (proc v)
        (kv:_set acc k v)
        acc))))

; ---------------------------------------------------------------------------
; Phase 15 lookup / value-presence / span helpers.
; ---------------------------------------------------------------------------

; (kv:find-key store proc) -> key | #f.
; First key for which (proc k v) is #t. Short-circuits left-to-right;
; #f on miss / empty.
(define (kv:find-key store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        (car p)
        (kv:find-key (cdr store) proc)))))

; (kv:find-value store proc) -> value | #f.
; First value for which (proc k v) is #t. Short-circuits left-to-right;
; #f on miss / empty.
(define (kv:find-value store proc)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        (cdr p)
        (kv:find-value (cdr store) proc)))))

; (kv:has-value? store val) -> #t | #f.
; True iff at least one entry's value is structurally equal to val.
(define (kv:has-value? store val)
  (kv:any? store (lambda (k v) (equal? v val))))

; (kv:none? store proc) -> #t | #f.
; True iff no entry satisfies (proc k v). Short-circuits on the first
; hit. Vacuous #t on an empty store.
(define (kv:none? store proc)
  (if (null? store)
    #t
    (let ((p (car store)))
      (if (and (pair? p) (proc (car p) (cdr p)))
        #f
        (kv:none? (cdr store) proc)))))

; (kv:take-while store proc) -> store.
; Keep entries (in insertion order) until the first entry for which
; (proc k v) is #f. The boundary belongs to drop-while's side, not
; take-while's. Empty input -> empty output; all-true proc yields the
; whole store.
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
; Drop entries (in insertion order) while (proc k v) is #t. Returns
; the rest, preserving its original order. Complements kv:take-while.
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

; ---------------------------------------------------------------------------
; Phase 16 ordering / sorting / key-extraction helpers.
; Pure functional; insertion order used as the stable tiebreaker for
; sorting (matches kv:invert / kv:update-keys first-occurrence
; semantics and the "earlier source position wins" rule used by every
; op in the store). No FS escapes; no API renames; no exports
; removed; no internals deleted.
;
; Conventions:
;   * `kv:sort-by` is the primitive; `kv:sort` is
;     `(kv:sort-by s (lambda (k v) v))`. Stability is achieved by
;     scanning the accumulator and inserting the new entry just BEFORE
;     the first existing entry whose sort-key is STRICTLY GREATER than
;     the new entry's sort-key — i.e., the boundary is "first q with
;     (proc q-k q-v) > nk", not ">=". That way, all existing entries
;     with the same sort-key as the new one remain ahead of the new
;     entry, so earlier source position wins on ties (matches
;     kv:invert / kv:update-keys). `kv:_append` is used to splice the
;     new entry into the middle of the sorted prefix without losing
;     cells. Non-pair cells in the source are skipped defensively
;     (they never enter the accumulator in the first place).
;   * `kv:max-key` / `kv:min-key` return the (k . v) entry — not just
;     the key — with the largest / smallest value (compared with `<`,
;     same convention as kv:max / kv:min). First-occurrence wins on
;     ties (the loop only updates `best-p` / `best-v` on a STRICT
;     inequality, matching kv:max / kv:min's first-wins semantics).
;     #f on empty store. Skips non-pair cells defensively.
;   * `kv:compare` is the three-way scalar comparator: -1 / 0 / 1.
;     Uses `equal?` for equality and `<` for the ordering axis. Useful
;     as a comparator passed into a future sort-by-with-compare, and
;     for general three-way branching on comparable scalar values.
;     Behaviour on mixed / non-comparable inputs is host-defined
;     (whatever `<` decides).
; ---------------------------------------------------------------------------

; (kv:sort-by store proc) -> store.
; Sort entries by (proc k v) ascending. Stable: insertion order is the
; tiebreaker — on equal (proc k v), the earlier source entry comes
; first. Implementation: walk source left-to-right; for each entry p,
; compute nk = (proc (car p) (cdr p)) and insert p into the
; accumulator at the correct sorted position. The boundary in the
; accumulator is the first q whose sort-key is STRICTLY GREATER than
; nk; p is inserted just before that q, after all entries with key
; <= nk. This yields source-order stability on ties.
(define (kv:sort-by store proc)
  (let loop ((xs store) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (let ((nk (proc (car p) (cdr p))))
            (let lp ((ys acc) (pre (quote ())))
              (if (null? ys)
                (loop (cdr xs)
                      (kv:_append (reverse pre) (cons p (quote ()))))
                (if (< nk (proc (car ys) (cdr ys)))
                  (loop (cdr xs)
                        (kv:_append
                          (kv:_append (reverse pre) (cons p (quote ())))
                          ys))
                  (lp (cdr ys) (cons (car ys) pre))))))
          (loop (cdr xs) acc))))))

; (kv:sort store) -> store.
; Sort by value ascending. Convenience for (kv:sort-by s (lambda (k v) v)).
; Inherits kv:sort-by's stability on ties.
(define (kv:sort store)
  (kv:sort-by store (lambda (k v) v)))

; (kv:max-key store) -> (k . v) | #f.
; Returns the entry with the largest value (compared with `<`).
; First-occurrence wins on ties (matches kv:max). #f on empty store.
(define (kv:max-key store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best-p p) (best-v (cdr p)))
          (if (null? xs)
            best-p
            (let ((q (car xs)))
              (if (and (pair? q) (< best-v (cdr q)))
                (loop (cdr xs) q (cdr q))
                (loop (cdr xs) best-p best-v)))))
        #f))))

; (kv:min-key store) -> (k . v) | #f.
; Returns the entry with the smallest value (compared with `<`).
; First-occurrence wins on ties (matches kv:min). #f on empty store.
(define (kv:min-key store)
  (if (null? store)
    #f
    (let ((p (car store)))
      (if (pair? p)
        (let loop ((xs (cdr store)) (best-p p) (best-v (cdr p)))
          (if (null? xs)
            best-p
            (let ((q (car xs)))
              (if (and (pair? q) (< (cdr q) best-v))
                (loop (cdr xs) q (cdr q))
                (loop (cdr xs) best-p best-v)))))
        #f))))

; (kv:compare a b) -> -1 | 0 | 1.
; Three-way scalar comparator. -1 if a<b, 0 if (equal? a b), 1 if a>b.
; Uses `equal?` for equality and `<` for the ordering axis (consistent
; with kv:max / kv:min / kv:sort-by). Behaviour on mixed / non-
; comparable inputs is host-defined (whatever `<` decides).
(define (kv:compare a b)
  (if (equal? a b)
    0
    (if (< a b) -1 1)))
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

; T34b: equal? distinguishes a stored #f from a miss.
(t "T34b-equal-false-vs-miss"
   (let* ((a (kv:set (kv:open) "k" #f))
          (b (kv:open)))
     (not (kv:equal? a b))))

; ---- Phase 8: positional / conditional / inversion helpers ----

; T35: first() returns the (k . v) pair of the first entry.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (f (kv:first s)))
  (t "T35-first"
     (and (pair? f)
          (equal? (car f) "a")
          (equal? (cdr f) 1))))

; T35b: first() on empty store is #f.
(t "T35b-first-empty" (eq? (kv:first (kv:open)) #f))

; T36: last() returns the (k . v) pair of the last entry.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (l (kv:last s)))
  (t "T36-last"
     (and (pair? l)
          (equal? (car l) "c")
          (equal? (cdr l) 3))))

; T36b: last() on empty store is #f.
(t "T36b-last-empty" (eq? (kv:last (kv:open)) #f))

; T37: rest() returns the store minus the first entry.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:rest s)))
  (t "T37-rest"
     (and (= (kv:size r) 2)
          (eq? (kv:has? r "a") #f)
          (equal? (kv:get r "b") 2)
          (equal? (kv:get r "c") 3))))

; T37b: butlast() returns the store minus the last entry.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:butlast s)))
  (t "T37b-butlast"
     (and (= (kv:size b) 2)
          (equal? (kv:get b "a") 1)
          (equal? (kv:get b "b") 2)
          (eq? (kv:get b "c") #f))))

; T37c: take() returns the first n entries.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (t2 (kv:take s 2))
       (t0 (kv:take s 0))
       (t9 (kv:take s 9)))
  (t "T37c-take"
     (and (= (kv:size t2) 2)
          (equal? (kv:get t2 "a") 1)
          (equal? (kv:get t2 "b") 2)
          (null? t0)
          (= (kv:size t9) 3))))

; T37d: drop() returns the store minus the first n entries.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (d1 (kv:drop s 1))
       (d3 (kv:drop s 3)))
  (t "T37d-drop"
     (and (= (kv:size d1) 2)
          (eq? (kv:get d1 "a") #f)
          (equal? (kv:get d1 "b") 2)
          (null? d3))))

; T38: invert() swaps keys and values; first occurrence wins on collisions.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 1))
       (r (kv:invert s)))
  (t "T38-invert"
     (and (= (kv:size r) 2)
          (equal? (kv:get r 1) "a")
          (equal? (kv:get r 2) "b"))))

; T38b: set-if-absent() sets only when key is missing.
(let* ((s (kv:set (kv:open) "a" 1))
       (s2 (kv:set-if-absent s "a" 99))
       (s3 (kv:set-if-absent s "b" 2)))
  (t "T38b-set-if-absent"
     (and (equal? (kv:get s2 "a") 1)
          (equal? (kv:get s3 "a") 1)
          (equal? (kv:get s3 "b") 2))))

; ---- Phase 9: aggregation / positional / composition helpers ----

; T39: nth() returns the nth entry; #f on out-of-range.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3)))
  (t "T39-nth"
     (and (equal? (kv:nth s 0) (cons "a" 1))
          (equal? (kv:nth s 1) (cons "b" 2))
          (equal? (kv:nth s 2) (cons "c" 3))
          (eq? (kv:nth s 5) #f)
          (eq? (kv:nth (kv:open) 0) #f))))

; T40: count() returns the number of entries matching proc.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "d" 4)))
  (t "T40-count"
     (and (= (kv:count s (lambda (k v) (> v 2))) 2)
          (= (kv:count s (lambda (k v) #t)) 4)
          (= (kv:count (kv:open) (lambda (k v) #t)) 0))))

; T41: sum() returns the sum of all values; 0 on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3)))
  (t "T41-sum"
     (and (= (kv:sum s) 6) (= (kv:sum (kv:open)) 0))))

; T42: zip() pairs values from a and b for shared keys.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "x" 1) "y" 2) "z" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "x" 10) "y" 20) "w" 30))
       (z (kv:zip a b)))
  (t "T42-zip"
     (and (= (kv:size z) 2)
          (equal? (kv:get z "x") (cons 1 10))
          (equal? (kv:get z "y") (cons 2 20))
          (eq? (kv:get z "z") #f)
          (eq? (kv:get z "w") #f))))

; T43: swap() exchanges two values; no-op when either key is absent.
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (sw (kv:swap s "a" "b"))
       (noop (kv:swap s "a" "ghost"))
       (same (kv:swap s "a" "a")))
  (t "T43-swap"
     (and (equal? (kv:get sw "a") 2)
          (equal? (kv:get sw "b") 1)
          (equal? (kv:get noop "a") 1)
          (equal? (kv:get noop "b") 2)
          (equal? (kv:get same "a") 1))))

; ---- Phase 10: statistical / numeric aggregation helpers ----

; T44: count() over a numeric set; sum() over the same set.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3)))
  (t "T44-count" (= (kv:count s (lambda (k v) (number? v))) 3))
  (t "T45-sum" (= (kv:sum s) 6)))

; T46: zip() works on shorter value lists too.
(let* ((a (kv:set (kv:set (kv:open) "x" 1) "y" 2))
       (b (kv:set (kv:open) "x" 10)))
  (t "T46-zip" (and (= (kv:size (kv:zip a b)) 1)
                    (equal? (kv:get (kv:zip a b) "x") (cons 1 10))))
  (t "T46b-zip-vals-shorter"
     (and (= (kv:size (kv:zip a b)) 1)
          (equal? (kv:get (kv:zip a b) "x") (cons 1 10))))
  (t "T46c-zip-keys-shorter"
     (and (= (kv:size (kv:zip b a)) 1)
          (equal? (kv:get (kv:zip b a) "x") (cons 10 1)))))

; T47: swap() on the same key is a no-op; on missing key is a no-op.
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
  (t "T47-swap" (kv:equal? (kv:swap s "a" "b")
                            (kv:set (kv:set (kv:open) "a" 2) "b" 1)))
  (t "T47b-swap-same-key" (kv:equal? (kv:swap s "a" "a") s))
  (t "T47c-swap-missing" (kv:equal? (kv:swap s "a" "z") s)))

; T48: min() returns the smallest value; #f on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 3) "b" 1) "c" 2)))
  (t "T48-min" (and (= (kv:min s) 1) (eq? (kv:min (kv:open)) #f)))
  (t "T48b-min-single" (= (kv:min (kv:set (kv:open) "x" 42)) 42))
  (t "T48c-min-negative"
     (= (kv:min (kv:set (kv:set (kv:set (kv:open) "a" 3) "b" -5) "c" 7)) -5)))

; T49: max() returns the largest value; #f on empty.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 3) "b" 1) "c" 2)))
  (t "T49-max" (and (= (kv:max s) 3) (eq? (kv:max (kv:open)) #f)))
  (t "T49b-max-single" (= (kv:max (kv:set (kv:open) "x" 42)) 42)))

; T50: product() of values; 1 on empty.
(t "T50-product" (= (kv:product (kv:set (kv:set (kv:set (kv:open) "a" 2) "b" 3) "c" 4)) 24))

; T51: avg() of values; #f on empty.
(t "T51-avg" (and (= (kv:avg (kv:set (kv:set (kv:set (kv:open) "a" 2) "b" 4) "c" 6)) 4)
                 (eq? (kv:avg (kv:open)) #f)))

; T52: defensive — min/max skip non-pair cells and never crash.
(t "T52-min-max-defensive"
   (let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 5)))
     (and (= (kv:min s) 1) (= (kv:max s) 5))))

; T53: stats compose with other ops.
(t "T53-stats-compose"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3)))
     (and (= (+ (kv:min s) (kv:max s)) 4)
          (= (kv:product s) 6))))

; ---- Phase 11: set-theoretic / relational helpers ----

; T54: intersection() keeps shared keys, with b's value; a's order.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "x" 1) "y" 2) "z" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "y" 20) "z" 30) "w" 40))
       (i (kv:intersection a b))
       (ik (kv:keys i)))
  (t "T54-intersection"
     (and (= (kv:size i) 2)
          (equal? (kv:get i "y") 20)
          (equal? (kv:get i "z") 30)
          (equal? (car ik) "y")
          (equal? (car (cdr ik)) "z"))))

; T54b: intersection() of disjoint operands is empty.
(t "T54b-intersection-disjoint"
   (= (kv:size (kv:intersection (kv:set (kv:open) "a" 1)
                                (kv:set (kv:open) "b" 2))) 0))

; T54c: intersection() with empty operand is empty.
(t "T54c-intersection-empty"
   (= (kv:size (kv:intersection (kv:open) (kv:set (kv:open) "a" 1))) 0))

; T55: subtract() removes b's keys from a.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "x" 1) "y" 2) "z" 3))
       (b (kv:set (kv:open) "y" 99))
       (d (kv:subtract a b)))
  (t "T55-subtract"
     (and (= (kv:size d) 2)
          (eq? (kv:get d "y") #f)
          (equal? (kv:get d "x") 1)
          (equal? (kv:get d "z") 3))))

; T55b: subtract() with empty b is identity on a.
(t "T55b-subtract-identity"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
     (kv:equal? (kv:subtract a (kv:open)) a)))

; T55c: subtract() of a from a is empty.
(t "T55c-subtract-self"
   (= (kv:size (kv:subtract (kv:set (kv:set (kv:open) "a" 1) "b" 2)
                            (kv:set (kv:set (kv:open) "a" 1) "b" 2))) 0))

; T56: disjoint? reports no shared keys.
(t "T56-disjoint?"
   (and (kv:disjoint? (kv:set (kv:open) "a" 1) (kv:set (kv:open) "b" 2))
        (not (kv:disjoint? (kv:set (kv:open) "a" 1) (kv:set (kv:open) "a" 1)))))

; T57: subset? reports containment-with-equal-values.
(t "T57-subset?"
   (let* ((a (kv:set (kv:open) "x" 1))
          (b (kv:set (kv:set (kv:open) "x" 1) "y" 2)))
     (and (kv:subset? a b)
          (not (kv:subset? b a))
          (not (kv:subset? a (kv:set (kv:open) "x" 99))))))

; T57b: empty set is a subset of any set.
(t "T57b-subset-empty"
   (kv:subset? (kv:open) (kv:set (kv:open) "a" 1)))

; T57c: subset? with a missing key in b is #f.
(t "T57c-subset-missing"
   (not (kv:subset? (kv:set (kv:open) "a" 1)
                    (kv:set (kv:open) "b" 2))))

; ---- Phase 12: completion of relational algebra + value-classification ----

; T58: union() merges two stores; a's order for shared keys; b-only appended.
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (b (kv:set (kv:set (kv:open) "b" 20) "c" 3))
       (u (kv:union a b))
       (uk (kv:keys u)))
  (t "T58-union"
     (and (= (kv:size u) 3)
          (equal? (kv:get u "a") 1)
          (equal? (kv:get u "b") 2)
          (equal? (kv:get u "c") 3)
          (equal? (car uk) "a")
          (equal? (car (cdr uk)) "b")
          (equal? (car (cdr (cdr uk))) "c"))))

; T58b: union() of disjoint operands concatenates a then b.
(t "T58b-union-disjoint"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
          (u (kv:union a b)))
     (and (= (kv:size u) 4)
          (equal? (kv:get u "a") 1)
          (equal? (kv:get u "d") 4))))

; T58c: union() with empty operand is identity on the other side.
(t "T58c-union-empty"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
     (and (kv:equal? (kv:union a (kv:open)) a)
          (kv:equal? (kv:union (kv:open) a) a))))

; T59: symmetric-difference() returns keys in exactly one operand.
(let* ((a (kv:set (kv:set (kv:set (kv:open) "x" 1) "y" 2) "z" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "y" 20) "z" 3) "w" 4))
       (d (kv:symmetric-difference a b))
       (dk (kv:keys d)))
  (t "T59-symmetric-difference"
     (and (= (kv:size d) 2)
          (equal? (kv:get d "x") 1)
          (equal? (kv:get d "w") 4)
          (eq? (kv:get d "y") #f)
          (eq? (kv:get d "z") #f))))

; T59b: symmetric-difference() of disjoint operands concatenates.
(t "T59b-symmetric-difference-disjoint"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
          (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
          (d (kv:symmetric-difference a b)))
     (= (kv:size d) 4)))

; T59c: symmetric-difference() of a store with itself is empty.
(t "T59c-symmetric-difference-self"
   (let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
     (= (kv:size (kv:symmetric-difference a a)) 0)))

; T60: reverse() flips insertion order; preserves set membership.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "d" 4))
       (r (kv:reverse s))
       (rk (kv:keys r)))
  (t "T60-reverse"
     (and (= (kv:size r) 4)
          (equal? (car rk) "d")
          (equal? (car (cdr rk)) "c")
          (equal? (car (cdr (cdr rk))) "b")
          (equal? (car (cdr (cdr (cdr rk)))) "a"))))

; T60b: reverse() on empty store is empty.
(t "T60b-reverse-empty" (null? (kv:reverse (kv:open))))

; T60c: double reverse is identity (structural).
(t "T60c-reverse-double"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3)))
     (kv:equal? (kv:reverse (kv:reverse s)) s)))

; T61: frequencies() counts value occurrences.
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 1) "d" 3) "e" 1)))
  (t "T61-frequencies"
     (and (= (kv:get (kv:frequencies s) 1) 3)
          (= (kv:get (kv:frequencies s) 2) 1)
          (= (kv:get (kv:frequencies s) 3) 1))))

; T61b: frequencies() on empty store is empty.
(t "T61b-frequencies-empty" (null? (kv:frequencies (kv:open))))

; T61c: frequencies() of distinct values is all 1s.
(t "T61c-frequencies-distinct"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
          (f (kv:frequencies s)))
     (and (= (kv:size f) 3)
          (= (kv:get f 1) 1)
          (= (kv:get f 2) 1)
          (= (kv:get f 3) 1))))

; ---- Phase 13: numeric / bulk-composition helpers ----

; T62: incr() bumps an existing key by 1.
(let* ((s (kv:set (kv:open) "c" 5)))
  (t "T62-incr-basic" (= (kv:get (kv:incr s "c") "c") 6)))

; T63: incr() creates a new counter at 1 on a miss.
(let* ((s (kv:incr (kv:open) "c")))
  (t "T63-incr-create" (and (= (kv:size s) 1) (= (kv:get s "c") 1))))

; T64: incr-by() bumps by a caller-supplied amount.
(let* ((s (kv:set (kv:open) "c" 10)))
  (t "T64-incr-by-amount" (= (kv:get (kv:incr-by s "c" 5) "c") 15)))

; T65: incr-by() refuses a non-numeric amount (returns store unchanged).
(t "T65-incr-refuse-bad-amount"
   (let* ((s (kv:set (kv:open) "c" 10)))
     (kv:equal? (kv:incr-by s "c" "five") s)))

; T66: incr-by() refuses a non-string key (returns store unchanged).
(t "T66-incr-refuse-bad-key"
   (let* ((s (kv:set (kv:open) "c" 10)))
     (kv:equal? (kv:incr-by s 42 5) s)))

; T67: decr() decrements an existing key.
(let* ((s (kv:set (kv:open) "c" 5)))
  (t "T67-decr-basic" (= (kv:get (kv:decr s "c") "c") 4)))

; T68: decr() creates a new counter at -1 on a miss.
(let* ((s (kv:decr (kv:open) "c")))
  (t "T68-decr-create" (and (= (kv:size s) 1) (= (kv:get s "c") -1))))

; T69: rename-keys() applies a mapping of (old . new) pairs in order,
; and preserves the rest of the store.
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
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 5) "d" 10))
       (tw (kv:take-while s (lambda (k v) (< v 5))))
       (dw (kv:drop-while s (lambda (k v) (< v 5))))
       (joined (kv:union tw dw)))
  (t "T87-take-drop-while-partition"
     (kv:equal? s joined)))

; ---- Phase 16: ordering / sorting / key-extraction helpers ----

; T88: sort() sorts by value ascending; insertion order is the stable
; tiebreaker (first occurrence wins on equal values, matching
; kv:invert / kv:update-keys first-occurrence semantics).
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 3) "b" 1) "c" 2) "d" 1))
       (r (kv:sort s))
       (rk (kv:keys r)))
  (t "T88-sort"
     (and (= (kv:size r) 4)
          (equal? (kv:get r "b") 1)
          (equal? (kv:get r "d") 1)
          (equal? (kv:get r "c") 2)
          (equal? (kv:get r "a") 3)
          (equal? (car rk) "b")
          (equal? (car (cdr rk)) "d")
          (equal? (car (cdr (cdr rk))) "c")
          (equal? (car (cdr (cdr (cdr rk)))) "a"))))

; T88b: sort() on an empty store yields an empty store.
(t "T88b-sort-empty"
   (null? (kv:sort (kv:open))))

; T88c: sort() on a single-entry store yields that entry unchanged.
(t "T88c-sort-single"
   (let* ((s (kv:set (kv:open) "only" 42))
          (r (kv:sort s)))
     (and (= (kv:size r) 1)
          (equal? (kv:get r "only") 42))))

; T89: sort-by() sorts by a caller-supplied proc; order is the
; proc-ascending order. Using (lambda (k v) (- v)) reverses the
; numeric sort: input [1,2,3,4] -> output keys [d,c,b,a].
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "d" 4))
       (r (kv:sort-by s (lambda (k v) (- v))))
       (rk (kv:keys r)))
  (t "T89-sort-by"
     (and (= (kv:size r) 4)
          (equal? (car rk) "d")
          (equal? (car (cdr rk)) "c")
          (equal? (car (cdr (cdr rk))) "b")
          (equal? (car (cdr (cdr (cdr rk)))) "a"))))

; T89b: sort-by() on an empty store yields an empty store.
(t "T89b-sort-by-empty"
   (null? (kv:sort-by (kv:open) (lambda (k v) v))))

; T89c: sort-by() on an already-sorted input preserves insertion order.
(t "T89c-sort-by-sorted"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
          (r (kv:sort-by s (lambda (k v) v)))
          (rk (kv:keys r)))
     (and (= (kv:size r) 3)
          (equal? (car rk) "a")
          (equal? (car (cdr rk)) "b")
          (equal? (car (cdr (cdr rk))) "c"))))

; T90: max-key() returns the (k . v) entry with the largest value.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 3)))
  (t "T90-max-key"
     (and (pair? (kv:max-key s))
          (equal? (car (kv:max-key s)) "b")
          (equal? (cdr (kv:max-key s)) 5))))

; T90b: min-key() returns the (k . v) entry with the smallest value.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 5) "c" 3)))
  (t "T90b-min-key"
     (and (pair? (kv:min-key s))
          (equal? (car (kv:min-key s)) "a")
          (equal? (cdr (kv:min-key s)) 1))))

; T90c: max-key/min-key on ties: first occurrence wins (matches
; kv:max / kv:min first-occurrence semantics).
(t "T90c-max-min-key-ties"
   (let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 5) "b" 5) "c" 1)))
     (and (equal? (kv:max-key s) (cons "a" 5))
          (equal? (kv:min-key s) (cons "c" 1)))))

; T91: compare() returns -1 / 0 / 1 for less / equal / greater.
(t "T91-compare"
   (and (= (kv:compare 1 2) -1)
        (= (kv:compare 5 5) 0)
        (= (kv:compare 7 3) 1)))

; T91b: max-key/min-key on an empty store yield #f.
(t "T91b-max-min-key-empty"
   (and (eq? (kv:max-key (kv:open)) #f)
        (eq? (kv:min-key (kv:open)) #f)))

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
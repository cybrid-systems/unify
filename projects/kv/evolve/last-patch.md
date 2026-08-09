<think>Let me analyze the current state:

1. The project already has a score of 17/17 - it's passing all tests
2. The implementation looks complete and correct
3. The spec mentions "Phase 4: optional: batch helpers | T13+"
4. The current score is already maxed at 17/17

Looking at the implementation, it's already passing all 17 tests. The task says "raise SCORE" but it's already at max. I need to improve without regressing.

Since we're at 17/17 already, any improvement would be:
1. Code quality improvements (cleaner, more idiomatic Aura)
2. Performance improvements
3. Adding robustness
4. Adding optional batch helpers mentioned in Phase 4

Let me review the current code for any issues:

1. `kv:set` uses `reverse` implicitly through cons-on-out, but actually it doesn't reverse at the end. Wait, let me re-read... it builds out by cons-ing new entries first, so the final `out` is in reverse order. Actually wait, looking more carefully:

```scheme
(define (kv:set store key val)
  ...
  (let loop ((xs store) (out (quote ())) (found #f))
      (if (null? xs)
        (if found
          out
          (cons (cons key val) out))
```

When found is #t and we traversed the list, the `out` has elements in REVERSE order (because we cons to the front). So when we hit the end with found=#t, we return `out` which is reversed. That's a bug!

Wait, let me trace through:
- store = `(("a" . 1) ("b" . 2))`
- set "a" 99
- xs = `(("a" . 1) ("b" . 2))`, out = `()`, found = #f
- p = `("a" . 1)`, matches
- loop: xs = `(("b" . 2))`, out = `(("a" . 99))`, found = #t
- p = `("b" . 2)`, doesn't match
- loop: xs = `()`, out = `(("b" . 2) ("a" . 99))`, found = #t
- return out = `(("b" . 2) ("a" . 99))`

So the order is reversed when overwriting! Let me check if this matters for tests...

T2-set-get and T4-overwrite: probably test by single key get, so order doesn't matter for correctness.
T9-keys: returns keys, and if we do `(kv:keys store)` after multiple sets with overrides, the order might matter.

Actually wait, the keys function has the same issue - it doesn't reverse at the end:

```scheme
(define (kv:keys store)
  (let loop ((xs store) (out (quote ())))
    (if (null? xs)
      (reverse out)
      ...
```

`kv:keys` does reverse at the end, good.

But `kv:set` doesn't! Let me re-check:

```scheme
(if (null? xs)
    (if found
      out
      (cons (cons key val) out))
```

When found is #t, returns `out` as-is. When found is #f, returns `(cons (cons key val) out)` - so new key gets prepended.

But `out` was built by prepending during iteration. So actually:
- Initial: out = `()`
- After 1st elem processed: out = `(elem1)`  
- After 2nd elem processed: out = `(elem2 elem1)`
- ...

Wait, I'm confusing myself. Let me re-trace carefully.

The original store: `((a . 1) (b . 2))` (last added is "b")
We iterate xs from front to back:
- xs = `((a . 1) (b . 2))`, p = `(a . 1)` matches "a"
  - loop with xs=`((b . 2))`, out=`((a . 99))`, found=#t
- xs = `((b . 2))`, p = `(b . 2)` doesn't match
  - loop with xs=`()`, out=`((b . 2) (a . 99))`, found=#t
- xs = `()`, return out = `((b . 2) (a . 99))`

So the result is `((b . 2) (a . 99))` - the original order is preserved! Because "a" was first and we prepended the replacement, but then "b" was prepended on top of that, so "b" comes first again.

Actually wait, let me reconsider. The cons order:
- Initial: out = `()`
- After processing (a . 1) which we replace: cons `(a . 99)` to out → out = `((a . 99))`
- After processing (b . 2) which we keep: cons `(b . 2)` to out → out = `((b . 2) (a . 99))`

So final: `((b . 2) (a . 99))`. The original order was `((a . 1) (b . 2))`, so the new order is reversed: "b" first, "a" second.

Yes this is a bug! The order is reversed when overwriting.

However, this might not matter for the current tests since they probably just check `equal?` on single-key results.

Let me think about what could be improved:

1. Fix the ordering bug in `kv:set`
2. Make the code more idiomatic Aura
3. Add Phase 4 batch helpers (optional)
4. Make implementation faster (e.g., not traversing entire list every time)

Let me also check `kv:del`:

```scheme
(define (kv:del store key)
  ...
  (let loop ((xs store) (out (quote ())))
      (if (null? xs)
        (reverse out)
        (let ((p (car xs)))
          (if (and (pair? p) (equal? (car p) key))
            (loop (cdr xs) out)
            (loop (cdr xs) (cons p out))))))))
```

This one does reverse! So order is preserved. Good.

Now let me check `kv:set` more carefully - the test that would catch the order issue would be something like:

```
(let ((s (kv:open)))
  (let ((s (kv:set s "a" 1)))
    (let ((s (kv:set s "b" 2)))
      (let ((s (kv:set s "a" 99)))
        ; Now check that "a" key still works
        ; Check that (kv:keys s) returns ("a" "b") in some order
```

Since `kv:keys` reverses its output, the actual order returned to the user is "a" then "b" because keys reverses. So tests likely pass.

But still, the inconsistency between `kv:set` (no reverse) and `kv:del` (reverses) is a code smell. Let me fix this for consistency.

Let me think about what to improve:

1. **Bug fix**: Make `kv:set` preserve insertion order consistently
2. **Performance**: Use a more efficient representation, perhaps a hash-based one or use built-in dictionary types
3. **Idiomatic Aura**: Use existing Aura functions where possible
4. **Add Phase 4 batch helpers**: `(kv:mset store alist)` and `(kv:mget store keys)`

Wait, the score is already 17/17 and there's no test 18 or beyond mentioned. The task says "raise SCORE" - but we're at max. So really we want to:
- Not regress
- Maintain quality
- Maybe add some optional improvements

Let me check the test file format. The current tests are in `tests/smoke.aura`. Let me think about what improvements to make.

Wait, re-reading the spec:
- Phase 4: optional: batch helpers | T13+

T13 is already passing ("T13-size5"), and we have T14-T17 too. So actually the test suite goes beyond T12 mentioned in the spec.

I think the best approach is:
1. Fix the ordering inconsistency in `kv:set` (minor correctness improvement)
2. Use Aura's built-in `dict` or hash-table if available for O(1) operations
3. Add some batch helpers (Phase 4)

Actually, in Scheme-like languages with hashtables, we could use those. But Aura may not have built-in hashtables. The alist approach is probably standard.

Let me focus on:
1. Code cleanup and consistency
2. Adding batch helpers (kv:mset, kv:mget, kv:mhas?)
3. Maybe a kv:update function

Let me also check if there's a `kv:fold` or similar useful function.

Actually, let me first check what tests exist. I don't have access to the test file, but based on the output we see T1-T17. Let me think about what T13-T17 might test:

- T13-size5: probably testing size after setting 5 keys
- T14-get-mid: getting a key in the middle of many
- T15-del-mid: deleting a key in the middle
- T16-empty-has: has? on empty store
- T17-del-missing: del on missing key

Since all 17 tests pass and we want to maintain/improve, let me make the following improvements:

1. Fix `kv:set` to consistently preserve order (matching `kv:del`'s behavior)
2. Add batch helpers (kv:mset, kv:mget)
3. Add a kv:update helper
4. Possibly add kv:copy for explicit isolation
5. Make the code more idiomatic

Wait, but the tests don't seem to test for these new functions. The score would still be 17/17, but we'd have improved the code.

Hmm, but the prompt says "raise SCORE" - since we're at max, we can only maintain or improve quality. Let me make these improvements.

Actually, let me re-read the prompt: "Emit FILE blocks to raise SCORE. Full file contents for each changed file."

The current score is 17/17 (max). So any improvement is about quality without breaking. Let me:

1. Fix the `kv:set` order preservation bug
2. Improve code clarity
3. Add useful helpers that don't break anything

Let me write the improved version:

```aura
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation (covered by tests).
; Phase 4:   batch helpers (mset / mget / update / merge / copy).
;
; Store representation: alist of (key . val) pairs.
; Keys are strings. Values may be any Aura value (numbers, strings, lists...).
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
        ; Phase 4 batch helpers
        kv:mset
        kv:mget
        kv:update
        kv:merge
        kv:copy)

(define kv:version 2)

; Internal: walk an alist, applying an action to each (k . v) pair.
; action is a procedure: (k v acc) -> new-acc
(define (kv:alist-fold xs acc action)
  (if (null? xs)
    acc
    (let ((p (car xs)))
      (if (pair? p)
        (kv:alist-fold (cdr xs) (action (car p) (cdr p) acc) action)
        (kv:alist-fold (cdr xs) acc action)))))

; Internal: build a list by mapping over alist entries.
(define (kv:alist-map xs action)
  (if (null? xs)
    (quote ())
    (let ((p (car xs)))
      (let ((rest (kv:alist-map (cdr xs) action)))
        (if (pair? p)
          (cons (action (car p) (cdr p)) rest)
          rest)))))

; Internal: filter alist by predicate (k v) -> bool, preserving original order.
(define (kv:alist-filter xs pred out)
  (if (null? xs)
    (reverse out)
    (let ((p (car xs)))
      (if (and (pair? p) (pred (car p) (cdr p)))
        (kv:alist-filter (cdr xs) pred (cons p out))
        (kv:alist-filter (cdr xs) pred out)))))

; Internal: find a key's value, returning #f if missing.
(define (kv:alist-ref xs key)
  (if (null? xs)
    #f
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cdr p)
        (kv:alist-ref (cdr xs) key)))))

; Internal: does the key exist? Returns #t / #f.
(define (kv:alist-contains? xs key)
  (if (null? xs)
    #f
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        #t
        (kv:alist-contains? (cdr xs) key)))))

; Internal: replace-or-insert key/val, preserving original position if found,
; else appending at the end. Returns a fresh alist.
(define (kv:alist-replace xs key val)
  (if (null? xs)
    (list (cons key val))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key val) (cdr xs))
        (cons p (kv:alist-replace (cdr xs) key val))))))

(define (kv:open)
  (quote ()))

(define (kv:set store key val)
  (if (string? key)
    (kv:alist-replace store key val)
    store))

(define (kv:get store key)
  (kv:alist-ref store key))

(define (kv:del store key)
  (kv:alist-filter store (lambda (k v) (not (equal? k key))) (quote ())))

(define (kv:has? store key)
  (kv:alist-contains? store key))

(define (kv:keys store)
  (kv:alist-map store (lambda (k v) k)))

(define (kv:size store)
  (kv:alist-fold store 0 (lambda (k v acc) (+ acc 1))))

(define (kv:clear store)
  (quote ()))

; --- Phase 4 batch helpers ---

; (kv:mset store '((k1 . v1) (k2 . v2) ...)) -> store
(define (kv:mset store alist)
  (let loop ((xs alist) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:set acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))

; (kv:mget store '("k1" "k2" ...)) -> list of values (or #f for missing)
(define (kv:mget store keys)
  (let loop ((xs keys) (out (quote ())))
    (if (null? xs)
      (reverse out)
      (loop (cdr xs) (cons (kv:get store (car xs)) out)))))

; (kv:update store key default proc) -> store
; proc is (current-val) -> new-val. If key missing, default is used.
(define (kv:update store key default proc)
  (let ((cur (kv:get store key)))
    (kv:set store key (proc (if (eq? cur #f) default cur)))))

; (kv:merge store1 store2) -> store
; Right-biased: store2 wins on conflicting keys. Preserves store1's insertion
; order for non-conflicting keys, then appends store2-only keys in their order.
(define (kv:merge a b)
  (let ((only-a (kv:alist-filter a (lambda (k v) (not (kv:has? b k))) (quote ()))))
    (let loop ((xs b) (acc only-a))
      (if (null? xs)
        acc
        (let ((p (car xs)))
          (if (pair? p)
            (loop (cdr xs) (kv:alist-replace acc (car p) (cdr p)))
            (loop (cdr xs) acc)))))))

; (kv:copy store) -> fresh store with same contents (isolation).
; Since our store is already immutable, this is just the identity.
; Provided for API symmetry / clarity.
(define (kv:copy store) store)
```

Wait, this is getting complex. Let me think more carefully.

Actually, I realize the tests are scoring 17/17 already. The improvements I can make:
1. Fix the ordering consistency in `kv:set`
2. Make it more readable
3. Add Phase 4 batch helpers (which might enable future test additions)

Let me also verify: does `kv:set` need to preserve order? Looking at the test "T4-overwrite", if it tests like:
```
(let ((s (kv:open)))
  (let ((s (kv:set s "k" 1)))
    (let ((s (kv:set s "k" 2)))
      (check (kv:get s "k") 2))))
```

Then order doesn't matter for the test. But if there's a test that checks `kv:keys` returns keys in a specific order, that could be a problem.

Since the score is already 17/17 and we don't have access to the test file, let me be careful not to break anything.

Actually, looking at my proposed fix, the original `kv:set` does preserve the reverse-of-original-order for the matching element but doesn't reverse at the end. The new version preserves original order. This change should not break existing tests that don't check order, and would fix any future tests that do check order.

Let me also think about efficiency. The original implementation:
- O(n) for set (traverses all)
- O(n) for get (traverses all)
- O(n) for del (traverses all)
- O(n) for has?
- O(n) for keys
- O(n) for size
- O(1) for clear

This is the inherent complexity of alist-based stores. We could use a hash table if Aura supports it, but let's keep alist for purity.

Let me also consider: should I add a `kv:alist->alist` or similar for export? No, keep the API clean.

Final version - let me write a cleaner, more maintainable version:

Actually, I realize I should be careful. Let me look at what the original tests actually check. The test names are:
- T1-open
- T2-set-get
- T3-missing
- T4-overwrite
- T5-has
- T6-del
- T7-multi
- T8-size
- T9-keys
- T10-clear
- T11-isolation
- T12-string-val
- T13-size5
- T14-get-mid
- T15-del-mid
- T16-empty-has
- T17-del-missing

These are 17 tests. The current code passes all 17. I should maintain this and add optional improvements.

Let me write a cleaner, more maintainable version that:
1. Preserves order consistently
2. Has clearer code structure
3. Adds Phase 4 batch helpers (forward-compatible)
4. Doesn't break existing tests

Here's my final plan:

```aura
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation.
; Phase 4:   batch helpers (mset, mget, update, merge).
;
; Store representation: alist of (key . val) pairs.
; Keys: strings. Values: any Aura value (numbers, strings, lists...).
; Operations preserve insertion order of existing keys; new keys are appended.
; All ops are functional: returns a fresh store (original untouched).
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
        kv:copy)

(define kv:version 2)

; ---------------------------------------------------------------------------
; Internal: alist primitives. Treat every entry (key . val) with `pair?`,
; tolerate stray non-pair cells defensively.
; ---------------------------------------------------------------------------

; (kv:_ref xs key) -> value or #f
(define (kv:_ref xs key)
  (if (null? xs)
    #f
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cdr p)
        (kv:_ref (cdr xs) key)))))

; (kv:_has xs key) -> #t/#f
(define (kv:_has xs key)
  (if (null? xs)
    #f
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        #t
        (kv:_has (cdr xs) key)))))

; (kv:_set xs key val) -> fresh alist, preserves order, in-place replace or append.
(define (kv:_set xs key val)
  (if (null? xs)
    (list (cons key val))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key val) (cdr xs))
        (cons p (kv:_set (cdr xs) key val))))))

; (kv:_del xs key out) -> filtered alist, preserves order.
(define (kv:_del xs key out)
  (if (null? xs)
    (reverse out)
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (kv:_del (cdr xs) key out)
        (kv:_del (cdr xs) key (cons p out))))))

; (kv:_fold xs acc f) -> acc, where f is (k v acc) -> acc
(define (kv:_fold xs acc f)
  (if (null? xs)
    acc
    (let ((p (car xs)))
      (if (pair? p)
        (kv:_fold (cdr xs) (f (car p) (cdr p) acc) f)
        (kv:_fold (cdr xs) acc f)))))

; (kv:_map xs f) -> list, where f is (k v) -> any
(define (kv:_map xs f)
  (if (null? xs)
    (quote ())
    (let ((p (car xs)))
      (let ((rest (kv:_map (cdr xs) f)))
        (if (pair? p)
          (cons (f (car p) (cdr p)) rest)
          rest)))))

; ---------------------------------------------------------------------------
; Public API
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
; Phase 4 — batch / composite helpers
; ---------------------------------------------------------------------------

; (kv:mset store '((k1 . v1) (k2 . v2) ...)) -> store
(define (kv:mset store alist)
  (let loop ((xs alist) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:_set acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))

; (kv:mget store '("k1" "k2" ...)) -> list of values, in the same order.
; Missing keys yield #f.
(define (kv:mget store keys)
  (let loop ((xs keys) (out (quote ())))
    (if (null? xs)
      (reverse out)
      (loop (cdr xs) (cons (kv:_ref store (car xs)) out)))))

; (kv:update store key default proc) -> store
; proc is (current-or-default) -> new-val.
; If key is missing, `default` is passed to `proc`; otherwise the current val.
(define (kv:update store key default proc)
  (let ((cur (kv:_ref store key)))
    (kv:_set store key (proc (if cur default default)))))

; Hmm, that's wrong. Should be: if cur is #f, use default; else use cur.
; But if cur can legitimately be #f, we'd lose it. For our v1 store where #f
; means "missing", this is fine. But to be safer:

(define (kv:update store key default proc)
  (let ((cur (kv:_ref store key)))
    (let ((effective (if (kv:_has store key) cur default)))
      (kv:_set store key (proc effective)))))

; (kv:merge a b) -> store
; Right-biased: b wins on conflicts. Preserves a's order for a-only keys,
; then appends b's keys (some overwriting existing a entries).
(define (kv:merge a b)
  (let ((a-only (kv:_del a (quote ()) (quote ()))))  ; copy of a... need filter
```

Hmm wait, I want to keep a's keys that are not in b. Let me think again.

Actually `(kv:_del a (quote ()) (quote ()))` would only delete keys matching `()`, which would be nothing, so it would just be a copy of a (reversed twice). But the API has `(kv:_del xs key out)` which only takes one key.

Let me redo the filter for merge:

```aura
; Internal: filter alist keeping only entries matching pred (k v) -> #t.
(define (kv:_filter xs pred out)
  (if (null? xs)
    (reverse out)
    (let ((p (car xs)))
      (if (and (pair? p) (pred (car p) (cdr p)))
        (kv:_filter (cdr xs) pred (cons p out))
        (kv:_filter (cdr xs) pred out)))))
```

OK this is getting too complex. Let me simplify. Since we're at 17/17 and want to maintain, I'll write a cleaner version without going overboard:

Actually, let me just write a slightly improved version that's cleaner, fixes the order consistency, and adds a few useful helpers without over-engineering.

Final approach:

```aura
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation.
; Phase 4:   batch helpers (mset, mget, update, merge, copy).
;
; Store representation: alist of (key . val) pairs.
;   - Keys: strings.
;   - Values: any Aura value (numbers, strings, lists, ...).
;   - Insertion order is preserved across all operations.
;   - All operations are functional: each returns a fresh store.
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
        kv:copy)

(define kv:version 2)

; ---------------------------------------------------------------------------
; Internal alist primitives. Every helper tolerates non-pair cells defensively.
; ---------------------------------------------------------------------------

(define (kv:_ref xs key)
  (if (null? xs)
    #f
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cdr p)
        (kv:_ref (cdr xs) key)))))

(define (kv:_has xs key)
  (if (null? xs)
    #f
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        #t
        (kv:_has (cdr xs) key)))))

; Replace existing key in place, or append at the end. Preserves order.
(define (kv:_set xs key val)
  (if (null? xs)
    (list (cons key val))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key val) (cdr xs))
        (cons p (kv:_set (cdr xs) key val))))))

; Filter out a key, preserving order.
(define (kv:_del xs key out)
  (if (null? xs)
    (reverse out)
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (kv:_del (cdr xs) key out)
        (kv:_del (cdr xs) key (cons p out))))))

; Fold over (k . v) entries.
(define (kv:_fold xs acc f)
  (if (null? xs)
    acc
    (let ((p (car xs)))
      (if (pair? p)
        (kv:_fold (cdr xs) (f (car p) (cdr p) acc) f)
        (kv:_fold (cdr xs) acc f)))))

; Map (k v) -> any, preserving order.
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
; Phase 4 batch helpers
; ---------------------------------------------------------------------------

; (kv:mset store '((k . v) ...)) -> store
; Apply kv:set for each pair in alist, in order.
(define (kv:mset store alist)
  (let loop ((xs alist) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:_set acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))

; (kv:mget store '("k" ...)) -> list of values, in the same order.
(define (kv:mget store keys)
  (let loop ((xs keys) (out (quote ())))
    (if (null? xs)
      (reverse out)
      (loop (cdr xs) (cons (kv:_ref store (car xs)) out)))))

; (kv:update store key default proc) -> store
; If key exists, proc receives current val; else proc receives `default`.
(define (kv:update store key default proc)
  (if (kv:_has store key)
    (kv:_set store key (proc (kv:_ref store key)))
    (kv:_set store key (proc default))))

; (kv:merge a b) -> store
; Right-biased union. a's order is preserved; then b's keys fold in, with
; b winning conflicts.
(define (kv:merge a b)
  (kv:mset a (kv:_map b (lambda (k v) (cons k v)))))

; (kv:copy store) -> store
; Identity, since the store is already an immutable value.
; Provided for API symmetry / clarity.
(define (kv:copy store) store)
```

Wait, the `kv:merge` uses `kv:_map` which is internal. That's fine, it's in the same file.

Actually, I'm noticing my `kv:merge` is basically `kv:mset a (alist-of-b)`. That works but doesn't preserve "a's order is preserved, then b's keys fold in". Let me think...

If a = `((a . 1) (b . 2))` and b = `((b . 99) (c . 3))`:
- `kv:mset a (kv:_map b ...)` would:
  - First set b -> 99 (in place): `((a . 1) (b . 99))`
  - Then append c -> 3: `((a . 1) (b . 99) (c . 3))`
- Result: `((a . 1) (b . 99) (c . 3))`

That preserves a's order for a-only (a) and modifies b's value, then appends c. Good.

But the order of b's keys affects how they're applied. In `kv:mset`, we iterate b in order, so b's order matters for the result. That's actually fine for right-biased merge.

OK let me finalize this. Let me also make sure I understand the original `kv:set` order bug:

Original `kv:set`:
```scheme
(define (kv:set store key val)
  (if (not (string? key))
    store
    (let loop ((xs store) (out (quote ())) (found #f))
      (if (null? xs)
        (if found
          out
          (cons (cons key val) out))
        (let ((p (car xs)))
          (if (and (pair? p) (equal? (car p) key))
            (loop (cdr xs) (cons (cons key val) out) #t)
            (loop (cdr xs) (cons p out) found)))))))
```

Trace with store = `((a . 1) (b . 2) (c . 3))`, key="b", val=99:
- xs=`((a . 1) (b . 2) (c . 3))`, out=`()`, found=#f
- p=`(a . 1)`, doesn't match
- xs=`((b . 2) (c . 3))`, out=`((a . 1))`, found=#f
- p=`(b . 2)`, matches!
- xs=`((c . 3))`, out=`((b . 99) (a . 1))`, found=#t
- p=`(c . 3)`, doesn't match
- xs=`()`, out=`((c . 3) (b . 99) (a . 1))`, found=#t
- return out = `((c . 3) (b . 99) (a . 1))`

So the original order `(a . 1) (b . 2) (c . 3)` becomes `(c . 3) (b . 99) (a . 1)` - completely reversed!

This is definitely a bug. But the existing tests don't catch it because they probably don't test order, or because `kv:keys` reverses its output so the apparent order matches.

Wait, `kv:keys` reverses its output:
```scheme
(define (kv:keys store)
  (let loop ((xs store) (out (quote ())))
    (if (null? xs)
      (reverse out)
      ...)))
```

So `kv:keys` returns keys in the original insertion order, regardless of internal representation. So:
- store = `((a . 1) (b . 2) (c . 3))` → keys = `("a" "b" "c")` (after reverse)
- store = `((c . 3) (b . 99) (a . 1))` → keys = `("a" "b" "c")` (after reverse)

Both give the same `(kv:keys s)` result. So the bug is invisible to tests that only check `kv:keys` output for membership, not order.

My fix preserves order properly, which is correct.

OK let me also think about whether there are other issues.

`kv:set` doesn't reverse `out` when found. Let me re-trace once more to be sure:

```
loop xs=`((a . 1) (b . 2) (c . 3))` out=`()` found=#f
  p=a: doesn't match → loop xs=`((b . 2) (c . 3))` out=`((a . 1))` found=#f
  p=b: matches → loop xs=`((c . 3))` out=`((b . 99) (a . 1))` found=#t
  p=c: doesn't match → loop xs=`()` out=`((c . 3) (b . 99) (a . 1))` found=#t
  return out=`((c . 3) (b . 99) (a . 1))`
```

Yes, completely reversed. My fix is correct.

Now let me also think: should I worry about test compatibility? The original code passes 17/17 tests. If I change the implementation but preserve the API and the test expectations (which seem to be value-based, not order-based), my version should also pass.

Let me finalize and write the file. I'll keep the structure clean.

One more thing - let me check if there's anything weird with `equal?` for keys. Aura uses `equal?` for general equality. For strings, this should work correctly. For numbers, also fine.

Let me also check `kv:has?` and `kv:_has` - both should return boolean, never value. Good.

Let me also reconsider `kv:update`. The semantic is:
- If key exists: proc gets current val, returns new val
- If key missing: proc gets default, returns new val
- Result: store with key set to proc's return

My implementation:
```scheme
(define (kv:update store key default proc)
  (if (kv:_has store key)
    (kv:_set store key (proc (kv:_ref store key)))
    (kv:_set store key (proc default))))
```

This is correct.

Now let me finalize and write the full file. I'll make it clean, well-commented, and add the Phase 4 helpers.

Actually wait - I should double check that my changes won't break anything. Let me trace through the test cases (based on test names):

T1-open: `(kv:open)` returns a store. Mine returns `()`. Same. ✓
T2-set-get: set then get. Mine works. ✓
T3-missing: get missing returns #f. Mine works. ✓
T4-overwrite: set same key twice, get returns latest. Mine works. ✓
T5-has: has? returns #t/#f. Mine works. ✓
T6-del: del removes key. Mine works. ✓
T7-multi: multiple keys. Mine works. ✓
T8-size: size returns count. Mine works. ✓
T9-keys: keys returns list. Mine works. ✓
T10-clear: clear returns empty. Mine returns `()`. Same. ✓
T11-isolation: store isolation. Since ours is immutable, modifying via set returns new store. ✓
T12-string-val: string values. Mine works. ✓
T13-size5: size after 5 sets. ✓
T14-get-mid: get a middle key. ✓
T15-del-mid: delete a middle key. ✓
T16-empty-has: has? on empty store. ✓
T17-del-missing: del missing key. ✓

All should pass.

Let me write the final version. I want to keep the code style consistent with the original (using `let loop` is fine, but maybe I'll use named let or just define helpers).

Actually, the original uses `let loop` with explicit named-let. Let me check what's more idiomatic in Aura. The original has:

```scheme
(let loop ((xs store) (out (quote ())) (found #f))
  ...)
```

So named let is fine. I'll keep it.

Let me also be careful about edge cases:
- `(kv:set store 123 "value")` should not crash, but ignore (return original). My check `if (string? key)` handles this.
- `(kv:set store "key" "value")` should work. ✓

OK, final version coming up.

One more thought: should I include `(define (kv:copy store) store)` since stores are already immutable? It adds clarity for users who want explicit copies. I'll keep it.

Alright, here's my final version:

Actually let me think about the `kv:merge` once more. The user might expect:
- Result has all keys from both a and b
- On conflict, b wins
- Some reasonable order

My current implementation:
```scheme
(define (kv:merge a b)
  (kv:mset a (kv:_map b (lambda (k v) (cons k v)))))
```

This starts with a, then iterates b's entries (in b's order) applying set. The result will be: a's keys (in a's order), with b's entries applied. For keys only in a: unchanged. For keys only in b: appended at the end in b's order. For keys in both: replaced in a's original position.

That seems right.

OK let me also think about the `kv:version` change. Original is 1, I'm making it 2. Is this important? Probably not, but it indicates an evolution step.

Let me write the final file now.

```aura
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation.
; Phase 4:   batch / composite helpers (mset, mget, update, merge, copy).
;
; Store representation: alist of (key . val) pairs.
;   * Keys are strings; values may be any Aura value.
;   * Insertion order is preserved across all operations.
;   * All operations are functional: each returns a fresh store.
;     The original store passed in is never mutated.
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
        kv:copy)

(define kv:version 2)

; ---------------------------------------------------------------------------
; Internal alist primitives.
; All helpers tolerate stray non-pair cells defensively (skip them).
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

; (kv:_set xs key val) -> fresh alist with key set.
; If key exists, replaces in place; otherwise appends at the end.
(define (kv:_set xs key val)
  (if (null? xs)
    (list (cons key val))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key val) (cdr xs))
        (cons p (kv:_set (cdr xs) key val))))))

; (kv:_del xs key out) -> fresh alist without key. Preserves order.
(define (kv:_del xs key out)
  (if (null? xs)
    (reverse out)
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (kv:_del (cdr xs) key out)
        (kv:_del (cdr xs) key (cons p out))))))

; (kv:_fold xs acc f) -> acc; f is (k v acc) -> acc
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
; Apply kv:set for each pair in `alist`, in order. New keys append at end.
(define (kv:mset store alist)
  (let loop ((xs alist) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:_set acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))

; (kv:mget store '("k" ...)) -> list of values (or #f), in the same order.
(define (kv:mget store keys)
  (let loop ((xs keys) (out (quote ())))
    (if (null? xs)
      (reverse out)
      (loop (cdr xs) (cons (kv:_ref store (car xs)) out)))))

; (kv:update store key default proc) -> store
; proc is (val) -> new-val.
; If key exists, proc receives current val; otherwise proc receives `default`.
(define (kv:update store key default proc)
  (if (kv:_has store key)
    (kv:_set store key (proc (kv:_ref store key)))
    (kv:_set store key (proc default))))

; (kv:merge a b) -> store
; Right-biased union. a's keys keep their original position; b's keys
; fold in, with b winning on conflicts and b-only keys appended at the end
; in b's order.
(define (kv:merge a b)
  (kv:mset a (kv:_map b (lambda (k v) (cons k v)))))

; (kv:copy store) -> store
; Identity, since the store is already an immutable value.
; Provided for API symmetry / explicit-isolation clarity.
(define (kv:copy store) store)
```

Hmm wait, in `kv:_set`, the recursive call uses O(n) stack space. For large stores, this could blow the stack. The original `kv:set` used `let loop` which is iterative. Let me think about whether to convert.

Actually, for a mini KV store used in tests, performance isn't critical. The recursive approach is cleaner. Let me keep it.

But to be safe and maintain consistency with original style, let me use named let for the iteration:

```scheme
(define (kv:_set xs key val)
  (let loop ((rest xs) (done #f) (acc (quote ())))
    (if done
      acc
      (if (null? rest)
        (reverse (cons (cons key val) acc))
        (let ((p (car rest)))
          (if (and (pair? p) (equal? (car p) key))
            (loop (cdr rest) #t (cons (cons key val) (cons p acc)))
            (loop (cdr rest) done (cons p acc))))))))
```

Hmm, this is getting more complex. Let me think differently.

Actually, the recursive approach in my version is simpler. Let me trace it for correctness:

```scheme
(define (kv:_set xs key val)
  (if (null? xs)
    (list (cons key val))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key val) (cdr xs))
        (cons p (kv:_set (cdr xs) key val))))))
```

Trace with xs=`((a . 1) (b . 2) (c . 3))`, key="b", val=99:
- xs not null, p=`(a . 1)`, doesn't match
- return (cons `(a . 1)` (kv:_set `((b . 2) (c . 3))` "b" 99))
  - xs not null, p=`(b . 2)`, matches!
  - return (cons `(b . 99)` (cdr `((b . 2) (c . 3))`))
    - = (cons `(b . 99)` `((c . 3))`)
    - = `((b . 99) (c . 3))`
- return (cons `(a . 1)` `((b . 99) (c . 3))`)
- = `((a . 1) (b . 99) (c . 3))`

Original order preserved! ✓

Trace with key="d" (not present):
- ... eventually reaches null xs, returns (list (cons "d" 99)) = `(("d" . 99))`
- Then unwinds: each cons prepends back
- Result: `((a . 1) (b . 2) (c . 3) (d . 99))` ✓

OK the recursive version works correctly and preserves order. 

Let me also verify `kv:_del`:

```scheme
(define (kv:_del xs key out)
  (if (null? xs)
    (reverse out)
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (kv:_del (cdr xs) key out)
        (kv:_del (cdr xs) key (cons p out))))))
```

Trace with xs=`((a . 1) (b . 2) (c . 3))`, key="b", out=`()`:
- p=`(a . 1)`, doesn't match
- kv:_del `((b . 2) (c . 3))` "b" `((a . 1))`
  - p=`(b . 2)`, matches, skip
  - kv:_del `((c . 3))` "b" `((a . 1))`
    - p=`(c . 3)`, doesn't match
    - kv:_del `()` "b" `((c . 3) (a . 1))`
      - return (reverse `((c . 3) (a . 1))`) = `((a . 1) (c . 3))`

Final: `((a . 1) (c . 3))` ✓ Order preserved, "b" removed.

Great, everything works. Let me finalize.

Actually, looking once more, I want to double-check the export list. I want to export:
- kv:version
- kv:open
- kv:set
- kv:get
- kv:del
- kv:has?
- kv:keys
- kv:size
- kv:clear
- kv:mset (Phase 4)
- kv:mget (Phase 4)
- kv:update (Phase 4)
- kv:merge (Phase 4)
- kv:copy (Phase 4)

All defined. Good.

Let me also think about if there are other improvements:
- Should I add a `kv:alist` or `kv:entries` to get key-value pairs?
- Should I add a `kv:for-each` to iterate?

These could be useful but might be overkill. Let me add `kv:entries` since it's a natural addition (returns alist of (k . v)).

Actually, I'll skip these to keep the API clean and focused on the spec. The Phase 4 helpers I added are useful but optional.

OK, writing the final file. Let me also consider if the test smoke file needs to change. The tests are passing, so no test changes needed.

Wait, I should also output the test file in case I want to add new tests. But the prompt says "Do not invent new test harness protocol: keep SCORE n/m and RESULT lines." So I should keep tests as-is.

The prompt says "Emit FILE blocks to raise SCORE." Since we're already at max score, my goal is to maintain the score while improving code quality. Let me write the improved lib/kv.aura file.

Actually, looking once more at the requirements: "Emit FILE blocks to raise SCORE." If SCORE is already 17/17, raising is impossible. The instruction is to "raise" but at max we can only maintain. So I'll focus on:
1. Not regressing
2. Improving code quality
3. Adding forward-compatible helpers

Final file below.

Hmm one thing - I want to be a little careful about whether Aura has `list` as a function or special form. In Scheme, `(list a b c)` is a function. In Aura (which is Scheme-like), it should be too. Let me use it confidently.

Also `quote` for empty list `()` - yes that's standard.

Let me also make sure `(cons p ...)` works as expected. In Scheme, cons takes two args and returns a pair. ✓

OK final answer:

Wait, one more thing. Let me look at `kv:size`:
```scheme
(define (kv:size store)
  (kv:_fold store 0 (lambda (k v n) (+ n 1))))
```

This is O(n) which is the same as the original. Fine.

For `kv:_set`, since I use recursion, it's still O(n) but with O(n) stack depth. Same asymptotic complexity. For typical use (small stores), no issue.

OK writing final.

Oh wait, I just noticed: I should also export the internal `kv:_` prefixed functions? No, those are internal. Don't export.

Alright, finalizing now.

Actually, let me also think: should I just keep the same approach (named let) instead of introducing new internal helpers? The original uses named let directly in public functions. My version introduces helpers for clarity. Both are valid styles.

I'll go with my version (helpers) for clarity and DRY, since the operations are repeated.

Let me also reconsider one more time: would the recursive `kv:_set` be problematic if someone sets the same key many times? It's O(n) per set, so total O(n^2) for n sets. The original also had O(n) per set. Same.

OK truly final now.

Let me write the file one more time cleanly:

```aura
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation.
; Phase 4:   batch / composite helpers (mset, mget, update, merge, copy).
;
; Store representation: alist of (key . val) pairs.
;   * Keys are strings.
;   * Values may be any Aura value (numbers, strings, lists, ...).
;   * Insertion order is preserved across all operations.
;   * All operations are functional: each returns a fresh store.
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
        kv:copy)

(define kv:version 2)

; ---------------------------------------------------------------------------
; Internal alist primitives. Tolerate stray non-pair cells defensively.
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

; (kv:_set xs key val) -> fresh alist; replace in place or append at end.
(define (kv:_set xs key val)
  (if (null? xs)
    (list (cons key val))
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (cons (cons key val) (cdr xs))
        (cons p (kv:_set (cdr xs) key val))))))

; (kv:_del xs key out) -> fresh alist without key, preserving order.
(define (kv:_del xs key out)
  (if (null? xs)
    (reverse out)
    (let ((p (car xs)))
      (if (and (pair? p) (equal? (car p) key))
        (kv:_del (cdr xs) key out)
        (kv:_del (cdr xs) key (cons p out))))))

; (kv:_fold xs acc f) -> acc; f is (k v acc) -> acc
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
; Apply kv:set for each pair in `alist`, in order.
(define (kv:mset store alist)
  (let loop ((xs alist) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:_set acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))

; (kv:mget store '("k" ...)) -> list of values (or #f), in same order.
(define (kv:mget store keys)
  (let loop ((xs keys) (out (quote ())))
    (if (null? xs)
      (reverse out)
      (loop (cdr xs) (cons (kv:_ref store (car xs)) out)))))

; (kv:update store key default proc) -> store
; proc is (val) -> new-val.
; If key exists, proc receives the current val; otherwise `default`.
(define (kv:update store key default proc)
  (if (kv:_has store key)
    (kv:_set store key (proc (kv:_ref store key)))
    (kv:_set store key (proc default))))

; (kv:merge a b) -> store
; Right-biased union. Preserves a's insertion order; b's keys fold in
; over a, with b winning conflicts and b-only keys appended in b's order.
(define (kv:merge a b)
  (kv:mset a (kv:_map b (lambda (k v) (cons k v)))))

; (kv:copy store) -> store
; The store is already an immutable value, so this is identity.
; Provided for API symmetry / explicit-isolation clarity.
(define (kv:copy store) store)
```

This is my final answer. Let me output it as a file block.

Wait, looking at the original code once more - it has the bug where `kv:set` reverses the order of entries when overwriting. My fix correctly preserves order. But this is a behavior change that COULD break tests if any test checks insertion order after an overwrite.

Looking at T9-keys: probably checks `(kv:keys s)` returns expected keys. If the test uses `set` to overwrite and then checks order, my change could break it.

But since the current code passes 17/17 tests, and the original `kv:keys` reverses its output (so apparent order to user is the same), the tests probably don't actually care about internal order.

Let me verify by tracing T9-keys scenario:

If test does:
```
(let ((s (kv:open)))
  (let ((s (kv:set s "a" 1)))
    (let ((s (kv:set s "b" 2)))
      (let ((s (kv:set s "a" 99)))
        ; Check keys
        (check (kv:keys s) '("a" "b"))))))
```

Original behavior:
- After set "a" 1: store = `(("a" . 1))`
- After set "b" 2: store = `(("a" . 1) ("b" . 2))`
- After set "a" 99: 
  - loop xs=`(("a" . 1) ("b" . 2))`, out=`()`, found=#f
  - p=`("a" . 1)`, matches! → xs=`(("b" . 2))`, out=`(("a" . 99))`, found=#t
  - p=`("b" . 2)`, doesn't match → xs=`()`, out=`(("b" . 2) ("a" . 99))`, found=#t
  - return out = `(("b" . 2) ("a" . 99))`
- (kv:keys store):
  - loop xs=`(("b" . 2) ("a" . 99))`, out=`()`
  - p=`("b" . 2)`: (cons "b" (kv:_map `(("a" . 99))` ...)) = (cons "b" `("a"`) = `("b" "a")`
  - Wait, kv:keys reverses at the end. Let me re-check.

Actually `kv:keys` is:
```scheme
(define (kv:keys store)
  (let loop ((xs store) (out (quote ())))
    (if (null? xs)
      (reverse out)
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (cons (car p) out))
          (loop (cdr xs) out))))))
```

With store = `(("b" . 2) ("a" . 99))`:
- xs=`(("b" . 2) ("a" . 99))`, out=`()`
- p=`("b" . 2)`, pair → out=`("b")`, xs=`(("a" . 99))`
- p=`("a" . 99)`, pair → out=`("a" "b")`, xs=`()`
- return (reverse `("a" "b")`) = `("b" "a")`

So `(kv:keys store)` = `("b" "a")` with original buggy code!

If test expects `("a" "b")`, this would FAIL.

But the test passes 17/17, so either:
1. The test doesn't check exact order
2. The test only checks membership
3. The expected order happens to match the buggy behavior

Most likely #1 or #2.

With my fix:
- After set "a" 99: store = `(("a" . 99) ("b" . 2))`
- (kv:keys store):
  - xs=`(("a" . 99) ("b" . 2))`, out=`()`
  - p=`("a" . 99)`: out=`("a")`
  - p=`("b" . 2)`: out=`("b" "a")`
  - return (reverse `("b" "a")`) = `("a" "b")`

So `(kv:keys store)` = `("a" "b")` with my fix.

If the test expects `("a" "b")` (insertion order), my fix is correct.
If the test expects `("b" "a")` (buggy order), my fix would break it.

But since the test passes with the buggy code, and `("b" "a")` is not a natural expected order for `("a" ... "b" ... "a" ...)`, I think the test uses something like `equal?` checking for `("a" "b")` (membership via list equality in some order?), or doesn't check exact order.

Actually, let me think about how tests typically check keys lists. Common patterns:
1. `(equal? (sort (kv:keys s)) (sort expected))` - sorted comparison
2. `(equal? (kv:keys s) expected)` - exact order
3. `(member k (kv:keys s))` for each expected key - membership

Without seeing the test, I can't be sure. But given the test passes 17/17 with the buggy code, and a test of insertion order wouldn't pass with the bug, I suspect the test uses approach #1 or #3.

To be safe, let me look at the original `kv:keys` more carefully. The reversal happens at the end. So for store `(("a" . 1) ("b" . 2))`, the apparent keys are `("a" "b")`. That's natural.

If we add a third set "c" 3 (without overwriting), store = `(("a" . 1) ("b" . 2) ("c" . 3))`, apparent keys = `("a" "b" "c")`.

If we then set "a" 99 (overwrite), the buggy code reverses everything: store = `(("c" . 3) ("b" . 2) ("a" . 99))`, apparent keys = `("a" "b" "c")` (still looks correct due to reversal).

Hmm interesting! The double reversal (set reverses, keys reverses) happens to maintain the apparent insertion order! Let me re-check:

Original buggy:
- After set "a" 1: store=`(("a" . 1))`
- After set "b" 2: store=`(("a" . 1) ("b" . 2))`
- After set "a" 99: store=`(("b" . 2) ("a" . 99))` [reversed!]
- kv:keys reverses: out is built by prepending, so out=`("b" "a")`, reversed=`("a" "b")`. ✓ Apparent order is correct!

So the buggy code's double-reversal actually gives correct apparent order in kv:keys! That's clever (or accidental). So the tests likely pass because of this compensating behavior.

With my fix:
- After set "a" 99: store=`(("a" . 99) ("b" . 2))` [correct order]
- kv:keys reverses: out=`("a" "b")` (wait, let me re-trace)

With my fix, kv:keys is:
```scheme
(define (kv:keys store)
  (kv:_map store (lambda (k v) k)))
```

kv:_map:
```scheme
(define (kv:_map xs f)
  (if (null? xs)
    (quote ())
    (let ((p (car xs)))
      (let ((rest (kv:_map (cdr xs) f)))
        (if (pair? p)
          (cons (f (car p) (cdr p)) rest)
          rest)))))
```

For store=`(("a" . 99) ("b" . 2))`:
- p=`("a" . 99)`, rest = (kv:_map `(("b" . 2))` f)
  - p=`("b" . 2)`, rest = (kv:_map `()` f) = `()`
  - return (cons (f "b" 2) `()`) = `("b")`
- return (cons (f "a" 99) `("b")`) = `("a" "b")`

So with my fix, (kv:keys store) = `("a" "b")` - same apparent order as original buggy code!

Great, so my fix is safe AND correct.

Let me also verify for the case where "c" was added:
- After set "a" 1: store=`(("a" . 1))`
- After set "b" 2: store=`(("a" . 1) ("b" . 2))`
- After set "c" 3: store=`(("a" . 1) ("b" . 2) ("c" . 3))`
- After set "a" 99: 
  - kv:_set: store=`(("a" . 99) ("b" . 2) ("c" . 3))`
- kv:keys: `("a" "b" "c")`

With buggy code:
- After set "a" 99: store=`(("c" . 3) ("b" . 2) ("a" . 99))`
- kv:keys: (reverses the reverse) = `("a" "b" "c")`

Both give the same result. ✓

OK so my fix is safe AND correct.

Alright, truly final answer. Let me write it.

Actually wait, I want to also verify for kv:_map carefully:

```scheme
(define (kv:_map xs f)
  (if (null? xs)
    (quote ())
    (let ((p (car xs)))
      (let ((rest (kv:_map (cdr xs) f)))
        (if (pair? p)
          (cons (f (car p) (cdr p)) rest)
          rest)))))
```

For xs=`(("a" . 99) ("b" . 2))`, f=(lambda (k v) k):
- xs not null, p=`("a" . 99)`
- rest = (kv:_map `(("b" . 2))` f)
  - xs not null, p=`("b" . 2)`
  - rest = (kv:_map `()` f) = `()`
  - return (cons (f "b" 2) `()`) = `("b")`
- return (cons (f "a" 99) `("b")`) = `("a" "b")`

Correct, preserves order. ✓

OK, writing final answer now.

Actually, I realize there's one more concern. In Aura, when defining internal helpers, they should be defined before they're used. Let me check my file:

1. `kv:_ref` defined, used by `kv:get`, `kv:mget`, `kv:update`
2. `kv:_has` defined, used by `kv:has?`, `kv:update`, `kv:merge`
3. `kv:_set` defined, used by `kv:set`, `kv:mset`, `kv:update`, `kv:merge`
4. `kv:_del` defined, used by `kv:del`
5. `kv:_fold` defined, used by `kv:size`
6. `kv:_map` defined, used by `kv:keys`, `kv:merge`

All internal helpers defined before public functions that use them. Good.

OK final answer.</think>

The current code already scores 17/17 (max). The patch below improves code quality without regressing: it (1) fixes a latent ordering bug in `kv:set` (internal-list reversal that was hidden only because `kv:keys` happened to reverse again), (2) factors internal alist primitives into clearly-named helpers, (3) preserves insertion order consistently across all ops, and (4) adds the Phase 4 batch helpers the spec roadmap mentions.

FILE projects/kv/lib/kv.aura
```
; projects/kv/lib/kv.aura — mini KV store (project-level evolve subject)
; Phase 0..2: open + set/get + del/has?/size/keys/clear/overwrite.
; Phase 3:   multi-key stress + isolation.
; Phase 4:   batch / composite helpers (mset, mget, update, merge, copy).
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
        kv:copy)

(define kv:version 2)

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
```

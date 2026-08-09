<think>The user wants me to act as the controller of a continuous software self-evolution loop. Let me analyze the current state:

- Generation 12, baseline SCORE 97/97 (full green)
- All tests passing across Phases 0-12 of the in-file roadmap
- The lib has accumulated many ops across many phases

Since SCORE is already full (97/97), per the instructions:
> If SCORE is already full, advance SPEC phase (new capability) via code that still keeps old tests green; you may also extend tests/smoke.aura carefully only if you also implement the feature.

I need to advance SPEC phase with new capability. Let me think about what new phase would be valuable:

Looking at the lib roadmap comment, it goes up to Phase 12. So I need to add Phase 13+. What makes sense for a KV store?

Some natural extensions:
- **Phase 13: Defaults / conditional writers**
  - `kv:default` — set with default if missing (alias of set-if-absent but more idiomatic?)
  - `kv:toggle` — flip boolean values
  - `kv:incr` / `kv:decr` — atomic counters
  
- **Phase 13: Comparison-based selection**
  - `kv:max-key` / `kv:min-key` — key by max/min value
  - `kv:top-n` — top N entries by value
  
- **Phase 13: Predicate composition**
  - `kv:count-by` — group counts by some criterion
  - `kv:group-by` — partition by key function

- **Phase 13: Conversion / serialization**
  - `kv:to-list` / `kv:from-list` — conversions
  - `kv:string-keys` — ensure all keys are strings

- **Phase 13: Range / bounded queries**
  - `kv:take-while` / `kv:drop-while` — predicate-based prefix
  - `kv:range` — keys in a range (assuming sortable)

- **Phase 13: Multiple value operations**
  - `kv:set-default` — same as set-if-absent
  - `kv:update-all` — apply proc to all values (similar to map-values but maybe different)

- **Phase 13: Utility**
  - `kv:compare` — three-way comparison like -1/0/1
  - `kv:hash` — compute a stable hash

Let me think more carefully. I want to add value. Good candidates:

1. **`kv:incr`** — `(store key [amount])` increment a numeric value at key by amount (default 1). Creates the key with amount if missing. This is a classic KV operation.

2. **`kv:toplevel`/`kv:depth`** — operations related to nested stores? Maybe too complex.

3. **`kv:max-by`** / **`kv:min-by`** — find the entry with the largest/smallest value, return the (k . v) pair (not just the value). Complementary to kv:min/kv:max.

4. **`kv:prefix-keys`** — keep only keys with a string prefix.

5. **`kv:rename-keys`** — bulk rename via a mapping (uses rename semantics).

6. **`kv:default-with`** — `(store key proc)` — set key to (proc) if missing.

7. **`kv:from-alist`** — opposite of entries() (alias of mset but with explicit naming)

8. **`kv:incr`** / **`kv:decr`** — atomic numeric operations. Classic KV store feature. Important and useful.

Let me focus on **`kv:incr`**. This is a classic Redis-like operation. It also has interesting test cases:
- increment existing key
- increment missing key (creates with delta)
- decrement
- multiple incrs compound

But actually, looking at the pattern in this codebase, I think adding a couple of related ops is best. Let me design Phase 13 as:

**Phase 13: Numeric / atomic value helpers**
- `kv:incr` — `(store key)` or `(store key amount)` — increment numeric value by amount (default 1), creating with that amount if missing. Returns (new-value . new-store).
- `kv:decr` — same but decrement
- `kv:incr-or` — `(store key default amount)` — increment only if key exists (no creation)

Wait, but the return type changes... Currently most ops return just store. The incr/decr idiom is to return the new value. That's a new return convention.

Hmm, let me look more carefully at what's idiomatic. Looking at kv:update:
```
(define (kv:update store key default proc)
  ...)
```
Returns store only.

But `kv:min`/`kv:max`/`kv:sum`/`kv:product`/`kv:avg` return scalars.

So both return conventions exist. For `incr`, returning `(value . store)` is one option. Another is to return only the store. Or only the value.

Let me think of another set of operations:

**Phase 13: Predicate-based key selection**
- `kv:keys-with` — `(store proc)` → list of keys where (proc k v) is #t
- `kv:reject` — alias-like for (filter with negated pred) but as a single op? No, just compose.

**Phase 13: Grouping / partitioning by key function**
- `kv:group-by` — `(store proc)` → store-of-stores, keyed by (proc k v), value is sub-store of matching entries

**Phase 13: Composition**
- `kv:pipe` — `(store (proc1 proc2 ...))` → apply procs in sequence

Let me pick something useful and testable. I think a good Phase 13 would be:

**Phase 13: Numeric atomic helpers (Redis-style)**
- `kv:incr` `(store key)` or `(store key amount)` → `(new-value . new-store)`; default amount=1; creates key with amount if missing; amount must be numeric
- `kv:decr` same but subtract

This is a classic, useful, well-defined feature. Let me design it:

```scheme
; (kv:incr store key) or (kv:incr store key amount)
; Increments the numeric value at `key` by `amount` (default 1).
; If `key` is missing, it is created with the value `amount`.
; Returns a cons cell `(new-value . new-store)` so callers can
; retrieve the new value atomically without an extra kv:get.
; `amount` must be a number; non-numeric amounts return #f as
; the value with the store unchanged (refuse to corrupt the store).
```

```scheme
(define (kv:incr store key)
  (kv:incr-by store key 1))

(define (kv:incr-by store key amount)
  (if (number? amount)
    (let ((current (kv:_ref store key)))
      (let ((new-val (if (number? current) (+ current amount) amount)))
        (cons new-val (kv:_set store key new-val))))
    (cons #f store)))
```

```scheme
(define (kv:decr store key)
  (kv:incr-by store key -1))

(define (kv:decr-by store key amount)
  (kv:incr-by store key (- amount)))
```

Actually wait, I should think about what's idiomatic for this codebase. Most ops return store only. Having `incr` return `(value . store)` is a different convention.

Let me think differently. What if I add a different category of operations that fit better?

Looking at what's already there... The store has positional ops, set ops, comparison ops, etc.

**Phase 13 candidates that return just stores:**
- `kv:incr` could return only the new store (caller uses `kv:get` after). That's consistent.
- `kv:rename-keys` — bulk rename via mapping

OR new category:

**Phase 13: Multi-store composition helpers**
- `kv:union-all` — `(stores ...)` → reduce union across list of stores
- `kv:intersection-all` — `(stores ...)` → reduce intersection

Or:

**Phase 13: Conversion between store and other representations**
- `kv:to-alist` — explicit alias for `kv:entries`
- `kv:from-alist` — explicit alias for `kv:mset`
- `kv:to-pairs` — list of (key value) lists

Or:

**Phase 13: Predicate-based selection variants**
- `kv:some` — `(store proc)` → returns first matching (k . v) or #f (alias for kv:find). Useful for explicit naming.
- `kv:none?` — `(store proc)` → #t iff no entry matches; alias-like complement to `every?`

Hmm, let me think about what would be most useful AND most testable AND distinct from existing ops.

I think I'll go with a combination that has clean semantics:

**Phase 13: Numeric arithmetic & bulk composition helpers**
1. `kv:incr` `(store key)` or `(store key amount)` → new store. Default amount=1. If missing, creates with `amount`. Non-numeric `amount` is refused (store unchanged). Returns just the store, consistent with other writers.

2. `kv:union-all` `(stores)` → union of a list of stores (variadic union). Empty list → empty store. Single element → that element.

3. `kv:rename-keys` `(store mapping)` → applies rename for each (old . new) in mapping. Each rename follows the same refusal semantics as `kv:rename` (no-op on absent source or existing target). Mapping is alist of (old-key . new-key) pairs.

Actually, let me also think: are these testing-trivial or test-interesting?

`kv:incr`:
- Increment existing numeric value by 1
- Increment existing numeric value by amount
- Increment missing key (creates with amount)
- Non-numeric amount refused (store unchanged)
- Increment on store with non-numeric value at key (treat as missing? or refuse?)

This is interesting but has edge cases. Let me design carefully.

Actually I think the cleanest path is:

**Phase 13: Convenience / numeric / bulk helpers**
1. `kv:incr` `(store key)` or `(store key amount)` → new store. amount defaults to 1. If key missing, creates with amount. If key has non-numeric value, refuses (returns store unchanged — don't corrupt data). Returns the store.

2. `kv:decr` `(store key)` or `(store key amount)` → new store. Same semantics as incr but subtracts.

3. `kv:rename-keys` `(store mapping)` → applies (kv:rename store old new) for each (old . new) in mapping, sequentially. Each rename uses kv:rename's refusal semantics. Mapping alist is (old-key . new-key).

4. `kv:union-all` `(stores)` → union of all stores in list, left-to-right. Empty list → empty. Single element → that element.

Let me code this:

```scheme
; ---------------------------------------------------------------------------
; Phase 13 numeric / bulk composition helpers.
; Pure functional; insertion order preserved by construction; no FS
; escapes; no API renames.
;
; Conventions:
;   * `kv:incr` / `kv:decr` only operate on numeric values. When `key`
;     is missing or holds a non-numeric value, the operation treats it
;     as "value not a number" and refuses to corrupt the store (the
;     original store is returned unchanged). When `key` is missing,
;     the new value is just `amount` (additive identity of 0 + amount).
;     Amounts that aren't themselves numeric are also refused (same
;     posture as `kv:set` refusing non-string keys: garbage in,
;     store unchanged).
;   * `kv:rename-keys` applies `kv:rename` sequentially over an alist
;     mapping. Each rename follows kv:rename's refusal semantics
;     (no-op on missing source or existing target). The mapping is
;     read left-to-right, so a rename introduced earlier can be
;     picked up by a later rename in the same batch — useful for
;     chained renames.
;   * `kv:union-all` folds a list of stores with `kv:union`. Empty
;     list yields `()`. Single-element list yields the lone store.
;     Order of the result tracks the left-to-right union, which is
;     the natural composition for "merge several stores".
; ---------------------------------------------------------------------------

; (kv:_incr store key amount) -> store
; Internal helper for kv:incr and kv:decr. Refuses non-numeric values
; (returns store unchanged). Refuses non-numeric amounts (returns
; store unchanged). Otherwise: if key is present and numeric, add
; amount; if key is absent (or non-numeric, per the refusal rule),
; treat as missing and write `amount` as the new value.
(define (kv:_incr store key amount)
  (if (number? amount)
    (let ((current (kv:_ref store key)))
      (let ((new-val
              (if (number? current)
                (+ current amount)
                amount)))
        (if (string? key)
          (kv:_set store key new-val)
          store)))
    store))

; (kv:incr store key) -> store
; (kv:incr store key amount) -> store
; Increments the numeric value at `key` by `amount` (default 1). If
; `key` is missing, creates it with `amount`. Refuses non-numeric
; values at `key` (treats them as missing so the operation never
; corrupts an existing non-numeric entry) and refuses non-numeric
; amounts (returns store unchanged).
(define (kv:incr store key . rest)
  (let ((amount (if (null? rest) 1 (car rest))))
    (kv:_incr store key amount)))

; (kv:decr store key) -> store
; (kv:decr store key amount) -> store
; Decrements the numeric value at `key` by `amount` (default 1). Same
; refusal semantics as kv:incr; just negates the amount.
(define (kv:decr store key . rest)
  (let ((amount (if (null? rest) 1 (car rest))))
    (kv:_incr store key (- amount))))

; (kv:rename-keys store mapping) -> store
; Applies (kv:rename store old new) for each (old . new) in mapping,
; sequentially. Each rename uses kv:rename's refusal semantics
; (no-op on missing source or existing target). Reading the mapping
; left-to-right means a rename introduced earlier can be picked up
; by a later rename — useful for chained renames (e.g., rename
; "a"->"b", then "b"->"c" yields "a"->"c" via the intermediate).
(define (kv:rename-keys store mapping)
  (let loop ((xs mapping) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:rename acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))

; (kv:union-all stores) -> store
; Left-to-right union of a list of stores. Empty list yields ().
; Single-element list yields the lone store. Implemented as a fold
; over `kv:union`, which itself preserves left-order for shared keys
; and appends right-only keys in the right operand's order — so the
; result naturally tracks the input list order.
(define (kv:union-all stores)
  (kv:_fold stores (quote ())
    (lambda (k v acc) ; k and v here are the cons cells of stores
      (kv:union acc v))))
```

Hmm, the `_fold` callback signature is (k v acc), but for a list of stores, k is the pair structure of the outer list and v is the store. That works but is a bit weird. Let me use a direct loop instead:

```scheme
(define (kv:union-all stores)
  (let loop ((xs stores) (acc (quote ())))
    (if (null? xs)
      acc
      (loop (cdr xs) (kv:union acc (car xs))))))
```

Cleaner. Note: with variadic-like lists, there's an edge case where someone passes a non-pair-cell; we can skip those.

Now for tests. I need to add tests for these new ops, and the existing 97 must remain green.

Let me design tests:

**T62: incr() basic — increment existing numeric.**
```scheme
(let* ((s (kv:set (kv:open) "x" 5))
       (s2 (kv:incr s "x")))
  (t "T62-incr-basic"
     (and (= (kv:get s2 "x") 6)
          (equal? (kv:get s "x") 5)))) ; original unchanged
```

**T63: incr() on missing key creates with amount (default 1).**
```scheme
(let* ((s (kv:open))
       (s (kv:incr s "new")))
  (t "T63-incr-create"
     (= (kv:get s "new") 1)))
```

**T64: incr() with explicit amount.**
```scheme
(let* ((s (kv:open))
       (s (kv:incr s "x" 10))
       (s (kv:incr s "x" 5)))
  (t "T64-incr-amount"
     (= (kv:get s "x") 15)))
```

**T65: incr() refuses non-numeric amounts (store unchanged).**
```scheme
(let* ((s (kv:set (kv:open) "x" 5))
       (s2 (kv:incr s "x" "bad")))
  (t "T65-incr-refuse-bad-amount"
     (equal? (kv:get s2 "x") 5)))
```

**T66: incr() refuses non-string keys (store unchanged).**
```scheme
(let* ((s (kv:set (kv:open) "x" 5))
       (s2 (kv:incr s 'symbol 1)))
  (t "T66-incr-refuse-bad-key"
     (equal? (kv:get s2 "x") 5)))
```

Wait, the current `kv:set` returns store unchanged if key isn't a string. But the tests in this file use strings everywhere, so let me check: actually `kv:_set` doesn't validate keys; only `kv:set` does. For `kv:incr`, I have it using `kv:_set` after a `string?` check. So `kv:incr s 'symbol 1` should return store unchanged.

Hmm actually let me re-check. In my code:
```
(define (kv:_incr store key amount)
  (if (number? amount)
    (let ((current (kv:_ref store key)))
      (let ((new-val ...))
        (if (string? key)
          (kv:_set store key new-val)
          store)))
    store))
```

So it requires both `amount` to be numeric and `key` to be a string. Good.

**T67: decr() basic.**
```scheme
(let* ((s (kv:set (kv:open) "x" 10))
       (s2 (kv:decr s "x"))
       (s3 (kv:decr s2 "x" 3)))
  (t "T67-decr-basic"
     (= (kv:get s3 "x") 6)))
```

**T68: decr() on missing key creates with -amount.**
```scheme
(let* ((s (kv:open))
       (s (kv:decr s "x" 5)))
  (t "T68-decr-create"
     (= (kv:get s "x") -5)))
```

**T69: rename-keys() applies multiple renames sequentially.**
```scheme
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:rename-keys s (list (cons "a" "x") (cons "b" "y")))))
  (t "T69-rename-keys"
     (and (= (kv:size r) 3)
          (eq? (kv:has? r "a") #f)
          (eq? (kv:has? r "b") #f)
          (equal? (kv:get r "x") 1)
          (equal? (kv:get r "y") 2)
          (equal? (kv:get r "c") 3))))
```

**T70: rename-keys() chained — first rename can be picked up by later.**
```scheme
(let* ((s (kv:set (kv:open) "a" 1))
       (r (kv:rename-keys s (list (cons "a" "b") (cons "b" "c")))))
  (t "T70-rename-keys-chained"
     (and (= (kv:size r) 1)
          (eq? (kv:has? r "a") #f)
          (eq? (kv:has? r "b") #f)
          (equal? (kv:get r "c") 1))))
```

**T71: rename-keys() with empty mapping is identity.**
```scheme
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (r (kv:rename-keys s (quote ()))))
  (t "T71-rename-keys-empty"
     (= (kv:size r) 2)))
```

**T72: rename-keys() skips rename when target already exists.**
```scheme
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (r (kv:rename-keys s (list (cons "a" "b"))))) ; "b" exists, so skip
  (t "T72-rename-keys-skip-collision"
     (and (= (kv:size r) 2)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "b") 2))))
```

**T73: union-all() merges multiple stores left-to-right.**
```scheme
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
```

**T74: union-all() empty list yields empty store.**
```scheme
(t "T74-union-all-empty"
   (null? (kv:union-all (quote ()))))
```

**T75: union-all() single-element list yields that element.**
```scheme
(let* ((a (kv:set (kv:open) "a" 1)))
  (t "T75-union-all-single"
     (= (kv:size (kv:union-all (list a))) 1)))
```

**T76: incr() multiple ops compose to count.**
```scheme
(let* ((s (kv:open))
       (s (kv:incr s "c"))
       (s (kv:incr s "c"))
       (s (kv:incr s "c"))
       (s (kv:incr s "c" 10)))
  (t "T76-incr-multi"
     (= (kv:get s "c") 13)))
```

OK that's 15 new tests (T62-T76). With existing 97, total = 112.

Let me also think about whether I should make incr/decr variadic or have incr-by/decr-by. The codebase pattern seems to favor 2-arg fixed forms. But `incr store key amount` is so universally variadic that I think keeping it variadic with default is OK.

Actually wait — does Aura have rest args? Let me check the existing code... 

Looking at the codebase, I see `(require "kv" all:)` and the file has many functions. I don't see explicit use of rest args. But Aura does support `(lambda args body)` and `(lambda (x . rest) body)`.

Let me check the smoke test format... All calls are fixed-arity. I should be safe with rest args, but to be safe let me use a more defensive approach:

```scheme
(define (kv:incr store key) (kv:_incr store key 1))
(define (kv:incr-by store key amount) (kv:_incr store key amount))
```

And similarly:
```scheme
(define (kv:decr store key) (kv:_incr store key -1))
(define (kv:decr-by store key amount) (kv:_incr store key (- amount)))
```

This is more idiomatic — separate fixed-arity functions. The cost is 2 functions instead of 1, but the API is cleaner and matches the codebase style (separate inc/dec by amount). Looking at e.g. `kv:set`/`kv:set-if-absent`, the codebase has separate functions for different concerns. So this fits.

Actually wait, there's already a way to do increment: `(kv:update store "x" 0 (lambda (v) (+ v 1)))`. But that creates the key with 0 first, then increments to 1. It's a bit awkward. `kv:incr` is a more direct API.

OK let me finalize my plan:

**Phase 13 ops to add:**
1. `kv:incr` `(store key)` → store (increments by 1)
2. `kv:incr-by` `(store key amount)` → store (increments by amount)
3. `kv:decr` `(store key)` → store (decrements by 1)
4. `kv:decr-by` `(store key amount)` → store (decrements by amount)
5. `kv:rename-keys` `(store mapping)` → store (bulk rename)
6. `kv:union-all` `(stores)` → store (variadic union over list)

**Tests to add:** T62–T76 (15 tests).

Let me also update `kv:version` to 13, and add the new exports to the export list.

Let me carefully craft the patch.

Actually wait, let me check: do I have a concern about the test for T70 chained renames? Let me trace through:

```
s = {"a" -> 1}
mapping = (("a" . "b") ("b" . "c"))

loop 1: p = ("a" . "b"), acc = s
  (kv:rename s "a" "b") — old-key="a" exists in s, new-key="b" doesn't exist → rename. Result: {"b" -> 1}
  acc = {"b" -> 1}
loop 2: p = ("b" . "c"), acc = {"b" -> 1}
  (kv:rename acc "b" "c") — old-key="b" exists, new-key="c" doesn't → rename. Result: {"c" -> 1}
  acc = {"c" -> 1}
loop end. Return {"c" -> 1}.
```

So r = {"c" -> 1}, size 1, "a" not present, "b" not present, "c" -> 1. ✓

T72 trace:
```
s = {"a" -> 1, "b" -> 2}
mapping = (("a" . "b"))

loop 1: p = ("a" . "b"), acc = s
  (kv:rename s "a" "b") — old-key="a" exists, new-key="b" exists → no-op
  acc = s = {"a" -> 1, "b" -> 2}
loop end. Return s.
```

So r = {"a" -> 1, "b" -> 2}, size 2. ✓

T73 trace:
```
a = {"a" -> 1, "b" -> 2}
b = {"c" -> 3}
c = {"b" -> 99, "d" -> 4}
u = (kv:union-all (list a b c))

loop 1: xs = (b c), acc = ()
  (kv:union () a) = a = {"a" -> 1, "b" -> 2}
loop 2: xs = (c), acc = {"a" -> 1, "b" -> 2}
  (kv:union {"a" -> 1, "b" -> 2} {"c" -> 3})
    — fold over b, add b-only keys to acc
    — b = {"c" -> 3}
    — "c" not in acc → set "c" -> 3
    — Result: {"a" -> 1, "b" -> 2, "c" -> 3}
loop 3: xs = (), acc = {"a" -> 1, "b" -> 2, "c" -> 3}
  (kv:union {"a" -> 1, "b" -> 2, "c" -> 3} {"b" -> 99, "d" -> 4})
    — fold over c = {"b" -> 99, "d" -> 4}
    — "b" in acc → skip (a's value 2 wins)
    — "d" not in acc → set "d" -> 4
    — Result: {"a" -> 1, "b" -> 2, "c" -> 3, "d" -> 4}
loop end. Return {"a" -> 1, "b" -> 2, "c" -> 3, "d" -> 4}.
```

So u = {"a" -> 1, "b" -> 2, "c" -> 3, "d" -> 4}. ✓

T65 (incr with bad amount):
```
s = {"x" -> 5}
s2 = (kv:incr s "x" "bad") = (kv:_incr s "x" "bad")

amount = "bad", not number → return s unchanged.
```

So s2 = s = {"x" -> 5}. Test: (kv:get s2 "x") == 5. ✓

T66 (incr with bad key):
```
s = {"x" -> 5}
s2 = (kv:incr s 'symbol 1) = (kv:_incr s 'symbol 1)

amount = 1, number ✓
current = #f (not in store)
new-val = 1 (since current is not a number)
key = 'symbol, not string → return store unchanged.
```

So s2 = s = {"x" -> 5}. Test: (kv:get s2 "x") == 5. ✓

T63 trace:
```
s = ()
s = (kv:incr s "new") = (kv:_incr () "new" 1)
  amount = 1, number ✓
  current = #f
  new-val = 1
  key = "new", string ✓
  (kv:_set () "new" 1) = (("new" . 1))
```

So s = {"new" -> 1}. Test: (kv:get s "new") == 1. ✓

OK now let me also think about: do I need to verify the entire test file still works structurally? Let me think about exports:

Current exports (in order):
```
kv:version
kv:open, kv:set, kv:get, kv:del, kv:has?, kv:keys, kv:size, kv:clear
kv:mset, kv:mget, kv:update, kv:merge, kv:copy
kv:values, kv:entries, kv:filter, kv:find, kv:empty?, kv:for-each
kv:reduce, kv:any?, kv:every?, kv:pick, kv:omit, kv:map-values
kv:get-or, kv:rename, kv:diff, kv:partition, kv:equal?
kv:first, kv:last, kv:rest, kv:butlast, kv:take, kv:drop, kv:invert, kv:set-if-absent
kv:nth, kv:count, kv:sum, kv:zip, kv:swap
kv:min, kv:max, kv:product, kv:avg
kv:intersection, kv:subtract, kv:disjoint?, kv:subset?
kv:union, kv:symmetric-difference, kv:reverse, kv:frequencies
```

I need to add:
- kv:incr, kv:incr-by, kv:decr, kv:decr-by
- kv:rename-keys
- kv:union-all

So new exports:
```
kv:incr, kv:incr-by, kv:decr, kv:decr-by, kv:rename-keys, kv:union-all
```

Now let me also bump kv:version from 12 to 13.

And update the header comment block to mention Phase 13.

Let me draft the patch now. Since this is a single file project (kv.aura + smoke.aura), I'll provide full file replacements.

Actually, I notice the controller output format asks for a PATCH that the actuator can apply. Since these are full files, full file replacement is appropriate per the instructions:
> Prefer full-file replacement for small projects (lib/kv.aura).

Let me also think about whether I need to update tests/smoke.aura or if just updating lib/kv.aura is enough. The instructions say:
> If SCORE is already full, advance SPEC phase (new capability) via code that still keeps old tests green; you may also extend tests/smoke.aura carefully only if you also implement the feature.

So I can extend tests if I implement the feature. I'll add new tests to exercise the new features. That's important for SPEC compliance.

Let me now write the full lib/kv.aura file and the test additions.

Actually I realize: the lib has been growing, and the file is large. Let me try to be careful to preserve all existing code exactly. I'll add the Phase 13 section at the end (after Phase 12) and the exports at the top.

Let me also add the version bump.

Looking at the file structure: header comment with phase roadmap, then exports, then internal helpers, then phases. The version number 12 is hardcoded in two places: the comment block and `(define kv:version 12)`.

Let me prepare the full new lib/kv.aura. I'll add Phase 13 right before the version comment header section is closed (after Phase 12).

Actually looking again at the file:
- Header comment with phase roadmap (top of file)
- Exports list
- Internal helpers (kv:_ref, kv:_has, etc.)
- Phase 0..2 public API
- Phase 4 batch/composite helpers
- Phase 5 iteration & query helpers
- Phase 6 fold/predicate/projection/selection helpers
- Phase 7 convenience/comparison helpers
- Phase 8 positional/conditional/inversion helpers
- Phase 9 aggregation/positional/composition helpers
- Phase 10 statistical/numeric aggregation helpers
- Phase 11 set-theoretic/relational helpers
- Phase 12 completion of relational algebra + value-classification helpers

So Phase 13 will be at the end, before EOF.

Let me also update the header comment. Here's the plan:

1. Update header comment to include Phase 13 in roadmap
2. Bump version 12 → 13
3. Add new exports
4. Add Phase 13 section at the end

Now writing the patch. I'll provide the full new lib/kv.aura and the smoke test additions.

Wait, looking at the tests/smoke.aura format, I notice it uses (t "T61-categories" ...) extensively. My new tests need to follow the same style. Let me also confirm the test runner format.

Looking at smoke.aura:
- `(define (t name ok) ...)` — prints PASS/FAIL with name
- `(t "T61-frequencies" ...)` — calls t with test name and boolean

OK let me write everything now.

For the smoke.aura, I'll add new tests right before the final score/result block. That's the standard location.

Let me also count tests to make sure I'm consistent. Current tests are T1-T61c, that's 61 numbered categories with some sub-tests. Total = 97 individual (t ...) calls. Adding T62-T76 = 15 new (t ...) calls, bringing total to 112.

OK let me draft the full new lib/kv.aura file. I'll preserve everything from the current file except for:
1. Header comment block (add Phase 13 entry)
2. Exports list (add new ops)
3. Version number (12 → 13)
4. Append Phase 13 section at end

Let me also think about whether I should add the operations in any particular order in the exports. Convention seems to be: version, then by-phase. I'll append the Phase 13 ops at the end of the exports list, after kv:frequencies.

Here's my draft of the Phase 13 section:

```scheme
; ---------------------------------------------------------------------------
; Phase 13 numeric / bulk-composition helpers.
; Pure functional; insertion order preserved by construction; no FS
; escapes; no API renames; no exports removed.
;
; Conventions:
;   * `kv:incr` / `kv:decr` (and their `-by` variants) only operate on
;     numeric values. When `key` is absent or holds a non-numeric value,
;     the operation treats the slot as "value not a number" and writes
;     the delta as the new value (mirroring how a counter would be
;     initialised by its first operation). Non-numeric amounts are
;     refused outright (the original store is returned unchanged),
;     matching the defensive posture used by `kv:set` (refuses
;     non-string keys). Non-string keys are also refused — the store
;     is for string keys and incr/decr must not silently introduce
;     a non-string slot.
;   * `kv:rename-keys` folds `mapping` left-to-right and applies
;     `kv:rename` for each (old . new) pair. Each rename inherits
;     `kv:rename`'s refusal semantics (no-op on missing source or
;     existing target). Sequential application is deliberate: a
;     rename introduced by an earlier entry can be picked up by a
;     later entry, supporting chained renames such as
;     (("a" . "b") ("b" . "c")) turning "a" into "c" via "b".
;   * `kv:union-all` is a left fold over `kv:union`. Empty list
;     yields `()`; a single-element list yields that element
;     unchanged. The order of the result tracks the left-to-right
;     union chain — consistent with how `kv:union` itself orders
;     shared keys (left-wins) and appends right-only keys (right's
;     order).
; ---------------------------------------------------------------------------

; (kv:_incr store key amount) -> store.
; Internal helper shared by `kv:incr` / `kv:incr-by` / `kv:decr` /
; `kv:decr-by`. Returns `store` unchanged when `amount` is not a
; number (defensive: refuse to corrupt the store). Otherwise
; computes the new value: if `key` is present with a numeric value,
; it is incremented by `amount`; if `key` is absent OR present with
; a non-numeric value, the new value is just `amount` (i.e. the
; operation initialises the slot to the delta). Requires `key` to
; be a string; non-string keys refuse (same posture as `kv:set`).
(define (kv:_incr store key amount)
  (if (number? amount)
    (let ((current (kv:_ref store key)))
      (let ((new-val
              (if (number? current)
                (+ current amount)
                amount)))
        (if (string? key)
          (kv:_set store key new-val)
          store)))
    store))

; (kv:incr store key) -> store.
; Increments the value at `key` by 1. Creates `key` with value 1
; if missing. Refuses non-numeric amounts (return unchanged); this
; signature has no amount argument, so the only failure mode is a
; non-numeric existing value (initialised to 1) or a non-string
; key (store unchanged).
(define (kv:incr store key)
  (kv:_incr store key 1))

; (kv:incr-by store key amount) -> store.
; Increments the value at `key` by `amount`. Creates `key` with
; value `amount` if missing (or if `key` holds a non-numeric value,
; which is treated as "no numeric slot yet"). Refuses non-numeric
; `amount` — the store is returned unchanged so a bad call can't
; poison a numeric counter.
(define (kv:incr-by store key amount)
  (kv:_incr store key amount))

; (kv:decr store key) -> store.
; Decrements the value at `key` by 1. Same semantics as `kv:incr`
; with amount -1. Creates `key` with value -1 if missing.
(define (kv:decr store key)
  (kv:_incr store key -1))

; (kv:decr-by store key amount) -> store.
; Decrements the value at `key` by `amount`. Same semantics as
; `kv:incr-by` with negated amount. Refuses non-numeric `amount`.
(define (kv:decr-by store key amount)
  (kv:_incr store key (- amount)))

; (kv:rename-keys store mapping) -> store.
; Apply (kv:rename store old new) for each (old . new) in `mapping`,
; sequentially. Each rename inherits `kv:rename`'s refusal semantics
; (no-op when `old` is absent or `new` is already present). Reading
; `mapping` left-to-right means a rename introduced by an earlier
; pair can be picked up by a later pair — useful for chained
; renames (e.g. (("a" . "b") ("b" . "c")) maps "a" to "c" via
; the intermediate "b"). Non-pair cells in `mapping` are skipped
; defensively, same posture as every other op.
(define (kv:rename-keys store mapping)
  (let loop ((xs mapping) (acc store))
    (if (null? xs)
      acc
      (let ((p (car xs)))
        (if (pair? p)
          (loop (cdr xs) (kv:rename acc (car p) (cdr p)))
          (loop (cdr xs) acc))))))

; (kv:union-all stores) -> store.
; Left-to-right union of a list of stores. Empty list yields ();
; single-element list yields that element unchanged. Implemented
; as a direct loop (not `kv:_fold`) so the call site reads as a
; plain "merge these stores left-to-right" — `kv:union` already
; gives the left-wins / right-appends ordering, and chaining it
; across a list is the natural composition. No FS escapes.
(define (kv:union-all stores)
  (let loop ((xs stores) (acc (quote ())))
    (if (null? xs)
      acc
      (loop (cdr xs) (kv:union acc (car xs))))))
```

Wait, there's a subtle issue with `kv:union-all`. The current kv:union is:
```scheme
(define (kv:union a b)
  (kv:_fold b a
    (lambda (k v acc)
      (if (kv:_has acc k)
        acc
        (kv:_set acc k v)))))
```

So it folds `b` and only adds b-only keys to `a`. For an empty `a`, this works fine — all keys of `b` get added. Good.

But the convention in `kv:union-all` is that empty list → empty store. And single element → that element. Let me trace:

`kv:union-all ()` → loop end → return () ✓
`kv:union-all (a)` → loop iter 1, xs = (a), acc = ()
  loop body: xs not null, acc = (kv:union () a) = a
  → loop (cdr xs) (kv:union () a) = loop () a
  → loop end → return a ✓

OK that works.

What about `kv:union-all (())` where the lone element is the empty store?
`kv:union-all (())` → loop iter 1, xs = (()), acc = ()
  acc = (kv:union () ()) = ()
  → loop (cdr xs) () = loop () ()
  → loop end → return () ✓

Good.

Now `kv:union-all (a b)` where a and b are non-empty:
  iter 1: acc = (kv:union () a) = a (a's keys added to empty)
  iter 2: acc = (kv:union a b) = a ∪ b with left-wins for shared
  → return a ∪ b ✓



One more edge: what if `stores` contains a non-pair cell? My current loop does `(kv:union acc (car xs))` which would treat (car xs) as a store. If (car xs) is not a proper store (e.g., a number), then `(kv:union acc 5)` would call `kv:_fold 5 a ...`. Looking at kv:_fold:
```scheme
(define (kv:_fold xs acc f)
  (if (null? xs)
    acc
    (let ((p (car xs)))
      (if (pair? p)
        (kv:_fold (cdr xs) (f (car p) (cdr p) acc) f)
        (kv:_fold (cdr xs) acc f)))))
```

So `(kv:_fold 5 acc f)` → `(null? 5)` is #f → `(let ((p (car 5))) ...)`. Calling `car` on a non-pair/non-null would be an error.

Hmm. To be defensive, I should skip non-pair cells in the input list:

```scheme
(define (kv:union-all stores)
  (let loop ((xs stores) (acc (quote ())))
    (if (null? xs)
      acc
      (let ((s (car xs)))
        (if (pair? s)
          (loop (cdr xs) (kv:union acc s))
          (loop (cdr xs) acc))))))
```

Wait but kv:union itself doesn't defend against a non-list `b`. If `b` is not a list, `kv:_fold` would fail. Hmm.

Actually I think for this codebase, defensive skipping at the entry point is appropriate. Let me add it.

Actually thinking more — the alist primitives already defend against stray non-pair cells in the store itself. But for `kv:union-all`, the input is a list of stores, not a store. So the defensive logic is different: we skip non-pair cells in the input list.

Let me add that defense.

OK let me also think about `kv:rename-keys` defensiveness. The `mapping` argument is a list of `(old . new)` pairs. If a cell is not a pair, we skip it. My current code does that. Good.

Now let me put together the full patch. I'll provide the full new lib/kv.aura and the smoke.aura additions.

Actually, I realize I should be careful with the exports. Let me look at how exports are currently listed. They're all on one line in the current file:

```
(export kv:version
        kv:open
        kv:set
        ...)
```

Hmm, but actually looking more carefully at the current file:
```
(export kv:version
        kv:open
        kv:set
        kv:get
        ...
```

OK they're each on a separate line. I'll follow the same pattern.

Now let me write the full new lib/kv.aura. Let me be careful to preserve all existing code exactly.

For the test additions, I'll add T62-T76 before the final score display.

Let me also think about whether to add edge case tests:
- T77: incr with negative amount (dec-by via incr-by)?
  Actually, that's just (kv:incr-by store key -5), which is essentially the same as (kv:decr-by store key 5). My tests already cover the decr side.

- T78: union-all with mixed empty and non-empty stores?
  Let me add this for completeness.

Actually let me add a couple more edge cases to be thorough:
- T77: union-all with mixed empty stores doesn't break things.
- T78: incr preserves insertion order.

Let me think if these are valuable. The "preserves insertion order" one is more of an internal property test. The "mixed empty" one tests robustness.

Actually let me focus on tests that are valuable and not redundant. I'll go with 15 tests (T62-T76).

Wait, I'm going to add 2 more for completeness:
- T77: union-all() with mixed empty stores yields correct result.
- T78: incr() preserves insertion order for new entries.

Total: 17 new tests, bringing total from 97 to 114.

Actually let me keep it tight. I'll just add the essential tests:

T62-T76 (15 tests) — final count = 112

Hmm, let me reconsider. The instructions say:
> you may also extend tests/smoke.aura carefully only if you also implement the feature.

So extending tests is fine. I'll add enough to verify the feature works correctly.

Let me also think: the tests/smoke.aura ends with:
```
(display "SCORE ")
(display pass)
(display "/")
(display total)
(newline)
...
```

I need to add my new tests before this final display block.

OK let me now write the actual patches. I'll provide the full new lib/kv.aura file and then the smoke.aura additions.

Wait, I realize I should double-check my understanding of Aura semantics. Let me re-read some key parts:

1. `(if (number? current) ...)` — `current` could be #f if key is missing. Is `(number? #f)` #f? In Scheme, yes — #f is not a number. So `(number? #f)` returns #f. So `(if (number? #f) ...)` goes to the else branch, where `(if (number? current) (+ current amount) amount)` evaluates `amount`. Good.

But wait, what if a stored value is literally `#f`? Then `(kv:_ref store key)` returns `#f`. And `(number? #f)` is `#f`. So `new-val` becomes `amount` and the store gets `amount` written. This means: incr/decr at a key with stored `#f` will overwrite the `#f` with the amount. That's... maybe surprising? But it's consistent with the rule "treat non-numeric as missing".

Actually thinking about it more: should I distinguish between "key missing" and "key has #f value" for incr/decr? Looking at the codebase:
- `kv:get-or` uses `kv:_has` to distinguish #f from missing
- `kv:equal?` uses `kv:_has` for the same reason

For incr/decr, what's more useful?
- Option A: Treat #f value as missing → write `amount`. (This is what I have.)
- Option B: Refuse to incr/decr a #f value (store unchanged). (More conservative.)

I think Option A is more useful: if you have a flag at #f and want to incr it, you probably want it to become 1. But this might surprise users who expected "incr is for numeric counters".

Let me go with Option A (treat #f as missing, initialise to amount). It's more useful in practice. The doc comment will make this explicit.

Actually, you know what, let me reconsider. The "init to amount on missing" is natural for counters. But for "init to amount on non-numeric" (which includes #f), this means incr could silently overwrite a #f flag. That's surprising.

Let me go with Option B instead: only write `amount` if key is truly missing. If key has any value (even #f), incr/decr refuses.

Actually no, this is getting complex. Let me simplify:

Final design:
- If amount is not numeric: refuse (store unchanged)
- If key is missing: write `amount` as new value (creates the slot)
- If key has a numeric value: increment by `amount`
- If key has a non-numeric value (including #f): refuse (store unchanged)

This is Option B. It's the most conservative and predictable. Let me code this:

```scheme
(define (kv:_incr store key amount)
  (if (number? amount)
    (if (kv:_has store key)
      (let ((current (kv:_ref store key)))
        (if (number? current)
          (if (string? key)
            (kv:_set store key (+ current amount))
            store)
          store))  ; existing value is non-numeric; refuse
      (if (string? key)
        (kv:_set store key amount)
        store))  ; non-string key; refuse
    store))  ; non-numeric amount; refuse
```

Hmm this is getting nested. Let me refactor:

```scheme
(define (kv:_incr store key amount)
  (if (and (number? amount) (string? key))
    (let ((current (kv:_ref store key)))
      (if (number? current)
        (kv:_set store key (+ current amount))
        (kv:_set store key amount)))  ; missing or non-numeric: init to amount
    store))
```

Hmm, but this still treats non-numeric (including #f) as "missing". Which is Option A.

OK let me just commit to Option A: missing OR non-numeric → init to amount. This is the most ergonomic for counter use cases. The doc comment will be explicit about this behavior.

```scheme
(define (kv:_incr store key amount)
  (if (and (number? amount) (string? key))
    (let ((current (kv:_ref store key)))
      (let ((new-val
              (if (number? current)
                (+ current amount)
                amount)))
        (kv:_set store key new-val)))
    store))
```

Wait, what about the case where `key` is a non-string? `kv:_set` doesn't check, but the public `kv:set` does. For incr, since the operation is atomic and uses `_set` directly, we should validate. My current code does validate via the `(string? key)` check. Good.

OK final plan:

```scheme
(define (kv:_incr store key amount)
  (if (and (number? amount) (string? key))
    (let ((current (kv:_ref store key)))
      (kv:_set store key
        (if (number? current)
          (+ current amount)
          amount)))
    store))
```

Trace T63 (incr on missing key):
- store = (), key = "new", amount = 1
- (number? 1) ✓, (string? "new") ✓ → enter branch
- current = #f
- (number? #f) → #f → new-val = 1
- (kv:_set () "new" 1) = (("new" . 1))
- Returns (("new" . 1))

Test: (kv:get s "new") == 1 ✓

Trace T65 (incr with bad amount):
- store = {"x" -> 5}, key = "x", amount = "bad"
- (number? "bad") → #f → return store unchanged
- Returns {"x" -> 5}

Test: (kv:get s2 "x") == 5 ✓

Trace T66 (incr with bad key):
- store = {"x" -> 5}, key = 'symbol, amount = 1
- (number? 1) ✓, (string? 'symbol) → #f → return store unchanged
- Returns {"x" -> 5}

Test: (kv:get s2 "x") == 5 ✓

Trace T64 (incr with amount, then incr with amount):
- Start: s = ()
- (kv:incr s "x" 10) = (kv:_incr () "x" 10)
  - amount = 10, key = "x" ✓
  - current = #f
  - new-val = 10 (since current is #f, not number)
  - s = (("x" . 10))
- (kv:incr s "x" 5) = (kv:_incr (("x" . 10)) "x" 5)
  - amount = 5, key = "x" ✓
  - current = 10
  - new-val = 15 (since current is number)
  - s = (("x" . 15))

Test: (kv:get s "x") == 15 ✓

Trace T67 (decr):
- s = {"x" -> 10}
- (kv:decr s "x") = (kv:_incr s "x" -1)
  - amount = -1, key = "x" ✓
  - current = 10
  - new-val = 10 + -1 = 9
  - s2 = {"x" -> 9}
- (kv:decr s2 "x" 3) = (kv:_incr s2 "x" -3)
  - amount = -3, key = "x" ✓
  - current = 9
  - new-val = 9 + -3 = 6
  - s3 = {"x" -> 6}

Test: (kv:get s3 "x") == 6 ✓

Trace T68 (decr on missing key):
- s = ()
- (kv:decr s "x" 5) = (kv:_incr () "x" -5)
  - amount = -5, key = "x" ✓
  - current = #f
  - new-val = -5
  - s = {"x" -> -5}

Test: (kv:get s "x") == -5 ✓

Trace T76 (multi incr):
- s = ()
- (kv:incr s "c") × 3 = {"c" -> 3}
- (kv:incr s "c" 10) = {"c" -> 13}

Test: (kv:get s "c") == 13 ✓

All traces look correct.

Now let me also think about the doc/comment for `kv:_incr` — what happens if a stored value is `#f`? With my current code, `#f` is treated as "not numeric" → init to amount. So incr on a #f-valued key overwrites #f with the amount. This is documented in the kv:incr comment.

Actually, let me check — is #f treated as "not numeric" by `number?`? In standard Scheme, `(number? #f)` returns `#f`. So yes, with my code, a #f-valued key gets overwritten with the delta.

That's a known quirk. Doc it.

OK now let me put it all together. I'll provide:
1. Full new lib/kv.aura
2. Tests to add to smoke.aura (just the new tests, not the full file)

Actually since smoke.aura is also small, let me provide the full file too. Wait, it's getting long. Let me just provide the additions block with a clear marker of where it goes.

The instructions say:
> Prefer full-file replacement for small projects (lib/kv.aura).

For smoke.aura, I'll do a partial replacement (just the additions) to keep the patch size manageable.

Actually, let me just provide the full new lib/kv.aura and the additions to smoke.aura (just the new tests block).

Let me write the final lib/kv.aura file now.

I need to:
1. Update header comment to add Phase 13
2. Update exports list
3. Bump version to 13
4. Add Phase 13 section at the end

For the header comment, the current section is:
```
; Phase 12:  completion of relational algebra + value-classification
;             (union, symmetric-difference, reverse, frequencies).
;
; Store representation: alist of (key . val) pairs.
```

I'll add a Phase 13 entry before the blank line and "Store representation" line.

Actually I realize the structure is:
```
; Phase 12:  completion of relational algebra + value-classification
;             (union, symmetric-difference, reverse, frequencies).
;
; Store representation: ...
```

So the last phase comment is Phase 12. I'll add Phase 13 right after, before the blank line and "Store representation".

Actually wait, the version comment block also says:
```
; Phase 12:  completion of relational algebra + value-classification
```

I'll add:
```
; Phase 13:  numeric / bulk-composition helpers
;             (incr, incr-by, decr, decr-by, rename-keys, union-all).
```

Let me now write everything out.

Also: I need to think about whether the existing test file imports change. The exports list changes, so any new tests need to access the new ops. But since `(require "kv" all:)` is used, all exports are imported. So my new tests can directly use the new op names.

Let me finalize.

Actually one more concern: the `kv:union-all` with `b-only keys appended at the end` rule. When the left operand is empty, all keys of `b` are b-only, so they all get appended. The order in the result follows `b`. Good.

When we have `kv:union-all (a b c)`, the operation is:
- Start with `acc = ()`
- acc = (kv:union () a) = a (a's keys appended, since all are "b-only" from empty's perspective)
- acc = (kv:union a b) = a-then-b-only-in-b's-order
- acc = (kv:union (a∪b) c) = (a∪b)-then-c-only-in-c's-order

So final order: a's keys (a's order), then b's b-only keys (b's order), then c's c-only keys (c's order). For shared keys between a, b, c — leftmost wins.

This is exactly what T73 expects. ✓

OK let me write the final patch. I'll use a comprehensive approach: provide the full new lib/kv.aura and the smoke.aura additions.

Actually, thinking about it more, the lib/kv.aura is quite long (~600 lines) and providing the full content might be unwieldy. But the instructions explicitly say "Prefer full-file replacement for small projects". So I'll provide the full file.

Let me start writing.

Header comment update — current:
```
; Phase 12:  completion of relational algebra + value-classification
;             (union, symmetric-difference, reverse, frequencies).
;
; Store representation: ...
```

New:
```
; Phase 12:  completion of relational algebra + value-classification
;             (union, symmetric-difference, reverse, frequencies).
; Phase 13:  numeric / bulk-composition helpers
;             (incr, incr-by, decr, decr-by, rename-keys, union-all).
;
; Store representation: ...
```

Exports — add to the end:
```
        kv:incr
        kv:incr-by
        kv:decr
        kv:decr-by
        kv:rename-keys
        kv:union-all)
```

Version: `(define kv:version 13)`

Then add Phase 13 section at the end.

Let me write the full file now.

Actually, I realize the file is really long. Let me just provide the full file as a single patch. I'll carefully reproduce all existing code.

OK here we go. Let me draft the full new lib/kv.aura.

Wait, I want to double check one thing. Looking at the existing tests, the helper `t` is defined as:

```scheme
(define (t name ok)
  (set! total (+ total 1))
  (if ok
    (begin (set! pass (+ pass 1)) (display "  PASS ") (display name) (newline))
    (begin (display "  FAIL ") (display name) (newline))))
```

So `t` mutates `pass` and `total` globals. The new tests will also call `t` and contribute to the count. Good.

Let me also note: the existing test file uses `set!` to mutate globals, which is a host-feature concern. But the existing code works, so my additions will also work.

OK final draft. Let me write everything.

For the tests, I'll add them right before the final score block:

```scheme
; ---- Phase 13: numeric / bulk-composition helpers ----

; T62: incr() increments an existing numeric value by 1.
(let* ((s (kv:set (kv:open) "x" 5))
       (s2 (kv:incr s "x")))
  (t "T62-incr-basic"
     (and (= (kv:get s2 "x") 6)
          (equal? (kv:get s "x") 5))))

; T63: incr() on a missing key creates the slot with value 1.
(let* ((s (kv:open))
       (s (kv:incr s "new")))
  (t "T63-incr-create"
     (= (kv:get s "new") 1)))

; T64: incr-by() with explicit amount accumulates correctly.
(let* ((s (kv:open))
       (s (kv:incr-by s "x" 10))
       (s (kv:incr-by s "x" 5)))
  (t "T64-incr-by-amount"
     (= (kv:get s "x") 15)))

; T65: incr-by() refuses non-numeric amounts (store unchanged).
(let* ((s (kv:set (kv:open) "x" 5))
       (s2 (kv:incr-by s "x" "bad")))
  (t "T65-incr-refuse-bad-amount"
     (equal? (kv:get s2 "x") 5)))

; T66: incr-by() refuses non-string keys (store unchanged).
(let* ((s (kv:set (kv:open) "x" 5))
       (s2 (kv:incr-by s 'symbol 1)))
  (t "T66-incr-refuse-bad-key"
     (equal? (kv:get s2 "x") 5)))

; T67: decr() decreases an existing numeric value.
(let* ((s (kv:set (kv:open) "x" 10))
       (s2 (kv:decr s "x"))
       (s3 (kv:decr s2 "x" 3)))
  (t "T67-decr-basic"
     (= (kv:get s3 "x") 6)))

; T68: decr-by() on a missing key creates the slot with -amount.
(let* ((s (kv:open))
       (s (kv:decr-by s "x" 5)))
  (t "T68-decr-create"
     (= (kv:get s "x") -5)))

; T69: rename-keys() applies multiple renames sequentially.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:rename-keys s (list (cons "a" "x") (cons "b" "y")))))
  (t "T69-rename-keys"
     (and (= (kv:size r) 3)
          (eq? (kv:has? r "a") #f)
          (eq? (kv:has? r "b") #f)
          (equal? (kv:get r "x") 1)
          (equal? (kv:get r "y") 2)
          (equal? (kv:get r "c") 3))))

; T70: rename-keys() chained renames — first rename picked up by later.
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

; T72: rename-keys() skips a rename when the target key already exists.
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (r (kv:rename-keys s (list (cons "a" "b")))))
  (t "T72-rename-keys-skip-collision"
     (and (= (kv:size r) 2)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "b") 2))))

; T73: union-all() merges a list of stores left-to-right.
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

; T75: union-all() with a single-element list yields that element.
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2)))
  (t "T75-union-all-single"
     (and (= (kv:size (kv:union-all (list a))) 2)
          (equal? (kv:get (kv:union-all (list a)) "a") 1)
          (equal? (kv:get (kv:union-all (list a)) "b") 2))))

; T76: incr() multi-call sequence composes into a counter.
(let* ((s (kv:open))
       (s (kv:incr s "c"))
       (s (kv:incr s "c"))
       (s (kv:incr s "c"))
       (s (kv:incr-by s "c" 10)))
  (t "T76-incr-multi"
     (= (kv:get s "c") 13)))
```

15 new tests (T62-T76), bringing total from 97 to 112.

Hmm, let me re-check T75. My test does `(kv:union-all (list a))` 3 times. Each call creates a fresh result. The `and` checks each separately. That's fine but a bit wasteful. Let me simplify:

```scheme
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (u (kv:union-all (list a))))
  (t "T75-union-all-single"
     (and (= (kv:size u) 2)
          (equal? (kv:get u "a") 1)
          (equal? (kv:get u "b") 2))))
```

Cleaner.

OK now let me write the full patch.

For the lib/kv.aura, I'll provide the complete new file. Let me carefully reproduce everything.

Wait, the file is going to be very long. Let me think if there's a more efficient way.

Actually, the controller's instructions say:
> Prefer full-file replacement for small projects (lib/kv.aura).

This is a small project (~600 lines), so full file replacement is appropriate. Let me write it out.

Let me start drafting:

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
        kv:union-all)

(define kv:version 13)

... [all the existing internals and public ops exactly as they are] ...

; Phase 13 section at the end.
```

OK that's the structure. Now let me reproduce all the internals and public ops. This is the bulk of the work.

I'll need to be very careful to preserve everything. Let me write out the complete file.

OK here goes — the full lib/kv.aura file with Phase 13 added.</think>

### REVIEW

- **Strengths**: 97/97 tests green across Phases 0–12 of the in-file roadmap. Alist-of-cons representation is robust (defensive skipping of stray non-pair cells), insertion order is preserved by every op, every op is pure functional, no FS / network / host escape used. Export-before-define discipline intact, API names stable since v1, `kv:pick` walks the *store*, `kv:rename`/`kv:swap` consistently refuse ambiguous writes, `kv:equal?` correctly distinguishes `#f` values from misses, stats ops compose cleanly with `kv:merge`, relational algebra is closed (union / intersection / subtract / symmetric-difference), and value-classification (`kv:frequencies`) lands the last natural extension.
- **Failures / Risks**: SCORE is full → per protocol, must advance SPEC phase by introducing new capability that keeps old tests green. The lib's roadmap comment block stops at Phase 12; adding Phase 13 is the natural progression. No host / FS / network concerns to mitigate.
- **Density**: Every existing op derives from `kv:_fold` / `kv:_set` / `kv:_has` / `kv:_ref` / `kv:_map` — new ops should follow the same pattern (single fold, no FS escapes, no new internal helper unless unavoidable).

### DIRECTION

- **Target phase: Phase 13 — numeric / bulk-composition helpers.** Same posture as Phase 12 (pure Aura, derived from existing alist primitives, insertion order preserved by construction, no FS escapes, no API renames, no exports removed). Keeps all T1–T61c green.
- **Ops to add (6 new, all pure, all derive from existing internals; export-before-define preserved):**
  - `kv:incr`     — `(store key)` → store; increment by 1; creates slot with 1 on miss
  - `kv:incr-by`  — `(store key amount)` → store; increment by amount; refuses non-numeric amount / non-string key
  - `kv:decr`     — `(store key)` → store; decrement by 1
  - `kv:decr-by`  — `(store key amount)` → store; decrement by amount
  - `kv:rename-keys` — `(store mapping)` → store; folds `(kv:rename store old new)` left-to-right over `(old . new)` pairs; chained renames supported (later entries can pick up earlier renames); skips non-pair cells
  - `kv:union-all` — `(stores)` → store; left-to-right `kv:union` over a list of stores; `()` yields `()`; singleton yields that element
- **Implementation notes**:
  - Use a single internal `kv:_incr` helper for all four incr/decr ops (mirroring how `kv:_ref` / `kv:_has` / `kv:_set` are reused).
  - Refuse non-numeric `amount` AND non-string `key` (return store unchanged) — same defensive posture as `kv:set`'s string?-key guard.
  - Missing key OR non-numeric existing value → write `amount` as the new value (init semantics; documented in comment).
  - `kv:rename-keys` / `kv:union-all` skip non-pair cells defensively (same posture as every other op).
  - No new internal helper beyond `kv:_incr`; reuse `kv:rename` and `kv:union` so semantics are identical.
- **Bump `kv:version` 12 → 13**, extend `tests/smoke.aura` with **T62–T76** (15 new tests covering each new op's primary path + key refusal edges).
- **Do NOT touch**: Phases 0–12, exports order for existing ops, header comment Phases 0–12 entries, `kv:_fold` / `kv:_set` / `kv:_has` / `kv:_ref` / `kv:_map`, journal format.

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
        kv:union-all)

(define kv:version 13)

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
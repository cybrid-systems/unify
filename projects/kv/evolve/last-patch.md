<think>The user is asking me to review the project state, set direction, and emit a patch. Let me analyze the current state:

1. The project is at generation 13, baseline SCORE 112/112, full green.
2. Phases 0-12 are complete according to the roadmap.
3. The last patch (Phase 13) added: incr, incr-by, decr, decr-by, rename-keys, union-all.
4. The test suite has 112 tests, all passing.

Looking at the in-file roadmap, the phases 0-13 are all implemented. The SPEC only requires Phase ≥ 3 with all T1–T12 green, multi-generation history in evolve/journal.jsonl. We're way past that.

Since we're at full score, the controller instructions say:
"If SCORE is already full, advance SPEC phase (new capability) via code that still keeps old tests green; you may also extend tests/smoke.aura carefully only if you also implement the feature."

So I should advance to a new phase. The current "Phase 13" was the last one in the lib comment roadmap. Let me think about what to add next.

Some natural extensions to a KV store:
1. **Iteration / cursor helpers**: a way to step through entries safely
2. **Persistent storage** (but the SPEC says "meter FS as escape")
3. **Type-safe accessors**: typed get/set helpers (number vs string)
4. **Composite helpers**: 
   - `kv:default` / `kv:default-by` — like get-or but with a thunk
   - `kv:toggle` — flip a boolean key
   - `kv:update-keys` — transform keys
   - `kv:where` — filter with predicate returning store (alias of filter)
5. **Sorting helpers**: sort-by, sort-keys
6. **Numeric boundary helpers**: clamp, between?
7. **Set-style helpers**: xnor (joint presence), difference-list
8. **Grouping helpers**: group-by
9. **Path / nested access**: get-path, set-path, del-path (but adds complexity)

Let me think about what's "natural" and fits the existing pattern of small, pure, composable helpers.

**Phase 14 ideas** — pure functional bulk/iteration/transformation helpers:

- `kv:update-keys` — `(store proc)` → new store with `(proc k)` applied to each key. Keys can collide — first-wins (consistent with `kv:invert`'s first-occurrence semantics).
- `kv:toggle` — `(store key)` → flip boolean (treat as 0/1, since Aura doesn't have a native bool). Sets key to 1 on miss, else flips between 0 and 1.
- `kv:merge-with` — `(store a b proc)` → merge where shared keys go through `proc(a-val, b-val)`. Adds arithmetic combine semantics.
- `kv:from-list` — `(kv:zip keys vals)` already exists. But a `kv:from-alist` could be useful.
- `kv:range-keys` — `(store start end)` — get sub-store by key range (lexicographic on string keys, etc.). Maybe overkill.
- `kv:head-map` / `kv:tail-map` — like map-values but conditional
- `kv:contains-value?` — `(store val)` — does the store contain value `val`?
- `kv:contains-values?` — `(store vals)` — does it contain all vals?

Let me pick a focused, coherent set of 4-5 helpers that fit the existing patterns:

**Phase 14: transformation / containment / composition helpers**

1. `kv:update-keys` — `(store proc)` → new store; `(proc k)` returns new key. First-occurrence wins on collision.
3. `kv:merge-with` — `(store a b proc)` → merge; shared keys: `proc(a-v, b-v)`.
4. `kv:contains-value?` — `(store val)` → `#t` if any entry has `val` as its value.
5. `kv:diff-by` — `(a b proc)` → diff using `proc` as equality comparator (extensibility hook for `kv:diff`).

Actually let me look more carefully. I want to keep the patch focused and small. Let me pick a tight, clean Phase 14:

**Phase 14: bulk-transformation helpers**

1. `kv:update-keys` — `(store proc)` → new store with `(proc k)` as new keys
2. `kv:contains-value?` — `(store val)` → `#t` / `#f`
3. `kv:merge-with` — `(a b proc)` → merge with combiner for shared keys
4. `kv:rename-all` — bulk rename using a function

Actually, let me think about what's missing and would be genuinely useful:

- `kv:contains-value?` is very natural — complement to `kv:has?`
- `kv:update-keys` is natural — complement to `kv:map-values`
- `kv:merge-with` is natural — generalization of `kv:merge`

That's a clean Phase 14 trio. Let me also add:
- `kv:zipmap` (alias of zip?) — maybe redundant
- `kv:from-alist` — `(kv:zip keys vals)` already covers this

Let me go with:
1. `kv:update-keys`
2. `kv:contains-value?`
3. `kv:merge-with`
4. `kv:count-values` — count occurrences of a value (uses kv:frequencies internally? Or just a count for one value)

Actually, `kv:contains-value?` is just `kv:any?` with `(lambda (k v) (equal? v val))`. So it's redundant. Let me drop that.

Final Phase 14:
1. `kv:update-keys` — `(store proc)` → new store with `(proc k)` as new keys
2. `kv:merge-with` — `(a b proc)` → merge with combiner for shared keys
3. `kv:head` — `(store)` → just the first pair's value (`#f` on empty)? Or take a different name...
4. `kv:tail` — last pair's value? 

Hmm, those aren't quite right. Let me reconsider.

Actually I think I'll keep this simple and focused. Let me add these for Phase 14:

1. `kv:update-keys` — `(store proc)` → new store; keys go through `(proc k)`. First-occurrence wins on collisions.
2. `kv:merge-with` — `(a b proc)` → merge; shared keys: `(proc a-v b-v)`. Right-only keys appended at end.
3. `kv:contains-value?` — wait, this is just `kv:any?` so I'll skip it.
4. `kv:count-value` — `(store val)` → number of entries with value `val` (uses `kv:count` internally). Useful shorthand.
5. `kv:filter-values` — `(store proc)` → sub-store where `(proc v)` is `#t`. Complements `kv:filter` which takes `(proc k v)`.

That's a clean 4-op Phase 14:
- `kv:update-keys` — bulk key transformation
- `kv:merge-with` — merge with combiner
- `kv:count-value` — value-presence count
- `kv:filter-values` — value-only filter

Let me write the code.

For `kv:update-keys`:
```aura
; (kv:update-keys store proc) -> store
; Apply (proc k) to each key. Collisions resolve to the first occurrence
; (consistent with kv:invert's first-occurrence semantics). Keys are
; passed through the existing string?-key guard implicitly because
; kv:_set already validates.
; Actually no, kv:_set doesn't validate; kv:set does. We need to use
; kv:set to get the string validation, but kv:set wraps in kv:_set only
; if key is string? — else returns store unchanged. That means a proc
; that produces a non-string key would silently drop that entry. 
; Hmm. Let me think...
```

Actually, the simplest correct approach: build new entries, validate at end. But that's complex. Let me just do the straightforward version using kv:_set directly (no string validation since update-keys may legitimately produce any key, just like invert). I'll note that in the comment.

```aura
(define (kv:update-keys store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (let ((new-k (proc k)))
        (if (kv:_has acc new-k)
          acc
          (kv:_set acc new-k v))))))
```

Wait, but this skips non-pair cells. And uses kv:_set which doesn't validate strings. Same posture as invert. Good.

For `kv:merge-with`:
```aura
(define (kv:merge-with a b proc)
  ; First, build merged store where shared keys get proc(a-v, b-v)
  ; and b-only keys are appended at the end.
  (let* ((merged
           (kv:_fold a (quote ())
             (lambda (k va acc)
               (if (kv:_has b k)
                 (kv:_set acc k (proc va (kv:_ref b k)))
                 (kv:_set acc k va)))))
         (b-only
           (kv:_fold b (quote ())
             (lambda (k v acc)
               (if (kv:_has a k)
                 acc
                 (kv:_set acc k v))))))
    ; Now append b-only in b's order
    ; Wait, this won't preserve order properly because we built acc in a's order
    ; then added b-only at the end. But we want b-only to be appended
    ; to merged (which already has a's order). That works!
    ; Actually wait, "appended" in our model means kv:_set on missing key,
    ; which appends. So merging merged + b-only gives us a's order for
    ; shared keys, then b-only in b's order. That's exactly what we want.
    (kv:_fold b-only merged
      (lambda (k v acc) (kv:_set acc k v)))))
```

Hmm, simpler:
```aura
(define (kv:merge-with a b proc)
  (kv:_fold b (kv:_fold a (quote ())
              (lambda (k va acc)
                (if (kv:_has b k)
                  (kv:_set acc k (proc va (kv:_ref b k)))
                  (kv:_set acc k va))))
    (lambda (k vb acc)
      (if (kv:_has a k)
        acc
        (kv:_set acc k vb)))))
```

Wait that's also fine. Let me think more carefully. We want:
- shared keys: `proc(a-v, b-v)`, in a's position
- a-only: a's value, in a's position
- b-only: b's value, appended at end in b's order

Build base from `a`:
- For each (k, va) in a:
  - if k in b: set k -> proc(va, b[k])
  - else: set k -> va

Then fold over `b` adding b-only at end:
- For each (k, vb) in b:
  - if k in a: skip (already handled)
  - else: set k -> vb (which appends)

```aura
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
```

That's clean.

For `kv:count-value`:
```aura
(define (kv:count-value store val)
  (kv:count store (lambda (k v) (equal? v val))))
```

For `kv:filter-values`:
```aura
(define (kv:filter-values store proc)
  (kv:_fold store (quote ())
    (lambda (k v acc)
      (if (proc v) (kv:_set acc k v) acc))))
```

Now I need tests too. Let me add T77-T80.

T77: `kv:update-keys` transforms keys
```aura
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (r (kv:update-keys s (lambda (k) (string-append k "!")))))
  (t "T77-update-keys"
     (and (= (kv:size r) 2)
          (eq? (kv:has? r "a") #f)
          (eq? (kv:has? r "b") #f)
          (equal? (kv:get r "a!") 1)
          (equal? (kv:get r "b!") 2))))
```

T77b: `kv:update-keys` first-occurrence wins on collision
```aura
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:update-keys s (lambda (k) "x"))))
  (t "T77b-update-keys-collision"
     (and (= (kv:size r) 1)
          (equal? (kv:get r "x") 1))))
```

T78: `kv:merge-with` uses combiner on shared keys
```aura
(let* ((a (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (b (kv:set (kv:set (kv:set (kv:open) "b" 20) "c" 30) "d" 4))
       (r (kv:merge-with a b (lambda (x y) (+ x y)))))
  (t "T78-merge-with"
     (and (= (kv:size r) 4)
          (equal? (kv:get r "a") 1)
          (equal? (kv:get r "b") 22)
          (equal? (kv:get r "c") 33)
          (equal? (kv:get r "d") 4))))
```

T78b: `kv:merge-with` preserves order (a-then-b-only)
```aura
(let* ((a (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (b (kv:set (kv:set (kv:open) "c" 3) "d" 4))
       (r (kv:merge-with a b (lambda (x y) (+ x y))))
       (rk (kv:keys r)))
  (t "T78b-merge-with-order"
     (and (equal? (car rk) "a")
          (equal? (car (cdr rk)) "b")
          (equal? (car (cdr (cdr rk))) "c")
          (equal? (car (cdr (cdr (cdr rk)))) "d"))))
```

T79: `kv:count-value` counts occurrences of a value
```aura
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 1) "d" 3) "e" 1)))
  (t "T79-count-value"
     (and (= (kv:count-value s 1) 3)
          (= (kv:count-value s 2) 1)
          (= (kv:count-value s 99) 0)
          (= (kv:count-value (kv:open) 1) 0))))
```

T80: `kv:filter-values` keeps entries whose value passes the predicate
```aura
(let* ((s (kv:set (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3) "d" 4))
       (r (kv:filter-values s (lambda (v) (> v 2)))))
  (t "T80-filter-values"
     (and (= (kv:size r) 2)
          (equal? (kv:get r "c") 3)
          (equal? (kv:get r "d") 4)
          (eq? (kv:get r "a") #f)
          (eq? (kv:get r "b") #f))))
```

Let me also bump `kv:version` to 14 and update the in-file comment roadmap.

Now let me write the full patch.

Actually wait — I need to check whether Aura has `string-append`. Let me search the existing code... I don't see it used. But it's likely a standard Aura builtin. If not, I can use a different example. Let me use something safer like prefixing with "k:" using cons or string concatenation that might already be there.

Hmm, looking at the existing code, I see `kv:zip` uses lists of strings directly. Let me check if `string-append` is mentioned anywhere... No. To be safe, let me use a function that doesn't need string manipulation. I'll use `(lambda (k) (cons 'k k))` or similar to generate unique keys.

Actually let me just use a simpler lambda that maps keys to symbols or to a fixed value. Like:
```aura
(kv:update-keys s (lambda (k) (cons 'k k)))
```

Then test:
```aura
(kv:has? r (cons 'k "a"))
```

Hmm, that gets messy. Let me try with a simpler example. I'll use a function that prepends a fixed prefix character:

Actually, the cleanest approach: use kv:update-keys to map keys to indices (using their position). But we don't have positions. 

Let me just use the `string-append` and trust that it's available. If not, I can adjust.

Actually, looking at typical Scheme/R7RS-small docs, `string-append` is a standard builtin. Aura is based on R5RS/R7RS, so it should have it.

Let me finalize the patch now.

I need to:
1. Update the in-file roadmap comment (add Phase 14)
2. Add Phase 14 ops to export list
3. Add Phase 14 implementations
4. Add Phase 14 tests
5. Bump `kv:version` to 14

Let me write it all out.

Wait — let me reconsider what to add. Let me think about the journal "direction" field the actuator will read. Let me write a clear direction.

OK, I'm going with:
- Phase 14: bulk-transformation / merging / counting / value-only filter helpers

Ops (4):
1. `kv:update-keys` — `(store proc)` → store; keys transformed by `proc`
2. `kv:merge-with` — `(a b proc)` → merge; shared keys combined via `proc(a-v, b-v)`
3. `kv:count-value` — `(store val)` → count of entries whose value equals `val`
4. `kv:filter-values` — `(store proc)` → sub-store of entries with `(proc v) = #t`

Tests T77-T80 (and maybe T77b, T78b, T80b variants).

Let me write out the full patches now.

Actually, one more consideration: the patch should be a "multi-file patch (usually lib/kv.aura, sometimes tests only if SPEC-aligned)". Since we're adding new functionality, I'll patch lib/kv.aura + tests/smoke.aura. Both.

But the output format says "FILE relative/path" for the patch. So I can include multiple files. Let me do that.

Let me now write the complete lib/kv.aura patch and the tests/smoke.aura patch.

Actually wait — re-reading the controller instructions:
"PATCH
FILE relative/path
```
full file contents
```"

So the format is one file block per file. I should output two file blocks.

Let me start writing.

First, lib/kv.aura. The structure I'll add is:

1. Update header comment roadmap (add Phase 14 line)
2. Add to exports list: `kv:update-keys`, `kv:merge-with`, `kv:count-value`, `kv:filter-values`
3. Bump `kv:version` to `14`
4. Add Phase 14 implementation block at the end

For the test file, add new tests after T76.

Let me write out the full lib/kv.aura. It's about 600 lines currently. I'll do the full file replacement since the SPEC says "Prefer full-file replacement for small projects".

Actually wait — let me re-read the file. I see the full file is given in the controller input. Let me write the modified version.

Here's the plan:
- Change `(define kv:version 13)` to `(define kv:version 14)`
- Add 4 names to the export list
- Add a Phase 14 section at the bottom with 4 ops

Let me write it.

For the Phase 14 section:

```
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
;     the new keys are caller-supplied projections, not fresh kv:set
;     writes — same posture as `kv:invert`.
;   * `kv:merge-with` generalises `kv:merge` by letting the caller pick
;     how shared-key values combine. `a's` insertion order is preserved
;     for shared keys (with `(proc a-v b-v)` as the new value); `b`-only
;     keys are appended at the end in `b`'s iteration order. Built as
;     a fold over `a` to compute the shared-key set, then a fold over
;     `b` to append b-only keys — no intermediate alist materialised.
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
; Apply `(proc k)` to each key. Folds `store` left-to-right in insertion
; order; for each (k, v), computes (new-k = (proc k)) and (if new-k is
; not already in the accumulator) writes (new-k -> v) into acc. On a
; collision (two source keys mapping to the same new-k) the FIRST
; occurrence wins and later duplicates are dropped — consistent with
; `kv:invert`'s first-occurrence semantics. Insertion order of the
; result tracks the source's order. Uses `kv:_set` directly (no
; string?-key guard) because the new keys are caller-supplied
; projections, not fresh `kv:set` writes — same posture as `kv:invert`.
; Non-pair cells in `store` are skipped defensively (via `_fold`).
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
; `a`'s value as-is. For each `b`-only key, writes `b`'s value at the
; end in `b`'s iteration order. Built as a fold over `a` to compute
; the shared-key set (with combiner applied), then a fold over `b`
; that appends the b-only keys — `kv:_set`'s "append on miss"
; behaviour does the rest. The insertion order of `a` is preserved
; for shared keys; b-only keys are appended at the end in b's order.
; For disjoint operands, no key is shared, so `proc` is never called
; and the result is identical to `kv:union`.
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
; matches `#f` (equal? agrees on `#f`); a missing entry never matches
; anything.
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
```

Now for tests, I'll add:

```
; ---- Phase 14: bulk-transformation / merging / counting / value-only filter ----

; T77: update-keys() transforms keys via caller-supplied proc.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:update-keys s (lambda (k) (string-append k "!"))))
       (rk (kv:keys r)))
  (t "T77-update-keys"
     (and (= (kv:size r) 3)
          (eq? (kv:has? r "a") #f)
          (eq? (kv:has? r "b") #f)
          (eq? (kv:has? r "c") #f)
          (equal? (kv:get r "a!") 1)
          (equal? (kv:get r "b!") 2)
          (equal? (kv:get r "c!") 3)
          (equal? (car rk) "a!")
          (equal? (car (cdr rk)) "b!")
          (equal? (car (cdr (cdr rk))) "c!"))))

; T77b: update-keys() on a collision: first-occurrence wins.
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:update-keys s (lambda (k) "x"))))
  (t "T77b-update-keys-collision"
     (and (= (kv:size r) 1)
          (equal? (kv:get r "x") 1))))

; T77c: update-keys() on an empty store is empty.
(t "T77c-update-keys-empty"
   (= (kv:size (kv:update-keys (kv:open) (lambda (k) k))) 0))

; T78: merge-with() combines shared keys via caller-supplied proc.
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

; T78b: merge-with() with disjoint operands equals union; combiner not called.
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

; T80: filter-values() keeps entries whose value passes the predicate.
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
```

Now I need to write out the full lib/kv.aura. Since it's quite long, let me be careful. The diff is:
1. Update comment header (add Phase 14 line)
2. Add 4 names to export list (after kv:union-all)
3. Bump version 13 → 14
4. Add Phase 14 implementation block at the end

Let me write the full file.

I'll prepare the full file contents now.

Actually, given the file is already very long, and the SPEC says "Prefer full-file replacement for small projects", and this is a small project — but the file is already ~700 lines. Let me think if there's a better way to do partial patches.

The output format says "FILE relative/path" then "```full file contents```". So I'll provide the full file.

Let me write it out carefully.

Actually, I'm going to be more careful. The full file is about 660+ lines based on the input. Let me carefully reproduce it with my modifications.

Let me go through and modify:

Line 1-13: Comment header. Add Phase 14 line.
Line 16-69: Export list. Add 4 new exports after `kv:union-all`.
Line 71: `kv:version` 13 → 14.
Lines 73-end: Internal helpers, then phases. Add Phase 14 at end.

Let me write the patch.

Wait, I realize the patch directive says "full file contents". Let me be very careful to reproduce the entire file accurately. Looking at the input, I have the full file. Let me just make targeted changes and write the full result.

Let me identify the exact changes:

1. Comment header (top of file): add Phase 14 line after Phase 13
2. Export list: add `kv:update-keys`, `kv:merge-with`, `kv:count-value`, `kv:filter-values` after `kv:union-all`
3. `(define kv:version 13)` → `(define kv:version 14)`
4. Add Phase 14 section at the end (before the EOF)

For test file:
1. Add Phase 14 tests after T76

Let me write these out.

For the export list, the current order is:
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
        kv:copy
        ...
        kv:union-all)
```

I need to add the 4 new ones. Let me put them after `kv:union-all` in the export list.

OK let me write the full patches now. I'll do this carefully.

Actually, on reflection — let me think about whether I should be so ambitious. The test count is already 112. Adding 8 more tests would bring it to 120. That's good.

Let me also reconsider whether string-append is supported. Looking at the existing code... I don't see any string operations. But it's a standard Scheme/R7RS builtin so it should be fine. If it's not, the test would fail and the patch would be rejected. Let me trust it.

Actually, let me think about a simpler test for update-keys that doesn't depend on string-append. I could use a function that returns a fixed string for any key:

```aura
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:update-keys s (lambda (k) "k")))
       (rk (kv:keys r)))
  (t "T77-update-keys"
     (and (= (kv:size r) 1)
          (eq? (kv:has? r "a") #f)
          (eq? (kv:has? r "b") #f)
          (eq? (kv:has? r "c") #f)
          (equal? (kv:get r "k") 1))))
```

Hmm, but this only tests the collision case (all keys → "k"). Not very interesting.

Better: test with prefix that doesn't cause collisions:

Actually, let me use a function that prefixes keys with a marker character. But I need string concatenation.

Alternative: I can build the new key with cons/list operations, but then has? wouldn't work the same.

Let me try: use `string-append`. It's a standard Scheme builtin. Aura should support it.

Or even simpler: I can use kv:update-keys with a function that returns a literal that's a fixed key for a particular input. Like:

```aura
(let* ((s (kv:set (kv:set (kv:open) "a" 1) "b" 2))
       (r (kv:update-keys s (lambda (k) (if (equal? k "a") "x" "y")))))
  (t "T77-update-keys"
     (and (= (kv:size r) 2)
          (eq? (kv:has? r "a") #f)
          (eq? (kv:has? r "b") #f)
          (equal? (kv:get r "x") 1)
          (equal? (kv:get r "y") 2))))
```

This works without string-append. Let me use this.

OK, let me finalize the patch.

For T77 update-keys, I'll use the if-equal lambda approach to avoid relying on string-append.

Now let me also reconsider: my `kv:update-keys` only handles non-collision case. The collision case is the first-wins behavior, which I have a test for (T77b).

But wait, T77 doesn't test "first-occurrence order preserved" because each input maps to a different output key. Let me add a check:

```aura
(let* ((s (kv:set (kv:set (kv:set (kv:open) "a" 1) "b" 2) "c" 3))
       (r (kv:update-keys s (lambda (k) (if (equal? k "a") "x"
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
```

That tests both "keys transformed" and "insertion order preserved".

Alright, I think I have a solid plan. Let me write the full patches.

For the lib/kv.aura, the full file is large but manageable. Let me reproduce it carefully.

Let me also check if I need to update the in-file roadmap comment at the top. Yes, I should add a line for Phase 14.

Original comment header:
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
```

I'll add:
```
; Phase 14:  bulk-transformation / merging / counting / value-only filter
;             (update-keys, merge-with, count-value, filter-values).
```

OK let me write out the full patches now. I'll be careful to keep everything else identical.

Looking at the export list:
```
(export kv:version
        kv:open
        ...
        kv:union-all)
```

I'll add the 4 new ones after `kv:union-all`:
```
(export kv:version
        ...
        kv:union-all
        kv:update-keys
        kv:merge-with
        kv:count-value
        kv:filter-values)
```

And bump version 13 → 14.

Let me write the full files now.

Hmm wait — I realize this is a lot of content. Let me try a cleaner approach. Since the file is large, and I have it in the controller input, let me write a full reproduction with modifications.

Actually, I'll just carefully reproduce the full file with my edits. Let me do that.

OK here goes. I'll structure my response now.</think>

### REVIEW

**Strengths**
- 112/112 tests green across Phases 0–13 of the in-file roadmap. Pure Aura alist-of-cons store, defensive skipping of stray non-pair cells, insertion order preserved by every op, no FS / network / host escape used anywhere. Export-before-define discipline is intact, API names stable since v1, every refactor (pick order, rename ambiguity, swap refusal, `kv:equal?` distinguishing `#f` from miss, init-semantics counters) has held up across generations.
- The journal shows 13 successful generations with monotonically improving score; denseness posture is solid — the only helper added that wasn't strictly required was the `kv:_incr` internal for counters, every other Phase 13 op is a thin projection over the existing primitives.
- Phase 13 (incr/incr-by/decr/decr-by/rename-keys/union-all) closed out numeric counters and bulk-composition cleanly. `kv:_bump` (Phase 12) and `kv:_incr` (Phase 13) are the only internal helpers added since Phase 8 — the rest is straight folds over `_fold`/`_set`.

**Failures / Risks**
- The store still has gaps in the **bulk-transformation** axis: there's `kv:map-values` for value projection but no `kv:update-keys` for key projection; `kv:merge` exists but is a fixed right-biased union — no `kv:merge-with` for caller-supplied combiners; no thin wrapper that turns "count entries where `v == X`" into a one-liner; and no value-only projection of `kv:filter`. None of these is a SPEC requirement, but they round out the Phase 5–13 surface and keep the "every op derives from the same alist primitives" story tight.
- All 112 tests currently green, so any patch MUST keep T1–T76 untouched.

### DIRECTION

**Target phase: Phase 14 — bulk-transformation / merging / counting / value-only filter helpers.** Same posture as Phase 13 (pure Aura, derived from existing `_fold`/`_set`/`_has`/`_ref` primitives and the Phase 6 `kv:count`, no new internal helper beyond re-using what's already there, no FS escapes, no API renames, no exports removed). Keeps T1–T76 green, extends the smoke suite to T80 / T80b with 8 new tests (target 120/120).

**Ops to add (4 new, all pure, all derive from existing internals; export-before-define preserved):**
- `kv:update-keys` — `(store proc)` → new store with `(proc k)` as the new keys. First-occurrence wins on collisions (consistent with `kv:invert`'s first-occurrence semantics). Uses `kv:_set` directly (no string?-key guard, like `kv:invert` — caller projections aren't fresh `kv:set` writes).
- `kv:merge-with` — `(a b proc)` → merge where shared keys go through `(proc a-v b-v)`. A's order preserved for shared keys; b-only keys appended at the end in b's order. Built as a fold over `a` then a fold over `b` — no intermediate alist materialised. For disjoint operands, `proc` is never called (parity with `kv:union` semantics minus the right-wins override).
- `kv:count-value` — `(store val)` → number of entries whose value is structurally equal to `val`. Thin wrapper over `kv:count`; mirrors `kv:has?` on the value axis.
- `kv:filter-values` — `(store proc)` → sub-store of entries for which `(proc v)` is `#t`. Complements `kv:filter (proc k v)` by dropping the key argument when the caller only cares about values.

Bump `kv:version` to `14`. Extend `tests/smoke.aura` with T77–T80b. **Do not touch any existing op or existing test.**

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
        kv:filter-values)

(define kv:version 14)

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
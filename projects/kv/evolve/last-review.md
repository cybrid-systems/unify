# Controller REVIEW

- **Strengths**: Phases 0–6 of the in-file roadmap are implemented; alist-of-cons representation is robust (defensive against stray non-pair cells) and all iterators preserve insertion order. Pure Aura, no FS escapes, export-before-define discipline intact, version bumped to 4.
- **Failure**: **T27-pick FAIL** — `kv:pick` iterates over the *requested-keys list* and `kv:_set`s each survivor into `acc`, so the resulting order is the keys-list order, not the store's insertion order. The test (and the doc comment I wrote myself) explicitly require store-order: `pk = ("a" "c")` not `("c" "a")`. This is a **semantic bug**, not a host risk.
- **Other**: All 32 other tests pass — no regressions in `omit`/`map-values`/`filter`/`merge`. The `kv:version` comment block still says "Phase 6" but `kv:version` is `4`; will nudge to `5` for traceability.

# DIRECTION

- **Target phase**: fix the `kv:pick` ordering bug to land 33/33. This is a same-phase bugfix (still Phase 6), no SPEC phase advancement. Don't touch any other op — they're individually covered by tests.
- **Ops to touch**:
  - Add internal `kv:_mem` helper (membership test, not exported).
  - Rewrite `kv:pick` to walk **the store** (via `kv:_fold`) and keep only entries whose key is in the requested-keys list — this guarantees store-insertion-order among survivors, matching the doc comment and T27's expectation.
  - Bump `kv:version` `4 → 5`.
  - Add two tiny edge tests T27b/T27c in `tests/smoke.aura` (empty key list; all-missing key list) so this regression class is locked down.
- **Do NOT touch**: `kv:_set`, `kv:_fold`, `kv:_map`, `kv:_del`, `kv:mset`, `kv:merge`, `kv:update`, `kv:filter`, `kv:find`, `kv:values`, `kv:entries`, `kv:reduce`, `kv:any?`, `kv:every?`, `kv:omit`, `kv:map-values`, `kv:keys`, `kv:for-each`. All verified green.

# Controller REVIEW

- All 46/46 tests are green; Phases 0–7 of the in-file roadmap (open/set/get → equal?) are locked in.
- Pure Aura throughout, alist-of-cons representation with defensive skipping of non-pair cells; insertion order preserved by every op; no FS / no network / no host escape.
- Export-before-define discipline intact; API names stable since v1; `kv:equal?` correctly distinguishes `#f` values from misses; `kv:pick` walks the *store* (insertion-order by construction); `kv:rename` is a true no-op on collision.
- Failure / risk: nothing failing — but the project has now consumed every phase enumerated in the in-file roadmap (0..7). SPEC's explicit roadmap only goes to Phase 4 (batch helpers), so the controller is well past it. The next move is **advance SPEC further** by adding a coherent new capability that is still pure Aura, still derived from existing internals, and still keeps T1–T34b green.

# DIRECTION

- **Target phase: Phase 8 — positional / conditional / inversion helpers.** Same denseness posture (pure Aura, derived from existing `_fold`/`_set`/`_has` primitives), keeps T1–T34b green, advances SPEC beyond Phase 7.
- **Ops to add (8 new, all pure, all derive from existing primitives; export-before-define preserved; no FS escapes):**
  - `kv:first`    — first `(k . v)`, `#f` on empty
  - `kv:last`     — last `(k . v)`, `#f` on empty
  - `kv:rest`     — store minus first entry; `()` on empty
  - `kv:butlast`  — store minus last entry; `()` on empty
  - `kv:take`     — first `n` entries; `n>=size` → whole store
  - `kv:drop`     — drop first `n` entries; `n>=size` → empty
  - `kv:invert`   — swap keys/values; first-wins on value collision
  - `kv:set-if-absent` — only sets when key missing
- Bump `kv:version` 6 → 7.
- **What NOT to touch**: existing primitives, existing tests, the kv:_set/kv:_has string-key discipline on `kv:set` (keep `kv:set-if-absent` consistent). No FS / no host escape. No API renames.
- Extend `tests/smoke.aura` with **T35–T42** (11 new assertions covering first/last/rest/butlast edge cases, take/drop boundaries, invert order + collision + empty, set-if-absent hit + miss).

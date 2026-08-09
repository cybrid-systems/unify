# Controller REVIEW

- All 25/25 green; Phases 0–5 of the lib comment roadmap are implemented (open, set/get, del/has?/size, keys/clear, multi-key stress + isolation, batch helpers, iteration & query helpers).
- Pure Aura throughout — store is a functional alist of `(key . val)` pairs; insertion order is preserved everywhere; no FS / no network / no host escape used.
- The SPEC table lists phases only through Phase 4 (batch helpers); Phase 5 (iteration/query) was a home-grown extension that we already locked in at gen 4. We have headroom for a new phase without disturbing any green test.
- Denseness posture is strong: every public op derives from `_fold` / `_map` / `_set` / `_del`. The one subtle weakness to call out is "any value lookup that is legitimately `#f` is indistinguishable from a miss" — it is consistent with `kv:get`'s contract but worth a one-line note for `kv:pick`.
- Export-before-define order has held across gens 1–4; no define-after-mutate hazard has bitten us.

# DIRECTION

- **Advance to Phase 6: fold / predicate / projection / selection helpers.** Everything pure-functional, derived from existing `_fold`/`_map` primitives, insertion-order preserved.
- New ops, all distinct from Phase 5:
  - `kv:reduce` — `(store init proc)` left fold, `proc` is `(k v acc) -> acc`
  - `kv:any?`  — short-circuit existential; `#f` on empty (vacuous)
  - `kv:every?` — short-circuit universal; `#t` on empty (vacuous)
  - `kv:pick`  — sub-store of listed keys; missing keys dropped; order follows `store`
  - `kv:omit`  — sub-store minus listed keys; survivors keep order
  - `kv:map-values` — transform values via `(proc v)`; keys + order preserved
- Bump `kv:version` from `3` to `4`.
- Extend `tests/smoke.aura` with **T24–T29** (8 new tests) covering happy paths *and* empty-store / boundary semantics.
- **Do not touch** internals (`kv:_ref`/`_has`/`_set`/`_del`/`_fold`/`_map`) or Phases 0–5 APIs. No FS escapes.

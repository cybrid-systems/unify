# Unify evolution model — project-level self-evolution

## Intent

Self-evolve a **software project** under a written SPEC and automated tests,
the way you would tell an LLM: *“implement a KV database, then keep improving it.”*

Not: mutate one pure function forever (`(* x K)` toys).

## Primary subject: `projects/kv`

| Artifact | Role |
|----------|------|
| `SPEC.md` | Product/API roadmap (phases 0–4) |
| `lib/kv.aura` | Implementation (grows over generations) |
| `tests/smoke.aura` | Acceptance suite → `SCORE n/m` |
| `evolve/state.json` | generation, best score, history |
| `evolve/last-patch.md` | last LLM proposal |

## Loop (`scripts/project-evolve.sh`)

```text
baseline tests → SCORE b/t
  → MiniMax reads SPEC + sources + fail tail
  → multi-file patch (FILE path + fenced body)
  → apply in sandbox copy of project
  → run tests → SCORE c/t
  → accept only if score improves (or full green)
  → copy into projects/kv → git commit + push
```

Continuous entry: `./scripts/evolve.sh` (default `UNIFY_PROJECT=projects/kv`).

## Relation to four spans

- **Offline smoke** still exercises Aether/Hephaestus/Prometheus/Hermes denseness.
- **Project evolve** is the *product* denseness probe: long-running pure-Aura
  software object with growing surface area — where host residuals show up as
  real engineering friction (define-after-mutate, FS escapes for later phases).

## Legacy

`scripts/durable-evolve.sh` four-axis pure functions remain available via
`UNIFY_DURABLE_EVOLVE=1` but are **off by default**.

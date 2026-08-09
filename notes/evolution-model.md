# Unify control architecture — load-adaptive infinite evolve

## Mission

`projects/kv` is an **in-memory** pure-Aura KV plant. Evolution is **unbounded**:

```text
simulate load → observe metrics → retune index/cache/policy/layout →
verify smoke + load-sim → accept if fitness↑ → journal → forever
```

Sibling denseness hosts (Aether / Hephaestus / Prometheus / Hermes) and Aura host
residuals are co-pressured in the same continuous run (“左右仓库实时进化”).

## Roles

| Role | Who | When |
|------|-----|------|
| **Controller** | MiniMax-M3 (`scripts/llm_controller.py`) | 1 call / project generation after observe |
| **Actuator** | Unify scripts + Aura runtime | Patch sandbox, run smoke + load-sim, git |
| **Plant** | `lib/kv.aura` + `lib/kv-engine.aura` | Correctness floor + adaptive engine |
| **Load** | `tests/load-sim.aura` | Workload profiles + LOAD / FITNESS lines |
| **Memory** | `evolve/state.json`, `journal.jsonl` | Includes `load_score` |

## Closed loop

```text
[1] OBSERVE   smoke.aura → SCORE   +  load-sim.aura → load_score / hit_rate
[2] CONTROL   LLM ← SPEC + engine + load metrics + journal
              LLM → REVIEW + DIRECTION + PATCH  (prefer kv-engine policy/structure)
[3] ACT       sandbox apply FILE blocks
[4] VERIFY    smoke (hard gate) + load-sim (soft optimize)
[5] MEMORY    accept if smoke OK and load not worse / improved
              → commit+push → next cycle (infinite)
```

Also each `run-continuous` cycle:

| Step | Purpose |
|------|---------|
| offline / live denseness | four-span smoke |
| git-probe | unify repo health |
| fiber-stress | high-concurrency fiber denseness |
| load-sim (via project-evolve) | adaptive KV fitness |
| project-evolve | LLM control + accept |
| sibling denseness (optional) | heph concurrent examples under fiber-stress |

## Fitness

| Gate | Rule |
|------|------|
| Hard | smoke SCORE full-green (or non-decreasing while climbing floor) |
| Soft | `LOAD_SCORE_TOTAL` / hit_rate / ops_per_s improve or hold |
| Reject | smoke regress, load regress, parse fail (0/0), LLM timeout (soft) |

## Adaptive engine surface

See `projects/kv/SPEC.md`. Generations retune:

- `mode`: alist | cache | index | hybrid  
- `cache-size`, `index-threshold`  
- eviction / rebuild / layout internals in `kv-engine.aura`

## Entry

```bash
./scripts/evolve.sh                 # continuous + watchdog
./scripts/evolve.sh status
./scripts/project-evolve.sh projects/kv
./scripts/kv-load.sh                # load-sim only
./scripts/fiber-stress.sh           # fiber pressure only
```

## Non-goals of the controller

- Infinite Phase-N helper APIs as the primary objective  
- Disk / network KV (unless a later metered phase)  
- Spam Aura issues without 定界  

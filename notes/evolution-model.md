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
| load-sim | adaptive KV fitness (default policy) |
| **squeeze** | **parallel local policy grid + multi-worker CPU burn (no LLM)** |
| project-evolve | LLM every `UNIFY_LLM_EVERY` cycles; **skipped** if squeeze just gained |

### Resident multi-gen (primary — full Aura leverage)

```bash
UNIFY_RESIDENT_GENS=3 ./scripts/aura-resident.sh
```

| Phase | Aura surface |
|-------|----------------|
| **one cold start** | entire GENS loop in single process |
| denseness | `mutate:rebind` multi-cand per gen |
| plant | free knobs via `set-code` + **`mutate:rebind` plant-mode/cache/thr** + load measure |
| fiber | multi-wave flat soak (`UNIFY_FIBER_SOAK_WAVES`) |
| metrology | `METRO cold_start_ms / gen_ms / mutate_ops / cold=0` |
| persist | best policy written to `kv-engine` after verify |

### Aura-hot (optional single-gen)

```bash
./scripts/aura-hot.sh
```

### Multi-process squeeze (optional CPU farm)

```bash
UNIFY_SQUEEZE=1 ./scripts/kv-squeeze.sh
```

LLM project-evolve only every `UNIFY_LLM_EVERY` cycles, skipped when hot/squeeze gains.

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

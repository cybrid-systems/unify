# Unify control architecture — LLM controller + Aura actuator

## Roles

| Role | Who | When |
|------|-----|------|
| **Controller** | MiniMax-M3 (`scripts/llm_controller.py`) | Each project generation, **once**, after observe |
| **Actuator** | Unify scripts + Aura runtime | Apply patch, run tests, snapshot/select, git |
| **Plant / subject** | `projects/kv` (SPEC + lib + tests) | Continuously under test |
| **Memory** | `evolve/state.json`, `journal.jsonl`, `last-review.md` | After accept/reject → next observe |

LLM is **not** the thing that mutates AST in-process by default for the project loop.
It **commands** the loop: review, direction, concrete FILE patches.

Aura **has** local mutation primitives (`query :find`, `mutate:rebind`, `ast:snapshot`)
used for denseness micro-loops; the **project** loop uses file-level patches +
Aura as the **test/execution** engine (and later denseness mutations inside modules).

## When LLM is called

Exactly **one controller call per `project-evolve` generation**:

```text
[1] OBSERVE   Aura runs tests/smoke.aura → SCORE b/t + fail tail
[2] CONTROL   LLM ← SPEC + sources + score + journal + fail tail
              LLM → REVIEW + DIRECTION + PATCH
[3] ACT       sandbox copy of project; apply FILE blocks
[4] VERIFY    Aura runs tests on sandbox → SCORE c/t
[5] MEMORY    accept if score↑ or full-green; else reject
              journal + last-review.md; on accept: git commit+push
              → back to [1] on next evolve.sh cycle
```

No LLM during offline four-span smoke, git-probe, or pure test runs.

## Closed loop (control view)

```text
                 ┌──────────────────────────────────────┐
                 │           LLM controller             │
                 │  review · direction · patch ideas    │
                 └──────────────┬───────────────────────┘
                                │ PATCH (FILE blocks)
                                ▼
  observe ◄── tests ── Aura ── act (sandbox apply)
     ▲                           │
     │                           ▼
     └────── memory ◄── accept/reject ◄── verify (Aura SCORE)
```

## Aura local transform (actuator toolkit)

| Primitive | Use in loop |
|-----------|-------------|
| Run `tests/smoke.aura` | Observe / verify fitness |
| File sandbox + copy | Actuator for project-level edits |
| `(query :find)` / `mutate:rebind` / `ast:snapshot` | Optional denseness sub-loop inside modules |
| `write-file` etc. | Later KV persistence phases (metered E) |

## Artifacts per generation

| Path | Content |
|------|---------|
| `evolve/last-observe.log` | Test output before control |
| `evolve/last-control.json` | Parsed review / direction / patch |
| `evolve/last-review.md` | Human/agent readable review |
| `evolve/last-patch.md` | Raw controller output |
| `evolve/journal.jsonl` | Accepted/rejected memory for next control |

## Entry & resume

```bash
./scripts/evolve.sh                      # loop + watchdog
./scripts/evolve.sh status
./scripts/evolve.sh stop                 # clean stop (no auto-restart)
./scripts/evolve.sh resume               # after crash/network: pull if safe + restart
./scripts/project-evolve.sh projects/kv  # one generation
```

### Survive network / process death

| Mechanism | Behavior |
|-----------|----------|
| Workspace state | `projects/kv/lib`, `tests`, `evolve/state.json` — never reset on restart |
| Watchdog | `evolve-watchdog.sh` polls every 60s; if loop PID dead and `WANT_RUN` set → restart |
| LLM timeout | retries + soft-reject; next generation continues |
| Git push fail | non-fatal; local commits remain; next accept retries push |
| `resume` | `git fetch`; ff-only pull if local not ahead; ensure loop+watchdog |

Do **not** delete `projects/kv` to “reset” unless you mean a new project.

## Legacy

Function-axis denseness explore (`durable-evolve.sh`) is optional
(`UNIFY_DURABLE_EVOLVE=1`); not the primary product controller loop.

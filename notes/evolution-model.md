# Unify evolution model

## Why not `start.sh`

The long-running process is a **self-evolution control loop**, not an app
server. Entry name: **`scripts/evolve.sh`** (`start.sh` remains a thin alias).

## Aura surfaces we use

| Primitive | Role |
|-----------|------|
| `(query :find "name")` | Locate binding node(s) — **query** half of query→mutate |
| `(mutate:rebind "name" body summary)` | Local name-level mutation (not whole-file rewrite) |
| `(mutate:query-and-replace …)` | Pattern-local mutation when predicates known |
| `(ast:snapshot tag)` / `(ast:restore id)` | **Sandbox** a candidate; roll back losers |
| `(mutate:boundary-safe?)` / quota | Safety gate before mutate |
| `(serialize-workspace path)` | Optional full workspace blob (host E) |

**Note:** Docs mention `(query:code)` as “current source”; this Aura build does
**not** register that prim. Unify therefore **tracks the subject body string**
we last applied (and can re-`set-code` from state). That is intentional until
`query:code` / `ast:to-source` is available on the host.

## Evolution pattern (not “first LLM wins”)

```text
load state (body, factor, gen)
  → install subject (local name `score`)
  → query locus (query :find "score")
  → propose K candidates (rule + MiniMax + optional alts)
  → for each candidate:
        snap → rebind(name, body) → verify samples → fitness → restore
  → arbiter: pick best fitness (and verify-pass)
  → apply winner once
  → persist body to notes/evolve-state/ + git commit
```

So:

1. **Mutation is local** — rebind one name / query-replace a locus, not rewrite the repo.
2. **Sandbox first** — multi-candidate under `ast:snapshot`; losers discarded.
3. **Select then keep** — only the winner is applied and committed.
4. **Soak ≠ evolve** — `examples/02-live-evolve` is in-memory denseness smoke only.

## Relation to Aether

Aether’s **researcher → arbiter → executor** (e.g. `11-arbitrated-multi`) is the
same shape. Unify reuses that discipline for **composition-bed** subjects and
durable state under `notes/evolve-state/`.

## What gets committed

- `notes/evolve-state/state.json` — generation, factor, **winning body**
- `journal.jsonl` — candidate outcomes over time
- **Not** every sandbox attempt; only accepted winners

# Project: Adaptive In-Memory KV (continuous load → runtime optimize)

## Identity

| | |
|--|--|
| **What** | Pure-Aura **in-memory** key–value store (no disk, no network) |
| **Why evolve** | Not to pile more CRUD helpers — to **approach optimality under live load** |
| **Loop** | simulate load → observe metrics → retune index / cache / layout → re-verify → forever |
| **Repos** | `projects/kv` is the plant; sibling denseness hosts (Aether/Hephaestus/Prometheus/Hermes) + Unify actuators **co-evolve** in the same continuous run |

This is a **runtime self-optimizing system**, not a phase-locked API checklist.

## Non-goals (explicit)

- Disk persistence / multi-process durability (metered later if ever)
- Networked multi-node KV
- Infinite helper-API surface (Phase 0–16 smoke is a **correctness floor**, not the product goal)
- One-shot “finished” state — there is none; evolution is **unbounded**

## Correctness floor (must never regress)

Public baseline API (stable names):

| Op | Contract |
|----|----------|
| `(kv:open)` | → empty store |
| `(kv:set store key val)` | set string key → value; → store |
| `(kv:get store key)` | → value or `#f` |
| `(kv:del store key)` | delete; → store |
| `(kv:has? store key)` | → bool |
| `(kv:keys store)` / `(kv:size store)` / `(kv:clear store)` | as before |

Keys are strings. Values any Aura value. **Insertion-order alist semantics** remain the default body unless a generation explicitly migrates with tests.

`tests/smoke.aura` SCORE must stay **full-green** (currently 148/148). New helpers are optional; regressions are hard rejects.

## Adaptive engine (primary evolution surface)

Beyond the bare store, generations may evolve an **engine** handle:

```text
engine = {
  body    : source-of-truth map (alist or denser layout)
  index   : secondary structure for faster key lookup (optional)
  cache   : hot-key cache (LRU / clock / size-bounded; optional)
  stats   : reads, writes, hits, misses, rebuilds, ...
  policy  : mode, cache-size, index-threshold, rebuild triggers, ...
}
```

Public engine surface (target; extend as denseness allows):

| Op | Contract |
|----|----------|
| `(kv:engine-open [policy])` | → engine |
| `(kv:engine-set e k v)` / `(kv:engine-get e k)` / `(kv:engine-del e k)` | same contracts as store; update stats |
| `(kv:engine-stats e)` | → alist of counters + last policy |
| `(kv:engine-tune e policy-patch)` | → new engine with retuned policy (may rebuild index/cache) |
| `(kv:engine-body e)` | → underlying store for interop with pure helpers |

**Adaptation rule:** policy changes are driven by **observed load**, not by fashion.

## Load simulation (continuous)

Every evolve cycle should run at least one **workload profile** and record metrics:

| Profile | Intent |
|---------|--------|
| `uniform-read` | cold-ish uniform gets after bulk fill |
| `hotspot-read` | Zipf-like / fixed hot key set (cache should win) |
| `write-heavy` | many sets/overwrite (index rebuild cost visible) |
| `mixed` | 80/20 read/write, realistic mix |
| `fiber-fanout` | concurrent readers/builders (Aura fiber denseness) |

Metrics (emit in load-sim log):

```text
LOAD profile=... ops=... elapsed_ms=... ops_per_s=...
  hits=... misses=... hit_rate=...
  policy=... mode=... cache_size=... index=...
FITNESS correctness=pass|fail load_score=...  ; higher better
```

Fitness for accept/reject (project-evolve):

1. **Hard gate:** smoke SCORE full-green (or non-decreasing if still climbing floor)  
2. **Soft optimize:** load `ops_per_s` / `hit_rate` / composite `load_score` **improves** or holds under harder profiles  
3. Never accept a faster wrong store

## Infinite evolution objectives (priority order)

1. **Correctness** under smoke + load-sim invariants  
2. **Throughput** under declared profiles (ops/s)  
3. **Hit rate / latency proxy** (hits vs misses; elapsed_ms for fixed ops)  
4. **Structure cost** (rebuilds, memory-ish size via entry counts)  
5. **Denseness** — pure Aura preferred; FS/network = escape  
6. **Host residual discovery** — file Aura issues only when 定界 host+high  

There is **no terminal phase**. After the API floor is green, every generation is:

```text
observe load → hypothesize policy/structure change → patch →
verify smoke + load-sim → accept if fitness↑ → remember → repeat
```

## Controller guidance (LLM)

Stop defaulting to “add Phase N helpers”. Prefer:

- retune `cache-size` / `index-threshold` / mode (`alist` | `index` | `cache` | `hybrid`)
- change index representation (assoc vs bucketed)
- change cache eviction
- specialized paths for hotspot vs write-heavy
- fiber-safe pure read paths under fanout
- shrink hot path allocations / recursion depth (host residual aware)

Only add API surface when it **serves measurement or adaptation**.

## Sibling / multi-repo co-evolution (“左右仓库”)

Continuous unify loop also pressures:

| Repo / span | Role |
|-------------|------|
| **unify** | controller, load-sim, project plant, actuators |
| **aura** (host) | fiber / env residuals → draft/issue when confirmed |
| **aether / hephaestus / prometheus / hermes** | denseness under concurrent load; optional micro-evolve examples |

Real-time = same `evolve.sh` cycle (or sibling step), shared journal of host vs denseness vs plant fitness — not a separate abandoned nightly.

## Success (open-ended)

- Smoke stays green forever  
- Load-sim runs **every** cycle with published metrics  
- Journal shows **accepted structure/policy wins**, not only helper counts  
- Engine policies visibly track workload shifts (e.g. hotspot ↑ → hit_rate ↑)  
- Sibling denseness probes remain green or produce 定界 residuals  

## Constraints

- Prefer pure Aura; meter escapes  
- Export-before-define form order  
- MiniMax-M3 only for LLM control  
- No commit spam on no-gain / timeout (soft-reject)  

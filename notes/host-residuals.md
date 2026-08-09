# Host Residuals — Unify

Packaging / host / stdlib issues — **not** denseness failures of the four spans.

| Date | Issue | Upstream | Notes |
|------|-------|----------|-------|
| (seed) | std/socket wrappers shadow prims | [aura#2865](https://github.com/cybrid-systems/aura/issues/2865) | Prefer bare TCP prims / Hermes path |
| (seed) | denseness runner env | [aura#2767](https://github.com/cybrid-systems/aura/issues/2767) [aura#2772](https://github.com/cybrid-systems/aura/issues/2772) | export AURA_BIN |
| 2026-08-09 | set-code module bind / top-level wipe | draft `set-code-module-bind` | After multi-round `set-code`+`eval-current`, driver top-level defines vanish; some freshly installed names not callable from a *required module* (leaf_a fail / leaf_b ok). Compose uses FlatAST metrology instead of direct leaf call. |
| 2026-08-09 | multi-define top-level after multi-require | same family | After loading four span facades, later top-level `(define …)` binds can appear unbound while earlier ones remain (hit in 03-git-host-probe). Workaround: bind via `let*` in one frame. |
| 2026-08-09 | nested fiber:join-in-worker deadlock | draft only | backend=2 (thread): worker that `fiber:spawn`+`fiber:join` hangs forever. Stress uses **flat** fanout from main only. |
| 2026-08-09 | set! free-var from nested lambda | same family as wipe | `set!` on outer `let*` binding from a helper lambda → `unbound variable: set!: name`. Count purely; set! only in outer body / same-let `while`. |
| 2026-08-09 | fiber:join may wipe top-level define | related #2868 family | After join, top-level helper names unbound. Keep all stress helpers in one `let*`. |
| 2026-08-09 | pthread EAGAIN under unbounded fanout | draft only | backend=2 real threads; large simultaneous spawn → `Resource temporarily unavailable` / SIGABRT. Cap with `UNIFY_FIBER_BATCH` (default 16). |
| 2026-08-09 | recursive kv:set build depth | draft only | recursive `let` build-store blows `recursion depth >700` around keys≈200 (kv:set multiplies frames). Fiber-stress default keys=128. |

## 定界 policy (before any Aura issue)

| Outcome | Gate | Tracker |
|---------|------|---------|
| Confirmed Aura host | `class=host` **and** `confidence=high` **and** `should_file=true` | `cybrid-systems/aura` |
| Suspected host | host + medium/low | draft only — human review |
| Unify-owned | `unify-self` / `should_self_evolve` | `notes/self-evolve/` queue — self-fix |
| Denseness / LLM | verify / network | never Aura |

Pipeline:

1. `classify-failure.py` — 定界 + confidence + reasons
2. `file-aura-issue.sh --log` — create **only** if `should_file`
3. else `enqueue-self-evolve.sh` for unify-self (optional MiniMax proposal)

Drafts: `notes/issue-drafts/` (gitignored). Auth: `~/.github-token`.

# Host Residuals — Unify

Packaging / host / stdlib issues — **not** denseness failures of the four spans.

| Date | Issue | Upstream | Notes |
|------|-------|----------|-------|
| (seed) | std/socket wrappers shadow prims | [aura#2865](https://github.com/cybrid-systems/aura/issues/2865) | Prefer bare TCP prims / Hermes path |
| (seed) | denseness runner env | [aura#2767](https://github.com/cybrid-systems/aura/issues/2767) [aura#2772](https://github.com/cybrid-systems/aura/issues/2772) | export AURA_BIN |
| 2026-08-09 | set-code module bind / top-level wipe | draft `set-code-module-bind` | After multi-round `set-code`+`eval-current`, driver top-level defines vanish; some freshly installed names not callable from a *required module* (leaf_a fail / leaf_b ok). Compose uses FlatAST metrology instead of direct leaf call. |
| 2026-08-09 | multi-define top-level after multi-require | same family | After loading four span facades, later top-level `(define …)` binds can appear unbound while earlier ones remain (hit in 03-git-host-probe). Workaround: bind via `let*` in one frame. |
| 2026-08-09 | nested fiber:join-in-worker deadlock | [aura#2869](https://github.com/cybrid-systems/aura/issues/2869) | backend=2: worker that `fiber:spawn`+`fiber:join` hangs forever. Stress uses **flat** fanout from main only. Minimal repro in issue. |
| 2026-08-09 | top-level set! unbound after fiber:join | [aura#2870](https://github.com/cybrid-systems/aura/issues/2870) | After top-level join, `set!` of top-level define → `unbound variable: set!: name`. Regression signal vs closed #2322; distinct from set-code #2868. let* control works. |
| 2026-08-09 | named-let recursion depth footgun | [aura#2871](https://github.com/cybrid-systems/aura/issues/2871) | no TCO; pure loop dies at ~700. |
| 2026-08-09 | multi-frame stack cost (kv fill / cache) | [aura#2873](https://github.com/cybrid-systems/aura/issues/2873) | Same `>700` cap: pure ~700 iters; `kv:set`+string ~200; nested recursive list rebuild ~120. load-sim evidence. |
| 2026-08-09 | define RHS depth-fail wrong bind / wipe | [aura#2872](https://github.com/cybrid-systems/aura/issues/2872) | **high**: failed `(define name deep-RHS)` binds `name` to **previous** top-level value (`eq?` alias) and can **unbind siblings**. Root of load-sim “top-level wipe” cascade. Workaround: single `let*` + `while`. |
| 2026-08-09 | pthread EAGAIN under corrupted fanout | **not filed** (secondary) | Seen only after prior unbound/crash cascade + large fanout → SIGABRT. Fresh 256-spawn ok. Batch cap remains defensive. |
| 2026-08-09 | fiber:join top-level define wipe | **not filed** (not cleanly repro'd alone) | Intermediate stress; see also #2870 / #2872 for related env corruption. |

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

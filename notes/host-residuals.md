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
| 2026-08-09 | named-let recursion depth footgun | [aura#2871](https://github.com/cybrid-systems/aura/issues/2871) | medium conf: no TCO; pure loop dies at ~700, multi-frame ~200. Fiber-stress keys≤128. |
| 2026-08-09 | pthread EAGAIN under corrupted fanout | **not filed** (secondary) | Seen only after prior unbound/crash cascade + large fanout → SIGABRT. Fresh 256-spawn ok. Batch cap remains defensive. |
| 2026-08-09 | fiber:join top-level define wipe | **not filed** (not cleanly repro'd) | Intermediate stress showed `build-store` unbound after join; standalone R3b did not reproduce. Absorbed into #2870 family if it reappears. |

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

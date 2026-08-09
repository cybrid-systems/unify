# Unify

**Cross-span synthesis bed for Aura Unify** — compose the four denseness spans and run a continuous self-evolution loop with **MiniMax-M3 only**.

| Span | Role in synthesis |
|------|-------------------|
| [Aether](https://github.com/cybrid-systems/aether) | Agent closed loop + safe mutation |
| [Hephaestus](https://github.com/cybrid-systems/hephaestus) | Pure-Aura kernels + load metrology |
| [Prometheus](https://github.com/cybrid-systems/prometheus) | Scale AST / continuous mutation surface |
| [Hermes](https://github.com/cybrid-systems/hermes) | Topology, wire, multi-process / TCP edges |

Unify is **not** a fifth theoretical subspace. It answers:

> Can the same basis \(V_A\) host a single long-running system that **thinks, mutates, measures, and coordinates** — and when the *host* breaks, file a reproducible issue against Aura?

## Fixed LLM: MiniMax-M3

Unify **only** uses MiniMax-M3 (OpenAI-compatible):

| Env | Value |
|-----|--------|
| `LLM_MODEL` | `MiniMax-M3` |
| `LLM_BASE_URL` | `https://api.minimaxi.com/v1` |
| Key file | `~/code/keys/minimax` |

```bash
source ./scripts/env-minimax.sh   # required for live evolve
```

No DeepSeek / multi-provider matrix in this repo by policy.

## Layout

```text
unify/
├── examples/
│   ├── 01-offline-compose/   # sibling smokes + in-process four-span compose
│   ├── 02-live-evolve/       # MiniMax-M3 propose → mutate → verify (short N)
│   └── 03-git-host-probe/    # Aura git-* (libgit2) + residual classify
├── lib/                      # measure, loop, host, compose (export-before-require)
├── scripts/
│   ├── run-aura.sh
│   ├── run-offline.sh
│   ├── env-minimax.sh
│   ├── overnight.sh
│   └── file-aura-issue.sh    # ~/.github-token; draft default; UNIFY_AUTO_ISSUE=1
├── notes/
│   ├── denseness-report.md
│   ├── escape-log.md
│   ├── host-residuals.md
│   └── issue-drafts/
└── prompts/GROK.md
```

## Prerequisites (sibling checkouts)

Default layout (same parent as this repo):

```text
../aura-grok/build/aura
../aether
../hephaestus
../prometheus
../hermes
```

Override with `AURA_BIN`, `AURA_ROOT`, `AETHER_ROOT`, etc.

## Quick start

```bash
# Offline: one smoke probe from each span (no API key)
./scripts/run-offline.sh

# Live evolve (MiniMax-M3)
source ./scripts/env-minimax.sh
./scripts/run-aura.sh examples/02-live-evolve/main.aura

# Continuous loop (offline + live×N + git probe; draft issues unless UNIFY_AUTO_ISSUE=1)
source ./scripts/env-minimax.sh
./scripts/run-continuous.sh          # forever; logs under logs/runs/latest/
./scripts/status.sh                  # pid / last events / failures
# touch logs/runs/STOP               # graceful stop after current cycle

# Finite overnight (one cycle, N live rounds)
UNIFY_OVERNIGHT_N=20 ./scripts/overnight.sh
```

### Logs (continuous)

| Path | Content |
|------|---------|
| `logs/runs/latest/master.log` | timestamped step stream |
| `logs/runs/latest/events.jsonl` | machine-readable events |
| `logs/runs/latest/SUMMARY.md` | human cycle summary |
| `logs/runs/latest/failures/` | copied failing logs + issue bodies |
| `logs/runs/latest/cycles/NNNN/` | per-cycle offline/live/git logs |

### 定界 → Aura issue **or** self-evolve

Failures are classified **before** any GitHub write:

| Class / confidence | Action |
|--------------------|--------|
| `host` + **high** (`should_file`) | detailed draft + create on `cybrid-systems/aura` (if `UNIFY_AUTO_ISSUE=1`) |
| `host` + medium/low | draft only — human 定界, no auto-file |
| `unify-self` | queue `notes/self-evolve/` — fix in Unify, **never** Aura |
| `denseness` | denseness-report / draft only |
| `llm` | retry / draft only |

```bash
# Classify only
python3 scripts/classify-failure.py --log path.log --label x | jq '{class,confidence,should_file,should_self_evolve,action,reasons}'

# File (gated by should_file)
./scripts/file-aura-issue.sh --log path.log --label live-003 \
  --cmd './scripts/run-aura.sh examples/02-live-evolve/main.aura'

# Unify-self + optional MiniMax proposal (not auto-applied)
UNIFY_SELF_EVOLVE=1 ./scripts/enqueue-self-evolve.sh --log path.log --label x
```

Auth: `~/.github-token`. Soft signals (capability / git alone / set-code alone)
never auto-file.

## Issue policy (Aura)

Failures are **classified** before any GitHub write:

| Class | Action |
|-------|--------|
| `host` residual (unbound prim, crash, stdlib break) | write `notes/issue-drafts/<fingerprint>.md`; if `UNIFY_AUTO_ISSUE=1`, `gh issue create` on `cybrid-systems/aura` |
| `denseness` (core escape / verify fail) | denseness-report only — **not** auto-filed to Aura |
| `llm` / network / no-key | retry or skip |
| duplicate fingerprint | skip |

Default is **draft-only** so overnight cannot spam the Aura tracker.

## Status

**Iteration 2.** In-process four-span composition, metered `git-*` host probe, issue
drafts via `~/.github-token` (curl fallback). Expand overnight N and dual-subject
synthesis under denseness discipline.

## License

Apache License 2.0

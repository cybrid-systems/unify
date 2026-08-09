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
│   ├── 01-offline-compose/   # no LLM: run one denseness probe per span
│   └── 02-live-evolve/       # MiniMax-M3 propose → mutate → verify (short N)
├── lib/                      # thin composition (export-before-require)
├── scripts/
│   ├── run-aura.sh
│   ├── run-offline.sh
│   ├── env-minimax.sh
│   ├── overnight.sh
│   └── file-aura-issue.sh    # draft by default; UNIFY_AUTO_ISSUE=1 to post
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

# Overnight (draft issues only unless UNIFY_AUTO_ISSUE=1)
source ./scripts/env-minimax.sh
./scripts/overnight.sh
```

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

**Initialized.** Offline compose + live evolve skeleton. Expand N and dual-span subjects under denseness discipline.

## License

Apache License 2.0

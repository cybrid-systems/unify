# Denseness Report — Unify synthesis

**Status**: Iteration 2 — in-process four-span compose + git host probe

## Claim

Unify does **not** claim a new \(S_k\). It claims **constructive composition**:

> The four practically-dense spans can be exercised together in one \(V_A\) process;
> MiniMax-M3 drives a schema-gated propose edge; host residuals (including
> `set-code` / `git-*`) are separated from denseness failures.

## Fixed LLM policy

| Field | Value |
|-------|--------|
| Provider | MiniMax only |
| Model | `MiniMax-M3` |
| Base | `https://api.minimaxi.com/v1` |
| Key | `~/code/keys/minimax` via `scripts/env-minimax.sh` |

## Results

| Probe | Result | Notes |
|-------|--------|-------|
| span smokes ×4 (shell) | **pass** | aether / hephaestus / prometheus / hermes 01-* |
| 01-offline-compose in-process | **pass** | `unify:compose-all!` + metered `git-probe` |
| 02-live-evolve offline | **pass** | force BODY triple |
| 02-live-evolve live MiniMax-M3 | **pass** | commits via LLM propose, escapes=1 (HTTPS E) |
| 03-git-host-probe | **pass** | libgit2 git-* reads + classify |

## Host residuals found this iteration

| Fingerprint | Class | Action |
|-------------|-------|--------|
| `set-code-module-bind` | host | draft in `notes/issue-drafts/`; compose workaround via FlatAST observe |

## Judgment

*Composition strengthened (in-process multi-require + git E). Continue overnight N,
multi-subject synthesis, and selective `UNIFY_AUTO_ISSUE=1` filing.*

# Denseness Report — Unify synthesis

**Status**: Initialized + first offline/live smokes green

## Claim

Unify does **not** claim a new \(S_k\). It claims **constructive composition**:

> The four practically-dense spans can be exercised together; MiniMax-M3 drives a
> schema-gated propose edge; host residuals are separated from denseness failures.

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
| 01-offline-compose | **pass** | aether+hephaestus+prometheus+hermes smokes + unify force-body |
| 02-live-evolve offline | **pass** | force BODY triple, escapes=0 |
| 02-live-evolve live MiniMax-M3 | **pass** | commits via LLM propose, escapes=1 (HTTPS E) |

## Judgment

*Composition smoke positive.* Expand overnight N and multi-subject synthesis under the same discipline.

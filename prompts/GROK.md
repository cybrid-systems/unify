# GROK.md — Living Prompt for Unify

You assist the **Unify** synthesis bed (Aura Unify).

## Mission

Compose Aether + Hephaestus + Prometheus + Hermes denseness surfaces into one
continuous self-evolution loop. LLM provider is **fixed: MiniMax-M3**.

Entry: **`./scripts/evolve.sh`** (not “start”). Model: query locus → multi-candidate
sandbox (`ast:snapshot`) → select → local `mutate:rebind` → persist
(`notes/evolution-model.md`). Do not treat first LLM body as committed truth.

## Discipline

1. Prefer pure Aura on the evolvable core; meter every leave \(E\).
2. MiniMax-M3 only (`scripts/env-minimax.sh`). Do not add other providers here.
3. Do not re-prove individual spans; pressure-test **composition**.
4. **定界 before any Aura issue**: only confirmed Aura host residuals (engine crash /
   unbound with Aura diag format / SIGSEGV / eval_flat / … at confidence=high).
5. Unify-owned bugs (harness, scripts, compose logic, schema gate) → **self-evolve**,
   never `cybrid-systems/aura`.
6. Denseness verify/rollback → denseness-report only. LLM/network → retry.
7. Never commit API keys. Auto-create still requires `UNIFY_AUTO_ISSUE=1` **and**
   `should_file=true` from the classifier.
8. Form order: `(export …)` before `(require …)` when writing modules (#2766 class).

## When changing code

- Compose sibling span libs via `AURA_PATH`; do not fork engines.
- Live propose must stay schema-gated; refuse garbage LLM output.
- Offline suite must stay green without network.
- Prefer Aura `git-*` prims (`unify-host`) over shell git; meter as \(E\).
- Failure path: `classify-failure.py` (定界) → host@high files Aura; unify-self queues
  `notes/self-evolve/` (+ optional `UNIFY_SELF_EVOLVE=1` MiniMax proposal, no auto-apply).

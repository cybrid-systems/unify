# Host Residuals — Unify

Packaging / host / stdlib issues — **not** denseness failures of the four spans.

| Date | Issue | Upstream | Notes |
|------|-------|----------|-------|
| (seed) | std/socket wrappers shadow prims | [aura#2865](https://github.com/cybrid-systems/aura/issues/2865) | Prefer bare TCP prims / Hermes path |
| (seed) | denseness runner env | [aura#2767](https://github.com/cybrid-systems/aura/issues/2767) [aura#2772](https://github.com/cybrid-systems/aura/issues/2772) | export AURA_BIN |
| 2026-08-09 | set-code module bind / top-level wipe | draft `set-code-module-bind` | After multi-round `set-code`+`eval-current`, driver top-level defines vanish; some freshly installed names not callable from a *required module* (leaf_a fail / leaf_b ok). Compose uses FlatAST metrology instead of direct leaf call. |
| 2026-08-09 | multi-define top-level after multi-require | same family | After loading four span facades, later top-level `(define …)` binds can appear unbound while earlier ones remain (hit in 03-git-host-probe). Workaround: bind via `let*` in one frame. |

## Auto-issue

See `scripts/file-aura-issue.sh` (loads `~/.github-token`; `gh` or curl).
Drafts land in `notes/issue-drafts/`. Set `UNIFY_AUTO_ISSUE=1` to post.

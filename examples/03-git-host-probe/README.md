# 03-git-host-probe

Read-side exercise of Aura `git-*` primitives (libgit2 when built-in) plus
host/denseness/llm classification for issue drafts.

```bash
./scripts/run-aura.sh examples/03-git-host-probe/main.aura

# Optional: poke git-stage with a missing path
UNIFY_GIT_WRITE=1 ./scripts/run-aura.sh examples/03-git-host-probe/main.aura
```

Expect `RESULT pass example=03-git-host-probe`.

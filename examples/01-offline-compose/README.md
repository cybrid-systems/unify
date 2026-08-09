# 01-offline-compose

Two layers (no LLM):

1. **Sibling smokes** — each span's own denseness probe via `scripts/run-offline.sh`
2. **In-process compose** — one Aura process loads all four facades + metered `git-*`

```bash
./scripts/run-offline.sh
# or only in-process:
./scripts/run-aura.sh examples/01-offline-compose/main.aura
```

Expect `RESULT pass example=01-offline-compose`.

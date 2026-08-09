# projects/kv — project-level self-evolution subject

Mini KV store grown by **project-evolve** (LLM patches + tests), not single-function
toys.

```bash
# run tests
AURA_PATH=projects/kv/lib:lib ./scripts/run-aura.sh projects/kv/tests/smoke.aura

# one evolution generation
./scripts/project-evolve.sh projects/kv

# continuous loop uses project-evolve by default
./scripts/evolve.sh
```

See `SPEC.md` and `evolve/state.json`.

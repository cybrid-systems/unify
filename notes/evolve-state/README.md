# Evolve state (durable subject)

| field | value |
|-------|-------|
| updated | 2026-08-09T03:59Z |
| generation | 1 |
| factor | 3 |
| body | `(lambda (x) (* x 3))` |
| decision | commit |
| source | llm |

**This is real self-evolution state.**  
`examples/02-live-evolve` is only in-memory soak (no file / no git).

Advance: `./scripts/durable-evolve.sh` (also each continuous cycle).

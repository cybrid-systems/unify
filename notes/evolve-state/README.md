# Evolve state (durable subject)

| field | value |
|-------|-------|
| updated | 2026-08-09T04:00Z |
| generation | 3 |
| factor | 7 |
| body | `(lambda (x) (* x 7))` |
| decision | commit |
| source | llm |

**This is real self-evolution state.**  
`examples/02-live-evolve` is only in-memory soak (no file / no git).

Advance: `./scripts/durable-evolve.sh` (also each continuous cycle).

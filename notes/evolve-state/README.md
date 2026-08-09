# Spacetime denseness explore state

| field | value |
|-------|-------|
| mode | spacetime-explore |
| generation | 40 |
| last axis | hop (hermes) |
| winner body | `(lambda (i) (if (= i 0) 1 (if (= i 1) 2 0)))` |
| candidates tried | 5/5 |

## Four axes (composition)

| axis | span | role |
|------|------|------|
| score | Aether | free pure decision metric |
| kernel | Hephaestus | triangle closed form |
| leaf | Prometheus | homogeneous pure map |
| hop | Hermes | ring next-hop |

Each generation mutates **one** axis under multi-cand sandbox; **all** must still verify.
Failed explorations → `frontier.jsonl` (denseness boundary samples).

Readable dump: `subject.aura`. Entry: `./scripts/evolve.sh`.

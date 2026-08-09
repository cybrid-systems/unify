# Project: mini KV store (Aura denseness subject)

## Goal

Implement a **usable in-process key-value store** in pure Aura (as far as denseness
allows), then **iteratively self-evolve** it under a fixed test suite.

This is a **project-level** evolution target — not a single-function toy.

## Public API (target)

| Op | Contract |
|----|----------|
| `(kv:open)` | → store handle (opaque list/hash) |
| `(kv:set store key val)` | set string key → any value; → store |
| `(kv:get store key)` | → value or `#f` if missing |
| `(kv:del store key)` | delete key; → store |
| `(kv:has? store key)` | → `#t` / `#f` |
| `(kv:keys store)` | → list of keys |
| `(kv:size store)` | → number of keys |
| `(kv:clear store)` | empty store; → store |

Keys are strings. Values may be numbers or strings in v1.

## Evolution phases (roadmap)

| Phase | Focus | Tests unlocked |
|-------|--------|----------------|
| 0 | open + set/get | T1–T3 |
| 1 | del / has? / size | T4–T6 |
| 2 | keys / clear / overwrite | T7–T9 |
| 3 | multi-key stress + isolation | T10–T12 |
| 4 | optional: batch helpers | T13+ |

Each **generation** of project-evolve should:

1. Read this SPEC + current `lib/kv.aura` + last test log  
2. Propose a **multi-file patch** (usually `lib/kv.aura`, sometimes tests only if SPEC-aligned)  
3. Run `tests/smoke.aura`  
4. Keep the patch only if `score` does not regress and preferably improves  
5. Commit + push when accepted  

## Constraints

- Prefer pure Aura; meter any `write-file` / FS as escape \(E\).  
- Do not break export/require form order if modularizing.  
- Keep API names stable once introduced.  
- No network. MiniMax-M3 is the only LLM for propose.  

## Success

Phase ≥ 3 with all T1–T12 green, multi-generation history in `evolve/journal.jsonl`.

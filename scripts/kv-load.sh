#!/usr/bin/env bash
# Run adaptive KV load simulation (fitness signal for infinite evolve).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export AURA_BIN="${AURA_BIN:-$ROOT/../aura-grok/build/aura}"
export AURA_SANDBOX="${AURA_SANDBOX:-off}"
export AURA_PATH="${AURA_PATH:-$ROOT/projects/kv/lib:$ROOT/../aura-grok/lib:$ROOT/lib}"
LOG="$(mktemp)"
set +e
"$AURA_BIN" <"$ROOT/projects/kv/tests/load-sim.aura" >"$LOG" 2>&1
rc=$?
set -e
cat "$LOG"
if grep -q 'RESULT pass project=kv-load' "$LOG"; then
  echo "RESULT pass kv-load"
  exit 0
fi
echo "RESULT fail kv-load rc=$rc"
exit 1

#!/usr/bin/env bash
# High-concurrency fiber pressure on projects/kv (+ optional Hephaestus denseness).
#
# Defaults intentionally aggressive: 32 workers × 128 keys × 4 waves + 64 burst.
# Nested fiber:join-in-worker is avoided (host residual deadlock on backend=2).
#
#   ./scripts/fiber-stress.sh
#   UNIFY_FIBER_N=64 UNIFY_FIBER_KEYS=256 UNIFY_FIBER_WAVES=6 ./scripts/fiber-stress.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export AURA_BIN="${AURA_BIN:-$ROOT/../aura-grok/build/aura}"
export AURA_SANDBOX="${AURA_SANDBOX:-off}"
export AURA_PIPELINE_STRICT="${AURA_PIPELINE_STRICT:-0}"
export UNIFY_FIBER_N="${UNIFY_FIBER_N:-32}"
export UNIFY_FIBER_KEYS="${UNIFY_FIBER_KEYS:-128}"
export UNIFY_FIBER_WAVES="${UNIFY_FIBER_WAVES:-4}"
# Live concurrent thread cap per fanout (backend=2 = real threads). 0 = no batching.
export UNIFY_FIBER_BATCH="${UNIFY_FIBER_BATCH:-16}"
# Soft wall for hung host; continuous loop must not freeze forever
export UNIFY_FIBER_TIMEOUT_SEC="${UNIFY_FIBER_TIMEOUT_SEC:-120}"

# Include hephaestus for optional secondary probe
export AURA_PATH="${AURA_PATH:-$ROOT/projects/kv/lib:$ROOT/../hephaestus/lib:$ROOT/../aura-grok/lib:$ROOT/lib}"

if [[ ! -x "$AURA_BIN" ]]; then
  echo "error: AURA_BIN not executable: $AURA_BIN" >&2
  exit 1
fi

echo "[fiber-stress] N=$UNIFY_FIBER_N keys=$UNIFY_FIBER_KEYS waves=$UNIFY_FIBER_WAVES batch=$UNIFY_FIBER_BATCH timeout=${UNIFY_FIBER_TIMEOUT_SEC}s"
LOG="$(mktemp)"
set +e
timeout "${UNIFY_FIBER_TIMEOUT_SEC}" "$AURA_BIN" <"$ROOT/projects/kv/tests/fiber-stress.aura" >"$LOG" 2>&1
rc=$?
set -e
cat "$LOG"

if [[ $rc -eq 124 ]]; then
  echo "RESULT fail fiber-stress reason=timeout sec=$UNIFY_FIBER_TIMEOUT_SEC"
  exit 1
fi

if grep -q 'RESULT pass project=kv-fiber' "$LOG"; then
  echo "RESULT pass fiber-stress"
  # Optional secondary denseness probes (non-fatal if absent/fail)
  if [[ "${UNIFY_FIBER_HEPH:-1}" == "1" ]]; then
    for heph_ex in \
      examples/09-concurrent-rebind/main.aura \
      examples/15-concurrent-multi-rebind/main.aura; do
      if [[ -f "$ROOT/../hephaestus/$heph_ex" ]]; then
        echo "[fiber-stress] hephaestus $heph_ex…"
        set +e
        (cd "$ROOT/../hephaestus" && timeout 60 ./scripts/run-aura.sh "$heph_ex") >"$LOG.heph" 2>&1
        hrc=$?
        set -e
        if grep -qE 'RESULT pass' "$LOG.heph"; then
          echo "RESULT pass fiber-stress-heph example=$(basename "$(dirname "$heph_ex")")"
          tail -n 5 "$LOG.heph" || true
        else
          echo "WARN heph $heph_ex did not pass (non-fatal for kv gate, rc=$hrc)"
          tail -n 15 "$LOG.heph" || true
        fi
      fi
    done
  fi
  exit 0
fi

echo "RESULT fail fiber-stress rc=$rc"
exit 1

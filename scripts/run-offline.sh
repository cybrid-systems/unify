#!/usr/bin/env bash
# Offline synthesis: one denseness smoke from each span + unify forced-body loop.
# No network / no LLM required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

AETHER="${AETHER_ROOT:-$ROOT/../aether}"
HEPH="${HEPHAESTUS_ROOT:-$ROOT/../hephaestus}"
PROM="${PROMETHEUS_ROOT:-$ROOT/../prometheus}"
HERMES="${HERMES_ROOT:-$ROOT/../hermes}"

fail=0
pass=0

run_span() {
  local name="$1"
  local dir="$2"
  local probe="$3"
  echo "======== span=$name probe=$probe ========"
  if [[ ! -d "$dir" ]]; then
    echo "MISSING sibling: $dir"
    fail=$((fail + 1))
    return
  fi
  if [[ ! -f "$dir/$probe" ]]; then
    echo "MISSING probe: $dir/$probe"
    fail=$((fail + 1))
    return
  fi
  local log="/tmp/unify-offline-$name.log"
  if (cd "$dir" && ./scripts/run-aura.sh "$probe") >"$log" 2>&1; then
    if grep -qE 'RESULT pass|PASS:' "$log"; then
      echo "PASS span=$name"
      pass=$((pass + 1))
      tail -n 3 "$log" || true
    else
      echo "FAIL span=$name (no RESULT pass)"
      tail -n 20 "$log" || true
      fail=$((fail + 1))
    fi
  else
    echo "FAIL span=$name (runner error)"
    tail -n 30 "$log" || true
    fail=$((fail + 1))
  fi
  echo
}

run_span aether    "$AETHER"  "examples/01-single-loop/main.aura"
run_span hephaestus "$HEPH"   "examples/01-minimal-kernel/main.aura"
run_span prometheus "$PROM"   "examples/01-minimal-scale/main.aura"
run_span hermes    "$HERMES"  "examples/01-minimal-topology/main.aura"

run_unify() {
  local name="$1"
  local path="$2"
  local expect="$3"
  echo "======== unify $name ========"
  local log="/tmp/unify-offline-$name.log"
  if ./scripts/run-aura.sh "$path" >"$log" 2>&1; then
    if grep -q "$expect" "$log"; then
      echo "PASS unify=$name"
      pass=$((pass + 1))
      tail -n 4 "$log" || true
    else
      echo "FAIL unify=$name (no expected RESULT)"
      tail -n 30 "$log" || true
      fail=$((fail + 1))
    fi
  else
    echo "FAIL unify=$name (runner error)"
    tail -n 40 "$log" || true
    fail=$((fail + 1))
  fi
  echo
}

# Offline path: no UNIFY_LIVE → force-body triple / no LLM
unset UNIFY_LIVE LLM_API_KEY || true

run_unify "in-process-compose" "examples/01-offline-compose/main.aura" \
  "RESULT pass example=01-offline-compose"
run_unify "forced-body-evolve" "examples/02-live-evolve/main.aura" \
  "RESULT pass example=02-live-evolve"
run_unify "git-host-probe" "examples/03-git-host-probe/main.aura" \
  "RESULT pass example=03-git-host-probe"

echo "======== summary ========"
echo "pass=$pass fail=$fail"
if [[ "$fail" -ne 0 ]]; then
  echo "RESULT fail example=01-offline-compose"
  exit 1
fi
echo "RESULT pass example=01-offline-compose spans=4+unify-compose+git"

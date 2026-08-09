#!/usr/bin/env bash
# Cross-generation resident Aura: ONE process, GENS×(denseness mutate + plant
# mutate grid + multi-wave fiber soak). Then persist best policy to disk.
#
#   UNIFY_RESIDENT_GENS=4 ./scripts/aura-resident.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export AURA_BIN="${AURA_BIN:-$ROOT/../aura-grok/build/aura}"
export AURA_SANDBOX="${AURA_SANDBOX:-off}"
export AURA_PIPELINE_STRICT="${AURA_PIPELINE_STRICT:-0}"
export UNIFY_RESIDENT_GENS="${UNIFY_RESIDENT_GENS:-3}"
export UNIFY_LOAD_KEYS="${UNIFY_LOAD_KEYS:-48}"
export UNIFY_LOAD_OPS="${UNIFY_LOAD_OPS:-128}"
export UNIFY_HOT_FIBER_N="${UNIFY_HOT_FIBER_N:-24}"
export UNIFY_FIBER_SOAK_WAVES="${UNIFY_FIBER_SOAK_WAVES:-4}"
export UNIFY_RESIDENT_DENSE="${UNIFY_RESIDENT_DENSE:-1}"

PROJ="${UNIFY_PROJECT:-projects/kv}"
EVOLVE="$ROOT/$PROJ/evolve"
ENGINE="$ROOT/$PROJ/lib/kv-engine.aura"
mkdir -p "$EVOLVE"

# Need denseness + kv libs in one path
export AURA_PATH="${AURA_PATH:-$ROOT/$PROJ/lib:$ROOT/lib:$ROOT/../aura-grok/lib:$ROOT/../aether/lib:$ROOT/../hephaestus/lib:$ROOT/../prometheus/lib:$ROOT/../hermes/lib}"

if [[ ! -x "$AURA_BIN" ]]; then
  echo "error: AURA_BIN" >&2
  exit 1
fi

echo "[resident] gens=$UNIFY_RESIDENT_GENS keys=$UNIFY_LOAD_KEYS ops=$UNIFY_LOAD_OPS fiber=${UNIFY_HOT_FIBER_N}x${UNIFY_FIBER_SOAK_WAVES}"
LOG="$EVOLVE/last-resident.log"
set +e
"$AURA_BIN" <"$ROOT/$PROJ/tests/resident-loop.aura" >"$LOG" 2>&1
rc=$?
set -e
# show metrology
grep -E 'METRO|BEST_POLICY|DENSE|PLANT_BEST|FIBER_SOAK|RESULT|GEN ' "$LOG" | tail -60 || true
tail -n 8 "$LOG" || true

if ! grep -q 'RESULT pass project=kv-resident' "$LOG"; then
  echo "RESULT fail aura-resident rc=$rc"
  exit 1
fi

mode="$(grep 'BEST_POLICY mode=' "$LOG" | tail -n1 | sed -n 's/.*mode=\([^ ]*\).*/\1/p')"
cache="$(grep 'BEST_POLICY mode=' "$LOG" | tail -n1 | sed -n 's/.*cache=\([0-9]*\).*/\1/p')"
thr="$(grep 'BEST_POLICY mode=' "$LOG" | tail -n1 | sed -n 's/.*thr=\([0-9]*\).*/\1/p')"
score="$(grep 'BEST_POLICY mode=' "$LOG" | tail -n1 | sed -n 's/.*score=\([0-9.]*\).*/\1/p')"
mutate_ops="$(grep 'mutate_ops_total=' "$LOG" | tail -n1 | sed -n 's/.*mutate_ops_total=\([0-9]*\).*/\1/p')"
total_ms="$(grep 'METRO total_ms=' "$LOG" | tail -n1 | sed -n 's/.*total_ms=\([0-9]*\).*/\1/p')"
echo "[resident] best mode=$mode cache=$cache thr=$thr score=$score mutate_ops=$mutate_ops total_ms=$total_ms"

base_score="0"
if [[ -f "$EVOLVE/last-load.log" ]] && grep -q LOAD_SCORE_TOTAL "$EVOLVE/last-load.log"; then
  base_score="$(grep -oE 'LOAD_SCORE_TOTAL [-0-9.]+' "$EVOLVE/last-load.log" | tail -n1 | awk '{print $2}')"
fi

# persist knobs + default-policy to engine file
backup="$(mktemp)"
cp -f "$ENGINE" "$backup"
python3 - "$ENGINE" "$mode" "$cache" "$thr" <<'PY'
import re, sys
path, mode, cache, thr = sys.argv[1:5]
src = open(path, encoding="utf-8").read()
# knobs if present
src2, n1 = re.subn(
    r'\(define kv:pol-mode "[^"]*"\)',
    f'(define kv:pol-mode "{mode}")', src, count=1)
src2, n2 = re.subn(
    r'\(define kv:pol-cache \d+\)',
    f'(define kv:pol-cache {cache})', src2, count=1)
src2, n3 = re.subn(
    r'\(define kv:pol-thr \d+\)',
    f'(define kv:pol-thr {thr})', src2, count=1)
src2, n4 = re.subn(
    r'(\(define \(kv:_default-policy\)\s*)\(list\s+[^)]+\)(\))',
    rf'\1(list kv:pol-mode kv:pol-cache kv:pol-thr)\2', src2, count=1)
# also plain list form
if n4 == 0:
    src2, n4 = re.subn(
        r'\(define \(kv:_default-policy\)\s*\(list[^)]+\)\)',
        f'(define (kv:_default-policy) (list "{mode}" {cache} {thr}))',
        src2, count=1)
open(path, "w", encoding="utf-8").write(src2)
print(f"persist n_mode={n1} n_cache={n2} n_thr={n3} n_def={n4} → {mode} {cache} {thr}")
PY

VER="$EVOLVE/last-load.log"
set +e
AURA_PATH="$ROOT/$PROJ/lib:$ROOT/../aura-grok/lib:$ROOT/lib" \
  UNIFY_LOAD_KEYS="$UNIFY_LOAD_KEYS" UNIFY_LOAD_OPS="$UNIFY_LOAD_OPS" \
  "$AURA_BIN" <"$ROOT/$PROJ/tests/load-sim.aura" >"$VER" 2>&1
set -e
vscore="0"
if grep -q LOAD_SCORE_TOTAL "$VER"; then
  vscore="$(grep -oE 'LOAD_SCORE_TOTAL [-0-9.]+' "$VER" | tail -n1 | awk '{print $2}')"
fi
echo "[resident] verify load_score=$vscore baseline=$base_score"

applied=0
if grep -q 'RESULT pass project=kv-load' "$VER" \
  && awk -v a="$vscore" -v b="$base_score" 'BEGIN { exit !(a+0 + 0.01*b >= b+0) }'; then
  applied=1
  echo "[resident] ACCEPT"
else
  echo "[resident] REJECT → revert"
  cp -f "$backup" "$ENGINE"
fi
rm -f "$backup"

SMOKE="$(mktemp)"
set +e
AURA_PATH="$ROOT/$PROJ/lib:$ROOT/../aura-grok/lib:$ROOT/lib" \
  "$AURA_BIN" <"$ROOT/$PROJ/tests/smoke.aura" >"$SMOKE" 2>&1
set -e
if ! grep -q 'RESULT pass project=kv' "$SMOKE"; then
  echo "RESULT fail aura-resident reason=smoke"
  exit 1
fi
rm -f "$SMOKE"

# optional multi-process burn after resident
if [[ "${UNIFY_HOT_BURN:-1}" == "1" ]]; then
  jobs="${UNIFY_SQUEEZE_JOBS:-0}"
  if [[ "$jobs" -le 0 ]]; then
    jobs="$(nproc 2>/dev/null || echo 4)"; [[ "$jobs" -gt 8 ]] && jobs=8
  fi
  echo "[resident] burn jobs=$jobs"
  w="$(mktemp -d)"
  for i in $(seq 1 "$jobs"); do
    (AURA_PATH="$ROOT/$PROJ/lib:$ROOT/../aura-grok/lib:$ROOT/lib" \
      UNIFY_LOAD_KEYS="$UNIFY_LOAD_KEYS" UNIFY_LOAD_OPS="$UNIFY_LOAD_OPS" \
      "$AURA_BIN" <"$ROOT/$PROJ/tests/load-sim.aura" >"$w/b$i.log" 2>&1) &
  done
  wait
  rm -rf "$w"
fi

python3 - "$EVOLVE/last-resident.json" "$mode" "$cache" "$thr" "$score" "$vscore" \
  "$applied" "$mutate_ops" "$total_ms" "$UNIFY_RESIDENT_GENS" <<'PY'
import json, sys
from datetime import datetime, timezone
open(sys.argv[1], "w").write(json.dumps({
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
    "mode": sys.argv[2],
    "cache": int(sys.argv[3] or 0),
    "thr": int(sys.argv[4] or 0),
    "resident_score": sys.argv[5],
    "verify_score": sys.argv[6],
    "applied": sys.argv[7] == "1",
    "mutate_ops": int(sys.argv[8] or 0),
    "total_ms": int(sys.argv[9] or 0),
    "gens": int(sys.argv[10] or 0),
    "cold_starts": 1,
    "path": "resident-multi-gen",
}, indent=2))
print(sys.argv[1])
PY

STATE="$EVOLVE/state.json"
python3 - "$STATE" "$vscore" "$applied" "$mutate_ops" <<'PY'
import json, sys
from pathlib import Path
from datetime import datetime, timezone
p = Path(sys.argv[1])
st = json.loads(p.read_text()) if p.is_file() else {}
try:
    st["best_load_score"] = max(float(st.get("best_load_score") or 0), float(sys.argv[2] or 0))
except Exception:
    pass
st["last_resident"] = {
    "verify": sys.argv[2], "applied": sys.argv[3] == "1",
    "mutate_ops": sys.argv[4],
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
}
st["updated"] = st["last_resident"]["ts"]
p.write_text(json.dumps(st, indent=2))
PY

if [[ "$applied" -eq 1 ]]; then
  if [[ "${UNIFY_GIT_COMMIT:-1}" == "1" ]]; then
    git add "$ENGINE" "$EVOLVE/last-resident.json" "$STATE" 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
      git commit -m "$(cat <<EOF
project(kv): resident ${UNIFY_RESIDENT_GENS}gens → ${mode} c=${cache} load=${vscore}

Single Aura process: denseness mutate + plant rebind grid + fiber soak waves.
mutate_ops=${mutate_ops} total_ms=${total_ms} cold_starts=1
EOF
)" || true
      [[ "${UNIFY_GIT_PUSH:-1}" == "1" ]] && git push origin HEAD 2>/dev/null || true
    fi
  fi
  echo "1" >"$EVOLVE/squeeze-gain.flag"
  echo "RESULT pass aura-resident improved=1 gens=$UNIFY_RESIDENT_GENS mode=$mode cache=$cache thr=$thr verify=$vscore mutate_ops=$mutate_ops cold_starts=1"
else
  rm -f "$EVOLVE/squeeze-gain.flag"
  echo "RESULT pass aura-resident improved=0 gens=$UNIFY_RESIDENT_GENS mode=$mode cache=$cache thr=$thr verify=$vscore mutate_ops=$mutate_ops cold_starts=1"
fi
exit 0

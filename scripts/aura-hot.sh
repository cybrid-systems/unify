#!/usr/bin/env bash
# Aura-native hot evolve step: ONE denseness mutate process + ONE in-process
# policy grid (hot-squeeze) + optional multi-process burn.
#
# Leverages: set-code/mutate:rebind, single-process multi-trial eval, fiber soak.
#   ./scripts/aura-hot.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export AURA_BIN="${AURA_BIN:-$ROOT/../aura-grok/build/aura}"
export AURA_SANDBOX="${AURA_SANDBOX:-off}"
export AURA_PIPELINE_STRICT="${AURA_PIPELINE_STRICT:-0}"
export UNIFY_LOAD_KEYS="${UNIFY_LOAD_KEYS:-64}"
export UNIFY_LOAD_OPS="${UNIFY_LOAD_OPS:-192}"
export UNIFY_HOT_FIBER_N="${UNIFY_HOT_FIBER_N:-24}"

PROJ="${UNIFY_PROJECT:-projects/kv}"
EVOLVE="$ROOT/$PROJ/evolve"
ENGINE="$ROOT/$PROJ/lib/kv-engine.aura"
mkdir -p "$EVOLVE"

# denseness path needs span libs
export AURA_PATH_DENSE="${AURA_PATH_DENSE:-$ROOT/lib:$ROOT/../aura-grok/lib:$ROOT/../aether/lib:$ROOT/../hephaestus/lib:$ROOT/../prometheus/lib:$ROOT/../hermes/lib}"
export AURA_PATH_KV="${AURA_PATH_KV:-$ROOT/$PROJ/lib:$ROOT/../aura-grok/lib:$ROOT/lib}"

if [[ ! -x "$AURA_BIN" ]]; then
  echo "error: AURA_BIN not executable" >&2
  exit 1
fi

echo "[aura-hot] denseness mutate (in-process multi-cand)…"
DENSE_LOG="$EVOLVE/last-hot-denseness.log"
set +e
AURA_PATH="$AURA_PATH_DENSE" "$AURA_BIN" <"$ROOT/$PROJ/tests/hot-denseness.aura" >"$DENSE_LOG" 2>&1
drc=$?
set -e
tail -n 20 "$DENSE_LOG" || true
if ! grep -q 'RESULT pass project=kv-hot-denseness' "$DENSE_LOG"; then
  echo "WARN denseness hot soft-fail rc=$drc (continue to policy hot)"
  dense_ok=0
else
  dense_ok=1
  echo "[aura-hot] denseness OK"
fi

echo "[aura-hot] in-process policy grid + fiber soak…"
HOT_LOG="$EVOLVE/last-hot-squeeze.log"
set +e
AURA_PATH="$AURA_PATH_KV" \
  UNIFY_LOAD_KEYS="$UNIFY_LOAD_KEYS" UNIFY_LOAD_OPS="$UNIFY_LOAD_OPS" \
  UNIFY_HOT_FIBER_N="$UNIFY_HOT_FIBER_N" \
  "$AURA_BIN" <"$ROOT/$PROJ/tests/hot-squeeze.aura" >"$HOT_LOG" 2>&1
hrc=$?
set -e
tail -n 30 "$HOT_LOG" || true
if ! grep -q 'RESULT pass project=kv-hot-squeeze' "$HOT_LOG"; then
  echo "RESULT fail aura-hot reason=hot-squeeze rc=$hrc"
  exit 1
fi

# parse BEST_POLICY
mode="$(grep -oE 'BEST_POLICY mode=[^ ]+' "$HOT_LOG" | tail -n1 | cut -d= -f2 | awk '{print $1}')"
cache="$(grep 'BEST_POLICY mode=' "$HOT_LOG" | tail -n1 | sed -n 's/.*cache=\([0-9]*\).*/\1/p')"
thr="$(grep 'BEST_POLICY mode=' "$HOT_LOG" | tail -n1 | sed -n 's/.*thr=\([0-9]*\).*/\1/p')"
score="$(grep 'BEST_POLICY mode=' "$HOT_LOG" | tail -n1 | sed -n 's/.*score=\([0-9.]*\).*/\1/p')"
echo "[aura-hot] best mode=$mode cache=$cache thr=$thr score=$score"

base_score="0"
if [[ -f "$EVOLVE/last-load.log" ]] && grep -q LOAD_SCORE_TOTAL "$EVOLVE/last-load.log"; then
  base_score="$(grep -oE 'LOAD_SCORE_TOTAL [-0-9.]+' "$EVOLVE/last-load.log" | tail -n1 | awk '{print $2}')"
fi

backup="$(mktemp)"
cp -f "$ENGINE" "$backup"
python3 - "$ENGINE" "$mode" "$cache" "$thr" <<'PY'
import re, sys
path, mode, cache, thr = sys.argv[1:5]
src = open(path, encoding="utf-8").read()
pat = re.compile(
    r"(\(define \(kv:_default-policy\)\s*)\(list\s+\"[^\"]+\"\s+\d+\s+\d+\)(\))"
)
new, n = pat.subn(rf'\1(list "{mode}" {cache} {thr})\2', src, count=1)
if n != 1:
    pat2 = re.compile(r"\(define \(kv:_default-policy\)\s*\(list[^)]+\)\)")
    new, n = pat2.subn(
        f'(define (kv:_default-policy) (list "{mode}" {cache} {thr}))', src, count=1
    )
if n != 1:
    sys.exit("patch failed")
open(path, "w", encoding="utf-8").write(new)
print("patched", mode, cache, thr)
PY

# verify with load-sim (one process)
VER="$EVOLVE/last-load.log"
set +e
AURA_PATH="$AURA_PATH_KV" UNIFY_LOAD_KEYS="$UNIFY_LOAD_KEYS" UNIFY_LOAD_OPS="$UNIFY_LOAD_OPS" \
  "$AURA_BIN" <"$ROOT/$PROJ/tests/load-sim.aura" >"$VER" 2>&1
set -e
vscore="0"
if grep -q LOAD_SCORE_TOTAL "$VER"; then
  vscore="$(grep -oE 'LOAD_SCORE_TOTAL [-0-9.]+' "$VER" | tail -n1 | awk '{print $2}')"
fi
echo "[aura-hot] verify load_score=$vscore baseline=$base_score"

applied=0
if grep -q 'RESULT pass project=kv-load' "$VER" \
  && awk -v a="$vscore" -v b="$base_score" 'BEGIN { exit !(a+0 + 0.01*b >= b+0) }'; then
  applied=1
  echo "[aura-hot] ACCEPT policy"
else
  echo "[aura-hot] REJECT → revert engine"
  cp -f "$backup" "$ENGINE"
fi
rm -f "$backup"

# smoke floor
SMOKE="$(mktemp)"
set +e
AURA_PATH="$AURA_PATH_KV" "$AURA_BIN" <"$ROOT/$PROJ/tests/smoke.aura" >"$SMOKE" 2>&1
set -e
if ! grep -q 'RESULT pass project=kv' "$SMOKE"; then
  echo "RESULT fail aura-hot reason=smoke"
  tail -n 10 "$SMOKE"
  exit 1
fi
echo "[aura-hot] smoke ok"

# optional multi-process burn (CPU soak after hot path)
if [[ "${UNIFY_HOT_BURN:-1}" == "1" ]]; then
  jobs="${UNIFY_SQUEEZE_JOBS:-0}"
  if [[ "$jobs" -le 0 ]]; then
    jobs="$(nproc 2>/dev/null || echo 4)"
    [[ "$jobs" -gt 8 ]] && jobs=8
  fi
  echo "[aura-hot] multi-process burn jobs=$jobs"
  w="$(mktemp -d)"
  for i in $(seq 1 "$jobs"); do
    (AURA_PATH="$AURA_PATH_KV" UNIFY_LOAD_KEYS="$UNIFY_LOAD_KEYS" UNIFY_LOAD_OPS="$UNIFY_LOAD_OPS" \
      "$AURA_BIN" <"$ROOT/$PROJ/tests/load-sim.aura" >"$w/b$i.log" 2>&1) &
  done
  wait
  rm -rf "$w"
  echo "[aura-hot] burn done"
fi

python3 - "$EVOLVE/last-hot.json" "$mode" "$cache" "$thr" "$score" "$vscore" "$applied" "$dense_ok" <<'PY'
import json, sys
from datetime import datetime, timezone
path = sys.argv[1]
open(path, "w").write(json.dumps({
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
    "mode": sys.argv[2],
    "cache": int(sys.argv[3] or 0),
    "thr": int(sys.argv[4] or 0),
    "hot_score": sys.argv[5],
    "verify_score": sys.argv[6],
    "applied": sys.argv[7] == "1",
    "denseness_ok": sys.argv[8] == "1",
    "path": "in-process-hot",
}, indent=2))
print(path)
PY

# state
STATE="$EVOLVE/state.json"
python3 - "$STATE" "$vscore" "$applied" <<'PY'
import json, sys
from pathlib import Path
from datetime import datetime, timezone
p, vs, ap = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
st = json.loads(p.read_text()) if p.is_file() else {}
try:
    st["best_load_score"] = max(float(st.get("best_load_score") or 0), float(vs or 0))
except Exception:
    st["best_load_score"] = vs
st["last_hot"] = {"verify": vs, "applied": ap == "1",
                  "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")}
st["updated"] = st["last_hot"]["ts"]
p.write_text(json.dumps(st, indent=2))
PY

if [[ "$applied" -eq 1 ]]; then
  if [[ "${UNIFY_GIT_COMMIT:-1}" == "1" ]]; then
    git add "$ENGINE" "$EVOLVE/last-hot.json" "$STATE" 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
      git commit -m "$(cat <<EOF
project(kv): aura-hot policy → ${mode} cache=${cache} thr=${thr} load=${vscore}

In-process denseness mutate + single-process policy grid + fiber soak.
EOF
)" || true
      if [[ "${UNIFY_GIT_PUSH:-1}" == "1" ]]; then
        git push origin HEAD 2>/dev/null || true
      fi
    fi
  fi
  echo "1" >"$EVOLVE/squeeze-gain.flag"
  echo "RESULT pass aura-hot improved=1 denseness=$dense_ok mode=$mode cache=$cache thr=$thr verify=$vscore"
else
  rm -f "$EVOLVE/squeeze-gain.flag"
  echo "RESULT pass aura-hot improved=0 denseness=$dense_ok mode=$mode cache=$cache thr=$thr verify=$vscore"
fi
exit 0

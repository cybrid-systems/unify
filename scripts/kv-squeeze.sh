#!/usr/bin/env bash
# Local high-CPU squeeze: parallel policy grid + heavy load, no LLM.
#
# Finds best (mode, cache-size, index-threshold) under load, patches
# kv:_default-policy if improved, verifies smoke+load, optional commit.
#
#   ./scripts/kv-squeeze.sh
#   UNIFY_SQUEEZE_JOBS=8 UNIFY_LOAD_KEYS=64 UNIFY_LOAD_OPS=384 ./scripts/kv-squeeze.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

export AURA_BIN="${AURA_BIN:-$ROOT/../aura-grok/build/aura}"
export AURA_SANDBOX="${AURA_SANDBOX:-off}"
export AURA_PATH="${AURA_PATH:-$ROOT/projects/kv/lib:$ROOT/../aura-grok/lib:$ROOT/lib}"
export UNIFY_LOAD_KEYS="${UNIFY_LOAD_KEYS:-64}"
export UNIFY_LOAD_OPS="${UNIFY_LOAD_OPS:-256}"

PROJ="${UNIFY_PROJECT:-projects/kv}"
ENGINE="$ROOT/$PROJ/lib/kv-engine.aura"
EVOLVE="$ROOT/$PROJ/evolve"
mkdir -p "$EVOLVE"
STATE="$EVOLVE/state.json"
OUT_JSON="$EVOLVE/last-squeeze.json"
BEST_FILE="$EVOLVE/best-policy.txt"

JOBS="${UNIFY_SQUEEZE_JOBS:-0}"
if [[ "$JOBS" -le 0 ]]; then
  JOBS="$(nproc 2>/dev/null || echo 4)"
  # leave headroom for fiber/system
  if [[ "$JOBS" -gt 10 ]]; then JOBS=10; fi
  if [[ "$JOBS" -lt 2 ]]; then JOBS=2; fi
fi

if [[ ! -x "$AURA_BIN" ]]; then
  echo "error: AURA_BIN not executable: $AURA_BIN" >&2
  exit 1
fi
if [[ ! -f "$ENGINE" ]]; then
  echo "error: missing $ENGINE" >&2
  exit 1
fi

echo "[squeeze] jobs=$JOBS keys=$UNIFY_LOAD_KEYS ops=$UNIFY_LOAD_OPS aura=$AURA_BIN"

# ── parallel policy grid ──────────────────────────────────────────────────
WORKDIR="$(mktemp -d /tmp/unify-squeeze-XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

# modes × cache × thr — modest grid, high parallelism
MODES=(hybrid cache alist)
CACHES=(4 8 16 32 48 64)
THRS=(16 32 64)

task_list=()
task_list+=("alist|0|9999")
for m in hybrid cache; do
  for c in "${CACHES[@]}"; do
    for t in "${THRS[@]}"; do
      task_list+=("${m}|${c}|${t}")
    done
  done
done
echo "[squeeze] grid_points=${#task_list[@]}"

run_one() {
  local spec="$1"
  local mode cache thr
  IFS='|' read -r mode cache thr <<<"$spec"
  local tag="${mode}_c${cache}_t${thr}"
  local logf="$WORKDIR/${tag}.log"
  set +e
  UNIFY_POL_MODE="$mode" UNIFY_POL_CACHE="$cache" UNIFY_POL_THR="$thr" \
    UNIFY_LOAD_KEYS="$UNIFY_LOAD_KEYS" UNIFY_LOAD_OPS="$UNIFY_LOAD_OPS" \
    "$AURA_BIN" <"$ROOT/$PROJ/tests/policy-bench.aura" >"$logf" 2>&1
  local rc=$?
  set -e
  local score="0"
  if grep -qE 'LOAD_SCORE_TOTAL ' "$logf"; then
    score="$(grep -oE 'LOAD_SCORE_TOTAL [-0-9.]+' "$logf" | tail -n1 | awk '{print $2}')"
  fi
  echo "${score}|${mode}|${cache}|${thr}|${rc}" >"$WORKDIR/${tag}.res"
  echo "[squeeze] done $tag score=$score rc=$rc"
}

# worker pool
running=0
for spec in "${task_list[@]}"; do
  run_one "$spec" &
  running=$((running + 1))
  if [[ "$running" -ge "$JOBS" ]]; then
    wait -n 2>/dev/null || wait
    running=$((running - 1))
  fi
done
wait

# pick best
best_score="-1"
best_mode="hybrid"
best_cache="8"
best_thr="32"
results=()
while IFS= read -r -d '' f; do
  line="$(cat "$f")"
  results+=("$line")
  score="${line%%|*}"
  rest="${line#*|}"
  mode="${rest%%|*}"
  rest2="${rest#*|}"
  cache="${rest2%%|*}"
  rest3="${rest2#*|}"
  thr="${rest3%%|*}"
  # numeric compare
  if awk -v a="$score" -v b="$best_score" 'BEGIN { exit !(a+0 > b+0) }'; then
    best_score="$score"
    best_mode="$mode"
    best_cache="$cache"
    best_thr="$thr"
  fi
done < <(find "$WORKDIR" -name '*.res' -print0)

echo "[squeeze] BEST mode=$best_mode cache=$best_cache thr=$best_thr score=$best_score"
echo "mode=$best_mode cache=$best_cache thr=$best_thr score=$best_score" >"$BEST_FILE"

# baseline score from last load or state
base_score="0"
if [[ -f "$EVOLVE/last-load.log" ]] && grep -q LOAD_SCORE_TOTAL "$EVOLVE/last-load.log"; then
  base_score="$(grep -oE 'LOAD_SCORE_TOTAL [-0-9.]+' "$EVOLVE/last-load.log" | tail -n1 | awk '{print $2}')"
elif [[ -f "$STATE" ]]; then
  base_score="$(python3 -c 'import json;print(json.load(open("'"$STATE"'")).get("best_load_score",0))' 2>/dev/null || echo 0)"
fi
echo "[squeeze] baseline_load_score=$base_score"

# read current default policy from engine source
cur_line="$(grep -E 'define \(kv:_default-policy\)' "$ENGINE" | head -n1 || true)"
echo "[squeeze] current $cur_line"

# Prefer cache/hybrid over pure alist when within 12% of grid best (adaptive surface)
pick_mode="$best_mode"
pick_cache="$best_cache"
pick_thr="$best_thr"
pick_score="$best_score"
if [[ "$best_mode" == "alist" ]]; then
  alt="$(printf '%s\n' "${results[@]:-}" | awk -F'|' '
    $2=="hybrid" || $2=="cache" {
      if ($1+0 > best+0) { best=$1; line=$0 }
    }
    END { if (best!="") print line }
  ')"
  if [[ -n "$alt" ]]; then
    a_score="${alt%%|*}"
    if awk -v a="$a_score" -v b="$best_score" 'BEGIN { exit !(a+0 >= b+0 * 0.88) }'; then
      pick_score="$a_score"
      rest="${alt#*|}"
      pick_mode="${rest%%|*}"
      rest2="${rest#*|}"
      pick_cache="${rest2%%|*}"
      rest3="${rest2#*|}"
      pick_thr="${rest3%%|*}"
      echo "[squeeze] prefer adaptive mode=$pick_mode cache=$pick_cache thr=$pick_thr score=$pick_score (within 12% of alist peak)"
    fi
  fi
fi
best_mode="$pick_mode"
best_cache="$pick_cache"
best_thr="$pick_thr"
best_score="$pick_score"
echo "[squeeze] PICK mode=$best_mode cache=$best_cache thr=$best_thr score=$best_score"

# Always try patch candidate; accept only if verify load_score >= baseline
applied=0
backup="$(mktemp)"
cp -f "$ENGINE" "$backup"
python3 - "$ENGINE" "$best_mode" "$best_cache" "$best_thr" <<'PY'
import re, sys
path, mode, cache, thr = sys.argv[1:5]
src = open(path, encoding="utf-8").read()
pat = re.compile(
    r"(\(define \(kv:_default-policy\)\s*)\(list\s+\"[^\"]+\"\s+\d+\s+\d+\)(\))"
)
repl = rf'\1(list "{mode}" {cache} {thr})\2'
new, n = pat.subn(repl, src, count=1)
if n != 1:
    pat2 = re.compile(r"\(define \(kv:_default-policy\)\s*\(list[^)]+\)\)")
    new, n = pat2.subn(
        f'(define (kv:_default-policy) (list "{mode}" {cache} {thr}))', src, count=1
    )
if n != 1:
    sys.exit(f"patch failed n={n}")
open(path, "w", encoding="utf-8").write(new)
print(f"patched default-policy → {mode} {cache} {thr}")
PY

# ── heavy multi-worker burn (CPU soak) ────────────────────────────────────
BURN="${UNIFY_SQUEEZE_BURN:-1}"
if [[ "$BURN" == "1" ]]; then
  burn_n="$JOBS"
  echo "[squeeze] CPU burn: $burn_n parallel heavy load-sim"
  for i in $(seq 1 "$burn_n"); do
    (
      UNIFY_LOAD_KEYS="$UNIFY_LOAD_KEYS" UNIFY_LOAD_OPS="$UNIFY_LOAD_OPS" \
        "$AURA_BIN" <"$ROOT/$PROJ/tests/load-sim.aura" >"$WORKDIR/burn-$i.log" 2>&1
    ) &
  done
  wait
  echo "[squeeze] burn complete"
fi

# ── verify after apply ────────────────────────────────────────────────────
VERIFY_LOG="$EVOLVE/last-squeeze-verify.log"
set +e
UNIFY_LOAD_KEYS="$UNIFY_LOAD_KEYS" UNIFY_LOAD_OPS="$UNIFY_LOAD_OPS" \
  "$AURA_BIN" <"$ROOT/$PROJ/tests/load-sim.aura" >"$VERIFY_LOG" 2>&1
vrc=$?
set -e
cp -f "$VERIFY_LOG" "$EVOLVE/last-load.log"
vscore="0"
if grep -qE 'LOAD_SCORE_TOTAL ' "$VERIFY_LOG"; then
  vscore="$(grep -oE 'LOAD_SCORE_TOTAL [-0-9.]+' "$VERIFY_LOG" | tail -n1 | awk '{print $2}')"
fi
echo "[squeeze] verify load_score=$vscore rc=$vrc baseline=$base_score"
if ! grep -q 'RESULT pass project=kv-load' "$VERIFY_LOG"; then
  echo "[squeeze] verify-load failed → revert"
  cp -f "$backup" "$ENGINE"
  echo "RESULT fail squeeze reason=verify-load"
  exit 1
fi

# Accept only if verify score is not worse than baseline (noise margin 1%)
if awk -v a="$vscore" -v b="$base_score" 'BEGIN { exit !(a+0 + 0.01*b >= b+0) }'; then
  applied=1
  echo "[squeeze] ACCEPT verify $vscore >= baseline $base_score"
else
  echo "[squeeze] REJECT verify $vscore < baseline $base_score → revert"
  cp -f "$backup" "$ENGINE"
  applied=0
fi
rm -f "$backup"

# optional quick smoke (correctness floor)
SMOKE_LOG="$WORKDIR/smoke.log"
set +e
"$AURA_BIN" <"$ROOT/$PROJ/tests/smoke.aura" >"$SMOKE_LOG" 2>&1
src=$?
set -e
if ! grep -q 'RESULT pass project=kv' "$SMOKE_LOG"; then
  echo "RESULT fail squeeze reason=smoke"
  tail -n 15 "$SMOKE_LOG" || true
  exit 1
fi
smoke_sc="$(grep -oE 'SCORE [0-9]+/[0-9]+' "$SMOKE_LOG" | tail -n1)"
echo "[squeeze] smoke $smoke_sc"

# update state best_load_score
python3 - "$STATE" "$best_mode" "$best_cache" "$best_thr" "$best_score" "$vscore" "$applied" "$base_score" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path
path, mode, cache, thr, gscore, vscore, applied, base = sys.argv[1:9]
p = Path(path)
st = json.loads(p.read_text()) if p.is_file() else {}
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
try:
    best = max(float(st.get("best_load_score") or 0), float(vscore or 0), float(gscore or 0))
except Exception:
    best = vscore
st["best_load_score"] = best
st["last_squeeze"] = {
    "ts": now,
    "mode": mode,
    "cache": int(cache),
    "thr": int(thr),
    "grid_score": gscore,
    "verify_score": vscore,
    "baseline": base,
    "applied": applied == "1",
}
st["updated"] = now
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(st, indent=2))
print("state updated best_load_score=", best)
PY

python3 - "$OUT_JSON" "$best_mode" "$best_cache" "$best_thr" "$best_score" "$vscore" "$applied" "$base_score" "$JOBS" <<'PY'
import json, sys
from datetime import datetime, timezone
path = sys.argv[1]
out = {
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
    "mode": sys.argv[2],
    "cache": int(sys.argv[3]),
    "thr": int(sys.argv[4]),
    "grid_best_score": sys.argv[5],
    "verify_score": sys.argv[6],
    "applied": sys.argv[7] == "1",
    "baseline": sys.argv[8],
    "jobs": int(sys.argv[9]),
}
open(path, "w").write(json.dumps(out, indent=2))
print(path)
PY

# commit if applied and git enabled
if [[ "$applied" -eq 1 && "${UNIFY_GIT_COMMIT:-1}" == "1" ]]; then
  git add "$ENGINE" "$BEST_FILE" "$OUT_JSON" "$STATE" 2>/dev/null || true
  if ! git diff --cached --quiet 2>/dev/null; then
    git commit -m "$(cat <<EOF
project(kv): squeeze policy → ${best_mode} cache=${best_cache} thr=${best_thr} load=${vscore}

Local parallel policy grid (no LLM); CPU soak + load-sim verify; smoke green.
EOF
)" || true
    if [[ "${UNIFY_GIT_PUSH:-1}" == "1" ]]; then
      git push origin HEAD 2>/dev/null || echo "[squeeze] push soft-fail"
    fi
  fi
fi

# signal for continuous: skip LLM if we applied a gain
if [[ "$applied" -eq 1 ]]; then
  echo "1" >"$EVOLVE/squeeze-gain.flag"
  echo "RESULT pass squeeze improved=1 mode=$best_mode cache=$best_cache thr=$best_thr grid=$best_score verify=$vscore"
else
  rm -f "$EVOLVE/squeeze-gain.flag"
  echo "RESULT pass squeeze improved=0 mode=$best_mode cache=$best_cache thr=$best_thr grid=$best_score verify=$vscore baseline=$base_score"
fi
exit 0

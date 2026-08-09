#!/usr/bin/env bash
# Project closed-loop: OBSERVE → LLM CONTROL → ACT → VERIFY → MEMORY
#
#   LLM = controller (review + direction + patch ideas)
#   Unify/Aura = actuator (sandbox apply, run tests, accept/reject, git)
#
#   ./scripts/project-evolve.sh [projects/kv]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJ_REL="${1:-${UNIFY_PROJECT:-projects/kv}}"
PROJ="$ROOT/$PROJ_REL"
if [[ ! -d "$PROJ" || ! -f "$PROJ/SPEC.md" ]]; then
  echo "error: need project dir with SPEC.md: $PROJ_REL" >&2
  exit 2
fi

EVOLVE_DIR="$PROJ/evolve"
mkdir -p "$EVOLVE_DIR"
STATE="$EVOLVE_DIR/state.json"
JOURNAL="$EVOLVE_DIR/journal.jsonl"
LAST_FAIL="$EVOLVE_DIR/last-fail.log"
LAST_CTRL="$EVOLVE_DIR/last-control.json"
LAST_PATCH="$EVOLVE_DIR/last-patch.md"
LAST_REVIEW="$EVOLVE_DIR/last-review.md"

GIT_COMMIT="${UNIFY_GIT_COMMIT:-1}"
GIT_PUSH="${UNIFY_GIT_PUSH:-1}"
export AURA_BIN="${AURA_BIN:-$ROOT/../aura-grok/build/aura}"
export AURA_SANDBOX="${AURA_SANDBOX:-off}"
export AURA_PIPELINE_STRICT="${AURA_PIPELINE_STRICT:-0}"

if [[ ! -x "$AURA_BIN" ]]; then
  echo "error: AURA_BIN not executable: $AURA_BIN" >&2
  exit 1
fi

if [[ ! -f "$STATE" ]]; then
  cat >"$STATE" <<JSON
{
  "project": "$PROJ_REL",
  "generation": 0,
  "best_score": 0,
  "best_total": 0,
  "status": "init",
  "controller": "llm+minimax",
  "actuator": "unify-sandbox+aura-tests",
  "history": []
}
JSON
fi

# ── Actuator: run Aura project tests ──────────────────────────────────────
run_tests() {
  local work="$1"
  local logf="$2"
  local suite="${3:-smoke.aura}"
  local apath="$work/lib:${AURA_PATH:-$ROOT/../aura-grok/lib:$ROOT/lib}"
  set +e
  AURA_PATH="$apath" AURA_BIN="$AURA_BIN" AURA_SANDBOX="$AURA_SANDBOX" \
    "$AURA_BIN" <"$work/tests/$suite" >"$logf" 2>&1
  local rc=$?
  set -e
  local score=0 total=0
  if grep -qE 'SCORE [0-9]+/[0-9]+' "$logf"; then
    score="$(grep -oE 'SCORE [0-9]+/[0-9]+' "$logf" | tail -n1 | awk '{print $2}' | cut -d/ -f1)"
    total="$(grep -oE 'SCORE [0-9]+/[0-9]+' "$logf" | tail -n1 | awk '{print $2}' | cut -d/ -f2)"
  fi
  echo "$rc $score $total"
}

parse_load_score() {
  local logf="$1"
  if grep -qE 'LOAD_SCORE_TOTAL ' "$logf"; then
    grep -oE 'LOAD_SCORE_TOTAL [-0-9.]+' "$logf" | tail -n1 | awk '{print $2}'
  elif grep -qE 'load_score=' "$logf"; then
    grep -oE 'load_score=[-0-9.]+' "$logf" | tail -n1 | cut -d= -f2
  else
    echo "0"
  fi
}

echo "======== [1/5] OBSERVE (smoke + load-sim) ========"
BASE_LOG="$(mktemp)"
read -r BASE_RC BASE_SCORE BASE_TOTAL < <(run_tests "$PROJ" "$BASE_LOG" smoke.aura)
echo "[observe] smoke=$BASE_SCORE/$BASE_TOTAL rc=$BASE_RC project=$PROJ_REL"
if [[ "$BASE_TOTAL" -eq 0 ]]; then
  echo "error: tests produced no SCORE" >&2
  tail -n 40 "$BASE_LOG" || true
  exit 1
fi
BASE_LOAD_LOG="$(mktemp)"
BASE_LOAD_SCORE="0"
if [[ -f "$PROJ/tests/load-sim.aura" ]]; then
  read -r _BLRC _BLS _BLT < <(run_tests "$PROJ" "$BASE_LOAD_LOG" load-sim.aura)
  BASE_LOAD_SCORE="$(parse_load_score "$BASE_LOAD_LOG")"
  echo "[observe] load_score=$BASE_LOAD_SCORE load_tests=${_BLS:-?}/${_BLT:-?} (infinite-evolve fitness)"
  cp -f "$BASE_LOAD_LOG" "$EVOLVE_DIR/last-load.log"
else
  echo "[observe] no load-sim.aura — fitness=smoke only"
  echo "(no load-sim)" >"$BASE_LOAD_LOG"
fi
cp -f "$BASE_LOG" "$EVOLVE_DIR/last-observe.log"
# Combined observe for humans
{
  echo "### smoke"
  tail -n 30 "$BASE_LOG"
  echo "### load-sim"
  tail -n 40 "$BASE_LOAD_LOG"
} >"$EVOLVE_DIR/last-observe-combined.log"

if [[ ! -f "${MINIMAX_KEY_FILE:-$HOME/code/keys/minimax}" ]]; then
  echo "error: MiniMax key required (LLM controller)" >&2
  exit 1
fi
# shellcheck disable=SC1091
source ./scripts/env-minimax.sh

GEN="$(python3 -c 'import json;print(json.load(open("'"$STATE"'")).get("generation",0))')"

echo "======== [2/5] CONTROL (LLM review + direction + patch) ========"
echo "[control] frequency: 1 MiniMax call per project-evolve generation (after observe)"
echo "[control] timeout=${UNIFY_LLM_TIMEOUT:-480}s retries=${UNIFY_LLM_RETRIES:-3}"
set +e
python3 "$ROOT/scripts/llm_controller.py" \
  --project "$PROJ" \
  --gen "$GEN" \
  --score "$BASE_SCORE" \
  --total "$BASE_TOTAL" \
  --spec "$PROJ/SPEC.md" \
  --test-log "$BASE_LOG" \
  --load-log "$BASE_LOAD_LOG" \
  --load-score "$BASE_LOAD_SCORE" \
  --memory "$JOURNAL" \
  --source lib/kv.aura \
  --source lib/kv-engine.aura \
  --source tests/load-sim.aura \
  --source tests/smoke.aura \
  --out-json "$LAST_CTRL" \
  --out-patch "$LAST_PATCH"
ctrl_rc=$?
set -e
if [[ "$ctrl_rc" -ne 0 ]]; then
  echo "[control] LLM failed (timeout/network) — soft-reject this generation; next cycle retries"
  python3 - "$STATE" "$JOURNAL" "$BASE_SCORE" "$BASE_TOTAL" <<'PY'
import json, sys
from datetime import datetime, timezone
path, journal, bs, bt = sys.argv[1:5]
st = json.load(open(path))
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
row = {
    "ts": now,
    "phase": "control-loop",
    "generation": int(st.get("generation") or 0),
    "accepted": False,
    "reason": "llm-timeout-or-error",
    "baseline": f"{bs}/{bt}",
    "candidate": f"{bs}/{bt}",
}
st.setdefault("history", []).append(row)
st["history"] = st["history"][-100:]
st["status"] = "llm-retry"
st["updated"] = now
json.dump(st, open(path, "w"), indent=2)
open(journal, "a").write(json.dumps(row, ensure_ascii=False) + "\n")
print("memory: llm-retry recorded")
PY
  echo "RESULT pass project-evolve soft-reject reason=llm-timeout score=$BASE_SCORE/$BASE_TOTAL"
  exit 0
fi

python3 - "$LAST_CTRL" "$LAST_REVIEW" <<'PY'
import json, sys
from pathlib import Path
c = json.load(open(sys.argv[1]))
Path(sys.argv[2]).write_text(
    "# Controller REVIEW\n\n" + (c.get("review") or "") +
    "\n\n# DIRECTION\n\n" + (c.get("direction") or "") + "\n",
    encoding="utf-8",
)
print("controller memory:", sys.argv[2])
PY

echo "======== [3/5] ACT (sandbox apply patch) ========"
SANDBOX="$(mktemp -d /tmp/unify-proj-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
cp -a "$PROJ/." "$SANDBOX/"

python3 - "$SANDBOX" "$LAST_CTRL" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent) if False else "")
# import apply from sibling module
import importlib.util
spec = importlib.util.spec_from_file_location(
    "llm_controller",
    Path(sys.argv[0]).resolve().parent / "llm_controller.py"
    if False else Path(sys.argv[1]).parent  # placeholder
)
# simpler: exec apply_patch_text by loading file
import re
root = Path(sys.argv[1])
ctrl = json.load(open(sys.argv[2]))
text = ctrl.get("patch") or open(ctrl.get("raw_path", "/dev/null")).read() if ctrl.get("raw_path") else ""
if not text and ctrl.get("raw_path"):
    text = open(ctrl["raw_path"], encoding="utf-8", errors="replace").read()
# Prefer full raw if patch section empty
if not (text or "").strip() and ctrl.get("raw_path"):
    text = open(ctrl["raw_path"], encoding="utf-8", errors="replace").read()

def apply_patch_text(root: Path, patch_text: str):
    pat = re.compile(r"FILE\s*:?\s*(\S+)\s*\n```(?:\w*)\n(.*?)```", re.S | re.I)
    applied = []
    root = root.resolve()
    for m in pat.finditer(patch_text or ""):
        rel = m.group(1).strip().strip("`").lstrip("./")
        if not rel or rel in (":", "-", "path"):
            continue
        for prefix in ("projects/kv/", "kv/"):
            if rel.startswith(prefix):
                rel = rel[len(prefix):]
        if ".." in rel or rel.startswith("/"):
            continue
        dest = (root / rel).resolve()
        if not str(dest).startswith(str(root)):
            continue
        body = m.group(2)
        if not body.endswith("\n"):
            body += "\n"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(body, encoding="utf-8")
        applied.append(rel)
        print(f"act: applied {rel} ({len(body)} bytes)")
    if not applied and "(define" in (patch_text or "") and "kv:" in (patch_text or ""):
        body = re.sub(r"^```\w*\n", "", patch_text)
        body = re.sub(r"\n```\s*$", "", body)
        if not body.endswith("\n"):
            body += "\n"
        (root / "lib/kv.aura").write_text(body)
        applied.append("lib/kv.aura")
        print("act: applied lib/kv.aura (fallback)")
    return applied

# load full raw for FILE blocks (often outside PATCH-only)
raw_path = ctrl.get("raw_path")
blob = open(raw_path, encoding="utf-8", errors="replace").read() if raw_path else (text or "")
applied = apply_patch_text(root, blob)
if not applied:
    sys.exit(3)
print(f"act: files_applied={len(applied)}")
PY
act_rc=$?
if [[ "$act_rc" -ne 0 ]]; then
  echo "RESULT fail project-evolve reason=no-patch"
  exit 1
fi

echo "======== [4/5] VERIFY (smoke + load-sim on sandbox) ========"
NEW_LOG="$(mktemp)"
read -r NEW_RC NEW_SCORE NEW_TOTAL < <(run_tests "$SANDBOX" "$NEW_LOG" smoke.aura)
echo "[verify] smoke=$NEW_SCORE/$NEW_TOTAL rc=$NEW_RC"
tail -n 15 "$NEW_LOG" || true

NEW_LOAD_LOG="$(mktemp)"
NEW_LOAD_SCORE="0"
if [[ -f "$SANDBOX/tests/load-sim.aura" ]]; then
  read -r _NLRC _NLS _NLT < <(run_tests "$SANDBOX" "$NEW_LOAD_LOG" load-sim.aura)
  NEW_LOAD_SCORE="$(parse_load_score "$NEW_LOAD_LOG")"
  echo "[verify] load_score=$NEW_LOAD_SCORE load_tests=${_NLS:-?}/${_NLT:-?}"
  tail -n 20 "$NEW_LOAD_LOG" || true
fi

ACCEPT=0
REASON="regress-or-no-gain"
# Hard gate: smoke must not regress; prefer full-green floor
SMOKE_OK=0
if [[ "$NEW_TOTAL" -gt 0 && "$NEW_SCORE" -eq "$NEW_TOTAL" && "$NEW_SCORE" -ge "$BASE_SCORE" ]]; then
  SMOKE_OK=1
elif [[ "$NEW_TOTAL" -gt 0 && "$NEW_SCORE" -gt "$BASE_SCORE" ]]; then
  SMOKE_OK=1
fi

load_ge() {
  # awk numeric compare a >= b
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a+0 >= b+0) }'
}
load_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a+0 > b+0) }'
}

if [[ "$SMOKE_OK" -eq 1 ]]; then
  if load_gt "$NEW_LOAD_SCORE" "$BASE_LOAD_SCORE"; then
    ACCEPT=1; REASON="load-improved"
  elif [[ "$NEW_SCORE" -gt "$BASE_SCORE" ]]; then
    ACCEPT=1; REASON="score-improved"
  elif [[ "$NEW_SCORE" -eq "$NEW_TOTAL" && "$NEW_SCORE" -gt "$BASE_TOTAL" ]]; then
    ACCEPT=1; REASON="smoke-expanded"
  elif load_ge "$NEW_LOAD_SCORE" "$BASE_LOAD_SCORE"; then
    # full smoke + load not worse: accept structure/policy edits
    if ! diff -rq "$PROJ/lib" "$SANDBOX/lib" >/dev/null 2>&1 \
      || ! diff -q "$PROJ/tests/load-sim.aura" "$SANDBOX/tests/load-sim.aura" >/dev/null 2>&1; then
      ACCEPT=1; REASON="full-green-adaptive-refactor"
    else
      REASON="no-change"
    fi
  else
    REASON="load-regress"
  fi
else
  if [[ "$NEW_TOTAL" -eq 0 ]]; then
    REASON="smoke-load-fail"
  else
    REASON="smoke-regress"
  fi
fi

echo "======== [5/5] MEMORY (accept/reject + journal) ========"
if [[ "$ACCEPT" -ne 1 ]]; then
  cp -f "$NEW_LOG" "$LAST_FAIL"
  python3 - "$STATE" "$JOURNAL" "$LAST_CTRL" "$BASE_SCORE" "$BASE_TOTAL" "$NEW_SCORE" "$NEW_TOTAL" "$REASON" \
    "$BASE_LOAD_SCORE" "$NEW_LOAD_SCORE" <<'PY'
import json, sys
from datetime import datetime, timezone
path, journal, ctrlp, bs, bt, ns, nt, reason, bls, nls = sys.argv[1:11]
st = json.load(open(path))
ctrl = json.load(open(ctrlp))
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
row = {
    "ts": now,
    "phase": "control-loop",
    "generation": int(st.get("generation") or 0),
    "accepted": False,
    "reason": reason,
    "baseline": f"{bs}/{bt}",
    "candidate": f"{ns}/{nt}",
    "load_baseline": bls,
    "load_candidate": nls,
    "review": (ctrl.get("review") or "")[:500],
    "direction": (ctrl.get("direction") or "")[:500],
}
st.setdefault("history", []).append(row)
st["history"] = st["history"][-100:]
st["status"] = "rejected"
st["updated"] = now
st["best_load_score"] = st.get("best_load_score", bls)
st["last_review"] = (ctrl.get("review") or "")[:2000]
st["last_direction"] = (ctrl.get("direction") or "")[:1000]
json.dump(st, open(path, "w"), indent=2)
open(journal, "a").write(json.dumps(row, ensure_ascii=False) + "\n")
print("memory: rejected", reason, "load", bls, "->", nls)
PY
  echo "RESULT pass project-evolve soft-reject reason=$REASON smoke=$NEW_SCORE/$NEW_TOTAL load=$NEW_LOAD_SCORE baseline_load=$BASE_LOAD_SCORE"
  exit 0
fi

# Promote sandbox → project (actuator commit to workspace)
while IFS= read -r -d '' f; do
  rel="${f#"$SANDBOX/"}"
  case "$rel" in
    lib/*|tests/*|SPEC.md|README.md)
      mkdir -p "$PROJ/$(dirname "$rel")"
      cp -f "$f" "$PROJ/$rel"
      ;;
  esac
done < <(find "$SANDBOX" -type f -print0)

python3 - "$STATE" "$JOURNAL" "$LAST_CTRL" "$BASE_SCORE" "$BASE_TOTAL" "$NEW_SCORE" "$NEW_TOTAL" "$REASON" \
  "$BASE_LOAD_SCORE" "$NEW_LOAD_SCORE" <<'PY'
import json, sys
from datetime import datetime, timezone
path, journal, ctrlp, bs, bt, ns, nt, reason, bls, nls = sys.argv[1:11]
st = json.load(open(path))
ctrl = json.load(open(ctrlp))
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
gen = int(st.get("generation") or 0) + 1
row = {
    "ts": now,
    "phase": "control-loop",
    "generation": gen,
    "accepted": True,
    "reason": reason,
    "baseline": f"{bs}/{bt}",
    "candidate": f"{ns}/{nt}",
    "load_baseline": bls,
    "load_candidate": nls,
    "review": (ctrl.get("review") or "")[:500],
    "direction": (ctrl.get("direction") or "")[:500],
}
st["generation"] = gen
st["best_score"] = int(ns)
st["best_total"] = int(nt)
try:
    st["best_load_score"] = max(float(st.get("best_load_score") or 0), float(nls or 0))
except Exception:
    st["best_load_score"] = nls
st["status"] = "ok"
st["updated"] = now
st["last_review"] = (ctrl.get("review") or "")[:2000]
st["last_direction"] = (ctrl.get("direction") or "")[:1000]
st.setdefault("history", []).append(row)
st["history"] = st["history"][-100:]
json.dump(st, open(path, "w"), indent=2)
open(journal, "a").write(json.dumps(row, ensure_ascii=False) + "\n")
print(f"memory: accepted gen={gen} smoke={ns}/{nt} load={nls}")
PY

echo "RESULT pass project-evolve generation=$(python3 -c 'import json;print(json.load(open("'"$STATE"'"))["generation"])') smoke=$NEW_SCORE/$NEW_TOTAL load=$NEW_LOAD_SCORE reason=$REASON"

if [[ "$GIT_COMMIT" != "1" ]]; then
  echo "git: commit skipped"
  exit 0
fi

git add "$PROJ_REL" 2>/dev/null || true
if git diff --cached --quiet; then
  echo "git: nothing staged"
  exit 0
fi

git commit -m "$(cat <<EOF
project(kv): adaptive gen → smoke ${NEW_SCORE}/${NEW_TOTAL} load ${NEW_LOAD_SCORE} (${REASON})

Load-driven engine/policy evolve; smoke floor + load-sim fitness accepted.
EOF
)" || true
echo "git: $(git log -1 --oneline)"

if [[ "$GIT_PUSH" == "1" ]]; then
  if git push origin HEAD 2>&1; then
    echo "git: pushed $(git rev-parse --short HEAD) → origin"
  else
    echo "git: push failed (non-fatal)" >&2
  fi
fi

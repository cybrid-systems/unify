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
  local apath="$work/lib:${AURA_PATH:-$ROOT/../aura-grok/lib:$ROOT/lib}"
  set +e
  AURA_PATH="$apath" AURA_BIN="$AURA_BIN" AURA_SANDBOX="$AURA_SANDBOX" \
    "$AURA_BIN" <"$work/tests/smoke.aura" >"$logf" 2>&1
  local rc=$?
  set -e
  local score=0 total=0
  if grep -qE 'SCORE [0-9]+/[0-9]+' "$logf"; then
    score="$(grep -oE 'SCORE [0-9]+/[0-9]+' "$logf" | tail -n1 | awk '{print $2}' | cut -d/ -f1)"
    total="$(grep -oE 'SCORE [0-9]+/[0-9]+' "$logf" | tail -n1 | awk '{print $2}' | cut -d/ -f2)"
  fi
  echo "$rc $score $total"
}

echo "======== [1/5] OBSERVE (Aura tests) ========"
BASE_LOG="$(mktemp)"
read -r BASE_RC BASE_SCORE BASE_TOTAL < <(run_tests "$PROJ" "$BASE_LOG")
echo "[observe] score=$BASE_SCORE/$BASE_TOTAL rc=$BASE_RC project=$PROJ_REL"
if [[ "$BASE_TOTAL" -eq 0 ]]; then
  echo "error: tests produced no SCORE" >&2
  tail -n 40 "$BASE_LOG" || true
  exit 1
fi
cp -f "$BASE_LOG" "$EVOLVE_DIR/last-observe.log"

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
  --memory "$JOURNAL" \
  --source lib/kv.aura \
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

echo "======== [4/5] VERIFY (Aura tests on sandbox) ========"
NEW_LOG="$(mktemp)"
read -r NEW_RC NEW_SCORE NEW_TOTAL < <(run_tests "$SANDBOX" "$NEW_LOG")
echo "[verify] score=$NEW_SCORE/$NEW_TOTAL rc=$NEW_RC"
tail -n 20 "$NEW_LOG" || true

ACCEPT=0
REASON="regress-or-no-gain"
if [[ "$NEW_TOTAL" -gt 0 && "$NEW_SCORE" -gt "$BASE_SCORE" ]]; then
  ACCEPT=1; REASON="score-improved"
elif [[ "$NEW_TOTAL" -gt 0 && "$NEW_SCORE" -eq "$NEW_TOTAL" && "$NEW_SCORE" -ge "$BASE_SCORE" ]]; then
  ACCEPT=1; REASON="full-green"
elif [[ "$NEW_TOTAL" -gt 0 && "$NEW_SCORE" -eq "$BASE_SCORE" && "$NEW_SCORE" -eq "$BASE_TOTAL" ]]; then
  # already full; accept only if sources changed meaningfully toward next phase
  if ! diff -q "$PROJ/lib/kv.aura" "$SANDBOX/lib/kv.aura" >/dev/null 2>&1; then
    ACCEPT=1; REASON="full-green-refactor"
  else
    REASON="no-change"
  fi
fi

echo "======== [5/5] MEMORY (accept/reject + journal) ========"
if [[ "$ACCEPT" -ne 1 ]]; then
  cp -f "$NEW_LOG" "$LAST_FAIL"
  python3 - "$STATE" "$JOURNAL" "$LAST_CTRL" "$BASE_SCORE" "$BASE_TOTAL" "$NEW_SCORE" "$NEW_TOTAL" "$REASON" <<'PY'
import json, sys
from datetime import datetime, timezone
path, journal, ctrlp, bs, bt, ns, nt, reason = sys.argv[1:9]
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
    "review": (ctrl.get("review") or "")[:500],
    "direction": (ctrl.get("direction") or "")[:500],
}
st.setdefault("history", []).append(row)
st["history"] = st["history"][-100:]
st["status"] = "rejected"
st["updated"] = now
st["last_review"] = (ctrl.get("review") or "")[:2000]
st["last_direction"] = (ctrl.get("direction") or "")[:1000]
json.dump(st, open(path, "w"), indent=2)
open(journal, "a").write(json.dumps(row, ensure_ascii=False) + "\n")
print("memory: rejected", reason)
PY
  echo "RESULT pass project-evolve soft-reject reason=$REASON score=$NEW_SCORE/$NEW_TOTAL baseline=$BASE_SCORE/$BASE_TOTAL"
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

python3 - "$STATE" "$JOURNAL" "$LAST_CTRL" "$BASE_SCORE" "$BASE_TOTAL" "$NEW_SCORE" "$NEW_TOTAL" "$REASON" <<'PY'
import json, sys
from datetime import datetime, timezone
path, journal, ctrlp, bs, bt, ns, nt, reason = sys.argv[1:9]
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
    "review": (ctrl.get("review") or "")[:500],
    "direction": (ctrl.get("direction") or "")[:500],
}
st["generation"] = gen
st["best_score"] = int(ns)
st["best_total"] = int(nt)
st["status"] = "ok"
st["updated"] = now
st["last_review"] = (ctrl.get("review") or "")[:2000]
st["last_direction"] = (ctrl.get("direction") or "")[:1000]
st.setdefault("history", []).append(row)
st["history"] = st["history"][-100:]
json.dump(st, open(path, "w"), indent=2)
open(journal, "a").write(json.dumps(row, ensure_ascii=False) + "\n")
print(f"memory: accepted gen={gen} score={ns}/{nt}")
PY

echo "RESULT pass project-evolve generation=$(python3 -c 'import json;print(json.load(open("'"$STATE"'"))["generation"])') score=$NEW_SCORE/$NEW_TOTAL reason=$REASON"

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
project(kv): controller gen → ${NEW_SCORE}/${NEW_TOTAL} (${REASON})

LLM review+direction+patch; Aura tests verified; accepted by control loop.
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

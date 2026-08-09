#!/usr/bin/env bash
# Project-level self-evolution: SPEC → LLM multi-file patch → test → keep/commit/push.
#
#   ./scripts/project-evolve.sh [projects/kv]
#
# Unlike durable-evolve (single pure function axes), this evolves a *software project*
# under a fixed test suite — e.g. implement/improve a KV store.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJ_REL="${1:-projects/kv}"
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
LAST_PATCH="$EVOLVE_DIR/last-patch.md"

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
  "history": []
}
JSON
fi

run_tests() {
  local work="$1"
  local logf="$2"
  local path_extra="$work/lib"
  # Also allow unify lib if project wants it later
  local apath="$path_extra:${AURA_PATH:-$ROOT/../aura-grok/lib:$ROOT/lib}"
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

# Baseline test on current tree
BASE_LOG="$(mktemp)"
read -r BASE_RC BASE_SCORE BASE_TOTAL < <(run_tests "$PROJ" "$BASE_LOG")
echo "[project-evolve] baseline score=$BASE_SCORE/$BASE_TOTAL rc=$BASE_RC ($PROJ_REL)"
if [[ "$BASE_TOTAL" -eq 0 ]]; then
  echo "error: tests produced no SCORE line" >&2
  tail -n 40 "$BASE_LOG" || true
  exit 1
fi

# Gather context for LLM
SPEC="$(cat "$PROJ/SPEC.md")"
KV_SRC=""
if [[ -f "$PROJ/lib/kv.aura" ]]; then
  KV_SRC="$(cat "$PROJ/lib/kv.aura")"
fi
FAIL_TAIL="$(tail -n 60 "$BASE_LOG")"
GEN="$(python3 -c 'import json;print(json.load(open("'"$STATE"'")).get("generation",0))')"

# Propose patch via MiniMax
if [[ ! -f "${MINIMAX_KEY_FILE:-$HOME/code/keys/minimax}" ]]; then
  echo "error: MiniMax key required for project-evolve" >&2
  exit 1
fi
# shellcheck disable=SC1091
source ./scripts/env-minimax.sh

PROPOSAL="$(python3 - "$SPEC" "$KV_SRC" "$FAIL_TAIL" "$BASE_SCORE" "$BASE_TOTAL" "$GEN" <<'PY'
import json, os, sys, urllib.request
from pathlib import Path

spec, src, fail_tail, score, total, gen = sys.argv[1:7]
key_file = os.environ.get("MINIMAX_KEY_FILE") or str(Path.home() / "code/keys/minimax")
raw = open(key_file).read().strip()
key = raw.split("=", 1)[1] if "=" in raw else raw
base = os.environ.get("LLM_BASE_URL", "https://api.minimaxi.com/v1").rstrip("/")
model = os.environ.get("LLM_MODEL", "MiniMax-M3")

system = """You are evolving a mini KV store project written in Aura (Scheme-like).
Return a multi-file patch that IMPROVES the implementation against the SPEC and tests.

Output format ONLY (no markdown fences around the whole answer):

FILE path/relative/to/project
```
full new file contents
```

You may emit multiple FILE blocks. Prefer editing lib/kv.aura.
Do not invent new test harness protocol: keep SCORE n/m and RESULT lines.
Use pure Aura; avoid set! if you can use functional store updates.
Keep exports listed at top before defines if you use (export ...).
Implement missing ops (del/keys/size/clear) when tests fail.
Generation context: improve score without regressions."""

user = f"""PROJECT generation={gen} current_score={score}/{total}

# SPEC
{spec}

# CURRENT lib/kv.aura
{src}

# LAST TEST OUTPUT (tail)
{fail_tail}

Emit FILE blocks to raise SCORE. Full file contents for each changed file.
"""

payload = {
    "model": model,
    "temperature": 0.3,
    "messages": [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ],
}
req = urllib.request.Request(
    f"{base}/chat/completions",
    data=json.dumps(payload).encode(),
    headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=180) as resp:
    content = json.load(resp)["choices"][0]["message"]["content"]
print(content)
PY
)"

printf '%s\n' "$PROPOSAL" >"$LAST_PATCH"
echo "[project-evolve] proposal saved $LAST_PATCH ($(wc -c <"$LAST_PATCH") bytes)"

# Parse FILE blocks into sandbox
SANDBOX="$(mktemp -d /tmp/unify-proj-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
cp -a "$PROJ/." "$SANDBOX/"

python3 - "$SANDBOX" "$LAST_PATCH" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
text = Path(sys.argv[2]).read_text(encoding="utf-8", errors="replace")
# Patterns:
# FILE path\n```\n...\n```
# or FILE: path
pat = re.compile(
    r"FILE\s*:?\s*(\S+)\s*\n```(?:\w*)\n(.*?)```",
    re.S | re.I,
)
n = 0
for m in pat.finditer(text):
    rel = m.group(1).strip().strip("`").lstrip("./")
    if not rel or rel in (":", "-", "path"):
        continue
    # strip project prefix if model included it
    for prefix in ("projects/kv/", "kv/"):
        if rel.startswith(prefix):
            rel = rel[len(prefix):]
    # only allow safe relative paths under project
    if ".." in rel or rel.startswith("/"):
        print(f"skip unsafe path:{rel}")
        continue
    body = m.group(2)
    if not body.endswith("\n"):
        body += "\n"
    dest = (root / rel).resolve()
    if not str(dest).startswith(str(root.resolve())):
        print(f"skip escaped path:{rel}")
        continue
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(body, encoding="utf-8")
    print(f"applied sandbox:{rel} ({len(body)} bytes)")
    n += 1
if n == 0:
    # fallback: if entire response looks like aura file, write lib/kv.aura
    if "(define" in text and "kv:" in text:
        # strip markdown fences
        body = text
        body = re.sub(r"^```\w*\n", "", body)
        body = re.sub(r"\n```\s*$", "", body)
        (root / "lib/kv.aura").write_text(body if body.endswith("\n") else body + "\n")
        print("applied sandbox:lib/kv.aura (fallback whole response)")
        n = 1
if n == 0:
    sys.exit(3)
print(f"files_applied={n}")
PY
apply_rc=$?
if [[ "$apply_rc" -ne 0 ]]; then
  echo "error: could not parse any FILE patch from LLM" >&2
  head -c 800 "$LAST_PATCH" || true
  echo "RESULT fail project-evolve reason=no-patch"
  exit 1
fi

NEW_LOG="$(mktemp)"
read -r NEW_RC NEW_SCORE NEW_TOTAL < <(run_tests "$SANDBOX" "$NEW_LOG")
echo "[project-evolve] candidate score=$NEW_SCORE/$NEW_TOTAL rc=$NEW_RC"
tail -n 25 "$NEW_LOG" || true

# Accept if score improved, or equal score but total same and files changed meaningfully
ACCEPT=0
if [[ "$NEW_TOTAL" -gt 0 && "$NEW_SCORE" -gt "$BASE_SCORE" ]]; then
  ACCEPT=1
  REASON="score-improved"
elif [[ "$NEW_TOTAL" -gt 0 && "$NEW_SCORE" -eq "$BASE_SCORE" && "$NEW_SCORE" -eq "$NEW_TOTAL" && "$BASE_SCORE" -lt "$BASE_TOTAL" ]]; then
  # full pass when baseline was not full
  ACCEPT=1
  REASON="full-pass"
elif [[ "$NEW_TOTAL" -gt 0 && "$NEW_SCORE" -eq "$NEW_TOTAL" && "$NEW_SCORE" -ge "$BASE_SCORE" ]]; then
  ACCEPT=1
  REASON="full-green"
else
  REASON="regress-or-no-gain"
fi

if [[ "$ACCEPT" -ne 1 ]]; then
  cp -f "$NEW_LOG" "$LAST_FAIL"
  python3 - "$STATE" "$JOURNAL" "$BASE_SCORE" "$BASE_TOTAL" "$NEW_SCORE" "$NEW_TOTAL" "$REASON" <<'PY'
import json, sys
from datetime import datetime, timezone
path, journal, bs, bt, ns, nt, reason = sys.argv[1:8]
st = json.load(open(path))
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
row = {
    "ts": now,
    "generation": int(st.get("generation") or 0),
    "accepted": False,
    "reason": reason,
    "baseline": f"{bs}/{bt}",
    "candidate": f"{ns}/{nt}",
}
st.setdefault("history", []).append(row)
st["history"] = st["history"][-100:]
st["status"] = "rejected"
st["updated"] = now
json.dump(st, open(path, "w"), indent=2)
open(journal, "a").write(json.dumps(row) + "\n")
print("rejected:", reason)
PY
  echo "RESULT fail project-evolve reason=$REASON score=$NEW_SCORE/$NEW_TOTAL baseline=$BASE_SCORE/$BASE_TOTAL"
  # Still "pass" harness step only if we want continuous not to fail every gen —
  # project evolution often rejects; use soft RESULT for continuous:
  echo "RESULT pass project-evolve soft-reject reason=$REASON"
  exit 0
fi

# Promote sandbox → project
if [[ -f "$SANDBOX/lib/kv.aura" ]]; then
  cp -f "$SANDBOX/lib/kv.aura" "$PROJ/lib/kv.aura"
fi
# copy any other applied files under lib/ or tests/ carefully
while IFS= read -r -d '' f; do
  rel="${f#"$SANDBOX/"}"
  case "$rel" in
    lib/*|tests/*|SPEC.md|README.md)
      mkdir -p "$PROJ/$(dirname "$rel")"
      cp -f "$f" "$PROJ/$rel"
      ;;
  esac
done < <(find "$SANDBOX" -type f -print0)

python3 - "$STATE" "$JOURNAL" "$BASE_SCORE" "$BASE_TOTAL" "$NEW_SCORE" "$NEW_TOTAL" "$REASON" <<'PY'
import json, sys
from datetime import datetime, timezone
path, journal, bs, bt, ns, nt, reason = sys.argv[1:8]
st = json.load(open(path))
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
gen = int(st.get("generation") or 0) + 1
row = {
    "ts": now,
    "generation": gen,
    "accepted": True,
    "reason": reason,
    "baseline": f"{bs}/{bt}",
    "candidate": f"{ns}/{nt}",
}
st["generation"] = gen
st["best_score"] = int(ns)
st["best_total"] = int(nt)
st["status"] = "ok"
st["updated"] = now
st.setdefault("history", []).append(row)
st["history"] = st["history"][-100:]
json.dump(st, open(path, "w"), indent=2)
open(journal, "a").write(json.dumps(row) + "\n")
print(f"accepted gen={gen} score={ns}/{nt} reason={reason}")
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
project(kv): gen improve score ${NEW_SCORE}/${NEW_TOTAL} (${REASON})

Project-level self-evolution of mini KV store under tests/smoke.aura.
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

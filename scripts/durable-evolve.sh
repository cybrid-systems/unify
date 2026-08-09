#!/usr/bin/env bash
# Durable self-evolution: advance a pure-Aura subject, persist, git commit.
#
# Why this exists:
#   examples/02-live-evolve only mutates *in-memory* for one process — no file, no git.
#   This script is the real accumulation path:
#     notes/evolve-state/state.json  +  journal  +  git commit
#
# Ladder: factor 2 → 3 → 5 → 7 → 9 → …
# Body form: (lambda (x) (* x K))  verified on samples 0,4,7.
#
#   ./scripts/durable-evolve.sh
#   UNIFY_GIT_COMMIT=0 ./scripts/durable-evolve.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

STATE_DIR="$ROOT/notes/evolve-state"
STATE_FILE="$STATE_DIR/state.json"
JOURNAL="$STATE_DIR/journal.jsonl"
mkdir -p "$STATE_DIR"

GIT_COMMIT="${UNIFY_GIT_COMMIT:-1}"
export AURA_BIN="${AURA_BIN:-$ROOT/../aura-grok/build/aura}"
export AURA_PATH="${AURA_PATH:-$ROOT/../aura-grok/lib:$ROOT/../aether/lib:$ROOT/../hephaestus/lib:$ROOT/../prometheus/lib:$ROOT/../hermes/lib:$ROOT/lib}"
export AURA_SANDBOX="${AURA_SANDBOX:-off}"
export AURA_PIPELINE_STRICT="${AURA_PIPELINE_STRICT:-0}"

if [[ ! -x "$AURA_BIN" ]]; then
  echo "error: AURA_BIN not executable: $AURA_BIN" >&2
  exit 1
fi

if [[ ! -f "$STATE_FILE" ]]; then
  cat >"$STATE_FILE" <<'JSON'
{
  "generation": 0,
  "factor": 2,
  "body": "(lambda (x) (* x 2))",
  "status": "init",
  "history": []
}
JSON
fi

# Resolve next factor + propose body (rule is source of truth; LLM optional)
PROPOSE_JSON="$(python3 - "$STATE_FILE" <<'PY'
import json, os, re, sys, urllib.request
from pathlib import Path

st = json.load(open(sys.argv[1]))
factor = int(st.get("factor") or 2)
body = st.get("body") or "(lambda (x) (* x 2))"
gen = int(st.get("generation") or 0)
nxt = 3 if factor < 3 else factor + 2
rule = f"(lambda (x) (* x {nxt}))"
prop = rule
source = "rule"

# Optional MiniMax propose — must extract exact lambda with numeric factor
key_file = os.environ.get("MINIMAX_KEY_FILE") or str(Path.home() / "code/keys/minimax")
force = os.environ.get("UNIFY_EVOLVE_FORCE_BODY") or ""
if force.strip():
    prop = force.strip()
    source = "force"
elif os.path.isfile(key_file) and os.environ.get("UNIFY_EVOLVE_LLM", "1") == "1":
    raw = open(key_file).read().strip()
    key = raw.split("=", 1)[1] if "=" in raw else raw
    payload = {
        "model": os.environ.get("LLM_MODEL", "MiniMax-M3"),
        "temperature": 0,
        "messages": [
            {
                "role": "system",
                "content": (
                    "Output EXACTLY one line and nothing else:\n"
                    f"BODY|(lambda (x) (* x {nxt}))\n"
                    "No markdown, no thinking, no explanation."
                ),
            },
            {
                "role": "user",
                "content": f"N={nxt}. Emit BODY|(lambda (x) (* x {nxt})) only.",
            },
        ],
    }
    base = os.environ.get("LLM_BASE_URL", "https://api.minimaxi.com/v1").rstrip("/")
    req = urllib.request.Request(
        f"{base}/chat/completions",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = json.load(resp)
        content = data["choices"][0]["message"]["content"]
        # Prefer BODY| line
        chosen = None
        for line in content.splitlines():
            line = line.strip()
            if line.startswith("BODY|"):
                chosen = line[5:].strip()
                break
        if not chosen:
            m = re.search(r"\(lambda\s*\(\s*x\s*\)\s*\(\s*\*\s*x\s*" + str(nxt) + r"\s*\)\s*\)", content)
            if m:
                chosen = m.group(0)
        # Accept only pure multiply-by-N form
        if chosen and re.fullmatch(
            r"\(lambda\s*\(\s*x\s*\)\s*\(\s*\*\s*x\s*" + str(nxt) + r"\s*\)\s*\)",
            chosen.strip(),
        ):
            prop = chosen.strip()
            source = "llm"
        else:
            prop = rule
            source = "rule-fallback"
    except Exception as e:
        prop = rule
        source = f"rule-error:{type(e).__name__}"

print(json.dumps({
    "generation": gen,
    "factor": factor,
    "next_factor": nxt,
    "cur_body": body,
    "prop_body": prop,
    "source": source,
}))
PY
)"

CUR_GEN="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["generation"])' "$PROPOSE_JSON")"
CUR_FACTOR="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["factor"])' "$PROPOSE_JSON")"
NEXT_FACTOR="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["next_factor"])' "$PROPOSE_JSON")"
CUR_BODY="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["cur_body"])' "$PROPOSE_JSON")"
PROP_BODY="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["prop_body"])' "$PROPOSE_JSON")"
SOURCE="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["source"])' "$PROPOSE_JSON")"

echo "[durable-evolve] gen=$CUR_GEN factor=$CUR_FACTOR -> $NEXT_FACTOR source=$SOURCE"
echo "[durable-evolve] cur=$CUR_BODY"
echo "[durable-evolve] prop=$PROP_BODY"

# Escape for Aura string literals
esc() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1])[1:-1])' "$1"; }
EBODY="$(esc "$CUR_BODY")"
EPROP="$(esc "$PROP_BODY")"

TMP_AURA="$(mktemp /tmp/unify-durable-XXXXXX.aura)"
TMP_LOG="$(mktemp /tmp/unify-durable-XXXXXX.log)"
trap 'rm -f "$TMP_AURA" "$TMP_LOG"' EXIT

cat >"$TMP_AURA" <<EOF
(require "unify-min" all:)
(unify:stats-reset!)
(define cur-body "$EBODY")
(define prop-body "$EPROP")
(define next-factor $NEXT_FACTOR)

(display "=== durable-evolve install+rebind+verify ===")
(newline)

(define ok-install
  (unify:install-subject (string-append "(define score " cur-body ")")))

(define (verify-factor k)
  (and (= (unify:observe-score 0) 0)
       (= (unify:observe-score 7) (* 7 k))
       (= (unify:observe-score 4) (* 4 k))))

(if (not ok-install)
  (begin (display "RESULT fail durable-evolve reason=install") (newline))
  (begin
    (display "R0 score(7)=") (display (unify:observe-score 7)) (newline)
    (if (verify-factor next-factor)
      (begin
        (display "DURABLE_BODY ") (display cur-body) (newline)
        (display "DURABLE_FACTOR ") (display next-factor) (newline)
        (display "DURABLE_DECISION already") (newline)
        (display "RESULT pass durable-evolve factor=")
        (display next-factor) (display " decision=already") (newline))
      (let ((rb (unify:rebind-safe "score" prop-body "durable-evolve")))
        (display "rebind=") (write rb) (newline)
        (if (not (unify:alist-ref ":ok" rb #f))
          (begin (display "RESULT fail durable-evolve reason=rebind") (newline))
          (if (verify-factor next-factor)
            (begin
              (display "DURABLE_BODY ") (display prop-body) (newline)
              (display "DURABLE_FACTOR ") (display next-factor) (newline)
              (display "DURABLE_DECISION commit") (newline)
              (display "score(7)=") (display (unify:observe-score 7)) (newline)
              (display "RESULT pass durable-evolve factor=")
              (display next-factor) (display " decision=commit") (newline))
            (begin
              (display "score(7)=") (display (unify:observe-score 7)) (newline)
              (display "RESULT fail durable-evolve reason=verify") (newline))))))))
EOF

set +e
"$AURA_BIN" <"$TMP_AURA" >"$TMP_LOG" 2>&1
rc=$?
set -e
cat "$TMP_LOG"

if ! grep -q 'RESULT pass durable-evolve' "$TMP_LOG"; then
  cp -f "$TMP_LOG" "$STATE_DIR/last-fail.log"
  echo "RESULT fail durable-evolve"
  exit 1
fi

NEW_BODY="$(grep '^DURABLE_BODY ' "$TMP_LOG" | tail -n1 | sed 's/^DURABLE_BODY //')"
NEW_FACTOR="$(grep '^DURABLE_FACTOR ' "$TMP_LOG" | tail -n1 | sed 's/^DURABLE_FACTOR //')"
DECISION="$(grep '^DURABLE_DECISION ' "$TMP_LOG" | tail -n1 | sed 's/^DURABLE_DECISION //')"

python3 - "$STATE_FILE" "$JOURNAL" "$NEW_BODY" "$NEW_FACTOR" "$DECISION" "$CUR_GEN" "$SOURCE" <<'PY'
import json, sys
from datetime import datetime, timezone
path, journal, body, factor, decision, cur_gen, source = sys.argv[1:8]
factor = int(factor)
cur_gen = int(cur_gen)
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
st = json.load(open(path))
hist = st.get("history") or []
hist.append({
    "ts": now,
    "from_generation": cur_gen,
    "to_generation": cur_gen + 1,
    "factor": factor,
    "body": body,
    "decision": decision,
    "source": source,
})
st = {
    "generation": cur_gen + 1,
    "factor": factor,
    "body": body,
    "status": "ok",
    "updated": now,
    "last_decision": decision,
    "last_source": source,
    "history": hist[-50:],
}
json.dump(st, open(path, "w"), indent=2)
with open(journal, "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "ts": now, "generation": st["generation"], "factor": factor,
        "decision": decision, "source": source, "body": body,
    }, ensure_ascii=False) + "\n")
print(f"state: generation={st['generation']} factor={factor} decision={decision} source={source}")
PY

cat >"$STATE_DIR/README.md" <<EOF
# Evolve state (durable subject)

| field | value |
|-------|-------|
| updated | $(date -u +%Y-%m-%dT%H:%MZ) |
| generation | $(python3 -c 'import json;print(json.load(open("'"$STATE_FILE"'"))["generation"])') |
| factor | $NEW_FACTOR |
| body | \`$NEW_BODY\` |
| decision | $DECISION |
| source | $SOURCE |

**This is real self-evolution state.**  
\`examples/02-live-evolve\` is only in-memory soak (no file / no git).

Advance: \`./scripts/durable-evolve.sh\` (also each continuous cycle).
EOF

echo "RESULT pass durable-evolve generation=$((CUR_GEN + 1)) factor=$NEW_FACTOR decision=$DECISION source=$SOURCE"

if [[ "$GIT_COMMIT" != "1" ]]; then
  echo "git: skipped (UNIFY_GIT_COMMIT=$GIT_COMMIT)"
  exit 0
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add notes/evolve-state/state.json notes/evolve-state/journal.jsonl notes/evolve-state/README.md
  if git diff --cached --quiet; then
    echo "git: nothing new to commit"
  else
    git -c user.email="${GIT_AUTHOR_EMAIL:-unify-bot@local}" \
        -c user.name="${GIT_AUTHOR_NAME:-unify-evolve}" \
        commit -m "$(cat <<EOF
evolve: generation $((CUR_GEN + 1)) factor=${NEW_FACTOR} (${DECISION}/${SOURCE})

Durable subject advanced by scripts/durable-evolve.sh.
EOF
)" || git commit -m "evolve: generation $((CUR_GEN + 1)) factor=${NEW_FACTOR} (${DECISION}/${SOURCE})"
    echo "git: committed $(git log -1 --oneline)"
    if [[ "${UNIFY_GIT_PUSH:-0}" == "1" ]]; then
      git push origin HEAD || echo "git: push failed (non-fatal)"
    fi
  fi
fi

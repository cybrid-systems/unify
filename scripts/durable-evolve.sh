#!/usr/bin/env bash
# Durable evolution: multi-candidate sandbox → select winner → persist + git commit.
#
# Model (see notes/evolution-model.md):
#   query locus → propose K local bodies → snapshot-sandbox each →
#   arbiter picks best verify/fitness → apply once → state.json + git commit
#
# Not the same as examples/02-live-evolve (in-memory smoke only).
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

# Build candidate list (JSON array of body strings) + next factor
CAND_JSON="$(python3 - "$STATE_FILE" <<'PY'
import json, os, re, sys, urllib.request
from pathlib import Path

st = json.load(open(sys.argv[1]))
factor = int(st.get("factor") or 2)
body = st.get("body") or "(lambda (x) (* x 2))"
gen = int(st.get("generation") or 0)
nxt = 3 if factor < 3 else factor + 2
rule = f"(lambda (x) (* x {nxt}))"
cands = [rule]
# alternate pure forms for small factors (local variants)
if nxt == 3:
    cands.append("(lambda (x) (+ x x x))")
if nxt == 5:
    cands.append("(lambda (x) (+ (* x 2) (* x 3)))")

force = (os.environ.get("UNIFY_EVOLVE_FORCE_BODY") or "").strip()
if force:
    cands.insert(0, force)

# Optional MiniMax candidate (strict extract)
key_file = os.environ.get("MINIMAX_KEY_FILE") or str(Path.home() / "code/keys/minimax")
if os.path.isfile(key_file) and os.environ.get("UNIFY_EVOLVE_LLM", "1") == "1":
    raw = open(key_file).read().strip()
    key = raw.split("=", 1)[1] if "=" in raw else raw
    payload = {
        "model": os.environ.get("LLM_MODEL", "MiniMax-M3"),
        "temperature": 0,
        "messages": [
            {
                "role": "system",
                "content": (
                    "Output EXACTLY one line:\n"
                    f"BODY|(lambda (x) (* x {nxt}))\n"
                    "Pure arithmetic on x only. No markdown/thinking."
                ),
            },
            {"role": "user", "content": f"N={nxt}. BODY|(lambda (x) (* x {nxt})) only."},
        ],
    }
    base = os.environ.get("LLM_BASE_URL", "https://api.minimaxi.com/v1").rstrip("/")
    req = urllib.request.Request(
        f"{base}/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            content = json.load(resp)["choices"][0]["message"]["content"]
        chosen = None
        for line in content.splitlines():
            line = line.strip()
            if line.startswith("BODY|"):
                chosen = line[5:].strip()
                break
        if not chosen:
            m = re.search(
                r"\(lambda\s*\(\s*x\s*\)\s*\(\s*\*\s*x\s*" + str(nxt) + r"\s*\)\s*\)",
                content,
            )
            if m:
                chosen = m.group(0)
        if chosen and re.fullmatch(
            r"\(lambda\s*\(\s*x\s*\)\s*\(\s*\*\s*x\s*" + str(nxt) + r"\s*\)\s*\)",
            chosen.strip(),
        ):
            cands.insert(0, chosen.strip())
    except Exception:
        pass

# de-dupe preserve order
seen, uniq = set(), []
for c in cands:
    if c not in seen:
        seen.add(c)
        uniq.append(c)

print(json.dumps({
    "generation": gen,
    "factor": factor,
    "next_factor": nxt,
    "cur_body": body,
    "candidates": uniq,
}))
PY
)"

CUR_GEN="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["generation"])' "$CAND_JSON")"
NEXT_FACTOR="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["next_factor"])' "$CAND_JSON")"
CUR_BODY="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["cur_body"])' "$CAND_JSON")"
# Write candidates as Aura list literal
CAND_AURA="$(python3 -c 'import json,sys; cs=json.loads(sys.argv[1])["candidates"]; print("(list "+", ".join(json.dumps(c) for c in cs)+")")' "$CAND_JSON")"
N_CAND="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["candidates"]))' "$CAND_JSON")"

echo "[durable-evolve] gen=$CUR_GEN -> factor=$NEXT_FACTOR candidates=$N_CAND"
echo "[durable-evolve] cur=$CUR_BODY"
echo "[durable-evolve] cands=$CAND_AURA"

esc() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1])[1:-1])' "$1"; }
EBODY="$(esc "$CUR_BODY")"

TMP_AURA="$(mktemp /tmp/unify-durable-XXXXXX.aura)"
TMP_LOG="$(mktemp /tmp/unify-durable-XXXXXX.log)"
trap 'rm -f "$TMP_AURA" "$TMP_LOG"' EXIT

cat >"$TMP_AURA" <<EOF
(require "unify-min" all:)
(unify:stats-reset!)
(define cur-body "$EBODY")
(define next-factor $NEXT_FACTOR)
(define candidates $CAND_AURA)

(display "=== durable-evolve multi-cand sandbox select ===")
(newline)
(display "mutate-version=") (display unify:mutate-version) (newline)

(define ok-install
  (unify:install-subject (string-append "(define score " cur-body ")")))

(if (not ok-install)
  (begin (display "RESULT fail durable-evolve reason=install") (newline))
  (begin
    (display "R0 score(7)=") (display (unify:observe-score 7)) (newline)
    (display "locus=") (write (unify:query-name "score")) (newline)
    (if (unify:verify-factor next-factor)
      (begin
        (display "DURABLE_BODY ") (display cur-body) (newline)
        (display "DURABLE_FACTOR ") (display next-factor) (newline)
        (display "DURABLE_DECISION already") (newline)
        (display "DURABLE_TRIED 0") (newline)
        (display "RESULT pass durable-evolve factor=")
        (display next-factor) (display " decision=already") (newline))
      (let ((sel (unify:select-candidate! "score" candidates next-factor)))
        (display "select=") (write sel) (newline)
        (display "stats=") (write (unify:stats-alist)) (newline)
        (if (unify:alist-ref ":ok" sel #f)
          (begin
            (display "DURABLE_BODY ") (display (unify:alist-ref ":body" sel "")) (newline)
            (display "DURABLE_FACTOR ") (display next-factor) (newline)
            (display "DURABLE_DECISION select") (newline)
            (display "DURABLE_TRIED ") (display (unify:alist-ref ":tried" sel 0)) (newline)
            (display "DURABLE_FIT ") (display (unify:alist-ref ":fitness" sel 0)) (newline)
            (display "score(7)=") (display (unify:observe-score 7)) (newline)
            (display "RESULT pass durable-evolve factor=")
            (display next-factor) (display " decision=select") (newline))
          (begin
            (display "RESULT fail durable-evolve reason=")
            (display (unify:alist-ref ":reason" sel "select"))
            (newline)))))))
EOF

set +e
"$AURA_BIN" <"$TMP_AURA" >"$TMP_LOG" 2>&1
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
TRIED="$(grep '^DURABLE_TRIED ' "$TMP_LOG" | tail -n1 | sed 's/^DURABLE_TRIED //' || echo 0)"

python3 - "$STATE_FILE" "$JOURNAL" "$NEW_BODY" "$NEW_FACTOR" "$DECISION" "$CUR_GEN" "$TRIED" "$N_CAND" <<'PY'
import json, sys
from datetime import datetime, timezone
path, journal, body, factor, decision, cur_gen, tried, n_cand = sys.argv[1:9]
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
    "candidates_tried": int(tried or 0),
    "candidates_n": int(n_cand or 0),
    "mode": "multi-sandbox-select",
})
st = {
    "generation": cur_gen + 1,
    "factor": factor,
    "body": body,
    "status": "ok",
    "updated": now,
    "last_decision": decision,
    "last_mode": "multi-sandbox-select",
    "history": hist[-50:],
}
json.dump(st, open(path, "w"), indent=2)
with open(journal, "a", encoding="utf-8") as f:
    f.write(json.dumps(hist[-1], ensure_ascii=False) + "\n")
print(f"state: generation={st['generation']} factor={factor} decision={decision} tried={tried}/{n_cand}")
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
| mode | multi-sandbox-select (query→mutate, K candidates) |

See \`notes/evolution-model.md\`. Entry: \`./scripts/evolve.sh\`.
EOF

echo "RESULT pass durable-evolve generation=$((CUR_GEN + 1)) factor=$NEW_FACTOR decision=$DECISION tried=${TRIED:-0}/$N_CAND"

if [[ "$GIT_COMMIT" != "1" ]]; then
  echo "git: skipped (UNIFY_GIT_COMMIT=$GIT_COMMIT)"
  exit 0
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add notes/evolve-state/state.json notes/evolve-state/journal.jsonl notes/evolve-state/README.md
  if git diff --cached --quiet; then
    echo "git: nothing new to commit"
  else
    git commit -m "$(cat <<EOF
evolve: generation $((CUR_GEN + 1)) factor=${NEW_FACTOR} (${DECISION}, multi-sandbox)

Selected winner among ${N_CAND} candidates via snapshot sandbox; local rebind only.
EOF
)" || true
    echo "git: committed $(git log -1 --oneline)"
    if [[ "${UNIFY_GIT_PUSH:-0}" == "1" ]]; then
      git push origin HEAD || echo "git: push failed (non-fatal)"
    fi
  fi
fi

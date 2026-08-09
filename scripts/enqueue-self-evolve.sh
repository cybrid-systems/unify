#!/usr/bin/env bash
# Queue a Unify-owned failure for self-evolution (never files to Aura).
#
#   ./scripts/enqueue-self-evolve.sh --log path.log --label L --cmd '...'
#
# Writes notes/self-evolve/<fp>.md and appends notes/self-evolve-queue.jsonl.
# Optional: UNIFY_SELF_EVOLVE=1 → MiniMax proposal note (not auto-applied).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOG_FILE=""
LABEL="unknown"
CMD=""
NOTES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log) LOG_FILE="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --cmd) CMD="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$LOG_FILE" || ! -f "$LOG_FILE" ]]; then
  echo "usage: $0 --log PATH [--label L] [--cmd C]" >&2
  exit 2
fi

mkdir -p notes/self-evolve
QUEUE="notes/self-evolve-queue.jsonl"
CLASSIFY_FILE="$(mktemp)"
python3 scripts/classify-failure.py \
  --log "$LOG_FILE" --label "$LABEL" --cmd "$CMD" --root "$ROOT" --notes "$NOTES" \
  >"$CLASSIFY_FILE"

FP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "$CLASSIFY_FILE")"
CLASS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["class"])' "$CLASSIFY_FILE")"
KIND="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kind"])' "$CLASSIFY_FILE")"
TITLE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["title"])' "$CLASSIFY_FILE")"
ACTION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("action",""))' "$CLASSIFY_FILE")"
SHOULD_SELF="$(python3 -c 'import json,sys; print(bool(json.load(open(sys.argv[1])).get("should_self_evolve")))' "$CLASSIFY_FILE")"

if [[ "$CLASS" != "unify-self" && "$SHOULD_SELF" != "True" && "$ACTION" != "self_evolve" ]]; then
  echo "skip-queue: class=$CLASS action=$ACTION should_self=$SHOULD_SELF"
  rm -f "$CLASSIFY_FILE"
  exit 0
fi

SAFE_FP="$(echo "$FP" | tr -cd 'a-zA-Z0-9._-')"
ENTRY="notes/self-evolve/${SAFE_FP}.md"
if [[ -f "$ENTRY" ]]; then
  echo "skip-queue: already have $ENTRY"
  rm -f "$CLASSIFY_FILE"
  exit 0
fi

python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"])' "$CLASSIFY_FILE" >"$ENTRY"

python3 - "$QUEUE" "$CLASSIFY_FILE" "$ENTRY" "$LOG_FILE" "$LABEL" "$CMD" <<'PY'
import json, sys
from datetime import datetime, timezone
from pathlib import Path

queue_path = Path(sys.argv[1])
classify = json.load(open(sys.argv[2], encoding="utf-8"))
entry, log_file, label, cmd = sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6]
row = {
    "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ"),
    "fingerprint": classify["fingerprint"],
    "class": classify["class"],
    "kind": classify["kind"],
    "title": classify["title"],
    "label": label,
    "cmd": cmd,
    "log": log_file,
    "entry": entry,
    "status": "queued",
    "reasons": classify.get("reasons", []),
}
with queue_path.open("a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
print(f"queued: {row['fingerprint']} -> {entry}")
PY

rm -f "$CLASSIFY_FILE"
echo "self-evolve entry: $ENTRY"
echo "class=$CLASS kind=$KIND action=self_evolve fingerprint=$SAFE_FP"

if [[ "${UNIFY_SELF_EVOLVE:-0}" != "1" ]]; then
  echo "tip: UNIFY_SELF_EVOLVE=1 to request MiniMax proposal (not auto-applied)"
  exit 0
fi

if [[ ! -f "${MINIMAX_KEY_FILE:-$HOME/code/keys/minimax}" ]]; then
  echo "no minimax key; entry only"
  exit 0
fi

# shellcheck disable=SC1091
source ./scripts/env-minimax.sh
PROP="notes/self-evolve/${SAFE_FP}.proposal.md"
if [[ -f "$PROP" ]]; then
  echo "proposal exists: $PROP"
  exit 0
fi

AURA_BIN="${AURA_BIN:-$ROOT/../aura-grok/build/aura}"
if [[ ! -x "$AURA_BIN" ]]; then
  echo "no aura bin for llm propose; entry only"
  exit 0
fi

export AURA_BIN
export AURA_PATH="${AURA_PATH:-$ROOT/../aura-grok/lib:$ROOT/lib}"
export AURA_SANDBOX=off
TAIL_ESC="$(tail -n 40 "$LOG_FILE" | python3 -c 'import sys; print(sys.stdin.read()[:1800].replace("\\","\\\\").replace("\"","\\\"").replace("\n","\\n"))')"

cat > /tmp/unify-self-evolve-propose.aura <<EOF
(require "std/string" all:)
(require "std/llm" all:)
(define sys "You fix Unify harness/composition bugs only (lib/*.aura, scripts/*, examples/*). Never blame Aura engine unless proven. Reply markdown: root cause, files to edit, concrete patch sketch. No secrets.")
(define usr (string-append
  "label=$LABEL kind=$KIND fp=$SAFE_FP\n"
  "cmd=$CMD\n"
  "log_tail=$TAIL_ESC"))
(define r (try (llm:chat sys usr) (catch (e) #f)))
(if (and (hash? r) (hash-ref r "ok" #f))
  (begin (display (hash-ref r "content" "")) (newline))
  (begin (display "PROPOSE_FAIL") (newline)))
EOF

set +e
OUT="$("$AURA_BIN" < /tmp/unify-self-evolve-propose.aura 2>/dev/null)"
set -e
{
  echo "# Self-evolve proposal — \`$SAFE_FP\`"
  echo
  echo "- generated: $(date -u +%Y-%m-%dT%H:%MZ)"
  echo "- status: proposal only (NOT auto-applied / NOT committed)"
  echo
  printf '%s\n' "$OUT"
} >"$PROP"
echo "proposal: $PROP"

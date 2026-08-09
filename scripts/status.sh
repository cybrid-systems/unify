#!/usr/bin/env bash
# Show continuous-run status and recent failures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_ROOT="${UNIFY_LOG_ROOT:-$ROOT/logs/runs}"
LATEST="$LOG_ROOT/latest"

echo "=== Unify continuous status ==="
echo "log_root: $LOG_ROOT"

if [[ -f "$ROOT/projects/kv/evolve/state.json" ]]; then
  echo "project(kv):"
  python3 -c '
import json
s=json.load(open("'"$ROOT"'/projects/kv/evolve/state.json"))
print("  gen=%s best=%s/%s status=%s" % (s.get("generation"), s.get("best_score"), s.get("best_total"), s.get("status")))
' 2>/dev/null || true
fi
if [[ -f "$ROOT/notes/evolve-state/state.json" ]]; then
  echo "function-axis explore (legacy):"
  python3 -c '
import json
s=json.load(open("'"$ROOT"'/notes/evolve-state/state.json"))
print("  mode=%s gen=%s last=%s/%s" % (s.get("mode"), s.get("generation"), s.get("last_axis"), s.get("last_span")))
' 2>/dev/null || true
fi

if [[ ! -e "$LATEST" ]]; then
  echo "no run yet (missing $LATEST)"
  exit 1
fi

RUN_DIR="$(readlink -f "$LATEST" 2>/dev/null || readlink "$LATEST" 2>/dev/null || echo "$LATEST")"
echo "latest: $RUN_DIR"

if [[ -f "$RUN_DIR/pid" ]]; then
  pid="$(cat "$RUN_DIR/pid")"
  if kill -0 "$pid" 2>/dev/null; then
    echo "state: RUNNING pid=$pid"
  else
    echo "state: STALE pid=$pid (not running)"
  fi
else
  echo "state: not running (no pid file)"
fi

if [[ -f "$RUN_DIR/status.txt" ]]; then
  echo "status: $(cat "$RUN_DIR/status.txt")"
fi

echo
echo "--- last 15 master lines ---"
tail -n 15 "$RUN_DIR/master.log" 2>/dev/null || echo "(no master.log)"

echo
echo "--- last 8 events ---"
tail -n 8 "$RUN_DIR/events.jsonl" 2>/dev/null || echo "(no events)"

echo
echo "--- failures ---"
if [[ -d "$RUN_DIR/failures" ]] && compgen -G "$RUN_DIR/failures/*" >/dev/null 2>&1; then
  ls -lt "$RUN_DIR/failures" | head -n 20
else
  echo "(none)"
fi

if [[ -f "$LOG_ROOT/STOP" ]]; then
  echo
  echo "NOTE: STOP file present at $LOG_ROOT/STOP"
fi

echo
echo "--- recent Aura issue filings (drafts with .url) ---"
draft_dir="$ROOT/notes/issue-drafts"
if compgen -G "$draft_dir"/*.url >/dev/null 2>&1; then
  for u in "$draft_dir"/*.url; do
    base="$(basename "$u")"
    base="${base%.url}"
    base="${base%.md}"
    echo "  $base → $(cat "$u")"
  done
else
  echo "(none yet)"
fi

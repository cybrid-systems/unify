#!/usr/bin/env bash
# Overnight synthesis: offline compose + N live evolve rounds (MiniMax-M3).
# Issues: draft-only unless UNIFY_AUTO_ISSUE=1.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

N="${UNIFY_OVERNIGHT_N:-20}"
LOG_DIR="${UNIFY_LOG_DIR:-/tmp/unify-overnight}"
mkdir -p "$LOG_DIR"

echo "[overnight] offline compose"
./scripts/run-offline.sh | tee "$LOG_DIR/offline.log"

if [[ ! -f "${MINIMAX_KEY_FILE:-$HOME/code/keys/minimax}" ]]; then
  echo "[overnight] no minimax key; skip live rounds"
  exit 0
fi

# shellcheck disable=SC1091
source ./scripts/env-minimax.sh

echo "[overnight] live evolve N=$N"
ok=0
fail=0
for i in $(seq 1 "$N"); do
  log="$LOG_DIR/live-$(printf '%03d' "$i").log"
  echo "---- round $i/$N ----"
  if ./scripts/run-aura.sh examples/02-live-evolve/main.aura >"$log" 2>&1; then
    if grep -q 'RESULT pass example=02-live-evolve' "$log"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
      # Host-ish signals → draft (never denseness-only)
      if grep -qE 'unbound variable|recursion depth exceeded|SIGSEGV|internal error' "$log"; then
        fp="overnight-$(date -u +%Y%m%d)-r$(printf '%03d' "$i")"
        body="$LOG_DIR/body-$fp.md"
        {
          echo "## Summary"
          echo
          echo "Unify overnight live-evolve round $i hit a host-like error."
          echo
          echo "## Repro"
          echo
          echo '```bash'
          echo "source ./scripts/env-minimax.sh"
          echo "./scripts/run-aura.sh examples/02-live-evolve/main.aura"
          echo '```'
          echo
          echo "## Log tail"
          echo
          echo '```'
          tail -n 80 "$log"
          echo '```'
        } >"$body"
        ./scripts/file-aura-issue.sh \
          --title "[Unify] host residual in live-evolve round $i" \
          --class host \
          --fingerprint "$fp" \
          --body-file "$body" || true
      fi
    fi
  else
    fail=$((fail + 1))
  fi
done

echo "[overnight] ok=$ok fail=$fail total=$N"
echo "logs: $LOG_DIR"
